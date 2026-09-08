// PROTOTYPE — Jelly full-view popup wired to the live daemon (v0 ad-hoc
// jelly-ipc). Single source of truth: the daemon's pushed PlaybackSnapshot.
// The UI keeps no playback state — only a navigation cursor, which starts
// at the top of every view; o jumps to the playing track. Throwaway.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Mock.js" as Mock

Panel {
  id: root
  moduleName: "eddie.jelly"
  ipcTarget: "eddie.jelly"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- daemon snapshot: THE playback truth (two-tier model:
  //      snap.context = loaded album/playlist, snap.queue + queue_head =
  //      the temporary queue)
  property var snap: ({ status: "stopped", queue: [], queue_head: null, current: null, context: null, volume: 100 })
  property real position: 0
  readonly property bool playing: snap.status === "playing"
  readonly property bool connected: sock !== null && sock.connected
  readonly property var nowTrack: snap.current || snap.queue_head || null
  readonly property var now: nowTrack
    ? nowTrack
    : ({ id: "", name: connected ? "Nothing playing" : "Daemon offline", artist: "", album: "" })
  readonly property var nowCtx: snap.context || null
  readonly property real duration: {
    if (snap.duration_secs) return snap.duration_secs
    return (nowTrack && nowTrack.duration_secs) || 0
  }
  readonly property string pillGlyph: playing ? "󰏤" : "󰐊"
  readonly property string pillText:
    now.name + (nowCtx && nowCtx.name ? " — " + nowCtx.name : (now.album ? " — " + now.album : ""))
  readonly property string nowCover:
    (nowCtx && nowCtx.image_url) || coverByAlbum(now.album)

  // ---- browse library (real dump from Jellyfin)
  property var library: ({ albums: [], playlists: [] })
  readonly property bool libraryLoaded: library.albums.length > 0

  // Queue view: the playing track is the queue head, else find it among
  // the visible track rows by id.
  function nowPlayingRaw() {
    if (!now || !now.id) return -1
    // Queue tab: the playing row is matched by track id in focusPlaying.
    if (tab === "queue") return now.id
    var t = tab, p = path
    if (t === "albums") {
      if (p.length >= 1) {
        var al = library.albums[p[0]]
        for (var i = 0; i < al.tracks.length; i++) if (al.tracks[i].id === now.id) return i
      }
      return -1
    }
    var pls = library.playlists.filter(function(p2) { return p2.name === "Playlists" })
    if (pls.length === 0) return -1
    var items = pls[0].items || []
    if (p.length >= 1) {
      var tracks = items[p[0]] ? (items[p[0]].tracks || []) : []
      for (var j = 0; j < tracks.length; j++) if (tracks[j].id === now.id) return j
      return -1
    }
    for (var k = 0; k < items.length; k++) if (items[k].type !== "Playlist" && items[k].id === now.id) return k
    return -1
  }

  function coverByAlbum(albumTitle) {
    if (!albumTitle) return ""
    var als = library.albums
    for (var i = 0; i < als.length; i++) if (als[i].title === albumTitle) return coverFor(als[i])
    return ""
  }

  // ---- cover disk cache. QML only caches images in memory, so every
  // popup open re-downloaded ~27 covers. The warmer downloads each cover
  // once into $XDG_CACHE_HOME/jelly/covers/<id>.png; from then on rows
  // use a file:// URL and opening the popup is instant.
  readonly property string coverDir:
    (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") || "/home") + "/.cache") + "/jelly/covers"
  // id -> "file://..." for every cover the warmer has confirmed on disk.
  property var cachedCovers: ({})
  property int coversRev: 0

  function coverFor(item) {
    var _ = coversRev  // re-evaluate when the warmer reports new files
    return cachedCovers[item.id] || item.cover || ""
  }

  function warmCovers() {
    var script = "mkdir -p '" + coverDir + "'\n"
    function add(it) {
      if (!it || !it.id || !it.cover) return
      // Serve from disk once the file exists; download it if it doesn't.
      script += "f='" + coverDir + "/" + it.id + ".png'"
        + "; if [ -s \"$f\" ] || curl -sf '" + it.cover + "' -o \"$f\"; then echo '" + it.id + "'; fi\n"
    }
    for (var i = 0; i < library.albums.length; i++) add(library.albums[i])
    for (var p = 0; p < library.playlists.length; p++) {
      var its = library.playlists[p].items || []
      for (var j = 0; j < its.length; j++) add(its[j])
    }
    coverWarmer.command = ["sh", "-c", script]
    coverWarmer.running = true
  }

  Process {
    id: coverWarmer
    command: []
    stdout: SplitParser {
      onRead: line => {
        var id = line.trim()
        if (id === "") return
        var m = {}
        for (var k in root.cachedCovers) m[k] = root.cachedCovers[k]
        m[id] = "file://" + root.coverDir + "/" + id + ".png"
        root.cachedCovers = m
      }
    }
    onExited: root.coversRev++
  }

  // ---- navigation state (cursor is navigation-only, never playback truth)
  property string tab: "albums"   // queue | albums | playlists
  property var paths: ({ "queue": [], "albums": [], "playlists": [] })
  property var filterTexts: ({ "queue": "", "albums": "", "playlists": "" })
  property bool filtering: false
  // cursorPos indexes the visible (possibly filtered) list; raw is the
  // stable identity used for drill/play and for keeping focus across
  // filter changes.
  property int cursorPos: 0
  property int lastRaw: -1

  readonly property var path: paths[tab]
  onPathChanged: console.info("jelly: path ->", JSON.stringify(path), "tab", tab)
  readonly property string filterText: filtering ? filterInput.text : filterTexts[tab]

  // ---- daemon socket. A Socket whose first connect failed can stay wedged
  // (connected stays true, toggling coalesces), so the watchdog RECREATES
  // the socket object instead of toggling it.
  property real lastRecv: 0
  property var sock: null

  Component {
    id: sockComp

    Socket {
      path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/jelly/daemon.sock"
      connected: true
      onError: console.warn("jelly: socket error", JSON.stringify(error))

      parser: SplitParser {
        onRead: line => {
          if (line.trim() === "") return
          root.lastRecv = Date.now()
          try {
            var msg = JSON.parse(line)
            if (msg.type === "state") {
              root.snap = msg
              root.position = msg.position_secs || 0
            } else if (msg.type === "position") {
              root.position = msg.position_secs
            } else if (msg.type === "error") {
              console.warn("jelly daemon error:", msg.message)
            }
          } catch (e) { console.warn("jelly: bad line", e) }
        }
      }
      onConnectedChanged: {
        console.info("jelly: socket connected =", connected)
        if (connected) Qt.callLater(function() { root.send({ type: "get_state" }) })
      }
    }
  }

  function connectSock() {
    if (sock) sock.destroy()
    sock = sockComp.createObject(root)
  }

  // Watchdog: the daemon may come up after us (the plugin service spawns it
  // ~2s in), and a live daemon talks constantly (position events every
  // 250ms while playing). Silence for 5s = rebuild the connection.
  Timer {
    interval: 3000
    running: true
    repeat: true
    onTriggered: if (Date.now() - root.lastRecv > 5000) root.connectSock()
  }

  function send(obj) {
    console.info("jelly: send", obj.type)
    if (sock) {
      sock.write(JSON.stringify(obj) + "\n")
      sock.flush()
    }
  }

  // ---- list model per view. Items: { raw, title, sub, kind, drillable,
  //      playing, cover, playTrackIds, playStart }
  // kind: "album" | "playlist" | "track"
  function metasFrom(list, albumTitle) {
    return list.map(function(x) {
      return { id: x.id, name: x.title, artist: x.artist || "", album: albumTitle || x.album || "",
               duration_secs: x.length ? x.length * 1.0 : null, image_url: null, stream_url: "" }
    })
  }

  // Metadata for the drilled-in album/playlist detail view (header block).
  function detailMeta() {
    var t = tab, p = path
    if (t === "albums" && p.length >= 1) {
      var al = library.albums[p[0]]
      if (!al) return {}
      var dur = 0
      for (var i = 0; i < al.tracks.length; i++) dur += al.tracks[i].length || 0
      return { title: al.title, artist: al.artist, cover: coverFor(al), count: al.tracks.length, dur: dur }
    }
    if (t === "playlists" && p.length >= 1) {
      var pls = library.playlists.filter(function(p2) { return p2.name === "Playlists" })
      if (pls.length === 0) return {}
      var parent = (pls[0].items || [])[p[0]]
      if (!parent) return {}
      var tracks = parent.tracks || []
      var d2 = 0
      for (var j = 0; j < tracks.length; j++) d2 += tracks[j].length || 0
      return { title: parent.title, artist: parent.artist || "", cover: coverFor(parent), count: tracks.length, dur: d2 }
    }
    return {}
  }

  function rawList() {
    var t = root.tab, p = root.path
    if (t === "queue") {
      // Two tiers: the queue (pinned head + waiting items), a rule, then
      // the remaining playback-context tracks under a context header.
      var out = []
      var ctx = snap.context
      var ctxCover = ctx && ctx.image_url ? ctx.image_url : ""
      function row(tr, extra) {
        var base = {
          cover: coverByAlbum(tr.album) || (tr.image_url || ""),
          title: tr.name,
          sub: (tr.artist ? tr.artist : "") + (tr.duration_secs ? "  ·  " + Mock.fmt(tr.duration_secs) : ""),
          kind: "track", drillable: false, favId: tr.id,
          playing: tr.id === root.now.id && !root.snap.queue_head
        }
        for (var k in extra) base[k] = extra[k]
        return base
      }
      // The current queue song is NOT listed — it lives in the now-playing
      // bar at the bottom.
      var waiting = snap.queue || []
      if (waiting.length > 0)
        out.push({ raw: "section-upnext", title: "Up next", sub: "", kind: "section",
                   drillable: false, playing: false })
      for (var i = 0; i < waiting.length; i++) {
        out.push(row(waiting[i], { raw: waiting[i].id, trackId: waiting[i].id, queueIndex: i }))
      }
      if (ctx) {
        // The rule only separates two non-empty sections.
        if (waiting.length > 0)
          out.push({ raw: "sep", title: "", sub: "", kind: "sep", drillable: false, playing: false })
        out.push({ raw: "section-ctx", title: ctx.name, sub: ctx.artist || "", kind: "section",
                   drillable: false, playing: false })
        var tracks = ctx.tracks || []
        for (var j = (ctx.current_index !== null && ctx.current_index !== undefined ? ctx.current_index + 1 : 0); j < tracks.length; j++) {
          out.push(row(tracks[j], { raw: tracks[j].id, trackId: tracks[j].id, ctxIndex: j, metas: tracks }))
        }
      }
      return out
    }
    if (t === "albums") {
      if (p.length === 0)
        return library.albums.map(function(al, i) {
          return { raw: i, itemId: al.id, cover: coverFor(al), title: al.title, sub: al.artist + "  ·  " + al.tracks.length + " tracks",
                   kind: "album", drillable: true,
                   playing: nowCtx && nowCtx.name === al.title,
                   playTrackIds: al.tracks.map(function(x) { return x.id }), playStart: 0 }
        })
      var album = library.albums[p[0]]
      return album.tracks.map(function(tr, i) {
        return { raw: i, favId: tr.id, cover: album.cover || "", title: tr.title, sub: tr.artist + "  ·  " + Mock.fmt(tr.length),
                 kind: "track", drillable: false, playing: tr.id === now.id,
                 playTrackIds: album.tracks.map(function(x) { return x.id }), playStart: i }
      })
    }
    // playlists: items of the "Playlists" playlist — nested playlists are
    // drillable like albums.
    var pls = library.playlists.filter(function(p2) { return p2.name === "Playlists" })
    if (pls.length === 0) return []
    var items = pls[0].items || []
    if (p.length === 0)
      return items.map(function(it, i) {
        var isPl = it.type === "Playlist"
        return { raw: i, itemId: it.id, cover: coverFor(it), title: it.title,
                 sub: isPl ? (it.tracks ? it.tracks.length + " tracks" : "playlist") : (it.artist || ""),
                 kind: isPl ? "playlist" : "track", drillable: isPl,
                 playing: isPl ? (nowCtx && nowCtx.name === it.title) : (!isPl && it.id === now.id),
                 playTrackIds: isPl ? (it.tracks || []).map(function(x) { return x.id }) : items.filter(function(x) { return x.type !== "Playlist" }).map(function(x) { return x.id }),
                 playStart: 0 }
      })
    var parent = items[p[0]]
    var tracks = parent ? (parent.tracks || []) : []
    return tracks.map(function(tr, i) {
      return { raw: i, favId: tr.id, cover: coverFor(parent), title: tr.title,
               sub: tr.artist || "", kind: "track", drillable: false, playing: tr.id === now.id,
               playTrackIds: tracks.map(function(x) { return x.id }), playStart: i }
    })
  }

  readonly property var rawItems: rawList()
  readonly property var items: filterText === "" ? rawItems
    : rawItems.filter(function(it) {
        return it.title.toLowerCase().indexOf(filterText.toLowerCase()) >= 0
      })

  // Only real rows take the cursor; pinned head / rule / section header
  // are skipped.
  function selectable(it) {
    return it && (it.kind === "track" || it.drillable)
  }

  // Nearest selectable index at or after `pos`, searching outward.
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

  // Keep the same underlying item focused when the list changes under a
  // filter (clearing or editing maps the cursor back via its raw index).
  // Cursor bookkeeping in one place: park cursorPos on whatever is actually
  // rendered (the playing row while following, else the lastRaw remap) and
  // ask the list to scroll there. Used by drill/pop/tab/open/items-change so
  // the real cursor can never disagree with the visible highlight.
  signal requestScroll(int pos)

  // Entering a view always starts at the top; o jumps to the playing row.
  function resetViewCursor() {
    cursorPos = 0
    lastRaw = -1
    requestScroll(0)
  }

  // Park the cursor on the row with this raw identity (used when popping
  // back out of a view, to land on the album/playlist we came from).
  function focusRaw(raw, fallbackPos) {
    var idx = -1
    for (var i = 0; i < items.length; i++) if (items[i].raw === raw) { idx = i; break }
    if (idx < 0) idx = nearestSelectable(fallbackPos || 0)
    if (idx < 0) idx = 0
    cursorPos = idx
    lastRaw = items[idx] ? items[idx].raw : -1
    requestScroll(idx)
  }

  onItemsChanged: {
    if (items.length === 0) { cursorPos = 0; lastRaw = -1; return }
    var before = cursorPos
    var idx = -1
    for (var i = 0; i < items.length; i++) if (items[i].raw === lastRaw) { idx = i; break }
    // Cursor identity lost (e.g. the selected queue head became the
    // current song): land on the next selectable row.
    var target = idx >= 0 ? idx : nearestSelectable(cursorPos)
    if (target < 0) target = nearestSelectable(0)
    cursorPos = target >= 0 ? target : 0
    if (!selectable(items[cursorPos])) {
      var ns = nearestSelectable(cursorPos)
      cursorPos = ns >= 0 ? ns : 0
    }
    lastRaw = items[cursorPos].raw
    // Defer the scroll to after the new model has laid out: re-scrolling
    // during a model reset positions against half-built geometry and
    // lands mid-list (the "g jumps to the middle" bug).
    if (cursorPos !== before) Qt.callLater(function() { root.requestScroll(cursorPos) })
  }

  function moveCursor(d) {
    if (items.length === 0) return
    var pos = cursorPos
    do { pos = Math.max(0, Math.min(items.length - 1, pos + d)) } while (!selectable(items[pos]) && pos > 0 && pos < items.length - 1)
    if (!selectable(items[pos])) return
    cursorPos = pos
    lastRaw = items[pos].raw
    requestScroll(pos)
  }

  function jumpCursor(pos) {
    if (items.length === 0) return
    var ns = nearestSelectable(pos)
    if (ns < 0) return
    cursorPos = ns
    lastRaw = items[ns].raw
    requestScroll(ns)
  }

  function clampCursor() {
    if (items.length === 0) { cursorPos = 0; return }
    var ns = nearestSelectable(cursorPos)
    cursorPos = ns >= 0 ? ns : 0
    lastRaw = items[cursorPos].raw
  }

  function drill() {
    var it = items[cursorPos]
    if (!it || !it.drillable) return
    // l navigates into the view one level.
    clearFilter()
    var p = paths[tab].slice()
    p.push(it.raw)
    var np = {}
    for (var k in paths) np[k] = paths[k]
    np[tab] = p
    paths = np
    resetViewCursor()
  }

  function popLevel() {
    clearFilter()
    if (paths[tab].length === 0) return false
    var cameFrom = paths[tab][paths[tab].length - 1]
    var np = {}
    for (var k in paths) np[k] = paths[k]
    np[tab] = paths[tab].slice(0, -1)
    paths = np
    // Land on the album/playlist we just came from, not the top.
    focusRaw(cameFrom, 0)
    return true
  }

  // Cycle tabs in display order; [ goes left, ] goes right, wrapping.
  function cycleTab(dir) {
    var order = ["queue", "albums", "playlists"]
    var next = (order.indexOf(tab) + dir + order.length) % order.length
    switchTab(order[next])
  }

  function switchTab(t) {
    clearFilter()
    if (t === tab) {
      var np = {}
      for (var k in paths) np[k] = paths[k]
      np[t] = []
      paths = np
      resetViewCursor()
      return
    }
    tab = t
    resetViewCursor()
  }

  // Start a (re)selection: loading a fresh context resets repeat-one to
  // plain repeat — nobody wants one song looping forever after picking a
  // new album.
  function startPlayback(tracks, startIndex) {
    send({ type: "play", tracks: tracks, start_index: startIndex })
    if (snap.repeat === "one") send({ type: "set_repeat", mode: "off" })
  }

  function activate() {
    var it = items[cursorPos]
    if (!it) return
    // Enter plays: an album/playlist becomes the playback context from
    // its start; a track plays in place.
    if (it.kind !== "track") {
      if (it.drillable && it.playTrackIds && it.playTrackIds.length > 0) {
        var metas = buildMetas(it)
        if (metas.length > 0) { startPlayback(metas, 0); return }
      }
      if (it.drillable) { drill(); return }
      return
    }
    if (tab === "queue") {
      // Waiting queue item: jump to it (earlier ones are consumed).
      if (it.queueIndex !== undefined && it.queueIndex !== null) {
        send({ type: "jump_to", index: it.queueIndex })
        return
      }
      // Context track: restart the context at that song.
      if (it.ctxIndex !== undefined && it.ctxIndex !== null && it.metas && it.metas.length > 0) {
        startPlayback(it.metas, it.ctxIndex)
        return
      }
      return
    }
    // enter = play from here; daemon state push moves the UI
    if (!it.playTrackIds || it.playTrackIds.length === 0) return
    var metas = buildMetas(it)
    if (metas.length === 0) return
    startPlayback(metas, it.playStart)
  }

  // TrackMeta list for the item's context (daemon rebuilds stream URLs from ids).
  function buildMetas(it) {
    var t = tab, p = path
    var src = []
    if (t === "queue") {
      src = snap.queue.map(function(q) {
        return { id: q.id, name: q.name, artist: q.artist || "", album: q.album || "", duration_secs: q.duration_secs || null, stream_url: "" }
      })
    } else if (t === "albums") {
      if (p.length >= 1) {
        var al = library.albums[p[0]]
        src = metasFrom(al.tracks, al.title)
      } else {
        // album row: play the album itself
        var al2 = library.albums[it.raw]
        if (al2) src = metasFrom(al2.tracks, al2.title)
      }
    } else if (t === "playlists") {
      var pls = library.playlists.filter(function(p2) { return p2.name === "Playlists" })
      if (pls.length > 0) {
        var items = pls[0].items || []
        if (p.length >= 1) {
          var parent = items[p[0]]
          src = metasFrom(parent ? (parent.tracks || []) : [], parent ? parent.title : "")
        } else if (it.kind === "playlist") {
          var nested = items[it.raw]
          src = metasFrom(nested.tracks || [], nested.title)
        } else {
          // play the first nested playlist's tracks as a stand-in
          for (var i = 0; i < items.length; i++)
            if (items[i].type === "Playlist") { src = metasFrom(items[i].tracks || [], items[i].title); break }
        }
      }
    }
    return src
  }

  // ---- transport commands
  // Jump the cursor to the playing track and re-sync. Only offered when the
  // playing track is visible in the current view.
  function focusPlaying() {
    var np = nowPlayingRaw()
    if (np < 0) return
    for (var i = 0; i < items.length; i++) {
      if (selectable(items[i]) && (items[i].trackId !== undefined ? items[i].trackId : items[i].raw) === np) {
        cursorPos = i
        lastRaw = items[i].raw
        requestScroll(i)
        return
      }
    }
  }

  readonly property bool canFocusPlaying: nowPlayingRaw() !== -1

  function togglePlay() { send({ type: "toggle_play" }) }
  function skip(dir) { send(dir > 0 ? { type: "next" } : { type: "prev" }) }
  function nextTrack() { skip(1) }
  function prevTrack() { skip(-1) }
  function seekBy(d) { send({ type: "seek", position_secs: Math.max(0, position + d) }) }

  // ---- queue actions (q/p work on any track row; d/J/K only on waiting
  //      queue items in the queue tab)
  // TrackMeta for the cursor's track: queue/context rows carry wire metas
  // already; browse rows go through buildMetas. Null when there's nothing
  // queueable — including tracks already waiting in the queue.
  function queuedIds() {
    var ids = {}
    if (snap.queue_head) ids[snap.queue_head.id] = true
    var w = snap.queue || []
    for (var i = 0; i < w.length; i++) ids[w[i].id] = true
    return ids
  }

  function metaForQueueAction() {
    var it = items[cursorPos]
    if (!it || it.kind !== "track") return null
    if (tab === "queue") {
      if (it.queueIndex !== undefined && it.queueIndex !== null) return snap.queue[it.queueIndex]
      if (it.ctxIndex !== undefined && it.ctxIndex !== null && snap.context) return snap.context.tracks[it.ctxIndex]
      return null
    }
    var m = buildMetas(it)
    if (m.length === 0) return null
    return m[it.playStart || 0]
  }

  function flashAction(raw, text) {
    actionFlash = { raw: raw, text: text }
    flashTimer.restart()
  }

  function queueTail() {
    var it = items[cursorPos]
    var m = metaForQueueAction()
    if (!m) return
    if (queuedIds()[m.id]) { flashAction(it.raw, "already queued"); return }
    send({ type: "enqueue", items: [m] })
    flashAction(it.raw, "queued")
  }

  function queueHead() {
    var it = items[cursorPos]
    var m = metaForQueueAction()
    if (!m) return
    if (queuedIds()[m.id]) { flashAction(it.raw, "already queued"); return }
    send({ type: "play_next", item: m })
    flashAction(it.raw, "play next")
  }

  function removeQueueItem() {
    var it = items[cursorPos]
    if (tab === "queue" && it && it.queueIndex !== undefined && it.queueIndex !== null)
      send({ type: "remove_from_queue", index: it.queueIndex })
  }

  function moveQueueItem(delta) {
    var it = items[cursorPos]
    if (tab !== "queue" || !it || it.queueIndex === undefined || it.queueIndex === null) return
    var target = it.queueIndex + delta
    if (target < 0 || target >= snap.queue.length) return // daemon clamps; don't move the cursor
    send({ type: "move_queue", index: it.queueIndex, delta: delta })
    // Keep the moved song under the cursor: pin its stable id so the
    // item-remap below follows it to the new slot.
    cursorPos = cursorPos + delta
    lastRaw = it.raw
    requestScroll(cursorPos)
  }

  // Selection feedback: a short accent label on the acted-on row, placed
  // left of the heart icon so the two never overlap.
  property var actionFlash: null
  Timer { id: flashTimer; interval: 1400; onTriggered: root.actionFlash = null }

  // ---- favorites. The daemon pushes the full favorite-id set on login
  //      and after every toggle.
  readonly property var favSet: {
    var m = {}
    var ids = snap.favorite_ids || []
    for (var i = 0; i < ids.length; i++) m[ids[i]] = true
    return m
  }

  function toggleFavoriteId(id, flashRaw) {
    if (!id) return
    if (!connected) {
      flashAction(flashRaw, "offline — favorites need a daemon connection")
      return
    }
    send({ type: "toggle_favorite", item_id: id })
    flashAction(flashRaw, favSet[id] ? "unfavorited" : "favorited")
  }

  function toggleFavoriteSelected() {
    var it = items[cursorPos]
    var id = it ? (it.trackId !== undefined ? it.trackId : it.favId) : null
    toggleFavoriteId(id, it ? it.raw : undefined)
  }

  function toggleFavoriteNow() {
    toggleFavoriteId(now.id, undefined)
  }

  function startFilter() {
    // The queue tab is a live view of daemon state — no filter there.
    if (tab === "queue") return
    filtering = true
    Qt.callLater(function() { filterInput.forceActiveFocus() })
  }

  function commitFilter() {
    var nf = {}
    for (var k in filterTexts) nf[k] = filterTexts[k]
    nf[tab] = filterInput.text
    filterTexts = nf
    filtering = false
    // A committed filter is a fresh view: start at the top. The cursor
    // identity must be pinned to the top row of the FILTERED list once
    // it settles, so exiting the filter later lands on this same item
    // (not the top of the unfiltered list).
    resetViewCursor()
    Qt.callLater(function() {
      keyFocus.forceActiveFocus()
      if (items[cursorPos]) lastRaw = items[cursorPos].raw
    })
  }

  function cancelFilter() {
    filtering = false
    Qt.callLater(function() { keyFocus.forceActiveFocus() })
  }

  function clearFilter() {
    filtering = false
    var had = filterTexts[tab] !== ""
    var nf = {}
    for (var k in filterTexts) nf[k] = filterTexts[k]
    nf[tab] = ""
    filterTexts = nf
    // Exiting a committed filter is not a view change: park the cursor
    // back on the same item selected in the filtered view, wherever it
    // sits in the full list. (Drill/pop/tab flows call this first, then
    // re-target the cursor themselves — those run after and win.)
    if (had) focusRaw(lastRaw, 0)
  }

  // ---- contextual hint bar
  readonly property string hints: {
    if (!connected) return "daemon offline — start jelly-daemon"
    if (filtering) return "type to filter (live) · enter keep & jump in · esc cancel"
    var h = "j/k move"
    var it = (items.length > 0 && cursorPos < items.length) ? items[cursorPos] : null
    if (it && it.drillable) h += " · enter open"
    else if (it && it.kind === "track") h += " · enter play"
    if (tab === "queue" && it && it.queueIndex !== undefined)
      h += " · enter jump · d remove · J/K move"
    else if (it && it.kind === "track")
      h += " · q queue · p play next · f favorite"
    h += " · h out" + (tab === "queue" ? "" : " · / filter") + " · tab/H/L tabs" + (root.canFocusPlaying ? " · o playing" : "") + " · space play/pause · n/N next/prev · ,/. seek · s shuffle · r repeat · F fav playing · esc close"
    return h
  }

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function refresh() {}

  function injectKeys() {
    Qt.callLater(function() { if (!filtering) keyFocus.forceActiveFocus() })
  }

  // ---- library load
  FileView {
    path: Qt.resolvedUrl("MockLibrary.json")
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.library = JSON.parse(text())
        root.warmCovers()
      } catch (e) { console.warn("jelly: bad library json", e) }
    }
  }

  // Cover preloader: decode every cover once into Qt's image cache so
  // scrolling list rows never show a blank slot on the way back.
  // Preloader: decode every cover once into Qt's image cache. Kept visible
  // but parked off-screen — async images with visible:false never load.
  Item {
    x: -9999
    y: -9999
    width: 1
    height: 1
    Repeater {
      model: root.library.albums
      Image {
        required property var modelData
        source: modelData.cover || ""
        cache: true
        asynchronous: true
        sourceSize.width: 320
        sourceSize.height: 320
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyFocus
    contentWidth: panel.fittedContentWidth(Style.space(680))
    // Floor at the stable layout sum: at first open the Column hasn't been
    // laid out yet and its implicitHeight reads ~53, which would birth the
    // window tiny and grow it a few frames later.
    contentHeight: panel.fittedContentHeight(
      Math.max(fullColumn.implicitHeight, Style.space(521)))

    onOpenChanged: if (open) injectKeys()

    FocusScope {
      id: keyFocus
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        var t = event.text
        // No key repeat on transport keys: held n/N would queue a burst of
        // cold network fetches in mpv. j/k and ,/. keep their repeat.
        var transport = t === "n" || t === "N" || event.key === Qt.Key_Space
        if (transport && event.isAutoRepeat) { event.accepted = true; return }
        // A committed filter comes first: esc/h clear it before any
        // view navigation happens.
        if (!root.filtering && root.filterText !== ""
            && (event.key === Qt.Key_Escape || t === "h")) {
          root.clearFilter(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Escape) {
          if (root.filtering) { root.clearFilter(); event.accepted = true; return }
          if (root.popLevel()) { event.accepted = true; return }
          root.close(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Down || t === "j") { root.moveCursor(1); event.accepted = true; return }
        if (event.key === Qt.Key_Up || t === "k") { root.moveCursor(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Left || t === "h") { root.popLevel(); event.accepted = true; return }
        if (event.key === Qt.Key_Right || t === "l") { root.drill(); event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activate(); event.accepted = true; return }
        if (event.key === Qt.Key_Space) { root.togglePlay(); event.accepted = true; return }
        if (t === "g") { root.jumpCursor(0); event.accepted = true; return }
        if (t === "G") { root.jumpCursor(root.items.length - 1); event.accepted = true; return }
        if (t === "s") { send({ type: "set_shuffle", on: !(snap.shuffle) }); event.accepted = true; return }
        if (t === "r") {
          var mode = snap.repeat === "all" ? "one" : snap.repeat === "one" ? "off" : "all"
          send({ type: "set_repeat", mode: mode }); event.accepted = true; return
        }
        if (t === "n") { root.nextTrack(); event.accepted = true; return }
        if (t === "N") { root.prevTrack(); event.accepted = true; return }
        if (t === ",") { root.seekBy(-10); event.accepted = true; return }
        if (t === ".") { root.seekBy(10); event.accepted = true; return }
        if (t === "q") { root.queueTail(); event.accepted = true; return }
        if (t === "p") { root.queueHead(); event.accepted = true; return }
        if (t === "d") { root.removeQueueItem(); event.accepted = true; return }
        if (t === "f") { root.toggleFavoriteSelected(); event.accepted = true; return }
        if (t === "F") { root.toggleFavoriteNow(); event.accepted = true; return }
        if (t === "J") { root.moveQueueItem(1); event.accepted = true; return }
        if (t === "K") { root.moveQueueItem(-1); event.accepted = true; return }
        if (t === "/") { root.startFilter(); event.accepted = true; return }
        if (t === "o") { root.focusPlaying(); event.accepted = true; return }
        if (t === "H") { root.cycleTab(-1); event.accepted = true; return }
        if (t === "L") { root.cycleTab(1); event.accepted = true; return }
        if (event.key === Qt.Key_Tab && !event.isAutoRepeat) { root.cycleTab(1); event.accepted = true; return }
        // Shift+Tab arrives as Backtab, not Tab+Shift.
        if (event.key === Qt.Key_Backtab && !event.isAutoRepeat) { root.cycleTab(-1); event.accepted = true; return }
      }
    }

    Column {
      id: fullColumn
      anchors.fill: parent
      spacing: Style.space(8)

      // tabs row; the filter input temporarily takes its place while
      // filtering so the list never jumps.
      Row {
        id: tabsRow
        visible: !root.filtering
        height: Style.space(30)
        leftPadding: Style.space(16)
        rightPadding: Style.space(16)
        spacing: Style.space(10)

        Repeater {
          model: [ { id: "queue", label: "󰐑 Queue" },
                   { id: "albums", label: "󰀥 Albums" },
                   { id: "playlists", label: "󰲸 Playlists" } ]

          delegate: Rectangle {
            required property var modelData
            readonly property bool active: root.tab === modelData.id
            anchors.verticalCenter: parent.verticalCenter
            width: tabLabel.implicitWidth + Style.space(14)
            height: tabLabel.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            color: active ? Color.accent : "transparent"

            Text {
              id: tabLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: parent.modelData.label
              color: parent.active ? Color.background : Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: parent.active
            }
          }
        }

        // committed filter, shown inline so the filtered state is obvious
        Rectangle {
          visible: !root.filtering && root.filterTexts[root.tab] !== ""
          anchors.verticalCenter: parent.verticalCenter
          width: filterBadge.implicitWidth + Style.space(12)
          height: Style.space(22)
          radius: Style.cornerRadius
          color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)

          Text {
            id: filterBadge
            anchors.centerIn: parent
            textFormat: Text.PlainText
            // Truncate in JS: a fixed Text width would overflow this
            // naturally-sized pill.
            text: {
              var f = root.filterTexts[root.tab]
              return "/" + (f.length > 18 ? f.slice(0, 17) + "…" : f)
            }
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // filter input — occupies the tabs row's slot while filtering
      TextField {
        id: filterInput
        visible: root.filtering
        x: Style.space(16)
        height: tabsRow.height
        width: Style.space(300)
        placeholderText: "filter…"
        foreground: Color.foreground
        font.family: Style.font.family
        verticalAlignment: TextInput.AlignVCenter
        onVisibleChanged: if (visible) { text = root.filterTexts[root.tab] || "" ; selectAll(); forceActiveFocus() }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.commitFilter(); event.accepted = true }
          else if (event.key === Qt.Key_Escape) { root.cancelFilter(); event.accepted = true }
        }
      }

      // list; the empty-state message overlays it so the popup height
      // never depends on whether there are results.
      Item {
        width: parent.width
        height: Style.space(380)

      ListView {
        id: list
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        width: parent.width - Style.space(18)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.items
        highlight: null

        // Detail-view metadata (cover, title, artist, counts). Lives in the
        // list header so it scrolls away as you move down.
        header: root.tab !== "queue" && root.path.length >= 1 ? headerComp : null

        Component {
          id: headerComp

          Item {
            readonly property var meta: root.detailMeta()
            width: list.width
            height: Style.space(128)

            Row {
              x: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(14)

              Image {
                id: headerCover
                source: parent.parent.meta.cover || ""
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(104)
                height: Style.space(104)
                asynchronous: true
                cache: true
                sourceSize.width: 320
                sourceSize.height: 320
                fillMode: Image.PreserveAspectCrop
              }

              Column {
                anchors.bottom: headerCover.bottom
                anchors.bottomMargin: Style.space(2)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: parent.parent.parent.meta.title || ""
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                  width: Style.space(500)
                }

                Text {
                  textFormat: Text.PlainText
                  text: parent.parent.parent.meta.artist || ""
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: Style.space(500)
                }

                Text {
                  textFormat: Text.PlainText
                  text: (parent.parent.parent.meta.count || 0) + " tracks"
                        + (parent.parent.parent.meta.dur ? "  ·  " + Mock.fmt(parent.parent.parent.meta.dur) : "")
                  color: Qt.darker(Color.foreground, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // The cursor is ours, not ListView's: model resets clobber
        // currentIndex, so we scroll to the cursor manually instead. Model
        // resets also clobber contentY (every playback push recomputes the
        // list), so the scroll offset is saved/restored across them — only
        // j/k should move the list.
        property real savedY: 0
        // The model reset clobbers contentY before onItemsChanged can
        // restore it, so snapshot on a short lag instead.
        Timer { interval: 200; running: list.visible; repeat: true; onTriggered: {
            list.savedY = list.contentY
        } }

        // One-row buffer: keep the neighbours contained too, so the cursor
        // never sits flush against an edge while navigating.
        function scrollListTo(pos) {
            if (pos < 0 || list.count === 0) return
            // Near the top: pin to the very start so the detail header
            // stays in view (the one-row-buffer below would scroll past it
            // and never come back, since Contain only scrolls when the
            // target is out of view).
            var top = list.headerItem ? -list.headerItem.height : 0
            if (pos === 0) { list.contentY = top; list.savedY = top; return }
            var n = list.count
            list.positionViewAtIndex(Math.min(pos + 1, n - 1), ListView.Contain)
            list.positionViewAtIndex(Math.max(pos - 1, 0), ListView.Contain)
            list.savedY = list.contentY
        }
        Connections {
            target: root
            function onCursorPosChanged() { list.scrollListTo(root.cursorPos) }
            function onRequestScroll(pos) { list.scrollListTo(pos) }
            function onItemsChanged() { list.contentY = list.savedY }
        }
        onWidthChanged: if (root.cursorPos >= 0) positionViewAtIndex(root.cursorPos, ListView.Contain)

        delegate: Item {
          required property var modelData
          required property int index
          width: list.width
          // Pinned head gets extra breathing room; rule/section are compact.
          height: modelData.kind === "head" ? Math.max(rowImg.visible ? rowImg.height : 0, rowCol.implicitHeight) + Style.space(24)
                : modelData.kind === "sep" ? Style.space(13)
                : modelData.kind === "section" ? sectionLabel.implicitHeight + Style.space(8)
                : Math.max(rowImg.visible ? rowImg.height : 0, rowCol.implicitHeight) + Style.space(8)

          // Cursor highlight only on rows the cursor can actually sit on.
          Rectangle {
            anchors.fill: parent
            color: !root.filtering && (modelData.kind === "track" || modelData.drillable) && index === root.cursorPos ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
          }

          // Horizontal rule between the queue and the context section.
          Rectangle {
            visible: modelData.kind === "sep"
            anchors.verticalCenter: parent.verticalCenter
            x: Style.space(16)
            width: parent.width - Style.space(32)
            height: 1
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
          }

          // Context section header.
          Row {
            visible: modelData.kind === "section"
            x: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              id: sectionLabel
              textFormat: Text.PlainText
              text: modelData.title
              color: Qt.darker(Color.foreground, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
              width: Style.space(540)
            }
          }

          // Selection feedback: a short accent label on the acted-on row.
          Rectangle {
            visible: root.actionFlash !== null && root.actionFlash.raw === modelData.raw
            anchors.right: parent.right
            // Clears the heart icon (which sits at rightMargin 8).
            anchors.rightMargin: Style.space(30)
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
            width: flashLabel.implicitWidth + Style.space(12)
            height: flashLabel.implicitHeight + Style.space(4)

            Text {
              id: flashLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.actionFlash ? root.actionFlash.text : ""
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // Favorite heart: filled (accent) on favorited tracks; the
          // empty outline only shows on the cursor row to keep the list
          // clean.
          Text {
            readonly property bool isFav: root.favSet[modelData.favId] === true
            readonly property bool onCursor: index === root.cursorPos && !root.filtering
            visible: modelData.kind === "track" && (isFav || onCursor)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: isFav ? "󰋑" : "󰋕"
            color: isFav ? Color.accent : Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Row {
            id: rowCol
            visible: modelData.kind !== "sep" && modelData.kind !== "section"
            leftPadding: Style.space(8)
            rightPadding: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            // Reserved gutter: a fixed slot wide enough for the glyph plus
            // 4px padding per side. Vertical alignment comes from the row,
            // since the slot itself is deliberately height-less.
            Item {
              width: Style.space(16)
              height: 1
              Text {
                visible: modelData.playing
                y: (rowCol.height - height) / 2
                x: (parent.width - width) / 2
                textFormat: Text.PlainText
                text: "󰐌"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Image {
              id: rowImg
              visible: modelData.cover !== "" && (modelData.kind !== "track" || root.tab === "queue")
              source: modelData.cover || ""
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(44)
              height: Style.space(44)
              asynchronous: true
              cache: true
              sourceSize.width: 88
              sourceSize.height: 88
              fillMode: Image.PreserveAspectCrop
              onStatusChanged: if (status === Image.Error || status === Image.Null) console.warn("jelly: cover", status, source)
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                textFormat: Text.PlainText
                text: modelData.title
                color: modelData.playing ? Color.accent : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: modelData.playing
                elide: Text.ElideRight
                width: Style.space(560)
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.sub
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: Style.space(560)
              }
            }
          }
        }
      }

      // Scroll progress (read-only indicator, not draggable). Lives in its
      // own gutter so it never overlaps rows; progress is derived from the
      // content's actual laid-out extents rather than estimated sizes.
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

          // Qt6 contentHeight includes the header; originY is its top edge
          // (negative when a header is mounted). Content spans
          // [originY, originY + contentHeight], so the scrollable range is
          // exactly contentHeight - height — no header guesswork.
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
        visible: root.items.length === 0
        anchors.centerIn: parent
        leftPadding: Style.space(16)
        text: {
          if (!root.libraryLoaded && root.tab !== "queue") return "Loading library…"
          if (root.tab === "queue") return "Queue empty — q queues the selected song, p plays it next"
          return "No matches" + (root.filterText !== "" ? " for \u201C" + root.filterText + "\u201D — esc to clear" : " here")
        }
        color: Qt.darker(Color.foreground, 1.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      }

      // ---- Now Playing, pinned at the bottom
      Rectangle {
        id: npBar
        width: parent.width
        height: npRow.implicitHeight + Style.space(12)
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)

        // Width available to the text/progress column: bar minus its own
        // padding, minus the cover and the gap between them.
        readonly property real contentW:
          width - Style.space(16 + 16 + 12) - (nowCover.visible ? nowCover.width : 0)

        Row {
          id: npRow
          x: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Image {
            id: nowCover
            visible: root.nowCover !== ""
            source: root.nowCover
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(52)
            height: Style.space(52)
            asynchronous: true
            cache: true
            sourceSize.width: 320
            sourceSize.height: 320
            fillMode: Image.PreserveAspectCrop
          }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              width: npBar.contentW

              Item {
                width: parent.width
                height: npHeadCol.implicitHeight

                Column {
                  id: npHeadCol
                  spacing: Style.space(4)
                  width: parent.width - (npControls.visible ? npControls.width + Style.space(12) : 0)

                  Text {
                    textFormat: Text.PlainText
                    text: root.now.name
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.now.album || ""
                    color: Qt.darker(Color.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Row {
                  id: npControls
                  visible: root.connected
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    text: root.playing ? "󰏤" : "󰐊"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "󰒝"
                    color: root.snap.shuffle ? Color.accent : Qt.darker(Color.foreground, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.snap.repeat === "one" ? "󰑘" : "󰑖"
                    color: root.snap.repeat === "off" ? Qt.darker(Color.foreground, 1.6) : Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                  }
                }
              }

            Rectangle {
              width: parent.width
              height: Style.space(5)
              radius: height / 2
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)

              Rectangle {
                width: Math.round(parent.width * (root.duration > 0 ? root.position / root.duration : 0))
                height: parent.height
                radius: parent.radius
                color: Color.accent
              }
            }

            Item {
              width: parent.width
              height: posTime.implicitHeight

              Text {
                id: posTime
                textFormat: Text.PlainText
                anchors.left: parent.left
                text: Mock.fmt(root.position)
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.connected ? Mock.fmt(root.duration) : "offline"
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // hint bar
      Text {
        textFormat: Text.PlainText
        leftPadding: Style.space(16)
        rightPadding: Style.space(16)
        width: parent.width
        text: root.hints
        color: Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
