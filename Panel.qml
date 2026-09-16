// Jelly full-view popup wired to the live daemon (v0 ad-hoc jelly-ipc).
// Single source of truth: the daemon's pushed PlaybackSnapshot.
// The UI keeps no playback state — only a navigation cursor, which starts
// at the top of every view; o jumps to the playing track.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Util.js" as Util

Panel {
  id: root
  moduleName: "eddie.jelly"
  ipcTarget: "eddie.jelly"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property string debugInstance: Math.random().toString(36).slice(2, 8)
  // Temporary test seam: inject a key through the same router used by the
  // real keyboard path, without depending on compositor focus.
  function injectKey(name) {
    var keys = {
      "Enter": Qt.Key_Return,
      "Return": Qt.Key_Return,
      "Escape": Qt.Key_Escape,
      "Up": Qt.Key_Up,
      "Down": Qt.Key_Down,
      "Left": Qt.Key_Left,
      "Right": Qt.Key_Right,
      "Space": Qt.Key_Space
    }
    var key = keys[name] !== undefined ? keys[name] : 0
    var text = name.length === 1 ? name : ""
    panel.handleGlobalKey({ key: key, text: text, isAutoRepeat: false, accepted: false })
  }
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
  // The playing song's own cover (each context track carries its
  // album's image_url), falling back to the album lookup.
  readonly property string nowCover:
    now.image_url || coverByAlbum(now.album)

  // ---- browse library, built live from the daemon's browse IPC:
  //      artists -> albums -> tracks, playlists -> playlist tracks.
  //      Albums/playlists are fetched up front; tracks load in the
  //      background so drills usually open already populated.
  property var albumList: []
  property var playlistList: []
  readonly property var library: ({
    albums: albumList,
    playlists: [{ name: "Playlists", items: playlistList }]
  })

  // req_id -> request descriptor, so browse replies can be routed.
  property var pending: ({})
  property int reqSeq: 1
  property int awaitingArtists: 0
  property int awaitingAlbums: 0
  // One fetch at a time: reconnects must not cancel in-flight requests
  // (the socket churns; each refresh used to wipe `pending` mid-flight).
  property bool libraryFetching: false
  property string lastAuthStatus: ""

  function browse(kind, extra) {
    var id = reqSeq++
    var o = { type: kind, req_id: id }
    for (var k in extra) o[k] = extra[k]
    pending[id] = { kind: kind, extra: extra }
    send(o)
  }

  function refreshLibrary() {
    if (!connected) return
    if (snap.auth !== "authenticated") return
    if (libraryFetching) return
    if (albumList.length > 0 || playlistList.length > 0) return
    libraryFetching = true
    albumList = []
    playlistList = []
    awaitingArtists = 0
    awaitingAlbums = 0
    pending = ({})
    browse("browse_artists", {})
    browse("browse_playlists", {})
  }

  function onBrowse(msg) {
    var req = pending[msg.req_id]
    if (!req) return
    var items = msg.items || []
    if (req.kind === "browse_artists") {
      delete pending[msg.req_id]
      awaitingArtists = items.length
      if (items.length === 0) { awaitingAlbums = 0; return }
      for (var i = 0; i < items.length; i++) browse("browse_albums", { artist_id: items[i].id })
    } else if (req.kind === "browse_albums") {
      delete pending[msg.req_id]
      var acc = albumList.slice()
      for (var j = 0; j < items.length; j++) {
        var it = items[j]
        acc.push({ id: it.id, title: it.name, artist: it.detail || "", cover: it.image_url || "", tracks: [] })
      }
      acc.sort(function(a, b) { return a.title.toLowerCase() < b.title.toLowerCase() ? -1 : 1 })
      albumList = acc
      awaitingArtists = Math.max(0, awaitingArtists - 1)
      if (awaitingArtists === 0) {
        awaitingAlbums = acc.length
        warmCovers()
        // Background: fill in each album's tracks for counts + drills.
        for (var k = 0; k < acc.length; k++) browse("browse_tracks", { album_id: acc[k].id })
      }
    } else if (req.kind === "browse_tracks") {
      delete pending[msg.req_id]
      var albumId = req.extra.album_id
      var next = albumList.slice()
      for (var m = 0; m < next.length; m++) {
        if (next[m].id !== albumId) continue
        next[m] = {
          id: next[m].id, title: next[m].title, artist: next[m].artist, cover: next[m].cover,
          tracks: items.map(function(x) {
            return { id: x.id, title: x.name, artist: x.detail || next[m].artist,
                     length: x.duration_secs || 0 }
          })
        }
        break
      }
      albumList = next
      awaitingAlbums = Math.max(0, awaitingAlbums - 1)
      if (awaitingArtists === 0 && awaitingAlbums === 0) libraryFetching = false
    } else if (req.kind === "browse_playlists") {
      delete pending[msg.req_id]
      playlistList = items.map(function(x) {
        return { type: "Playlist", id: x.id, title: x.name, artist: "", cover: x.image_url || "", tracks: [] }
      })
      warmCovers()
      for (var p = 0; p < items.length; p++) browse("browse_playlist_tracks", { playlist_id: items[p].id })
    } else if (req.kind === "browse_playlist_tracks") {
      delete pending[msg.req_id]
      var playlistId = req.extra.playlist_id
      var pls = playlistList.slice()
      for (var q = 0; q < pls.length; q++) {
        if (pls[q].id !== playlistId) continue
        pls[q] = {
          type: "Playlist", id: pls[q].id, title: pls[q].title, artist: pls[q].artist, cover: pls[q].cover,
          tracks: items.filter(function(x) {
            return (x.item_type || "").indexOf("Playlist") < 0
          }).map(function(x) {
            return { id: x.id, title: x.name, artist: x.detail || "", length: x.duration_secs || 0 }
          })
        }
        break
      }
      playlistList = pls
    }
  }

  // Cover for a track id: find which library album owns it.
  function coverForTrackId(id) {
    if (!id) return ""
    for (var i = 0; i < albumList.length; i++) {
      var trs = albumList[i].tracks || []
      for (var j = 0; j < trs.length; j++) {
        if (trs[j].id === id) return coverFor(albumList[i])
      }
    }
    return ""
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

  // ---- navigation state (cursor/filtering/scrolling live in List)
  property string tab: "albums"
  property var viewStates: ({})

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
              console.info("jelly: state push: ctx", msg.context ? ((msg.context.tracks || []).length + " tracks") : "NONE",
                           "q", (msg.queue || []).length, "shuffle", msg.shuffle,
                           "cur", msg.context ? msg.context.current_index : "?")
            } else if (msg.type === "position") {
              root.position = msg.position_secs
            } else if (msg.type === "browse") {
              root.onBrowse(msg)
            } else if (msg.type === "error") {
              console.warn("jelly daemon error:", msg.message)
            }
          } catch (e) { console.warn("jelly: bad line", e) }
        }
      }
      onConnectedChanged: {
        console.info("jelly: socket connected =", connected)
        if (connected) Qt.callLater(function() { root.send({ type: "get_state" }); root.refreshLibrary() })
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

  // ---- List tabs. List owns cursor, filtering and scrolling; the panel
  //      supplies rows, actions, and tab state.
  property string openAlbumId: ""
  property string playbackAlbumId: ""
  onOpenAlbumIdChanged: {
    console.info("jelly: album changed", openAlbumId)
    // The "reopen the playing album" convenience applies only while on
    // the albums tab; during a tab switch restoreViewState clears
    // openAlbumId for the OTHER views and must not be overwritten here
    // (the queue/commands lists would otherwise inherit a phantom album:
    // 40-tall rows with 44-tall covers overflowing them).
    if (tab === "albums" && openAlbumId === "" && playbackAlbumId !== "")
      openAlbumId = playbackAlbumId
  }

  // Per-view state (cursor + filter + drilled album), so each
  // tab keeps its own position when you switch back and forth.
  function saveViewState() {
    console.info("jelly: save view", tab, "cursor", mainList.cursorPos, "raw", String(mainList.lastRaw))
    var m = viewStates
    m[tab] = { cursor: mainList.cursorPos, raw: mainList.lastRaw,
               filter: mainList.filterText, albumId: openAlbumId,
               contentY: mainList.scrollOffset() }
    viewStates = m
  }
  function restoreViewState() {
    var st = viewStates[tab]
    console.info("jelly: restore view", tab, st ? "cursor " + String(st.cursor) + " raw " + String(st.raw) : "empty state")
    openAlbumId = st ? (st.albumId || "") : ""
    mainList.filterText = st ? (st.filter || "") : ""
    mainList.cursorPos = st ? (st.cursor || 0) : 0
    mainList.lastRaw = st ? (st.raw !== undefined ? st.raw : -1) : -1
    // Restore the exact scroll offset, not a recomputed one: no flash at
    // the top, no partial scroll to the cursor.
    if (st && st.contentY !== undefined && st.contentY >= 0) mainList.scrollToOffset(st.contentY)
    else mainList.resetCursor()
  }

  // Metadata for the drilled album view (MetaHeader).
  readonly property var headerAlbum: {
    if (tab !== "albums" || openAlbumId === "") return ({})
    for (var i = 0; i < albumList.length; i++) {
      var al = albumList[i]
      if (al.id !== openAlbumId) continue
      var dur = 0
      var trs = al.tracks || []
      for (var j = 0; j < trs.length; j++) dur += trs[j].length || 0
      return { title: al.title, artist: al.artist, cover: al.cover,
               count: trs.length, dur: dur }
    }
    return ({})
  }

  // Transient feedback for row actions.
  property var rowFlash: null
  Timer { id: rowFlashTimer; interval: 1400; onTriggered: root.rowFlash = null }

  function albumMetas(al) {
    return (al.tracks || []).map(function(t) {
      return { id: t.id, name: t.title, artist: t.artist || "", album: al.title,
               duration_secs: t.length || null, image_url: al.cover || null, stream_url: "" }
    })
  }

  function viewRows() {
    if (tab === "queue") {
      var out = []
      var ctxCover = (snap.context && snap.context.image_url) || ""
      var waiting = snap.queue || []
      for (var i = 0; i < waiting.length; i++) {
        var q = waiting[i]
        out.push({ raw: "q:" + q.id, trackId: q.id, queueIndex: i, title: q.name,
                   artist: q.artist || "", durationSecs: q.duration_secs || null,
                   sub: (q.artist || "") + (q.duration_secs ? "  ·  " + Util.fmt(q.duration_secs) : ""),
                   cover: coverByAlbum(q.album) || coverForTrackId(q.id) || q.image_url || "",
                   showCover: true, showGlyph: false, showFav: true, playing: false,
                   section: "" })
      }
      var ctx = snap.context
      if (ctx) {
        var tracks = ctx.tracks || []
        var cur = (ctx.current_index !== null && ctx.current_index !== undefined) ? ctx.current_index : -1
        function ctxRow(t, idx, sectionName) {
          return { raw: "c:" + t.id, trackId: t.id, ctxIndex: idx, metas: tracks,
                   artist: t.artist || "", durationSecs: t.duration_secs || null,
                   title: t.name,
                   sub: (t.artist || "") + (t.duration_secs ? "  ·  " + Util.fmt(t.duration_secs) : ""),
                   cover: (ctx.image_url || ""), showCover: true, showGlyph: false, showFav: true,
                   playing: t.id === root.now.id && !root.snap.queue_head,
                   section: sectionName }
        }
        // Remaining tracks only (the playing track is the now-playing
        // bar, not a row)...
        for (var j = cur + 1; j < tracks.length; j++) out.push(ctxRow(tracks[j], j, ctx.name))
        // ...then, under repeat-all, the already-played ones wrap around,
        // in their own section so the wrap point is visible.
        if (snap.repeat === "all" && cur > 0) {
          // The already-played tracks wrap around; the current song is not
          // repeated here (it is what plays next).
          for (var k = 0; k < cur && k < tracks.length; k++) {
            out.push(ctxRow(tracks[k], k, ctx.name))
          }
        }
      }
      return out
    }
    if (tab === "albums") {
      if (openAlbumId === "") {
        return albumList.map(function(al) {
          return { raw: al.id, albumId: al.id, isAlbum: true, title: al.title,
                   sub: (al.artist || "") + "  ·  " + (al.tracks || []).length + " tracks",
                   cover: coverFor(al), showCover: true, showGlyph: true,
                   playing: nowCtx && nowCtx.name === al.title,
                   section: "" }
        })
      }
      var al = null
      for (var k = 0; k < albumList.length; k++) if (albumList[k].id === openAlbumId) al = albumList[k]
      if (!al) return []
      return (al.tracks || []).map(function(t, idx) {
        return { raw: t.id, trackId: t.id, title: t.title, artist: t.artist || "",
                 durationSecs: t.length || null,
                 sub: (t.artist || "") + (t.length ? "  ·  " + Util.fmt(t.length) : ""),
                 cover: al.cover, playing: t.id === now.id, section: "",
                 ctxIndex: idx, metas: albumMetas(al) }
      })
    }
    if (tab === "commands") {
      return commands.map(function(c) {
        return { raw: c.key, key: c.key, desc: c.desc, section: "" }
      })
    }
    return []
  }

  function activateRow(item) {
    if (!item) return
    console.info("jelly: activate", tab, "album", openAlbumId,
                 "raw", item.raw, "ctx", item.ctxIndex,
                 "queue", item.queueIndex, "cursor", mainList.cursorPos)
    if (tab === "albums") {
      if (item.isAlbum) {
        // Enter plays the album from the start (the daemon's shuffle
        // order applies from there); l opens it.
        var al = null
        for (var i = 0; i < albumList.length; i++) if (albumList[i].id === item.albumId) al = albumList[i]
        if (al) startPlayback(albumMetas(al), 0)
        return
      }
      if (item.metas) {
        playbackAlbumId = openAlbumId
        startPlayback(item.metas, item.ctxIndex || 0)
        return
      }
    }
    if (tab === "queue") {
      if (item.queueIndex !== undefined && item.queueIndex !== null) {
        // jump_to consumes this item and everything before it. After the
        // model update, focus the first remaining queue row; album/context
        // activation below must not move the scroll at all.
        mainList.pendingJumpPrefix = "q:"
        mainList.jumpCursor(0)
        send({ type: "jump_to", index: item.queueIndex }); return
      }
      if (item.ctxIndex !== undefined && item.ctxIndex !== null && item.metas) {
        startPlayback(item.metas, item.ctxIndex); return
      }
    }
  }

  // Guard rails for row actions: duplicate-queue guard, offline
  // guard for favorites, and a transient message on the acted-on row.
  function rowAction(action, item) {
    if (!item || !item.trackId) return
    if (action === "favorite") {
      if (!connected) { flashRow(item.raw, "offline — favorites need a daemon connection"); return }
      send({ type: "toggle_favorite", item_id: item.trackId })
      flashRow(item.raw, favSet[item.trackId] ? "unfavorited" : "favorited")
      return
    }
    if (queuedIds()[item.trackId]) { flashRow(item.raw, "already queued"); return }
    var meta = { id: item.trackId, name: item.title, artist: item.artist || "",
                 album: "", duration_secs: item.durationSecs || null,
                 image_url: item.cover || "", stream_url: "" }
    if (action === "queue") {
      send({ type: "enqueue", items: [meta] })
      flashRow(item.raw, "queued")
    } else if (action === "next") {
      send({ type: "play_next", item: meta })
      flashRow(item.raw, "play next")
    }
  }

  // Row-level keys List doesn't consume (q/p/f/d/J/K), dispatched to the
  // actions above.
  function flashRow(raw, text) {
    rowFlash = { raw: raw, text: text }
    rowFlashTimer.restart()
  }

  function handleRowKey(event) {
    var t = event.text
    var item = mainList.cursorItem
    if (!item) return false
    if (t === "q") { rowAction("queue", item); return true }
    if (t === "p") { rowAction("next", item); return true }
    if (t === "f") { rowAction("favorite", item); return true }
    var inQueue = item.queueIndex !== undefined && item.queueIndex !== null
    if (t === "d" && inQueue) {
      send({ type: "remove_from_queue", index: item.queueIndex }); return true
    }
    if (t === "J" && inQueue) {
      send({ type: "move_queue", index: item.queueIndex, delta: 1 })
      mainList.moveWithItem(1)
      return true
    }
    if (t === "K" && inQueue) {
      send({ type: "move_queue", index: item.queueIndex, delta: -1 })
      mainList.moveWithItem(-1)
      return true
    }
    return false
  }

  function focusPlayingRow() {
    var rows = viewRows()
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].trackId !== undefined && rows[i].trackId === now.id) {
        mainList.jumpCursor(i)
        return
      }
    }
  }

  Timer {
    id: postDrillFocusTimer
    interval: 120
    onTriggered: keyFocus.forceActiveFocus()
  }

  function drillBack() {
    if (tab === "albums" && openAlbumId !== "") {
      var cameFrom = openAlbumId
      playbackAlbumId = ""
      mainList.beginViewReset()
      openAlbumId = ""
      // Land back on the album we came from (cursor + scroll).
      Qt.callLater(function() { mainList.focusRaw(cameFrom, 0) })
      return true
    }
    return false
  }

  // Cycle tabs in display order; [ goes left, ] goes right, wrapping.
  function cycleTab(dir) {
    var order = ["queue", "albums", "commands"]
    var next = (order.indexOf(tab) + dir + order.length) % order.length
    switchTab(order[next])
  }

  function switchTab(t) {
    saveViewState()
    if (t === tab) {
      if (t === "albums" && openAlbumId !== "") openAlbumId = ""
      mainList.resetCursor()
      return
    }
    tab = t
    restoreViewState()
    keyFocus.forceActiveFocus()
  }

  // Start a (re)selection: loading a fresh context resets repeat-one to
  // plain repeat — nobody wants one song looping forever after picking a
  // new album.
  function startPlayback(tracks, startIndex) {
    send({ type: "play", tracks: tracks, start_index: startIndex })
    if (snap.repeat === "one") send({ type: "set_repeat", mode: "off" })
  }

  // ---- command palette (?): every keybind, filterable. One filter char
  //      matches keybinds; multiple chars match descriptions.
  property bool paletteOpen: false
  property bool paletteFiltering: false
  property int paletteCursor: 0

  readonly property var commands: [
    { key: "j", desc: "Move cursor down" },
    { key: "k", desc: "Move cursor up" },
    { key: "Enter", desc: "Play selection (album/playlist from start)" },
    { key: "l", desc: "Into view (drill)" },
    { key: "h", desc: "Out of view / close" },
    { key: "Esc", desc: "Clear filter / out of view / close" },
    { key: "Tab", desc: "Next tab" },
    { key: "Shift+Tab", desc: "Previous tab" },
    { key: "H", desc: "Previous tab" },
    { key: "L", desc: "Next tab" },
    { key: "g", desc: "Jump to top of list" },
    { key: "G", desc: "Jump to bottom of list" },
    { key: "o", desc: "Focus the playing row" },
    { key: "/", desc: "Filter the current view" },
    { key: "q", desc: "Queue selection at tail of queue" },
    { key: "p", desc: "Queue selection to play next (head)" },
    { key: "d", desc: "Remove selected queue item" },
    { key: "J", desc: "Move queue item down" },
    { key: "K", desc: "Move queue item up" },
    { key: "f", desc: "Toggle favorite on selection" },
    { key: "F", desc: "Toggle favorite on playing song" },
    { key: "s", desc: "Toggle shuffle" },
    { key: "r", desc: "Cycle repeat off / all / one" },
    { key: "n", desc: "Next track" },
    { key: "N", desc: "Previous track" },
    { key: "Space", desc: "Play / pause" },
    { key: ",", desc: "Seek back 10s" },
    { key: ".", desc: "Seek forward 10s" },
    { key: "?", desc: "Command palette" }
  ]

  readonly property var paletteItems: {
    var f = paletteFilter.toLowerCase()
    if (f === "") return commands
    if (f.length === 1)
      return commands.filter(function(c) { return c.key.toLowerCase().indexOf(f) >= 0 })
    return commands.filter(function(c) { return c.desc.toLowerCase().indexOf(f) >= 0 })
  }
  onPaletteItemsChanged:
    paletteCursor = Math.max(0, Math.min(paletteCursor, paletteItems.length - 1))

  property string paletteFilter: ""

  function openPalette() {
    paletteOpen = true
    paletteFiltering = false
    paletteFilter = ""
    paletteCursor = 0
    Qt.callLater(function() { paletteModal.forceActiveFocus() })
  }

  function closePalette() {
    paletteOpen = false
    paletteFiltering = false
    Qt.callLater(function() { keyFocus.forceActiveFocus() })
  }

  function togglePlay() { send({ type: "toggle_play" }) }
  function skip(dir) { send(dir > 0 ? { type: "next" } : { type: "prev" }) }
  function nextTrack() { skip(1) }
  function prevTrack() { skip(-1) }
  // Seeking clamps at the edges of the current song; the bar fill caps.
  function seekBy(d) {
    if (duration > 0) {
      send({ type: "seek", position_secs: Math.max(0, Math.min(duration - 0.5, position + d)) })
      return
    }
    send({ type: "seek", position_secs: Math.max(0, position + d) })
  }

  // ---- queue/favorite actions used by List rows.
  function queuedIds() {
    var ids = {}
    if (snap.queue_head) ids[snap.queue_head.id] = true
    var w = snap.queue || []
    for (var i = 0; i < w.length; i++) ids[w[i].id] = true
    return ids
  }

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
      if (flashRaw !== undefined) flashRow(flashRaw, "offline — favorites need a daemon connection")
      return
    }
    send({ type: "toggle_favorite", item_id: id })
    if (flashRaw !== undefined) flashRow(flashRaw, favSet[id] ? "unfavorited" : "favorited")
  }

  function toggleFavoriteNow() {
    toggleFavoriteId(now.id, undefined)
  }

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function injectKeys() {
    Qt.callLater(function() { if (!paletteOpen) keyFocus.forceActiveFocus() })
  }

  // ---- library load
  // Library arrives over the socket (browse IPC); refresh when auth
  // becomes available and after each reconnect.
  onSnapChanged: {
    if (tab === "albums" && playbackAlbumId !== "" && openAlbumId === "")
      openAlbumId = playbackAlbumId
    if (snap.auth !== lastAuthStatus) {
      lastAuthStatus = snap.auth || ""
      // A pre-login browse can fail and leave the in-flight guard set.
      // Authentication is the boundary at which those requests are stale.
      if (lastAuthStatus === "authenticated") libraryFetching = false
    }
    if (snap.auth === "authenticated" && albumList.length === 0 && playlistList.length === 0)
      refreshLibrary()
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
    contentHeight: panel.fittedContentHeight(fullColumn.implicitHeight)

    onOpenChanged: if (open) injectKeys()

    FocusScope {
      id: keyFocus
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) { panel.handleGlobalKey(event) }
    }

    // Handles every panel-level key. List offers it the keys it did not
    // consume, so global bindings keep working on every tab.
    function handleGlobalKey(event) {
        if (root.paletteOpen) { event.accepted = true; return }
        if (mainList.handleKey(event)) { event.accepted = true; return }
        if (root.handleRowKey(event)) { event.accepted = true; return }
        var t = event.text
        // No key repeat on transport keys: held n/N would queue a burst of
        // cold network fetches in mpv. j/k and ,/. keep their repeat.
        var transport = t === "n" || t === "N" || event.key === Qt.Key_Space
        if (transport && event.isAutoRepeat) { event.accepted = true; return }
        if (event.key === Qt.Key_Escape) {
          root.close(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Left || t === "h") { root.close(); event.accepted = true; return }
        if (event.key === Qt.Key_Space) { root.togglePlay(); event.accepted = true; return }
        if (t === "s") {
          send({ type: "set_shuffle", on: !(snap.shuffle) })
          // The queue never shuffles: a queue-row cursor stays put. A
          // context-row cursor jumps to the top of the context on the
          // next push; no id tracking in either case.
          var lr = typeof mainList.lastRaw === "string" ? mainList.lastRaw : ""
          if (lr.indexOf("q:") !== 0) mainList.pendingJumpPrefix = "c:"
          event.accepted = true
          return
        }
        if (t === "r") {
          var mode = snap.repeat === "all" ? "one" : snap.repeat === "one" ? "off" : "all"
          send({ type: "set_repeat", mode: mode }); event.accepted = true; return
        }
        if (t === "n") { root.nextTrack(); event.accepted = true; return }
        if (t === "N") { root.prevTrack(); event.accepted = true; return }
        if (t === "," && !event.isAutoRepeat) { root.seekBy(-10); event.accepted = true; return }
        if (t === "." && !event.isAutoRepeat) { root.seekBy(10); event.accepted = true; return }
        if (t === "F") { root.toggleFavoriteNow(); event.accepted = true; return }
        if (t === "?") { root.openPalette(); event.accepted = true; return }
        if (t === "H") { root.cycleTab(-1); event.accepted = true; return }
        if (t === "L") { root.cycleTab(1); event.accepted = true; return }
        if (event.key === Qt.Key_Tab && !event.isAutoRepeat) { root.cycleTab(1); event.accepted = true; return }
        // Shift+Tab arrives as Backtab, not Tab+Shift.
        if (event.key === Qt.Key_Backtab && !event.isAutoRepeat) { root.cycleTab(-1); event.accepted = true; return }
    }

    Column {
      id: fullColumn
      anchors.fill: parent
      spacing: Style.space(8)

      // ---- Now Playing: the reading order is Now Playing -> tabs -> list
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
                width: Math.min(parent.width, Math.round(parent.width * (root.duration > 0 ? root.position / root.duration : 0)))
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
                text: Util.fmt(root.position)
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.connected ? Util.fmt(root.duration) : "offline"
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }


      // Tabs. Filtering belongs to List, so this row is always stable.
      Row {
        id: tabsRow
        height: Style.space(30)
        leftPadding: Style.space(16)
        rightPadding: Style.space(16)
        spacing: Style.space(10)

        Repeater {
          model: [ { id: "queue", label: "󰐑 Queue" },
                    { id: "albums", label: "󰀥 Albums" },
                    { id: "commands", label: "Commands" } ]

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
      }

      // list; the empty-state message overlays it so the popup height
      // never depends on whether there are results.
      Item {
        width: parent.width
        height: Style.space(380)

      Component { id: trackRowComp; TrackRow {} }
      Component { id: commandRowComp; CommandRow {} }

      // Queue header: a fixed "Up next" strip above the list, only while
      // there are queued rows. A known-height header (like MetaHeader)
      // keeps the exact scroll math clean; the queue rows group starts
      // directly under it.
      Component {
        id: queueHeaderComp
        Item {
          implicitHeight: Style.space(28)
          height: implicitHeight
          Text {
            x: Style.space(16)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            textFormat: Text.PlainText
            text: "Up next"
            color: Qt.darker(Color.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }

      Component {
        id: headerComp
        MetaHeader { info: root.headerAlbum }
      }

      // ---- Main list (see List.qml)
      List {
        id: mainList
        debugName: root.debugInstance + ":" + root.tab + "/" + root.openAlbumId
        anchors.fill: parent
        rows: root.viewRows()
        filterable: root.tab !== "queue"
        filterFn: root.tab === "commands" ? Util.filterByKeyOrDesc : Util.filterByTitleOrArtist
        // Delegate + its height travel together: commands get the compact
        // keybind row; track lists get the media row (cover rows 56 tall,
        // drill rows 40).
        rowDelegate: root.tab === "commands"
          ? commandRowComp : trackRowComp
        rowHeight: root.tab === "commands"
          ? Style.space(32)
          : (root.openAlbumId !== "" ? Style.space(40) : Style.space(56))
        // Queue strips ("Up next", context name) are half-height.
        secHeight: root.tab === "queue" ? Style.space(28) : Style.space(56)
        reversed: false
        flash: root.rowFlash
        favSet: root.favSet
        headerComponent: root.tab === "queue"
          ? (root.snap.queue && root.snap.queue.length > 0 ? queueHeaderComp : null)
          : (root.tab === "albums" && root.openAlbumId !== "" ? headerComp : null)
        headerHeight: root.tab === "queue"
          ? (root.snap.queue && root.snap.queue.length > 0 ? Style.space(28) : 0)
          : (root.tab === "albums" && root.openAlbumId !== "" ? Style.space(128) : 0)
        // While the library streams in, each album batch reorders the
        // title-sorted rows; the identity remap would drift the cursor.
        suppressRemap: root.libraryFetching
        emptyText: root.tab === "queue"
          ? "Queue empty — q queues the selected song, p plays it next"
          : (root.tab === "albums" && albumList.length === 0 ? "Loading library…" : "Nothing here")
        focusPlayingHook: function() { root.focusPlayingRow() }
        backHook: function() { return root.drillBack() }
        drillHook: function() {
          var it = mainList.cursorItem
          if (root.tab === "albums" && it && it.isAlbum) {
            root.playbackAlbumId = ""
            mainList.beginViewReset()
            root.openAlbumId = it.albumId
              Qt.callLater(function() {
                mainList.resetCursor()
                Qt.callLater(function() {
                  keyFocus.focus = true
                  keyFocus.forceActiveFocus()
                  postDrillFocusTimer.restart()
                })
              })
            return true
          }
          return false
        }
        onActivated: item => root.activateRow(item)
        onActionTriggered: (action, item) => root.rowAction(action, item)
      }

      }

      // command palette: dims the panel and floats a navigable list of
      // every keybind. "/" switches to filter mode (input focused); Esc
      // leaves filter mode; Esc/h in navigate mode closes.
      Rectangle {
        anchors.fill: parent
        visible: root.paletteOpen
        color: Qt.rgba(0, 0, 0, 0.55)

        Rectangle {
          id: paletteModal

          anchors.centerIn: parent
          width: parent.width - Style.space(96)
          height: Style.space(440)
          radius: Style.cornerRadius
          color: Color.popups.background
          border.width: Math.max(1, Style.space(1))
          border.color: Color.popups.border

          Keys.onPressed: function(event) {
            var t = event.text
            if (event.key === Qt.Key_Escape || t === "h") { root.closePalette(); event.accepted = true; return }
            if (event.key === Qt.Key_Down || t === "j") { root.paletteCursor = Math.min(root.paletteItems.length - 1, root.paletteCursor + 1); event.accepted = true; return }
            if (event.key === Qt.Key_Up || t === "k") { root.paletteCursor = Math.max(0, root.paletteCursor - 1); event.accepted = true; return }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.closePalette(); event.accepted = true; return }
            if (t === "/") {
              root.paletteFiltering = true
              Qt.callLater(function() { paletteInput.forceActiveFocus() })
              event.accepted = true
              return
            }
          }

          onFocusChanged: if (!focus && visible && !root.paletteFiltering) forceActiveFocus()

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            // Filter mode input; the dimmed "/" prompt takes its place in
            // navigate mode, same as the main views.
            TextField {
              id: paletteInput
              visible: root.paletteFiltering
              width: parent.width
              height: tabsRow.height
              placeholderText: "filter commands…"
              foreground: Color.foreground
              onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
              onTextChanged: root.paletteFilter = text
              Keys.onPressed: function(event) {
                // In filter mode: Esc clears the text first, then a second
                // Esc exits back to navigate mode. Enter commits (and the
                // cursor restarts at the first match). Focus moves
                // synchronously so keys can never fall between the two
                // modes and get swallowed.
                if (event.key === Qt.Key_Escape) {
                  root.paletteFiltering = false
                  root.paletteFilter = ""
                  paletteModal.forceActiveFocus()
                  event.accepted = true
                  return
                }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  // Commit the filter: start at the first match.
                  root.paletteFiltering = false
                  root.paletteCursor = 0
                  paletteModal.forceActiveFocus()
                  event.accepted = true
                  return
                }
              }
            }

            Item {
              visible: !root.paletteFiltering
              width: parent.width
              height: tabsRow.height

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "/ filter commands"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            ListView {
              width: parent.width
              height: parent.height - tabsRow.height - Style.space(8)
              clip: true
              model: root.paletteItems
              currentIndex: root.paletteCursor
              boundsBehavior: Flickable.StopAtBounds

              delegate: Item {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: commandText.implicitHeight + Style.space(10)

                Rectangle {
                  anchors.fill: parent
                  color: !root.paletteFiltering && index === root.paletteCursor ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
                }

                Row {
                  x: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(14)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.key
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    width: Style.space(96)
                  }

                  Text {
                    id: commandText
                    textFormat: Text.PlainText
                    text: modelData.desc
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: Style.space(400)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
