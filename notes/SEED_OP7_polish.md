# GdTimeMachine — Op7 Polish: Seeding Prompt (fresh-context ready)

> Paste this entire block into a fresh agent session. It is self-contained: read the files listed in §2, follow the conventions in §4, implement per §5, test per §6, and land per §7–§8. Do NOT re-research the engine facts in §3 — they were verified against Godot 4.7.1 source and official 4.7 docs on 2026-08-07.

______________________________________________________________________

## 0. Mission

Implement **Op7 (nice-to-haves)** for the GdTimeMachine Godot editor addon — three sub-tasks:

1. **Editor-wide record/stop keyboard shortcut** (no need to hit the tiny toolbar button).
1. **Live recording state in the dock status line** — backend name, elapsed time, output path — updating while recording.
1. **Per-backend capture-semantics tooltips** — explain fixed-fps (non-real-time, Movie Maker) vs real-time (Screenshot) capture.

All three. Tests green (`make test-godot`), docs synced per §8.

______________________________________________________________________

## 1. Project orientation

GdTimeMachine is a **Godot editor plugin addon** (not a game) that records footage of the user's project scenes. Lives in `addons/GdTimeMachine/`. Two recording backends:

- `BackendMovieMaker` — `RESTART_SCENE`: relaunches the scene, Godot's built-in Movie Maker writes a fixed-fps file (AVI/OGV/PNG). Deterministic frame rate.
- `BackendScreenshotCapture` — `IN_PLACE`: captures the *running* scene via the engine debugger screenshot channel into PNG/JPG frames (~15 fps real-time, machine-bound, no audio, game window must be visible/focused).

A tier-2 ffmpeg hook (`GdTMFFmpegConvert`) converts native artifacts to MP4/WebM. That is shipped and verified — **out of scope**; do not touch it.

Architecture rule: the dock talks only to `RecorderController` (signal re-emitter) and the config store — never to a backend directly. The controller exposes: `recording_started(backend_name, output_path)`, `recording_stopped(backend_name, output_path)`, `recording_error(backend_name, message)`, `recording_notice(backend_name, message)`, `recording_converted(backend_name, clip_path)` (guarded by `has_signal`), `backend_changed(backend_name)`, `is_recording()`, `get_capture_mode()`, `start_recording(config)` / `stop_recording()`.

______________________________________________________________________

## 2. Read these first (in order)

1. `notes/ENHANCEMENTS_engine_native_recording.md` — §7 is the Op7 spec; §1–§6 give the conventions used throughout (seams, signal contracts).
1. `notes/SESSION_PLAN_engine_native_recording.md` — Op 7 section (acceptance wording).
1. `addons/GdTimeMachine/plugin.gd` — `_enter_tree`/`_exit_tree`, `_ensure_editor_settings_defaults()` (~line 412), `_setup_run_bar_button()` (~line 173), `_build_record_button()` (~line 224), `_on_record_button_pressed()` (~line 286), `_connect_controller_feedback()` (~line 378).
1. `addons/GdTimeMachine/ui/time_machine_dock.gd` — status row (`_status_label`/`_status_light` onready ~line 122-125), `_set_status()` (~line 800), `_on_recording_started()` (~line 717), `_on_recording_stopped()` (~line 723), `_on_recording_converted()` (~line 769), `_update_backend_tooltip()` (~line 470).
1. `addons/GdTimeMachine/backend/backend_movie_maker.gd` — `get_description()` (~line 94).
1. `addons/GdTimeMachine/backend/backend_screenshot_capture.gd` — `get_description()` (~line 138).
1. Tests: `test/unit/test_plugin_button_state.gd`, `test/unit/test_time_machine_dock.gd`, `test/unit/test_recorder_backend.gd` — these define the test conventions you must mirror.

Also read `AGENTS.md` (repo conventions) and the `Makefile` (targets: `test-godot`, `launch-editor`, `check-docs`, `sync-docs`).

______________________________________________________________________

## 3. Verified engine facts (2026-08-07) — do NOT re-research

### 3a. There is NO editor status bar API in Godot 4.7

`EditorInterface.get_editor_status_bar()` **does not exist**. Verified: official 4.7 `EditorInterface` docs method table (no such method), `class_editorstatusbar.html` is 404, no `editor_status_bar.*` file in the 4.7-stable recursive tree, `EditorStatusBar.xml` 404 at 4.7-stable and master, and zero hits for `get_editor_status_bar` across 1M+ GitHub repos. The thin bottom strip is internal layout — do NOT try to inject into it via `get_base_control()` traversal.

The maintained way to put persistent UI at the bottom of the editor is **`EditorPlugin.add_dock(EditorDock)` with `EditorDock.default_slot = EditorDock.DOCK_SLOT_BOTTOM`** — which this addon **already does** in `plugin.gd` (`_editor_dock`). **Therefore sub-task 2 targets the dock's existing status row** (`_status_label` + `_status_light`), enhanced with a live elapsed timer. That is the correct, honest reading of "status-bar recording state". `EditorInterface.get_editor_toaster().push_toast()` exists but auto-dismisses — not suitable for persistent elapsed state; do not use it for this.

### 3b. Editor-wide shortcut: `EditorSettings.add_shortcut()` + `BaseButton.shortcut`

The official, maintained mechanism (added in Godot 4.6, PR #102889; present in 4.7.1):

- **`EditorSettings.add_shortcut(path: String, shortcut: Shortcut)`** — registers a user-rebindable shortcut. It appears in **Project > Editor Settings > Shortcuts** under the section named by the first path segment (e.g. `gd_time_machine/...` → "gd_time_machine"). User rebinds persist per-editor in `editor_settings-4.7.tres` and survive plugin disable/re-enable (the engine keeps the user's events when the stored "original" meta differs). Safe to call on every `_enter_tree` — it will not clobber user rebinds.
- **`EditorSettings.get_shortcut(path: String)`** — retrieves it (returns the user's rebind if any).
- **`BaseButton.shortcut`** — when set on a Button, the button's `shortcut_input()` fires **editor-wide** whenever the button is visible + enabled in the tree and the key is pressed (`matches_event`), no focus required. It calls `accept_event()`, so the first matching button in the shortcut-input pass wins.
- The class is **`Shortcut`** (Godot 4). There is **no `EditorShortcut`** in 4.x (that was Godot 3).
- **`EditorCommandPalette.add_command(command_name, key_name, callable, shortcut_text="None")`** — the 4th param is a **display-only String**. It does NOT bind any key. Use it only for palette discoverability (pass `shortcut.get_as_text()`). Remember `remove_command(command_name)` in `_exit_tree`.

Caveats (from engine source `base_button.cpp` + `editor_settings.cpp` @ 4.7, sha `eefdc2db`):

- The shortcut fires **after** `gui_input` — a focused control that consumes the key (script editor, Inspector field) wins. So pick an uncommon default like **`Ctrl+Alt+R`** (unmodified letters are the worst choice; avoid F5–F8, used by the run bar). On macOS prefer `Cmd+Alt+R` (meta instead of ctrl).
- Echo/key-repeat is ignored (`!p_event->is_echo()`), so hold-to-repeat won't double-toggle.
- Collisions with built-in editor shortcuts resolve by `accept_event()` order — nondeterministic for the same combo; users can rebind via the Shortcuts tab. Choose a unique default.
- Not OS-global — fires only while the Godot editor window is focused.

### 3c. Reference URLs (already verified; cite if you write notes)

- [EditorSettings.add_shortcut](https://docs.godotengine.org/en/4.7/classes/class_editorsettings.html#class-editorsettings-method-add-shortcut) · [BaseButton.shortcut](https://docs.godotengine.org/en/4.7/classes/class_basebutton.html#class-basebutton-property-shortcut) · [EditorCommandPalette.add_command](https://docs.godotengine.org/en/4.7/classes/class_editorcommandpalette.html#class-editorcommandpalette-method-add-command) · [Feature PR #102889](https://github.com/godotengine/godot/pull/102889) · [add_shortcut impl](https://github.com/godotengine/godot/blob/eefdc2dbda97f89b1d7fd268c91fda99d6a24636/editor/settings/editor_settings.cpp#L2068-L2092) · [BaseButton::shortcut_input](https://github.com/godotengine/godot/blob/eefdc2dbda97f89b1d7fd268c91fda99d6a24636/scene/gui/base_button.cpp#L471-L506)

______________________________________________________________________

## 4. Codebase conventions & hard constraints (non-negotiable)

- All addon scripts are `@tool` and use `class_name` where referenced cross-file.
- **Never call `ProjectSettings.save()`.** The plugin sets editor settings in-memory only. (Also `EditorSettings` is editor-only — guard with `Engine.is_editor_hint()` like `_ensure_editor_settings_defaults()` does.)
- **Extract pure, static logic into testable functions** (precedent: `compute_game_view_button_state()` in `plugin.gd`). Keep seams overridable (`_now()`, factory methods) so GUT can fake clocks/editor.
- **Graceful degradation everywhere**: any editor-UI failure (button not found, etc.) must `push_warning` and degrade — never crash, never block recording.
- Timers in addon nodes are created lazily behind `is_inside_tree()` guards (see `_ensure_timers()` in the backends). Mirror this in the dock.
- Keep behavior for existing users unchanged. Default shortcut must not shadow common editor keys.
- Match the codebase style exactly: GDScript 4, tabs, `_`-prefixed private methods/vars, doc comments (`##`) on every member, typed everything.

______________________________________________________________________

## 5. Implementation map

### 5a. Editor-wide record/stop shortcut

1. In `plugin.gd`, inside `_ensure_editor_settings_defaults()` (or a sibling `_register_recording_shortcut()` called from `_enter_tree`): build a `Shortcut` whose `events` is one `InputEventKey` — `Ctrl+Alt+R` (or `Cmd+Alt+R` on macOS; detect via `OS.get_name() == "macOS"`) — and call `EditorSettings.add_shortcut("gd_time_machine/toggle_recording", shortcut)`. Add property info if desired so it shows under Editor Settings; it appears automatically in the Shortcuts tab via `add_shortcut`.
1. Attach the shortcut to the **run-bar button only** — in `_setup_run_bar_button()` after the button is built: `_run_bar_button.shortcut = EditorSettings.get_shortcut("gd_time_machine/toggle_recording")`. **Do NOT add it in `_build_record_button()`** (that factory is shared with the game-view button, which is only in the tree while a scene plays — attaching there would create a second, intermittently-active shortcut).
   - The run-bar button's `pressed` signal already routes through `_on_record_button_pressed()` → controller toggle → `_apply_button_state()`. Pressing the shortcut triggers the button's `pressed`, so the whole existing flow (record/stop toggle, icon/text state) works for free.
1. Optional but recommended (matches the notes' "command-palette action" wording): in `_enter_tree`, `EditorInterface.get_command_palette().add_command("GdTimeMachine: Toggle Recording", "gd_time_machine_toggle_recording", _on_record_button_pressed, shortcut.get_as_text())`; in `_exit_tree`, `get_command_palette().remove_command("GdTimeMachine: Toggle Recording")` to avoid stale entries across re-enables.

### 5b. Live recording state in the dock status line

Target: the existing `StatusRow` (StatusLight + StatusLabel). While recording, show `Recording [backend] → filename (mm:ss)`; on stop/error/converted, existing behavior (Converting… / Saved / Error) must be preserved.

1. Add a `_recording_started_at` timestamp (ms, via a `_now()` seam — mirror the backends' `_now()` = `Time.get_ticks_msec() / 1000.0`) and a `_recording_backend_name` set in `_on_recording_started()`.
1. Add a 1-second repeating `Timer` (lazy `_ensure_timer()` with `is_inside_tree()` guard, mirroring backend `_ensure_timers()`). Start it in `_on_recording_started()`, stop it in `_on_recording_stopped()`, `_on_recording_error()`, and `_on_recording_converted()`.
1. Timer tick handler: guard `_controller.is_recording()` (single source of truth); compute `elapsed = _now() - _recording_started_at`; format `mm:ss` (or `h:mm:ss` past an hour); update via `_set_status("Recording [%s] → %s (%s)" % [backend, output_path.get_file(), formatted], COLOR_RECORDING)`. Reuse the stored output path from `_on_recording_started`.
1. Keep `_set_recording_ui(true)` behavior unchanged; the status line is the only thing that becomes live.

### 5c. Per-backend capture-semantics tooltips

The dock already composes `_update_backend_tooltip()` from a generic note + `active_backend.get_description()`. Extend the two backend `get_description()` strings to state capture semantics explicitly:

- `BackendMovieMaker`: mention **fixed-fps, non-real-time** — the scene is restarted and playback is deterministically paced; output rate equals the configured FPS regardless of editor performance.
- `BackendScreenshotCapture`: mention **real-time** — the game sim runs at normal speed, capture is machine-bound (~15 fps typical), no audio, window must stay visible/focused.

(Precedent: the screenshot backend's existing `get_description()` already documents limits — follow that style. This is the "constraint 9" semantics note from the spec.)

______________________________________________________________________

## 6. Tests to write/extend (GUT, `test/unit/`, run `make test-godot`)

Mirror existing patterns exactly (pure-logic fakes, seam overrides, no real editor UI):

1. **Shortcut** — new `test_plugin_shortcut.gd` or extend `test_plugin_button_state.gd`: a pure helper (e.g. `build_toggle_shortcut()`) returns a `Shortcut` with exactly one `InputEventKey`, correct keycode + ctrl/alt (or meta) flags, and `shortcut.get_as_text()` contains the expected combo. If you extract a `_should_use_meta()`/OS seam, test both branches.
1. **Dock elapsed status** — extend `test_time_machine_dock.gd`: fake controller emits `recording_started(backend, path)` → assert the tick handler computes `mm:ss` from a faked `_now()`; timer stops on `recording_stopped`/`recording_error`/`recording_converted` (assert no further ticks); `_controller.is_recording()` guard respected; existing "Converting…"/"Saved" flows still emit their statuses after the live timer stops.
1. **Tooltips** — extend `test_recorder_backend.gd` (or the backend tests): assert `BackendMovieMaker.get_description()` and `BackendScreenshotCapture.get_description()` each mention the semantics keyword (fixed-fps / real-time) — keeps the tooltip contract locked.
1. Keep every existing test green. Do not delete or weaken tests.

______________________________________________________________________

## 7. Definition of done + verification

- [ ] `make test-godot` → **all green** (currently 199/199 — do not regress).
- [ ] Manual windowed check via `make launch-editor`: shortcut toggles recording from the dock's focus, from the script editor, and from the inspector (proving editor-wide firing); dock status line counts elapsed live while recording and resets correctly on stop/error/converted; both backends' tooltips show semantics text.
- [ ] No `ProjectSettings.save()` added anywhere. No new dependencies. No changes to `GdTMFFmpegConvert` or backend capture logic.
- [ ] `make check-docs` passes (README root vs addon copy).

## 8. Docs to update (AGENTS.md convention)

- `notes/SESSION_PLAN_engine_native_recording.md` — mark Op 7 shipped, note the 199→N test count, the `add_shortcut` API correction (research said "command palette", reality is `EditorSettings.add_shortcut` + `BaseButton.shortcut`), and the status-bar reframe (no `get_editor_status_bar()` in 4.7 → dock status row).
- `notes/ENHANCEMENTS_engine_native_recording.md` — flip item 7 to `[x]` with shipped detail.
- `README.md` (root + addon, then `make sync-docs`) — mention the shortcut + live status in the "What works today" list if the change is user-visible enough.

______________________________________________________________________

## 9. Harness / tooling notes

- `make test-godot` runs GUT headless (`test/` dir, include_subdirs). Use it liberally.
- `make launch-editor` launches the pinned Godot 4.7.1 (godotenv) for manual checks.
- `make sync-docs` / `make check-docs` keep root↔addon README/LICENSE consistent.
- codegraph is indexed for this repo but **stale** (only ~12 files, mostly GUT docs) — use `Read`/`Grep` directly on addon files; treat codegraph results as hints only.
