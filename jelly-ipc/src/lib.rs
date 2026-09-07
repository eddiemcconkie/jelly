//! Wire schema shared by the jelly daemon and its quickshell client.
//!
//! Transport is a private Unix socket speaking JSON lines: one
//! `ClientMessage` per line from the client, one `DaemonMessage` per line
//! from the daemon. Keep every type here dependency-light (serde only).

use serde::{Deserialize, Serialize};

/// Client → daemon.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    /// Liveness check; daemon replies with `Pong`.
    Ping,
    /// Ask for the current auth status.
    GetAuthStatus,
    /// Ask daemon to (re)authenticate. Password comes from rbw; the daemon
    /// never accepts a password over the socket.
    Login,
    /// Replace the queue and start playing at `start_index`.
    Play {
        tracks: Vec<TrackMeta>,
        #[serde(default)]
        start_index: usize,
    },
    Pause,
    Resume,
    TogglePlay,
    Stop,
    Next,
    Prev,
    /// Seek to an absolute position in seconds.
    Seek { position_secs: f64 },
    /// Volume 0..=100.
    SetVolume { volume: u8 },
    /// Full snapshot of playback + queue.
    GetState,
}

/// Daemon → client.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DaemonMessage {
    Pong,
    AuthStatus { status: AuthStatus },
    /// Full snapshot, sent in reply to `GetState` and on every change.
    State(Box<PlaybackSnapshot>),
    /// Small increment used for high-frequency position updates.
    Position { position_secs: f64 },
    Error { message: String },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthStatus {
    /// Have a valid Jellyfin token.
    Authenticated,
    /// rbw agent locked or no stored secret yet; user interaction needed.
    NeedsUnlock,
    /// Tried and failed (bad credentials or server unreachable).
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackMeta {
    /// Jellyfin item id.
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    /// Track length in seconds, if known.
    #[serde(default)]
    pub duration_secs: Option<f64>,
    /// Absolute URL for primary image, if any.
    #[serde(default)]
    pub image_url: Option<String>,
    /// Absolute URL of the direct-play stream. Optional on the wire: the
    /// daemon rebuilds it from `id` (client only knows ids).
    #[serde(default)]
    pub stream_url: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackStatus {
    Stopped,
    Paused,
    Playing,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSnapshot {
    pub status: PlaybackStatus,
    /// Index into the queue of the current track, if any.
    pub current_index: Option<usize>,
    pub queue: Vec<TrackMeta>,
    /// Position of the current track in seconds.
    pub position_secs: f64,
    /// Duration of the current track in seconds, if known.
    pub duration_secs: Option<f64>,
    pub volume: u8,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    /// Filled when auth is not `authenticated`.
    #[serde(default)]
    pub auth: Option<AuthStatus>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    Off,
    All,
    One,
}

impl Default for PlaybackSnapshot {
    fn default() -> Self {
        Self {
            status: PlaybackStatus::Stopped,
            current_index: None,
            queue: Vec::new(),
            position_secs: 0.0,
            duration_secs: None,
            volume: 100,
            shuffle: false,
            repeat: RepeatMode::Off,
            auth: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_message_round_trips() {
        let msg = ClientMessage::Play {
            tracks: vec![TrackMeta {
                id: "abc".into(),
                name: "Song".into(),
                artist: "Artist".into(),
                album: "Album".into(),
                duration_secs: Some(180.0),
                image_url: None,
                stream_url: "http://x/stream".into(),
            }],
            start_index: 0,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"play\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn daemon_message_round_trips() {
        let msg = DaemonMessage::State(Box::default());
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"state\""));
        let back: DaemonMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn auth_status_is_snake_case() {
        let json = serde_json::to_string(&AuthStatus::NeedsUnlock).unwrap();
        assert_eq!(json, "\"needs_unlock\"");
    }
}
