# Session Plan — Engine-Native Recording Enhancements

Date: 2026-08-01 Based on: `ENHANCEMENTS_engine_native_recording.md`, `BRAINSTORM_in_place_recording.md` Update 2026-08-01: Op 1-2 shipped (66 GUT green incl. graceful-stop funnel, ButtonState matrix, CaptureMode). Research ses_041598e3dffeO0PR0i4m6iIrH6 verified EditorDebuggerSession.send_message API. Op 3 measured: 16-18 fps @720p fg / 1 fps bg (see `SPIKE_screenshot_fps.md`). Status: ✅ Op 1-3 shipped, spike code cleaned, ready for Op 4 hardening.

## Goal

Execute the engine-native enhancement backlog in dependency order: interface honesty (#1), the AVI-finalization defect fix (#2), a measured go/no-go for the zero-dep in-place backend (#3), hardening of the shipping Movie Maker path (#5+#6), then the in-place story itself (#4 → #4a), with polish last (#7).

## Execution order (locked)

**#1 → #2 → #3 → #5+#6 → #4 → #4a → #7**

```
#1 CaptureMode ─────────────────────────┐
#2 Graceful stop (debugger plumbing) ───┼──► #4 ScreenshotCapture ──► #4a ffmpeg
#3 FPS spike (go/no-go) ────────────────┘         ▲ convert target
#5+#6 Movie Maker hardening ──────────────────────┘
#7 nice-to-haves — anytime
```

Rationale: #5+#6 sit before #4 because they are unconditional value (Movie Maker remains the deterministic fixed-fps path even after OBS lands) while #4 is spike-gated — and #4a needs #5's dropdown as its convert target on arrival.

## Op specs

### Op 1 — #1 CaptureMode + honest UI (no deps, small) — SHIPPED 2026-08-01

- `backend/recorder_backend.gd`: `enum CaptureMode { RESTART_SCENE, IN_PLACE }`, `get_capture_mode()` defaulting to `RESTART_SCENE`. BackendMovieMaker relies on the default (explicit override optional, documentation value only).
- `controller/recorder_controller.gd`: null-safe `get_capture_mode()` forwarder.
- `plugin.gd`: extract a pure `_compute_button_state(recording, mode)` for testability; **wire buttons to `backend_changed`** (gap found during spec — buttons currently only listen to `recording_started`/`recording_stopped`, so the grey-out would go stale on backend switch). Grey out only the GameView button, only when `!recording and mode == RESTART_SCENE`; Stop always enabled; run-bar and dock buttons unchanged.
- `ui/time_machine_dock.gd`: hide `$SettingsGroup/SceneRow` when `IN_PLACE`.
- Tests: default mode on abstract base; controller routing; button-state matrix incl. re-apply on `backend_changed`/`recording_*` (fake IN_PLACE backend).
- **Shipped:** 43/43 green.

### Op 2 — #2 Graceful-stop autoload (no deps; builds #4 infra) — SHIPPED 2026-08-01 (66/66 green)

- Task 0 (30 min, in-editor): verify `EditorDebuggerPlugin.send_message` → game-side `EngineDebugger.register_message_capture` round-trip with a throwaway script. **API correction:** `EditorDebuggerPlugin` does NOT have `send_message()` — it lives on `EditorDebuggerSession` via `get_session(id).send_message("gd_time_machine:graceful_stop", [])`. Verified against engine source (editor_debugger_plugin.cpp:63-66, remote_debugger.cpp:658-672) and wild addons (beehave, dialogue_manager, godot-statecharts, cozy-cube relays).
- New `autoload/graceful_stop.gd`: capture `gd_time_machine` prefix → payload `graceful_stop` → `get_tree().quit()` behind `_quit_game()` seam. Registered via `add_autoload_singleton()` on `_enter_tree`, removed on `_exit_tree`.
- One `EditorDebuggerPlugin` subclass (`editor/debugger_plugin.gd` `GdTMDebuggerPlugin`) registered in `plugin.gd` — this same registration hosts Op 5's screenshot loop later. `send_graceful_stop()` broadcasts to all sessions + fallback to session 0, `_send_to_session` guards `is_active()`.
- **Stop-flow rework** (race found during spec): today `stop()` emits `recording_stopped` then kills playback; with a graceful quit the poll sees not-playing and `_finalize_stopped()` would emit a second time. New funnel: `stop()` sends the message, sets `_stopping`, starts a ~2s grace timer; poll-observed exit or timer expiry → single `_finalize_stopped()`; timer expiry also force-calls `_stop_playing_scene()` as fallback. All stop paths (manual, duration, natural exit) converge on the one emission site. `_active` stays true during grace so `is_recording()` remains true and double-stop is idempotent.
- Tests: message sent before `_stop_playing_scene()`; autoload quit seam; single emission across stop paths; force-stop fallback; duration-during-grace no-double; EditorDebuggerPlugin contract+mirror behavior. 66/66 green.
- In-editor spike checklist lives in `.omo/plans/op2_graceful_stop.md` — still recommended for AVI idx1 manual verification.

### Op 3 — #3 Screenshot FPS spike (gates Op 5) — MEASURED 2026-08-01 (see SPIKE_screenshot_fps.md)

- Measured `scene:rq_screenshot` [rq_id] → `game_view:get_screenshot` [id,w,h,path] one-in-flight, deferred idle yield, at 720p 16-18 fps fg / 1 fps bg, 1080p 9.4 fps mixed. Game must be foreground — low_processor fix attempt reverted after proving ineffective. Pattern abstracted for reuse in Op 5: id tracking, has_capture only while measuring to avoid shadowing GameViewDebugger, deferred send_next, stddev measurement.
- Thread ffmpeg probe: `OS.execute` output-array capture from worker Thread verified via dock button (exit 0 no freeze).
- Deliverable: `notes/SPIKE_screenshot_fps.md` + go/no-go: **GO** — 16-18 fps @720p fg = low-end product viable dev-tool, OBS remains primary.
- Spike code cleaned: `editor/screenshot_spike_plugin.gd`, `test/manual/screenshot_spike.*` removed after measurement, SPIKE_ENABLED conditionals removed, no lingering refs — ready to promote pattern to `BackendScreenshotCapture`.

### Op 4 — #5+#6 Movie Maker hardening batch (no deps) — SHIPPED 2026-08-01

- #5: dock format dropdown (OGV / AVI / PNG) persisted under `gd_time_machine/recorder/output_format`; **default stays AVI** (decision 2026-08-01 — no behavior change for existing users; OGV opt-in). Extension → `editor/movie_writer/movie_file` routing in the backend; `_build_output_path` uses the selected extension. AVI selected → dock warning label about the 4 GB cap. OGV row/tooltip notes editor-binaries-only.
- #6 (spike-gated): verify root-node `movie_file` metadata wins over the global setting and survives `play_custom_scene()`. If yes → set metadata on the launched root, drop the global write. If no → restore-on-stop. Either way the `ProjectSettings.save()` pollution dies (decision reversal — see below); metadata covers `movie_file` only, so `fps` gets restore-on-stop regardless.
- Tests: config routing per extension; metadata/restore seam assertions.
- **Shipped:** dropdown (GdTMOutputFormat + `test_output_format.gd`), AVI 4 GB dock warning, and restore-on-stop for `movie_file`+`fps` (no `ProjectSettings.save()` anywhere). Spike outcome: metadata is **NO-GO** — `play_custom_scene()` (RUN_CUSTOM) skips the metadata block, only `play_current_scene()` (RUN_CURRENT) reads it (see `SPIKE_movie_metadata.md`). Remaining: manual windowed verify (see Open items).

### Op 5 — #4 BackendScreenshotCapture core (deps: #1, #2, #3-go)

- New `backend/backend_screenshot_capture.gd`, `CaptureMode.IN_PLACE`: paced one-in-flight `scene:rq_screenshot` loop (target fps default ~15) on the Op-2 debugger plugin; buffer received PNG paths.
- On stop: write frames (`<output_path>.frames/frame_%05d.png`) + manifest (measured average fps, frame count, elapsed) → `recording_stopped`. No container writer, no conversion in this op.
- Tests: state machine, one-in-flight pacing, stop-writes-files (fakes for debugger + file seams).

### Op 6 — #4a ffmpeg auto-convert (deps: #4, #5)

- Probe (`ffmpeg -version`, optional `ffmpeg_path` override) → graceful frames-kept fallback when absent (not an error).
- Convert target = #5's dropdown → codec map (OGV→libtheora `-an`, AVI→mjpeg, PNG→no-op); quality from `editor/movie_writer/video_quality`; `-framerate` from the manifest's measured average fps.
- `Thread` + blocking `OS.execute` (stderr capture), `call_deferred` back: exit 0 → new `recording_converted` signal (base + controller forwarder) + frames dir cleaned; nonzero → frames kept + `recording_error` with stderr tail. `wait_to_finish()` before free/`_exit_tree`.
- Dock: "Converting…" status until `recording_converted`; auto-convert toggle
  - ffmpeg-path settings rows.

### Op 7 — #7 nice-to-haves (tail)

- Record/stop editor shortcut; status-bar recording state; dock tooltip on fixed-fps vs real-time semantics per backend.

## Key decisions

- **Hardening batch (#5+#6) before #4** — unconditional value first; the dropdown exists when #4a needs it. (2026-08-01)
- **AVI remains the default format** — OGV/PNG opt-in via the new dropdown; no behavior change for existing users. (2026-08-01)
- **Stop-flow single-emission funnel** — all stop paths converge on `_finalize_stopped()`; grace timer with force-stop fallback. Fixes the double-emit race the graceful quit introduces.
- **One `EditorDebuggerPlugin` registration** hosts both the graceful-stop send (#2) and the screenshot loop (#4).
- **Reversal of a Phase-2 decision**: `movie_file`/`fps` are currently written to the user's project.godot via `ProjectSettings.save()` on every recording (recorded as deliberate in `SESSION_PLAN_phase2.md`). #6 removes that pollution via root-node metadata (spike-gated) or restore-on-stop; `fps` always gets restore-on-stop.
- **Autoload footprint caveat (accepted)**: `add_autoload_singleton` dirties the user's project.godot while the plugin is enabled; removed on `_exit_tree`, but an editor crash leaves residue. Documented, not blocking.

## Acceptance checklist (per op)

- [ ] Op 1: `make test-godot` green incl. button-state matrix; GameView button greys with tooltip on Movie Maker, enabled on (fake) IN_PLACE backend
- [ ] Op 2: stop emits graceful-stop message before playback stops; AVI finalized (index/header present) after editor-initiated Stop — manual windowed verification
- [ ] Op 3: fps numbers at 720p/1080p + go/no-go appended to this note
- [ ] Op 4: dropdown routes all three extensions; AVI 4 GB warning shown; no `movie_file`/`fps` residue in project.godot after a recording
- [ ] Op 5: frames + manifest written on stop; game never restarts; GUT green
- [ ] Op 6: probe-present → converted clip + frames cleaned; probe-missing → frames kept + status; nonzero exit → frames kept + stderr tail
- [ ] Op 7: shortcut, status-bar state, semantics tooltip

## Open items

- Op 3 spike results pending — Op 5 scope (product feature vs dev tool) depends on the measured ceiling.
- #6 metadata spike outcome selects metadata vs restore-on-stop for `movie_file`.
