// PROTOTYPE — headless service: keeps the jelly daemon alive with the shell.
// While debugging, Eddie shouldn't have to think about the daemon running.
// On shell start (and plugin reload): spawn the daemon unless one is already
// alive; if it dies, bring it back after a short cooldown. Its stdout/stderr
// is piped into the omarchy-shell log (journalctl --user) so one place shows
// both UI and daemon diagnostics.
//
// The liveness check is its own pgrep process whose command line contains
// ONLY the bracketed pattern — the daemon path itself lives in a second
// process, so pgrep can never match its own spawner.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string pluginDir: Quickshell.env("JELLY_PLUGIN_DIR")
    || (Quickshell.env("HOME") + "/.config/omarchy/plugins/eddie.jelly")
  readonly property string bin: pluginDir + "/target/debug/jelly-daemon"

  Process {
    id: daemonProc
    command: [root.bin]

    stdout: SplitParser {
      onRead: line => console.info("jelly-daemon:", line)
    }
    stderr: SplitParser {
      onRead: line => console.warn("jelly-daemon:", line)
    }

    onExited: restartTimer.restart()
  }

  Timer {
    id: restartTimer
    interval: 2000
    onTriggered: daemonProc.running = true
  }

  // Liveness probe: exit code 0 = a daemon is running.
  Process {
    id: checkProc
    command: ["/usr/bin/pgrep", "-f", "target/debug/[j]elly-daemon"]
    onExited: if (exitCode !== 0 && !daemonProc.running) daemonProc.running = true
  }

  Timer {
    id: checkTimer
    interval: 1000
    repeat: true
    running: true
    onTriggered: checkProc.running = true
  }
}
