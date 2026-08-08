# Engine-Native Recording Enhancements (before OBS)

Status: Op 1-3 shipped (2026-08-01) — 43 green Op 1, 66 green Op 2, Op 3 measured at 16-18 fps foreground / 1 fps backgrounded (see `SPIKE_screenshot_fps.md`). Scene-aware profiles + config-store refactor shipped same day (see `SESSION_scene_aware_profiles.md`) — that session also delivered the format dropdown + 4 GB dock warning (#5) and the `EditorDock` migration (see `SESSION_editordock_migration.md`). 106/106 GUT green. Op 4 shipped — #5 dropdown + #6 `project.godot` pollution fixed via restore-on-stop (metadata approach NO-GO, see `SPIKE_movie_metadata.md`). **Op 5 shipped 2026-08-02 (152/152)** — `BackendScreenshotCapture` core + IN_PLACE handling. **Op 6 shipped 2026-08-03 (199/199)** — #4a ffmpeg tier-2 hook (`ffmpeg_convert.gd`) + MP4/WebM tier-2 targets in the dropdown; verified end-to-end. Remaining: Op 7 polish, OBS (Phase 3/4), CLI companion.

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

## 4. `[x]` BackendScreenshotCapture — zero-dep in-place recording — SHIPPED 2026-08-02, ffmpeg hook (#4a) 2026-08-03

The engine-native way to "record a running scene, stop without killing it". Real-time capture (game simulation untouched, unlike Movie Maker's fixed-fps mode), restart-free, no external software. **Shipped** (see `SESSION_PLAN_engine_native_recording.md` Op 5 + Op 6): IN_PLACE state machine (pending-start scene launch, one-in-flight pacing, no-reply/duration timeouts), copy-on-receipt PNG/JPG frames into `<output>.frames/` + manifest (measured fps, count, elapsed, dims), zero/low-frame → `recording_stopped` + notice (not error), `recording_notice` channel, and the **4a ffmpeg hook wired in** (frames→MP4/WebM/AVI/OGV on stop when auto-convert is on).

- `EditorDebuggerPlugin` subclass: `send_message("scene:rq_screenshot")` on a paced loop (target fps, default ~15), receive `game_view:get_screenshot` via `capture()`/`has_capture()`, buffer PNG paths.
- On stop: write the PNG frames + a small manifest to a capture dir. **No container writer needed** — the engine's own `.png` output mode ("PNG image sequence + WAV, designed to be encoded... with FFmpeg after recording") is the precedent, and the screenshot channel already hands us PNGs. Then run the ffmpeg auto-convert hook (4a) if ffmpeg is available.
- Never queue more than one screenshot request (one-in-flight pacing).
- Known limits to document: no audio; real-time jitter; fps ceiling from the spike.

Depends on: #3 (fps spike), #1 (`CaptureMode` → `IN_PLACE` so buttons behave), #5 (shared format dropdown for the auto-convert target — shipped 2026-08-01, so 4a maps formats to codec/container pairs directly). Files: new `backend/backend_screenshot_capture.gd`, editor-debugger-plugin glue, `backend/ffmpeg_convert.gd` (probe + command builder + async runner), new `recording_converted` signal on `recorder_backend.gd` + controller forwarder, dock "Converting…" status + auto-convert/ffmpeg-path settings, GUT fakes for the debugger and `OS.execute`/`Thread` seams. Tests: state machine, one-in-flight pacing, stop-writes-files (fake PNG paths); probe-present → convert invoked, probe-missing → frames kept + status; exit-0 → `recording_converted` + frames dir cleaned, exit-nonzero → frames kept + `recording_error` with stderr tail.

#### 4a. ffmpeg auto-convert hook — SHIPPED 2026-08-03 (Op 6)

On `stop()`, after frames + manifest are written — and generally after *any* backend's `recording_stopped` (generalized to the backend-agnostic tier-2 hook, per `BRAINSTORM_tier2_ffmpeg_exports.md`):

1. **Probe for ffmpeg.** `OS.execute("ffmpeg", ["-version"], output, true)`; exit 0 → present. An optional `ffmpeg_path` setting (`gd_time_machine/ffmpeg/path`) overrides PATH. **If absent → graceful fallback, not an error**: keep the frames dir + manifest and surface "ffmpeg not found — frames kept". No dead end, no failed recording.
1. **Target format = the shared movie-format dropdown (item 5)**, mapped to ffmpeg codec/container pairs:
   - MP4 → `-c:v libx264 -crf <q> -pix_fmt yuv420p -movflags +faststart` (+ `-c:a aac` for file input)
   - WebM → `-c:v libvpx-vp9 -crf 31 -b:v 0` (+ `-c:a libopus`)
   - AVI → `-c:v mjpeg -q:v <q>`
   - OGV → `-c:v libtheora -q:v <q> -an`
   - PNG/JPG → no conversion (the sequence dir IS the output, same as the engine's `.png` mode) Quality `<q>` reuses `ProjectSettings.editor/movie_writer/video_quality` so both backends honor one preference. MP4/WebM are dropdown additions beyond the engine's three writers — the hook's "tier 2" mechanism is backend-agnostic, running after any backend's `recording_stopped`.
1. **Never block the editor.** Run the encode on a `Thread` (blocking `OS.execute` inside, capturing stdout/stderr via the output array), then `call_deferred` back to the main thread: exit 0 → emit `recording_converted(backend_name, clip_path)` and clean up the frames dir (per `gd_time_machine/ffmpeg/clean_frames`); nonzero → keep frames + emit `recording_error` with the stderr tail; missing → `ffmpeg_not_found` notice. A `Thread` is preferred over `OS.create_process()` + PID polling because it captures ffmpeg's stderr cross-platform without shell redirection hacks. Lifecycle: the backend must `wait_to_finish()` the thread before free/`_exit_tree` (ffmpeg runs to completion; acceptable to wait).
1. **Timing fidelity.** `-framerate` comes from the **manifest's measured average fps** (frame count / elapsed between first and last capture), not the configured target — the screenshot channel can't hold a steady rate. (v2 alternative: concat demuxer with per-frame durations from the manifest.)
1. **Layout.** `config.output_path` = the final clip path; frames go to a sibling temp dir (`<output_path>.frames/`, zero-padded `frame_%05d.png` for globbability). The manifest is kept either way — it's the manual-convert fallback and future metadata.
1. **Dock UX.** After `recording_stopped`, show "Converting…" until `recording_converted`; show "Frames saved, ffmpeg not found" when the probe fails. Settings: "Auto-convert with ffmpeg (if available)" toggle + custom ffmpeg path (`Project > Editor Settings` under `gd_time_machine/ffmpeg/`).

Implemented (Op 6): `backend/ffmpeg_convert.gd` `GdTMFFmpegConvert` (probe, frame/file command builders, sync + async `Thread` runners, stderr tail, recursive cleanup, `wait_to_finish` on `_exit_tree`/`NOTIFICATION_PREDELETE`), `recording_converted` on base + controller forwarder, both backends trigger conversion in `_finalize_stopped`, dock "Converting…"/converted status. Tests: `test_ffmpeg_convert.gd` (211), backend convert-trigger tests. Verified end-to-end: in-editor AVI→MP4/WebM artifacts (2026-08-03) + headless frames→video smoke test against real capture data.

Verify in the #3 spike: exact `OS.execute`/`Thread` signatures and whether a worker thread may call `OS.execute` while the editor runs (it may — but confirm output-array capture works from a thread).

## 5. `[x]` Movie Maker output-format dropdown (OGV / AVI / PNG) + 4 GB guard — SHIPPED 2026-08-01

The engine ships three writers; we no longer hardcode AVI. **The dropdown is backend-agnostic**: Movie Maker maps it to the engine's `editor/movie_writer/movie_file` extension (the output path's extension drives the engine's writer); `BackendScreenshotCapture` maps it to an ffmpeg codec/container pair (see 4a). A single "output format" preference drives both backends. Formats a backend can't write natively are produced by the shared tier-2 ffmpeg hook — per-backend tier-1 sets + the format matrix live in `BRAINSTORM_tier2_ffmpeg_exports.md`.

- OGV (Theora + Vorbis): smaller files, has audio, editor-binaries only — good default for most captures.
- AVI (MJPEG + uncompressed audio): current default; **capped at 4 GB** — a long/high-res recording can hit the cap and break the file. Guard shipped as a dock warning ("AVI is capped at 4 GB…"); a hard size guard can follow if the warning proves insufficient.
- PNG sequence + WAV: lossless master for a later FFmpeg encode.

Implemented: `config/output_format.gd` (`GdTMOutputFormat` — shared enum → extension → display name → warning text), dock format selector + warning row (`ui/time_machine_dock.gd` `_format_option` / `_update_format_warning()`), `build_config()` routes `output_format` → extension → output path, which the backend sets as `movie_file`. Tests: `test_output_format.gd` (routing/parsing for each extension). Remaining: the format → ffmpeg codec/container mapping for the screenshot backend, which lands with Op 4a.

## 6. `[x]` No `project.godot` pollution (`movie_file`/`fps`) — RESOLVED via restore-on-stop — SHIPPED 2026-08-01

The original idea — per-scene `movie_file` metadata on the scene root (docs: "for running single scenes, a `movie_file` metadata can be added to the root node…") — is **NO-GO for this addon**, verified in `SPIKE_movie_metadata.md` against `editor_run_bar.cpp:280-364`:

- The engine reads `movie_file` metadata **only in RUN_CURRENT** (`play_current_scene()`/F6, on the in-memory edited scene root); `play_custom_scene()` (RUN_CUSTOM) skips the metadata block and always falls back to the global `editor/movie_writer/movie_file`. Our backend launches via `play_custom_scene()`, so metadata can never fire for the dock's arbitrary-scene flow — and it would cover `movie_file` only, never `fps`.

Shipped instead (the plan's pre-specified fallback branch): **restore-on-stop** in `backend_movie_maker.gd` — capture the previous `editor/movie_writer/movie_file` + `fps` on `start()`, set the new values **in-memory with no `ProjectSettings.save()`** (the child reads them via GLOBAL_GET), restore on `_finalize_stopped()` and the duration-error path. Same pollution removal, works for any scene path, covers both settings. Tests: restore seams in `test_backend_movie_maker.gd`. Remaining: manual windowed check that the child sees the in-memory value without `save()` (spike "Open item left") — bundled with Op 2's AVI-finalization verify.

## 7. `[ ]` Nice-to-haves

- Editor shortcut / command-palette action for record/stop (no need to hit the tiny toolbar button).
- Show recording state (backend, elapsed, output path) in the editor status bar while recording.
- Dock tooltip explaining fixed-fps (non-real-time) vs real-time capture semantics per backend (constraint 9).

## 8. `[x]` Scene-aware profiles + shared config store — SHIPPED 2026-08-01

Not engine-native per se, but shipped in the same effort and it reshaped how per-scene settings work — the "scene-specific settings" the dock offers today. The dock follows the open scene (`EditorPlugin.scene_changed` / `scene_closed` forwarded from `plugin.gd`) and auto-saves/loads per-scene profiles on switch; `CompositeConfigStore` resolves scene override > `profiles.cfg` `[default]` > `EditorSettings`, with `profiles.cfg` as the source of truth (first-run seed from EditorSettings, write-through on save). Also delivered alongside it: the `EditorDock` migration (deprecated `add_control_to_bottom_panel`) and the #5 format dropdown.

Full detail: `SESSION_scene_aware_profiles.md` + `SESSION_editordock_migration.md`. 106/106 GUT green.

______________________________________________________________________

## Cut line

Items 1–4 are the in-place story: interface honesty (#1), a defect fix for the current backend that doubles as shared infra for #4 (#2), and a measured zero-dep in-place backend (#3 → #4). Item 4a's ffmpeg hook is where #4 meets #5 — the shared format dropdown (shipped) becomes the single "output format" preference for both backends; the format → codec/container mapping is the only part of #5 still pending, and it lands with 4a. Item 8's config store + scene-aware profiles is the dock/UX side of the same effort. Item 7 is polish of the Movie Maker path; #6's pollution fix already shipped via restore-on-stop. OBS (Phase 3/4, sketched in `BRAINSTORM.md`) supersedes #4 as the product answer, but #1–#2 and #8 remain relevant regardless, and #5 is backend-agnostic.
