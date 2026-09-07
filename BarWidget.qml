// PROTOTYPE — bar pill for the Jelly interaction-design prototype.
// Long "title — album" strings marquee: clipped at a max width, scroll left
// and back while overflowing; static once it fits.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "eddie.jelly"

  readonly property bool live: panelLoader.item !== null
  readonly property string label: live ? panelLoader.item.pillText : "Jelly"
  readonly property string playGlyph: live ? panelLoader.item.pillGlyph : "󰐊"

  // Marquee geometry: max pill width and the measured text width. Only in
  // horizontal mode; the vertical bar keeps a static label.
  readonly property bool horizontal: !root.vertical
  readonly property real pillMaxWidth: Style.space(280)
  readonly property real pillPadding: Style.spaceReal(8.75) * 2
  readonly property real textWidth: metrics.width
  readonly property bool coverVisible: live && panelLoader.item.nowCover !== ""
  readonly property real coverWidth: coverVisible ? Style.space(20 + 6) : 0
  readonly property real availableWidth: Math.max(0, pillMaxWidth - pillPadding - coverWidth)
  readonly property bool overflowing: horizontal && textWidth > availableWidth
  readonly property real pillWidth: horizontal
    ? (overflowing ? pillMaxWidth : textWidth + pillPadding + coverWidth) : -1

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  TextMetrics {
    id: metrics
    text: root.label
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  // New track → marquee starts over from the beginning.
  onLabelChanged: {
    if (!marqueeText) return
    marqueeText.x = 0
    if (root.overflowing) marqueeAnim.restart()
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "eddie.jelly"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    labelVisible: false
    hasVisualContent: root.label !== ""
    fixedWidth: root.pillWidth
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      root.togglePanel()
    }

    // Cover + clipped scrolling label (replaces the button's own centered
    // label).
    Row {
      visible: root.horizontal
      anchors.centerIn: parent
      spacing: Style.space(10)

      Image {
        visible: root.coverVisible
        source: root.live ? panelLoader.item.nowCover : ""
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        height: Style.space(20)
        asynchronous: true
        cache: true
        sourceSize.width: 40
        sourceSize.height: 40
        fillMode: Image.PreserveAspectCrop
      }

      // Play/pause state, static — only the title—album text marquees.
      Text {
        textFormat: Text.PlainText
        text: root.playGlyph
        anchors.verticalCenter: parent.verticalCenter
        color: button.foreground
        font.family: metrics.font.family
        font.pixelSize: metrics.font.pixelSize
        renderType: Text.NativeRendering
      }

      Item {
      width: Math.min(root.textWidth, root.availableWidth)
      height: metrics.height
      clip: true

      Text {
        id: marqueeText
        textFormat: Text.PlainText
        x: 0
        text: root.label
        color: button.foreground
        font.family: metrics.font.family
        font.pixelSize: metrics.font.pixelSize
        renderType: Text.NativeRendering

        SequentialAnimation on x {
          id: marqueeAnim
          running: root.overflowing
          loops: Animation.Infinite

          // Hold at the start, pan across linearly, hold at the end, then
          // snap back to the start for the next loop.
          PauseAnimation { duration: 1800 }
          NumberAnimation {
            from: 0
            to: -Math.max(0, root.textWidth - root.availableWidth)
            duration: root.overflowing ? Math.max(3000, (root.textWidth - root.availableWidth) * 40) : 0
            easing.type: Easing.Linear
          }
          PauseAnimation { duration: 1800 }
          ScriptAction { script: marqueeText.x = 0 }
        }
      }
      }
    }
  }
}
