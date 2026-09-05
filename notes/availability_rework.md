# Availability display rework (option 3) — DONE

## Verification

- `make test-godot` → GUT-SUITE-OK (292 passing, 0 failing).
- `make check-docs` → consistent.

## Goal

- No " — not available" suffix. Plain backend names always.
- Truly unavailable => greyed + unselectable (`OptionButton.set_item_disabled`) + tooltip.
- Same treatment for ffmpeg-dependent formats via parallel interface.
- Status via tooltip + existing status line narration (launch progress already goes to status).

## Truly unavailable definition

- Backends: `is_available()` = selectable. Movie Maker/Screenshot always true. OBS = `is_obs_installed()` (binary present), NOT websocket reachable. Installed-but-idle stays selectable (will auto-launch).
- Formats: `needs_ffmpeg(fmt)` + `ffmpeg missing` => disabled. OBS native MP4 never needs ffmpeg, stays enabled.

## Common interface

- `RecorderBackend.is_available() -> bool` (selectability gate, UI disables when false)
- `RecorderBackend.get_unavailable_reason() -> String` ("" when available)
- `RecorderBackend.get_runtime_hint() -> String` ("" when nothing to say; OBS: "Installed, not running — will auto-launch…")
- `GdTMFFmpegConvert.probe_ffmpeg()` ≅ `is_available()` + `GdTMOutputFormat.warning_text()` ≅ reason. Dock mirrors with `is_format_available()` / tooltip.
- `RecorderController.get_backend_tooltip(name)` = reason if unavailable else runtime hint.

## OBS signal note

- `_available` stays as reachability cache for `is_obs_running()`.
- `availability_changed` still emitted from probe (reachability flip). Dock handler ignores bool payload and recomputes disabled from `is_available()` (installed) + tooltip from controller. Keeps live tooltip updates with minimal churn.

## Dock changes (`time_machine_dock.gd`)

- Remove `UNAVAILABLE_SUFFIX`, `_backend_label()`.
- `_populate_backends()`: plain names, `set_item_disabled(not available)`, tooltip via controller.
- `_on_backend_availability_changed()`: update disabled+tooltip, fallback to first enabled if selected became disabled.
- `_on_backend_selected()`: guard disabled — revert, show install hint, don't persist.
- `_backend_tooltip()` replaces `_unavailable_tooltip()`.
- Formats: `_populate_formats()` adds metadata (int fmt), disabled when needs_ffmpeg && !ffmpeg, tooltip with warning. `_format_needs_ffmpeg(fmt)` per-format version of `_expects_conversion()`. `_get_selected_format()` reads metadata first. `_select_format_item()` / `_repopulate` ensure enabled selection. `_is_ffmpeg_available()` with `_ffmpeg_probe_override` test seam.
- `_maybe_show_obs_install_hint()` unchanged logic (now fires only when truly unavailable since `is_available`=installed).

## Backend changes

- `recorder_backend.gd`: docs + 2 new methods.
- `backend_obs.gd`: `is_available()=is_obs_installed()`, `get_unavailable_reason()`, `get_runtime_hint()`, retry binary resolve when cached empty.
- `ffmpeg_convert.gd`: add `is_available()` alias + `get_unavailable_reason()` for parallel naming (delegates to probe/warning).

## Controller

- Add `get_backend_unavailable_reason()`, `get_backend_runtime_hint()`, `get_backend_tooltip()`.

## Tests

- `test_time_machine_dock.gd`: update mocks (reason/hint), replace suffix asserts with disabled asserts, update flip test, update unavailable-selection test to assert revert, add ffmpeg disabled tests via `_ffmpeg_probe_override`.
- `test_backend_obs.gd`: update two-axis tests to new semantics (installed=>available), add reason/hint tests.
- `test_backend_base.gd` + `test_recorder_controller.gd`: add reason/hint/tooltip coverage.

## Verification

- `make test-godot` (GUT 284 tests).
