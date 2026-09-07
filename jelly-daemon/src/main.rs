//! jelly-daemon entry point.

use anyhow::Result;
use jelly_daemon::coordinator::{AppCommand, Coordinator};
use jelly_daemon::{jellyfin, mpris, playback, server, state};
use jelly_ipc::DaemonMessage;
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, watch};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let server_url =
        std::env::var("QUICKJELL_SERVER").unwrap_or_else(|_| "https://jellyfin.mcconkie.dev".into());
    tracing::info!("jelly daemon starting; server: {server_url}");

    let (state_tx, state_rx) = state::initial();
    let (auth_tx, auth_rx) = watch::channel(jelly_ipc::AuthStatus::NeedsUnlock);
    let (broadcast_tx, _) = broadcast::channel::<DaemonMessage>(64);
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<AppCommand>();
    let (engine_event_tx, mut engine_event_rx) = mpsc::unbounded_channel();

    let engine = playback::spawn(engine_event_tx, 100);

    // MPRIS shares cmd_tx with socket clients.
    let mpris_handle = mpris::serve(state_rx.clone(), cmd_tx.clone()).await?;

    let mut coordinator = Coordinator {
        client: jellyfin::JellyfinClient::new(&server_url),
        engine,
        state_tx,
        state_rx: state_rx.clone(),
        auth_tx,
        auth_rx: auth_rx.clone(),
        broadcast_tx: broadcast_tx.clone(),
        mpris: mpris_handle,
        server_url: server_url.clone(),
        cmd_tx: cmd_tx.clone(),
    };

    // Try a silent login (never prompts; needs rbw unlocked).
    coordinator.try_autologin().await;

    let srv = server::bind(cmd_tx, broadcast_tx.clone(), state_rx, auth_rx).await?;
    tokio::spawn(srv.run());

    loop {
        tokio::select! {
            Some(cmd) = cmd_rx.recv() => coordinator.handle_cmd(cmd).await,
            Some(ev) = engine_event_rx.recv() => coordinator.handle_engine_event(ev).await,
            else => break,
        }
    }
    Ok(())
}
