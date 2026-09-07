# PROTOTYPE — widget interaction design (throwaway)

Wayfinder ticket: "Prototype: bar widget + popup interaction design". Mock data only
(`Mock.js`); no daemon, no v1 schema. Lives in the real plugin dir so it hot-reloads
onto the actual bar.

## Question

How should the Jelly bar widget + popup behave? Keyboard-first, vim-like bindings.

## Design under test (agreed with Eddie, 2026-09-06)

- Compact **transport popup** on toggle: title/artist, progress, play/pause, next/prev,
  volume, seek. `f` **expands in place** to the full view; `f` again collapses.
- Full view: tabs `[Q] Queue [A] Albums [P] Playlists` — uppercase keys, order as
  displayed. Same tab key pressed again returns that tab to its root. Tab switch
  preserves each tab's drill state.
- `j/k` move within the current list; `h` pops out (up a breadcrumb level), `l` drills
  in (hidden secondary; `enter` is the shown primary — drills *or* plays).
- **Breadcrumbs** (`Artists › Lifeformed › Axiom Verge OST`) show where you are;
  drilling is real navigation, highlight is just the cursor.
- `/` filter mode: type → `enter` jumps cursor into the filtered list; `esc` cancels,
  and `esc` with a filter applied clears it first, then pops levels, then closes.
- Contextual hint bar at the bottom of each view.
- transport: `space` play/pause · `n`/`N` next/prev · `-`/`=` volume · `,`/`.` seek ·
  `f` full · `q` close.

## Verdict

(security note: this file is a scratchpad; findings recorded on the Plane ticket at
resolution)
