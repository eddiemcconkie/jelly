// The reusable list component. Owns the cursor, scrolling,
// filtering, sections and optional reversed layout, so every list surface
// behaves identically instead of re-implementing these rules.
//
// The caller supplies rows, an explicit row delegate, an explicit filter
// predicate and whether the list is filterable. Nothing has a default.
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: list2

  // ---- required inputs (explicit by design)
  required property var rows              // array of row objects
  required property Component rowDelegate
  required property bool filterable
  // (item, text) -> bool. Called for every row while filtering.
  required property var filterFn
  // Uniform row height for the whole list, decided by the caller with the
  // delegate. Section strips may take their own height (queue headers);
  // heights must be known BEFORE layout, never from materialization
  // timing — that invariant keeps every scroll position exact.
  required property real rowHeight
  property real secHeight: rowHeight
  property var rowHeightOf: function(md) {
    if (md && md.headerRow) return headerHeight
    return md && md.sectionRow ? secHeight : rowHeight
  }

  // ---- exact scroll math. ListView's built-in estimator (it sizes
  // un-instantiated rows from the first instantiated delegate) lies as
  // soon as heights vary, so all positioning is computed here from the
  // rows themselves: totals, cumulative offsets, band rules. No
  // positionViewAtIndex/AtEnd and no reading of contentHeight.
  function rowH(i) { return rowHeightOf(items[i]) }

  // Row offsets are pure model sums: row 0 starts at content y=0, every
  // delegate (header pseudo-row included) carries a data-driven height.
  function cumulativeY(pos) {
    var h = 0
    for (var i = 0; i < pos; i++) h += rowHeightOf(items[i])
    return h
  }

  // ---- optional behaviour
  property bool reversed: false
  property string emptyText: "Nothing here"
  // Row identity for cursor preservation across model changes. Rows
  // without a raw keep their index as identity.
  property var rawOf: function(item, index) {
    return item.raw !== undefined ? item.raw : index
  }
  // The caller holds this while the model is being streamed in
  // (bulk library load) so the identity remap cannot drift the cursor.
  property bool suppressRemap: false
  property var labelOf: function(item) { return item.title || "" }

  property int cursorPos: 0
  // Row identity can be a string (track/album ids), so this is untyped.
  property var lastRaw: -1

  readonly property var cursorItem:
    (items.length > 0 && cursorPos < items.length) ? items[cursorPos] : null

  // ---- filtering (navigate mode vs filter mode)
  // Filter UI: the prompt is always visible; `/` makes typed characters
  // append to it ("/ zelda"). No separate input box, no focus juggling.
  property bool filtering: false
  property string filterText: ""

  readonly property var items: {
    if (filterText === "") return composeItems(rows, true)
    var f = filterText.toLowerCase()
    return composeItems(rows.filter(function(it) { return filterFn(it, f) }), false)
  }

  // The content model is: your rows + synthetic rows with data-driven
  // heights. Any leading block (album metadata, queue strip) becomes a
  // pseudo-row, so EVERY delegate has an exact per-row height from here
  // and scroll math is pure arithmetic (row0, header row included).
  function composeItems(src, withSections) {
    var out = []
    // The leading block scrolls away with the content, exactly like any
    // other row; filtering keeps it (it is the view's chrome).
    if (headerComponent && headerHeight > 0) {
      out.push({ raw: "hdr:", headerRow: true, selectable: false, section: "" })
    }
    if (withSections) {
      var last = undefined
      for (var i = 0; i < src.length; i++) {
        var s = src[i] ? (src[i].section || "") : ""
        // A header opens EVERY titled group, including the leading one: on
        // the queue tab the context section must carry its name even when
        // nothing is queued above it (rows without a section never get one).
        if (s !== "" && s !== last) {
          out.push({ raw: "sec:" + s, sectionRow: true, title: s,
                     selectable: false, section: s,
                     showCover: src[i].showCover === true })
          last = s
        }
        out.push(src[i])
      }
    } else {
      for (var j = 0; j < src.length; j++) out.push(src[j])
    }
    return out
  }

  // While focused the placeholder disappears: "/ " plus a blinking cursor.
  readonly property string filterPrompt:
    filtering ? "/ " + filterText
    : ("/ " + (filterText === "" ? "filter" : filterText))
  // muted when idle, accent while focused, foreground once a filter exists
  readonly property color filterColor:
    filtering ? Color.accent
    : (filterText !== "" ? Color.foreground : Qt.darker(Color.foreground, 1.6))

  function selectable(it) { return it && it.selectable !== false }

  function nearestSelectable(pos) {
    if (items.length === 0) return -1
    pos = Math.max(0, Math.min(pos, items.length - 1))
    if (selectable(items[pos])) return pos
    for (var d = 1; d < items.length; d++) {
      if (pos + d < items.length && selectable(items[pos + d])) return pos + d
      if (pos - d >= 0 && selectable(items[pos - d])) return pos - d
    }
    return -1
  }

  function moveCursor(d) {
    if (items.length === 0) return
    var pos = cursorPos
    do { pos = Math.max(0, Math.min(items.length - 1, pos + d)) }
    while (!selectable(items[pos]) && pos > 0 && pos < items.length - 1)
    if (!selectable(items[pos])) return
    setCursor(pos)
  }

  function setCursor(pos) {
    dlog("nav: cursor", cursorPos + "->" + pos, "scrollY", scrollY.toFixed(1),
         "n", items.length)
    cursorPos = pos
    lastRaw = items[pos] ? rawOf(items[pos], pos) : -1
    requestScroll(pos)
  }

  function jumpCursor(pos) {
    var ns = nearestSelectable(pos)
    if (ns >= 0) setCursor(ns)
  }

  // Entering a view starts at the top.
  function resetCursor() {
    cursorPos = 0
    lastRaw = -1
    scrollTo(0)
  }

  function beginViewReset() {
    resettingView = true
    lastRaw = -1
    cursorPos = 0
  }

  function focusRaw(raw, fallback) {
    for (var i = 0; i < items.length; i++) {
      if (rawOf(items[i], i) === raw) { setCursor(i); return }
    }
    jumpCursor(fallback || 0)
  }

  // The view identity of the last items push. When it changes (tab
  // switch, drill in/out), scroll state from the previous view must not
  // leak into the new one — under the center rule a stale heldY reads as
  // a mid-list window that "doesn't line up" with the cursor.
  property string lastView: ""

  onItemsChanged: {
    var viewChanged = debugName !== lastView
    lastView = debugName
    dlog("model-reset: before", debugName, "items", items.length,
         "scrollY", scrollY.toFixed(1),
         "resetting", resettingView, "pendingJump", pendingJumpPrefix,
         "viewChanged", viewChanged,
         "total", contentTotal().toFixed(1), "h", list.height.toFixed(1))
    // During bulk library load the caller streams album batches in and
    // each one reorders the (title-sorted) list as it lands; identity
    // remapping during that churn drifts the cursor (observed: 0 -> 1 on
    // every open). While suppressing, the cursor stays put instead.
    if (items.length === 0) {
      cursorPos = 0
      lastRaw = -1
      return
    }
    // A new view starts at its top, cursor 0 — before any remap can
    // apply the previous view's cursor/offset to the new rows.
    if (viewChanged && pendingJumpPrefix === "") {
      resettingView = false
      lastRaw = -1
      scrollTo(0)
      return
    }
    if (!suppressRemap && lastRaw !== -1) {
      var best = -1, bestDist = Infinity
      for (var i = 0; i < items.length; i++) {
        if (rawOf(items[i], i) !== lastRaw) continue
        var dist = Math.abs(i - cursorPos)
        if (dist < bestDist) { bestDist = dist; best = i; if (dist === 0) break }
      }
      if (best >= 0) {
        dlog("remap-id:", "raw", String(lastRaw), "cursor", cursorPos + "->" + best,
             "n", items.length)
        cursorPos = best
      } else {
        dlog("remap-clamp:", "raw", String(lastRaw), "cursor", cursorPos + "->" +
             Math.max(0, Math.min(cursorPos, items.length - 1)),
             "n", items.length)
        cursorPos = Math.max(0, Math.min(cursorPos, items.length - 1))
      }
    }
    if (!selectable(items[cursorPos])) {
      var ns = nearestSelectable(cursorPos)
      cursorPos = ns >= 0 ? ns : 0
    }
    lastRaw = items[cursorPos] ? rawOf(items[cursorPos], cursorPos) : -1
    // A queued section jump (e.g. shuffle flips the context order): move
    // the cursor to the first row whose identity has the prefix. This
    // wins over the remap, so the caller need not track ids itself.
    var modelJumped = false
    if (pendingJumpPrefix !== "") {
      var pref = pendingJumpPrefix
      pendingJumpPrefix = ""
      modelJumped = true
      for (var p = 0; p < items.length; p++) {
        var rj = rawOf(items[p], p)
        if (typeof rj === "string" && rj.indexOf(pref) === 0) { jumpCursor(p); break }
      }
    }
    if (resettingView) scrollTo(0)
    else if (!modelJumped) restoreHeldY()
    resettingView = false
    dlog("model-reset: after", "scrollY", scrollY.toFixed(1), "modelJump", modelJumped,
         "cursor", cursorPos, "total", contentTotal().toFixed(1))
  }

  // Caller queues a prefix: on the next model change the cursor jumps to
  // the first row whose identity starts with it ("" = no-op).
  property string pendingJumpPrefix: ""

  function scrollOffset() { return scrollY }

  signal requestScroll(int pos)
  signal activated(var item)
  signal actionTriggered(string action, var item)

  function activate() {
    if (!cursorItem) return
    dlog("activate: cursor", cursorPos, "raw", String(lastRaw),
         "scrollY", scrollY.toFixed(1))
    activated(cursorItem)
  }

  function startFilter() {
    if (!filterable) return
    filtering = true
  }

  // Committing keeps the text and starts at the first match.
  function commitFilter() {
    filtering = false
    cursorPos = 0
    lastRaw = -1
    Qt.callLater(function() {
      if (items[cursorPos]) lastRaw = rawOf(items[cursorPos], cursorPos)
      requestScroll(cursorPos)
    })
  }

  function clearFilter() {
    var had = filterText !== ""
    filtering = false
    filterText = ""
    if (had) focusRaw(lastRaw, 0)
  }

  // Cursor follows the item it is on when the list reorders around it.
  function moveWithItem(delta) {
    var it = cursorItem
    if (!it) return
    var raw = rawOf(it, cursorPos)
    cursorPos = Math.max(0, Math.min(items.length - 1, cursorPos + delta))
    lastRaw = raw
    requestScroll(cursorPos)
  }

  // ---- scrolling. One owner: the offset is a plain property, content
  // y = -scrollY, and every write clamps inside [0, contentTotal - vp].
  // (No ListView: its internal contentY re-clamps while rederiving
  // geometry were the source of every scroll glitch in the journal.)
  property real scrollY: 0
  property bool resettingView: false
  property string debugName: ""
  property bool debug: true

  function dlog() {
    if (!debug) return
    var args = Array.prototype.slice.call(arguments)
    console.log("list2:", args.join(" | "))
  }

  // The leading block (album metadata, queue strip) declares its height
  // so it takes part in the pure model arithmetic.
  property real headerHeight: 0

  // Every write of the offset passes through here and cannot leave the
  // content bounds. One owner, one clamp, at write time.
  function setScroll(cause, value) {
    var maxY = Math.max(0, contentTotal() - list.height)
    var y = Math.max(0, Math.min(value, maxY))
    dlog("y-set:", cause, scrollY.toFixed(1) + "->", y.toFixed(1))
    scrollY = y
  }

  function scrollToOffset(y) {
    setScroll("scrollToOffset", y)
  }

  function firstSelectableIndex() {
    for (var i = 0; i < items.length; i++)
      if (selectable(items[i])) return i
    return items.length
  }

  // Total content height (header pseudo-row + all rows) from the model.
  function contentTotal() { return cumulativeY(items.length) }

  function scrollTo(pos) {
    if (pos < 0 || items.length === 0) return
    var vp = list.height
    var total = contentTotal()
    // A list that fits the viewport has only one position: the top.
    if (total <= vp) {
      setScroll("scrollTo fit (cursor " + pos + ")", 0)
      return
    }
    // Reaching the very top — by g, by filter commit, or by walking j up
    // to the first selectable row — snaps to the content top so the
    // metadata header (and any lead-in block) is visible again.
    if (pos === 0 || pos <= firstSelectableIndex()) {
      setScroll("scrollTo head (cursor " + pos + ")", 0)
      return
    }
    // Center rule: keep the cursor row vertically centered in the
    // viewport unless the content edge stops us — natural edge behavior
    // emerges from the clamp inside setScroll alone.
    var target = cumulativeY(pos) + rowH(pos) / 2 - vp / 2
    setScroll("scrollTo cursor " + pos, target)
  }

  // Restore is a re-derive now: the cursor is the single scroll truth.
  function restoreHeldY() {
    if (items.length === 0) return
    scrollTo(cursorPos)
  }

  // Returns true when the event was consumed; unhandled keys stay
  // unaccepted so they can forward to the panel's own handler.
  function handleKey(event) {
    var t = event.text
    // Filter mode: type into the prompt, Enter commits, Esc clears/leaves.
    if (filtering) {
      if (event.key === Qt.Key_Escape) {
        if (filterText !== "") filterText = ""
        else filtering = false
        return true
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { commitFilter(); return true }
      if (event.key === Qt.Key_Backspace) { filterText = filterText.slice(0, -1); return true }
      if (t && t.length === 1 && event.key !== Qt.Key_Space) { filterText += t; return true }
      if (event.key === Qt.Key_Space) { filterText += " "; return true }
      return true
    }
    if (event.key === Qt.Key_Escape || t === "h") {
      if (filterText !== "") { clearFilter(); return true }
      if (backHook()) return true
      return false
    }
    if (t === "l") { return drillHook() }
    if (event.key === Qt.Key_Down || t === "j") { moveCursor(1); return true }
    if (event.key === Qt.Key_Up || t === "k") { moveCursor(-1); return true }
    if (t === "g") { jumpCursor(0); return true }
    if (t === "G") { jumpCursor(items.length - 1); return true }
    if (t === "o") { focusPlayingHook(); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { activate(); return true }
    if (t === "/") { if (!filterable) return false; startFilter(); return true }
    return false
  }

  // Caller hook: return true when the list navigated back a level.
  property var backHook: function() { return false }
  property var drillHook: function() { return false }

  // Transient action feedback: { raw, text }, shown on the matching row.
  property var flash: null

  // Optional metadata block rendered above the rows (album/playlist header).
  property Component headerComponent: null

  // Favorite-id lookup ({ id: true }); rows opt in via showFav.
  property var favSet: ({})



  // Optional hook: callers that know the playing row set this to focus it.
  property var focusPlayingHook: function() {}



  // ---- filter prompt (always visible; `/` starts typing over it)
  Text {
    id: filterPrompt
    visible: list2.filterable
    x: Style.space(16)
    y: Style.space(4)
    height: Style.space(26)
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    text: list2.filterPrompt
    color: list2.filterColor
    font.family: Style.font.family
    font.pixelSize: Style.font.body

    // Block cursor while filter mode is active: hard blink, no fade.
    Rectangle {
      id: filterCursor
      visible: list2.filtering
      x: parent.contentWidth + Style.space(1)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: Style.space(15)
      color: Color.accent
      property bool on: true
      opacity: on ? 1 : 0
      Timer {
        interval: 500
        running: list2.filtering
        repeat: true
        onTriggered: filterCursor.on = !filterCursor.on
      }
    }
  }

  // ---- the scroller. A plain Item: we OWN the offset directly instead
  // of delegating it to a ListView, whose own repricing (originY/contentY
  // re-clamps during delegate (re)instantiation) kept fighting every
  // scheme in this file — the source of ever scroll glitch in the
  // journal. Every row (leading block included) is an exact-height
  // pseudo-row, so the position is pure arithmetic and the visible
  // window CANNOT leave the content bounds.
  Item {
    id: list
    anchors.top: parent.top
    anchors.topMargin: list2.filterable ? Style.space(34) : 0
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    width: parent.width - Style.space(18)
    clip: true

    // A Repeater (unlike a ListView) keeps every delegate ALIVE: layout
    // can never half-materialize, so offsets depend only on our
    // arithmetic.
    Column {
      id: contentCol
      width: list.width
      // The offset is ours; nothing internal ever writes it (no wheel,
      // no flick physics): every move is from the cursor scrollers and
      // reset paths below or an explicit scrollToOffset.
      y: -list2.scrollY

      Repeater {
        model: list2.items
        // The delegate wrapper's height is the data-driven per-row
        // height (rowHeightOf).
        delegate: Item {
          id: rowWrap
          objectName: "row" + index
          required property var modelData
          required property int index
          width: list.width
          implicitHeight: list2.rowHeightOf(modelData)
          height: implicitHeight

          Loader {
            id: rowLoader
            anchors.fill: parent
            // The leading block (album metadata, queue strip) is a
            // pseudo-row: dispatch its component instead of the row
            // template.
            sourceComponent: rowWrap.modelData.headerRow === true
              ? list2.headerComponent : list2.rowDelegate
            property var modelData: rowWrap.modelData
            property int index: rowWrap.index
          }

          // Declarative bindings: the row's inputs update with the
          // model, the cursor and the transient flash — nothing is
          // assigned imperatively.
          Binding {
            target: rowLoader.item
            property: "modelData"
            value: rowWrap.modelData
            when: rowLoader.item !== null
          }
          Binding {
            target: rowLoader.item
            property: "index"
            value: rowWrap.index
            when: rowLoader.item !== null
          }
          Binding {
            target: rowLoader.item
            property: "isCursor"
            value: rowWrap.index === list2.cursorPos && !list2.filtering
            when: rowLoader.item !== null
          }
          Binding {
            target: rowLoader.item
            property: "isFav"
            value: list2.favSet[rowWrap.modelData ? rowWrap.modelData.trackId : ""] === true
            when: rowLoader.item !== null
          }
          Binding {
            target: rowLoader.item
            property: "flashText"
            value: (list2.flash !== null
                    && list2.flash.raw === list2.rawOf(rowWrap.modelData, rowWrap.index)) ? list2.flash.text : ""
            when: rowLoader.item !== null
          }
        }
      }
    }

    // Cursor-driven scroll requests land here.
    Connections {
      target: list2
      function onRequestScroll(pos) { list2.scrollTo(pos) }
    }
  }

  // Reversed lists read bottom-up, so the current section is the one at
  // the bottom edge; this overlay keeps it visible there.
  Rectangle {
    visible: list2.reversed && list2.items.length > 0
    anchors.left: list.left
    anchors.right: list.right
    anchors.bottom: list.bottom
    height: reversedSectionText.implicitHeight + Style.space(10)
    color: Color.popups.background

    Text {
      id: reversedSectionText
      x: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      // Pure-math replacement of the old list.indexAt: the first row
      // whose top is at the viewport bottom edge.
      readonly property int edgeIndex: {
        var y = list2.scrollY + list.height - 2
        for (var i = list2.items.length - 1; i >= 0; i--) {
          if (list2.cumulativeY(i) <= y) return i
        }
        return -1
      }
      text: edgeIndex >= 0 && list2.items[edgeIndex] !== undefined
        ? (list2.items[edgeIndex].section || "") : ""
      color: Qt.darker(Color.foreground, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // Scroll progress (read-only): derived from the content's real extents.
  Rectangle {
    visible: list2.contentTotal() > list.height + 1
    x: parent.width - width
    y: 0
    width: Style.space(4)
    height: parent.height
    radius: width / 2
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)

    Rectangle {
      width: parent.width
      radius: width / 2
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
      readonly property real progress: {
        var range = list2.contentTotal() - list.height
        if (range <= 0) return 0
        return Math.max(0, Math.min(1, list2.scrollY / range))
      }
      readonly property real frac: Math.min(1, list.height / Math.max(1, list2.contentTotal()))
      height: Math.max(Style.space(24), parent.height * frac)
      y: progress * (parent.height - height)
    }
  }

  Text {
    visible: list2.items.length === 0
    anchors.centerIn: list
    textFormat: Text.PlainText
    text: list2.filterText !== ""
      ? "No matches for \u201C" + list2.filterText + "\u201D — esc to clear"
      : list2.emptyText
    color: Qt.darker(Color.foreground, 1.7)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
