// Row delegate for the Mixes tab: mix name + album count on the left,
// and a right-aligned strip of up to five member-album covers (ordered
// by release year desc). Media (the covers) is fixed size; the text
// column absorbs the remaining width.
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
  readonly property var covers: md.covers || []
  readonly property real coverSize: Style.space(32)

  width: parent ? parent.width : 0
  implicitHeight: Style.space(56)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    color: mixRow.isCursor ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
  }

  RowLayout {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(16)
    anchors.rightMargin: Style.space(16)
    spacing: Style.space(10)

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
        visible: (mixRow.md.sub || "") !== ""
        textFormat: Text.PlainText
        text: mixRow.md.sub || ""
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
      spacing: Style.space(3)

      Repeater {
        model: Math.min(mixRow.covers.length, 10)

        Rectangle {
          width: mixRow.coverSize
          height: mixRow.coverSize
          radius: Style.cornerRadius
          color: "transparent"

          Image {
            anchors.fill: parent
            source: mixRow.covers[index]
            asynchronous: true
            cache: true
            sourceSize.width: 80
            sourceSize.height: 80
            fillMode: Image.PreserveAspectCrop
          }
        }
      }
    }
  }
}
