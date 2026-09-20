//! Runtime playback-mode persistence: shuffle, repeat and the tier
//! filter survive daemon restarts (shell reloads) via a small JSON file
//! in `$XDG_RUNTIME_DIR/jelly/modes.json`. Runtime dir = gone on
//! reboot, which is right for session modes.

use jelly_ipc::{RepeatMode, TierFilter};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "snake_case")]
pub struct Modes {
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub filter: TierFilter,
}

fn path() -> Option<PathBuf> {
    let dir = std::env::var("XDG_RUNTIME_DIR").ok()?;
    Some(PathBuf::from(dir).join("jelly").join("modes.json"))
}

/// Load persisted modes; any absence/corruption falls back to defaults
/// (never a startup failure).
pub async fn load() -> Modes {
    let Some(p) = path() else {
        return Modes::default();
    };
    tokio::fs::read_to_string(&p)
        .await
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub async fn save(modes: &Modes) {
    let Some(p) = path() else { return };
    if let Some(dir) = p.parent() {
        let _ = tokio::fs::create_dir_all(dir).await;
    }
    let Ok(json) = serde_json::to_string(modes) else {
        return;
    };
    let _ = tokio::fs::write(&p, json).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_round_trip_and_default_on_garbage() {
        let m = Modes {
            shuffle: true,
            repeat: RepeatMode::One,
            filter: TierFilter::Loved,
        };
        let json = serde_json::to_string(&m).unwrap();
        let back: Modes = serde_json::from_str(&json).unwrap();
        assert_eq!(back, m);
        let back: Modes = serde_json::from_str("{}").unwrap();
        assert_eq!(back, Modes::default());
        assert!(serde_json::from_str::<Modes>("not json").is_err());
    }
}
