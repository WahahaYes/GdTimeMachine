# GdTimeMachine

A time machine for your Godot project. Record any scene, rewind any commit.

GdTimeMachine is a Godot editor addon that records footage of your project's scenes from inside the editor — currently via Godot's built-in Movie Maker — and is designed to one day rewind your project to any historical git commit and capture the scene as it existed then.

## Current status

What works today:

- **Godot Movie Maker backend** — recording is done by Godot's built-in Movie Maker. No external software or dependencies.
- **Output** — recordings are written as `.avi` by default, with `.ogv` and PNG sequence as opt-in formats. File names are auto-generated from scene name + timestamp.
- **Bottom panel dock** — a "GdTimeMachine" tab in the editor's bottom panel holds the controls.
- **Toolbar buttons** — Record/Stop buttons in the run bar and in the game view toolbar.
- **Graceful stop** — Stop asks the running game to quit cleanly so Movie Maker finalizes the file, instead of killing the process mid-write.
- **No project.godot pollution** — Movie Maker settings are set in-memory for the recording and restored afterwards; nothing is written to `project.godot` on disk.
- **Local config store** — default profile in `EditorSettings` under `gd_time_machine/recorder/*`, per-scene overrides in `addons/GdTimeMachine/config/state/profiles.cfg` (gitignored by default, localized under the addon, opt-in to commit).
- **Scene-aware profiles** — the dock tracks the open scene automatically (`EditorPlugin.scene_changed`) and auto-loads/saves per-scene settings on scene switch.

## Backends

| Backend | CaptureMode | Deps | Output | Notes | |---|---|---|---|---| | Godot Movie Maker | `RESTART_SCENE` | none (built-in) | AVI / OGV / PNG sequence | Restarts the scene to record; duration watchdog stops recording if the scene never starts; AVI files are capped at 4 GB | | Screenshot | `IN_PLACE` | none | images | Planned — zero-dependency, dev-quality capture of the running scene | | OBS | `IN_PLACE` | OBS Studio | — | Planned — requires OBS installed; records the running scene without restarting it |

`RESTART_SCENE` backends (Movie Maker) must launch a fresh scene to record, so the in-game record button is greyed out while a scene is running — starting a recording would restart the scene you are looking at.

## Usage

1. Enable the plugin (see [Installation](#installation)).
1. Open the **GdTimeMachine** tab in the editor's bottom panel.
1. Set the backend, output directory, format, FPS, and duration. The scene field follows the currently open scene automatically.
1. Press **Record**. "Remember settings for this scene": when checked, this scene's settings are saved to its own profile in `addons/GdTimeMachine/config/state/profiles.cfg` when you switch scenes, and reloaded when you come back. When unchecked, settings use the default profile.

Recording starts when the scene plays. Press **Stop** to finalize the file — the running game is asked to quit gracefully, then the clip is closed out.

### Output format

- AVI — MJPEG, 4 GB cap, largest files.
- OGV — Theora+Vorbis, smaller, editor binaries only.
- PNG — PNG image sequence + WAV, lossless master for external encode.

## Settings

On first use, the default profile is seeded into `addons/GdTimeMachine/config/state/profiles.cfg` (the `[default]` section) from `EditorSettings` (`Project > Editor Settings`, keys under `gd_time_machine/recorder/`):

| Setting | Type | Purpose | |---|---|---| | `gd_time_machine/recorder/output_dir` | String | Directory recordings are written to | | `gd_time_machine/recorder/output_format` | String | Default format (`avi`, `ogv`, `png`) | | `gd_time_machine/recorder/default_duration` | float | Default recording duration in seconds (0 = record until stopped) | | `gd_time_machine/recorder/default_fps` | int | Default target FPS cap | | `gd_time_machine/recorder/default_backend` | String | Backend selected by default |

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

## License

Apache-2.0 — see [LICENSE.txt](LICENSE.txt).
