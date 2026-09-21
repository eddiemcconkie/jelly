// Row for the album mix editor: checkbox + mix name on the left,
// current album count on the right. The new-mix row becomes an inline
// text prompt so the list geometry never shifts while typing.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
  id: mixRow

  property var modelData: null
  property int index: -1
  property bool isCursor: false
  property string tier: ""
  property string flashText: ""

  width: parent ? parent.width : 0
  implicitHeight: parent ? parent.height : Style.space(42)
  height: implicitHeight

  Timer {
    id: blinkTimer
    interval: 500
    repeat: true
    running: mixRow.modelData && mixRow.modelData.inputMode === true
    onTriggered: cursor.on = !cursor.on
    onRunningChanged: cursor.on = running
  }

  Rectangle {
    anchors.fill: parent
    color: mixRow.isCursor ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
  }

  RowLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(8)

    Text {
      Layout.preferredWidth: Style.space(24)
      textFormat: Text.PlainText
      text: mixRow.modelData ? (mixRow.modelData.checkbox || "") : ""
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.15)
      font.bold: true
      horizontalAlignment: Text.AlignLeft
    }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true

      Text {
        id: labelText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: mixRow.modelData ? (mixRow.modelData.desc || "") : ""
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.body * 1.15)
        font.bold: mixRow.modelData && mixRow.modelData.isNewMix === true
        horizontalAlignment: Text.AlignLeft
        elide: Text.ElideRight
      }

      Rectangle {
        id: cursor
        visible: mixRow.modelData && mixRow.modelData.inputMode === true
        anchors.left: labelText.left
        anchors.leftMargin: labelText.contentWidth + Style.space(1)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(7)
        height: Style.space(18)
        color: Color.accent
        property bool on: true
        opacity: on ? 1 : 0
      }
    }

    Text {
      visible: mixRow.modelData ? (mixRow.modelData.albumCountText || "") !== "" : false
      Layout.preferredWidth: Style.space(92)
      textFormat: Text.PlainText
      text: mixRow.modelData ? (mixRow.modelData.albumCountText || "") : ""
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }
}
