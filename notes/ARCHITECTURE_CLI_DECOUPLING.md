# Architecture — Decoupling CLI from Editor

**Context:** `GdTimeMachine` v0.1.0 shipped with three backends (`BackendMovieMaker`, `BackendScreenshotCapture`, `BackendOBS`) all coupled to `EditorInterface` (`is_playing_scene`, `play_custom_scene`, `set_movie_maker_enabled`, `is_movie_maker_enabled`) via `RecorderBackend` → `RecorderController` → `ui/time_machine_dock.gd`. The CLI (`addons/GdTimeMachine/cli/main.gd` + `cli/record.gd` + `gdtime` wrapper) is headless (`Engine.is_editor_hint() == false`, `godot --headless -s` or `godot --path <worktree> -s`), has no `EditorInterface`, and must be self-contained in `addons/GdTimeMachine/` (only path that ships via Asset Library).

Attempting to reuse `RecorderController`/`Backend*` from the CLI headless led to:

- `Parse Error: Identifier "RecorderController" not declared` (missing `preload` in worktree at HEAD)
- `Nonexistent function 'is_playing_scene' in base 'EditorInterface'` (headless has no editor)
- `0-byte .avi` with `headless` dummy renderer (`texture_2d_get` at `dummy/storage/texture_storage.h:110`) when using `godot --headless --write-movie` (dummy cannot capture)
- `Couldn't detect whether to run the editor... Aborting` at `main/main.cpp:4352` when mixing `--headless`, `--path`, and `-s` incorrectly
- `OS.execute("sh", ["-c", "echo \"hello world\" > log"], out, true)` truncates after the quoted space (Godot `out` array bug) — fixed via temp `sh` script + `exec > log`

Manual `godot --path /tmp/test-worktree --write-movie /tmp/cli_manual_test.avi --fixed-fps 30 --quit-after 90 res://test/manual/recording_smoke.tscn` **without `--headless`** (Vulkan) succeeded with `2.0M, 90 frames` — proving the headless `dummy` path is the wrong driver for movie capture.

## Change

Split the addon into **core (headless-safe)** and **editor (EditorInterface-dependent)**.

**New `addons/GdTimeMachine/core/` (no `Node`, no `EditorInterface`, no `SceneTree`):**

- `core/movie_writer.gd` — pure `RefCounted` with `static func record(worktree_path, scene, output, fps, duration, godot_bin) -> int` that builds `godot --path <worktree> --write-movie <output> --fixed-fps <fps> --quit-after <frames> <scene>` (no `--headless`), runs via `OS.create_process`, waits, returns exit code, and leaves `output` as absolute path so it survives `worktree remove`.
- `core/worktree.gd` — `add/remove/prune/list` wrappers around `git worktree` (already in `cli/main.gd`, move there).
- `core/godot_resolve.gd` — `godotenv` → `godot_path` → `which godot` → `GODOT_BIN` (already in `cli/main.gd`).
- `core/build_runner.gd` — `OS.set_environment("GDTM_*")` + temp `sh` script + `exec > log` (the quoting fix), returns exit code.

**Keep in `core/` (already granular):**

- `config/output_format.gd` (`GdTMOutputFormat`), `backend/ffmpeg_convert.gd` (`GdTMFFmpegConvert` as `RefCounted`, not `add_child` on `SceneTree`).

**Remain `editor/` (not imported by CLI):**

- `backend/recorder_backend.gd`, `backend/backend_obs.gd`, `backend/backend_screenshot_capture.gd`, `backend/backend_movie_maker.gd` (all `extends Node` + `EditorInterface`), `controller/recorder_controller.gd`, `ui/time_machine_dock.gd`, `plugin.gd`, `editor/debugger_plugin.gd`.

**CLI (`addons/GdTimeMachine/cli/main.gd` + `cli/gdtime` wrapper) then depends only on `core/` + `config/` + `backend/ffmpeg_convert.gd`:**

- `cli/main.gd:run` does `worktree.add` → `godot_resolve` → `build_runner.run` → `movie_writer.record` → `ffmpeg_convert` if `output` is `mp4`/`webm`. No `RecorderController`, no `is_playing_scene`, no `record.gd` headless branch.
- `cli/record.gd` becomes **editor-only** (or deleted) — it currently tries to reuse `RecorderController` headless and needs `preload` + `root.add_child` fixes that are unnecessary once `core/movie_writer.gd` exists.
- `cli/main.gd` already handles `gdtime` wrapper (`godot --headless -s cli/main.gd`), `validate`/`doctor`/`run --dry-run/--no-git/--keep-*`, `git` fallback (`--no-git` = `HEAD`-only), and `doctor` probes (`git`, `godot`, `ffmpeg`, `OBS`, `build hook` warn-only, `output_dir`, `worktree`). No change there.

**Why:**

- CLI must run as `godot --headless -s cli/main.gd` (no editor) and still produce video files that populate `media/captures/history/...` (globalized absolute path, not worktree `res://`). Using `core/movie_writer.gd` with `godot --path <worktree> --write-movie` (no `--headless`, Vulkan) is the only path that gave `2.0M` in manual tests; `godot --headless --write-movie` with dummy stays `0-byte`.
- Keeps the Asset Library zip self-contained: `core/` + `cli/` + `config/` + `backend/ffmpeg_convert.gd` are all under `addons/GdTimeMachine/`; `tools/` stays deleted.

**Out of scope for this doc:**

- `notes/BUG_headless_movie.md` holds the full repro + diagnosis; this doc is the forward architecture.
- No `CHANGELOG` until `v0.1.1`; `CONTRIBUTING.md` stays as is.
