//! Commands accepted from any front door (socket clients and MPRIS).
//!
//! The coordinator owns the two-tier playback model (model.rs): every
//! transition is decided here and driven into the engine (which plays one
//! track at a time). The watch-shared snapshot is derived from the model.

use crate::server::BrowseRequest;
use jelly_ipc::{ClientMessage};
use jelly_ipc::{ClientKind, ErrorCode, PlaybackSnapshot, PlaybackStatus, RepeatMode, TrackMeta};
use std::sync::Arc;

#[derive(Debug, Clone)]
pub enum AppCommand {
    /// Replace the playback context and start playing at `start_index`.
    /// The queue survives.
    Play { tracks: Vec<TrackMeta>, start_index: usize },
    Pause,
    Resume,
    Toggle,
    Stop,
    Next,
    Prev,
    Seek(f64),
    SetVolume(u8),
    SetRepeat(RepeatMode),
    SetShuffle(bool),
    /// Append tracks to the tail of the queue (starts playing if idle).
    Enqueue { items: Vec<TrackMeta> },
    /// Insert a track at the head of the queue (plays next).
    PlayNext { item: TrackMeta },
    /// Jump to a waiting queue item, consuming earlier ones. `req_id`
    /// rides along so a refusal can be echoed to its requester.
    JumpTo { index: usize, req_id: Option<u64> },
    /// Remove the waiting queue item at this index.
    RemoveFromQueue { index: usize, req_id: Option<u64> },
    /// Move the waiting queue item at `index` by `delta` slots (clamped).
    MoveQueue { index: usize, delta: i32, req_id: Option<u64> },
    /// Re-authenticate using rbw-stored credentials.
    Login,
}

/// State machine glue between the socket/MPRIS front doors, the Jellyfin
/// client, the mpv engine, and the shared snapshot.
pub struct Coordinator {
    pub client: crate::jellyfin::JellyfinClient,
    pub engine: crate::playback::EngineHandle,
    pub state_tx: crate::state::SharedState,
    pub state_rx: tokio::sync::watch::Receiver<Arc<PlaybackSnapshot>>,
    pub auth_tx: tokio::sync::watch::Sender<jelly_ipc::AuthStatus>,
    pub auth_rx: tokio::sync::watch::Receiver<jelly_ipc::AuthStatus>,
    pub broadcast_tx: tokio::sync::broadcast::Sender<DaemonMessage>,
    pub mpris: crate::mpris::MprisHandle,
    pub server_url: String,
    /// Self-enqueue path for the unlock-retry task.
    pub cmd_tx: tokio::sync::mpsc::UnboundedSender<AppCommand>,
    /// The two-tier playback model — the source of truth.
    pub model: crate::model::PlaybackModel,
    /// Last observed engine facts (mirrored into snapshots).
    pub position_secs: f64,
    pub duration_secs: Option<f64>,
    pub volume: u8,
    pub status: PlaybackStatus,
}

use jelly_ipc::{AuthStatus, DaemonKind, DaemonMessage};

impl Coordinator {
    pub fn snapshot(&self) -> Arc<PlaybackSnapshot> {
        crate::state::snapshot(&self.state_rx)
    }

    /// Derive the wire snapshot from the model + engine facts.
    pub fn build_snapshot(&self) -> PlaybackSnapshot {
        let (context, head, queue) = self.model.snapshot_parts();
        let current = self.model.current();
        PlaybackSnapshot {
            status: self.status,
            context,
            current,
            queue_head: head,
            queue,
            position_secs: self.position_secs,
            duration_secs: self.duration_secs,
            volume: self.volume,
            shuffle: self.model.shuffle,
            repeat: self.model.repeat,
            library_rev: crate::state::LIBRARY_REV,
            auth: Some(*self.auth_rx.borrow()),
        }
    }

    pub async fn push_state(&self, old: &PlaybackSnapshot) {
        let snap = Arc::new(self.build_snapshot());
        let _ = self.state_tx.send(snap.clone());
        let _ = self
            .broadcast_tx
            .send(DaemonMessage::new(DaemonKind::State(Box::new((*snap).clone())), None));
        let changed = crate::mpris::changed_props(old, &snap);
        if !changed.is_empty() {
            if let Err(e) = self.mpris.player_props_changed(changed).await {
                tracing::warn!("mpris props changed failed: {e}");
            }
        }
    }

    /// Apply a model transition to the engine.
    fn apply(&mut self, t: crate::model::Transition) {
        use crate::model::Transition;
        match t {
            Transition::Play(track) => {
                self.position_secs = 0.0;
                self.duration_secs = track.duration_secs;
                self.engine
                    .send(crate::playback::EngineCommand::PlayUrl(track.stream_url.clone()));
                self.status = PlaybackStatus::Playing;
            }
            Transition::Stop => {
                self.engine.send(crate::playback::EngineCommand::Stop);
                self.status = PlaybackStatus::Stopped;
                self.position_secs = 0.0;
            }
            // 5s-rule restart: rewind the current track.
            Transition::Stay => {
                self.position_secs = 0.0;
                self.engine.send(crate::playback::EngineCommand::Seek(0.0));
            }
        }
    }

    pub async fn handle_cmd(&mut self, cmd: AppCommand) {
        let old = self.build_snapshot();
        match cmd {
            AppCommand::Login => self.login().await,
            AppCommand::Play { mut tracks, start_index } => {
                self.rebuild_stream_urls(&mut tracks);
                if tracks.is_empty() {
                    return;
                }
                let name = tracks[0].album.clone();
                let artist = tracks[0].artist.clone();
                let image = tracks[0].image_url.clone();
                let t = self.model.set_context(name, artist, image, tracks, start_index);
                self.apply(t);
            }
            AppCommand::Pause => {
                self.engine.send(crate::playback::EngineCommand::Pause);
                self.status = PlaybackStatus::Paused;
            }
            AppCommand::Resume => {
                self.engine.send(crate::playback::EngineCommand::Unpause);
                self.status = PlaybackStatus::Playing;
            }
            AppCommand::Toggle => self.engine.send(crate::playback::EngineCommand::Toggle),
            AppCommand::Stop => {
                self.engine.send(crate::playback::EngineCommand::Stop);
                self.status = PlaybackStatus::Stopped;
            }
            AppCommand::Next => {
                let t = self.model.next();
                self.apply(t);
            }
            AppCommand::Prev => {
                let t = self.model.prev(self.position_secs);
                self.apply(t);
            }
            AppCommand::Seek(pos) => {
                self.position_secs = pos.max(0.0);
                self.engine.send(crate::playback::EngineCommand::Seek(self.position_secs));
            }
            AppCommand::SetVolume(v) => {
                self.volume = v;
                self.engine.send(crate::playback::EngineCommand::SetVolume(v));
            }
            AppCommand::SetRepeat(mode) => {
                self.model.repeat = mode;
                // loop-file natively repeats the single track (repeat-one);
                // repeat-all wrap and off/stop are the model's decisions.
                self.engine
                    .send(crate::playback::EngineCommand::SetLoopFile(mode == RepeatMode::One));
            }
            AppCommand::SetShuffle(on) => {
                self.model.set_shuffle(on);
            }
            AppCommand::Enqueue { mut items } => {
                self.rebuild_stream_urls(&mut items);
                let idle = self.model.head.is_none() && self.model.queue.is_empty();
                let stopped = self.status == PlaybackStatus::Stopped;
                self.model.enqueue(items);
                // Nothing was queued and nothing is playing: start now.
                if idle && stopped {
                    let t = self.model.next();
                    self.apply(t);
                }
            }
            AppCommand::PlayNext { mut item } => {
                self.rebuild_stream_urls(std::slice::from_mut(&mut item));
                self.model.play_next(item);
            }
            AppCommand::JumpTo { index, req_id } => match self.model.jump(index) {
                Some(item) => {
                    self.apply(crate::model::Transition::Play(item));
                }
                None => {
                    let _ = self.broadcast_tx.send(DaemonMessage::new(
                        DaemonKind::Error {
                            code: ErrorCode::NotFound,
                            message: format!("queue index {index} does not exist"),
                        },
                        req_id,
                    ));
                }
            },
            AppCommand::RemoveFromQueue { index, req_id } => {
                if self.model.remove(index).is_none() {
                    let _ = self.broadcast_tx.send(DaemonMessage::new(
                        DaemonKind::Error {
                            code: ErrorCode::NotFound,
                            message: format!("queue index {index} does not exist"),
                        },
                        req_id,
                    ));
                }
            }
            AppCommand::MoveQueue { index, delta, req_id } => {
                if !self.model.move_item(index, delta) {
                    let _ = self.broadcast_tx.send(DaemonMessage::new(
                        DaemonKind::Error {
                            code: ErrorCode::Invalid,
                            message: format!("cannot move queue index {index} by {delta}"),
                        },
                        req_id,
                    ));
                }
            }
        }
        self.push_state(&old).await;
    }

    /// Fill in direct-play stream URLs from item ids (the client never
    /// sends them).
    fn rebuild_stream_urls(&self, tracks: &mut [TrackMeta]) {
        for t in tracks.iter_mut() {
            if let Some(url) = self.client.stream_url(&t.id) {
                t.stream_url = url;
            }
        }
    }

    /// Answer a browse request routed from the socket server. Replies are
    /// per-connection (oneshot), never broadcast.
    pub async fn handle_browse(&mut self, req: BrowseRequest) {
        let ClientMessage { kind, req_id } = req.msg;
        if !self.client.is_authenticated() {
            let _ = req.reply.send(DaemonMessage::new(
                DaemonKind::Error {
                    code: ErrorCode::NotAuthenticated,
                    message: "browse needs an authenticated session; send login".into(),
                },
                req_id,
            ));
            return;
        }
        let fetched: anyhow::Result<Vec<crate::jellyfin::MediaItem>> = match kind {
            ClientKind::BrowseArtists => self.client.album_artists().await,
            ClientKind::BrowseAlbums { artist_id } => self.client.albums_for_artist(&artist_id).await,
            ClientKind::BrowseTracks { album_id } => self.client.tracks_for_album(&album_id).await,
            ClientKind::BrowsePlaylists => self.client.playlists().await,
            ClientKind::BrowsePlaylistTracks { playlist_id } => {
                self.client.playlist_tracks(&playlist_id).await
            }
            other => {
                let _ = req.reply.send(DaemonMessage::new(
                    DaemonKind::Error {
                        code: ErrorCode::BadMessage,
                        message: format!("not a browse request: {other:?}"),
                    },
                    req_id,
                ));
                return;
            }
        };
        let reply = match fetched {
            Ok(items) => {
                let items = items
                    .into_iter()
                    .map(|item| {
                        crate::jellyfin::browse_item_from(&item, self.client.image_url(&item))
                    })
                    .collect();
                DaemonMessage::new(
                    DaemonKind::Browse {
                        items,
                        library_rev: crate::state::LIBRARY_REV,
                    },
                    req_id,
                )
            }
            Err(e) => DaemonMessage::new(
                DaemonKind::Error {
                    code: ErrorCode::Internal,
                    message: format!("browse failed: {e:#}"),
                },
                req_id,
            ),
        };
        let _ = req.reply.send(reply);
    }

    async fn login(&mut self) {
        let old = self.build_snapshot();
        if !crate::rbw::unlocked().await {
            tracing::info!("rbw locked; spawning rbw unlock for a pinentry prompt");
            let _ = self.auth_tx.send(AuthStatus::NeedsUnlock);
            self.push_state(&old).await;
            let _ = crate::rbw::spawn_unlock().await;
            self.schedule_unlock_retry();
            return;
        }
        match crate::rbw::get_credentials().await {
            Ok((username, password)) => match self.client.authenticate(&username, &password).await {
                Ok(_) => {
                    tracing::info!("authenticated as {username}");
                    let _ = self.auth_tx.send(AuthStatus::Authenticated);
                }
                Err(e) => {
                    tracing::warn!("login failed: {e:#}");
                    let _ = self.auth_tx.send(AuthStatus::Failed);
                }
            },
            Err(e) => {
                tracing::warn!("rbw credential fetch failed: {e:#}");
                let _ = self.auth_tx.send(AuthStatus::NeedsUnlock);
            }
        }
        self.push_state(&old).await;
    }

    /// Poll until the agent unlocks (user completes pinentry), then re-login.
    /// One retry task at a time.
    fn schedule_unlock_retry(&self) {
        use std::sync::atomic::{AtomicBool, Ordering};
        static RETRYING: AtomicBool = AtomicBool::new(false);
        if RETRYING.swap(true, Ordering::SeqCst) {
            return;
        }
        let cmd_tx = self.cmd_tx.clone();
        tokio::spawn(async move {
            for _ in 0..90 {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                if crate::rbw::unlocked().await {
                    let _ = cmd_tx.send(AppCommand::Login);
                    break;
                }
            }
            RETRYING.store(false, Ordering::SeqCst);
        });
    }

    pub async fn handle_engine_event(&mut self, ev: crate::playback::EngineEvent) {
        let old = self.build_snapshot();
        match ev {
            crate::playback::EngineEvent::Status(status) => {
                self.status = status;
            }
            crate::playback::EngineEvent::Position(pos) => {
                // High-frequency: update the shared snapshot and send only
                // the small Position message. No State broadcast, no MPRIS.
                self.position_secs = pos;
                let mut snap = self.build_snapshot();
                snap.position_secs = pos;
                self.state_tx.send_replace(Arc::new(snap));
                let _ = self
                    .broadcast_tx
                    .send(DaemonMessage::new(DaemonKind::Position { position_secs: pos }, None));
                return;
            }
            crate::playback::EngineEvent::Duration(d) => {
                self.duration_secs = Some(d);
            }
            crate::playback::EngineEvent::LoadFailed => {
                // Tell clients; keep state as-is.
                let _ = self.broadcast_tx.send(DaemonMessage::new(
                    DaemonKind::Error {
                        code: ErrorCode::Internal,
                        message: "track failed to load".into(),
                    },
                    None,
                ));
                return;
            }
            crate::playback::EngineEvent::TrackEnded => {
                // The model owns the transition (queue head, context walk,
                // wrap, stop). Repeat-one never gets here (loop-file).
                let t = self.model.track_ended();
                self.apply(t);
            }
        }
        self.push_state(&old).await;
    }

    /// Startup convenience: log in if rbw is already unlocked.
    pub async fn try_autologin(&mut self) {
        self.login().await;
    }
}
