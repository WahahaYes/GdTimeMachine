# GdTimeMachine

A time machine for your Godot project. Record any scene, rewind any commit.

GdTimeMachine is a Godot editor addon that records footage of your project's scenes from inside the editor — currently via Godot's built-in Movie Maker — and is designed to one day rewind your project to any historical git commit and capture the scene as it existed then.

## Current status

What works today:

- **Godot Movie Maker backend** — recording is done by Godot's built-in Movie Maker. No external software or dependencies.
- **Output** — recordings are written as `.avi` files.
- **Bottom panel dock** — a "GdTimeMachine" tab in the editor's bottom panel holds the controls.
- **Toolbar buttons** — Record/Stop buttons in the run bar and in the game view toolbar.
- **Graceful stop** — Stop asks the running game to quit cleanly so Movie Maker finalizes the AVI file, instead of killing the process mid-write.

## Backends

| Backend | CaptureMode | Deps | Output | Notes | |---|---|---|---|---| | Godot Movie Maker | `RESTART_SCENE` | none (built-in) | AVI | Restarts the scene to record; duration watchdog stops recording if the scene never starts; AVI files are capped at 4 GB | | Screenshot | `IN_PLACE` | none | images | Planned — zero-dependency, dev-quality capture of the running scene | | OBS | `IN_PLACE` | OBS Studio | — | Planned — requires OBS installed; records the running scene without restarting it |

`RESTART_SCENE` backends (Movie Maker) must launch a fresh scene to record, so the in-game record button is greyed out while a scene is running — starting a recording would restart the scene you are looking at.

## Usage

1. Enable the plugin (see [Installation](#installation)).
1. Open the **GdTimeMachine** tab in the editor's bottom panel.
1. Set the output directory, scene, FPS, and duration.
1. Press **Record**.

Recording starts when the scene plays. Press **Stop** (in the run bar or the game view toolbar) to finalize the file — the running game is asked to quit gracefully, then the AVI is closed out.

## Settings

Editor settings, found under `Project > Editor Settings`, in the `gd_time_machine/recorder/` section:

| Setting | Type | Purpose | |---|---|---| | `gd_time_machine/recorder/output_dir` | String | Directory recordings are written to | | `gd_time_machine/recorder/default_duration` | float | Default recording duration in seconds (0 = record until stopped) | | `gd_time_machine/recorder/default_fps` | int | Default target FPS cap | | `gd_time_machine/recorder/default_backend` | String | Backend selected by default |

## Installation

1. Copy the `addons/gd-time-machine` directory into your project's `addons/` folder.
1. Enable it in **Project > Project Settings > Plugins** (activate the GdTimeMachine plugin).

## Architecture

Recording backends (`RecorderBackend` subclasses) are a small abstraction over how footage is captured, each with its own `CaptureMode`. The `RecorderController` owns backend lifecycles and re-emits backend signals; the dock UI only talks to the controller, never directly to a backend.

## License

Apache-2.0 — see [LICENSE.txt](LICENSE.txt).
