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

## OBS MP4 label fix (DONE)

- `GdTMOutputFormat.display_name_for_backend()` / `warning_text_for_backend()` strip the ffmpeg suffix/warning for natives.
- Dock uses `_format_display_name()` / `_format_warning_text()`; OBS shows plain "MP4 (.mp4)", Movie Maker keeps "- ffmpeg".
- Tests: 297 passing.

## Diagnosis: why OBS native MP4 can't reach other formats via ffmpeg

Three gates, all intentional at the time OBS landed as MP4-only:

1. UI allow-list — `time_machine_dock.gd:_get_allowed_formats()` returns exactly `get_native_formats()` ([MP4]) for OBS, so WEBM/AVI/OGV are never offered.
1. Backend start gate — `backend_obs.gd:start()` rejects non-MP4 with "OBS records MP4 natively".
1. Missing post-record step — unlike Movie Maker (`_ffmpeg_converter`, `convert_file_async`, converted/failed/not-found handlers) and Screenshot (`convert_frames_async`), `backend_obs.gd` has no converter member, no trigger, never emits `recording_converted`; `_final_output_path == _intermediate_path` always and `_finalize_stopped()` ends at `recording_stopped`. The ffmpeg file->file plumbing already supports MP4->anything (`ffmpeg_convert.gd:build_file_convert_command`, `convert_file_async`); OBS just never calls it. Plug-in shape (if wanted): widen OBS allow-list to tier-2 targets gated on ffmpeg presence, keep recording MP4 as intermediate, then `convert_file_async(intermediate, final)` on stop with the Movie Maker notice/converted/error pattern and `_exit_tree` wait.

## Format interface + OBS transcoding (DONE)

- `RecorderBackend` now owns format knowledge: `get_native_formats()` / `get_supported_formats()` / `is_format_supported()` / `format_needs_ffmpeg()`. Movie Maker [AVI,OGV,PNG]+MP4/WEBM, Screenshot [PNG,JPG]+all containers, OBS [MP4]+WEBM/AVI/OGV. Dock delegates (`_get_allowed_formats`, `_format_needs_ffmpeg`, `_is_format_native`, `_expects_conversion`) — the capture-mode branching is gone from format logic.
- OBS records an MP4 intermediate and post-converts via `convert_file_async` on stop (Movie Maker pattern: notice Converting… → converted/notice or not-found notice / error). MP4 label is plain "MP4 (.mp4)".
- Tests: 306 passing. `make check-docs` clean.

## OBS format honesty fix (DONE)

- No, AVI/OGV are not OBS-native (OBS records FLV/MKV/MP4/MOV/TS-family). OBS supported narrowed to [MP4, WEBM]; MP4→AVI(mjpeg)/OGV(theora,-an) would be silent downgrades.
- Suffix scheme is now needs-driven, not format-driven: `display_name_for_backend()` = plain base + " - ffmpeg" iff transcoded, so Screenshot AVI/OGV (same latent bug) label honestly too; transcoded warnings always name ffmpeg instead of cap/editor-binaries text that only describes engine output. Doubles without declared natives fall back to native ⟺ no-ffmpeg-needed, preserving historical labels.
- Tests: 308 passing. `make check-docs` clean.

## OBS transcode scope: offer all, decide nothing (DONE)

- Per review: OBS offers every container our file converter can write — [MP4, WEBM, AVI, OGV] — rather than restricting by taste. The boundary is capability (build_file_convert_command arms), not opinion. PNG/JPG stay out: file → frames-sequence extraction has no converter yet (fallback arm would mislabel h264-in-.png).
- The dynamic "- ffmpeg" suffix is what makes this honest: transcoded AVI/OGV now label correctly under OBS (the reported bug), same for Screenshot. Tests pin AVI/OGV suffixes under OBS.
- Tests: 308 passing. `make check-docs` clean.
