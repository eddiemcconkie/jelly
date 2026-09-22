//! Wire schema shared by the jelly daemon and its quickshell client.
//!
//! Transport is a private Unix socket speaking JSON lines: one
//! `ClientMessage` per line from the client, one `DaemonMessage` per line
//! from the daemon. Keep every type here dependency-light (serde only).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A track's score tier — stored server-side as the per-user
/// `UserData.Rating` (Liked→8, Loved→9, Favorite→10; unrated = no
/// rating). Unrated is behavioral zero: excluded from every tier
/// filter, included in "All".
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Tier {
    Unrated,
    Liked,
    Loved,
    Favorite,
}

impl Tier {
    /// Rating value to persist, or `None` to clear (unrated).
    pub fn rating(self) -> Option<f64> {
        match self {
            Tier::Unrated => None,
            Tier::Liked => Some(8.0),
            Tier::Loved => Some(9.0),
            Tier::Favorite => Some(10.0),
        }
    }

    /// Bucket a stored rating. Bands are generous so foreign values
    /// (e.g. a 5 written elsewhere) still surface instead of vanishing:
    /// favorite ≥9.5, loved ≥8.5, liked ≥6.5 (the server's own
    /// "liked" threshold), below that unrated.
    pub fn from_rating(rating: Option<f64>) -> Tier {
        match rating {
            Some(r) if r >= 9.5 => Tier::Favorite,
            Some(r) if r >= 8.5 => Tier::Loved,
            Some(r) if r >= 6.5 => Tier::Liked,
            _ => Tier::Unrated,
        }
    }

    /// The next tier in the cycle: unrated→liked→loved→favorite→unrated.
    pub fn next(self) -> Tier {
        match self {
            Tier::Unrated => Tier::Liked,
            Tier::Liked => Tier::Loved,
            Tier::Loved => Tier::Favorite,
            Tier::Favorite => Tier::Unrated,
        }
    }
}

/// The global playback filter: a session-wide minimum tier applied at
/// walk time (contexts always hold every track; the filter decides what
/// `next` finds). `All` plays everything.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TierFilter {
    #[default]
    All,
    Liked,
    Loved,
    Favorite,
}

impl TierFilter {
    pub fn min(self) -> Option<Tier> {
        match self {
            TierFilter::All => None,
            TierFilter::Liked => Some(Tier::Liked),
            TierFilter::Loved => Some(Tier::Loved),
            TierFilter::Favorite => Some(Tier::Favorite),
        }
    }

    /// Does a track at `tier` pass this filter? Unrated passes nothing
    /// short of All.
    pub fn passes(self, tier: Tier) -> bool {
        match self.min() {
            None => true,
            Some(min) => tier >= min,
        }
    }

    /// Step the ladder down/up: `up` moves All→Liked→Loved→Favorite;
    /// down reverses that path. Both ends clamp.
    pub fn step(self, up: bool) -> TierFilter {
        use TierFilter::*;
        let order = [All, Liked, Loved, Favorite];
        let i = order.iter().position(|f| *f == self).unwrap_or(0);
        let j = if up {
            (i + 1).min(order.len() - 1)
        } else {
            i.saturating_sub(1)
        };
        order[j]
    }
}

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
    /// playing at `start_index`. The waiting queue survives by default;
    /// the currently-playing queue head is always dropped (starting
    /// something new means moving on from it). `clear_queue: true` (the
    /// queue tab's "play this row now") consumes the waiting queue too.
    Play {
        tracks: Vec<TrackMeta>,
        #[serde(default)]
        start_index: usize,
        #[serde(default)]
        clear_queue: bool,
    },
    /// Play an album without the client needing its track list: the daemon
    /// fetches the album's tracks itself and starts at track 0.
    PlayAlbum {
        album_id: String,
    },
    /// Play every audio item carrying a Jellyfin tag/mix.
    PlayMix {
        tag: String,
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
    Seek {
        position_secs: f64,
    },
    /// Volume 0..=100.
    SetVolume {
        volume: u8,
    },
    /// Full snapshot of playback + context + queue.
    GetState,
    // --- Browse (typed views, lazy fetch; no pagination in v1) ---
    /// One request: every album in the library.
    BrowseAlbums,
    /// Tracks on an album.
    BrowseTracks {
        album_id: String,
    },
    /// The user's playlists.
    BrowsePlaylists,
    /// Items of one playlist.
    BrowsePlaylistTracks {
        playlist_id: String,
    },
    /// Toggle one tag/mix on an album.
    ToggleTag {
        album_id: String,
        tag: String,
        #[serde(default)]
        present: Option<bool>,
    },
    // --- Queue editing (the queue only; the context is immutable) ---
    /// Append tracks to the tail of the queue (starts playing if stopped
    /// and nothing else is queued).
    Enqueue {
        items: Vec<TrackMeta>,
    },
    /// Insert one track at the head of the queue (plays next).
    PlayNext {
        item: TrackMeta,
    },
    /// Jump to a waiting queue item; earlier waiting items are consumed.
    JumpTo {
        index: usize,
    },
    /// Remove the waiting queue item at `index`.
    RemoveFromQueue {
        index: usize,
    },
    /// Move the waiting queue item at `index` by -1 or +1 (clamped).
    MoveQueue {
        index: usize,
        delta: i32,
    },
    SetRepeat {
        mode: RepeatMode,
    },
    /// Toggles a fixed permutation of the context order only.
    SetShuffle {
        on: bool,
    },
    /// DEPRECATED (superseded by `SetTier`/`CycleTier`, JELLY-39): the
    /// favorite flag is now write-side only — Favorite tier hearts the
    /// item for other clients, nothing in our UI renders favorites.
    /// Kept one release for compatibility.
    ToggleFavorite {
        item_id: String,
    },
    /// Set a track's tier (synchronous server write; the command fails
    /// and nothing changes while the server is unreachable). Favorite
    /// also drives the native favorite flag; every other tier clears it.
    SetTier {
        item_id: String,
        tier: Tier,
    },
    /// Cycle the track's tier (unrated→liked→loved→favorite→unrated).
    /// The current tier comes from the daemon's tier map.
    CycleTier {
        item_id: String,
    },
    /// Set the global playback filter directly.
    SetFilter {
        filter: TierFilter,
    },
    /// Step the global filter: up = toward Favorite, down = toward All.
    StepFilter {
        up: bool,
    },
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
    Welcome {
        version: u32,
        library_rev: u64,
    },
    AuthStatus {
        status: AuthStatus,
    },
    /// Full snapshot, sent in reply to `GetState` and on every change.
    State(Box<PlaybackSnapshot>),
    /// Small increment used for high-frequency position updates.
    Position {
        position_secs: f64,
    },
    /// Reply to any `Browse*` request.
    Browse {
        items: Vec<BrowseItem>,
        library_rev: u64,
    },
    /// Confirmation that a state-changing command was accepted.
    Ack,
    /// Successful album tag write; clients update checked state only on
    /// this message, not on the immediate command Ack.
    TagUpdate {
        album_id: String,
        tags: Vec<String>,
    },
    Error {
        code: ErrorCode,
        message: String,
    },
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
    #[serde(default)]
    pub tags: Vec<String>,
    /// Release year (albums); lets the UI order a mix's member-album covers
    /// by year desc without a second round-trip. Absent for tracks.
    #[serde(default)]
    pub year: Option<i32>,
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
    /// Ids of the user's favorited songs (heart icons). Refreshed on
    /// login and after every successful toggle.
    #[serde(default)]
    pub favorite_ids: Vec<String>,
    /// Score tiers by track id — only tiers actually set (unrated is
    /// absence). Seeded on login from user data and patched by the
    /// session's `UserDataChanged` events.
    #[serde(default)]
    pub tiers: BTreeMap<String, Tier>,
    /// The active global playback filter (walk-time minimum tier).
    #[serde(default)]
    pub filter: TierFilter,
    /// All known album tags/mixes, aggregated from the album browse list.
    #[serde(default)]
    pub mixes: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    #[default]
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
            favorite_ids: Vec::new(),
            tiers: BTreeMap::new(),
            filter: TierFilter::default(),
            mixes: Vec::new(),
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
                clear_queue: false,
            },
            Some(42),
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"play\""));
        assert!(json.contains("\"req_id\":42"));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    /// Old clients omit `clear_queue`; it must default to false (the queue
    /// survives a plain Play). The queue-tab takeover sends true.
    #[test]
    fn play_clear_queue_defaults_false_and_parses_true() {
        let back: ClientMessage =
            serde_json::from_str("{\"type\":\"play\",\"tracks\":[],\"start_index\":3}").unwrap();
        assert_eq!(
            back.kind,
            ClientKind::Play {
                tracks: vec![],
                start_index: 3,
                clear_queue: false
            }
        );
        let back: ClientMessage =
            serde_json::from_str("{\"type\":\"play\",\"tracks\":[],\"clear_queue\":true}").unwrap();
        assert_eq!(
            back.kind,
            ClientKind::Play {
                tracks: vec![],
                start_index: 0,
                clear_queue: true
            }
        );
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
                    tags: vec![],
                    year: None,
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
        let msg = DaemonMessage::new(
            DaemonKind::Welcome {
                version: 1,
                library_rev: 0,
            },
            None,
        );
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
        let msg = ClientMessage::new(
            ClientKind::MoveQueue {
                index: 2,
                delta: -1,
            },
            Some(9),
        );
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

    #[test]
    fn toggle_favorite_round_trips() {
        let msg = ClientMessage::new(
            ClientKind::ToggleFavorite {
                item_id: "t1".into(),
            },
            Some(5),
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"toggle_favorite\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn snapshot_carries_favorite_ids() {
        let mut snap = PlaybackSnapshot::default();
        snap.favorite_ids = vec!["a".into(), "b".into()];
        let json = serde_json::to_string(&snap).unwrap();
        assert!(json.contains("\"favorite_ids\""));
        let back: PlaybackSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back.favorite_ids, vec!["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn tier_rating_mapping_is_lossless() {
        for t in [Tier::Liked, Tier::Loved, Tier::Favorite] {
            assert_eq!(Tier::from_rating(t.rating()), t);
        }
        assert_eq!(Tier::Unrated.rating(), None);
        assert_eq!(Tier::from_rating(None), Tier::Unrated);
    }

    #[test]
    fn tier_bands_absorb_foreign_ratings() {
        // Server's "liked" threshold and up reads as tiers; junk below it
        // (e.g. a legacy dislike written as rating 1) stays unrated.
        assert_eq!(Tier::from_rating(Some(0.0)), Tier::Unrated);
        assert_eq!(Tier::from_rating(Some(6.49)), Tier::Unrated);
        assert_eq!(Tier::from_rating(Some(6.5)), Tier::Liked);
        assert_eq!(Tier::from_rating(Some(7.9)), Tier::Liked);
        assert_eq!(Tier::from_rating(Some(8.5)), Tier::Loved);
        assert_eq!(Tier::from_rating(Some(9.4)), Tier::Loved);
        assert_eq!(Tier::from_rating(Some(9.5)), Tier::Favorite);
        assert_eq!(Tier::from_rating(Some(10.0)), Tier::Favorite);
    }

    #[test]
    fn tier_cycles_back_to_unrated() {
        assert_eq!(Tier::Unrated.next(), Tier::Liked);
        assert_eq!(Tier::Liked.next(), Tier::Loved);
        assert_eq!(Tier::Loved.next(), Tier::Favorite);
        assert_eq!(Tier::Favorite.next(), Tier::Unrated);
    }

    #[test]
    fn set_and_cycle_tier_commands_round_trip() {
        let msg = ClientMessage::new(
            ClientKind::SetTier {
                item_id: "t1".into(),
                tier: Tier::Loved,
            },
            Some(7),
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"set_tier\""));
        assert!(json.contains("\"tier\":\"loved\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);

        let msg = ClientMessage::new(
            ClientKind::CycleTier {
                item_id: "t2".into(),
            },
            None,
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"cycle_tier\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn snapshot_tiers_round_trip_and_default() {
        let mut snap = PlaybackSnapshot::default();
        snap.tiers.insert("t1".into(), Tier::Favorite);
        let json = serde_json::to_string(&snap).unwrap();
        let back: PlaybackSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back.tiers.get("t1"), Some(&Tier::Favorite));
        // Older daemons/clients: absent fields default to empty/All.
        let back: PlaybackSnapshot = serde_json::from_str("{\"status\":\"stopped\",\"position_secs\":0,\"volume\":100,\"shuffle\":false,\"repeat\":\"off\"}").unwrap();
        assert!(back.tiers.is_empty());
        assert_eq!(back.filter, TierFilter::All);
        assert!(back.mixes.is_empty());
    }

    #[test]
    fn tier_filter_is_a_minimum_not_an_exact_match() {
        // Loved admits Loved and Favorite; unrated admits nothing short
        // of All.
        assert!(TierFilter::Liked.passes(Tier::Liked));
        assert!(TierFilter::Liked.passes(Tier::Favorite));
        assert!(!TierFilter::Liked.passes(Tier::Unrated));
        assert!(TierFilter::Loved.passes(Tier::Loved));
        assert!(TierFilter::Loved.passes(Tier::Favorite));
        assert!(!TierFilter::Loved.passes(Tier::Liked));
        assert!(TierFilter::Favorite.passes(Tier::Favorite));
        assert!(!TierFilter::Favorite.passes(Tier::Loved));
        for t in [Tier::Unrated, Tier::Liked, Tier::Loved, Tier::Favorite] {
            assert!(TierFilter::All.passes(t));
        }
    }

    #[test]
    fn tier_filter_steppers_clamp_at_both_ends() {
        assert_eq!(TierFilter::All.step(true), TierFilter::Liked);
        assert_eq!(TierFilter::Liked.step(true), TierFilter::Loved);
        assert_eq!(TierFilter::Loved.step(true), TierFilter::Favorite);
        assert_eq!(TierFilter::Favorite.step(true), TierFilter::Favorite);
        assert_eq!(TierFilter::Favorite.step(false), TierFilter::Loved);
        assert_eq!(TierFilter::Liked.step(false), TierFilter::All);
        assert_eq!(TierFilter::All.step(false), TierFilter::All);
    }

    #[test]
    fn filter_commands_round_trip() {
        let msg = ClientMessage::new(
            ClientKind::SetFilter {
                filter: TierFilter::Loved,
            },
            Some(4),
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"set_filter\""));
        assert!(json.contains("\"filter\":\"loved\""));
        assert_eq!(serde_json::from_str::<ClientMessage>(&json).unwrap(), msg);
        let msg = ClientMessage::new(ClientKind::StepFilter { up: false }, None);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"step_filter\""));
        assert_eq!(serde_json::from_str::<ClientMessage>(&json).unwrap(), msg);
    }

    #[test]
    fn mix_commands_and_fields_round_trip() {
        let msg = ClientMessage::new(ClientKind::PlayMix { tag: "Road".into() }, Some(8));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"play_mix\""));
        assert_eq!(serde_json::from_str::<ClientMessage>(&json).unwrap(), msg);

        let msg = ClientMessage::new(
            ClientKind::ToggleTag {
                album_id: "a1".into(),
                tag: "Road".into(),
                present: Some(true),
            },
            Some(9),
        );
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"toggle_tag\""));
        assert_eq!(serde_json::from_str::<ClientMessage>(&json).unwrap(), msg);

        let mut snap = PlaybackSnapshot::default();
        snap.mixes = vec!["Road".into()];
        let json = serde_json::to_string(&snap).unwrap();
        let back: PlaybackSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back.mixes, vec!["Road".to_string()]);
    }
}
