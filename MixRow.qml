// Delegate for the mix editor's album checklist: cached cover + album
// title + artist, with a 󰄱/󰄲 checkbox reflecting membership in this mix.
// Toggling a row only changes the mix being edited — an album may belong to
// many mixes — so membership lives in the modal, not on the album.
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

  readonly property var md: modelData || ({})

  width: parent ? parent.width : 0
  implicitHeight: Style.space(48)
  height: implicitHeight

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
    spacing: Style.space(10)

    Image {
      Layout.preferredWidth: Style.space(32)
      Layout.preferredHeight: Style.space(32)
      Layout.alignment: Qt.AlignVCenter
      source: mixRow.md.cover || ""
      asynchronous: true
      cache: true
      sourceSize.width: 128
      sourceSize.height: 128
      fillMode: Image.PreserveAspectCrop
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: 0

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: mixRow.md.title || ""
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        visible: (mixRow.md.artist || "") !== ""
        textFormat: Text.PlainText
        text: mixRow.md.artist || ""
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      Layout.preferredWidth: Style.space(24)
      Layout.alignment: Qt.AlignVCenter
      textFormat: Text.PlainText
      text: mixRow.md.checked ? "󰄲" : "󰄱"
      color: mixRow.md.checked ? Color.accent : Qt.darker(Color.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.15)
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
