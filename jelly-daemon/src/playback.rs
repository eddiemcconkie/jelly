//! Playback engine wrapping libmpv on a dedicated OS thread.
//!
//! Two-tier model: mpv plays ONE track at a time — the coordinator decides
//! every transition (queue head, context walk, repeat, wrap) and issues a
//! `PlayUrl` for the next song. The engine just plays, reports position,
//! and says when a track ended (EOF). See model.rs for the decisions.

use libmpv2::Mpv;
use jelly_ipc::PlaybackStatus;
use std::sync::mpsc as std_mpsc;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum EngineCommand {
    /// Play this one URL, replacing whatever is loaded.
    PlayUrl(String),
    Pause,
    Unpause,
    Toggle,
    Stop,
    Seek(f64),
    SetVolume(u8),
    /// loop-file for repeat-one (EOF never fires while it loops).
    SetLoopFile(bool),
}

#[derive(Debug, Clone)]
pub enum EngineEvent {
    Status(PlaybackStatus),
    /// Position in seconds, sampled ~4x/sec while playing.
    Position(f64),
    /// Duration of the current file in seconds.
    Duration(f64),
    /// The current track reached its end (EOF).
    TrackEnded,
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

    loop {
        // 1. Drain pending commands.
        while let Ok(cmd) = cmd_rx.try_recv() {
            if let Err(e) = handle_command(&mpv, cmd, &mut status, &event_tx) {
                tracing::warn!("engine command failed: {e}");
            }
        }

        // 2. Wait for the next mpv event (bounded so commands are seen).
        match mpv.wait_event(POLL_SECS) {
            Some(Ok(event)) => handle_event(&mpv, event, &mut status, &event_tx),
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
    event_tx: &mpsc::UnboundedSender<EngineEvent>,
) -> Result<(), Box<dyn std::error::Error>> {
    match cmd {
        EngineCommand::PlayUrl(url) => {
            // stop/loadfile do not clear a previous pause; make sure the
            // new track actually plays.
            mpv.set_property("pause", false)?;
            mpv.command("loadfile", &[url.as_str(), "replace"])?;
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
        EngineCommand::SetLoopFile(on) => {
            mpv.set_property("loop-file", if on { "inf" } else { "no" })?;
        }
    }
    Ok(())
}

fn handle_event(
    mpv: &Mpv,
    event: libmpv2::events::Event<'_>,
    status: &mut PlaybackStatus,
    event_tx: &mpsc::UnboundedSender<EngineEvent>,
) {
    use libmpv2::events::Event;
    match event {
        Event::FileLoaded => {
            if let Ok(d) = mpv.get_property::<f64>("duration") {
                let _ = event_tx.send(EngineEvent::Duration(d));
            }
            set_status(status, event_tx, PlaybackStatus::Playing);
        }
        Event::EndFile(reason) => {
            // EOF (0, not re-exported by libmpv2): the coordinator picks
            // the next track. Repeat-one loops natively via loop-file, so
            // an EOF here means "really ended" — no repeat handling here.
            if reason == 0 {
                set_status(status, event_tx, PlaybackStatus::Stopped);
                let _ = event_tx.send(EngineEvent::TrackEnded);
            }
        }
        _ => {}
    }
}
