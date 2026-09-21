//! Commands accepted from any front door (socket clients and MPRIS).
//!
//! The coordinator owns the two-tier playback model (model.rs): every
//! transition is decided here and driven into the engine (which plays one
//! track at a time). The watch-shared snapshot is derived from the model.

use crate::server::BrowseRequest;
use crate::session::SessionEvent;
use anyhow::Context as _;
use jelly_ipc::ClientMessage;
use jelly_ipc::{
    ClientKind, ErrorCode, PlaybackSnapshot, PlaybackStatus, RepeatMode, Tier, TrackMeta,
};
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::sync::Arc;

#[derive(Debug, Clone)]
pub enum AppCommand {
    /// Replace the playback context and start playing at `start_index`.
    /// The waiting queue survives unless `clear_queue` (queue-tab pick).
    Play {
        tracks: Vec<TrackMeta>,
        start_index: usize,
        clear_queue: bool,
    },
    /// Play an album by id: the daemon fetches its tracks and starts at 0.
    PlayAlbum {
        album_id: String,
        req_id: Option<u64>,
    },
    /// Play all tracks carrying this Jellyfin tag/mix.
    PlayMix {
        tag: String,
        req_id: Option<u64>,
    },
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
    Enqueue {
        items: Vec<TrackMeta>,
    },
    /// Insert a track at the head of the queue (plays next).
    PlayNext {
        item: TrackMeta,
    },
    /// Jump to a waiting queue item, consuming earlier ones. `req_id`
    /// rides along so a refusal can be echoed to its requester.
    JumpTo {
        index: usize,
        req_id: Option<u64>,
    },
    /// Remove the waiting queue item at this index.
    RemoveFromQueue {
        index: usize,
        req_id: Option<u64>,
    },
    /// Move the waiting queue item at `index` by `delta` slots (clamped).
    MoveQueue {
        index: usize,
        delta: i32,
        req_id: Option<u64>,
    },
    /// Toggle the favorite flag on an item; pushes the refreshed set.
    ToggleFavorite {
        item_id: String,
        req_id: Option<u64>,
    },
    /// Set a track's tier (synchronous server write; failure = no change).
    SetTier {
        item_id: String,
        tier: Tier,
        req_id: Option<u64>,
    },
    /// Toggle one album tag/mix (synchronous server write).
    ToggleTag {
        album_id: String,
        tag: String,
        present: Option<bool>,
        req_id: Option<u64>,
    },
    /// Cycle a track's tier from its current value.
    CycleTier {
        item_id: String,
        req_id: Option<u64>,
    },
    /// Set the global playback filter (walk-time minimum tier).
    SetFilter {
        filter: jelly_ipc::TierFilter,
    },
    /// Step the global filter: up = toward Favorite, down = toward All.
    StepFilter {
        up: bool,
    },
    /// Raw event from the Jellyfin session websocket; the coordinator
    /// filters by user and applies tier echoes (our writes and edits from
    /// other devices).
    SessionEvent(crate::session::SessionEvent),
    /// Re-authenticate using rbw-stored credentials.
    Login,
}

/// Short label for command logging (no payload noise).
fn cmd_title(cmd: &AppCommand) -> String {
    match cmd {
        AppCommand::Play { start_index, .. } => format!("Play@{start_index}"),
        AppCommand::PlayAlbum { album_id, .. } => format!("PlayAlbum {album_id}"),
        AppCommand::PlayMix { tag, .. } => format!("PlayMix {tag}"),
        AppCommand::JumpTo { index, .. } => format!("JumpTo@{index}"),
        AppCommand::RemoveFromQueue { index, .. } => format!("Remove@{index}"),
        AppCommand::MoveQueue { index, delta, .. } => format!("Move@{index} {delta:+}"),
        AppCommand::ToggleFavorite { item_id, .. } => format!("Fav {item_id}"),
        AppCommand::SetTier { item_id, tier, .. } => format!("Tier {item_id} {tier:?}"),
        AppCommand::ToggleTag { album_id, tag, .. } => format!("Tag {album_id} {tag}"),
        AppCommand::CycleTier { item_id, .. } => format!("TierCycle {item_id}"),
        AppCommand::SessionEvent(SessionEvent::UserDataChanged { entries, .. }) => {
            format!("SessionEvent UserDataChanged n={}", entries.len())
        }
        AppCommand::SessionEvent(SessionEvent::KeepAlive) => "SessionEvent KeepAlive".into(),
        AppCommand::Enqueue { items, .. } => format!("Enqueue n={}", items.len()),
        AppCommand::SetShuffle(on) => format!("Shuffle {on}"),
        AppCommand::SetRepeat(r) => format!("Repeat {r:?}"),
        other => format!("{other:?}"),
    }
}

fn filter_label(filter: jelly_ipc::TierFilter) -> &'static str {
    match filter {
        jelly_ipc::TierFilter::All => "All",
        jelly_ipc::TierFilter::Liked => "Liked",
        jelly_ipc::TierFilter::Loved => "Loved",
        jelly_ipc::TierFilter::Favorite => "Favorite",
    }
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
    /// Ids of the user's favorited songs (heart icons).
    pub favorite_ids: Vec<String>,
    /// Track tiers by item id; only rated entries present. Seeded on
    /// login, patched by writes and `UserDataChanged` echoes.
    pub tiers: BTreeMap<String, Tier>,
    /// The global playback filter applied at walk time (JELLY-40).
    pub filter: jelly_ipc::TierFilter,
    /// All known album tags/mixes, aggregated from the album browse list.
    pub mixes: Vec<String>,
    /// Publishes the websocket session (token + user) for the session
    /// listener; `None` parks it (logout / failed login).
    pub session_tx: tokio::sync::watch::Sender<Option<crate::session::Session>>,
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
            favorite_ids: self.favorite_ids.clone(),
            tiers: self.tiers.clone(),
            filter: self.filter,
            mixes: self.mixes.clone(),
        }
    }

    pub async fn push_state(&self, old: &PlaybackSnapshot) {
        let snap = Arc::new(self.build_snapshot());
        let _ = self.state_tx.send(snap.clone());
        let _ = self.broadcast_tx.send(DaemonMessage::new(
            DaemonKind::State(Box::new((*snap).clone())),
            None,
        ));
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
                self.engine.send(crate::playback::EngineCommand::PlayUrl(
                    track.stream_url.clone(),
                ));
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
        tracing::info!("cmd: {:?}", cmd_title(&cmd));
        let old = self.build_snapshot();
        match cmd {
            AppCommand::Login => self.login().await,
            AppCommand::Play {
                mut tracks,
                start_index,
                clear_queue,
            } => {
                self.rebuild_stream_urls(&mut tracks);
                if tracks.is_empty() {
                    return;
                }
                let name = tracks[0].album.clone();
                let artist = tracks[0].artist.clone();
                let image = tracks[0].image_url.clone();
                let t =
                    self.model
                        .set_context(name, artist, image, tracks, start_index, clear_queue);
                self.apply(t);
            }
            AppCommand::PlayAlbum { album_id, req_id } => {
                self.play_album_and_apply(&album_id, req_id).await;
            }
            AppCommand::PlayMix { tag, req_id } => {
                self.play_mix_and_apply(&tag, req_id).await;
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
                let t = self.filtered_next();
                self.apply(t);
            }
            AppCommand::Prev => {
                let t = self.model.prev(self.position_secs);
                self.apply(t);
            }
            AppCommand::Seek(pos) => {
                // Clamp to what the current track reports; a seek past the
                // end must never push the optimistic position beyond it.
                let max = self.duration_secs.unwrap_or(f64::MAX);
                self.position_secs = pos.clamp(0.0, max);
                self.engine
                    .send(crate::playback::EngineCommand::Seek(self.position_secs));
            }
            AppCommand::SetVolume(v) => {
                self.volume = v;
                self.engine
                    .send(crate::playback::EngineCommand::SetVolume(v));
            }
            AppCommand::SetRepeat(mode) => {
                self.model.repeat = mode;
                // loop-file natively repeats the single track (repeat-one);
                // repeat-all wrap and off/stop are the model's decisions.
                self.engine
                    .send(crate::playback::EngineCommand::SetLoopFile(
                        mode == RepeatMode::One,
                    ));
                self.persist_modes().await;
            }
            AppCommand::SetShuffle(on) => {
                self.model.set_shuffle(on);
                self.persist_modes().await;
            }
            AppCommand::SetFilter { filter } => {
                self.filter = filter;
                self.persist_modes().await;
            }
            AppCommand::StepFilter { up } => {
                self.filter = self.filter.step(up);
                self.persist_modes().await;
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
            AppCommand::MoveQueue {
                index,
                delta,
                req_id,
            } => {
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
            AppCommand::ToggleFavorite { item_id, req_id } => {
                if !self.client.is_authenticated() {
                    let _ = self.broadcast_tx.send(DaemonMessage::new(
                        DaemonKind::Error {
                            code: ErrorCode::NotAuthenticated,
                            message: "favorites need an authenticated session".into(),
                        },
                        req_id,
                    ));
                } else {
                    match self.client.toggle_favorite(&item_id).await {
                        Ok(_) => {
                            match self.client.favorite_ids().await {
                                Ok(ids) => self.favorite_ids = ids,
                                Err(e) => {
                                    tracing::warn!("favorite refresh failed: {e:#}");
                                    // Toggle succeeded; approximate by
                                    // flipping this one id locally.
                                    if let Some(p) =
                                        self.favorite_ids.iter().position(|i| i == &item_id)
                                    {
                                        self.favorite_ids.remove(p);
                                    } else {
                                        self.favorite_ids.push(item_id.clone());
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = self.broadcast_tx.send(DaemonMessage::new(
                                DaemonKind::Error {
                                    code: ErrorCode::Internal,
                                    message: format!("favorite toggle failed: {e:#}"),
                                },
                                req_id,
                            ));
                        }
                    }
                }
            }
            AppCommand::SetTier {
                item_id,
                tier,
                req_id,
            } => {
                self.write_tier(&item_id, tier, req_id).await;
            }
            AppCommand::ToggleTag {
                album_id,
                tag,
                present,
                req_id,
            } => {
                self.write_album_tag(&album_id, &tag, present, req_id).await;
            }
            AppCommand::CycleTier { item_id, req_id } => {
                let next = self
                    .tiers
                    .get(&item_id)
                    .copied()
                    .unwrap_or(Tier::Unrated)
                    .next();
                self.write_tier(&item_id, next, req_id).await;
            }
            AppCommand::SessionEvent(ev) => match ev {
                SessionEvent::UserDataChanged { user_id, entries } => {
                    // The server scopes pushes to the acting user's own
                    // sessions; verify before applying (defence in depth).
                    if self.client.user_id() == Some(user_id.as_str()) {
                        for entry in entries {
                            let tier = Tier::from_rating(entry.rating);
                            self.apply_tier_local(&entry.item_id, tier);
                        }
                    }
                }
                SessionEvent::KeepAlive => {
                    // The socket answers it itself; a queued copy is a no-op.
                }
            },
        }
        self.push_state(&old).await;
    }

    /// Local bookkeeping for a tier: presence in the map is the tier
    /// (unrated = absent), and the heart tracks the Favorite tier.
    fn apply_tier_local(&mut self, item_id: &str, tier: Tier) {
        match tier {
            Tier::Unrated => {
                self.tiers.remove(item_id);
            }
            t => {
                self.tiers.insert(item_id.to_string(), t);
            }
        }
        let hearted = self.favorite_ids.iter().any(|i| i == item_id);
        if tier == Tier::Favorite && !hearted {
            self.favorite_ids.push(item_id.to_string());
        } else if tier != Tier::Favorite && hearted {
            self.favorite_ids.retain(|i| i != item_id);
        }
    }

    /// Synchronous tier write: on failure nothing changes and the error
    /// goes back to the requester (no journal, no retry — offline means
    /// read-only).
    /// Snapshot of the session modes for persistence.
    fn current_modes(&self) -> crate::modes::Modes {
        crate::modes::Modes {
            shuffle: self.model.shuffle,
            repeat: self.model.repeat,
            filter: self.filter,
        }
    }

    async fn persist_modes(&self) {
        crate::modes::save(&self.current_modes()).await;
    }

    /// Restore shuffle/repeat/filter at daemon startup (shell reload).
    /// No context exists yet, so this is pure state + one engine flag.
    pub async fn apply_startup_modes(&mut self) {
        let m = crate::modes::load().await;
        self.filter = m.filter;
        self.model.repeat = m.repeat;
        if m.repeat == RepeatMode::One {
            self.engine
                .send(crate::playback::EngineCommand::SetLoopFile(true));
        }
        self.model.set_shuffle(m.shuffle);
        if m != crate::modes::Modes::default() {
            tracing::info!("restored modes: {m:?}");
        }
    }

    /// Filtered context advance (manual next AND natural end-of-track):
    /// field-destructured so the predicate borrows `tiers`/`filter`
    /// while the model walks mutably. Queue consumption and all walk
    /// semantics live in `PlaybackModel::next_with` (tested there).
    fn filtered_next(&mut self) -> crate::model::Transition {
        let Self {
            model,
            filter,
            tiers,
            ..
        } = self;
        model.next_with(&|t: &TrackMeta| {
            let tier = tiers.get(&t.id).copied().unwrap_or(Tier::Unrated);
            filter.passes(tier)
        })
    }

    async fn write_tier(&mut self, item_id: &str, tier: Tier, req_id: Option<u64>) {
        if !self.client.is_authenticated() {
            let _ = self.broadcast_tx.send(DaemonMessage::new(
                DaemonKind::Error {
                    code: ErrorCode::NotAuthenticated,
                    message: "tiers need an authenticated session".into(),
                },
                req_id,
            ));
            return;
        }
        match self.client.set_tier(item_id, tier).await {
            Ok(()) => self.apply_tier_local(item_id, tier),
            Err(e) => {
                let _ = self.broadcast_tx.send(DaemonMessage::new(
                    DaemonKind::Error {
                        code: ErrorCode::Internal,
                        message: format!("tier write failed: {e:#}"),
                    },
                    req_id,
                ));
            }
        }
    }

    async fn write_album_tag(
        &mut self,
        album_id: &str,
        tag: &str,
        present: Option<bool>,
        req_id: Option<u64>,
    ) {
        if !self.client.is_authenticated() {
            let _ = self.broadcast_tx.send(DaemonMessage::new(
                DaemonKind::Error {
                    code: ErrorCode::NotAuthenticated,
                    message: "mixes need an authenticated session".into(),
                },
                req_id,
            ));
            return;
        }
        match self.client.set_album_mix_tag(album_id, tag, present).await {
            Ok(tags) => {
                if let Ok(albums) = self.client.all_albums().await {
                    self.refresh_mixes_from_albums(&albums);
                }
                let _ = self.broadcast_tx.send(DaemonMessage::new(
                    DaemonKind::TagUpdate {
                        album_id: album_id.to_string(),
                        tags,
                    },
                    req_id,
                ));
            }
            Err(e) => {
                let _ = self.broadcast_tx.send(DaemonMessage::new(
                    DaemonKind::Error {
                        code: ErrorCode::Internal,
                        message: format!("tag write failed: {e:#}"),
                    },
                    req_id,
                ));
            }
        }
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

    /// Fetch one item's media metadata.
    async fn fetch_item(&self, id: &str) -> anyhow::Result<crate::jellyfin::MediaItem> {
        let user_id = self.client.user_id().context("not authenticated")?;
        self.client
            .get_json(&format!("/Users/{user_id}/Items/{id}"), &[])
            .await
    }

    /// Play an album by id without the client having its track list:
    /// fetch the album item (for context name/cover) and its tracks, then
    /// hand them to the normal Play path.
    async fn play_album_and_apply(&mut self, album_id: &str, req_id: Option<u64>) {
        if !self.client.is_authenticated() {
            tracing::warn!("play_album before authentication; send login first");
            return;
        }
        let album = match self.fetch_item(album_id).await {
            Ok(a) => a,
            Err(e) => {
                tracing::warn!("play_album: album fetch failed: {e:#}");
                return;
            }
        };
        let items = match self.client.tracks_for_album(album_id).await {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!("play_album: track fetch failed: {e:#}");
                return;
            }
        };
        let tracks: Vec<TrackMeta> = items
            .iter()
            .map(|it| TrackMeta {
                id: it.id.clone(),
                name: it.name.clone(),
                artist: it
                    .album_artist
                    .clone()
                    .or_else(|| it.artists.as_ref().and_then(|a| a.first().cloned()))
                    .unwrap_or_default(),
                album: album.name.clone(),
                duration_secs: it.run_time_ticks.map(|t| t as f64 / 10_000_000.0),
                image_url: self.client.image_url(&album),
                stream_url: String::new(),
            })
            .collect();
        if tracks.is_empty() {
            tracing::warn!("play_album: album {album_id} returned no tracks");
            return;
        }
        let start_index = if self.filter == jelly_ipc::TierFilter::All {
            0
        } else {
            match tracks.iter().position(|t| {
                let tier = self.tiers.get(&t.id).copied().unwrap_or(Tier::Unrated);
                self.filter.passes(tier)
            }) {
                Some(i) => i,
                None => {
                    let _ = self.broadcast_tx.send(DaemonMessage::new(
                        DaemonKind::Error {
                            code: ErrorCode::BadMessage,
                            message: format!("no {} tracks", filter_label(self.filter)),
                        },
                        req_id,
                    ));
                    return;
                }
            }
        };
        let mut tracks = tracks;
        self.rebuild_stream_urls(&mut tracks);
        let name = album.name.clone();
        let artist = tracks[start_index].artist.clone();
        let t = self.model.set_context(
            name,
            artist,
            self.client.image_url(&album),
            tracks,
            start_index,
            false,
        );
        self.apply(t);
    }

    async fn play_mix_and_apply(&mut self, tag: &str, req_id: Option<u64>) {
        if !self.client.is_authenticated() {
            tracing::warn!("play_mix before authentication; send login first");
            return;
        }
        let items = match self.client.tracks_for_tag(tag).await {
            Ok(t) => t,
            Err(e) => {
                let _ = self.broadcast_tx.send(DaemonMessage::new(
                    DaemonKind::Error {
                        code: ErrorCode::Internal,
                        message: format!("mix fetch failed: {e:#}"),
                    },
                    req_id,
                ));
                return;
            }
        };
        let tracks: Vec<TrackMeta> = items
            .iter()
            .map(|it| TrackMeta {
                id: it.id.clone(),
                name: it.name.clone(),
                artist: it
                    .album_artist
                    .clone()
                    .or_else(|| it.artists.as_ref().and_then(|a| a.first().cloned()))
                    .unwrap_or_default(),
                album: it.album_id.clone().unwrap_or_default(),
                duration_secs: it.run_time_ticks.map(|t| t as f64 / 10_000_000.0),
                image_url: self.client.image_url(it),
                stream_url: String::new(),
            })
            .collect();
        if tracks.is_empty() {
            let _ = self.broadcast_tx.send(DaemonMessage::new(
                DaemonKind::Error {
                    code: ErrorCode::NotFound,
                    message: format!("mix '{tag}' has no tracks"),
                },
                req_id,
            ));
            return;
        }
        let start_index = if self.filter == jelly_ipc::TierFilter::All {
            0
        } else {
            match tracks.iter().position(|t| {
                let tier = self.tiers.get(&t.id).copied().unwrap_or(Tier::Unrated);
                self.filter.passes(tier)
            }) {
                Some(i) => i,
                None => {
                    let _ = self.broadcast_tx.send(DaemonMessage::new(
                        DaemonKind::Error {
                            code: ErrorCode::BadMessage,
                            message: format!("no {} tracks", filter_label(self.filter)),
                        },
                        req_id,
                    ));
                    return;
                }
            }
        };
        let mut tracks = tracks;
        self.rebuild_stream_urls(&mut tracks);
        let t = self
            .model
            .set_context(format!("Mix: {tag}"), "", None, tracks, start_index, false);
        self.apply(t);
    }

    fn refresh_mixes_from_albums(&mut self, albums: &[crate::jellyfin::MediaItem]) {
        let mut set = BTreeSet::new();
        for album in albums {
            for tag in album.tags.clone().unwrap_or_default() {
                if let Some(label) = crate::jellyfin::mix_label(&tag) {
                    set.insert(label);
                }
            }
        }
        self.mixes = set.into_iter().collect();
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
        let fetched: anyhow::Result<Vec<crate::jellyfin::MediaItem>> = match &kind {
            ClientKind::BrowseAlbums => self.client.all_albums().await,
            ClientKind::BrowseTracks { album_id } => self.client.tracks_for_album(album_id).await,
            ClientKind::BrowsePlaylists => self.client.playlists().await,
            ClientKind::BrowsePlaylistTracks { playlist_id } => {
                self.client.playlist_tracks(playlist_id).await
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
                if matches!(kind, ClientKind::BrowseAlbums) {
                    self.refresh_mixes_from_albums(&items);
                }
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
        // Park the session socket while we sort out credentials.
        let _ = self.session_tx.send(None);
        // Session cache first: no rbw round-trip (and no pinentry risk)
        // when this is a daemon restart within the same login session.
        if let Some(cached) = crate::rbw::cached_credentials() {
            match self
                .client
                .authenticate(&cached.username, &cached.password)
                .await
            {
                Ok(_) => {
                    tracing::info!("authenticated as {} (cached credentials)", cached.username);
                    let _ = self.auth_tx.send(AuthStatus::Authenticated);
                    self.refresh_user_state().await;
                    self.push_state(&old).await;
                    return;
                }
                Err(e) => {
                    tracing::warn!("cached credentials rejected, falling back to rbw: {e:#}");
                    crate::rbw::clear_cached_credentials();
                }
            }
        }
        if !crate::rbw::unlocked().await {
            tracing::info!("rbw locked; spawning rbw unlock for a pinentry prompt");
            let _ = self.auth_tx.send(AuthStatus::NeedsUnlock);
            self.push_state(&old).await;
            let _ = crate::rbw::spawn_unlock().await;
            self.schedule_unlock_retry();
            return;
        }
        match crate::rbw::get_credentials().await {
            Ok((username, password)) => {
                match self.client.authenticate(&username, &password).await {
                    Ok(_) => {
                        tracing::info!("authenticated as {username}");
                        let _ = self.auth_tx.send(AuthStatus::Authenticated);
                        crate::rbw::cache_credentials(&crate::rbw::CachedCredentials {
                            username: username.clone(),
                            password,
                        });
                        self.refresh_user_state().await;
                    }
                    Err(e) => {
                        tracing::warn!("login failed: {e:#}");
                        let _ = self.auth_tx.send(AuthStatus::Failed);
                    }
                }
            }
            Err(e) => {
                tracing::warn!("rbw credential fetch failed: {e:#}");
                let _ = self.auth_tx.send(AuthStatus::NeedsUnlock);
            }
        }
        self.push_state(&old).await;
    }

    /// After a successful login: pull the authoritative favorite set and
    /// tier map, then publish the session for the UserDataChanged socket.
    async fn refresh_user_state(&mut self) {
        match self.client.favorite_ids().await {
            Ok(ids) => self.favorite_ids = ids,
            Err(e) => tracing::warn!("favorite fetch failed: {e:#}"),
        }
        match self.client.tier_map().await {
            Ok(map) => self.tiers = map,
            Err(e) => tracing::warn!("tier fetch failed: {e:#}"),
        }
        let session = self.client.session(&self.server_url);
        let _ = self.session_tx.send(session);
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
                let _ = self.broadcast_tx.send(DaemonMessage::new(
                    DaemonKind::Position { position_secs: pos },
                    None,
                ));
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
                // wrap, stop) under the active tier filter. Repeat-one
                // never gets here (loop-file).
                let t = self.filtered_next();
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
