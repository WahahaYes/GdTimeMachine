# Session Plan — Engine-Native Recording Enhancements

Date: 2026-08-01 Based on: `ENHANCEMENTS_engine_native_recording.md`,
`BRAINSTORM_in_place_recording.md` Status: ✅ Aligned — ready to implement,
nothing built yet

## Goal

Execute the engine-native enhancement backlog in dependency order: interface
honesty (#1), the AVI-finalization defect fix (#2), a measured go/no-go for the
zero-dep in-place backend (#3), hardening of the shipping Movie Maker path
(#5+#6), then the in-place story itself (#4 → #4a), with polish last (#7).

## Execution order (locked)

**#1 → #2 → #3 → #5+#6 → #4 → #4a → #7**

```
#1 CaptureMode ─────────────────────────┐
#2 Graceful stop (debugger plumbing) ───┼──► #4 ScreenshotCapture ──► #4a ffmpeg
#3 FPS spike (go/no-go) ────────────────┘         ▲ convert target
#5+#6 Movie Maker hardening ──────────────────────┘
#7 nice-to-haves — anytime
```

Rationale: #5+#6 sit before #4 because they are unconditional value (Movie Maker
remains the deterministic fixed-fps path even after OBS lands) while #4 is
spike-gated — and #4a needs #5's dropdown as its convert target on arrival.

## Op specs

### Op 1 — #1 CaptureMode + honest UI (no deps, small)

- `backend/recorder_backend.gd`: `enum CaptureMode { RESTART_SCENE, IN_PLACE }`,
  `get_capture_mode()` defaulting to `RESTART_SCENE`. BackendMovieMaker relies
  on the default (explicit override optional, documentation value only).
- `controller/recorder_controller.gd`: null-safe `get_capture_mode()` forwarder.
- `plugin.gd`: extract a pure `_compute_button_state(recording, mode)` for
  testability; **wire buttons to `backend_changed`** (gap found during spec —
  buttons currently only listen to `recording_started`/`recording_stopped`, so
  the grey-out would go stale on backend switch). Grey out only the GameView
  button, only when `!recording and mode == RESTART_SCENE`; Stop always enabled;
  run-bar and dock buttons unchanged.
- `ui/time_machine_dock.gd`: hide `$SettingsGroup/SceneRow` when `IN_PLACE`.
- Tests: default mode on abstract base; controller routing; button-state matrix
  incl. re-apply on `backend_changed`/`recording_*` (fake IN_PLACE backend).

### Op 2 — #2 Graceful-stop autoload (no deps; builds #4 infra)

- Task 0 (30 min, in-editor): verify `EditorDebuggerPlugin.send_message` →
  game-side `EngineDebugger.register_message_capture` round-trip with a
  throwaway script.
- New `autoload/graceful_stop.gd`: capture `gd_time_machine:graceful_stop` →
  `get_tree().quit()` behind a seam. Registered via `add_autoload_singleton()`
  on `_enter_tree`, removed on `_exit_tree`.
- One `EditorDebuggerPlugin` subclass registered in `plugin.gd` — this same
  registration hosts Op 5's screenshot loop later.
- **Stop-flow rework** (race found during spec): today `stop()` emits
  `recording_stopped` then kills playback; with a graceful quit the poll sees
  not-playing and `_finalize_stopped()` would emit a second time. New funnel:
  `stop()` sends the message, sets `_stopping`, starts a ~2s grace timer;
  poll-observed exit or timer expiry → single `_finalize_stopped()`; timer
  expiry also force-calls `_stop_playing_scene()` as fallback. All stop paths
  (manual, duration, natural exit) converge on the one emission site.
- Tests: message sent before `_stop_playing_scene()`; autoload quit seam; single
  emission across stop paths; force-stop fallback.

### Op 3 — #3 Screenshot FPS spike (gates Op 5)

- Time `scene:rq_screenshot` round-trips at 720p and 1080p; answer "is
  one-in-flight pacing sufficient for steady pacing?"
- Fold in 4a's open question: does `OS.execute` output-array capture work from a
  worker `Thread`?
- Deliverable: numbers + go/no-go recommendation appended to this note.

### Op 4 — #5+#6 Movie Maker hardening batch (no deps)

- #5: dock format dropdown (OGV / AVI / PNG) persisted under
  `gd_time_machine/recorder/output_format`; **default stays AVI** (decision
  2026-08-01 — no behavior change for existing users; OGV opt-in). Extension →
  `editor/movie_writer/movie_file` routing in the backend; `_build_output_path`
  uses the selected extension. AVI selected → dock warning label about the 4 GB
  cap. OGV row/tooltip notes editor-binaries-only.
- #6 (spike-gated): verify root-node `movie_file` metadata wins over the global
  setting and survives `play_custom_scene()`. If yes → set metadata on the
  launched root, drop the global write. If no → restore-on-stop. Either way the
  `ProjectSettings.save()` pollution dies (decision reversal — see below);
  metadata covers `movie_file` only, so `fps` gets restore-on-stop regardless.
- Tests: config routing per extension; metadata/restore seam assertions.

### Op 5 — #4 BackendScreenshotCapture core (deps: #1, #2, #3-go)

- New `backend/backend_screenshot_capture.gd`, `CaptureMode.IN_PLACE`: paced
  one-in-flight `scene:rq_screenshot` loop (target fps default ~15) on the Op-2
  debugger plugin; buffer received PNG paths.
- On stop: write frames (`<output_path>.frames/frame_%05d.png`) + manifest
  (measured average fps, frame count, elapsed) → `recording_stopped`. No
  container writer, no conversion in this op.
- Tests: state machine, one-in-flight pacing, stop-writes-files (fakes for
  debugger + file seams).

### Op 6 — #4a ffmpeg auto-convert (deps: #4, #5)

- Probe (`ffmpeg -version`, optional `ffmpeg_path` override) → graceful
  frames-kept fallback when absent (not an error).
- Convert target = #5's dropdown → codec map (OGV→libtheora `-an`, AVI→mjpeg,
  PNG→no-op); quality from `editor/movie_writer/video_quality`; `-framerate`
  from the manifest's measured average fps.
- `Thread` + blocking `OS.execute` (stderr capture), `call_deferred` back: exit
  0 → new `recording_converted` signal (base + controller forwarder) + frames
  dir cleaned; nonzero → frames kept + `recording_error` with stderr tail.
  `wait_to_finish()` before free/`_exit_tree`.
- Dock: "Converting…" status until `recording_converted`; auto-convert toggle
  - ffmpeg-path settings rows.

### Op 7 — #7 nice-to-haves (tail)

- Record/stop editor shortcut; status-bar recording state; dock tooltip on
  fixed-fps vs real-time semantics per backend.

## Key decisions

- **Hardening batch (#5+#6) before #4** — unconditional value first; the
  dropdown exists when #4a needs it. (2026-08-01)
- **AVI remains the default format** — OGV/PNG opt-in via the new dropdown; no
  behavior change for existing users. (2026-08-01)
- **Stop-flow single-emission funnel** — all stop paths converge on
  `_finalize_stopped()`; grace timer with force-stop fallback. Fixes the
  double-emit race the graceful quit introduces.
- **One `EditorDebuggerPlugin` registration** hosts both the graceful-stop send
  (#2) and the screenshot loop (#4).
- **Reversal of a Phase-2 decision**: `movie_file`/`fps` are currently written
  to the user's project.godot via `ProjectSettings.save()` on every recording
  (recorded as deliberate in `SESSION_PLAN_phase2.md`). #6 removes that
  pollution via root-node metadata (spike-gated) or restore-on-stop; `fps`
  always gets restore-on-stop.
- **Autoload footprint caveat (accepted)**: `add_autoload_singleton` dirties the
  user's project.godot while the plugin is enabled; removed on `_exit_tree`, but
  an editor crash leaves residue. Documented, not blocking.

## Acceptance checklist (per op)

- [ ] Op 1: `make test-godot` green incl. button-state matrix; GameView button
  greys with tooltip on Movie Maker, enabled on (fake) IN_PLACE backend
- [ ] Op 2: stop emits graceful-stop message before playback stops; AVI
  finalized (index/header present) after editor-initiated Stop — manual windowed
  verification
- [ ] Op 3: fps numbers at 720p/1080p + go/no-go appended to this note
- [ ] Op 4: dropdown routes all three extensions; AVI 4 GB warning shown; no
  `movie_file`/`fps` residue in project.godot after a recording
- [ ] Op 5: frames + manifest written on stop; game never restarts; GUT green
- [ ] Op 6: probe-present → converted clip + frames cleaned; probe-missing →
  frames kept + status; nonzero exit → frames kept + stderr tail
- [ ] Op 7: shortcut, status-bar state, semantics tooltip

## Open items

- Op 3 spike results pending — Op 5 scope (product feature vs dev tool) depends
  on the measured ceiling.
- #6 metadata spike outcome selects metadata vs restore-on-stop for
  `movie_file`.
