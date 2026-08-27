# Seed — CLI v0.1.1 Polish Pass (pre-publish)

**Purpose:** Seed for next session to do a full cleanup, tidiness, and documentation pass over the CLI surface before tagging `v0.1.1` (first Asset Library release with `gdtime` history batch). This is *not* a feature session — it is a polish pass. No new flags or backends; just make what we have shippable.

**Context:** `v0.1.0` already published (OBS + Screenshot + Movie Maker, `284/284` GUT, `README` 944w, `tools/` deleted). `cli/main.gd` now delegates to `core/` (`worktree`, `godot_resolve`, `build_runner`, `movie_writer`), `cli/record.gd` is editor-only, `gdtime` wrapper handles exit codes via `tee` + `grep -F`. Phases 0–3 are live (`validate` / `run --dry-run/--resume/--keep-*/--fail-fast/--no-git/--force/--build-timeout` + `doctor` + `list-commits`), but the surface still has stub artifacts and uneven docs.

## What to do — full CLI surface sweep

Do a single pass over **every file under `addons/GdTimeMachine/cli/` and `addons/GdTimeMachine/core/`**:

1. **Stubbed behavior:**

   - Search for `stub`, `TODO`, `FIXME`, `not yet implemented`, `will check`, `Phase 0`, `Phase 1`, `Phase 2`, `Phase 3`, `Phase 4`, `MVP`, `TBD`. Every hit is a must-fix or must-document-as-intentional.
   - Ensure `doctor` no longer prints `probe not yet implemented` (it now does real probes, but verify `ffmpeg`/`OBS`/`build hook`/`worktree` branches are all live).
   - Ensure `run`’s `--resume`/`--build-timeout`/`--keep-failed`/`--fail-fast` are not just parsed but actually affect control flow (they now do — re-verify with the `false` build fixtures and `resume-b` dry-run).

1. **Emojis:**

   - `grep -r "✔\|✘\|⚠\|○\|▶" addons/GdTimeMachine/cli/ addons/GdTimeMachine/core/` must return **0 hits** in CLI output. Help and `doctor` already use `[OK]/[FAIL]/[WARN]/[INFO]` — verify `validate`/`run`/`list-commits` also use plain tags and that `test/cli/run_cli_smoke.sh` (which still has `✔` in its *test* output) is either left as test-only or also stripped for consistency.

1. **Excessive comments / docstrings / planning references:**

   - Remove or rewrite any comment that mentions `notes/PLAN_cli_companion.md`, `notes/ARCHITECTURE_CLI_DECOUPLING.md`, `notes/BUG_headless_movie.md`, `obs-backend-v2`, `Phase 0`, `v0.1.0`, or prior state. The shipped `cli/` should read as if it was always self-contained, not as a migration from `tools/capture_obs.py`.
   - Trim verbose docstrings: keep `##` one-liners for public methods, drop `Replaces the old cargo build... hardcode` style history. If a comment is longer than the code it explains, shorten it.
   - Ensure no `TODO: Phase 3` or `Future phases will invoke build + record here` remains (that was already removed from `cli/main.gd`’s `worktree ready` path, but re-check).

1. **Docstrings — add where missing:**

   - Every `func` that is `public` (not `func _` private) in `cli/main.gd`, `cli/record.gd` (editor-only), `core/worktree.gd`, `core/godot_resolve.gd`, `core/build_runner.gd`, `core/movie_writer.gd` gets a `##` docstring: one-line purpose, params, return, and exit-code contract where relevant.
   - Every key `const`/`var` that is part of the CLI surface (`VERSION`, `SCHEMA_PATH`, `GdTM*` preloads, `build_timeout` default `600`, `GDTM_*` env vars) gets a `##` line.
   - Follow existing style: `##` for docs, `const` before `var`, `static func` for `core/` helpers.

## Acceptance — what “done” looks like

- `grep -r "Phase\|PLAN\|roadmap\|TODO\|FIXME\|stub" addons/GdTimeMachine/cli/ addons/GdTimeMachine/core/` → 0 hits (or only `TODO` that is explicitly `TODO(v0.1.2)` with a follow-up note).
- `grep -r "✔\|✘\|⚠\|○" addons/GdTimeMachine/cli/ addons/GdTimeMachine/core/` → 0 hits; `gdtime --help` and `gdtime doctor` samples in `README` show `[OK]/[FAIL]/[WARN]` only.
- `godot --headless --check-only -s addons/GdTimeMachine/cli/main.gd` and `core/*.gd` → no `Parse error`, no `Push warning` for missing docstrings (if `gdformat` enforces).
- `make test-godot` → `284/284` still green; `./test/cli/run_cli_smoke.sh` → `✔` or `[OK]` consistently (update its `echo` to match CLI style if you strip its emojis).
- `wc -w notes/SEED_cli_v0_1_1_polish.md` is the only new note; `notes/PLAN_cli_companion.md`, `ARCHITECTURE_CLI_DECOUPLING.md`, `BUG_headless_movie.md` remain as history but are not referenced from `cli/`.

## Out of scope for this pass

- No new flags, no `BackendOBS` for history, no `record.gd` headless revival — `core/movie_writer.gd`’s `godot --path <worktree> --write-movie` (no `--headless`, Vulkan, `60 frames @ 30 FPS` as proven) stays.
- No `CHANGELOG` until `v0.1.1` tag; no `media/` gif.

## How to run this pass

```sh
grep -rn "Phase\|PLAN\|TODO\|FIXME\|stub" addons/GdTimeMachine/cli/ addons/GdTimeMachine/core/
grep -rn "✔\|✘\|⚠\|○" addons/GdTimeMachine/cli/ addons/GdTimeMachine/core/
godot --headless --check-only -s addons/GdTimeMachine/cli/main.gd
godot --headless --check-only -s addons/GdTimeMachine/core/*.gd
./test/cli/run_cli_smoke.sh
make test-godot
```

Commit as `chore: CLI v0.1.1 polish — docs, no emojis, no stubs` and tag `v0.1.1` after.
