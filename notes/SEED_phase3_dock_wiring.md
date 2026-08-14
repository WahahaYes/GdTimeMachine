# Seed Prompt — Phase 3: plugin + dock wiring (OBS availability gating, install dialog, native formats)

Use this as the opening prompt for the Phase 3 agent. It orients the worker to the mission, the locked spec, and what already landed during Phases 0–2 (so nothing is re-done). The worker MUST read the plan and the current dock/controller/backend code before writing anything.

______________________________________________________________________

## Mission

Complete **Phase 3 of the OBS backend v2 rebuild** on branch **`obs-backend-v2`** of GdTimeMachine: the remaining **dock wiring** in plan §6 — OBS availability gating in the backend dropdown, a one-time install-hint dialog, native-MP4 format filtering, the `hints/dont_show_obs_hint` EditorSettings default, and their tests. `plugin.gd` registration of `BackendOBS` and the `gd_time_machine/obs/*` defaults ALREADY landed (2026-08-14 session) — do NOT re-do them.

## Gate status (do not re-litigate)

Phases 0–2 are DONE and green (266 tests). The OBS backend is registered and selectable in the dock; its `_exit_tree()` already best-effort-kills a launched OBS (`_we_launched && auto_close`) and releases its client, and `BackendOBS` has **no** `_debugger_plugin` (plan §6's `_exit_tree` bullet is satisfied by the backend itself). The pre-dock end-to-end path is proven live by `tools/obs_backend_drive.gd` (record/stop/file-move on a real 4455 server, both password modes). Evidence: `notes/PROGRESS_obs_backend_v2.md`.

## Read first (mandatory)

1. `notes/PLAN_obs_backend_v2.md` — **§6 is YOUR spec**. Also §2 (locked decisions, esp. "dock settings UI: still cut"), §7 manifest, §8 testing strategy, §9 manual matrix.
1. `notes/PROGRESS_obs_backend_v2.md` — the full Phase trail + the 2026-08-14 session note (what's already wired).
1. Current code (read in this order):
   - `addons/GdTimeMachine/plugin.gd` — `_enter_tree` registration order, `_ensure_editor_settings_defaults()` (you extend this with the hint flag).
   - `addons/GdTimeMachine/ui/time_machine_dock.gd` — `_populate_backends()`, `_get_allowed_formats()`, `_on_backend_selected()`, `_on_backend_changed()`, `_update_backend_tooltip()`, the status-line handlers, and the `_ready` signal wiring.
   - `addons/GdTimeMachine/ui/time_machine_dock.tscn` — where the install-hint `AcceptDialog` node goes.
   - `addons/GdTimeMachine/backend/recorder_backend.gd` — base contract: `is_available()`, `get_native_formats()` is NOT on the base (only `BackendOBS` has it — guard with `has_method`).
   - `addons/GdTimeMachine/controller/recorder_controller.gd` — signal contract (forwards recording\_\* + `backend_changed` only; **no** availability forwarding yet).
   - `addons/GdTimeMachine/backend/backend_obs.gd` — `is_available()`, `availability_changed`, `_get_obs_settings()`.
1. Test patterns: `test/unit/test_time_machine_dock.gd` (`MockBackend`, `_build_dock`, `FakeStore` — the template for your new tests), `test/unit/test_recorder_controller.gd`.

## Current state (what's done — don't touch)

- `plugin.gd` registers `BackendOBS` after Screenshot (Movie Maker stays default); saved "OBS Studio" profiles now resolve.
- `plugin.gd._ensure_editor_settings_defaults()` adds `gd_time_machine/obs/{host,port,password,scene,auto_launch,auto_close,binary_path}` with property info.
- `BackendOBS._exit_tree()` handles the §6 best-effort kill + client release.
- Dock status line already consumes `recording_started/stopped/error/notice` generically — OBS flows through unchanged (verify, don't rework).

## Spec (plan §6, authoritative)

1. **plugin.gd** — extend `_ensure_editor_settings_defaults()` with `hints/dont_show_obs_hint` (bool, default `false`) so the install dialog's "don't show again" survives restarts. Read via the same EditorSettings-first path (`_get_obs_settings`-style) the backend already uses.
1. **`_populate_backends()` gating** — when the OBS item's backend `is_available()` is false, mark it per §6 ("— not available" + explanatory tooltip). **Design decision (settle before coding):** a fully `set_item_disabled`'d item can't fire the install dialog on selection, but §9 item 5 expects both "— not available" greyed AND the one-time install dialog. Recommended reading: keep the item **selectable**, show the "— not available" suffix + tooltip, and fire the install dialog from `_on_backend_selected()` when an unavailable OBS is chosen (recording itself still fails actionably from the backend's error path). If you prefer hard-disable, state where the dialog fires instead — but the §9 matrix must be reachable.
1. **Native formats** — `_get_allowed_formats()` must honor `get_native_formats()` (OBS → `[MP4]`) when the active backend has the method, instead of the blanket IN_PLACE list. Guard with `has_method("get_native_formats")` so Movie Maker / Screenshot fall back to their existing behavior.
1. **Install dialog** — AcceptDialog node in `time_machine_dock.tscn` plus wiring: shown once when OBS is selected while unavailable, suppressed while `hints/dont_show_obs_hint` is true (set it when the user ticks "don't show again"). **Text must be built dynamically** (Bug-6 lesson — never hardcode "OBS must be running"): name the actual host/port from settings, give setup steps (install OBS, Tools → WebSocket Server Settings → Enable, matching password in Project > Editor Settings under `gd_time_machine/obs/password`), and a button/link that `OS.shell_open("https://obsproject.com")`. No OBS-less assumptions.
1. **Live refresh** — the availability probe is async (`BackendOBS.availability_changed`). The "— not available" marking must refresh when availability changes so the dropdown un-greys when OBS starts. The dock currently has no backend references beyond `_controller.get_backend_names()` / `_controller.active_backend`. **Design decision:** add a read-only `RecorderController.get_backend(backend_name)` accessor and subscribe to the backend's `availability_changed` (guard with `has_signal` — it's not in the base contract), OR forward a controller-level availability signal. Pick the minimal path that keeps "UI never reaches into backends directly" honest; justify in PROGRESS.
1. **Status line / error text** — confirm OBS `recording_error` (e.g. B1 "OBS Studio not found", the 4009 password guidance) and `recording_notice` surface in the dock unchanged.

## Tests (plan §8 + §6; extend `test/unit/test_time_machine_dock.gd`)

Use the existing `MockBackend`/`_build_dock`/`FakeStore` pattern; add a fake backend mirroring `BackendOBS` (name "OBS Studio", `is_available()` toggleable, `get_native_formats()` → `[MP4]`, emit-able `availability_changed`):

- gating: OBS unavailable → item marked "— not available" (+ tooltip); available → normal.
- live refresh: emit `availability_changed(true)` → marking clears (or vice versa).
- native formats: with the OBS fake active, the format dropdown offers only MP4; Movie Maker / Screenshot behavior is unchanged (existing tests stay green).
- dialog: selecting unavailable OBS → dialog shown; flag `hints/dont_show_obs_hint` set → not shown; "don't show again" persists the flag.
- existing dock/GUT tests must stay green throughout.

## Verify

- `make test-godot` (headless GUT) — stay green (266 baseline + new dock tests).
- Run the pre-commit hooks on changed files: `gdformat`, `trailing-whitespace`, `end-of-file-fixer`, `gitleaks`, `mdformat` (notes).
- Do NOT commit. Update `notes/PROGRESS_obs_backend_v2.md` with the Phase 3 summary (what landed, test delta, the two design decisions above and how you resolved them, deviations from §6).
- Manual (user's run, after code lands): §9 items 1–5 against the real dock with OBS on 4455; `tools/obs_backend_drive.gd` remains a valid pre-dock cross-check.

## Style / anti-goals

- Tabs, snake_case, doc comments on new members; match the existing dock file.
- **Scope lock (§1):** NO `platform_capture.gd`, NO RestoreToken/token persistence, NO `needs_setup()`/Wayland flow, NO `SetRecordDirectory`, NO ffmpeg tier-2 conversion wiring, **NO dock password OBS settings rows** (§2 lock — password stays in Project > Editor Settings).
- Do NOT change the controller's public signal contract incompatibly; do NOT let the dock manage/kill OBS processes (the backend owns process lifecycle).
- Do NOT regress the plugin-level shortcut/command-palette work from the 2026-08-14 session.
