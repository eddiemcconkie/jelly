// One tier glyph: the filled Nerd Font icon for liked/loved/favorite,
// invisible for unrated. Deliberately just a Text — callers position it
// with their layout, and the triptych (JELLY-40) stacks three of these.
import QtQuick
import qs.Commons
import "Util.js" as Util

Text {
  id: tierGlyph
  // "" / "unrated" | "liked" | "loved" | "favorite"
  property string tier: ""
  visible: tierGlyph.tier !== "" && Util.tierGlyph(tierGlyph.tier) !== ""
  opacity: Util.tierOpacity(tierGlyph.tier)
  textFormat: Text.PlainText
  text: Util.tierGlyph(tierGlyph.tier)
  color: Color.foreground
  font.family: Style.font.family
  font.pixelSize: Style.font.body
}
