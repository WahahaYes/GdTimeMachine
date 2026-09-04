# GdTimeMachine

<p align="center">
  <img src="https://raw.githubusercontent.com/WahahaYes/GdTimeMachine/main/addons/GdTimeMachine/ui/icons/icon_logo.svg" width="60%" alt="GdTimeMachine icon" />
</p>

**Record any scene, rewind any commit.**

GdTimeMachine records your scenes right from the editor — no external capture or window setup. Pick a backend, hit Record, and get a clip named for the scene and time. Built for the “time machine” workflow: rewind your project to any git commit and capture it again to diff how a scene looked across history.

## Installation

### Asset Library

GdTimeMachine v0.1.1 for Godot 4.7 is listed on the Godot Asset Library: https://godotengine.org/asset-library/asset/5430

1. In Godot: **AssetLib → Search "GdTimeMachine" → Download → Install**
1. Then **Project > Project Settings > Plugins → Enable GdTimeMachine**

### Manual Install

```sh
# from your project root
cp -r /path/to/GdTimeMachine/addons/GdTimeMachine addons/
```

Then in Godot:

1. Open **Project > Project Settings > Plugins**
1. Enable **GdTimeMachine**

No extra dependencies for the built-in backends. OBS and ffmpeg are optional (see below).

## Quick Start

1. Open the **GdTimeMachine** dock in the **bottom panel**.
1. Pick a **backend**, **format**, and **FPS** (duration `0` = record until stopped).
1. Press **Record** — press **Stop** when done. Files are named `<scene>_<timestamp>.<ext>` in your output dir.

Shortcuts:

- `Ctrl+Alt+R` / `Cmd+Alt+R` (macOS) toggles recording from anywhere in the editor.
- **Command Palette** → `GdTimeMachine: Toggle Recording`.
- Rebind via `Project > Editor Settings > Shortcuts` → `gd_time_machine/toggle_recording`.

The dock status line shows live state while recording (backend, output file, elapsed time) and the final save/convert result.

> **Tip:** Check *Remember settings for this scene* in the dock to save per-scene overrides.

## Backends

- **Movie Maker** (`RESTART_SCENE`) — AVI / OGV / PNG. Restarts the scene to record. AVI capped at **4 GB** (auto-stops before cap). No external deps.
- **Screenshot** (`IN_PLACE`) — PNG / JPG (+ ffmpeg → MP4 / WebM). Records the running scene in real time (~15 fps, no audio). Window must stay visible. No restart, no kill on Stop.
- **OBS Studio** (`IN_PLACE`) — MP4 (native). Full FPS + audio. Auto-launches OBS via WebSocket if not running. No scene restart.

`RESTART_SCENE` backends must relaunch the scene, so the in-game record button is disabled while a scene runs. `IN_PLACE` backends capture the running scene directly; if nothing is running, Record launches the scene first.

OBS always appears in the backend list — if not installed the dock shows an install hint instead of failing silently. Launch progress is narrated in both the dock status line and the terminal `[GdTM]` log.

## OBS Setup

1. **Install OBS Studio** (obsproject.com).
1. In OBS: **Tools → WebSocket Server Settings → Enable WebSocket Server** (default port `4455`). Set a password if desired.
1. In Godot: **Project > Editor Settings → `gd_time_machine/obs/*`** — set matching `host`, `port`, and `password`.
1. Optional `obs/*` settings: `scene` (auto-switch on record), `auto_launch` (default on), `auto_close` (stop OBS we launched when Godot closes), `binary_path` (custom OBS binary).

If OBS isn't reachable and `auto_launch` is on, GdTimeMachine launches it minimized to tray and waits for the WebSocket (with status narration). If `auto_launch` is off or OBS isn't installed, recording reports an actionable error.

## Output Formats

The format dropdown is backend-aware — it shows native formats plus what ffmpeg can convert to.

- **Native (no ffmpeg):** AVI, OGV, PNG sequence, JPG sequence (availability depends on backend).
- **Converted via ffmpeg (tier-2):** MP4 (H.264) and WebM (VP9) from any backend's native artifact — e.g. Movie Maker AVI → MP4, or Screenshot PNG/JPG frames → MP4/WebM.

Tier-2 conversion is **on by default** (`gd_time_machine/ffmpeg/auto_convert`). It uses the capture's measured average FPS. If ffmpeg is missing or conversion fails, the native artifact is kept and the status line explains why — never a lost recording. On success, intermediate frames/files are cleaned up per `clean_frames`.

- AVI: MJPEG, largest files, 4 GB cap.
- OGV: Theora+Vorbis, editor binaries only.
- PNG/JPG: image sequences, lossless/compact masters.
- MP4/WebM: require ffmpeg.

### ffmpeg Setup (for MP4 / WebM)

Godot has no built-in MP4 writer — MP4/WebM come from ffmpeg tier-2 conversion of the native artifact.

1. **Install ffmpeg:** Linux `sudo apt install ffmpeg`, macOS `brew install ffmpeg`, Windows `winget install ffmpeg` / `choco install ffmpeg`.
1. **Verify on PATH:** `ffmpeg -version` should print a version; `which ffmpeg` shows the path.
1. **Tell Godot where it is:** if on `PATH`, nothing to do; otherwise set **Project > Editor Settings → `gd_time_machine/ffmpeg/path`** to the full path. Test with an MP4/WebM recording — status shows `Converted` or `ffmpeg not found`.

Disable tier-2 via `gd_time_machine/ffmpeg/auto_convert = false` to keep native formats only.

## Configuration

All defaults live in **Project > Editor Settings** and can be overridden per scene.

**Recorder (`gd_time_machine/recorder/*`):**

- `output_dir` — where recordings are written (default `res://media/captures`)
- `output_format` — default format (`avi`, `ogv`, `png`, `jpg`, `mp4`, `webm`)
- `default_backend` — backend selected by default
- `default_fps` — target FPS cap
- `default_duration` — seconds (`0` = until stopped)

**ffmpeg (`gd_time_machine/ffmpeg/*`):**

- `path` — custom ffmpeg binary (empty = `PATH` lookup)
- `auto_convert` — auto-convert tier-2 formats after recording (default `true`)
- `clean_frames` — delete frames/intermediate after successful conversion (default `true`)

**OBS (`gd_time_machine/obs/*`):**

- `host`, `port`, `password`, `scene`, `auto_launch`, `auto_close`, `binary_path`

**Shortcut:**

- `gd_time_machine/toggle_recording` — `Ctrl+Alt+R` / `Cmd+Alt+R`

**Per-scene overrides** — `addons/GdTimeMachine/config/state/profiles.cfg` (gitignored by default):

```ini
[default]
output_dir = res://media/captures
output_format = mp4
fps = 60
duration = 30

["res://scenes/menu.tscn"]
fps = 30
output_format = png
```

Each `["res://..."]` overrides `[default]`. Edit directly or use *Remember settings for this scene* in the dock. Commit for shared team profiles.

## CLI — batch capture (history)

`gdtime` is the headless companion for the time-machine workflow — same `plugin.cfg` version as the editor plugin, no extra dependencies.

```sh
gdtime validate <manifest.json> [--strict]          # check manifest (strict rejects unknown keys)
gdtime run [options] <manifest.json>                # worktree → godot → build → record
gdtime doctor [--verbose] [--fix]                   # git / godot / ffmpeg / OBS / build hook / worktrees
gdtime list-commits <manifest.json>                 # commit label for each capture
gdtime --help
gdtime --version
```

**Manifest** (`res://addons/GdTimeMachine/cli/schema/batch_manifest.schema.json`): `project_root`, `captures[]` with `commit` (hex 4–40 or `HEAD`), `scene` (`res://…`), `label` (`[A-Za-z0-9_-]+`, unique), optional `duration`/`fps`/`godot_version_hint`/`output_path`/`build_command` and top-level `godot_path`/`build_command`/`output_dir`.

**`run` options:** `--dry-run` (preview), `--resume LABEL` (skip before label), `--keep-worktrees` / `--keep-failed`, `--no-git` (HEAD-only), `--force` (overwrite), `--build-timeout SECS` (default 600), `--fail-fast`, `--strict`.

**Examples:**

```sh
gdtime validate test/cli/manifest_history.json
gdtime run --dry-run test/cli/manifest_history.json
gdtime run test/cli/manifest_history.json
gdtime doctor --verbose
```

History uses `godot --path <worktree> --write-movie` (Vulkan, no `--headless`) with `godotenv`/`GODOT_BIN` resolution and `rm -rf .godot && godot --editor --headless --quit` cache regeneration. Wrapper is `addons/GdTimeMachine/cli/gdtime` (`godot --headless -s addons/GdTimeMachine/cli/main.gd -- …` also works).

Exit codes: `0` ok, `1` failure, `2` degraded/partial (doctor warnings or `run` with `--keep-failed`).

## License

Apache-2.0 — see [LICENSE.txt](LICENSE.txt).
