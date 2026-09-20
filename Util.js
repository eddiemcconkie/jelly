// Shared helpers. Pure functions only — no state, no imports.

// Seconds -> "m:ss".
function fmt(s) {
  if (s < 0) s = 0
  var m = Math.floor(s / 60), r = Math.floor(s % 60)
  return m + ":" + (r < 10 ? "0" : "") + r
}

// ---- tier vocabulary. Wire values (jelly_ipc::Tier, snake_case):
// "" / "unrated" | "liked" | "loved" | "favorite". Filled Nerd Font
// FontAwesome glyphs only — never the outline codepoints.

var TIER_ORDER = ["", "liked", "loved", "favorite"]

function tierGlyph(tier) {
  if (tier === "liked") return "\uf164"
  if (tier === "loved") return "\uf004"
  if (tier === "favorite") return "\uf005"
  return ""
}

// Icon opacity by tier: only Liked is quieted; Loved reads full white
// and Favorite full + accent (color carries the top tier, opacity the
// bottom one).
function tierOpacity(tier) {
  if (tier === "liked") return 0.5
  return 1.0
}

// The tier reached by cycling from `tier` (f/F): unrated→liked→...→unrated.
function tierNext(tier) {
  var i = TIER_ORDER.indexOf(tier || "")
  return TIER_ORDER[(i + 1) % TIER_ORDER.length]
}

// ---- shared filter predicates. Lists pass one of these to List; the
// predicate receives (row, lowercased filter text).

function filterByTitle(row, text) {
  return (row.title || "").toLowerCase().includes(text)
}

function filterByTitleOrArtist(row, text) {
  return (row.title || "").toLowerCase().includes(text)
      || (row.sub || "").toLowerCase().includes(text)
}

// Command palette: a single character matches the keybind, more matches
// the description.
function filterByKeyOrDesc(row, text) {
  if (text.length === 1) return (row.key || "").toLowerCase().includes(text)
  return (row.desc || "").toLowerCase().includes(text)
}
