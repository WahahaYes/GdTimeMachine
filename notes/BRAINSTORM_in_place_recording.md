# Brainstorm — "Record from the current state" (no restart)

The GameView toolbar Record button works, but it *restarts* the scene because it drives Godot's Movie Maker, which is a process-launch feature. This note explores whether the interface can instead record the **running** scene and stop **without killing it**.

Status: brainstorm + proposal, engine-doc verified (2026-08-01); nothing implemented.

______________________________________________________________________

## The ask

- Press Record while a scene is already playing → capture **from that moment**, no restart, no visible blink.
- Press Stop → finalize the file; the scene keeps running.

## Verified constraints (Godot 4.7 source + official class docs)

1. **Movie Maker is a startup-argument feature.** The game always runs as a separate OS process; `EditorRun::run()` (`editor/run/editor_run.cpp`) appends `--write-movie <path> --fixed-fps <fps>` when the toggle is on. The `MovieWriter` singleton is created from that flag in `Main::setup()` (`main.cpp:3800`), `begin()` at `main.cpp:4855`, driven per-frame by `Main::iteration()` (`main.cpp:5150`). **You cannot attach a MovieWriter to an already-running process.** → restart is inherent to this backend. The official docs say it plainly: "Toggling Movie Maker mode does not affect project instances that are already running."

1. **AVI finalization only happens on clean shutdown.** `movie_writer->end()` (`main.cpp:5241`) runs inside `Main::cleanup()`. `write_end()` is what writes the `idx1` index and patches the RIFF header sizes (`movie_writer_mjpeg.cpp:230`). Skipped → file is header-0 / no index (usually still playable via chunk scanning, but technically un-finalized). Docs: `_write_end()` "occurs when the engine quits by pressing the window manager's close button, or when `SceneTree.quit()` is called" — and, inversely, "Pressing Ctrl + C on the terminal running the editor/project does _not_ result in `_write_end()` being called." **The graceful path is `get_tree().quit()` from the game** (this is the doc-verified basis for the graceful-stop autoload in `ENHANCEMENTS_engine_native_recording.md`).

1. **The editor's Stop button SIGKILLs the game.** `EditorRunBar::stop_playing()` (`editor_run_bar.cpp:462`) → `editor_run.stop()` → `OS::kill()` per pid → `::kill(p_pid, SIGKILL)` (`drivers/unix/os_unix.cpp`). SIGKILL cannot be caught → `Main::cleanup()` never runs in the game → no AVI finalization. This affects the **built-in** Movie Maker too when stopped from the editor.

1. **No editor→game graceful-quit message exists.** The debugger `request_quit` message is game→editor only (`script_editor_debugger.cpp:906` — the *editor* handles it when the *game* asks to stop). `EditorDebuggerNode::stop()` (`editor_debugger_node.cpp:305`) just closes the server. There is no "please quit and finalize your movie" channel — but a plugin can *add* one: `EditorDebuggerPlugin.send_message()` + a game-side `EngineDebugger.register_message_capture()` is exactly the gap the graceful-stop autoload fills (`ENHANCEMENTS_engine_native_recording.md` #2).

1. **`MovieWriter` is scriptable but not runtime-attachable.** It has GDVIRTUALs (`_write_begin/_write_frame/_write_end`) and a static `add_writer()` (`movie_writer.cpp:138`), so custom writers can be registered — but the engine only *drives* the singleton that was picked at startup via `find_writer_for_file()`. Registering a writer mid-run does nothing; the engine has no runtime "start recording" hook. The docs set the registration deadline explicitly: `add_writer()` "must be called early enough in the engine initialization to work, as movie writing is designed to start at the same time as the rest of the engine." (Custom writers are officially supported — GDExtension recommended — but only at engine init.)

1. **There IS a working channel to the running game: the debugger screenshot.** `EditorDebuggerPlugin` exposes `send_message()`, `has_capture()`, `capture()`. Game-side `SceneDebugger::_msg_rq_screenshot` (`scene/debugger/scene_debugger.cpp`) saves the viewport PNG to a temp file and replies `game_view:get_screenshot` with `[path, size]`. This is the only established, restart-free way to pull the game's current pixels into the editor.

1. **PNG image sequence + WAV is a built-in output format.** The `.png` extension writer outputs a PNG sequence + WAV, "designed to be encoded to a video file with another tool such as FFmpeg after recording." The screenshot channel already hands us PNGs, so an in-place backend needs **no custom container writer** — just write the received frames to a directory (plus a manifest), exactly like the engine's own PNG output mode.

1. **AVI output is capped at 4 GB.** "AVI output is currently limited to a file of 4 GB in size at most" — long or high-res Movie Maker recordings can hit the cap and break the file.

1. **Movie Maker recording is non-real-time.** Recording "forces the reported `delta` in `Node._process()`... to be identical across frames, regardless of how long it actually took to render the frame" — the game's simulation locks to the movie fps while recording. The screenshot channel and OBS record real-time and leave the game untouched. Two different capture philosophies with a real semantic difference for the UI to communicate.

1. **The docs sanction OBS for gameplay recording.** "Players wishing to record gameplay videos should install tools such as OBS Studio or SimpleScreenRecorder instead." → the long-term in-place answer is engine-doc-endorsed, not just our preference.

## Options

### A. Debugger screenshot capture (in-place, engine-native, zero deps)

The plugin drives `scene:rq_screenshot` in a loop while "recording", collects PNG paths, and assembles them into an output file on Stop.

- **Pros**: records the *actual current state*, game never restarts, Stop does not touch the game. Uses existing engine plumbing only. Real-time capture — the game's simulation is not perturbed (unlike Movie Maker's fixed-fps mode, constraint 9).
- **Cons**:
  - **FPS is low**: every frame is a full-viewport PNG encode (CPU) + TCP + file write. Realistic ceiling ~10–30 fps at 720p, less at 1080p.
  - **No audio**: the screenshot channel carries no sound stream.
  - **PNG-sequence output only (no container writer)**: we write the received PNGs to a directory + manifest; the engine's own `.png` output mode (constraint 7) is the precedent. Encoding to a real video is the user's FFmpeg step — same as the built-in PNG writer.

### B. Runtime MovieWriter activation (dead end without an engine patch)

Registering a custom `MovieWriter` via `add_writer()` at runtime doesn't work: the engine only calls `add_frame()` on the startup singleton. Patching `Main` to allow late activation (`Engine::set_write_movie_path()` mid-run) is an upstream-engine change — out of scope for an addon unless we maintain a fork. The docs make the timing requirement explicit: `add_writer()` "must be called early enough in the engine initialization to work" (constraint 5).

### C. State snapshot + relaunch (restart, but "from here")

Serialize the running scene's state (PackedScene / SceneState), stop the game, relaunch with `--write-movie`, restore the snapshot.

- **Pros**: full Movie Maker quality (AVI, audio, real fps); reuses the existing backend.
- **Cons**: still a visible restart; Godot has **no general "save full runtime state"** API (timers, physics, animations, RNG, shaders are lost). Fidelity is low except for trivial scenes. High complexity for a worse UX than A/E.

### D. OBS backend (the planned Phase 3/4 answer)

OBS captures the live game window at full fps with audio; the addon only talks to obs-websocket. Start/Stop are pure OBS commands — the game is untouched.

- **Pros**: exactly the requested UX (record current state, stop without killing the scene), full quality + audio, no engine involvement. Already sketched in `BRAINSTORM.md`. The engine docs recommend exactly this class of tool for gameplay recording (constraint 10).
- **Cons**: OBS must be installed/configured; embedded-game-window capture is a known issue (godot#103154) — separate-window mode is the reliable target.

## Proposed implementation

### 1. Backend capability flag (interface change, small)

Extend `RecorderBackend` with a capture-mode enum so the UI can be honest:

```gdscript
enum CaptureMode { RESTART_SCENE, IN_PLACE }
func get_capture_mode() -> CaptureMode: return CaptureMode.RESTART_SCENE  # default
```

- `BackendMovieMaker` → `RESTART_SCENE` (unchanged behavior).
- New `BackendOBS` → `IN_PLACE`.
- Optional `BackendScreenshotCapture` → `IN_PLACE`.

### 2. Button behavior adapts (plugin.gd)

- Run-bar button: unchanged (restart-from-idle is acceptable there).
- `RecorderController` re-emits `backend_changed` already → buttons can react.

#### Special case: the in-game (GameView toolbar) button

This button is where the restart surprise hurts most — the user is *looking at their running scene* and presses Record, only for it to vanish and reboot. Grey-out-with-tooltip is the right special case for it, and it's cheap:

- **Grey out when the active backend can't record in place.** When `active_backend.get_capture_mode() == RESTART_SCENE`, set `button.disabled = true` (Godot's disabled theme automatically greys the button) and set `button.tooltip_text` to something explicit, e.g.: `"Recording with the Movie Maker backend restarts the scene. Switch to the OBS backend in the dock to record without restarting."`
- **Tooltip on hover works even when disabled.** `Button.disabled` does not suppress tooltips in Godot, so the explanatory text is exactly what the hover shows — no extra hover handler needed.
- **Only grey the "Record" state, never "Stop".** If a Movie Maker recording is already running (started from the dock or run bar), the game-view button should stay enabled showing "Stop" — stopping is the user's explicit action, and it doesn't restart anything. Tie grey-out to `!recording and mode == RESTART_SCENE`, not to the mode alone.
- **Re-apply on backend switch.** `backend_changed` must re-run the grey-out logic, otherwise switching to OBS in the dock while the game view is open leaves the button stale. Same for `recording_started`/`recording_stopped`.
- **Why not a confirm dialog instead?** A `pressed` → `AcceptDialog` ("This will restart the scene. Continue?") preserves a one-click path but still makes the restart *feel* sanctioned. Grey-out is stricter: it says "this backend fundamentally can't do what you're asking from here." The run-bar button keeps restart semantics, so the capability isn't lost — it's just relocated to where a restart is the expected price of recording.
- **Future nuance:** once `BackendOBS` exists, the grey-out disappears and the button becomes a plain Record/Stop toggle against the running game — the original intent of the button. If both backends are ever selectable at runtime, the tooltip should name the switch path (dock backend dropdown), not hardcode "OBS".

### 3. BackendScreenshotCapture (in-place fallback, if we want zero-deps)

- On `start()`: register an `EditorDebuggerPlugin` subclass; `send_message` `scene:rq_screenshot` at a target fps (configurable, default ~15); receive `game_view:get_screenshot` via `capture()`/`has_capture()`; buffer paths.
- On `stop()`: write the buffered PNGs + a small manifest to a capture dir — PNG-sequence output, **no container writer** (constraint 7); emit `recording_stopped`. Game untouched. Encoding to a video is the user's FFmpeg step, mirroring the engine's own `.png` mode.
- Real-time capture (constraint 9): the game keeps its true delta; no fixed-fps perturbation.
- Risks to verify before committing: screenshot round-trip latency (measure!), no audio (document), frame pacing (request one frame at a time, never queue).

### 4. Order of work

1. `CaptureMode` on `RecorderBackend` + `BackendMovieMaker` returns `RESTART_SCENE`; GUT tests.
1. Game-view button grey-out + tooltip keyed on `!recording and mode == RESTART_SCENE`; re-apply on `backend_changed`/`recording_*` signals; GUT tests for the state transitions.
1. `BackendOBS` (IN_PLACE) — the real long-term answer; port the websocket work already sketched in `BRAINSTORM.md`.
1. Only if OBS is rejected by users: `BackendScreenshotCapture` as the zero-dependency IN_PLACE option (accepting low fps / no audio).

See `notes/ENHANCEMENTS_engine_native_recording.md` for the full engine-native backlog this plan belongs to (graceful-stop autoload, screenshot backend, movie format dropdown, per-scene `movie_file` metadata).

## Open questions / risks

- **AVI finalization on Stop (affects current backend too)**: the editor's Stop SIGKILLs the game, so today's `BackendMovieMaker.stop()` likely leaves the AVI without its final index/header. The fix is doc-verified: `_write_end()` runs when the game quits via `SceneTree.quit()` (constraint 2), so a game-side autoload that quits on a debugger message finalizes the file. Planned as the graceful-stop autoload in `ENHANCEMENTS_engine_native_recording.md`.
- **Screenshot fps ceiling** must be measured before betting on Option A.
- **Embedded vs separate window** for OBS capture (godot#103154).
- **Non-real-time vs real-time semantics** (constraint 9): Movie Maker locks the simulation to the movie fps while recording; in-place capture does not. Fine for footage, but the dock should communicate the difference.
- **AVI 4 GB cap** (constraint 8) on long Movie Maker recordings.
- **OGV/Theora is editor-binaries only** — fine for editor recording, but the format dropdown must not promise OGV in exported projects.

## Files

- `addons/gd-time-machine/backend/recorder_backend.gd` — add `CaptureMode`
- `addons/gd-time-machine/backend/backend_movie_maker.gd` — return `RESTART_SCENE`
- `addons/gd-time-machine/controller/recorder_controller.gd` — expose mode
- `addons/gd-time-machine/plugin.gd` — button enable/tooltip per mode
- `test/unit/test_recorder_controller.gd` — GUT: `get_capture_mode()` routing
- `test/unit/test_plugin_button_state.gd` — GUT: grey-out state transitions (or fold into the existing controller/backend suites)
- `notes/BRAINSTORM.md` — existing OBS websocket sketches
- Reference: official `MovieWriter` class docs (https://docs.godotengine.org/en/stable/classes/class_moviewriter.html)
- Reference: `/tmp/opencode/movie_writer_mjpeg.cpp` (container writer), the fetched Godot 4.7 sources

_Proposal only — nothing committed yet._
