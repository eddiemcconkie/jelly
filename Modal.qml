import QtQuick
import qs.Commons
import qs.Ui

FocusScope {
  id: root

  property bool open: false
  property real modalWidth: parent ? parent.width - Style.space(96) : Style.space(360)
  property real modalHeight: Style.space(360)
  // When false, the base modal skips its own Escape-close so an instance
  // that handles Escape itself (e.g. the mix editor's two-tier Esc) is the
  // sole authority. Both keys handlers attach to this same object, so
  // without the gate the base handler still fires and closes the modal.
  property bool closeOnEscape: true
  default property alias content: body.data

  signal closeRequested()

  anchors.fill: parent
  visible: open
  focus: open

  Keys.onPressed: function(event) {
    if (closeOnEscape && event.key === Qt.Key_Escape) {
      root.closeRequested()
      event.accepted = true
    }
  }

  onOpenChanged: if (open) Qt.callLater(function() { root.forceActiveFocus() })
  onFocusChanged: if (!focus && visible) forceActiveFocus()

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: root.modalWidth
    height: root.modalHeight
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: Math.max(1, Style.space(1))
    border.color: Color.popups.border

    Column {
      id: body
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(8)
    }
  }
}
