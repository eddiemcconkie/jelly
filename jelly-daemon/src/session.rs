//! Jellyfin session WebSocket: listens for `UserDataChanged` pushes so
//! tier edits land in the daemon's tier map without re-querying.
//!
//! Reference: Emby-compatible socket — server frames are
//! `{"MessageType": "...", "Data": ...}` where `Data` is a JSON-encoded
//! string on 10.11 (older protocol) and an object on newer builds; both
//! are accepted. `UserDataChanged` carries `UserDataList` entries with
//! `ItemId` + full user data (Rating/IsFavorite), batched ~500ms, and is
//! only sent to sessions of the user whose data changed.

use futures::{SinkExt, StreamExt};
use serde_json::Value;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::MaybeTlsStream;
use tokio_tungstenite::WebSocketStream;

/// Credentials the socket needs; `None` = logged out (socket parked).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub ws_url: String,
    pub user_id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UserDataEntry {
    pub item_id: String,
    pub rating: Option<f64>,
    pub favorite: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SessionEvent {
    UserDataChanged {
        user_id: String,
        entries: Vec<UserDataEntry>,
    },
    KeepAlive,
}

/// Build the websocket URL for a server base + token.
pub fn ws_url(server_url: &str, token: &str) -> String {
    let base = server_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        base.to_string()
    };
    format!("{ws}/websocket?api_key={token}")
}

/// Parse one server frame; `None` for anything we ignore.
pub fn parse_message(raw: &str) -> Option<SessionEvent> {
    let v: Value = serde_json::from_str(raw).ok()?;
    match v.get("MessageType")?.as_str()? {
        "KeepAlive" | "ForceKeepAlive" => Some(SessionEvent::KeepAlive),
        "UserDataChanged" => {
            let data = data_of(&v)?;
            let user_id = data.get("UserId")?.as_str()?.to_string();
            let list = data.get("UserDataList")?.as_array()?;
            let entries = list.iter().filter_map(entry_from).collect();
            Some(SessionEvent::UserDataChanged { user_id, entries })
        }
        _ => None,
    }
}

/// `Data` arrives as an embedded JSON string (10.11) or an object (12.x).
fn data_of(frame: &Value) -> Option<Value> {
    match frame.get("Data")? {
        Value::String(s) => serde_json::from_str(s).ok(),
        Value::Null => None,
        obj => Some(obj.clone()),
    }
}

fn entry_from(v: &Value) -> Option<UserDataEntry> {
    Some(UserDataEntry {
        item_id: v.get("ItemId")?.as_str()?.to_string(),
        rating: v.get("Rating").and_then(|r| r.as_f64()),
        favorite: v
            .get("IsFavorite")
            .and_then(|f| f.as_bool())
            .unwrap_or(false),
    })
}

fn keepalive_frame() -> Message {
    Message::Text(r#"{"MessageType":"KeepAlive","Data":null}"#.into())
}

/// Connect and forward events until the session changes; reconnect with
/// capped backoff. Lives until the process does.
pub fn spawn(
    mut sessions: watch::Receiver<Option<Session>>,
    events: mpsc::UnboundedSender<SessionEvent>,
) {
    tokio::spawn(async move {
        let mut backoff = Duration::from_secs(1);
        loop {
            let Some(session) = sessions.borrow_and_update().clone() else {
                if sessions.changed().await.is_err() {
                    return;
                }
                continue;
            };
            match run_socket(&session, &events, &mut sessions).await {
                Ok(alive_secs) => {
                    // A clean swap or a long-lived drop: start fresh;
                    // flapping reconnects back off up to a minute.
                    backoff = if alive_secs >= 30 {
                        Duration::from_secs(1)
                    } else {
                        (backoff * 2).min(Duration::from_secs(60))
                    };
                }
                Err(e) => {
                    tracing::warn!("session socket: {e:#}");
                    backoff = (backoff * 2).min(Duration::from_secs(60));
                }
            }
            tokio::time::sleep(backoff).await;
        }
    });
}

async fn run_socket(
    current: &Session,
    events: &mpsc::UnboundedSender<SessionEvent>,
    sessions: &mut watch::Receiver<Option<Session>>,
) -> anyhow::Result<u64> {
    let (stream, _resp) = tokio::time::timeout(
        Duration::from_secs(15),
        tokio_tungstenite::connect_async(&current.ws_url),
    )
    .await
    .map_err(|_| anyhow::anyhow!("connect timeout"))?
    .map_err(|e| anyhow::anyhow!("connect failed: {e}"))?;
    let mut stream: WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>> = stream;
    let started = tokio::time::Instant::now();
    // Answer the server's initial ForceKeepAlive promptly.
    stream.send(keepalive_frame()).await.ok();
    loop {
        tokio::select! {
            _ = sessions.changed() => {
                let swap = sessions.borrow_and_update().clone();
                if swap.as_ref() != Some(current) {
                    // Logged out or credentials rotated: reconnect.
                    return Ok(started.elapsed().as_secs());
                }
            }
            msg = stream.next() => {
                match msg {
                    Some(Ok(Message::Text(t))) => {
                        match parse_message(t.as_str()) {
                            Some(SessionEvent::KeepAlive) => { stream.send(keepalive_frame()).await.ok(); }
                            Some(ev) => { events.send(ev).ok(); }
                            None => {}
                        }
                    }
                    Some(Ok(Message::Ping(p))) => { stream.send(Message::Pong(p)).await.ok(); }
                    Some(Ok(_)) => {}
                    Some(Err(e)) => return Err(e.into()),
                    None => return Err(anyhow::anyhow!("socket closed")),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ws_url_swaps_scheme_and_token() {
        assert_eq!(
            ws_url("https://jf.example/", "tok1"),
            "wss://jf.example/websocket?api_key=tok1"
        );
        assert_eq!(
            ws_url("http://localhost:8096", "t"),
            "ws://localhost:8096/websocket?api_key=t"
        );
    }

    const LEGACY_FRAME: &str = r#"{"MessageType":"UserDataChanged","Data":"{\"UserId\":\"u1\",\"UserDataList\":[{\"ItemId\":\"i1\",\"Rating\":8.0,\"IsFavorite\":false,\"Played\":true},{\"ItemId\":\"i2\",\"Rating\":null,\"IsFavorite\":true,\"Played\":false}]}"}"#;

    #[test]
    fn parses_double_encoded_userdata_frame() {
        let ev = parse_message(LEGACY_FRAME).unwrap();
        let SessionEvent::UserDataChanged { user_id, entries } = ev else {
            panic!("wrong event")
        };
        assert_eq!(user_id, "u1");
        assert_eq!(entries.len(), 2);
        assert_eq!(
            entries[0],
            UserDataEntry {
                item_id: "i1".into(),
                rating: Some(8.0),
                favorite: false
            }
        );
        assert_eq!(
            entries[1],
            UserDataEntry {
                item_id: "i2".into(),
                rating: None,
                favorite: true
            }
        );
    }

    #[test]
    fn parses_object_data_frame() {
        let raw = r#"{"MessageType":"UserDataChanged","Data":{"UserId":"u9","UserDataList":[{"ItemId":"i3","Rating":10.0,"IsFavorite":true}]}}"#;
        let ev = parse_message(raw).unwrap();
        match ev {
            SessionEvent::UserDataChanged { user_id, entries } => {
                assert_eq!(user_id, "u9");
                assert_eq!(entries[0].rating, Some(10.0));
            }
            _ => panic!("wrong event"),
        }
    }

    #[test]
    fn keepalive_variants_and_junk() {
        assert_eq!(
            parse_message(r#"{"MessageType":"ForceKeepAlive","Data":"30"}"#),
            Some(SessionEvent::KeepAlive)
        );
        assert_eq!(
            parse_message(r#"{"MessageType":"KeepAlive","Data":null}"#),
            Some(SessionEvent::KeepAlive)
        );
        assert!(parse_message(r#"{"MessageType":"Sessions","Data":"[]"}"#).is_none());
        assert!(parse_message("not json").is_none());
    }

    #[test]
    fn empty_or_missing_lists_parse_clean() {
        let raw =
            r#"{"MessageType":"UserDataChanged","Data":"{\"UserId\":\"u\",\"UserDataList\":[]}"}"#;
        let ev = parse_message(raw).unwrap();
        assert!(matches!(ev, SessionEvent::UserDataChanged { entries, .. } if entries.is_empty()));
        // No Data at all -> ignored, not a crash.
        assert!(parse_message(r#"{"MessageType":"UserDataChanged"}"#).is_none());
    }
}
