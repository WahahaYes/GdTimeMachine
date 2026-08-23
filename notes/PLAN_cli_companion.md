# GdTimeMachine CLI Companion — Implementation Roadmap

**Status:** Roadmap (post-v0.1.0) · **Base:** `main` ~`ab07fa8+` (Asset Library v0.1.0) **Replaces:** `notes/ENHANCEMENT_CLI_COMPANION.md` (hardcoded `cargo build`) and `notes/archive/IMPLEMENTATION_PLAN.md` § Historical Capture **CLI entry:** `gdtime <command>` via wrapper shim → `addons/GdTimeMachine/cli/main.gd` (GDScript, self-contained) **Location:** `addons/GdTimeMachine/cli/main.gd` (only path that reliably ships via Asset Library)

## 1. Goal

Batch-capture any historical commit: for each manifest entry, check out the commit in an isolated **git worktree** (with fallback when `git` is absent, see §4 Phase 1), resolve the **correct Godot binary** via **godotenv** (fallback `godot_path`), run an optional generic **`build_command`**, regenerate `.godot/` caches, then **record** the scene headlessly. No editor is open in the worktree.

Dock (inside editor) **authors** the manifest; CLI (outside editor) **executes** it via `gdtime`. This is GdTimeMachine's core differentiator — a time machine for your project's visual history.

**Self-containment:** only `addons/GdTimeMachine/` reliably ships to consumers (Asset Library zip). The entire CLI lives at `addons/GdTimeMachine/cli/main.gd` (GDScript) + `schema/` + a thin `gdtime` wrapper shim. No `tools/` or repo-root Python is required at runtime.

## 2. Manifest Schema (JSON)

Single file written by the dock, validated by JSON Schema before execution. CLI command: `gdtime validate manifest.json` (wrapper shim, see §3a).

```json
{
  "$schema": "https://gdtime.example/schema/batch_manifest.json",
  "project_root": "/home/user/projects/my-game",
  "godot_path": "godot",
  "build_command": "cargo build --manifest-path rust/Cargo.toml",
  "output_dir": "res://media/captures/history",
  "obs": {
    "host": "localhost",
    "port": 4455,
    "password_env_var": "OBS_PASSWORD",
    "scene_name": "Scene"
  },
  "captures": [
    {
      "commit": "dc48fe5",
      "scene": "res://examples/hunger_basic_2d.tscn",
      "label": "01_before_gdscript",
      "duration": 30,
      "fps": 60,
      "fullscreen": true,
      "godot_version_hint": "4.3"
    },
    {
      "commit": "a9bda00",
      "scene": "res://examples/campfire_2d.tscn",
      "label": "09_final_campfire",
      "duration": 10
    }
  ]
}
```

**Top-level:** `project_root` (abs path, required — validated via `git rev-parse`), `godot_path` (fallback binary, default `"godot"`), `build_command` (generic hook, see §3), `output_dir` (default output), `obs` (WebSocket defaults), `captures[]` (non-empty, labels unique + filesystem-safe).

**Per-capture:** `commit` (SHA, required), `scene` (res:// path, required), `label` (slug for worktree dir + output, required), `duration` (default 30), `fps` (default 60), `fullscreen`, `godot_version_hint`, `output_path` (override), `build_command` (per-entry override). `--strict` rejects unknown keys.

## 3. Generic Build Hook — optional CLI command

`build_command` is an **optional CLI command string** supplied by the user. The CLI has no Rust/GDExtension-specific logic — it just runs what the user typed, if anything.

**What it accepts:**

- A single opaque shell string, exactly as the user would type it in a terminal. Examples: `""` (none), `"cargo build --manifest-path rust/Cargo.toml"`, `"scons target=template_release"`, `"cmake --build build"`, `"./tools/import_assets.sh"`, `"make gdext"`. If the user leaves it empty or omits it, the CLI does no build — correct for pure GDScript projects.
- No structured args or separate `build_args` array — just one string, passed verbatim to the shell.

**What it is configured to:**

- **Manifest level:** top-level `build_command` sets the default for all entries. **Per-entry override:** `captures[].build_command` replaces the top-level for that entry (including `""` to explicitly skip for a single entry). CLI flag `--build-command "<cmd>"` overrides both for a dry run. No EditorSettings key — the manifest is the source of truth, authored via dock “Export Manifest…” (which pre-fills from `godot_version_hint` if the project has a Rust build, otherwise `""`).

**How it runs:**

- `""` or absent → skip build.
- Non-empty → `sh -c "$build_command"` (`cmd /c` on Windows), `workdir = worktree_path`, timeout 600s (`--build-timeout`), env passthrough + `GDTM_LABEL`/`GDTM_COMMIT`/`GDTM_SCENE` for the entry.
- Exit ≠ 0 → entry fails, logged; worktree kept with `--keep-failed`, otherwise removed. `--fail-fast` aborts batch.
- Manifest is local/trusted — no sandbox. Document that `build_command` is arbitrary code.

**Probe (for `gdtime doctor`):**

- `doctor` extracts the leading binary from `build_command` (`cargo`, `scons`, `cmake`, etc.) and probes `<bin> --version` with a 2s timeout. It **only warns** — `⚠ build hook: scons not found (build_command="scons …")` or `⚠ build hook: cargo --version failed` — never `✘`. If `build_command` is `""` or absent, doctor reports `○ build hook: none (GDScript-only)` with no warning. Missing hook is not fatal; the batch will still run and fail per-entry with a clear log if the command is truly needed.

Replaces the old `cargo build (debug) → copy .so` hardcode.

## 3a. Entrypoint — `gdtime` wrapper (not raw `godot --headless`)

Consumers run `gdtime <command>` — never the raw `godot --headless -s --path . addons/GdTimeMachine/cli/main.gd -- ...`.

- **Wrapper shim:** `addons/GdTimeMachine/cli/gdtime` (shell, `chmod +x`) + `addons/GdTimeMachine/cli/gdtime.bat` (Windows) that resolves the Godot binary (`godotenv` if present, else `godot` on PATH, else `GODOT_BIN` env) and execs `godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args>`. For Asset Library, the shim ships *inside* `addons/GdTimeMachine/cli/` so it’s present after install; consumers add it to PATH or invoke as `addons/GdTimeMachine/cli/gdtime run manifest.json`.
- **Fallback:** advanced users can still run `godot --headless -s addons/GdTimeMachine/cli/main.gd -- run manifest.json` directly — document as “if `gdtime` is not on PATH”.
- **Why:** `godot --headless -s --path .` leaks repo-root assumptions and fails when invoked from a worktree. The wrapper hides Godot invocation and keeps the CLI self-contained.

## 4. Phases

### Phase 0 — Schema + Validation (1–2 hrs)

Create `addons/GdTimeMachine/cli/schema/batch_manifest.schema.json` (2020-12) and `gdtime validate` (wrapper → `cli/main.gd`). Dock "Export Manifest…" serializes current scene + defaults. **Acceptance:** duplicate labels / bad SHA / invalid JSON fails with a clear message.

### Phase 1 — Worktree Lifecycle (1–2 hrs)

Preferred: `git worktree add --detach .worktrees/<label> <commit>` per entry. Verify commit resolves; refuse collision unless `--force`. Cleanup via `git worktree remove --force` + `prune` on success; `atexit`/`SIGINT` trap ensures no orphans. Flags: `--keep-worktrees`, `--keep-failed`. **Acceptance:** interrupted batch leaves no orphan worktrees (or lists them with `--keep-failed`).

**Fallback when `git` is absent:** `gdtime` probes `git --version` on start. If `git` is not on PATH:

- Single-commit mode: `gdtime run --no-git manifest.json` executes only entries whose `commit` equals `HEAD`, operating on the current checkout (no worktree). Document as “history mode requires git”.
- Otherwise, `gdtime` fails fast with an actionable error: “git not found — install git or use --no-git for current-commit only; history capture requires git + worktrees”. Do not silently fall back to `git clone` + `checkout` (that risks dirty worktrees). This keeps the CLI self-contained while degrading gracefully for consumers without git.

### Phase 2 — Godot Resolve + Build Hook (2–3 hrs)

Resolve binary: `godotenv godot env get` in worktree → `godot_path` fallback → `godot` on PATH; honour `godot_version_hint`. Regenerate cache: `rm -rf .godot/ && <godot> --editor --headless --quit` (120s timeout). Then run `build_command` if set, streaming output to per-entry log. **Acceptance:** GDScript-only manifest (`build_command=""`) and Rust manifest (`"cargo build"`) both record correctly for old commits pinned to different Godot versions.

### Phase 3 — Batch Record (3–4 hrs)

Invoke GdTimeMachine’s self-contained headless record path — **no external `capture_obs.py`/`obs_controller.py`** (those live in GdPlanningAI, and `tools/` is deleted on `main`). CLI at `addons/GdTimeMachine/cli/main.gd` reuses `BackendOBS` / `BackendScreenshotCapture` / `BackendMovieMaker` directly: for each worktree, run `godot --headless --path <worktree> -s addons/GdTimeMachine/cli/record.gd --scene <scene> -d <duration> -o <output> --fps <fps>` (or call the backend APIs via GDScript). Do not symlink helpers into worktrees. Sequential, one Godot instance at a time. Progress: `[3/9] 09_final_campfire (a9bda00) — ▶ recording`. **Acceptance:** 3-entry batch yields 3 playable files in `output_dir`.

### Phase 4 — Cleanup + CLI UX (3 hrs)

Commands (via wrapper, self-contained):

```
gdtime run [--dry-run] [--resume LABEL] [--keep-failed] [--fail-fast] [--no-git] manifest.json
# (equivalently: godot --headless -s addons/GdTimeMachine/cli/main.gd -- run manifest.json)
gdtime list-commits manifest.json
gdtime validate manifest.json
gdtime doctor [--verbose] [--fix]
```

- `--dry-run`: prints worktree path, resolved Godot, build command, scene, output — no side effects.
- `--resume LABEL`: skips entries before label.
- `--keep-failed` / `--fail-fast`, `--help`/`--version`, shell completions.
- Exit codes: `0` all ok, `2` partial, `1` fatal. Per-entry JSON log consumable by dock "Previous runs" view.

**Healthcheck — `gdtime doctor` (included in Phase 4):**

Probes all optional dependencies and reports actionable status without running a batch. Exits `0` if core is healthy, `2` if degraded.

```
$ gdtime doctor
✔ git 2.43.0 — worktrees: yes
✔ godot 4.7.1 (via godotenv, pinned .godot-version) — fallback /usr/bin/godot 4.3
✔ ffmpeg 6.1 — /usr/bin/ffmpeg (tier-2 MP4/WebM: yes)
✔ OBS Studio /usr/bin/obs — WebSocket ws://localhost:4455: reachable (auth ok)
✔ build hook: cargo 1.78.0 — sh -c "cargo build": ok
✔ output_dir res://media/captures — writable

$ gdtime doctor --verbose
… per-check: version, path, latency, hints
```

Checks (each with `✔/✘/⚠` + hint):

- **git** — `git --version` + `git worktree` support (≥2.13). If missing → `--no-git` single-commit mode only.
- **godot** — `godotenv godot env get` in repo → `godot_path` fallback → `godot --version`. Reports pinned vs fallback.
- **godotenv** — present / missing (warn, not fatal — uses `godot_path`).
- **ffmpeg** — `ffmpeg -version` + check `gd_time_machine/ffmpeg/path` override; reports tier-2 availability (`mp4/webm: yes/no`).
- **OBS Studio** — binary at `gd_time_machine/obs/binary_path` or PATH (`which obs`), plus WebSocket probe to `host:port` (reuses `BackendOBS` probe, 1.5s timeout). Separate `installed` vs `reachable` like the dock (never conflated).
- **build hook** — user-supplied optional CLI command (`build_command`). If `""`/absent → `○ build hook: none (GDScript-only)` (no warning). If set, `doctor` extracts the leading binary and probes `<bin> --version` (2s timeout) — reports `✔ build hook: cargo 1.78.0` on success, `⚠ build hook: scons not found` or `⚠ build hook: cargo --version failed` only when missing or `--version` doesn’t resolve. Never `✘`; missing hook is not fatal — batch will still run and fail per-entry with a clear log if the build is truly needed.
- **output_dir** — `DirAccess.dir_exists` + writable check.
- **worktree** — `git worktree list` sanity (no orphans).
- `--fix` (nice-to-have): offers to `git worktree prune`, `mkdir -p output_dir`, or print install hints (`sudo apt install ffmpeg`, `obsproject.com`).

Acceptance: `doctor` correctly flags missing `ffmpeg`/`OBS` as degraded (not fatal) and missing `git`/`godot` as fatal, with copy-pasteable fixes.

## 5. Out of Scope / Deferred

| Item | Reason | |---|---| | Replay buffer ("Record That") | Separate OBS feature, needs pre-configured buffer | | Dock batch UI (add/remove/reorder, git log picker) | CLI owns execution first; GUI follows | | CI integration | Manifest enables it; no runner work in v1 | | `BackendMovieMakerCLI` | Delegated to existing capture scripts | | Rust single-binary rewrite | Python v1 is sufficient; revisit on demand | | Win/macOS capture-source automation | Linux/PipeWire first; other platforms stubbed |

## 6. Success Criteria

- `validate` rejects malformed manifests with actionable errors.
- `run --dry-run` prints correct plan without touching git/Godot/build.
- `run` completes for both GDScript-only and native fixtures, cleaning worktrees on success.
- Resumable (`--resume`) and debuggable (`--keep-failed`) batches.
- No editor required during `run`; godotenv switching works across Godot minors.
- Docs (this file + `README.md` CLI section + schema) stay consistent.

## 7. Dependencies & Effort

Godot 4.7+, Git (optional with --no-git fallback), godotenv, optional OBS/ffmpeg. GDScript CLI at `addons/GdTimeMachine/cli/main.gd` + `gdtime` wrapper — no Python runtime required. Cargo/SCons/CMake only if `build_command` needs them.

| Phase | Time | |---|---| | 0 Schema | 1–2 hrs | | 1 Worktrees | 1–2 hrs | | 2 Godot + build | 2–3 hrs | | 3 Batch record | 3–4 hrs | | 4 CLI UX + doctor | 3 hrs | | **Total** | **~10–14 hrs** |
