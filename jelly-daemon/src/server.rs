//! Unix-socket server: JSON lines in (`ClientMessage`), JSON lines out
//! (`DaemonMessage`). Socket lives at `$XDG_RUNTIME_DIR/jelly.sock`
//! with 0700 perms on its parent dir.

use crate::coordinator::AppCommand;
use futures::{SinkExt, StreamExt};
use jelly_ipc::{ClientMessage, DaemonMessage};
use std::sync::Arc;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, watch};
use tokio_util::codec::{FramedRead, FramedWrite, LinesCodec};

pub struct Server {
    listener: UnixListener,
    pub cmd_tx: mpsc::UnboundedSender<AppCommand>,
    broadcast_tx: broadcast::Sender<DaemonMessage>,
    state_rx: watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: watch::Receiver<jelly_ipc::AuthStatus>,
}

pub async fn bind(
    cmd_tx: mpsc::UnboundedSender<AppCommand>,
    broadcast_tx: broadcast::Sender<DaemonMessage>,
    state_rx: watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: watch::Receiver<jelly_ipc::AuthStatus>,
) -> anyhow::Result<Server> {
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    let dir = format!("{runtime_dir}/jelly");
    tokio::fs::create_dir_all(&dir).await?;
    let path = format!("{dir}/daemon.sock");
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    // User-only socket.
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    tracing::info!("listening on {path}");
    Ok(Server {
        listener,
        cmd_tx,
        broadcast_tx,
        state_rx,
        auth_rx,
    })
}

impl Server {
    pub async fn run(self) {
        let mut conn_id = 0u64;
        loop {
            match self.listener.accept().await {
                Ok((stream, _)) => {
                    conn_id += 1;
                    let cmd_tx = self.cmd_tx.clone();
                    let broadcast_rx = self.broadcast_tx.subscribe();
                    let state_rx = self.state_rx.clone();
                    let auth_rx = self.auth_rx.clone();
                    tokio::spawn(serve_conn(
                        conn_id,
                        stream,
                        cmd_tx,
                        broadcast_rx,
                        state_rx,
                        auth_rx,
                    ));
                }
                Err(e) => {
                    tracing::warn!("accept failed: {e}");
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                }
            }
        }
    }
}

async fn serve_conn(
    id: u64,
    stream: UnixStream,
    cmd_tx: mpsc::UnboundedSender<AppCommand>,
    mut broadcast_rx: broadcast::Receiver<DaemonMessage>,
    state_rx: watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: watch::Receiver<jelly_ipc::AuthStatus>,
) {
    let (reader, writer) = tokio::io::split(stream);
    let mut lines = FramedRead::new(reader, LinesCodec::new());
    let mut sink = FramedWrite::new(writer, LinesCodec::new());
    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel::<DaemonMessage>();

    tracing::debug!(id, "client connected");

    loop {
        tokio::select! {
            line = lines.next() => {
                let Some(line) = line else { break };
                match line {
                    Ok(text) => {
                        match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(msg) => {
                                let replies = handle_client_msg(msg, &cmd_tx, &state_rx, &auth_rx);
                                for r in replies {
                                    let _ = reply_tx.send(r);
                                }
                            }
                            Err(e) => {
                                let _ = reply_tx.send(DaemonMessage::Error {
                                    message: format!("bad message: {e}"),
                                });
                            }
                        }
                    }
                    Err(e) => {
                        tracing::debug!(id, "read error: {e}");
                        break;
                    }
                }
            }
            reply = reply_rx.recv() => {
                if let Some(reply) = reply {
                    if sink.send(serde_json::to_string(&reply).unwrap_or_default()).await.is_err() {
                        break;
                    }
                }
            }
            pushed = broadcast_rx.recv() => {
                match pushed {
                    Ok(msg) => {
                        if sink.send(serde_json::to_string(&msg).unwrap_or_default()).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::debug!(id, "client lagged by {n}");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
    tracing::debug!(id, "client disconnected");
}

/// Direct replies for queries; everything state-changing becomes an
/// `AppCommand` for the coordinator.
fn handle_client_msg(
    msg: ClientMessage,
    cmd_tx: &mpsc::UnboundedSender<AppCommand>,
    state_rx: &watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: &watch::Receiver<jelly_ipc::AuthStatus>,
) -> Vec<DaemonMessage> {
    match msg {
        ClientMessage::Ping => vec![DaemonMessage::Pong],
        ClientMessage::GetAuthStatus => vec![DaemonMessage::AuthStatus {
            status: *auth_rx.borrow(),
        }],
        ClientMessage::GetState => vec![DaemonMessage::State(
            Box::new((**state_rx.borrow()).clone()),
        )],
        ClientMessage::Play { tracks, start_index } => {
            let _ = cmd_tx.send(AppCommand::Play { tracks, start_index });
            vec![]
        }
        ClientMessage::Login => {
            let _ = cmd_tx.send(AppCommand::Login);
            vec![]
        }
        ClientMessage::Pause => { let _ = cmd_tx.send(AppCommand::Pause); vec![] }
        ClientMessage::Resume => { let _ = cmd_tx.send(AppCommand::Resume); vec![] }
        ClientMessage::TogglePlay => { let _ = cmd_tx.send(AppCommand::Toggle); vec![] }
        ClientMessage::Stop => { let _ = cmd_tx.send(AppCommand::Stop); vec![] }
        ClientMessage::Next => { let _ = cmd_tx.send(AppCommand::Next); vec![] }
        ClientMessage::Prev => { let _ = cmd_tx.send(AppCommand::Prev); vec![] }
            ClientMessage::Seek { position_secs } => { let _ = cmd_tx.send(AppCommand::Seek(position_secs)); vec![] }
        ClientMessage::SetVolume { volume } => { let _ = cmd_tx.send(AppCommand::SetVolume(volume)); vec![] }
    }
}
