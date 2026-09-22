// The reusable list component. Owns the cursor, scrolling and filtering,
// so every list surface behaves identically instead of re-implementing
// these rules.
//
// A ListView fed by a Quickshell ScriptModel: the rows stay plain JS
// objects, but the model diffs them by `raw` identity, so a daemon push
// updates changed rows in place instead of resetting the model. That is
// the property every scroll/cursor guarantee rests on: ListView's window
// (and its contentY) survives pushes, and only cursor moves ever scroll.
//
// The caller supplies rows, an explicit row delegate, an explicit filter
// predicate and whether the list is filterable. Nothing has a default.
import QtQuick
import Quickshell
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
  // timing — that invariant keeps ListView's geometry honest.
  required property real rowHeight
  property real secHeight: rowHeight
  property var rowHeightOf: function(md) {
    if (md && md.headerRow) return headerHeight
    return md && md.sectionRow ? secHeight : rowHeight
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

  // Full scroll height of the rows. Note: NOT ListView.contentHeight (that
  // depends on cacheBuffer -> list.height -> whatever sizes the list, so a
  // card reading it for its own height forms a binding loop). This is a pure
  // data count; multiply by rowHeight to get a loop-free implicit height.
  readonly property int rowCount: items.length

  // ---- filtering (navigate mode vs filter mode)
  // Filter UI: the prompt is always visible; `/` makes typed characters
  // append to it ("/ zelda"). Live results update as you type; Enter
  // commits, Esc reverts to the pre-filter text and exits.
  property bool filtering: false
  property string filterText: ""
  // The committed filter as it stood when filter mode was entered;
  // Esc reverts to it (the original cancel semantics).
  property string preFilterText: ""

  readonly property var items: {
    if (filterText === "") return composeItems(rows, true)
    var f = filterText.toLowerCase()
    return composeItems(rows.filter(function(it) { return filterFn(it, f) }), false)
  }

  // The content model is: your rows + synthetic rows with data-driven
  // heights. Any leading block (album metadata, queue strip) becomes a
  // pseudo-row, so every delegate has an exact per-row height from the
  // model itself and no scroll position depends on layout timing.
  //
  // ScriptModel requires unique values: duplicate raws (e.g. a playlist
  // that holds the same track twice) get a shallow-copied "#n" suffix.
  function composeItems(src, withSections) {
    var out = []
    var seen = ({})
    function uniq(r, i) {
      var k = String(r)
      if (seen[k] === undefined) { seen[k] = true; return r }
      return k + "#" + i
    }
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
          out.push({ raw: uniq("sec:" + s, i), sectionRow: true, title: s,
                     selectable: false, section: s,
                     showCover: src[i].showCover === true })
          last = s
        }
        var it = src[i]
        var r = uniq(it.raw !== undefined ? it.raw : i, i)
        if (r !== it.raw) {
          var c = {}
          for (var k in it) c[k] = it[k]
          c.raw = r
          it = c
        }
        out.push(it)
      }
    } else {
      for (var j = 0; j < src.length; j++) {
        var it2 = src[j]
        var r2 = uniq(it2.raw !== undefined ? it2.raw : j, j)
        if (r2 !== it2.raw) {
          var c2 = {}
          for (var k2 in it2) c2[k2] = it2[k2]
          c2.raw = r2
          it2 = c2
        }
        out.push(it2)
      }
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
    dlog("nav: cursor", cursorPos + "->" + pos, "contentY", list.contentY.toFixed(1),
         "n", items.length)
    cursorPos = pos
    lastRaw = items[pos] ? rawOf(items[pos], pos) : -1
    requestScroll(pos)
  }

  function jumpCursor(pos) {
    var ns = nearestSelectable(pos)
    if (ns >= 0) setCursor(ns)
  }

  // Entering a view starts at the top: cursor on the first SELECTABLE
  // row (row 0 may be a header/section pseudo-row, which renders no
  // cursor), viewport pinned to the content top by the head rule.
  function resetCursor() {
    cursorPos = 0
    lastRaw = -1
    jumpCursor(0)
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

  // Move the cursor to the first selectable row whose data matches the
  // predicate; no-op when nothing matches. Callers must not scan their
  // own row arrays: those indices predate the pseudo-rows (header and
  // section strips) composeItems inserts, so they miss by one.
  function focusRowWhere(pred) {
    for (var i = 0; i < items.length; i++) {
      if (selectable(items[i]) && pred(items[i])) {
        dlog("focus-row:", "index", i, "raw", String(rawOf(items[i], i)))
        setCursor(i)
        return true
      }
    }
    return false
  }

  // The view identity of the last items push. When it changes (tab
  // switch, drill in/out), the cursor from the previous view must not
  // leak into the new one: a new view starts at its top.
  property string lastView: ""

  onItemsChanged: {
    var viewChanged = debugName !== lastView
    lastView = debugName
    dlog("model-change: before", debugName, "items", items.length,
         "contentY", list.contentY.toFixed(1),
         "resetting", resettingView, "pendingJump", pendingJumpPrefix,
         "viewChanged", viewChanged,
         "count", list.count, "cH", list.contentHeight.toFixed(1))
    // During bulk library load the caller streams rows in and each batch
    // reorders the (title-sorted) list as it lands; identity remapping
    // during that churn drifts the cursor. While suppressing, the cursor
    // stays put instead.
    if (items.length === 0) {
      cursorPos = 0
      lastRaw = -1
      // Nothing here: we ARE at the top. Don't let a queued top-jump
      // survive to ambush the next unrelated model change.
      pendingTopJump = false
      return
    }
    // A new view starts at its top — cursor on the first SELECTABLE row
    // (jumpCursor(0) skips any header/section pseudo-rows above it) —
    // before any remap can apply the previous view's cursor to the new
    // rows. Parking on row 0 would hide the cursor there: pseudo-rows
    // render no cursor, which looked like "no cursor until you hit j".
    if ((viewChanged && pendingJumpPrefix === "") || pendingTopJump) {
      resettingView = false
      pendingTopJump = false
      lastRaw = -1
      cursorPos = 0
      jumpCursor(0)
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
    // A model change NEVER scrolls by itself (unless the jump above moved
    // the cursor, which scrolls through setCursor). ScriptModel diffs in
    // place, so the viewport stays exactly where the user left it.
    if (resettingView) scrollTo(0)
    resettingView = false
    dlog("model-change: after", "contentY", list.contentY.toFixed(1),
         "modelJump", modelJumped, "cursor", cursorPos)
  }

  // Caller queues a prefix: on the next model change the cursor jumps to
  // the first row whose identity starts with it ("" = no-op).
  property string pendingJumpPrefix: ""

  // Caller demands a plain top-of-view jump on the next model change
  // (queue-tab jump_to: rows above the cursor get consumed, the cursor
  // must rejoin the top, not keep its index). A flag rather than a
  // prefix: prefix searches can miss (queue exhausted) or be consumed
  // by an unrelated model change, leaving the index-preservation clamp
  // as the fallback.
  property bool pendingTopJump: false

  function scrollOffset() { return list.contentY }

  signal requestScroll(int pos)
  signal activated(var item)

  function activate() {
    if (!cursorItem) return
    dlog("activate: cursor", cursorPos, "raw", String(lastRaw),
         "contentY", list.contentY.toFixed(1))
    activated(cursorItem)
  }

  function startFilter() {
    if (!filterable) return
    preFilterText = filterText
    filtering = true
  }

  // Committing keeps the text and starts at the first MATCH (jumpCursor
  // skips the header pseudo-row, which filtering keeps as view chrome).
  function commitFilter() {
    filtering = false
    lastRaw = -1
    cursorPos = 0
    jumpCursor(0)
  }

  // Leaving filter mode by Esc: revert the uncommitted edits (the
  // original cancel) and re-center the restored cursor. The filter churn
  // moved the content geometry under the viewport, so cancel is the one
  // model change that must scroll: "pushes never scroll" keeps the view
  // still, not the view stranded with the cursor off-screen.
  function cancelFilter() {
    var changed = filterText !== preFilterText
    filtering = false
    filterText = preFilterText
    if (!changed) return
    Qt.callLater(function() {
      if (items[cursorPos]) requestScroll(cursorPos)
    })
  }

  function clearFilter() {
    var had = filterText !== ""
    filtering = false
    filterText = ""
    preFilterText = ""
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

  // ---- scrolling. The cursor is the only scroll author: every move
  // centers its row (clamped at the content edges by the ListView), and
  // model changes never scroll. No Flickable of our own, no offset
  // ownership tricks: ScriptModel keeps contentY alive across pushes, and
  // the wheel is swallowed so nothing external ever writes it either.
  property bool resettingView: false
  property string debugName: ""
  property bool debug: true

  function dlog() {
    if (!debug) return
    var args = Array.prototype.slice.call(arguments)
    console.log("list2:", args.join(" | "))
  }

  // The leading block (album metadata, queue strip) declares its height
  // so it takes part in the row geometry as pseudo-row 0.
  property real headerHeight: 0

  function firstSelectableIndex() {
    for (var i = 0; i < items.length; i++)
      if (selectable(items[i])) return i
    return items.length
  }

  function scrollTo(pos) {
    if (pos < 0 || items.length === 0) return
    dlog("y-set: scrollTo cursor", pos, "contentY", list.contentY.toFixed(1))
    // Reaching the very top — by g, by filter commit, or by walking j up
    // to the first selectable row — pins the content top so the metadata
    // header (and any lead-in block) is visible again.
    if (pos === 0 || pos <= firstSelectableIndex()) {
      list.positionViewAtBeginning()
      return
    }
    // Center rule: the cursor row's position is a deterministic function
    // of itself — centered in the viewport, clamped at the content edges.
    list.positionViewAtIndex(pos, ListView.Center)
  }

  // Compatibility: jump straight to a pixel offset (Panel no longer
  // saves per-view offsets; kept for logging/debug callers).
  function scrollToOffset(y) {
    list.contentY = y
  }

  // Returns true when the event was consumed; unhandled keys stay
  // unaccepted so they can forward to the panel's own handler.
  function handleKey(event) {
    var t = event.text
    // Enter is an action key, never a held one: auto-repeat must not
    // re-activate rows (restart playback every frame) or re-commit the
    // filter. Handled here so every List user (main, palette) inherits it.
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
        && event.isAutoRepeat) { return true }
    // Filter mode: type into the prompt, Enter commits, Esc cancels.
    if (filtering) {
      if (event.key === Qt.Key_Escape) { cancelFilter(); return true }
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

  // Optional metadata block rendered above the rows (album/playlist
  // header). It enters the model as a pseudo-row, never as ListView's
  // `header` property: swapping/deleting the real header once crashed
  // quickshell outright, and a zero-height wrapper corrupted originY.
  property Component headerComponent: null

  // Tier lookup ({ id: "liked"|"loved"|"favorite" }); only rows with a
  // trackId ever resolve a tier, and unrated tracks are absent ("").
  property var tierMap: ({})

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

  // ---- the scroller: a real ListView (delegate windowing + recycling)
  // over a ScriptModel (in-place row updates, surviving contentY). The
  // wheel is swallowed by the MouseArea below, so the cursor is the only
  // scroll author and every row's on-screen position is deterministic.
  ListView {
    id: list
    anchors.top: parent.top
    anchors.topMargin: list2.filterable ? Style.space(34) : 0
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    width: parent.width - Style.space(18)
    clip: true
    highlight: null
    boundsBehavior: Flickable.StopAtBounds
    verticalLayoutDirection: list2.reversed ? ListView.BottomToTop : ListView.TopToBottom
    // Materialize two viewports past each edge so heights are measured
    // well before the center rule cares about them, and long-distance
    // jumps (g/G) settle within a frame.
    cacheBuffer: list.height > 0 ? list.height * 2 : 320

    model: ScriptModel {
      // Rows diff by `raw` identity: same raw = same row (updated in
      // place), new raw = insert/remove. Compose guarantees uniqueness.
      values: list2.items
      objectProp: "raw"
    }

    // The delegate wrapper is always instantiated and its height is the
    // caller's data-driven rowHeightOf — known before any layout, so
    // ListView's geometry stays exact (mixed heights mid-window were the
    // classic originY corruptor).
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
        // pseudo-row: dispatch its component instead of the row template.
        sourceComponent: rowWrap.modelData && rowWrap.modelData.headerRow === true
          ? list2.headerComponent : list2.rowDelegate
        property var modelData: rowWrap.modelData
        property int index: rowWrap.index
      }

      // Declarative bindings: the row's inputs update with the model, the
      // cursor and the transient flash — nothing is assigned imperatively.
      // The header pseudo-row loads a different component (MetaHeader/
      // queue strip) that owns none of these properties, so skip it.
      readonly property bool bindsRow: rowLoader.item !== null
        && !(rowWrap.modelData && rowWrap.modelData.headerRow === true)

      Binding {
        target: rowLoader.item
        property: "modelData"
        value: rowWrap.modelData
        when: rowWrap.bindsRow
      }
      Binding {
        target: rowLoader.item
        property: "index"
        value: rowWrap.index
        when: rowWrap.bindsRow
      }
      Binding {
        target: rowLoader.item
        property: "isCursor"
        value: rowWrap.index === list2.cursorPos && !list2.filtering
        when: rowWrap.bindsRow
      }
      Binding {
        target: rowLoader.item
        property: "tier"
        value: list2.tierMap[rowWrap.modelData ? rowWrap.modelData.trackId : ""] || ""
        when: rowWrap.bindsRow
      }
      Binding {
        target: rowLoader.item
        property: "flashText"
        value: (list2.flash !== null
                && rowWrap.index === list2.cursorPos
                && !list2.filtering
                && list2.flash.raw === list2.rawOf(rowWrap.modelData, rowWrap.index)) ? list2.flash.text : ""
        when: rowWrap.bindsRow
      }
    }

    Connections {
      target: list2
      function onRequestScroll(pos) { list2.scrollTo(pos) }
    }
  }

  // Wheel guard: the cursor owns scrolling, so no external scroll author
  // exists. acceptedButtons None lets clicks through; the wheel dies here.
  MouseArea {
    anchors.fill: list
    acceptedButtons: Qt.NoButton
    onWheel: wheel => wheel.accepted = true
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
      readonly property int edgeIndex: list.indexAt(list.width / 2, list.height - 2)
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
    visible: list.contentHeight > list.height + 1
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
        var range = list.contentHeight - list.height
        if (range <= 0) return 0
        return Math.max(0, Math.min(1, (list.contentY - list.originY) / range))
      }
      readonly property real frac: Math.min(1, list.height / Math.max(1, list.contentHeight))
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
