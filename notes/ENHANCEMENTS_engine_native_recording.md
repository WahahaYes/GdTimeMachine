# Engine-Native Recording Enhancements (before OBS)

Status: brainstorm backlog — nothing implemented yet.

The queue of improvements we can make using only Godot's built-in recording
machinery (Movie Maker + the debugger screenshot channel), before the OBS
backend (Phase 3/4) becomes the primary in-place path. OBS remains the long-term
answer for "record a running scene with audio at full fps", but everything here
is engine-native with zero external deps, and each item either fixes a defect in
what we ship today or de-risks the in-place story.

Legend: `[>]` designed, not built · `[~]` needs a spike/verification · `[ ]`
idea

Engine facts these build on are cited in `BRAINSTORM_in_place_recording.md`
(constraints 1–10, verified against the official `MovieWriter` class docs on
2026-08-01).

______________________________________________________________________

## 1. `[>]` CaptureMode on `RecorderBackend` + grey-out the in-game button

The interface generalization from `BRAINSTORM_in_place_recording.md` — the first
concrete step of that plan, and the thing that makes the UI honest about what
each backend can do.

- `enum CaptureMode { RESTART_SCENE, IN_PLACE }`, `get_capture_mode()`
  defaulting to `RESTART_SCENE` on the abstract backend.
- `BackendMovieMaker` → `RESTART_SCENE`; future `BackendOBS` /
  `BackendScreenshotCapture` → `IN_PLACE`.
- `RecorderController` gets a `get_capture_mode()` forwarder so buttons/dock
  never reach into the backend; `backend_changed` already exists for re-apply.
- GameView toolbar button greys out with an explanatory tooltip when
  `!recording and mode == RESTART_SCENE` — only the Record state; Stop is always
  allowed. Run-bar button unchanged (restart is the expected price there).
- Dock "Scene / Use Current" section hides when mode is `IN_PLACE`.

Files: `backend/recorder_backend.gd`, `backend/backend_movie_maker.gd`,
`controller/recorder_controller.gd`, `plugin.gd`, `ui/time_machine_dock.gd`.
Tests: default mode on the abstract base; `get_capture_mode()` routing via the
controller; button grey-out state transitions (Record disabled when
`!recording + RESTART_SCENE`, enabled when recording or `IN_PLACE`, re-applied
on `backend_changed`/`recording_*`).

## 2. `[>]` Graceful-stop autoload — finalize the AVI on Stop

Fixes a defect in the current backend: editor Stop SIGKILLs the game, so
`_write_end()` never runs and the AVI is left without its final index/header.

Doc-verified mechanism: `_write_end()` "occurs when the engine quits by pressing
the window manager's close button, or when `SceneTree.quit()` is called" — so a
graceful `get_tree().quit()` from the game finalizes the file.

Design:

- Addon ships a game-side autoload (`autoload/graceful_stop.gd`) injected via
  `EditorPlugin.add_autoload_singleton()` on `_enter_tree`, removed on
  `_exit_tree` — no permanent footprint in the user's project.
- The autoload registers
  `EngineDebugger.register_message_capture( "gd_time_machine:graceful_stop", ...)`;
  on message → `get_tree().quit()`.
- `BackendMovieMaker.stop()` (and the plugin's stop path) first sends
  `gd_time_machine:graceful_stop` to the running game via an
  `EditorDebuggerPlugin.send_message()`, then stops playback.
- Side benefit: window-close on the game window already finalizes, so manual
  quits are safe too.

Verify in a spike: `EngineDebugger.register_message_capture` from GDScript +
`EditorDebuggerPlugin.send_message` round-trip (both documented APIs).

Files: new `autoload/graceful_stop.gd`, `plugin.gd` (debugger plugin
registration), seam on `backend_movie_maker.gd` for the send. Tests: stop flow
emits the message before `_stop_playing_scene()`; autoload calls `quit()` on
message (via a seam on `get_tree().quit()` so GUT can fake it headlessly).

## 3. `[~]` Screenshot-channel FPS spike (measure before betting)

A 30-minute spike to time `scene:rq_screenshot` round-trips at 720p and 1080p
(PNG encode on the game side + TCP + file write + decode on the editor side).
This number decides whether the zero-dep in-place backend is viable as a product
feature or only a dev tool.

Deliverable: measured fps per resolution on one machine, plus the answer to "is
one screenshot request in flight at a time sufficient for steady pacing?"

## 4. `[>]` BackendScreenshotCapture — zero-dep in-place recording

The engine-native way to "record a running scene, stop without killing it".
Real-time capture (game simulation untouched, unlike Movie Maker's fixed-fps
mode), restart-free, no external software.

- `EditorDebuggerPlugin` subclass: `send_message("scene:rq_screenshot")` on a
  paced loop (target fps, default ~15), receive `game_view:get_screenshot` via
  `capture()`/`has_capture()`, buffer PNG paths.
- On stop: write the PNG frames + a small manifest to a capture dir. **No
  container writer needed** — the engine's own `.png` output mode ("PNG image
  sequence + WAV, designed to be encoded... with FFmpeg after recording") is the
  precedent, and the screenshot channel already hands us PNGs. Then run the
  ffmpeg auto-convert hook (4a) if ffmpeg is available.
- Never queue more than one screenshot request (one-in-flight pacing).
- Known limits to document: no audio; real-time jitter; fps ceiling from the
  spike.

Depends on: #3 (fps spike), #1 (`CaptureMode` → `IN_PLACE` so buttons behave),
#5 (shared format dropdown for the auto-convert target — conversion can ship
after, defaulting to OGV/AVI until the dropdown exists). Files: new
`backend/backend_screenshot_capture.gd`, editor-debugger-plugin glue,
`backend/ffmpeg_convert.gd` (probe + command builder + async runner), new
`recording_converted` signal on `recorder_backend.gd` + controller forwarder,
dock "Converting…" status + auto-convert/ffmpeg-path settings, GUT fakes for the
debugger and `OS.execute`/`Thread` seams. Tests: state machine, one-in-flight
pacing, stop-writes-files (fake PNG paths); probe-present → convert invoked,
probe-missing → frames kept + status; exit-0 → `recording_converted` + frames
dir cleaned, exit-nonzero → frames kept + `recording_error` with stderr tail.

#### 4a. ffmpeg auto-convert hook (conditional)

On `stop()`, after frames + manifest are written:

1. **Probe for ffmpeg.** `OS.execute("ffmpeg", ["-version"], output, true)`;
   exit 0 → present. An optional `ffmpeg_path` setting (dock/editor) overrides
   PATH. **If absent → graceful fallback, not an error**: keep the frames dir +
   manifest and surface "Frames saved — ffmpeg not found (install ffmpeg or
   convert manually)". No dead end, no failed recording.
1. **Target format = the shared movie-format dropdown (item 5)**, mapped to
   ffmpeg codec/container pairs:
   - OGV → `-c:v libtheora -q:v <q>` (video only for now — `-an`; no audio
     channel exists on this backend yet)
   - AVI → `-c:v mjpeg -q:v <q>` (mirrors the engine's MJPEG writer)
   - PNG → no conversion (the sequence dir IS the output, same as the engine's
     `.png` mode)
   - Future: MP4/H.264, WebM/VP9 as dropdown additions — ffmpeg is not limited
     to the engine's three writers. Quality `<q>` reuses
     `ProjectSettings.editor/movie_writer/video_quality` so both backends honor
     one preference.
1. **Never block the editor.** Run the encode on a `Thread` (blocking
   `OS.execute` inside, capturing stdout/stderr via the output array), then
   `call_deferred` back to the main thread: exit 0 → emit
   `recording_converted(backend_name, clip_path)` and clean up the frames dir;
   nonzero → keep frames + emit `recording_error` with the stderr tail. A
   `Thread` is preferred over `OS.create_process()` + PID polling because it
   captures ffmpeg's stderr cross-platform without shell redirection hacks.
   Lifecycle: the backend must `wait_to_finish()` the thread before
   free/`_exit_tree` (ffmpeg runs to completion; acceptable to wait).
1. **Timing fidelity.** `-framerate` comes from the **manifest's measured
   average fps** (frame count / elapsed between first and last capture), not the
   configured target — the screenshot channel can't hold a steady rate. (v2
   alternative: concat demuxer with per-frame durations from the manifest.)
1. **Layout.** `config.output_path` = the final clip path; frames go to a
   sibling temp dir (`<output_path>.frames/`, zero-padded `frame_%05d.png` for
   globbability). The manifest is kept either way — it's the manual-convert
   fallback and future metadata.
1. **Dock UX.** After `recording_stopped`, show "Converting…" until
   `recording_converted`; show "Frames saved, ffmpeg not found" when the probe
   fails. Settings row: "Auto-convert with ffmpeg (if available)" toggle +
   optional custom ffmpeg path.

Verify in the #3 spike: exact `OS.execute`/`Thread` signatures and whether a
worker thread may call `OS.execute` while the editor runs (it may — but confirm
output-array capture works from a thread).

## 5. `[ ]` Movie Maker output-format dropdown (OGV / AVI / PNG) + 4 GB guard

The engine ships three writers; we currently hardcode AVI via
`editor/movie_writer/movie_file`. Surface the choice in the dock. **The dropdown
is backend-agnostic**: Movie Maker maps it to the engine's
`editor/movie_writer/movie_file` extension; `BackendScreenshotCapture` maps it
to an ffmpeg codec/container pair (see 4a). A single "output format" preference
drives both backends.

- OGV (Theora + Vorbis): smaller files, has audio, editor-binaries only — good
  default for most captures.
- AVI (MJPEG + uncompressed audio): current default; **capped at 4 GB** — a
  long/high-res recording can hit the cap and break the file. Add a size guard
  or a dock warning.
- PNG sequence + WAV: lossless master for a later FFmpeg encode.

Files: `ui/time_machine_dock.gd` (format selector), `backend_movie_maker.gd`
(extension → setting), `recorder_backend.gd` config docs. Tests: config routing
for each extension.

## 6. `[ ]` Per-scene `movie_file` root metadata

Docs: "for running single scenes, a `movie_file` metadata can be added to the
root node, specifying the path to a movie file that will be used when recording
that scene."

We currently write the global `editor/movie_writer/movie_file` ProjectSetting
(plus `ProjectSettings.save()` — a side effect on the user's project). Setting
`movie_file` metadata on the scene root we launch would scope the path to the
recording and avoid polluting global settings.

Verify: that the metadata path wins over / works without the global setting, and
that it survives the scene being launched by `play_custom_scene()`. Files:
`backend_movie_maker.gd` (`_set_movie_file` seam), manual test. Tests: seam test
asserting metadata is set on the launched root node.

## 7. `[ ]` Nice-to-haves

- Editor shortcut / command-palette action for record/stop (no need to hit the
  tiny toolbar button).
- Show recording state (backend, elapsed, output path) in the editor status bar
  while recording.
- Dock tooltip explaining fixed-fps (non-real-time) vs real-time capture
  semantics per backend (constraint 9).

______________________________________________________________________

## Cut line

Items 1–4 are the in-place story: interface honesty (#1), a defect fix for the
current backend that doubles as shared infra for #4 (#2), and a measured
zero-dep in-place backend (#3 → #4). Item 4a's ffmpeg hook is where #4 meets #5
— the shared format dropdown becomes the single "output format" preference for
both backends. Items 5–7 are hardening/polish of the Movie Maker path. OBS
(Phase 3/4, sketched in `BRAINSTORM.md`) supersedes #4 as the product answer,
but #1–#2 remain relevant regardless, and #5–#6 are backend-agnostic.
