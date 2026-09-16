// The one row delegate shared by every list. The variants (cover or not,
// variants (cover or not, play glyph, heart, indent) are data on the row,
// not separate components.
//
// Layout is implicit: a RowLayout with spacing/padding sizes the row, and
// the row's height derives from it. Only media (the cover) is fixed, so
// changing that size adapts everything around it.
import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Util.js" as Util

Item {
  id: row2

  // Supplied by the owning list (List) via Bindings, not injected by the
  // view: the Loader wrapper passes them down after the row exists.
  property var modelData: null
  property int index: -1
  property bool isCursor: false
  property bool isFav: false
  property string flashText: ""

  readonly property var md: modelData || ({})
  readonly property string cover: md.cover !== undefined && md.cover !== null ? md.cover : ""
  readonly property bool playing: md.playing === true
  // A row only reserves space for what it is meant to show.
  readonly property bool showCover: md.showCover === true
  readonly property bool showGlyph: md.showGlyph === true
  // Favorite heart: only on song rows that opt in (showFav).
  readonly property bool showFav: md.showFav === true && md.trackId !== undefined

  // Fixed media size; everything else adapts to it.
  readonly property real coverSize: Style.space(44)
  readonly property real rowPadding: Style.space(6)
  // ListView geometry must not depend on layout timing. Cover rows use
  // the media gutter height, text-only rows a compact contract, and
  // section/command rows a short caption strip. (One delegate type, one
  // set of numbers.)
  readonly property bool sectionRow: md.sectionRow === true
  readonly property real rowHeight:
    showCover ? Style.space(56) : Style.space(40)

  width: parent ? parent.width : 0
  implicitHeight: rowHeight
  height: rowHeight

  // Section header row: only the bold caption — no cover, glyph, heart
  // or title row underneath. Aligned to the BOTTOM of the row: the text
  // sits next to its section, and the space above separates it from the
  // previous one.
  Text {
    visible: row2.sectionRow
    x: Style.space(16)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    textFormat: Text.PlainText
    text: row2.md.title || ""
    color: Qt.darker(Color.foreground, 1.3)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  Rectangle {
    visible: !row2.sectionRow
    anchors.fill: parent
    color: row2.isCursor ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
  }

  // Favorite heart: filled + accent when favorited (always); the empty
  // outline only appears on the cursor row, to keep the list quiet.
  Text {
    visible: row2.showFav && (row2.isFav || row2.isCursor)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: row2.isFav ? "󰋑" : "󰋕"
    color: row2.isFav ? Color.accent : Qt.darker(Color.foreground, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // Transient action feedback pill ("queued", "play next", …).
  Rectangle {
    visible: row2.flashText !== ""
    anchors.right: parent.right
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    radius: Style.cornerRadius
    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
    width: flashLabel.implicitWidth + Style.space(12)
    height: flashLabel.implicitHeight + Style.space(4)

    Text {
      id: flashLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: row2.flashText
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  RowLayout {
    id: rowLayout
    visible: !row2.sectionRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(16)
    anchors.rightMargin: Style.space(16)
    spacing: Style.space(10)

    // Reserved play-glyph gutter, only for rows that carry playback state.
    Item {
      Layout.preferredWidth: Style.space(16)
      Layout.fillHeight: true
      Layout.alignment: Qt.AlignVCenter
      visible: row2.showGlyph

      Text {
        visible: row2.playing
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "󰐌"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    // Cover slot, only for rows that are meant to have art. Missing art
    // gets a placeholder with a music note.
    Rectangle {
      Layout.preferredWidth: row2.coverSize
      Layout.preferredHeight: row2.coverSize
      Layout.alignment: Qt.AlignVCenter
      visible: row2.showCover && row2.cover === ""
      radius: Style.cornerRadius
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "󰎇"
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Image {
      Layout.preferredWidth: row2.coverSize
      Layout.preferredHeight: row2.coverSize
      Layout.alignment: Qt.AlignVCenter
      visible: row2.showCover && row2.cover !== ""
      source: row2.cover
      asynchronous: true
      cache: true
      sourceSize.width: 88
      sourceSize.height: 88
      fillMode: Image.PreserveAspectCrop
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: 0

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: row2.md.title || ""
        color: row2.playing ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: row2.playing
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        visible: (row2.md.sub || "") !== ""
        textFormat: Text.PlainText
        text: row2.md.sub || ""
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
