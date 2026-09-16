// Row for the command list: key accented on the left,
// description to its right with generous spacing. No cover, no glyph.
// The owning list pins the row height (List rowHeight); the row fills it.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
  id: cmdRow

  // Filled via List's Bindings (not view-injected: the Loader wrapper
  // passes them down after the row exists).
  property var modelData: null
  property int index: -1
  property bool isCursor: false
  // Unused for command rows; present so the shared Bindings stay silent.
  property bool isFav: false
  property string flashText: ""

  width: parent ? parent.width : 0
  // The wrapper pins the height; the loader mirrors it.
  implicitHeight: parent ? parent.height : Style.space(32)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    color: cmdRow.isCursor ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
  }

  RowLayout {
    id: cmdLayout
    x: Style.space(16)
    y: (cmdRow.height - height) / 2
    width: Math.max(0, cmdRow.width - Style.space(32))
    spacing: Style.space(24)

    Text {
      Layout.preferredWidth: Style.space(96)
      textFormat: Text.PlainText
      text: cmdRow.modelData ? (cmdRow.modelData.key || "") : ""
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: cmdRow.modelData ? (cmdRow.modelData.desc || "") : ""
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
