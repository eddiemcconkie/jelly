// Shared helpers. Pure functions only — no state, no imports.

// Seconds -> "m:ss".
function fmt(s) {
  if (s < 0) s = 0
  var m = Math.floor(s / 60), r = Math.floor(s % 60)
  return m + ":" + (r < 10 ? "0" : "") + r
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
