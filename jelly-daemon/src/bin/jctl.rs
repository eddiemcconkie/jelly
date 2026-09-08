//! jctl: tiny CLI for poking the jelly daemon socket.
//!
//! Usage: jctl [COMMAND]...   (e.g. `jctl play <track-id>`, `jctl artists`,
//! `jctl enqueue <id>...`, `jctl jump 2`, `jctl repeat all`, `jctl state`)
//! Commands mirror ClientKind; unknown words are sent raw as JSON.

use jelly_ipc::{
    ClientKind, ClientMessage, DaemonMessage, RepeatMode, TrackMeta,
};
use std::io::{BufRead, Write};
use std::os::unix::net::UnixStream;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (kind, req_id) = build_message(&args);
    let msg = ClientMessage::new(kind, req_id);
    let path = std::env::var("JELLY_SOCK")
        .unwrap_or_else(|_| {
            let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
            format!("{runtime}/jelly/daemon.sock")
        });
    let mut stream = UnixStream::connect(&path).expect("connect to daemon socket");

    let line = serde_json::to_string(&msg).unwrap();
    stream.write_all(line.as_bytes()).unwrap();
    stream.write_all(b"\n").unwrap();

    // Stream replies for 2s (push events included).
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .unwrap();
    let reader = std::io::BufReader::new(stream);
    for line in reader.lines() {
        match line {
            Ok(l) if l.is_empty() => break,
            Ok(l) => match serde_json::from_str::<DaemonMessage>(&l) {
                Ok(m) => println!("{}", serde_json::to_string_pretty(&m).unwrap()),
                Err(_) => break,
            },
            Err(_) => break,
        }
    }
}

fn track_placeholder(id: &str) -> TrackMeta {
    TrackMeta {
        id: id.to_string(),
        name: format!("track {id}"),
        artist: String::new(),
        album: String::new(),
        duration_secs: None,
        image_url: None,
        stream_url: String::new(),
    }
}

fn build_message(args: &[String]) -> (ClientKind, Option<u64>) {
    use ClientKind as K;
    let req_id = Some(1);
    match args.first().map(String::as_str) {
        Some("hello") | None => (K::Hello, req_id),
        Some("ping") => (K::Ping, req_id),
        Some("auth") => (K::GetAuthStatus, req_id),
        Some("login") => (K::Login, req_id),
        Some("state") => (K::GetState, req_id),
        Some("play") => (
            K::Play {
                tracks: args.iter().skip(1).map(|id| track_placeholder(id)).collect(),
                start_index: 0,
            },
            req_id,
        ),
        Some("pause") => (K::Pause, req_id),
        Some("resume") => (K::Resume, req_id),
        Some("toggle") => (K::TogglePlay, req_id),
        Some("stop") => (K::Stop, req_id),
        Some("next") => (K::Next, req_id),
        Some("prev") => (K::Prev, req_id),
        Some("seek") => (
            K::Seek {
                position_secs: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0.0),
            },
            req_id,
        ),
        Some("volume") => (
            K::SetVolume {
                volume: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(50),
            },
            req_id,
        ),
        Some("artists") => (K::BrowseArtists, req_id),
        Some("albums") => (
            K::BrowseAlbums {
                artist_id: args.get(1).cloned().unwrap_or_default(),
            },
            req_id,
        ),
        Some("tracks") => (
            K::BrowseTracks {
                album_id: args.get(1).cloned().unwrap_or_default(),
            },
            req_id,
        ),
        Some("playlists") => (K::BrowsePlaylists, req_id),
        Some("pltracks") => (
            K::BrowsePlaylistTracks {
                playlist_id: args.get(1).cloned().unwrap_or_default(),
            },
            req_id,
        ),
        Some("enqueue") => (
            K::Enqueue {
                items: args.iter().skip(1).map(|id| track_placeholder(id)).collect(),
            },
            req_id,
        ),
        Some("nextq") => (
            K::PlayNext {
                item: track_placeholder(args.get(1).map(String::as_str).unwrap_or("")),
            },
            req_id,
        ),
        Some("jump") => (
            K::JumpTo {
                index: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0),
            },
            req_id,
        ),
        Some("rm") => (
            K::RemoveFromQueue {
                index: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0),
            },
            req_id,
        ),
        Some("mv") => (
            K::MoveQueue {
                index: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0),
                delta: args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1),
            },
            req_id,
        ),
        Some("fav") => (
            K::ToggleFavorite {
                item_id: args.get(1).cloned().unwrap_or_default(),
            },
            req_id,
        ),
        Some("repeat") => (
            K::SetRepeat {
                mode: match args.get(1).map(String::as_str) {
                    Some("all") => RepeatMode::All,
                    Some("one") => RepeatMode::One,
                    _ => RepeatMode::Off,
                },
            },
            req_id,
        ),
        Some("shuffle") => (
            K::SetShuffle {
                on: args.get(1).map(String::as_str) == Some("on"),
            },
            req_id,
        ),
        Some(raw) => (
            serde_json::from_str(raw).expect("raw JSON ClientKind"),
            req_id,
        ),
    }
}
