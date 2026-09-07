//! Commands accepted from any front door (socket clients and MPRIS).

use jelly_ipc::{PlaybackSnapshot, RepeatMode, TrackMeta};

#[derive(Debug, Clone)]
pub enum AppCommand {
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
}

use jelly_ipc::{AuthStatus, DaemonMessage, PlaybackStatus};
use std::sync::Arc;

impl Coordinator {
    pub fn snapshot(&self) -> Arc<PlaybackSnapshot> {
        crate::state::snapshot(&self.state_rx)
    }

    pub async fn push_state(&self, old: &PlaybackSnapshot) {
        // Stamp the latest auth status into the snapshot (single source of
        // truth for the wire).
        let mut snap = (*self.snapshot()).clone();
        snap.auth = Some(*self.auth_rx.borrow());
        let snap = Arc::new(snap);
        let _ = self.state_tx.send(snap.clone());
        let _ = self.broadcast_tx.send(DaemonMessage::State(Box::new((*snap).clone())));
        let changed = crate::mpris::changed_props(old, &snap);
        if !changed.is_empty() {
            if let Err(e) = self.mpris.player_props_changed(changed).await {
                tracing::warn!("mpris props changed failed: {e}");
            }
        }
    }

    pub async fn handle_cmd(&mut self, cmd: AppCommand) {
        let old = (*self.snapshot()).clone();
        match cmd {
            AppCommand::Login => self.login().await,
            AppCommand::Play { mut tracks, start_index } => {
                // Rebuild stream URLs server-side; the client only knows ids.
                for t in tracks.iter_mut() {
                    if let Some(url) = self.client.stream_url(&t.id) {
                        t.stream_url = url;
                    }
                }
                let urls: Vec<String> = tracks.iter().map(|t| t.stream_url.clone()).collect();
                self.engine.send(crate::playback::EngineCommand::PlayUrls { urls, start_index });
                let mut snap = (*self.snapshot()).clone();
                snap.queue = tracks;
                snap.current_index = Some(start_index);
                self.state_tx.send_replace(Arc::new(snap));
            }
            AppCommand::Pause => self.engine.send(crate::playback::EngineCommand::Pause),
            AppCommand::Resume => self.engine.send(crate::playback::EngineCommand::Unpause),
            AppCommand::Toggle => self.engine.send(crate::playback::EngineCommand::Toggle),
            AppCommand::Stop => self.engine.send(crate::playback::EngineCommand::Stop),
            AppCommand::Next => self.engine.send(crate::playback::EngineCommand::Next),
            AppCommand::Prev => self.engine.send(crate::playback::EngineCommand::Prev),
            AppCommand::Seek(pos) => self.engine.send(crate::playback::EngineCommand::Seek(pos)),
            AppCommand::SetVolume(v) => {
                self.engine.send(crate::playback::EngineCommand::SetVolume(v));
                let mut snap = (*self.snapshot()).clone();
                snap.volume = v;
                self.state_tx.send_replace(Arc::new(snap));
            }
            AppCommand::SetRepeat(mode) => {
                let mut snap = (*self.snapshot()).clone();
                snap.repeat = mode;
                self.state_tx.send_replace(Arc::new(snap));
            }
            AppCommand::SetShuffle(on) => {
                let mut snap = (*self.snapshot()).clone();
                snap.shuffle = on;
                self.state_tx.send_replace(Arc::new(snap));
            }
        }
        self.push_state(&old).await;
    }

    async fn login(&mut self) {
        let old = (*self.snapshot()).clone();
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
        let old = (*self.snapshot()).clone();
        let mut snap = (*self.snapshot()).clone();
        match ev {
            crate::playback::EngineEvent::Status(status) => {
                snap.status = status;
                if status == PlaybackStatus::Stopped {
                    snap.position_secs = 0.0;
                }
            }
            crate::playback::EngineEvent::Position(pos) => {
                // High-frequency: update the shared snapshot and send only
                // the small Position message. No State broadcast, no MPRIS.
                snap.position_secs = pos;
                self.state_tx.send_replace(Arc::new(snap));
                let _ = self.broadcast_tx.send(DaemonMessage::Position { position_secs: pos });
                return;
            }
            crate::playback::EngineEvent::Duration(d) => {
                snap.duration_secs = Some(d);
                if let Some(i) = snap.current_index {
                    if let Some(t) = snap.queue.get_mut(i) {
                        t.duration_secs = Some(d);
                    }
                }
            }
            crate::playback::EngineEvent::LoadFailed => {
                // Tell clients; keep state as-is (mpv will advance or idle).
                let _ = self.broadcast_tx.send(DaemonMessage::Error {
                    message: "track failed to load".into(),
                });
                return;
            }
            crate::playback::EngineEvent::TrackChanged(i) => {
                snap.current_index = Some(i);
                snap.position_secs = 0.0;
                snap.duration_secs = snap.queue.get(i).and_then(|t| t.duration_secs);
            }
        }
        self.state_tx.send_replace(Arc::new(snap));
        self.push_state(&old).await;
    }

    /// Startup convenience: log in if rbw is already unlocked.
    pub async fn try_autologin(&mut self) {
        self.login().await;
    }
}
