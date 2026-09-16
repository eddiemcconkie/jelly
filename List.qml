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
    return md && md.sectionRow ? secHeight : rowHeight
  }

  // ---- exact scroll math. ListView's built-in estimator (it sizes
  // un-instantiated rows from the first instantiated delegate) lies as
  // soon as heights vary, so all positioning is computed here from the
  // rows themselves: totals, cumulative offsets, band rules. No
  // positionViewAtIndex/AtEnd and no reading of contentHeight.
  function rowH(i) { return rowHeightOf(items[i]) }

  function exactContentHeight() {
    var h = headerHeight
    for (var i = 0; i < items.length; i++) h += rowH(i)
    return h
  }

  // Row offsets do NOT include the header: delegates start at content
  // y=0 and the header hangs ABOVE row 0 (contentTop is negative). The
  // header only enters the total through contentTop (= bounds).
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

  // Section headers become ordinary rows: one delegate geometry, so
  // contentHeight is exact from the first layout pass (native ListView
  // section delegates do not participate reliably, which corrupted every
  // position computed from contentHeight). A header is inserted wherever
  // consecutive rows change `section`; empty section values merge into
  // the previous group. A header adopts the height class of the row that
  // follows it — heights stay uniform within each stretch of the list,
  // which is what keeps ListView's geometry bookkeeping exact (mixed
  // heights at the first row corrupted originY/scroll positions).
  // Sections are skipped while filtering.
  function composeItems(src, withSections) {
    if (!withSections) return src
    var out = []
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
         "cH", list.contentHeight.toFixed(1), "count", list.count,
         "originY", list.originY.toFixed(1), "headerH", list.headerItem ? list.headerItem.height.toFixed(1) : "?")
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

  onItemsChanged: {
    dlog("model-reset: before", debugName, "items", items.length,
         list.contentY.toFixed(1), "held", heldY.toFixed(1),
         "resetting", resettingView, "pendingJump", pendingJumpPrefix,
         "cH", list.contentHeight.toFixed(1), "h", list.height.toFixed(1),
         "originY", list.originY.toFixed(1))
    // During bulk library load the caller streams album batches in and
    // each one reorders the (title-sorted) list as it lands; identity
    // remapping during that churn drifts the cursor (observed: 0 -> 1 on
    // every open). While suppressing, the cursor stays put instead.
    if (items.length === 0) {
      cursorPos = 0
      lastRaw = -1
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
             "n", items.length, "list.count", list.count)
        cursorPos = best
      } else {
        dlog("remap-clamp:", "raw", String(lastRaw), "cursor", cursorPos + "->" +
             Math.max(0, Math.min(cursorPos, items.length - 1)),
             "n", items.length, "list.count", list.count)
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
    dlog("model-reset: after", list.contentY.toFixed(1), "modelJump", modelJumped,
         "cursor", cursorPos, "cH", list.contentHeight.toFixed(1),
         "originY", list.originY.toFixed(1))
  }

  // Caller queues a prefix: on the next model change the cursor jumps to
  // the first row whose identity starts with it ("" = no-op).
  property string pendingJumpPrefix: ""

  function scrollOffset() { return list.contentY }

  signal requestScroll(int pos)
  signal activated(var item)
  signal actionTriggered(string action, var item)

  function activate() {
    if (!cursorItem) return
    dlog("activate: cursor", cursorPos, "raw", String(lastRaw),
         "contentY", list.contentY.toFixed(1))
    heldY = list.contentY
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

  // ---- scrolling. One owner: explicit cursor/view commands update the
  // held offset; Enter only records it, so model pushes cannot move the
  // visible window.
  property real heldY: 0
  property bool resettingView: false
  property string debugName: ""
  property bool debug: true

  function dlog() {
    if (!debug) return
    var args = Array.prototype.slice.call(arguments)
    console.log("list2:", args.join(" | "))
  }

  // The content top derived from our own state: minus the header height
  // the caller declares alongside headerComponent. Do NOT read
  // list.headerItem here: touching it while the header is being destroyed
  // (every switch into the headerless queue view) crashed quickshell with
  // no QML warning.
  property real headerHeight: 0
  function contentTop() { return -headerHeight }


  // Every write of the offset goes through here so each change of the
  // visible window can be traced to its cause in the journal.
  property bool ySetting: false
  function yWrite(cause, value) {
    dlog("y-set:", cause, list.contentY.toFixed(1) + "->", value.toFixed(1),
         "heldY", heldY.toFixed(1))
    ySetting = true
    list.contentY = value
    ySetting = false
  }

  function scrollToOffset(y) {
    heldY = y
    restoreHeldY()
  }

  function firstSelectableIndex() {
    for (var i = 0; i < items.length; i++)
      if (selectable(items[i])) return i
    return items.length
  }

  function scrollTo(pos) {
    if (pos < 0 || list.count === 0) return
    // Reaching the very top — by g, by filter commit, or by walking j up
    // to the first selectable row — snaps to the content top so the
    // metadata header (and any lead-in block) is visible again.
    if (pos === 0 || pos <= firstSelectableIndex()) {
      heldY = contentTop()
      yWrite("scrollTo head (cursor " + pos + ")", contentTop())
      Qt.callLater(clampAndHold)
      return
    }
    // Band rule (the old list's "one-row buffer", now exact): the cursor
    // and its predecessor must both be fully visible; anything else
    // stays put. contentY ∈ [cursorBottom − viewport, predecessorTop].
    var top = contentTop()
    var vp = list.height
    // One-row buffer (the old Contain pair's intent): going down keeps
    // the NEXT row peeking below the viewport bottom, going up keeps the
    // PREVIOUS row above the top edge — the cursor never sits flush
    // against either edge mid-list.
    var y = cumulativeY(pos)
    var h = rowH(pos)
    var lo = pos + 1 < items.length
        ? cumulativeY(pos + 1) + rowH(pos + 1) - vp
        : y + h - vp
    var hi = y - rowH(pos - 1)
    var target = Math.max(lo, Math.min(list.contentY, hi))
    // A list that fits the viewport has only one position: the top
    // (header in view).
    if (exactContentHeight() <= vp) target = top
    // Content spans [contentTop, contentTop + exactHeight]; the bottom
    // stop must offset the header the same way the top does.
    heldY = Math.max(top, Math.min(target, contentTop() + exactContentHeight() - vp))
    yWrite("scrollTo cursor " + pos, heldY)
    Qt.callLater(clampAndHold)
  }

  // Restore trusts heldY verbatim: mid-reset contentHeight is unreliable
  // (delegates still materializing despite forceLayout), so clamping here
  // would crush a valid offset down to a smaller bogus maxY. Assign first,
  // then clamp a frame later against settled geometry.
  function restoreHeldY() {
    if (list.count === 0) return
    yWrite("restoreHeldY", heldY)
    Qt.callLater(clampAndHold)
  }

  function clampAndHold() {
    if (list.count === 0) return
    list.forceLayout()
    // heldY is the one owner of the offset. A model reset repositions
    // the viewport asynchronously at layout time (after this reset's
    // own restore), so the clamp must REASSERT heldY against the settled
    // geometry, not merely clamp whatever the ListView left behind —
    // otherwise the visible window flashes/lands at the top.
    var minY = contentTop()
    // draggable content spans [contentTop, contentTop + exactHeight] in
    // content coordinates (the header hangs above row 0), so the bottom
    // stop subtracts the top offset too. Forgetting it leaves a strip of
    // phantom content at the bottom edge.
    var maxY = Math.max(minY, contentTop() + exactContentHeight() - list.height)
    var ny = Math.max(minY, Math.min(heldY, maxY))
    dlog("clamp:", "heldY", heldY.toFixed(1), "ny", ny.toFixed(1),
         "maxY", maxY.toFixed(1), "cH", list.contentHeight.toFixed(1), "minY", minY.toFixed(1))
    heldY = ny
    yWrite("clampAndHold", ny)
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

  ListView {
    id: list
    anchors.top: parent.top
    anchors.topMargin: list2.filterable ? Style.space(34) : 0
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    width: parent.width - Style.space(18)
    clip: true
    model: list2.items
    highlight: null
    verticalLayoutDirection: list2.reversed ? ListView.BottomToTop : ListView.TopToBottom
    boundsBehavior: Flickable.StopAtBounds
    // Materialize delegates near the edges too, so the band check sees
    // them instead of treating a laid-out row as unloaded.
    cacheBuffer: list.height > 0 ? list.height * 2 : 320
    // The header must have a definite height or contentHeight misses it
    // (observed: c = sum of rows only), which breaks scroll bounds. Only
    // attach the component when there is one: an always-present empty
    // header wrapper leaves a stray zero-height item in the content that
    // corrupts originY/contentHeight bookkeeping.
    header: list2.headerComponent ? hdrComp : null
    Component {
      id: hdrComp
      Item {
        implicitHeight: hdrLoader.item ? hdrLoader.item.implicitHeight : 0
        height: implicitHeight
        Loader {
          id: hdrLoader
          sourceComponent: list2.headerComponent
        }
      }
    }

    // The delegate wrapper is always instantiated and its height is the
    // caller's constant rowHeight — known to ListView before any layout,
    // so contentHeight is exact from the first pass. The Loader swaps the
    // row component per tab without touching geometry.
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
        sourceComponent: list2.rowDelegate
        property var modelData: rowWrap.modelData
        property int index: rowWrap.index
      }

      // Declarative bindings: the row's inputs update with the model, the
      // cursor and the transient flash — nothing is assigned imperatively.
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

    // Viewport moves we did not make — typically ListView's async
    // post-reset reposition — reassert heldY immediately (synchronous in
    // this handler, so a repositioned frame can never paint). While the
    // user is wheel-scrolling/flicking, adopt the real position into
    // heldY instead; it is committed when the movement ends.
    onContentYChanged: {
      if (list2.ySetting) return
      list2.dlog("y-external:", "contentY", list.contentY.toFixed(1),
                 "heldY", list2.heldY.toFixed(1))
      if (list.moving || list.flicking) { list2.heldY = list.contentY; return }
      var minY = list2.contentTop()
      var maxY = Math.max(minY, list2.contentTop() + list2.exactContentHeight() - list.height)
      if (list2.heldY < minY - 0.01 || list2.heldY > maxY + 0.01) {
        // heldY is out of the content's valid range (viewport or content
        // changed): adopt the position the layout chose.
        list2.heldY = list.contentY
        return
      }
      if (Math.abs(list.contentY - list2.heldY) > 0.01) {
        list2.dlog("y-revert:", "external", list.contentY.toFixed(1) + "->", list2.heldY.toFixed(1))
        list2.ySetting = true
        list.contentY = list2.heldY
        list2.ySetting = false
      }
    }
    onMovementEnded: {
      list2.dlog("y-move-end:", "contentY", list.contentY.toFixed(1))
      list2.heldY = list.contentY
    }
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
        return Math.max(0, Math.min(1, (list.contentY - contentTop()) / range))
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
