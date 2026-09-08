//! Unix-socket server: JSON lines in (`ClientMessage`), JSON lines out
//! (`DaemonMessage`). Socket lives at `$XDG_RUNTIME_DIR/jelly/daemon.sock`
//! with 0600 perms on the socket, 0700 on its parent dir.

use crate::coordinator::AppCommand;
use futures::{SinkExt, StreamExt};
use jelly_ipc::{ClientKind, ClientMessage, DaemonKind, DaemonMessage, ErrorCode};
use std::sync::Arc;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio_util::codec::{FramedRead, FramedWrite, LinesCodec};

/// A browse request routed to the coordinator (which owns the Jellyfin
/// client); the reply comes back on the oneshot.
pub struct BrowseRequest {
    pub msg: ClientMessage,
    pub reply: oneshot::Sender<DaemonMessage>,
}

pub struct Server {
    listener: UnixListener,
    pub cmd_tx: mpsc::UnboundedSender<AppCommand>,
    pub browse_tx: mpsc::UnboundedSender<BrowseRequest>,
    broadcast_tx: broadcast::Sender<DaemonMessage>,
    state_rx: watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: watch::Receiver<jelly_ipc::AuthStatus>,
}

pub async fn bind(
    cmd_tx: mpsc::UnboundedSender<AppCommand>,
    browse_tx: mpsc::UnboundedSender<BrowseRequest>,
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
        browse_tx,
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
                    let browse_tx = self.browse_tx.clone();
                    let broadcast_rx = self.broadcast_tx.subscribe();
                    let state_rx = self.state_rx.clone();
                    let auth_rx = self.auth_rx.clone();
                    tokio::spawn(serve_conn(
                        conn_id,
                        stream,
                        cmd_tx,
                        browse_tx,
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
    browse_tx: mpsc::UnboundedSender<BrowseRequest>,
    mut broadcast_rx: broadcast::Receiver<DaemonMessage>,
    state_rx: watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: watch::Receiver<jelly_ipc::AuthStatus>,
) {
    let (reader, writer) = tokio::io::split(stream);
    let mut lines = FramedRead::new(reader, LinesCodec::new());
    let mut sink = FramedWrite::new(writer, LinesCodec::new());
    let (reply_tx, mut reply_rx) = mpsc::unbounded_channel::<DaemonMessage>();
    // Reply channel for an in-flight browse request, if any.
    let mut browse_reply: Option<oneshot::Receiver<DaemonMessage>> = None;

    tracing::debug!(id, "client connected");

    loop {
        tokio::select! {
            line = lines.next() => {
                let Some(line) = line else { break };
                match line {
                    Ok(text) => match serde_json::from_str::<ClientMessage>(&text) {
                        Ok(msg) => {
                            // Browse requests are async: route to the
                            // coordinator and pick the reply up below.
                            if is_browse(&msg.kind) {
                                let (tx, rx) = oneshot::channel();
                                let _ = browse_tx.send(BrowseRequest { msg, reply: tx });
                                browse_reply = Some(rx);
                            } else {
                                for r in handle_client_msg(msg, &cmd_tx, &state_rx, &auth_rx) {
                                    let _ = reply_tx.send(r);
                                }
                            }
                        }
                        Err(e) => {
                            let _ = reply_tx.send(DaemonMessage::new(
                                DaemonKind::Error {
                                    code: ErrorCode::BadMessage,
                                    message: format!("bad message: {e}"),
                                },
                                None,
                            ));
                        }
                    },
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
            reply = async {
                match browse_reply.as_mut() {
                    Some(rx) => rx.await.ok(),
                    None => std::future::pending().await,
                }
            } => {
                browse_reply = None;
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

fn is_browse(kind: &ClientKind) -> bool {
    matches!(
        kind,
        ClientKind::BrowseArtists
            | ClientKind::BrowseAlbums { .. }
            | ClientKind::BrowseTracks { .. }
            | ClientKind::BrowsePlaylists
            | ClientKind::BrowsePlaylistTracks { .. }
    )
}

/// Direct replies for queries; everything state-changing becomes an
/// `AppCommand` for the coordinator (plus an `Ack` carrying the req_id).
fn handle_client_msg(
    msg: ClientMessage,
    cmd_tx: &mpsc::UnboundedSender<AppCommand>,
    state_rx: &watch::Receiver<Arc<jelly_ipc::PlaybackSnapshot>>,
    auth_rx: &watch::Receiver<jelly_ipc::AuthStatus>,
) -> Vec<DaemonMessage> {
    let req_id = msg.req_id;
    let out = match msg.kind {
        ClientKind::Hello => vec![DaemonMessage::new(
            DaemonKind::Welcome {
                version: 1,
                library_rev: crate::state::LIBRARY_REV,
            },
            req_id,
        )],
        ClientKind::Ping => vec![DaemonMessage::new(DaemonKind::Pong, req_id)],
        ClientKind::GetAuthStatus => vec![DaemonMessage::new(
            DaemonKind::AuthStatus {
                status: *auth_rx.borrow(),
            },
            req_id,
        )],
        ClientKind::GetState => vec![DaemonMessage::new(
            DaemonKind::State(Box::new((**state_rx.borrow()).clone())),
            req_id,
        )],
        ClientKind::Login => {
            let _ = cmd_tx.send(AppCommand::Login);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Play { tracks, start_index } => {
            let _ = cmd_tx.send(AppCommand::Play { tracks, start_index });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Pause => {
            let _ = cmd_tx.send(AppCommand::Pause);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Resume => {
            let _ = cmd_tx.send(AppCommand::Resume);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::TogglePlay => {
            let _ = cmd_tx.send(AppCommand::Toggle);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Stop => {
            let _ = cmd_tx.send(AppCommand::Stop);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Next => {
            let _ = cmd_tx.send(AppCommand::Next);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Prev => {
            let _ = cmd_tx.send(AppCommand::Prev);
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Seek { position_secs } => {
            let _ = cmd_tx.send(AppCommand::Seek(position_secs));
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::SetVolume { volume } => {
            let _ = cmd_tx.send(AppCommand::SetVolume(volume));
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::Enqueue { items } => {
            let _ = cmd_tx.send(AppCommand::Enqueue { items });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::PlayNext { item } => {
            let _ = cmd_tx.send(AppCommand::PlayNext { item });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::JumpTo { index } => {
            let _ = cmd_tx.send(AppCommand::JumpTo { index, req_id });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::RemoveFromQueue { index } => {
            let _ = cmd_tx.send(AppCommand::RemoveFromQueue { index, req_id });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::MoveQueue { index, delta } => {
            let _ = cmd_tx.send(AppCommand::MoveQueue { index, delta, req_id });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::ToggleFavorite { item_id } => {
            let _ = cmd_tx.send(AppCommand::ToggleFavorite { item_id, req_id });
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::SetRepeat { mode } => {
            let _ = cmd_tx.send(AppCommand::SetRepeat(mode));
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        ClientKind::SetShuffle { on } => {
            let _ = cmd_tx.send(AppCommand::SetShuffle(on));
            vec![DaemonMessage::new(DaemonKind::Ack, req_id)]
        }
        // Browse kinds are handled in serve_conn.
        other => vec![DaemonMessage::new(
            DaemonKind::Error {
                code: ErrorCode::BadMessage,
                message: format!("unexpected: {other:?}"),
            },
            req_id,
        )],
    };
    out
}
