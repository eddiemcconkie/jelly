// Jelly full-view popup wired to the live daemon (v0 ad-hoc jelly-ipc).
// Single source of truth: the daemon's pushed PlaybackSnapshot.
// The UI keeps no playback state — only a navigation cursor, which starts
// at the top of every view; o jumps to the playing track.
import QtQuick
import QtQuick.Layouts
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
      "Space": Qt.Key_Space
    }
    var key = keys[name] !== undefined ? keys[name] : 0
    var text = name.length === 1 ? name : ""
    var ev = { key: key, text: text, isAutoRepeat: false, accepted: false }
    // Mirror the real focus path: while a modal is open keys land on the
    // modal router, not the panel router.
    if (deleteConfirmOpen) handleDeleteConfirmKey(ev)
    else if (mixModalOpen) handleMixModalKey(ev)
    else if (paletteOpen) handlePaletteKey(ev)
    else panel.handleGlobalKey(ev)
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
  // Mix names are the union of the daemon's aggregated tag list and every
  // tag present on the (optimistically-updated) album list, so a new mix
  // shows before the round-trip and a removed one disappears at once.
  readonly property var mixList: uniqueNames((snap.mixes || []).concat(allAlbumTags()))

  // req_id -> request descriptor, so browse replies can be routed.
  property var pending: ({})
  property int reqSeq: 1
  // Track-list drills already answered (album id -> tracks), so a drill
  // back and forth never refetches.
  property var tracksLoaded: ({})
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
    tracksLoaded = {}
    pending = ({})
    browse("browse_albums", {})
    browse("browse_playlists", {})
  }

  function onBrowse(msg) {
    var req = pending[msg.req_id]
    if (!req) return
    var items = msg.items || []
    delete pending[msg.req_id]
    if (req.kind === "browse_albums") {
      var acc = items.map(function(x) {
        return { id: x.id, title: x.name, artist: x.detail || "", cover: x.image_url || "", tags: x.tags || [], year: x.year || 0, tracks: [] }
      })
      // The server's SortName is franchise-edited on this server; sort by
      // plain album title here so the overview is alphabetical regardless.
      acc.sort(function(a, b) { return a.title.toLowerCase() < b.title.toLowerCase() ? -1 : 1 })
      albumList = acc
      libraryFetching = false
      warmCovers()
    } else if (req.kind === "browse_tracks") {
      var albumId = req.extra.album_id
      tracksLoaded[albumId] = true
      var next = albumList.slice()
      for (var m = 0; m < next.length; m++) {
        if (next[m].id !== albumId) continue
        next[m] = {
          id: next[m].id, title: next[m].title, artist: next[m].artist, cover: next[m].cover, tags: next[m].tags || [], year: next[m].year || 0,
          tracks: items.map(function(x) {
            return { id: x.id, title: x.name, artist: x.detail || next[m].artist,
                     length: x.duration_secs || 0 }
          })
        }
        break
      }
      albumList = next
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
              if (msg.context) root.pendingAlbumPlayRaw = ""
              console.info("jelly: state push: ctx", msg.context ? ((msg.context.tracks || []).length + " tracks") : "NONE",
                           "q", (msg.queue || []).length, "shuffle", msg.shuffle,
                           "cur", msg.context ? msg.context.current_index : "?")
            } else if (msg.type === "position") {
              root.position = msg.position_secs
            } else if (msg.type === "browse") {
              root.onBrowse(msg)
            } else if (msg.type === "tag_update") {
              root.applyTagUpdate(msg.album_id, msg.tags || [], msg.req_id)
            } else if (msg.type === "error") {
              console.warn("jelly daemon error:", msg.message)
              var tagReq = root.pendingTagReqs[msg.req_id]
              if (tagReq && root.pendingTagReqsByAlbum[tagReq.albumId] === msg.req_id) {
                root.applyAlbumTags(tagReq.albumId, tagReq.prevTags || [])
                delete root.pendingTagReqsByAlbum[tagReq.albumId]
                delete root.pendingTagReqs[msg.req_id]
                root.tickMixBatch(msg.req_id, true)
              }
              if (root.pendingAlbumPlayRaw !== "" && (msg.message || "").indexOf("no ") === 0) {
                root.flashRow(root.pendingAlbumPlayRaw, msg.message)
                root.pendingAlbumPlayRaw = ""
              }
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

  // Per-view state (cursor identity + filter + drilled album), so each
  // tab keeps its own position when you switch back and forth. The
  // scroll offset is never stored: it is a pure function of the cursor
  // (List centers the row it is on), so restoring the row restores the
  // view exactly.
  function saveViewState() {
    console.info("jelly: save view", tab, "raw", String(mainList.lastRaw))
    var m = viewStates
    m[tab] = { raw: mainList.lastRaw, filter: mainList.filterText,
               albumId: openAlbumId }
    viewStates = m
  }
  function restoreViewState() {
    var st = viewStates[tab]
    console.info("jelly: restore view", tab, st ? "raw " + String(st.raw) : "empty state")
    openAlbumId = st ? (st.albumId || "") : ""
    mainList.filterText = st ? (st.filter || "") : ""
    if (st && st.raw !== undefined && st.raw !== -1) {
      // Land on the stored row; List's model-change view reset parks the
      // cursor at 0 first, so the focus pass runs after items settle.
      Qt.callLater(function() { mainList.focusRaw(st.raw, 0) })
    } else {
      mainList.resetCursor()
    }
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
  property string pendingAlbumPlayRaw: ""
  property var pendingTagReqs: ({})
  property var pendingTagReqsByAlbum: ({})
  Timer { id: rowFlashTimer; interval: 1400; onTriggered: root.rowFlash = null }

  function albumMetas(al) {
    return (al.tracks || []).map(function(t) {
      return { id: t.id, name: t.title, artist: t.artist || "", album: al.title,
               duration_secs: t.length || null, image_url: al.cover || null, stream_url: "" }
    })
  }

  function albumById(id) {
    for (var i = 0; i < albumList.length; i++) if (albumList[i].id === id) return albumList[i]
    return null
  }

  function applyTagUpdate(albumId, tags, reqId) {
    // Reconcile like the tier system: the daemon serializes tag writes and
    // echoes the originating req_id. A confirmation whose req_id is no longer
    // the newest pending request for this album is stale (a superseded write
    // in a rapid on/off sequence) and must not stomp the live optimistic
    // state — drop it and let the newest request's confirmation land.
    if (pendingTagReqsByAlbum[albumId] !== reqId) {
      console.info("jelly: drop stale tag_update req", reqId, "for", albumId,
                   "newest is", pendingTagReqsByAlbum[albumId])
      return
    }
    applyAlbumTags(albumId, tags)
    console.info("jelly: accept tag_update req", reqId, "album", albumId, "tags", JSON.stringify(tags))
    delete pendingTagReqsByAlbum[albumId]
    delete pendingTagReqs[reqId]
    tickMixBatch(reqId, false)
  }

  function uniqueNames(names) {
    var seen = {}
    var out = []
    for (var i = 0; i < names.length; i++) {
      var name = (names[i] || "").trim()
      if (name === "") continue
      var key = name.toLowerCase()
      if (seen[key]) continue
      seen[key] = true
      out.push(name)
    }
    out.sort(function(a, b) { return a.toLowerCase() < b.toLowerCase() ? -1 : 1 })
    return out
  }

  function allAlbumTags() {
    var names = []
    for (var i = 0; i < albumList.length; i++) {
      var ts = albumList[i].tags || []
      for (var j = 0; j < ts.length; j++) names.push(ts[j])
    }
    return names
  }

  // Albums carrying a mix tag, ordered by release year desc (matches the
  // daemon's mix-track ordering) so a row's cover strip previews the mix's
  // newest members.
  function mixAlbums(tag) {
    var out = []
    for (var i = 0; i < albumList.length; i++) {
      if (hasMixTag(albumList[i].tags || [], tag)) out.push(albumList[i])
    }
    out.sort(function(a, b) { return (b.year || 0) - (a.year || 0) })
    return out
  }

  function applyAlbumTags(albumId, tags) {
    var next = albumList.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id !== albumId) continue
      next[i] = { id: next[i].id, title: next[i].title, artist: next[i].artist,
                  cover: next[i].cover, year: next[i].year || 0, tags: uniqueNames(tags), tracks: next[i].tracks || [] }
      break
    }
    albumList = next
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
                   showCover: true, showGlyph: false, playing: false,
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
                   cover: (ctx.image_url || ""), showCover: true, showGlyph: false,
                   playing: t.id === root.now.id && !root.snap.queue_head,
                   section: sectionName }
        }
        // Remaining tracks only (the playing track is the now-playing
        // bar, not a row), display-filtered by the active tier: rows the
        // walk would skip are hidden (the daemon's context still holds
        // them). Waiting-queue rows above are exempt — never filtered.
        for (var j = cur + 1; j < tracks.length; j++)
          if (root.filterPasses(tracks[j].id)) out.push(ctxRow(tracks[j], j, ctx.name))
        // ...then, under repeat-all, the already-played ones wrap around,
        // in their own section so the wrap point is visible.
        if (snap.repeat === "all" && cur > 0) {
          // The already-played tracks wrap around; the current song is not
          // repeated here (it is what plays next).
          for (var k = 0; k < cur && k < tracks.length; k++)
            if (root.filterPasses(tracks[k].id)) out.push(ctxRow(tracks[k], k, ctx.name))
        }
      }
      return out
    }
    if (tab === "albums") {
      if (openAlbumId === "") {
        return albumList.map(function(al) {
          return { raw: al.id, albumId: al.id, isAlbum: true, title: al.title,
                   sub: (al.artist || ""),
                   cover: coverFor(al), showCover: true, showGlyph: true,
                   playing: nowCtx && nowCtx.name === al.title,
                   section: "" }
        })
      }
      var al = null
      for (var k = 0; k < albumList.length; k++) if (albumList[k].id === openAlbumId) al = albumList[k]
      if (!al) return []
      // Lazy drill: one tracks fetch on first entry, cached in tracksLoaded.
      if (!(al.tracks || []).length && !tracksLoaded[al.id] && connected)
        browse("browse_tracks", { album_id: al.id })
      // Build the context metas ONCE per view and share the array across
      // rows: per-row albumMetas() copies made every push O(n^2).
      // Activation only reads them, never mutates.
      var metas = albumMetas(al)
      return (al.tracks || []).map(function(t, idx) {
        return { raw: t.id, trackId: t.id, title: t.title, artist: t.artist || "",
                 durationSecs: t.length || null,
                 sub: (t.artist || "") + (t.length ? "  ·  " + Util.fmt(t.length) : ""),
                 cover: al.cover, playing: t.id === now.id, section: "",
                 ctxIndex: idx, metas: metas }
      })
    }
    if (tab === "commands") {
      return commands.map(function(c) {
        return { raw: c.key, key: c.key, desc: c.desc, section: "" }
      })
    }
    if (tab === "mixes") {
      var mixRows = [{ raw: "newmix", isNewMix: true, title: "󰐕 New Mix", artist: "", sub: "",
                       covers: [], coverCount: 0, cover: "", showCover: false, showGlyph: false,
                       bold: true, section: "" }]
      return mixRows.concat(mixList.map(function(tag) {
        var al = mixAlbums(tag)
        var covers = []
        for (var i = 0; i < al.length && covers.length < 10; i++) {
          var c = coverFor(al[i])  // prefer the disk-cached file:// url
          if (c) covers.push(c)
        }
        return { raw: "mix:" + tag, isMix: true, title: tag, artist: "", sub: albumCountText(al.length),
                 covers: covers, coverCount: al.length,
                 cover: "", showCover: false, showGlyph: false, section: "" }
      }))
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
        // order applies from there); l opens it. The daemon fetches the
        // album's track list itself: the widget never needs it for this.
        pendingAlbumPlayRaw = item.raw
        send({ type: "play_album", album_id: item.albumId })
        return
      }
      if (item.metas) {
        startPlayback(item.metas, item.ctxIndex || 0)
        return
      }
    }
    if (tab === "queue") {
      if (item.queueIndex !== undefined && item.queueIndex !== null) {
        // jump_to consumes this item and everything before it. The rows
        // above the cursor vanish, so the cursor must rejoin the top of
        // the remaining list on the next push (pendingTopJump) rather
        // than keep its index — queue view only.
        mainList.pendingTopJump = true
        mainList.jumpCursor(0)
        send({ type: "jump_to", index: item.queueIndex }); return
      }
      if (item.ctxIndex !== undefined && item.ctxIndex !== null && item.metas) {
        mainList.pendingTopJump = true
        startPlayback(item.metas, item.ctxIndex, true); return
      }
    }
    if (tab === "mixes") {
      if (item.isNewMix) { openMixCreate(); return }
      if (item.isMix) {
        pendingAlbumPlayRaw = item.raw
        send({ type: "play_mix", tag: item.title })
        return
      }
    }
  }

  // Guard rails for row actions: duplicate-queue guard, offline
  // guard for tiers, and a transient message on the acted-on row.
  function rowAction(action, item) {
    if (!item || !item.trackId) return
    if (action === "tier") {
      if (!connected) { flashRow(item.raw, "offline — tiers need a daemon connection"); return }
      // Queue-tab CONTEXT rows are display-filtered: cycling one below
      // the filter would evict the row under the cursor. Tier editing
      // belongs in the album view, where every row is always visible.
      // (Waiting-queue rows are exempt — they never hide.)
      if (tab === "queue" && item.ctxIndex !== undefined && item.queueIndex === undefined) {
        flashRow(item.raw, "tiers: edit in the album view")
        return
      }
      var next = Util.tierNext(tierMap[item.trackId] || "")
      send({ type: "cycle_tier", item_id: item.trackId })
      flashRow(item.raw, next === "" ? "unrated" : next)
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

  // Auto-repeat is OFF by default: a held key fires the discrete action
  // once, not in a burst. Handlers call this to allow repeat on the small
  // set of keys where holding is the natural interaction: cursor nav
  // (j/k, Up/Down), seek (,/.) and filter/text editing (Backspace and any
  // printable character while a text field is open).
  function listNavRepeats(event) {
    if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) return true
    var t = event.text
    return t === "j" || t === "k"
  }
  function textEditRepeats(event, editing) {
    if (!editing) return false
    if (event.key === Qt.Key_Backspace) return true
    return !!(event.text && event.text.length === 1)
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
    if (t === "f") { rowAction("tier", item); return true }
    if (t === "e" && tab === "mixes" && item.isMix) { openMixEdit(item.title); return true }
    if (t === "d" && tab === "mixes" && item.isMix) { openMixDelete(item.title); return true }
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
    // Focus whatever row is marked playing: a track row in a drill/queue
    // view, or the album row owning the current context in an overview.
    // The flag is the same one the delegate renders (bold + glyph), so o
    // always lands on the row the UI says is playing. No-op when the
    // playing song has no row here (e.g. a queue head).
    mainList.focusRowWhere(function(it) { return it.playing === true })
  }

  Timer {
    id: postDrillFocusTimer
    interval: 120
    onTriggered: keyFocus.forceActiveFocus()
  }

  function drillBack() {
    if (tab === "albums" && openAlbumId !== "") {
      var cameFrom = openAlbumId
      // Popping a level clears the drill view's filter (the original
      // rule); the re-park it attempts is overridden by the view reset.
      mainList.clearFilter()
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
    var order = ["queue", "albums", "mixes", "commands"]
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
  // `consumeQueue` is the queue tab's semantics: the list is "what plays
  // next", so picking a row makes everything above it past — the waiting
  // queue goes too. Other tabs leave the queue alone (only the daemon-side
  // head rule applies: the interrupted song is dropped, not resurrected).
  function startPlayback(tracks, startIndex, consumeQueue) {
    send({ type: "play", tracks: tracks, start_index: startIndex,
           clear_queue: consumeQueue === true })
    if (snap.repeat === "one") send({ type: "set_repeat", mode: "off" })
  }

  // ---- command palette (?): every keybind, filterable. Rendered by the
  //      same List component as the main views so cursor/scroll/filter
  //      behavior is identical everywhere.
  property bool paletteOpen: false
  // ---- mix modal (mix-centric, two-step). Launched from the Mixes tab:
  //      create = name step -> album checklist; edit = album checklist with
  //      the current members pre-checked (name locked, no rename). Selection
  //      is desired membership (albumId -> true); the delta against the mix's
  //      live membership is written on submit as concurrent tag toggles.
  property bool mixModalOpen: false
  property string mixStep: "name"        // "name" | "albums"
  property string mixMode: "create"      // "create" | "edit"
  property string mixName: ""
  property var mixSelected: ({})
  // Concurrent-write tally: reconcile partial failures once every issued
  // toggle_tag has echoed (or errored) back.
  property int mixBatchTotal: 0
  property int mixBatchDone: 0
  property int mixBatchFailed: 0
  property var mixBatchReqs: ({})
  // Delete confirmation (mixes tab `d`).
  property bool deleteConfirmOpen: false
  property string deleteMixName: ""

  readonly property var commands: [
    { key: "j", desc: "Move cursor down" },
    { key: "k", desc: "Move cursor up" },
    { key: "Enter", desc: "Play selection (album/playlist from start)" },
    { key: "l", desc: "Into view (drill)" },
    { key: "h", desc: "Out of view (top level: nothing)" },
    { key: "Esc", desc: "Clear filter / out of view / close" },
    { key: "H", desc: "Previous tab" },
    { key: "L", desc: "Next tab" },
    { key: "g", desc: "Jump to top of list" },
    { key: "G", desc: "Jump to bottom of list" },
    { key: "o", desc: "Focus the playing row" },
    { key: "/", desc: "Filter the current view" },
    { key: "q", desc: "Queue selection at tail of queue" },
    { key: "p", desc: "Queue selection to play next (head)" },
    { key: "d", desc: "Delete queue item / selected mix" },
    { key: "J", desc: "Move queue item down" },
    { key: "K", desc: "Move queue item up" },
    { key: "f", desc: "Cycle tier on selection" },
    { key: "e", desc: "Edit selected mix (albums)" },
    { key: "F", desc: "Cycle tier on playing song" },
    { key: "[", desc: "Step playback filter down (toward All)" },
    { key: "]", desc: "Step playback filter up (toward Favorite)" },
    { key: "s", desc: "Toggle shuffle" },
    { key: "r", desc: "Cycle repeat off / all / one" },
    { key: "n", desc: "Next track" },
    { key: "N", desc: "Previous track" },
    { key: "Space", desc: "Play / pause" },
    { key: ",", desc: "Seek back 10s" },
    { key: ".", desc: "Seek forward 10s" },
    { key: "?", desc: "Command palette" }
  ]

  // The palette's rows: one per keybind. The List component owns the
  // cursor and the filter (1-char matches keys, longer matches descs).
  readonly property var paletteRows: commands.map(function(c) {
    return { raw: c.key, key: c.key, desc: c.desc, section: "" }
  })

  function openPalette() {
    paletteOpen = true
    Qt.callLater(function() {
      paletteList.filterText = ""
      paletteList.resetCursor()
      paletteModal.forceActiveFocus()
    })
  }

  // ---- mix modal: entry points ------------------------------------------
  // Create: name step first, then an all-album checklist starting empty.
  function openMixCreate() {
    mixMode = "create"
    mixStep = "name"
    mixName = ""
    mixSelected = ({})
    mixModalOpen = true
    Qt.callLater(function() { mixModal.forceActiveFocus() })
  }

  // Edit: name is locked, so skip the name step and open the checklist with
  // the mix's current members pre-checked.
  function openMixEdit(tag) {
    mixMode = "edit"
    mixStep = "albums"
    mixName = tag
    mixSelected = currentMixMembership(tag)
    mixModalOpen = true
    Qt.callLater(function() { mixAlbumList.resetCursor(); mixModal.forceActiveFocus() })
  }

  function closeMixModal() {
    mixModalOpen = false
    Qt.callLater(function() { keyFocus.forceActiveFocus() })
  }

  function mixNameExists(nm) {
    var w = (nm || "").toLowerCase()
    if (w === "") return false
    for (var i = 0; i < mixList.length; i++) if ((mixList[i] || "").toLowerCase() === w) return true
    return false
  }

  // Current membership of a mix as an albumId -> true map (case-insensitive
  // on the tag), read live from the album list so it reflects the truth
  // (including optimistic writes) at the moment we compare.
  function currentMixMembership(tag) {
    var m = ({})
    if (!tag) return m
    for (var i = 0; i < albumList.length; i++)
      if (hasMixTag(albumList[i].tags || [], tag)) m[albumList[i].id] = true
    return m
  }

  function memberAlbumIds(tag) {
    var ids = []
    if (!tag) return ids
    for (var i = 0; i < albumList.length; i++)
      if (hasMixTag(albumList[i].tags || [], tag)) ids.push(albumList[i].id)
    return ids
  }

  // ---- album checklist rows: every album, title-sorted (albumList already
  //      sorts by title), checkbox reflecting desired membership.
  function mixAlbumRows() {
    var sel = mixSelected
    return albumList.map(function(al) {
      return { raw: al.id, albumId: al.id, cover: coverFor(al),
               title: al.title, artist: al.artist || "", sub: al.artist || "",
               checked: sel[al.id] === true, section: "" }
    })
  }

  function selectedCount() {
    var n = 0
    for (var k in mixSelected) if (mixSelected[k]) n++
    return n
  }

  // Albums matching the checklist's current filter (the "visible" set that
  // a/A act on). Mirrors List's filterFn so a select-all never touches rows
  // scrolled/filtered out of sight.
  function visibleAlbumIds() {
    var f = (mixAlbumList.filterText || "").toLowerCase()
    var out = []
    for (var i = 0; i < albumList.length; i++) {
      var al = albumList[i]
      if (f === "" || Util.filterByTitleOrArtist({ title: al.title, sub: al.artist || "" }, f))
        out.push(al.id)
    }
    return out
  }

  function setAlbumSelected(albumId, on) {
    var m = ({})
    for (var k in mixSelected) if (mixSelected[k]) m[k] = true
    if (on) m[albumId] = true
    else delete m[albumId]
    mixSelected = m
  }

  // Space: toggle the focused album and advance the cursor one row, so
  // holding Space walks down a range.
  function toggleFocusedAlbum() {
    var it = mixAlbumList.cursorItem
    if (!it || !it.albumId) return
    setAlbumSelected(it.albumId, mixSelected[it.albumId] !== true)
    mixAlbumList.moveCursor(1)
  }

  function selectAllVisible(on) {
    var ids = visibleAlbumIds()
    var m = ({})
    for (var k in mixSelected) if (mixSelected[k]) m[k] = true
    for (var i = 0; i < ids.length; i++) {
      if (on) m[ids[i]] = true
      else delete m[ids[i]]
    }
    mixSelected = m
  }

  // ---- name step: Enter validates and advances (empty / duplicate names
  //      are simply rejected — the step stays put; no inline error bar).
  function advanceFromName() {
    var nm = (mixName || "").trim()
    if (nm === "") return
    if (mixNameExists(nm)) return
    mixName = nm
    mixSelected = ({})
    mixStep = "albums"
    Qt.callLater(function() { mixAlbumList.resetCursor() })
  }

  function handleMixModalKey(event) {
    if (mixStep === "name") {
      var nameEdit = event.key === Qt.Key_Backspace
                  || (event.text && event.text.length === 1 && event.text >= " ")
      if (event.isAutoRepeat && !(root.listNavRepeats(event) || root.textEditRepeats(event, true)
                                  && !(event.key === Qt.Key_Return || event.key === Qt.Key_Enter))) {
        // Backspace/printable repeat while typing; everything else one-shot.
        if (!nameEdit) { event.accepted = true; return }
      }
      if (event.key === Qt.Key_Escape) { closeMixModal(); event.accepted = true; return }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { advanceFromName(); event.accepted = true; return }
      if (event.key === Qt.Key_Backspace) { mixName = mixName.slice(0, -1); event.accepted = true; return }
      if (event.text && event.text.length === 1 && event.text >= " ") {
        mixName += event.text; event.accepted = true; return
      }
      event.accepted = true
      return
    }

    // ---- album step
    // Repeat only cursor nav here; Space/a/A/Enter are one-shot.
    if (event.isAutoRepeat && !root.listNavRepeats(event)) { event.accepted = true; return }

    // While a filter is being typed, only Esc is special (List's cancel).
    if (mixAlbumList.filtering) {
      mixAlbumList.handleKey(event)
      event.accepted = true
      return
    }
    var t = event.text
    if (event.key === Qt.Key_Escape) {
      // Back a step: create -> name step, edit -> close (name is locked).
      if (mixMode === "create") { mixStep = "name"; }
      else closeMixModal()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Space) { toggleFocusedAlbum(); event.accepted = true; return }
    if (t === "a") { selectAllVisible(true); event.accepted = true; return }
    if (t === "A") { selectAllVisible(false); event.accepted = true; return }
    // Enter (submit via onActivated), j/k/arrows, g/G, / all belong to List.
    mixAlbumList.handleKey(event)
    event.accepted = true
  }

  // ---- submit: delta-only writes against the mix's live membership.
  function submitMix() {
    var adds = [], removes = []
    if (mixMode === "create") {
      for (var k in mixSelected) if (mixSelected[k]) adds.push(k)
    } else {
      var cur = currentMixMembership(mixName)
      var sel = mixSelected
      for (var a in sel) if (sel[a] && !cur[a]) adds.push(a)
      for (var c in cur) if (cur[c] && !sel[c]) removes.push(c)
    }
    if (mixMode === "create" && adds.length === 0) {
      return
    }
    var name = mixName
    mixBatchTotal = 0; mixBatchDone = 0; mixBatchFailed = 0; mixBatchReqs = ({})
    sendTagBatch(adds, name, true)
    sendTagBatch(removes, name, false)
    closeMixModal()
    // Land the cursor on the freshly created mix row (already present in the
    // optimistic mixList), so the "n failed" flash has somewhere to show.
    if (mixMode === "create") Qt.callLater(function() { mainList.focusRaw("mix:" + name) })
  }

  // ---- concurrent tag writes with a completion tally.
  function sendTagBatch(ids, tag, present) {
    for (var i = 0; i < ids.length; i++) sendTagWrite(ids[i], tag, present)
  }

  function sendTagWrite(albumId, tag, present) {
    var album = albumById(albumId)
    if (!album) return
    if (!connected) {
      mixBatchTotal++; mixBatchDone++; mixBatchFailed++
      checkMixBatch(tag)
      return
    }
    var prev = (album.tags || []).slice()
    var next = prev.slice()
    var pos = -1
    for (var i = 0; i < next.length; i++) if ((next[i] || "").toLowerCase() === tag.toLowerCase()) pos = i
    if (present && pos < 0) next.push(tag)
    if (!present && pos >= 0) next.splice(pos, 1)
    var id = reqSeq++
    var superseded = pendingTagReqsByAlbum[albumId]
    if (superseded !== undefined) delete pendingTagReqs[superseded]
    pendingTagReqs[id] = { albumId: albumId, tag: tag, prevTags: prev }
    pendingTagReqsByAlbum[albumId] = id
    applyAlbumTags(albumId, next)
    mixBatchTotal++; mixBatchReqs[id] = true
    console.info("jelly: mix toggle_tag req", id, "album", albumId, "tag", tag, "present", present)
    send({ type: "toggle_tag", album_id: albumId, tag: tag, present: present, req_id: id })
  }

  function tickMixBatch(reqId, failed) {
    if (mixBatchReqs[reqId] !== true) return
    delete mixBatchReqs[reqId]
    mixBatchDone++
    if (failed) mixBatchFailed++
    checkMixBatch(mixName)
  }

  function checkMixBatch(name) {
    if (mixBatchTotal === 0 || mixBatchDone < mixBatchTotal) return
    if (mixBatchFailed > 0) root.flashRow("mix:" + name, mixBatchFailed + " failed")
    mixBatchTotal = 0; mixBatchDone = 0; mixBatchFailed = 0; mixBatchReqs = ({})
  }

  // ---- delete a mix: strip the tag from every member album (same path).
  function openMixDelete(tag) {
    deleteMixName = tag
    deleteConfirmOpen = true
    Qt.callLater(function() { deleteConfirmModal.forceActiveFocus() })
  }

  function closeDeleteConfirm() {
    deleteConfirmOpen = false
    Qt.callLater(function() { keyFocus.forceActiveFocus() })
  }

  function handleDeleteConfirmKey(event) {
    if (event.key === Qt.Key_Escape) { closeDeleteConfirm(); event.accepted = true; return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      var tag = deleteMixName
      var ids = memberAlbumIds(tag)
      mixBatchTotal = 0; mixBatchDone = 0; mixBatchFailed = 0; mixBatchReqs = ({})
      sendTagBatch(ids, tag, false)
      closeDeleteConfirm()
      event.accepted = true
      return
    }
    event.accepted = true
  }

  function hasMixTag(tags, tag) {
    for (var i = 0; i < tags.length; i++) if ((tags[i] || "").toLowerCase() === tag.toLowerCase()) return true
    return false
  }

  function mixAlbumCount(tag) {
    var count = 0
    for (var i = 0; i < albumList.length; i++) {
      if (hasMixTag(albumList[i].tags || [], tag)) count++
    }
    return count
  }

  function albumCountText(count) {
    return count + " album" + (count === 1 ? "" : "s")
  }

  function closePalette() {
    paletteOpen = false
    Qt.callLater(function() { keyFocus.forceActiveFocus() })
  }

  // Palette key router (shared by the modal's Keys handler and the
  // headless injectKey seam).
  function handlePaletteKey(event) {
    // Repeat is opt-in: paging, cursor nav and filter typing repeat; Enter
    // (activation) and everything else is one-shot.
    var paging = event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown
    var repeatable = paging || root.listNavRepeats(event)
                     || root.textEditRepeats(event, paletteList.filtering)
    if (event.isAutoRepeat && !repeatable) { event.accepted = true; return }
    if (event.key === Qt.Key_PageUp) { paletteList.jumpCursor(paletteList.cursorPos - 8); event.accepted = true; return }
    if (event.key === Qt.Key_PageDown) { paletteList.jumpCursor(paletteList.cursorPos + 8); event.accepted = true; return }
    paletteList.handleKey(event)
    event.accepted = true
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

  // ---- tiers. The daemon pushes the rated-track map (id -> tier) on
  //      every state change; unrated tracks are absent. IsFavorite is
  //      write-side only (Favorite tier hearts the item for other
  //      clients) — nothing in this UI renders favorites.
  readonly property var tierMap: snap.tiers || ({})

  // ---- playback filter (JELLY-40). The daemon walks contexts with this
  //      minimum tier; the panel uses it only for display filtering.
  readonly property string snapFilter: snap.filter || "all"

  function tierOf(id) { return (root.tierMap[id] || "unrated").toString().toLowerCase() }
  function tierRank(tier) {
    var t = (tier || "unrated").toString().toLowerCase()
    if (t === "liked") return 1
    if (t === "loved") return 2
    if (t === "favorite") return 3
    return 0
  }
  function filterPasses(id) {
    if (root.snapFilter === "all") return true
    // Inclusive threshold: Liked shows Liked/Loved/Favorite, Loved shows
    // Loved/Favorite, Favorite shows only Favorite.
    return root.tierRank(root.tierOf(id)) >= root.tierRank(root.snapFilter)
  }

  function cycleTierNow() {
    if (!now || !now.id) return
    if (!connected) return
    send({ type: "cycle_tier", item_id: now.id })
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
        if (root.paletteOpen || root.mixModalOpen || root.deleteConfirmOpen) { event.accepted = true; return }
        // Repeat is opt-in (see listNavRepeats/textEditRepeats): only cursor
        // nav, seek and filter typing survive auto-repeat; every discrete
        // action (transport, tier, queue, tab, play/pause, close) is one-shot.
        var seeking = event.text === "," || event.text === "."
        var repeatable = root.listNavRepeats(event) || seeking
                         || root.textEditRepeats(event, mainList.filtering)
        if (event.isAutoRepeat && !repeatable) { event.accepted = true; return }
        if (mainList.handleKey(event)) { event.accepted = true; return }
        if (root.handleRowKey(event)) { event.accepted = true; return }
        var t = event.text
        if (event.key === Qt.Key_Escape) {
          root.close(); event.accepted = true; return
        }
        // h is drill-back only (List's backHook handles it): at the top
        // level it does nothing. Esc is the close key.
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
        if (t === ",") { root.seekBy(-10); event.accepted = true; return }
        if (t === ".") { root.seekBy(10); event.accepted = true; return }
        if (t === "F") { root.cycleTierNow(); event.accepted = true; return }
        if (t === "[") { send({ type: "step_filter", up: false }); event.accepted = true; return }
        if (t === "]") { send({ type: "step_filter", up: true }); event.accepted = true; return }
        if (t === "?") { root.openPalette(); event.accepted = true; return }
        if (t === "H") { root.cycleTab(-1); event.accepted = true; return }
        if (t === "L") { root.cycleTab(1); event.accepted = true; return }
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
        // padding, minus the cover and the gap between them. The gap only
        // exists while the cover is visible; otherwise the initial empty
        // shell state gets an artificial right inset.
        readonly property real contentW:
          width - Style.space(16 + 16) - (nowCover.visible ? nowCover.width + Style.space(12) : 0)

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

                  // Current-song tier, using the same glyph semantics as
                  // track rows. The fixed slot keeps transport controls
                  // from shifting when a song is unrated.
                  Item {
                    visible: root.now && root.now.id
                    width: Style.space(16)
                    height: playPauseGlyph.implicitHeight
                    anchors.verticalCenter: parent.verticalCenter

                    TierGlyph {
                      anchors.centerIn: parent
                      tier: root.now && root.now.id ? root.tierOf(root.now.id) : ""
                      color: tier === "favorite" ? Color.accent : Color.foreground
                    }
                  }

                  Text {
                    id: playPauseGlyph
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
      // The tier-filter triptych rides the far right, fixed across tabs:
      // the ACCENTED icon is the active playback filter, all-dim = All.
      // (Track-row tier opacity intentionally overridden to full here —
      // unaccented must read dim, not quiet-by-tier.)
      Item {
        id: tabsRow
        width: parent ? parent.width : 0
        height: Style.space(30)

        Row {
          id: tabsInner
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          leftPadding: Style.space(16)
          rightPadding: Style.space(16)
          spacing: Style.space(10)

          Repeater {
            model: [ { id: "queue", label: "󰐑 Queue" },
                      { id: "albums", label: "󰀥 Albums" },
                      { id: "mixes", label: "Mixes" },
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

        Row {
          id: filterTriptych
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          rightPadding: Style.space(16)
          spacing: Style.space(6)

          Repeater {
            model: [ "liked", "loved", "favorite" ]
            delegate: TierGlyph {
              required property string modelData
              tier: modelData
              opacity: 1.0
              color: root.snapFilter === modelData ? Color.accent : Qt.darker(Color.foreground, 2.2)
              font.pixelSize: Style.font.body
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
      Component { id: mixListRowComp; MixListRow {} }
      Component { id: mixRowComp; MixRow {} }

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
        rowDelegate: root.tab === "commands" ? commandRowComp
          : (root.tab === "mixes" ? mixListRowComp : trackRowComp)
        rowHeight: root.tab === "commands"
          ? Style.space(32)
          : (root.tab === "mixes" ? Style.space(56)
          : (root.openAlbumId !== "" ? Style.space(40) : Style.space(56)))
        // Queue strips ("Up next", context name) are half-height.
        secHeight: root.tab === "queue" ? Style.space(28) : Style.space(56)
        reversed: false
        flash: root.rowFlash
        tierMap: root.tierMap
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
           : (root.tab === "mixes" && root.mixList.length === 0
               ? "No mixes yet — Enter on “New Mix” to create one"
              : (root.tab === "albums" && albumList.length === 0
              ? "Loading library…"
              : (root.tab === "albums" && root.openAlbumId !== "" && !tracksLoaded[root.openAlbumId]
                 ? "Loading…"
                 : "Nothing here")))
        focusPlayingHook: function() { root.focusPlayingRow() }
        backHook: function() { return root.drillBack() }
        drillHook: function() {
          var it = mainList.cursorItem
          if (root.tab === "albums" && it && it.isAlbum) {
            // Drilling in clears the filter (the original rule): the new
            // view starts fresh, unfiltered, at the top.
            mainList.clearFilter()
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
      }

      // Panel-wide modal layer. It is authored inside the list item but
      // reparented to the card — `fullColumn.parent` is the contentHolder and
      // its parent is the BorderSurface card that IS the widget (contentHolder
      // is inset by the popup padding, so filling it stops short of the card
      // edge). Anchoring to the card makes the scrim dim and the cards center
      // on the ENTIRE widget, padding ring included. (Anchoring to `panel`
      // fails: a KeyboardPanel is a full-screen PanelWindow, not an Item.)
      Item {
        id: modalOverlay
        parent: fullColumn.parent.parent
        anchors.fill: parent
        z: 5

        // Mix editor: one modal, two steps. Create opens on the name step (a
        // plain field + blinking cursor); Enter validates and reveals the album
        // checklist. Edit opens straight on the checklist with the mix's members
        // pre-checked (name locked). The card hugs the active step and clamps to
        // the widget; only the album list fills, so it scrolls when tall. Owns
        // its key router (handleMixModalKey) to remap Space/Enter/a per step.
        Modal {
          id: mixModal
          open: root.mixModalOpen
          closeOnEscape: false
          Keys.onPressed: function(event) { root.handleMixModalKey(event) }
          onCloseRequested: root.closeMixModal()

          // ---- step 1: name
          Text {
            visible: root.mixStep === "name"
            Layout.fillWidth: true
            leftPadding: Style.space(12)
            textFormat: Text.PlainText
            text: "New mix"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Item {
            visible: root.mixStep === "name"
            Layout.fillWidth: true
            Layout.preferredHeight: nameField.implicitHeight
            Text {
              id: nameField
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.mixName
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.body * 1.15)

              Rectangle {
                id: nameCursor
                visible: root.mixStep === "name"
                x: parent.contentWidth + Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: Math.round(Style.font.body * 1.15)
                color: Color.accent
                property bool on: true
                opacity: on ? 1 : 0
                Timer {
                  interval: 500
                  running: root.mixStep === "name"
                  repeat: true
                  onTriggered: nameCursor.on = !nameCursor.on
                }
              }
            }
          }

          // ---- step 2: album checklist
          Text {
            visible: root.mixStep === "albums"
            Layout.fillWidth: true
            leftPadding: Style.space(12)
            textFormat: Text.PlainText
            text: "Editing Mix: " + root.mixName
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          List {
            id: mixAlbumList
            visible: root.mixStep === "albums"
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Hug the rows (no layout-derived contentHeight -> no binding
            // loop); when this exceeds the widget the card clamps and the
            // list's Layout.fillHeight shrinks it to the room left, scrolling.
            implicitHeight: mixAlbumList.rowCount * Style.space(48) + Style.space(34)
            debugName: "mix-albums"
            rows: root.mixAlbumRows()
            filterable: true
            filterFn: Util.filterByTitleOrArtist
            rowDelegate: mixRowComp
            rowHeight: Style.space(48)
            emptyText: "No albums"
            onActivated: item => root.submitMix()
          }

          Text {
            visible: root.mixStep === "albums"
            Layout.fillWidth: true
            leftPadding: Style.space(12)
            textFormat: Text.PlainText
            text: root.selectedCount() + " selected"
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Delete confirmation: Enter strips the tag from every member album
        // (same delta write path), Esc dismisses. No affected-album list.
        Modal {
          id: deleteConfirmModal
          open: root.deleteConfirmOpen
          Keys.onPressed: function(event) { root.handleDeleteConfirmKey(event) }
          onCloseRequested: root.closeDeleteConfirm()

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "Delete ‘" + root.deleteMixName + "’?"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "Enter confirms · Esc cancels"
            color: Qt.darker(Color.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // command palette: dims the whole widget and floats a navigable list
        // of every keybind. "/" switches to filter mode (input focused); Esc
        // leaves filter mode; Esc/h in navigate mode closes.
        Modal {
          id: paletteModal
          open: root.paletteOpen
          // Everything the shared List doesn't consume is irrelevant to the
          // palette; PgUp/PgDn page the cursor by 8 as before.
          Keys.onPressed: function(event) { root.handlePaletteKey(event) }
          onCloseRequested: root.closePalette()

          // Same component as the main views: prompt, live filter (1 char
          // matches keybinds, longer text matches descriptions), cursor,
          // centered scrolling, g/G. Esc/h closes the palette (backHook);
          // Enter closes it (activation is display-only here).
          List {
            id: paletteList
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitHeight: paletteList.rowCount * Style.space(32) + Style.space(34)
            debugName: "palette"
            rows: root.paletteRows
            filterable: true
            filterFn: Util.filterByKeyOrDesc
            rowDelegate: commandRowComp
            rowHeight: Style.space(32)
            emptyText: "No matches"
            backHook: function() { root.closePalette(); return true }
            onActivated: item => root.closePalette()
          }
        }
      }

      }
    }
  }
}
