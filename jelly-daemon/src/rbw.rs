//! rbw helpers. Never logs the password; reads it fresh from the rbw
//! agent, with a session-scoped cache so daemon restarts within one
//! session don't re-trigger pinentry.
//!
//! The cache lives in $XDG_RUNTIME_DIR/jelly/credentials.json (tmpfs:
//! wiped at reboot, permissions 0600). The rbw agent remains the source
//! of truth; the cache is a copy that dies with the session.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::process::Stdio;
use tokio::process::Command;

pub const RBW_ENTRY: &str = "jellyfin.mcconkie.dev";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedCredentials {
    pub username: String,
    pub password: String,
}

fn cache_path() -> Option<std::path::PathBuf> {
    let dir = std::env::var("XDG_RUNTIME_DIR").ok()?;
    Some(std::path::Path::new(&dir).join("jelly").join("credentials.json"))
}

/// Read cached credentials, if present and well-formed. Any error means
/// "no cache" — callers fall back to rbw.
pub fn cached_credentials() -> Option<CachedCredentials> {
    let path = cache_path()?;
    let raw = std::fs::read_to_string(&path).ok()?;
    let c: CachedCredentials = serde_json::from_str(&raw).ok()?;
    if c.password.is_empty() || c.username.is_empty() {
        return None;
    }
    Some(c)
}

/// Persist credentials for the rest of the session (0600, tmpfs).
pub fn cache_credentials(c: &CachedCredentials) {
    let Some(path) = cache_path() else { return };
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    if let Ok(json) = serde_json::to_string(c) {
        if let Err(e) = std::fs::write(&path, json) {
            tracing::warn!("credential cache write failed: {e}");
            return;
        }
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
}

/// Drop the cache (e.g. after authentication with it fails).
pub fn clear_cached_credentials() {
    if let Some(path) = cache_path() {
        let _ = std::fs::remove_file(path);
    }
}

/// True iff the rbw agent is unlocked. Never prompts.
pub async fn unlocked() -> bool {
    Command::new("rbw")
        .arg("unlocked")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Spawn `rbw unlock` so the user gets a pinentry prompt. Detached: we
/// don't wait for it; callers poll `unlocked()` and retry login. Needs the
/// session env (WAYLAND_DISPLAY/XDG_RUNTIME_DIR) to be inherited, which it
/// is when the daemon runs under omarchy-shell.
pub async fn spawn_unlock() -> Result<()> {
    Command::new("rbw")
        .arg("unlock")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to spawn rbw unlock")?;
    Ok(())
}

/// Password + username from rbw. If the agent is locked this would trigger
/// pinentry via rbw get; callers should check `unlocked()` first unless
/// they deliberately want to prompt the user.
pub async fn get_credentials() -> Result<(String, String)> {
    let username = Command::new("rbw")
        .args(["get", "--field", "username", RBW_ENTRY])
        .output()
        .await
        .context("rbw get username failed")?;
    let password = Command::new("rbw")
        .args(["get", RBW_ENTRY])
        .output()
        .await
        .context("rbw get password failed")?;
    if !password.status.success() {
        anyhow::bail!("rbw get failed (locked or entry missing)");
    }
    let username = String::from_utf8(username.stdout)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "eddie".to_string());
    let password = String::from_utf8(password.stdout)?.trim().to_string();
    Ok((username, password))
}
