//! rbw helpers. Never logs the password; reads it fresh from the rbw agent.

use anyhow::{Context, Result};
use std::process::Stdio;
use tokio::process::Command;

pub const RBW_ENTRY: &str = "jellyfin.mcconkie.dev";

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
