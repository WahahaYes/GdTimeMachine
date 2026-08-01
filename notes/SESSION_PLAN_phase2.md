# Session Plan — Phase 2: BackendMovieMaker + Dock UI

Date: 2026-07-31
Status: ✅ Complete

## Goal

Deliver the "works immediately" path: the Movie Maker backend and the minimal
dock, so the addon can record scenes with zero external dependencies.

## Scope (locked)

- `backend/backend_movie_maker.gd` — Movie Maker backend
- `ui/time_machine_dock.tscn` + `.gd` — minimal dock titled "GdTimeMachine"
- `ui/icons/icon_record.svg` + `icon_stop.svg` — shipped SVGs (no EditorIcons)
- `test/unit/test_backend_movie_maker.gd` — GUT tests via fake seam overrides
- `test/manual/recording_smoke.tscn` + `.gd` — manual smoke scene
- `plugin.gd` — register backend, instantiate dock, bottom panel tab ("GdTimeMachine",
  next to Output/Debugger/GUT — not a right-side dock slot)
- No recent-captures list (deferred to Phase 5)

## Key decisions

- **No play-mode signal exists** (verified: EditorInterface has only
  `script_changed`/`property_list_changed`; PR godot#103056 unmerged). Poll
  `is_playing_scene()` on a 0.5s Timer.
- **Duration = auto-stop** (one-shot Timer); doubles as a watchdog — if the
  scene never starts playing before it elapses, emit `recording_error`.
- **`is_recording()` returns internal `_active` state**, not
  `is_movie_maker_enabled()` (the setting lags/persists; session state is
  accurate for the dock toggle).
- **All EditorInterface/ProjectSettings access via `_`-prefixed seam methods**
  so GUT can fake the editor headlessly.
- **`editor/movie_writer/movie_file` + `fps` are set + `ProjectSettings.save()`**
  per plan (persists in project.godot).
- Empty scene path → `play_current_scene()` (F6 semantics).

## Session log

1. Backend implemented (state machine + seams + timers). 17 GUT tests green.
2. Dock + icons + plugin wiring. First import failed with 3 parse errors:
   - `preload(svg)` fails during the editor's first import scan (SVG not yet
     imported when @tool script parses) → **load lazily in `_ready()`**.
   - `EditorSettings.get_singleton()` invalid → **`EditorInterface.get_editor_settings()`**.
   - `%UniqueName` lookups fail on reparented dock controls → **`$` node paths**
     (matches the plan's original sketch).
3. Editor boot clean (`--headless --editor --quit`), all 34 GUT tests pass
   (17 movie maker + 3 backend base + 14 controller).

## Acceptance checklist

- [x] `make test-godot` → all 34 tests pass
- [x] `godot --headless --import` → no script errors
- [x] `godot --headless --editor --quit` → clean plugin/dock load
- [ ] Manual: open editor → dock appears → Record → smoke scene plays →
      `.avi` appears in `res://media/captures/` → Stop → file playable
      (requires a windowed editor session)

## Notes for later phases

- When `scene_started`/`scene_stopped` land on EditorInterface (PR #103056),
  swap the poll for signal connections — isolated to `backend_movie_maker.gd`.
- Phase 5: recent-captures list, settings registration with
  `add_property_info`, batch manifest export.
- `test/manual/recording_smoke.gd` extends Node — GUT skips it (only
  GutTest subclasses are collected).
