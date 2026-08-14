# Plan — OBS Backend v2 (ground-up rebuild, minimal core)

Date: 2026-08-11 Status: `plan` — v2 plan, locked 2026-08-14; **Phase 0 code-side gate DONE** (reference vector + plumbing proof green, `notes/PROGRESS_obs_backend_v2.md`). Phases 1–3 not started (blocked on the user's real-OBS matrix). Branch: `obs-backend-v2` (from clean `main`). Archive of the v1 experiment: branch `obs-backend-wip` (`f74a953` impl, `713e147` tests, `f5e2a96` notes, `263b5f8` bug-7 test polish) — all 221 GUT tests green on the archive.

> Write location rule: `notes/` is the per-session plan store (`AGENTS.md`). This file IS the v2 work plan. No worker starts without explicit user "execute plan".

______________________________________________________________________

## 0. Why a ground-up rebuild (lessons from v1)

The v1 experiment (obs-backend-wip) produced 7 confirmed bugs. Post-mortem:

| Lesson | Evidence | |---|---| | **Auth math is NOT the bug.** `_generate_auth` = `base64(sha256(base64(sha256(password + salt)) + challenge))` — matches obs-websocket 5.x spec and the reference C++/JS implementations verbatim. The 4009-with-"matching"-password failure means the **password never reached `_password` on the client** (plumbing), or a settings-store mismatch (`_get_setting_string` reads EditorSettings first, then ProjectSettings; the dock has **no** OBS settings UI at all — zero matches for `obs/` or `password` in `time_machine_dock.gd`). User's live test proves the symmetry: auth *disabled* connects; auth *enabled* with intended-matching password gets 4009. | v1 `test_obs_client.gd` vectors were computed by our own function → self-consistent, proved nothing about OBS acceptance. | | **`is_available()` semantics drifted** → caused Bugs 1, 3, 4. Plan locked `is_available()` = *WebSocket reachable*; implementation made it *binary installed*. The empty-String cache sentinel (`"" == null` is never true) made the lazy resolve never fire. | BUGS_obs_backend_regressions.md Bug 1/3/4 | | **Await discipline**: calling a coroutine (`ensure_screen_capture`) without `await` → SCRIPT ERROR. | Bug 5 | | **Hardcoded UX text** assumed OBS running when it wasn't. | Bug 6 | | **Error surfacing** was the Bug 7 fix (capture `_last_connect_error`, `_describe_start_error()` + password guidance) — this landed and is worth keeping. | `263b5f8` |

**v2 stance:** keep the architecture that held (thin `OBSClient`, seams for GUT, single-emission `_finalize_stopped` funnel, ownership `_we_launched`/`auto_close` rules), re-implement the plumbing with tests-first, and gate everything on a **verified auth path** (Phase 0).

______________________________________________________________________

## 1. Scope (minimal core — user decision)

**IN v1:**

- `vendor/obs_client.gd` thin `WebSocketPeer` client with **verified** auth + `NOTICE.txt`
- `backend/backend_obs.gd` — `IN_PLACE`, connect/start/stop, file handling, error surfacing, auto-launch
- `plugin.gd` — register `gd_time_machine/obs/*` EditorSettings + register `BackendOBS`
- `ui/time_machine_dock.gd` (+tscn) — backend-populate gating by `is_available()`, status line, install-hint dialog
- GUT tests: `test_obs_client.gd`, `test_backend_obs.gd`, dock gating tests

**DEFERRED (follow-up, NOT v1):**

- `platform_capture.gd` (PipeWire portal detect) and `obs_token_persistence.gd` (RestoreToken) — the "Detect Capture Source" flow
- `needs_setup()` / Wayland setup dialog
- `auto_close` ownership polish (v1 spawned-and-killed OBS; v1 keeps spawn only, teardown = leave running or `_exit_tree` best-effort)
- Tier-2 ffmpeg conversion wiring (OBS native `mp4` is enough for v1; `webm/avi/ogv` via ffmpeg comes later)
- `SetRecordDirectory` vs move: **move-after-stop only** for v1 (simpler, fewer OBS-version branches); `SetRecordDirectory` deferred

**Success looks like:** user with OBS running + WebSocket enabled (with or without password) sees "OBS Studio" selectable; Record → OBS records → file lands in `output_dir`; Stop never kills the game; auth mismatches surface an actionable error, not a hang.

______________________________________________________________________

## 2. Locked decisions

| Question | Decision | Why | |---|---|---| | Auth verification strategy | **Phase 0 gate, before ANY feature code**: (a) independent reference cross-check of `_generate_auth` (compute expected value with a non-Godot reference — e.g. Python `hashlib`+`base64` or obs-websocket-js — pin as a fixed GUT vector), (b) plumbing proof (fake-settings test that the password read from the settings store actually lands in `_password`), (c) real-OBS manual check with a known password on 4455. | User decision: "Reference cross-check + real OBS". The v1 vectors were self-computed and proved nothing. | | `is_available()` vs `is_obs_installed()` | **Two separate axes, never conflated**: `is_available()` = WebSocket reachable (probe got `Identified`); `is_obs_installed()` = binary resolved (separate, for install hints only). Binary cache uses a **resolved-flag** (`_obs_binary_resolved: bool`), never an empty-String sentinel. | Bugs 1/3/4 root cause. | | Dock settings UI | **No OBS settings rows in the dock for v1.** Password/host/port configured via Project > Editor Settings (`gd_time_machine/obs/*`), which is the only source `_get_obs_settings()` reads. A GUT test must prove the read path. A dock password field is a possible follow-up if the plumbing proof shows the Editor-Settings path is the confusion point. | Zero `obs/` UI exists in v1 dock; keep scope tight, prove the read path instead. | | File handling | Move-after-stop: `StopRecord.outputPath` (file name) + OBS default Recording Path → rename to dock's `output_path + ext`. Handle name-vs-full-path across versions (normalize with `globalize_path` + `path_join` fallback). | Fewer OBS-version branches for minimal core. | | Auth behavior with empty password | **Send no `authentication` field** when password is empty (server with auth disabled accepts; server with auth enabled closes 4009 → surfaced by error path). Do NOT compute auth for empty password. | v1 computed auth even for empty → masked the plumbing bug. v2: empty password = no auth field; mismatch only ever surfaces with a non-empty password. | | Teardown | v1 owns the process it spawned (`_we_launched` + pid); kills on idle/`_exit_tree` only if `auto_close`. v1 keeps spawn + `_we_launched` tracking, defers the idle-timer teardown polish. Never kill a pre-existing OBS. | Ownership rules held in v1. |

______________________________________________________________________

## 3. Phase 0 — Auth verification gate (BLOCKING, do first)

**Goal:** prove or disprove the two hypotheses (algorithm vs plumbing) with evidence before writing feature code.

1. **Reference cross-check.** Compute the expected auth string for a fixed `(password, salt, challenge)` triple using an independent reference (Python one-liner or obs-websocket-js). Pin it as a constant in `test_obs_client.gd`. If `_generate_auth` output differs → algorithm bug, fix before anything else. If it matches → algorithm is correct; the v1 failure was plumbing.
1. **Plumbing proof (GUT).** Fake the settings store; assert the password string read via `_get_obs_settings()` reaches `client.connect_to_obs(host, port, password)` → `_password`. Cover both stores (EditorSettings present vs absent → ProjectSettings fallback).
1. **Real OBS (manual, blocking for release but not for code).** OBS running, WebSocket enabled, known password set in OBS **and** in `gd_time_machine/obs/password` → must reach `Identified`. Wrong password → 4009 with the actionable error. Auth disabled → connects. This run will also settle where the user's password was actually going (their Editor Settings may have been overridden by a project.godot copy, or never saved).

**Exit criteria for Phase 0:** the fixed vector test is green, the plumbing test is green, and the real-OBS matrix (correct/wrong/none password) behaves as documented.

______________________________________________________________________

## 4. Phase 1 — OBSClient (`vendor/obs_client.gd`, `@tool`, `class_name OBSClient`)

Port the v1 client (it held up) minus the empty-password auth behavior:

- State machine: `DISCONNECTED → CONNECTING → AWAITING_HELLO → AWAITING_IDENTIFIED → READY → CLOSING`; poll every `_process` (no throttle).
- `_handle_hello`: read `d.authentication.{salt,challenge}`; **only if password non-empty**, compute `_generate_auth` and include `authentication` in Identify; always send `rpcVersion: 1` + `eventSubscriptions`.
- `_generate_auth` — static, pure; verified by the Phase 0 fixed vector.
- Requests: `send_request(requestType, requestData, requestId=auto)` → `{"op":6,...}`; correlate `{"op":7,...}` by `requestId` → `request_completed`. Ops needed: `GetVersion` (probe `availableRequests`), `GetRecordStatus`, `StartRecord`, `StopRecord` (`outputPath`), `GetSceneList`, `SetCurrentProgramScene`.
- Signals: `connection_established`, `connection_authenticated`, `connection_closed(code, reason)`, `connection_failed(message)`, `request_completed(...)`, `event_received(...)`.
- Seams: `_create_websocket_peer()`, `_now()`, `is_connected()`, `get_ready_state()`. No `OS.execute`.
- Tests: fixed auth vector; connect happy-path via faked `WebSocketPeer`; auth-fail close 4009 → `connection_failed("Authentication failed…")`; no-auth-field-when-empty-password; request JSON shape; `requestId` correlation; poll pumps every frame; connect timeout.

______________________________________________________________________

## 5. Phase 2 — BackendOBS (`backend/backend_obs.gd`)

`@tool extends RecorderBackend`, `IN_PLACE`. States `IDLE → PENDING_START → RECORDING → STOPPING → IDLE`; timers `_poll_timer` (0.5 s GetRecordStatus while PENDING_START), `_duration_timer`, availability TTL (5 s).

- `is_available()` — cached probe result; never binary presence. `probe_obs_async()` → connect → await `connection_authenticated` (1.5 s) → disconnect → cache. `availability_changed(bool)` signal.
- `is_obs_installed()` — `_resolve_and_cache_binary()` with **resolved-flag**; per-OS candidates + `obs/binary_path` override. Used only for install hints / launch.
- `ensure_obs_running()` — gate on `is_obs_running()` (reachability), NOT `is_available()`-as-installed (Bug 3). Launch `--minimize-to-tray` when `auto_launch`, poll up to 10 s, kill own pid on timeout, set `_we_launched`.
- `start(config)` — parse; `!is_available()` → `ensure_obs_running()`; still unreachable → `recording_error(_describe_start_error())` and return. Connect+auth with 3 s timeout. `StartRecord` → on success emit `recording_started`; `code==500` (already recording) treat as success. Never restarts/kills the game (`IN_PLACE` invariant).
- `stop()` — `StopRecord` → `outputPath` → move to dock's `output_path + ext` → `_finalize_stopped()` single emission. Never kills the game.
- Error surfacing — keep v1's `_last_connect_error` + `_describe_start_error()` (auth mismatch → actionable password hint).
- `_finalize_stopped()` — single `recording_stopped` emission guard; stop timers; disconnect owned client.
- Seams: `_create_obs_client()`, `_get_obs_settings()`, `_is_playing_scene()`, `_play_scene()`, `_now()`, `_resolve_obs_binary()`, `_launch_obs_process()`, `_kill_process()`.
- Tests: contract (`get_backend_name/description/capture_mode`), `is_available` TTL + never-binary, `is_obs_installed` resolved-flag (installed/missing), `start` happy vs unreachable, pending-start launch, `stop` no-kill, duration auto-stop, single emission, file move fallback, auth-failure error text (Phase 0 plumbing test reuse).

______________________________________________________________________

## 6. Phase 3 — plugin + dock wiring

- `plugin.gd` — `_ensure_editor_settings_defaults()` extended with `gd_time_machine/obs/{host,port,password,scene,auto_launch,auto_close,binary_path}` + `hints/dont_show_obs_hint`; register `BackendOBS` after Screenshot (Movie Maker stays default). `_exit_tree` — best-effort kill only if `_we_launched` and `auto_close`; null `_debugger_plugin`.
- `time_machine_dock.gd` — `_populate_backends()` disables OBS item when `!is_available()` with "— not available" + tooltip; `_get_allowed_formats()` honors `get_native_formats()` (mp4) when present; `_on_backend_changed()` triggers one-time install dialog (guarded by `dont_show_obs_hint`, `OS.shell_open` to obsproject.com); status line reuses existing `recording_*` contract.
- Dialog text must be built dynamically (Bug 6 lesson — but `needs_setup` is deferred, so the setup dialog itself is out of scope; the install hint dialog is in).
- Tests: gating (fake backend `is_available()==false` → item disabled), dialog suppressed by flag, native-formats filter.

______________________________________________________________________

## 7. File manifest (v2 delta from main)

```
addons/GdTimeMachine/
├── plugin.gd                              # obs/* EditorSettings defaults + BackendOBS registration
├── vendor/
│   ├── obs_client.gd                      # NEW — thin WebSocketPeer client, @tool, verified auth
│   └── NOTICE.txt                         # NEW — auth logic from you-win/obs-websocket-gd (Apache-2.0)
├── backend/backend_obs.gd                 # NEW — IN_PLACE, minimal core
├── ui/
│   ├── time_machine_dock.gd               # backend gating + install dialog + native formats
│   └── time_machine_dock.tscn             # install-hint AcceptDialog node
└── test/unit/
    ├── test_obs_client.gd                 # NEW — auth vector, framing, handshake, timeouts
    ├── test_backend_obs.gd                # NEW — state machine, availability, error surfacing
    └── test_time_machine_dock.gd          # gating + dialog flag tests (extend existing)
```

Untouched: `recorder_backend.gd`, `backend_screenshot_capture.gd`, `backend_movie_maker.gd`, `ffmpeg_convert.gd`, `config/*`, `controller/*` (except registration in plugin.gd). Deferred files (portal detect, token persistence) deliberately NOT created.

______________________________________________________________________

## 8. Testing strategy

- All headless via `make test-godot` (GUT). OBS tests use fakes only (seams `_create_obs_client`, `_create_websocket_peer`, `_get_obs_settings`); never require a running OBS or binary. Manual-only checks are listed in §9 and tagged `skip`-style in CI if needed.
- The Phase 0 auth vector is a hard regression lock — any future auth regression fails CI immediately.
- Contract tests mirror screenshot/movie-maker patterns (`test_backend_obs.gd` ~12 cases, `test_obs_client.gd` ~8 cases).

______________________________________________________________________

## 9. Manual verification checklist (after Phases 1–3)

1. OBS running, WebSocket enabled, **no password** → dock shows OBS selectable; Record → OBS records → mp4 in `output_dir`; Stop finalizes; game never killed.
1. OBS running with a **known password** (set same in Editor Settings) → connects (`Identified`).
1. OBS running with a password, plugin password **wrong/empty** → actionable error naming the password setting (no hang, no generic install error).
1. OBS **stopped**, `auto_launch` on → Record launches OBS `--minimize-to-tray`, records; OBS killed only if we launched it.
1. OBS **not installed** → "OBS Studio — not available" greyed, one-time install dialog with link.
1. `make test-godot` green throughout.

______________________________________________________________________

## 10. What to do next

1. Review this plan — confirm the minimal-core cuts (§1), the two-axis availability lock (§2), and the Phase 0 gate.
1. Say **"execute PLAN_obs_backend_v2"** → Sisyphus delegates Phase 0 first (it is blocking), then Phases 1–3 per the delegation map (each phase = one `task(category=…, load_skills=[…])` lane; workers read this file).
1. Phase 0 real-OBS run needs a machine with OBS on 4455 — flag if you want that gated until you can run it manually.
