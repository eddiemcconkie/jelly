//! jctl: tiny CLI for poking the jelly daemon socket.
//!
//! Usage: jctl [COMMAND]...   (e.g. `jctl play <track-id>`,
//! `jctl artists`, `jctl state`, `jctl toggle`)
//! Commands mirror ClientMessage; unknown words are sent raw as JSON.

use jelly_ipc::{ClientMessage, DaemonMessage, TrackMeta};
use std::io::{BufRead, Write};
use std::os::unix::net::UnixStream;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let msg = build_message(&args);
    let path = std::env::var("QUICKJELL_SOCK")
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

fn build_message(args: &[String]) -> ClientMessage {
    match args.first().map(String::as_str) {
        Some("ping") | None => ClientMessage::Ping,
        Some("auth") => ClientMessage::GetAuthStatus,
        Some("login") => ClientMessage::Login,
        Some("state") => ClientMessage::GetState,
        Some("play") => ClientMessage::Play {
            tracks: args
                .iter()
                .skip(1)
                .map(|id| track_placeholder(id))
                .collect(),
            start_index: 0,
        },
        Some("pause") => ClientMessage::Pause,
        Some("resume") => ClientMessage::Resume,
        Some("toggle") => ClientMessage::TogglePlay,
        Some("stop") => ClientMessage::Stop,
        Some("next") => ClientMessage::Next,
        Some("prev") => ClientMessage::Prev,
        Some("seek") => ClientMessage::Seek {
            position_secs: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0.0),
        },
        Some("volume") => ClientMessage::SetVolume {
            volume: args.get(1).and_then(|s| s.parse().ok()).unwrap_or(50),
        },
        Some(raw) => serde_json::from_str(raw).expect("raw JSON ClientMessage"),
    }
}
