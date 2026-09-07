//! MPRIS2 D-Bus service so the desktop (and omarchy-shell's player widget)
//! can see and control jelly. Read model comes from the shared watch;
//! control goes out through the app command channel.

use crate::coordinator::AppCommand;
use crate::state;
use jelly_ipc::{AuthStatus, PlaybackSnapshot, PlaybackStatus, RepeatMode};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, watch};
use zbus::zvariant::{Dict, ObjectPath, Type, Value};
use zbus::Connection;

pub const PATH: &str = "/org/mpris/MediaPlayer2";
pub const NAME: &str = "org.mpris.MediaPlayer2.jelly";
const PLAYER_IFACE: &str = "org.mpris.MediaPlayer2.Player";
const PROPS_IFACE: &str = "org.freedesktop.DBus.Properties";

type CmdTx = mpsc::UnboundedSender<AppCommand>;

#[derive(Clone)]
pub struct MprisHandle {
    conn: Connection,
}

impl MprisHandle {
    /// Emit PropertiesChanged for the given player-interface props. The
    /// signal lives on org.freedesktop.DBus.Properties — clients match on
    /// that interface, not the player's.
    pub async fn player_props_changed(
        &self,
        changed: HashMap<String, Value<'static>>,
    ) -> zbus::Result<()> {
        if changed.is_empty() {
            return Ok(());
        }
        self.conn
            .emit_signal(
                None::<&str>,
                PATH,
                PROPS_IFACE,
                "PropertiesChanged",
                &(
                    PLAYER_IFACE.to_string(),
                    changed,
                    Vec::<String>::new(),
                ),
            )
            .await
    }
}

pub async fn serve(
    rx: watch::Receiver<Arc<PlaybackSnapshot>>,
    cmd_tx: CmdTx,
) -> anyhow::Result<MprisHandle> {
    let root = Root;
    let player = Player {
        rx,
        cmd_tx: cmd_tx.clone(),
    };
    let conn = zbus::connection::Builder::session()?
        .name(NAME)?
        .serve_at(PATH, root)?
        .serve_at(PATH, player)?
        .build()
        .await?;
    Ok(MprisHandle { conn })
}

/// Diff two snapshots into the MPRIS-relevant changed props.
pub fn changed_props(
    old: &PlaybackSnapshot,
    new: &PlaybackSnapshot,
) -> HashMap<String, Value<'static>> {
    let mut m = HashMap::new();
    if old.status != new.status {
        m.insert(
            "PlaybackStatus".into(),
            Value::from(status_str(new.status).to_string()),
        );
    }
    if old.current_index != new.current_index || old.queue != new.queue {
        m.insert("Metadata".into(), metadata_value(new));
    }
    if old.volume != new.volume {
        m.insert("Volume".into(), Value::from(f64::from(new.volume) / 100.0));
    }
    if old.shuffle != new.shuffle {
        m.insert("Shuffle".into(), Value::from(new.shuffle));
    }
    if old.repeat != new.repeat {
        m.insert(
            "LoopStatus".into(),
            Value::from(loop_str(new.repeat).to_string()),
        );
    }
    // Clients cache capabilities from their first read — which happens
    // before auth, so CanPlay starts false — and only update on
    // PropertiesChanged. Emit it when it flips.
    if can_play(old) != can_play(new) {
        m.insert("CanPlay".into(), Value::from(can_play(new)));
    }
    m
}

/// Mirrors the Player::can_play property.
fn can_play(snap: &PlaybackSnapshot) -> bool {
    !snap.queue.is_empty() || snap.auth == Some(AuthStatus::Authenticated)
}

fn status_str(s: PlaybackStatus) -> &'static str {
    match s {
        PlaybackStatus::Playing => "Playing",
        PlaybackStatus::Paused => "Paused",
        PlaybackStatus::Stopped => "Stopped",
    }
}

fn loop_str(r: RepeatMode) -> &'static str {
    match r {
        RepeatMode::Off => "None",
        RepeatMode::All => "Playlist",
        RepeatMode::One => "Track",
    }
}

fn current<'a>(snap: &'a PlaybackSnapshot) -> Option<&'a jelly_ipc::TrackMeta> {
    snap.current_index.and_then(|i| snap.queue.get(i))
}

/// a{sv} metadata dict for the current track.
fn metadata_map(snap: &PlaybackSnapshot) -> HashMap<String, Value<'static>> {
    let mut map = HashMap::new();
    if let Some(track) = current(snap) {
        let idx = snap.current_index.unwrap_or(0);
        let track_id = ObjectPath::try_from(format!("{PATH}/Track/{idx}"))
            .unwrap_or_else(|_| ObjectPath::from_static_str_unchecked(PATH));
        map.insert("mpris:trackid".to_string(), Value::ObjectPath(track_id));
        map.insert("xesam:title".to_string(), Value::from(track.name.clone()));
        if !track.artist.is_empty() {
            map.insert(
                "xesam:artist".to_string(),
                Value::from(vec![track.artist.clone()]),
            );
        }
        if !track.album.is_empty() {
            map.insert("xesam:album".to_string(), Value::from(track.album.clone()));
        }
        if let Some(url) = &track.image_url {
            map.insert("mpris:artUrl".to_string(), Value::from(url.clone()));
        }
        if let Some(d) = track.duration_secs {
            map.insert("mpris:length".to_string(), Value::I64((d * 1_000_000.0) as i64));
        }
    }
    map
}

fn metadata_value(snap: &PlaybackSnapshot) -> Value<'static> {
    let mut dict = Dict::new(
        <String as Type>::SIGNATURE,
        <Value as Type>::SIGNATURE,
    );
    for (k, v) in metadata_map(snap) {
        // Dict value signature is "v", so inner values must be boxed in a
        // Value::Value (otherwise the object-path/string entries mismatch).
        dict.append(Value::from(k), Value::Value(Box::new(v)))
            .expect("dict append");
    }
    Value::Dict(dict)
}

#[zbus::interface(name = "org.mpris.MediaPlayer2")]
impl Root {
    fn raise(&self) {}
    fn quit(&self) {}
    fn can_quit(&self) -> bool {
        false
    }
    fn can_raise(&self) -> bool {
        false
    }
    fn has_track_list(&self) -> bool {
        false
    }
    fn identity(&self) -> String {
        "Jelly".into()
    }
    fn desktop_entry(&self) -> String {
        "jelly".into()
    }
    fn supported_uri_schemes(&self) -> Vec<String> {
        vec!["http".into(), "https".into()]
    }
    fn supported_mime_types(&self) -> Vec<String> {
        vec![
            "audio/mpeg".into(),
            "audio/flac".into(),
            "audio/ogg".into(),
            "audio/mp4".into(),
        ]
    }
    fn can_set_fullscreen(&self) -> bool {
        false
    }
}

struct Root;

#[zbus::interface(name = "org.mpris.MediaPlayer2.Player")]
impl Player {
    fn next(&self) {
        let _ = self.cmd_tx.send(AppCommand::Next);
    }
    fn previous(&self) {
        let _ = self.cmd_tx.send(AppCommand::Prev);
    }
    fn pause(&self) {
        let _ = self.cmd_tx.send(AppCommand::Pause);
    }
    fn play_pause(&self) {
        let _ = self.cmd_tx.send(AppCommand::Toggle);
    }
    fn play(&self) {
        let _ = self.cmd_tx.send(AppCommand::Resume);
    }
    fn stop(&self) {
        let _ = self.cmd_tx.send(AppCommand::Stop);
    }
    /// Offset in microseconds.
    fn seek(&self, offset: i64) {
        let snap = state::snapshot(&self.rx);
        let pos = snap.position_secs + offset as f64 / 1_000_000.0;
        let _ = self
            .cmd_tx
            .send(AppCommand::Seek(pos.max(0.0)));
    }
    fn set_position(&self, _track_id: ObjectPath<'_>, position: i64) {
        let _ = self.cmd_tx.send(AppCommand::Seek(position as f64 / 1_000_000.0));
    }
    fn open_uri(&self, _uri: String) {}

    #[zbus(property)]
    fn playback_status(&self) -> String {
        status_str(state::snapshot(&self.rx).status).to_string()
    }
    #[zbus(property)]
    fn loop_status(&self) -> String {
        loop_str(state::snapshot(&self.rx).repeat).to_string()
    }
    #[zbus(property)]
    fn set_loop_status(&self, value: String) {
        let mode = match value.as_str() {
            "Playlist" => RepeatMode::All,
            "Track" => RepeatMode::One,
            _ => RepeatMode::Off,
        };
        let _ = self.cmd_tx.send(AppCommand::SetRepeat(mode));
    }
    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn set_rate(&self, _value: f64) {}
    #[zbus(property)]
    fn shuffle(&self) -> bool {
        state::snapshot(&self.rx).shuffle
    }
    #[zbus(property)]
    fn set_shuffle(&self, value: bool) {
        let _ = self.cmd_tx.send(AppCommand::SetShuffle(value));
    }
    #[zbus(property)]
    fn metadata(&self) -> HashMap<String, Value<'static>> {
        metadata_map(&state::snapshot(&self.rx))
    }
    #[zbus(property)]
    fn volume(&self) -> f64 {
        f64::from(state::snapshot(&self.rx).volume) / 100.0
    }
    #[zbus(property)]
    fn set_volume(&self, value: f64) {
        let v = (value * 100.0).round().clamp(0.0, 100.0) as u8;
        let _ = self.cmd_tx.send(AppCommand::SetVolume(v));
    }
    /// Position is polled by clients, never pushed.
    #[zbus(property(emits_changed_signal = "false"))]
    fn position(&self) -> i64 {
        (state::snapshot(&self.rx).position_secs * 1_000_000.0) as i64
    }
    #[zbus(property)]
    fn minimum_rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn maximum_rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn can_go_next(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn can_go_previous(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn can_play(&self) -> bool {
        can_play(&state::snapshot(&self.rx))
    }
    #[zbus(property)]
    fn can_pause(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn can_seek(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn can_control(&self) -> bool {
        true
    }
}

struct Player {
    rx: watch::Receiver<Arc<PlaybackSnapshot>>,
    cmd_tx: CmdTx,
}
