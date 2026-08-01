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
4. **Dock moved from DOCK_SLOT_RIGHT_BL to the bottom panel** (user request) —
   `add_control_to_bottom_panel(_dock, "GdTimeMachine")`, same place as GUT.
5. **Run-bar record button** (user request): a "Record"/"Stop" toggle inserted
   into the editor's `EditorRunBar` button row (next to Play/Stop/Movie-Maker).
   Uses `_dock.build_config()` so it records with the dock's current settings.
   - Traversal: `EditorInterface.get_base_control()` → class "EditorRunBar" →
     first "PanelContainer" → first HBoxContainer child.
   - **Timing gotcha**: the run bar isn't fully built during plugin
     `_enter_tree` nor at end-of-frame deferred calls — insert on the first
     `process_frame` (CONNECT_ONE_SHOT).
   - Graceful degradation: any traversal failure → `push_warning`, no button,
     dock still fully functional.
6. **Game view toolbar record button** (user request — "the Input, 2D, 3D bar
   that pops up when a scene plays"). The bar IS plugin-reachable via
   traversal — the earlier "not plugin-accessible" assumption was wrong.
   - Structure (verified via probe dump + Godot 4.7 source
     `editor/run/game_view_plugin.cpp`): `GameView` (C++) → `MarginContainer`
     (toolbar margin) → `HBoxContainer` (toolbar row) with 6 sections:
     `process_hb | input_hb | selection_hb | audio_hb | camera_hb |
     embedding_hb`. The "Input/2D/3D" buttons are `input_hb`'s
     `node_type_button[]`.
   - **The toolbar is built ONCE in the GameView constructor and never
     rebuilt** — `_update_ui()`/`_update_debugger_buttons()`/
     `_sessions_changed()` only toggle button states. An injected button
     survives play/stop cycles.
   - The button is inserted as a new section at index 2 (right after
     `input_hb`, before `selection_hb`); the `embedding_hb` section
     (EXPAND_FILL, holds the FPS label + window options) stays far right.
   - Same first-`process_frame` insertion + `push_warning` degradation as the
     run bar; idempotent re-setup (GameView persists across plugin re-enables);
     cleanup removes the whole section in `_exit_tree`.
7. **4.7 internals research** (raw.githubusercontent.com, tag `4.7`):
   - `editor/run/editor_run.cpp`: the game always runs as a **separate OS
     process** (`OS::create_instance`); Movie Maker is enabled by appending
     `--write-movie <path> --fixed-fps <fps> [--disable-vsync]` — matching the
     backend's seam design exactly.
   - `editor/run/embedded_process.cpp`: the embedded game view embeds that
     subprocess into the editor window via
     `DisplayServer::embed_process()` (PID-based).
   - `editor/run/game_view_plugin.cpp`: GameView class + toolbar constructor
     (see #6).

## Acceptance checklist

- [x] `make test-godot` → all 34 tests pass
- [x] `godot --headless --import` → no script errors
- [x] `godot --headless --editor --quit` → clean plugin/dock load
- [x] Run-bar button present in the editor run bar (verified via probe)
- [x] Game view toolbar button present at section index 2, right after the
      Input/2D/3D group (verified via probe: `GameView → MarginContainer →
      HBoxContainer → section[2] = GdTimeMachineRecord`)
- [ ] Manual: open editor → dock appears → Record → smoke scene plays →
      `.avi` appears in `res://media/captures/` → Stop → file playable
      (requires a windowed editor session)
- [ ] Manual: run-bar button starts/stops a recording using the dock's
      current settings
- [ ] Manual: game view toolbar button starts/stops a recording while a
      scene plays (requires a windowed editor session)

## Notes for later phases

- When `scene_started`/`scene_stopped` land on EditorInterface (PR #103056),
  swap the poll for signal connections — isolated to `backend_movie_maker.gd`.
- Phase 5: recent-captures list, settings registration with
  `add_property_info`, batch manifest export.
- `test/manual/recording_smoke.gd` extends Node — GUT skips it (only
  GutTest subclasses are collected).
