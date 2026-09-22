import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Full-widget modal: dims its entire parent and centers a card. The card
// always hugs its content, but never grows past the parent (minus a uniform
// inset) — when it would, a `Layout.fillHeight` child (a list) absorbs the
// overflow and scrolls. Nothing hardcodes a pixel height, so resizing the
// host widget needs no changes here.
FocusScope {
  id: root

  property bool open: false
  // Padding between the card and the dimmed edges; also the amount subtracted
  // from the parent's extents to get the card's maximum size.
  property real inset: Style.space(24)
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
    // Match the host card's corner so the dim stops at the rounded widget
    // edge instead of poking square corners past it (the overlay fills the
    // whole card, including its padding ring).
    radius: Style.cornerRadius
    color: Qt.rgba(0, 0, 0, 0.55)
  }

  Rectangle {
    id: card
    anchors.centerIn: parent
    width: parent.width - root.inset * 2
    // Hug the content, but clamp to the widget. `body.implicitHeight` is the
    // sum of the fixed rows plus the list's implicit (content) height; when
    // that exceeds the available space the min() caps the card and the list's
    // Layout.fillHeight lets it shrink to the room that is left.
    height: Math.min(body.implicitHeight + root.inset * 2,
                     parent.height - root.inset * 2)
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: Math.max(1, Style.space(1))
    border.color: Color.popups.border

    ColumnLayout {
      id: body
      anchors.fill: parent
      anchors.margins: root.inset
      spacing: Style.space(8)
    }
  }
}
