//! Wire schema shared by the jelly daemon and its quickshell client.
//!
//! Transport is a private Unix socket speaking JSON lines: one
//! `ClientMessage` per line from the client, one `DaemonMessage` per line
//! from the daemon. Keep every type here dependency-light (serde only).

use serde::{Deserialize, Serialize};

/// Client → daemon envelope: one of `ClientKind` plus an optional
/// `req_id` that the daemon echoes back on every correlated reply.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ClientMessage {
    #[serde(flatten)]
    pub kind: ClientKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub req_id: Option<u64>,
}

impl ClientMessage {
    pub fn new(kind: ClientKind, req_id: Option<u64>) -> Self {
        Self { kind, req_id }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientKind {
    /// First message on a connection; daemon replies with `Welcome`.
    Hello,
    /// Liveness check; daemon replies with `Pong`.
    Ping,
    /// Ask for the current auth status.
    GetAuthStatus,
    /// Ask daemon to (re)authenticate. Password comes from rbw; the daemon
    /// never accepts a password over the socket.
    Login,
    /// Replace the playback context (loaded album/playlist) and start
    /// playing at `start_index`. Any waiting queue survives.
    Play {
        tracks: Vec<TrackMeta>,
        #[serde(default)]
        start_index: usize,
    },
    Pause,
    Resume,
    TogglePlay,
    Stop,
    /// Advance. Plays the queue head if one is waiting, else walks the
    /// playback context (wrap under repeat-all; stop cleanly at the end
    /// with repeat off).
    Next,
    /// Backward. The daemon applies the 5s rule (restart vs previous) and
    /// repeat-all edge wrap; never mutates the queue.
    Prev,
    /// Seek to an absolute position in seconds.
    Seek { position_secs: f64 },
    /// Volume 0..=100.
    SetVolume { volume: u8 },
    /// Full snapshot of playback + context + queue.
    GetState,
    // --- Browse (typed views, lazy fetch; no pagination in v1) ---
    /// Album artists — the top of the browse tree.
    BrowseArtists,
    /// Albums under an artist.
    BrowseAlbums { artist_id: String },
    /// Tracks on an album.
    BrowseTracks { album_id: String },
    /// The user's playlists.
    BrowsePlaylists,
    /// Items of one playlist.
    BrowsePlaylistTracks { playlist_id: String },
    // --- Queue editing (the queue only; the context is immutable) ---
    /// Append tracks to the tail of the queue (starts playing if stopped
    /// and nothing else is queued).
    Enqueue { items: Vec<TrackMeta> },
    /// Insert one track at the head of the queue (plays next).
    PlayNext { item: TrackMeta },
    /// Jump to a waiting queue item; earlier waiting items are consumed.
    JumpTo { index: usize },
    /// Remove the waiting queue item at `index`.
    RemoveFromQueue { index: usize },
    /// Move the waiting queue item at `index` by -1 or +1 (clamped).
    MoveQueue { index: usize, delta: i32 },
    SetRepeat { mode: RepeatMode },
    /// Toggles a fixed permutation of the context order only.
    SetShuffle { on: bool },
}

/// Daemon → client envelope: one of `DaemonKind` plus `req_id` echoed
/// from the request that produced it (absent on pushed updates).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DaemonMessage {
    #[serde(flatten)]
    pub kind: DaemonKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub req_id: Option<u64>,
}

impl DaemonMessage {
    pub fn new(kind: DaemonKind, req_id: Option<u64>) -> Self {
        Self { kind, req_id }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DaemonKind {
    Pong,
    /// Reply to `Hello`: protocol version + current library revision.
    Welcome { version: u32, library_rev: u64 },
    AuthStatus { status: AuthStatus },
    /// Full snapshot, sent in reply to `GetState` and on every change.
    State(Box<PlaybackSnapshot>),
    /// Small increment used for high-frequency position updates.
    Position { position_secs: f64 },
    /// Reply to any `Browse*` request.
    Browse {
        items: Vec<BrowseItem>,
        library_rev: u64,
    },
    /// Confirmation that a state-changing command was accepted.
    Ack,
    Error { code: ErrorCode, message: String },
}

/// Coded errors so clients can branch without parsing messages.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// Unparseable or unsupported message.
    BadMessage,
    /// Operation needs an authenticated Jellyfin session.
    NotAuthenticated,
    /// Referenced item (or queue index) does not exist.
    NotFound,
    /// Operation is not valid in the current state (e.g. removing the
    /// playing track).
    Invalid,
    /// Daemon-side failure.
    Internal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BrowseItem {
    pub id: String,
    pub name: String,
    /// Jellyfin item type ("musicalbum", "audio", "playlist", ...).
    #[serde(default)]
    pub item_type: String,
    /// Context line: artist for albums/tracks, album for tracks, etc.
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub duration_secs: Option<f64>,
    #[serde(default)]
    pub image_url: Option<String>,
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

/// The loaded album or playlist. Immutable while loaded; selecting a song
/// inside one replaces the context (the queue survives).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ContextSnapshot {
    /// Display name (album or playlist title).
    pub name: String,
    /// Artist line for albums; empty for playlists.
    #[serde(default)]
    pub artist: String,
    /// Cover image URL, if any.
    #[serde(default)]
    pub image_url: Option<String>,
    /// Full track list in context order (already permuted when shuffle is
    /// on, so `current_index` walks the shuffled order too).
    pub tracks: Vec<TrackMeta>,
    /// Position of the current track within `tracks`.
    #[serde(default)]
    pub current_index: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSnapshot {
    pub status: PlaybackStatus,
    /// The loaded playback context, if any.
    #[serde(default)]
    pub context: Option<ContextSnapshot>,
    /// The currently-playing track, whatever tier it came from.
    #[serde(default)]
    pub current: Option<TrackMeta>,
    /// The current queue song (the head), when playing from the queue.
    #[serde(default)]
    pub queue_head: Option<TrackMeta>,
    /// Waiting queue items, in FIFO order (head excluded).
    #[serde(default)]
    pub queue: Vec<TrackMeta>,
    /// Position of the current track in seconds.
    pub position_secs: f64,
    /// Duration of the current track in seconds, if known.
    pub duration_secs: Option<f64>,
    pub volume: u8,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    /// Monotonic revision of the local library view; clients use it to
    /// invalidate cached browse views. Constant 0 until the snapshot layer
    /// exists (lazy fetches are always fresh).
    #[serde(default)]
    pub library_rev: u64,
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
            context: None,
            current: None,
            queue_head: None,
            queue: Vec::new(),
            position_secs: 0.0,
            duration_secs: None,
            volume: 100,
            shuffle: false,
            repeat: RepeatMode::Off,
            library_rev: 0,
            auth: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_message_round_trips_with_req_id() {
        let msg = ClientMessage::new(
            ClientKind::Play {
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
            },
            Some(42),
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"play\""));
        assert!(json.contains("\"req_id\":42"));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn client_message_without_req_id_round_trips() {
        let msg = ClientMessage::new(ClientKind::Ping, None);
        let json = serde_json::to_string(&msg).unwrap();
        assert_eq!(json, "{\"type\":\"ping\"}");
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    /// The prototype widget speaks bare tagged messages; the envelope must
    /// accept them (req_id defaults to None).
    #[test]
    fn bare_tagged_message_parses() {
        let back: ClientMessage = serde_json::from_str("{\"type\":\"get_state\"}").unwrap();
        assert_eq!(back.kind, ClientKind::GetState);
        assert_eq!(back.req_id, None);
        // Daemon pushes serialize without req_id, i.e. bare tagged.
        let push = DaemonMessage::new(DaemonKind::Position { position_secs: 1.5 }, None);
        let json = serde_json::to_string(&push).unwrap();
        assert_eq!(json, "{\"type\":\"position\",\"position_secs\":1.5}");
    }

    #[test]
    fn daemon_message_round_trips() {
        let msg = DaemonMessage::new(
            DaemonKind::Browse {
                items: vec![BrowseItem {
                    id: "i1".into(),
                    name: "Album".into(),
                    item_type: "musicalbum".into(),
                    detail: "Artist".into(),
                    duration_secs: None,
                    image_url: None,
                }],
                library_rev: 7,
            },
            Some(3),
        );
        let json = serde_json::to_string(&msg).unwrap();
        let back: DaemonMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn welcome_has_version_shape() {
        let msg = DaemonMessage::new(DaemonKind::Welcome { version: 1, library_rev: 0 }, None);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"welcome\""));
        assert!(json.contains("\"version\":1"));
    }

    #[test]
    fn error_codes_are_snake_case() {
        let msg = DaemonMessage::new(
            DaemonKind::Error {
                code: ErrorCode::NotAuthenticated,
                message: "login required".into(),
            },
            None,
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"code\":\"not_authenticated\""));
        let back: DaemonMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back.kind, msg.kind);
    }

    #[test]
    fn auth_status_is_snake_case() {
        let json = serde_json::to_string(&AuthStatus::NeedsUnlock).unwrap();
        assert_eq!(json, "\"needs_unlock\"");
    }

    #[test]
    fn move_queue_command_round_trips() {
        let msg = ClientMessage::new(ClientKind::MoveQueue { index: 2, delta: -1 }, Some(9));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"move_queue\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    /// The two-tier snapshot: context + head + waiting queue.
    #[test]
    fn two_tier_snapshot_round_trips() {
        let track = |id: &str| TrackMeta {
            id: id.into(),
            name: format!("Song {id}"),
            artist: "Artist".into(),
            album: "Album".into(),
            duration_secs: Some(200.0),
            image_url: None,
            stream_url: String::new(),
        };
        let snap = PlaybackSnapshot {
            context: Some(ContextSnapshot {
                name: "Album".into(),
                artist: "Artist".into(),
                image_url: None,
                tracks: vec![track("t1"), track("t2"), track("t3")],
                current_index: Some(0),
            }),
            current: Some(track("t1")),
            queue_head: Some(track("q0")),
            queue: vec![track("q1"), track("q2")],
            ..Default::default()
        };
        let msg = DaemonMessage::new(DaemonKind::State(Box::new(snap.clone())), None);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"context\""));
        assert!(json.contains("\"queue_head\""));
        let back: DaemonMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back.kind, DaemonKind::State(Box::new(snap)));
    }
}
