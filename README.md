# GdTimeMachine

A time machine for your Godot project. Record any scene, rewind any commit.

GdTimeMachine is a Godot editor addon that records footage of your project's scenes from inside the editor — currently via Godot's built-in Movie Maker — and is designed to one day rewind your project to any historical git commit and capture the scene as it existed then.

## Current status

What works today:

- **Godot Movie Maker backend** — recording is done by Godot's built-in Movie Maker. No external software or dependencies.
- **Screenshot backend** — zero-dependency in-place capture of the *running* scene via the engine's debugger screenshot channel (PNG or JPG frames). The game is never restarted or killed. Dev-quality: no audio, real-time jitter, ~15 fps typical, game window must stay visible and focused.
- **ffmpeg tier-2 conversion** — when ffmpeg is available, MP4 (H.264) and WebM (VP9) output are produced from any backend's native artifact (Movie Maker AVI → MP4; screenshot frames → MP4/WebM). Frames-per-second is taken from the capture's measured average, not the target. If ffmpeg is missing, the native artifact is kept and a notice is shown — never a failed recording.
- **Output** — recordings are written as `.avi`, `.ogv`, PNG/JPG sequences, `.mp4`, or `.webm`. File names are auto-generated from scene name + timestamp.
- **Bottom panel dock** — a "GdTimeMachine" tab in the editor's bottom panel holds the controls.
- **Toolbar buttons** — Record/Stop buttons in the run bar and in the game view toolbar.
- **Graceful stop** — Stop asks the running game to quit cleanly so Movie Maker finalizes the file, instead of killing the process mid-write.
- **No project.godot pollution** — Movie Maker settings are set in-memory for the recording and restored afterwards; nothing is written to `project.godot` on disk.
- **Local config store** — default profile in `EditorSettings` under `gd_time_machine/recorder/*`, per-scene overrides in `addons/GdTimeMachine/config/state/profiles.cfg` (gitignored by default, localized under the addon, opt-in to commit).
- **Scene-aware profiles** — the dock tracks the open scene automatically (`EditorPlugin.scene_changed`) and auto-loads/saves per-scene settings on scene switch.

## Backends

| Backend | CaptureMode | Deps | Output | Notes | |---|---|---|---|---| | Godot Movie Maker | `RESTART_SCENE` | none (built-in) | AVI / OGV / PNG sequence | Restarts the scene to record; duration watchdog stops recording if the scene never starts; AVI files are capped at 4 GB | | Screenshot | `IN_PLACE` | none | PNG/JPG frames (+ ffmpeg: MP4/WebM) | Zero-dependency, dev-quality capture of the running scene; no audio; game window must stay visible and focused | | OBS | `IN_PLACE` | OBS Studio | — | Planned — requires OBS installed; records the running scene without restarting it |

`RESTART_SCENE` backends (Movie Maker) must launch a fresh scene to record, so the in-game record button is greyed out while a scene is running — starting a recording would restart the scene you are looking at. In-place backends (Screenshot) record the running scene and stop without killing it; when no scene is playing, Record launches the scene first (same UX as Movie Maker).

## Usage

1. Enable the plugin (see [Installation](#installation)).
1. Open the **GdTimeMachine** tab in the editor's bottom panel.
1. Set the backend, output directory, format, FPS, and duration. The scene field follows the currently open scene automatically.
1. Press **Record**. "Remember settings for this scene": when checked, this scene's settings are saved to its own profile in `addons/GdTimeMachine/config/state/profiles.cfg` when you switch scenes, and reloaded when you come back. When unchecked, settings use the default profile.

Recording starts when the scene plays. Press **Stop** to finalize the file — the running game is asked to quit gracefully, then the clip is closed out.

### Output format

The format dropdown is backend-aware: it shows what the active backend can write natively **plus** what ffmpeg can convert to (tier-2). Native formats need no extra software; converted formats use ffmpeg when available.

- AVI — MJPEG, 4 GB cap, largest files. Native on Movie Maker.
- OGV — Theora+Vorbis, smaller, editor binaries only. Native on Movie Maker.
- PNG — PNG image sequence + WAV, lossless master for external encode. Native on both backends (frames).
- JPG — JPG image sequence, compact lossy frames. Native on Screenshot.
- MP4 — H.264 via ffmpeg tier-2 (no engine writer exists). Converted from any native artifact.
- WebM — VP9 via ffmpeg tier-2. Converted from any native artifact.

Conversion runs automatically after a recording stops (toggle in `Project > Editor Settings` under `gd_time_machine/ffmpeg/`); frame rate comes from the capture's measured average. On success the frames/intermediate are cleaned up (also configurable); if ffmpeg is missing or the conversion fails, the native artifact is kept and the status line explains why.

## Settings

On first use, the default profile is seeded into `addons/GdTimeMachine/config/state/profiles.cfg` (the `[default]` section) from `EditorSettings` (`Project > Editor Settings`, keys under `gd_time_machine/recorder/`):

| Setting | Type | Purpose | |---|---|---| | `gd_time_machine/recorder/output_dir` | String | Directory recordings are written to | | `gd_time_machine/recorder/output_format` | String | Default format (`avi`, `ogv`, `png`, `jpg`, `mp4`, `webm`) | | `gd_time_machine/recorder/default_duration` | float | Default recording duration in seconds (0 = record until stopped) | | `gd_time_machine/recorder/default_fps` | int | Default target FPS cap | | `gd_time_machine/recorder/default_backend` | String | Backend selected by default | | `gd_time_machine/ffmpeg/path` | String | Custom ffmpeg binary path (empty = PATH lookup) | | `gd_time_machine/ffmpeg/auto_convert` | bool | Convert tier-2 formats automatically after recording (default true) | | `gd_time_machine/ffmpeg/clean_frames` | bool | Delete frames/intermediate after a successful conversion (default true) |

After seeding, the `[default]` section in `profiles.cfg` is the source of truth for the default profile — edit the file directly to change your global defaults, and any default saved from the dock is written back there. Per-scene overrides live in the same file (INI via ConfigFile):

```ini
[default]
output_dir = res://media/captures
output_format = avi
fps = 60
duration = 30

["res://scenes/menu.tscn"]
fps = 30
output_format = png
```

This file lives under `addons/GdTimeMachine/config/state/` and is gitignored by default. Teams can commit it if they want shared recording profiles.

## Installation

1. Copy the `addons/GdTimeMachine` directory into your project's `addons/` folder.
1. Enable it in **Project > Project Settings > Plugins** (activate the GdTimeMachine plugin).

## Architecture

- `RecordingProfile` — per-recording config, serializable via `to_dict()`/`from_dict()`.
- `GdTMOutputFormat` — shared format enum → extension → display name → warning text.
- `ConfigStore` interface — `EditorSettingsConfigStore` (first-run default seed) + `ProjectLocalConfigStore` (`addons/GdTimeMachine/config/state/profiles.cfg` `[default]` + per-scene overrides, the source of truth) + `CompositeConfigStore` (scene override > local default > editor default).
- `RecorderBackend` subclasses with `CaptureMode`.
- `RecorderController` owns backend lifecycles and re-emits backend signals; dock talks only to the controller and the config store, never directly to a backend or ProjectSettings movie_writer keys.
- `BackendMovieMaker` — snapshot/restore of `editor/movie_writer/*` without `ProjectSettings.save()`, removing the old `project.godot` pollution.
- `BackendScreenshotCapture` — in-place frames capture over the debugger screenshot channel (PNG/JPG, one-in-flight pacing, measured-fps manifest).
- `GdTMFFmpegConvert` — the tier-2 conversion hook: probes for ffmpeg, maps formats to codec/container args, runs the encode on a `Thread` (blocking `OS.execute` with stderr capture), and emits `recording_converted`/`conversion_failed`/`ffmpeg_not_found`. Backend-agnostic — any backend can hand it a file or a frames dir.

## License

Apache-2.0 — see [LICENSE.txt](LICENSE.txt).
