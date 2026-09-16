// List metadata header (cover + title/artist/counts). Sized
// implicitly around the fixed cover, like every other row.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Util.js" as Util

Item {
  id: meta

  // Named `info`, not `data`: Item already has a `data` default property
  // (children), and shadowing it made the header render nothing.
  property var info: ({})

  width: parent ? parent.width : Style.space(600)
  // The cover establishes the metadata block's stable height.
  implicitHeight: Style.space(128)
  height: Style.space(128)

  RowLayout {
    id: metaRow
    x: Style.space(16)
    y: (meta.height - height) / 2
    width: Math.max(0, meta.width - Style.space(32))
    spacing: Style.space(14)

    Rectangle {
      Layout.preferredWidth: Style.space(104)
      Layout.preferredHeight: Style.space(104)
      Layout.alignment: Qt.AlignVCenter
      visible: (meta.info.cover || "") === ""
      radius: Style.cornerRadius
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
    }

    Image {
      Layout.preferredWidth: Style.space(104)
      Layout.preferredHeight: Style.space(104)
      Layout.alignment: Qt.AlignVCenter
      visible: (meta.info.cover || "") !== ""
      source: meta.info.cover || ""
      asynchronous: true
      cache: true
      sourceSize.width: 320
      sourceSize.height: 320
      fillMode: Image.PreserveAspectCrop
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(4)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: meta.info.title || ""
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: meta.info.artist || ""
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: (meta.info.count || 0) + " tracks"
              + (meta.info.dur ? "  ·  " + Util.fmt(meta.info.dur) : "")
        color: Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
