// Headless service: keeps the jelly daemon alive with the shell.
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

  property var shell: null

  readonly property string pluginDir: Quickshell.env("JELLY_PLUGIN_DIR")
    || (Quickshell.env("HOME") + "/.config/omarchy/plugins/eddie.jelly")
  readonly property string bin: pluginDir + "/target/debug/jelly-daemon"
  readonly property var sharedPanel: panelLoader.item

  function configurePanel(widget, anchor) {
    var panel = sharedPanel
    if (!panel || !widget || !anchor) return null
    if ("bar" in panel) panel.bar = widget.bar
    if ("settings" in panel) panel.settings = widget.settings
    if ("anchorItem" in panel) panel.anchorItem = anchor
    if ("hostWidget" in panel) panel.hostWidget = widget
    return panel && panel.hostWidget ? panel : null
  }

  function openFrom(widget, anchor) {
    var panel = configurePanel(widget, anchor)
    if (panel) panel.open()
  }

  function closeFrom(widget) {
    var panel = sharedPanel
    if (!panel) return
    if (!widget || panel.hostWidget === widget) panel.close()
  }

  function toggleFrom(widget, anchor) {
    var panel = sharedPanel
    if (panel && panel.opened && panel.hostWidget === widget) {
      panel.close()
      return
    }
    openFrom(widget, anchor)
  }

  function panelForScreen(screenName) {
    var panel = sharedPanel
    var widgets = []
    if (shell && shell.bar && typeof shell.bar.moduleWidgets === "function")
      widgets = shell.bar.moduleWidgets("eddie.jelly")
    for (var i = 0; i < widgets.length; i++) {
      var widget = widgets[i]
      var anchor = widget && widget.anchorButton ? widget.anchorButton : null
      var window = anchor && anchor.QsWindow ? anchor.QsWindow.window : null
      if (window && window.screen && window.screen.name === screenName)
        return configurePanel(widget, anchor)
    }
    return panel
  }

  function debugKeyOnScreen(screenName, name) {
    var panel = panelForScreen(screenName)
    if (panel) panel.injectKey(name)
  }

  IpcHandler {
    target: "eddie.jelly"

    function open(): void {
      var panel = root.panelForScreen("eDP-1")
      if (panel) panel.open()
    }
    function close(): void { root.closeFrom(null) }
    function toggle(): void {
      var panel = root.panelForScreen("eDP-1")
      if (!panel) return
      if (panel.opened) panel.close()
      else panel.open()
    }
    function debugKey(name: string): string {
      root.debugKeyOnScreen("eDP-1", name)
      return "ok"
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
  }

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
    onExited: function(exitCode) {
      if (exitCode !== 0 && !daemonProc.running) daemonProc.running = true
    }
  }

  Timer {
    id: checkTimer
    interval: 1000
    repeat: true
    running: true
    onTriggered: checkProc.running = true
  }
}
