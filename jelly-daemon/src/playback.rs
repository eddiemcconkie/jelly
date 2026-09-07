//! Playback engine wrapping libmpv on a dedicated OS thread.
//!
//! The thread owns the mpv handle and loops on `wait_event` (see
//! research/libmpv2-playback.md). Commands arrive over a std mpsc channel
//! checked with `try_recv` between event waits; state changes go back to
//! tokio-land over an unbounded channel.

use libmpv2::Mpv;
use jelly_ipc::PlaybackStatus;
use std::sync::mpsc as std_mpsc;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum EngineCommand {
    /// Replace the queue with these URLs and play from `start_index`.
    PlayUrls { urls: Vec<String>, start_index: usize },
    Pause,
    Unpause,
    Toggle,
    Stop,
    Seek(f64),
    SetVolume(u8),
    Next,
    Prev,
}

#[derive(Debug, Clone)]
pub enum EngineEvent {
    Status(PlaybackStatus),
    /// Position in seconds, sampled ~4x/sec while playing.
    Position(f64),
    /// Duration of the current file in seconds.
    Duration(f64),
    /// mpv moved to this internal playlist index (0-based).
    TrackChanged(usize),
    /// A file failed to load (bad URL, missing source, etc).
    LoadFailed,
}

pub struct EngineHandle {
    cmd_tx: std_mpsc::Sender<EngineCommand>,
}

impl EngineHandle {
    pub fn send(&self, cmd: EngineCommand) {
        // Engine must stay alive for the daemon's lifetime; a failed send
        // means the engine thread panicked.
        let _ = self.cmd_tx.send(cmd);
    }
}

const POLL_SECS: f64 = 0.25;
pub fn spawn(event_tx: mpsc::UnboundedSender<EngineEvent>, volume: u8) -> EngineHandle {
    let (cmd_tx, cmd_rx) = std_mpsc::channel::<EngineCommand>();
    std::thread::Builder::new()
        .name("jelly-mpv".into())
        .spawn(move || run_engine(cmd_rx, event_tx, volume))
        .expect("spawn mpv thread");
    EngineHandle { cmd_tx }
}

fn run_engine(
    cmd_rx: std_mpsc::Receiver<EngineCommand>,
    event_tx: mpsc::UnboundedSender<EngineEvent>,
    volume: u8,
) {
    // Options must be set before mpv_initialize, hence with_initializer.
    let mpv = match Mpv::with_initializer(|init| {
        init.set_property("ao", "pipewire")?;
        init.set_property("vid", "no")?;
        init.set_property("gapless-audio", "yes")?;
        init.set_option("volume", volume.to_string().as_str())?;
        Ok(())
    }) {
        Ok(mpv) => mpv,
        Err(e) => {
            tracing::error!("mpv init failed: {e}");
            return;
        }
    };

    let mut status = PlaybackStatus::Stopped;
    let mut queue_len: usize = 0;
    // mpv's internal playlist starts at 0 even when we load from
    // start_index; this offset maps internal positions back to queue
    // indices (single source of truth for "which track is playing").
    let mut offset: usize = 0;

    loop {
        // 1. Drain pending commands.
        while let Ok(cmd) = cmd_rx.try_recv() {
            if let Err(e) = handle_command(&mpv, cmd, &mut status, &mut queue_len, &mut offset, &event_tx) {
                tracing::warn!("engine command failed: {e}");
            }
        }

        // 2. Wait for the next mpv event (bounded so commands are seen).
        match mpv.wait_event(POLL_SECS) {
            Some(Ok(event)) => handle_event(&mpv, event, &mut status, &mut offset, queue_len, &event_tx),
            // Note: EndFile(ERROR) arrives here as an Err, not as an event.
            Some(Err(e)) => {
                tracing::warn!("mpv event error: {e}");
                let _ = event_tx.send(EngineEvent::LoadFailed);
            }
            None => {}
        }

        // 3. Sample position while playing.
        if status == PlaybackStatus::Playing {
            if let Ok(pos) = mpv.get_property::<f64>("time-pos") {
                let _ = event_tx.send(EngineEvent::Position(pos));
            }
        }
    }
}

fn set_status(status: &mut PlaybackStatus, event_tx: &mpsc::UnboundedSender<EngineEvent>, to: PlaybackStatus) {
    if *status != to {
        *status = to;
        let _ = event_tx.send(EngineEvent::Status(to));
    }
}

fn handle_command(
    mpv: &Mpv,
    cmd: EngineCommand,
    status: &mut PlaybackStatus,
    queue_len: &mut usize,
    offset: &mut usize,
    event_tx: &mpsc::UnboundedSender<EngineEvent>,
) -> Result<(), Box<dyn std::error::Error>> {
    match cmd {
        EngineCommand::PlayUrls { urls, start_index } => {
            let Some(first) = urls.get(start_index) else {
                return Ok(());
            };
            mpv.command("stop", &[])?;
            mpv.command("loadfile", &[first, "replace"])?;
            for url in urls.iter().skip(start_index + 1) {
                mpv.command("loadfile", &[url, "append-play"])?;
            }
            *queue_len = urls.len();
            *offset = start_index;
            // stop/loadfile do not clear a previous pause; make sure the
            // new selection actually plays.
            mpv.set_property("pause", false)?;
            let _ = event_tx.send(EngineEvent::TrackChanged(start_index));
            set_status(status, event_tx, PlaybackStatus::Playing);
        }
        EngineCommand::Pause => {
            mpv.set_property("pause", true)?;
            set_status(status, event_tx, PlaybackStatus::Paused);
        }
        EngineCommand::Unpause => {
            mpv.set_property("pause", false)?;
            set_status(status, event_tx, PlaybackStatus::Playing);
        }
        EngineCommand::Toggle => {
            let paused: bool = mpv.get_property("pause")?;
            mpv.set_property("pause", !paused)?;
            set_status(
                status,
                event_tx,
                if paused {
                    PlaybackStatus::Playing
                } else {
                    PlaybackStatus::Paused
                },
            );
        }
        EngineCommand::Stop => {
            mpv.command("stop", &[])?;
            set_status(status, event_tx, PlaybackStatus::Stopped);
        }
        EngineCommand::Seek(pos) => {
            mpv.command("seek", &[&format!("{pos:.3}"), "absolute"])?;
        }
        EngineCommand::SetVolume(volume) => {
            mpv.set_property("volume", i64::from(volume))?;
        }
        EngineCommand::Next => {
            mpv.command("playlist-next", &["force"])?;
        }
        EngineCommand::Prev => {
            mpv.command("playlist-prev", &["force"])?;
        }
    }
    Ok(())
}

fn handle_event(
    mpv: &Mpv,
    event: libmpv2::events::Event<'_>,
    status: &mut PlaybackStatus,
    offset: &mut usize,
    queue_len: usize,
    event_tx: &mpsc::UnboundedSender<EngineEvent>,
) {
    use libmpv2::events::Event;
    match event {
        Event::StartFile => {
            // -1 between tracks / after a stop; clamp before the usize cast.
            let pos: i64 = mpv.get_property("playlist-playing-pos").unwrap_or(0).max(0);
            let idx = (*offset).saturating_add(pos as usize);
            let _ = event_tx.send(EngineEvent::TrackChanged(idx));
            if let Ok(d) = mpv.get_property::<f64>("duration") {
                let _ = event_tx.send(EngineEvent::Duration(d));
            }
            set_status(status, event_tx, PlaybackStatus::Playing);
        }
        Event::FileLoaded => {
            if let Ok(d) = mpv.get_property::<f64>("duration") {
                let _ = event_tx.send(EngineEvent::Duration(d));
            }
        }
        Event::EndFile(reason) => {
            // EOF with nothing left in our view of the queue: stop.
            let pos: i64 = mpv.get_property("playlist-playing-pos").unwrap_or(0).max(0);
            if reason == 0 && // MPV_END_FILE_REASON_EOF (not re-exported by libmpv2)
                (*offset).saturating_add(pos as usize).saturating_add(1) >= queue_len
            {
                set_status(status, event_tx, PlaybackStatus::Stopped);
            }
        }
        _ => {}
    }
}
