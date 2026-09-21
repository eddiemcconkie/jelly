# Operating rules for this repo (jelly-daemon + eddie.jelly plugin)

## Architectural decisions — consult Eddie first
- **Eddie must be consulted before ANY architectural decision** (component
  structure, ownership of state, replacing a library primitive like
  ListView, IPC schema changes, anything that's a refactor rather than a
  bugfix). Propose options, wait for approval, then act. Do not assume.

## Project management
- All project management lives in **Plane** (via the Plane MCP): the Wayfinder
  map issue, tickets, decisions, specs, and research notes. Do NOT keep
  research docs, plans, or tracking files in this repo — put them on Plane
  (as issue descriptions/comments or pages). The repo is for code only;
  `CONTEXT.md` / `research/` are legacy from before this rule and should be
  migrated to Plane when touched.

## Shell / plugin changes
- After ANY change to plugin QML/JS files: run `omarchy plugin validate .` (in
  this dir), then `omarchy restart shell`. Hot reload exists but is unreliable.
- Prefer the Edit tool for QML changes; verify syntax with
  `/usr/lib/qt6/bin/qmllint <file>.qml` (ignore qs.Commons import warnings —
  they only appear because qmllint runs outside the shell). Runtime QML errors
  show up in `journalctl --user`.
- **Implicit layouts by default.** Compose with Row/Column (or RowLayout/
  ColumnLayout where fill/alignment is needed) plus `spacing` and padding;
  let items derive their own `implicitHeight` from their content. Do not
  hardcode row/item heights or hand-place children with `x`/`y`/anchors
  unless there is no layout alternative. Fixed sizes are for media (cover
  art and the like) so surrounding content adapts when those change.

## Daemon
- After changing Rust code, run `cargo fmt` before testing so formatting-only
  diffs do not surprise the next pass.
- The daemon's lifecycle belongs to the plugin: `Service.qml` spawns
  `target/debug/jelly-daemon` (with stdout/stderr piped into the shell journal,
  prefixed `jelly-daemon:`), respawns it 2s after death, and rbw-locked agents
  trigger `rbw unlock` (pinentry) automatically with login retry.
- To pick up a rebuilt daemon: `pkill -f '[j]elly-daemon'` (bracket the first
  letter — a plain pattern matches the pkill process itself), then the service
  respawns it. Do NOT use the old `jelly-dae[ ]mon` pattern: it matches a
  literal space, never matches the daemon, and caused zombie double-spawns.
- Only ONE daemon may run; two will fight over `$XDG_RUNTIME_DIR/jelly/daemon.sock`.
- Daemon restarts (shell restart or respawn) lose playback state; rbw must be
  unlocked for auth (or the unlock prompt handles it).

## Testing / fixtures
- **Daemon tests are permanent and must be exercised:** run `cargo test`
  (workspace root) before and after ANY change to `jelly-daemon/` or
  `jelly-ipc/`. The playback model transitions (queue consumption, head
  rules, context takeover) are covered there; a failing test is a signal
  the semantics changed, not something to delete. Playback semantics
  (approved 2026-09-18): starting a new context drops the playing queue
  head (never resurrects it); waiting queue survives except `play` with
  `clear_queue: true` (queue-tab activation — "everything above the pick
  is past").
- **Headless UI testing (no manual keyboard):** the widget accepts IPC from
  `omarchy-shell eddie.jelly <cmd>`:
  - `toggle` / `open` / `close` — the popup panel
  - `debugKey <name>` — inject a synthetic key through the same router as the
    real keyboard (`Panel.qml` `injectKey`). Names: `Enter`, `Return`,
    `Escape`, `Up`, `Down`, `Left`, `Right`, `Space`, or any single char
    (`j`, `k`, `q`, `f`, `Tab` uses `Enter`-style names only — see the map).
  Typical debug loop:
  `omarchy restart shell; sleep 5; omarchy-shell eddie.jelly toggle;
  omarchy-shell eddie.jelly debugKey j;`
  then verify behavior in `journalctl --user -f` (grep `qml: jelly`:` — the
  panel logs state pushes, activations, sends; List logs cursor moves).
- `target/debug/jctl` — poke the socket (state, play <id>, toggle, next...).
- `cargo run --bin probe` regenerates `MockLibrary.json` (real library dump:
  albums/tracks/covers/playlists incl. nested ones). It is gitignored.
- MPRIS debugging: `busctl --user call org.mpris.MediaPlayer2.jelly
  /org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties Get ss
  org.mpris.MediaPlayer2.Player <Prop>`; omarchy media widget state via
  `omarchy-shell media status`.
- MPRIS gotcha: PropertiesChanged must be emitted on interface
  `org.freedesktop.DBus.Properties` (not the player interface), and
  capabilities (e.g. CanPlay) must be re-emitted when they flip — clients
  cache their first read (taken pre-auth, so false).

## Server / credentials
- Eddie's server: jellyfin.mcconkie.dev (rbw entry of the same name; env
  `JELLY_SERVER`). Never print, commit, or copy passwords; nothing secret in
  the repo.

## Misc
- Commit only when Eddie asks.
- libmpv2 gotchas: `EndFileReason` constants not re-exported (raw compare:
  EOF=0, ERROR=4); EndFile(ERROR) arrives via wait_event Err; options must be
  set via `Mpv::with_initializer` before init; `playlist-playing-pos` can be
  -1 (clamp before casting to usize — it once panicked the engine thread).
- Engine keeps an `offset` mapping mpv-internal playlist positions to queue
  indices (mpv always starts its internal playlist at 0 even when we load
  from start_index).
