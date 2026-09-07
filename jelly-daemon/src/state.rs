//! Shared state: a `tokio::sync::watch` over the full playback snapshot.
//! Readers (MPRIS, socket replies) borrow the latest snapshot; the
//! coordinator is the only writer.

use jelly_ipc::{AuthStatus, PlaybackSnapshot, TrackMeta};
use std::sync::Arc;
use tokio::sync::watch;

pub type SharedState = Arc<watch::Sender<Arc<PlaybackSnapshot>>>;

/// Monotonic revision of the local library snapshot. 0 until the snapshot
/// layer exists; browse fetches are always fresh so nothing invalidates.
pub const LIBRARY_REV: u64 = 0;

pub fn initial() -> (SharedState, watch::Receiver<Arc<PlaybackSnapshot>>) {
    let (tx, rx) = watch::channel(Arc::new(PlaybackSnapshot {
        auth: Some(AuthStatus::NeedsUnlock),
        ..Default::default()
    }));
    (Arc::new(tx), rx)
}

pub fn snapshot(rx: &watch::Receiver<Arc<PlaybackSnapshot>>) -> Arc<PlaybackSnapshot> {
    rx.borrow().clone()
}

/// Convert Jellyfin items to wire tracks. `stream_for` builds the direct
/// play URL (needs the auth token).
pub fn track_from_item(
    item: &crate::jellyfin::MediaItem,
    stream_for: impl Fn(&str) -> Option<String>,
    image_for: impl Fn(&crate::jellyfin::MediaItem) -> Option<String>,
) -> Option<TrackMeta> {
    let stream_url = stream_for(&item.id)?;
    Some(TrackMeta {
        id: item.id.clone(),
        name: item.name.clone(),
        artist: item
            .artists
            .as_ref()
            .and_then(|a| a.first().cloned())
            .or_else(|| item.album_artist.clone())
            .unwrap_or_default(),
        album: String::new(),
        duration_secs: item.run_time_ticks.map(|t| t as f64 / 10_000_000.0),
        image_url: image_for(item),
        stream_url,
    })
}
