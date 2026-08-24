# Bug — Headless Movie Capture

**Symptom:** `gdtime run` on `GdTimeMachine` itself (via `cli/main.gd` → `cli/record.gd` headless) fails with either:

- `Couldn't detect whether to run the editor, the project manager or a specific project. Aborting. at main/main.cpp:4352`
- or `Movie Maker mode enabled, recording movie in 1152×648 @ 30 FPS...` then `0-byte .avi` + `texture_2d_get` with `headless` dummy, or `record: headless movie output not found` after 5s kill.

**Repro (GdTimeMachine, HEAD):**

```json
{
  "project_root": "/home/ethan/repos/GdTimeMachine",
  "output_dir": "res://media/captures/history_test",
  "captures": [{ "commit": "HEAD", "scene": "res://test/manual/recording_smoke.tscn", "label": "gdtime-movie-head", "duration": 3, "fps": 30, "backend": "Godot Movie Maker" }]
}
```

`gdtime run` creates `.worktrees/gdtime-movie-head`, resolves `godot` via `godotenv`, regenerates `.godot`, runs `build_command` (empty), then `record.gd` headless:

```
godot --headless --path <worktree> -s res://addons/GdTimeMachine/cli/record.gd -- --scene ... --output /home/.../history_test/gdtime-movie-head --backend "Godot Movie Maker"
```

`record.gd` detects `Engine.is_editor_hint() == false` and takes headless path, which spawns:

```
godot --path <worktree> --write-movie /home/.../history_test/gdtime-movie-head.avi --fixed-fps 30 --quit-after 90 res://test/manual/recording_smoke.tscn
```

**Diagnosis:**

- `record.gd` was missing `preload` for `RecorderController`/`Backend*`/`GdTMFFmpegConvert` → `Parse Error: Identifier not declared` when run in worktree at HEAD (before commit). Fixed by adding `const ... := preload(...)`.
- `record.gd` used `add_child(conv)` on `SceneTree` → `Parse Error: add_child not found`. Fixed to `root.add_child(conv)`.
- `record.gd` used `OS.get_current_dir()` (removed in Godot 4.7) → `Parse Error: Static function not found`. Fixed to `ProjectSettings.globalize_path("res://")`.
- Headless Movie Maker: `godot --headless --write-movie` forces `dummy` renderer (`headless` display driver) and fails with `texture_2d_get` + 0-byte AVI. **Without `--headless`** (`godot --path <worktree> --write-movie ...` with Vulkan) it succeeds: manual test `godot --path /tmp/test-worktree --write-movie /tmp/cli_manual_test.avi --fixed-fps 30 --quit-after 90 res://test/manual/recording_smoke.tscn` produced `2.0M, 90 frames @ 30 FPS, 00:00:03:00` (no abort, just `Resource file not found: res://` warning for autoload `.` which is benign).
- Previous `record.gd` headless incorrectly used `godot --headless --path <worktree> --write-movie` (dummy) and `project_path` was `ProjectSettings.globalize_path("res://")` from the *parent* project, not the worktree. Fixed to `worktree_path` and to `godot --path <worktree> --write-movie` (no `--headless`), plus `movie_path` now globalized to absolute `/home/.../history_test/...avi` so output lands in main repo, not worktree, and survives `worktree remove`.
- `OS.execute("sh", ["-c", "echo \"hello world\" > log"], out, true)` truncates at the space inside quotes when `out` array is used (Godot `OS.execute` bug). Fixed `cli/main.gd:_run_build_command` to write a temp `sh` script and `exec > log 2>&1` inside the script, then `OS.execute("sh", [script_path])` and read the log file.

**Current state:**

- `record.gd` now correctly takes `headless` path (`is_editor_hint() == false`), resolves `godot_bin` via `godotenv`, builds `args` as `["--path", worktree_path, "--write-movie", movie_path, "--fixed-fps", "30", "--quit-after", "90", scene]`, and `OS.create_process` succeeds. Manual `godot --path /tmp/test-worktree --write-movie /tmp/cli_manual_test.avi --quit-after 90 res://test/manual/recording_smoke.tscn` **succeeds with 2.0M** when run from shell. The CLI's headless `record.gd` now also succeeds in manual `godot --path` without `--headless`, but the automated `gdtime run` still shows `headless movie output not found` after the 5s kill — likely the `duration + 5` timeout is too short or `movie_path` without `.avi` extension check was missing (now fixed to add `.avi` when output has no extension).

**Next:**

- Verify `gdtime run` with the fixed `record.gd` and `cli/main.gd` (now globalized output, no `--headless` for the movie child) actually populates `/home/.../media/captures/history_test/gdtime-movie-head.avi` and survives worktree cleanup. If still 0-byte, test with `xvfb` or ensure `worktree_path` contains a valid `project.godot` and `res://` scene.

**Workaround for user alert:** Until headless is green, run `gdtime run --dry-run` to validate, then manually `godot --path <worktree> --write-movie ...` as proven above, or use `Screenshot` backend in editor (not headless) for quick verification.
