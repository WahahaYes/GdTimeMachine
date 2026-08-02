# Engine-Native Recording Enhancements (before OBS)

Status: Op 1-3 shipped (2026-08-01) — 43 green Op 1, 66 green Op 2, Op 3 measured at 16-18 fps foreground / 1 fps backgrounded (see `SPIKE_screenshot_fps.md`). Next: Op 4 hardening (#5 format dropdown + #6 metadata) before Op 5 screenshot backend.

The queue of improvements we can make using only Godot's built-in recording machinery (Movie Maker + the debugger screenshot channel), before the OBS backend (Phase 3/4) becomes the primary in-place path. OBS remains the long-term answer for "record a running scene with audio at full fps", but everything here is engine-native with zero external deps, and each item either fixes a defect in what we ship today or de-risks the in-place story.

Legend: `[x]` shipped · `[>]` designed, not built · `[~]` needs a spike/verification · `[ ]` idea

Engine facts these build on are cited in `BRAINSTORM_in_place_recording.md` (constraints 1–10, verified against the official `MovieWriter` class docs on 2026-08-01).

______________________________________________________________________

## 1. `[x]` CaptureMode on `RecorderBackend` + grey-out the in-game button — SHIPPED 2026-08-01

The interface generalization from `BRAINSTORM_in_place_recording.md` — the first concrete step of that plan, and the thing that makes the UI honest about what each backend can do.

- `enum CaptureMode { RESTART_SCENE, IN_PLACE }`, `get_capture_mode()` defaulting to `RESTART_SCENE` on the abstract backend.
- `BackendMovieMaker` → `RESTART_SCENE`; future `BackendOBS` / `BackendScreenshotCapture` → `IN_PLACE`.
- `RecorderController` gets a `get_capture_mode()` forwarder so buttons/dock never reach into the backend; `backend_changed` already exists for re-apply.
- GameView toolbar button greys out with an explanatory tooltip when `!recording and mode == RESTART_SCENE` — only the Record state; Stop is always allowed. Run-bar button unchanged (restart is the expected price there).
- Dock "Scene / Use Current" section hides when mode is `IN_PLACE`.

Implemented: `backend/recorder_backend.gd` enum + default, `backend_movie_maker.gd` explicit override, `controller/recorder_controller.gd` forwarder, `plugin.gd` pure `compute_game_view_button_state()` + `_refresh_game_view_button()` wired to `backend_changed`/`recording_*`, `ui/time_machine_dock.gd` SceneRow hide. Tests: `test_recorder_backend.gd` default + `test_recorder_controller.gd` routing/reapply + `test_plugin_button_state.gd` 5-case matrix. 43/43 GUT green.

## 2. `[x]` Graceful-stop autoload — finalize the AVI on Stop — SHIPPED 2026-08-01

Fixes a defect in the current backend: editor Stop SIGKILLs the game (OS::kill SIGKILL at editor_run_bar.cpp:462), so `_write_end()` never runs and the AVI is left without its final index/header.

Doc-verified mechanism: `_write_end()` "occurs when the engine quits by pressing the window manager's close button, or when `SceneTree.quit()` is called" — so a graceful `get_tree().quit()` from the game finalizes the file.

**Shipped design (API correction verified 2026-08-01):** `EditorDebuggerPlugin` does NOT have `send_message()` — editor→game messages are sent on `EditorDebuggerSession` via `get_session(id).send_message("gd_time_machine:graceful_stop", [])`. Game side registers capture name `gd_time_machine`, callable receives payload `graceful_stop` (prefix stripped at remote_debugger.cpp:658-672).

- `autoload/graceful_stop.gd` (game-side Node, no @tool): registers `gd_time_machine` capture in `_ready()`, `_quit_game()` seam (get_tree().quit()) for GUT, unregisters on `_exit_tree`.
- `editor/debugger_plugin.gd` `@tool extends EditorDebuggerPlugin` `GdTMDebuggerPlugin`: `_has_capture` claims `gd_time_machine`, `send_graceful_stop()` broadcasts to all sessions via `get_session(i).send_message()`, fallback to session 0 (single-session editor), `_send_to_session` guards `is_active()` so detached debugger never crashes editor. Placeholder `_capture` for future Op 5 screenshot replies.
- `plugin.gd`: `add_debugger_plugin()` + `add_autoload_singleton(AUTOLOAD_NAME="GdTimeMachineGracefulStop")` on `_enter_tree`, removal in reverse on `_exit_tree` (autoload dirties project.godot [autoload] — crash leaves residue, accepted caveat). Injects debugger plugin into `BackendMovieMaker._debugger_plugin`.
- `backend_movie_maker.gd` funnel: `stop()` sends graceful message BEFORE any SIGKILL fallback, sets `_stopping=true`, arms grace Timer 2.0s (seam `_get_grace_period()` → 0.1s in tests), keeps polling. `_on_poll_timeout` during `_stopping` → finalizes when `!_is_playing_scene()`. `_on_grace_timeout` force-calls `_stop_playing_scene()` then `_finalize_stopped()`. `_finalize_stopped()` single-emission guard (`not _active and not _stopping` → no-op). `_stopping` idempotency + duration-timeout-during-grace ignored. `is_recording()` stays true during grace window.
- Tests: 22 BackendMovieMaker (was 16) incl. graceful-sent-before-stop_playing, single emission via poll, grace-timer fallback, stop-during-grace idempotency, duration-during-grace no-double, natural-exit-no-graceful; 5 autoload harness (quit seam); 13 debugger plugin (contract + mirror behavior) — 66/66 green.

In-editor spike still recommended to verify wire (see `.omo/plans/op2_graceful_stop.md` spike checklist) — AVI idx1 finalization after Stop.

## 3. `[x]` Screenshot-channel FPS spike — MEASURED 2026-08-01 (see `SPIKE_screenshot_fps.md`)

Measured one-in-flight `scene:rq_screenshot` [rq_id] → `game_view:get_screenshot` [id,w,h,path] deferred to idle frame to keep editor responsive. Game must be foreground — verified fix attempt `OS.low_processor_usage_mode=false` did NOT help (reverted).

Results on AMD RENoir/Vulkan/Linux/Godot 4.7.1: 16-18 fps @~720p foreground (55-62ms avg, 136-143 frames/10s), 9.4 fps @1080p mixed, **1.0 fps when game backgrounded** (1000ms sleep, platform/window-manager throttling beyond addon control). Foreground requirement documented for Op 5. One-in-flight pacing with deferred idle yield works — tight loop starved editor. Go for Op 5 as IN_PLACE dev-tool/bug-report backend (16-18 fps zero-dep), OBS remains primary.

Harness was `editor/screenshot_spike_plugin.gd` (removed after measurement) + `test/manual/screenshot_spike.tscn` (removed). Pattern to reuse for Op 5: `EditorDebuggerPlugin` claiming `game_view` prefix, pacing via `call_deferred`, id tracking for multiplexing, `has_capture` only while measuring to avoid shadowing GameViewDebugger.

## 4. `[>]` BackendScreenshotCapture — zero-dep in-place recording

The engine-native way to "record a running scene, stop without killing it". Real-time capture (game simulation untouched, unlike Movie Maker's fixed-fps mode), restart-free, no external software.

- `EditorDebuggerPlugin` subclass: `send_message("scene:rq_screenshot")` on a paced loop (target fps, default ~15), receive `game_view:get_screenshot` via `capture()`/`has_capture()`, buffer PNG paths.
- On stop: write the PNG frames + a small manifest to a capture dir. **No container writer needed** — the engine's own `.png` output mode ("PNG image sequence + WAV, designed to be encoded... with FFmpeg after recording") is the precedent, and the screenshot channel already hands us PNGs. Then run the ffmpeg auto-convert hook (4a) if ffmpeg is available.
- Never queue more than one screenshot request (one-in-flight pacing).
- Known limits to document: no audio; real-time jitter; fps ceiling from the spike.

Depends on: #3 (fps spike), #1 (`CaptureMode` → `IN_PLACE` so buttons behave), #5 (shared format dropdown for the auto-convert target — conversion can ship after, defaulting to OGV/AVI until the dropdown exists). Files: new `backend/backend_screenshot_capture.gd`, editor-debugger-plugin glue, `backend/ffmpeg_convert.gd` (probe + command builder + async runner), new `recording_converted` signal on `recorder_backend.gd` + controller forwarder, dock "Converting…" status + auto-convert/ffmpeg-path settings, GUT fakes for the debugger and `OS.execute`/`Thread` seams. Tests: state machine, one-in-flight pacing, stop-writes-files (fake PNG paths); probe-present → convert invoked, probe-missing → frames kept + status; exit-0 → `recording_converted` + frames dir cleaned, exit-nonzero → frames kept + `recording_error` with stderr tail.

#### 4a. ffmpeg auto-convert hook (conditional)

On `stop()`, after frames + manifest are written:

1. **Probe for ffmpeg.** `OS.execute("ffmpeg", ["-version"], output, true)`; exit 0 → present. An optional `ffmpeg_path` setting (dock/editor) overrides PATH. **If absent → graceful fallback, not an error**: keep the frames dir + manifest and surface "Frames saved — ffmpeg not found (install ffmpeg or convert manually)". No dead end, no failed recording.
1. **Target format = the shared movie-format dropdown (item 5)**, mapped to ffmpeg codec/container pairs:
   - OGV → `-c:v libtheora -q:v <q>` (video only for now — `-an`; no audio channel exists on this backend yet)
   - AVI → `-c:v mjpeg -q:v <q>` (mirrors the engine's MJPEG writer)
   - PNG → no conversion (the sequence dir IS the output, same as the engine's `.png` mode)
   - Future: MP4/H.264, WebM/VP9 as dropdown additions — ffmpeg is not limited to the engine's three writers. Quality `<q>` reuses `ProjectSettings.editor/movie_writer/video_quality` so both backends honor one preference. **(This hook is the "tier 2" mechanism of `BRAINSTORM_tier2_ffmpeg_exports.md` — generalize it to run after *any* backend's `recording_stopped`, not just this one.)**
1. **Never block the editor.** Run the encode on a `Thread` (blocking `OS.execute` inside, capturing stdout/stderr via the output array), then `call_deferred` back to the main thread: exit 0 → emit `recording_converted(backend_name, clip_path)` and clean up the frames dir; nonzero → keep frames + emit `recording_error` with the stderr tail. A `Thread` is preferred over `OS.create_process()` + PID polling because it captures ffmpeg's stderr cross-platform without shell redirection hacks. Lifecycle: the backend must `wait_to_finish()` the thread before free/`_exit_tree` (ffmpeg runs to completion; acceptable to wait).
1. **Timing fidelity.** `-framerate` comes from the **manifest's measured average fps** (frame count / elapsed between first and last capture), not the configured target — the screenshot channel can't hold a steady rate. (v2 alternative: concat demuxer with per-frame durations from the manifest.)
1. **Layout.** `config.output_path` = the final clip path; frames go to a sibling temp dir (`<output_path>.frames/`, zero-padded `frame_%05d.png` for globbability). The manifest is kept either way — it's the manual-convert fallback and future metadata.
1. **Dock UX.** After `recording_stopped`, show "Converting…" until `recording_converted`; show "Frames saved, ffmpeg not found" when the probe fails. Settings row: "Auto-convert with ffmpeg (if available)" toggle + optional custom ffmpeg path.

Verify in the #3 spike: exact `OS.execute`/`Thread` signatures and whether a worker thread may call `OS.execute` while the editor runs (it may — but confirm output-array capture works from a thread).

## 5. `[ ]` Movie Maker output-format dropdown (OGV / AVI / PNG) + 4 GB guard

The engine ships three writers; we currently hardcode AVI via `editor/movie_writer/movie_file`. Surface the choice in the dock. **The dropdown is backend-agnostic**: Movie Maker maps it to the engine's `editor/movie_writer/movie_file` extension; `BackendScreenshotCapture` maps it to an ffmpeg codec/container pair (see 4a). A single "output format" preference drives both backends. Formats a backend can't write natively are produced by the shared tier-2 ffmpeg hook — per-backend tier-1 sets + the format matrix live in `BRAINSTORM_tier2_ffmpeg_exports.md`.

- OGV (Theora + Vorbis): smaller files, has audio, editor-binaries only — good default for most captures.
- AVI (MJPEG + uncompressed audio): current default; **capped at 4 GB** — a long/high-res recording can hit the cap and break the file. Add a size guard or a dock warning.
- PNG sequence + WAV: lossless master for a later FFmpeg encode.

Files: `ui/time_machine_dock.gd` (format selector), `backend_movie_maker.gd` (extension → setting), `recorder_backend.gd` config docs. Tests: config routing for each extension.

## 6. `[ ]` Per-scene `movie_file` root metadata

Docs: "for running single scenes, a `movie_file` metadata can be added to the root node, specifying the path to a movie file that will be used when recording that scene."

We currently write the global `editor/movie_writer/movie_file` ProjectSetting (plus `ProjectSettings.save()` — a side effect on the user's project). Setting `movie_file` metadata on the scene root we launch would scope the path to the recording and avoid polluting global settings.

Verify: that the metadata path wins over / works without the global setting, and that it survives the scene being launched by `play_custom_scene()`. Files: `backend_movie_maker.gd` (`_set_movie_file` seam), manual test. Tests: seam test asserting metadata is set on the launched root node.

## 7. `[ ]` Nice-to-haves

- Editor shortcut / command-palette action for record/stop (no need to hit the tiny toolbar button).
- Show recording state (backend, elapsed, output path) in the editor status bar while recording.
- Dock tooltip explaining fixed-fps (non-real-time) vs real-time capture semantics per backend (constraint 9).

______________________________________________________________________

## Cut line

Items 1–4 are the in-place story: interface honesty (#1), a defect fix for the current backend that doubles as shared infra for #4 (#2), and a measured zero-dep in-place backend (#3 → #4). Item 4a's ffmpeg hook is where #4 meets #5 — the shared format dropdown becomes the single "output format" preference for both backends. Items 5–7 are hardening/polish of the Movie Maker path. OBS (Phase 3/4, sketched in `BRAINSTORM.md`) supersedes #4 as the product answer, but #1–#2 remain relevant regardless, and #5–#6 are backend-agnostic.
