# Progress — OBS Backend v2

Date: 2026-08-14. Branch: `obs-backend-v2`. Working: **Phases 0–2 COMPLETE; Phase 3 IN PROGRESS** (plugin registration + editor-settings defaults done; dock gating / install dialog / native-format filter + tests remaining — see `notes/SEED_phase3_dock_wiring.md`).

## Decisions locked at session start (user)

- **Scope: Phase 0 only.** Run the code-side gate (reference vector + plumbing proof), then pause for review. No feature code.
- **Real-OBS matrix: wait.** The manual correct/wrong/none-password run on 4455 is the user's, after the code-side gate. Do not start Phase 1 without it.
- **Dock OBS settings UI: still cut.** Password/host/port live in `gd_time_machine/obs/*` (Project > Editor Settings). A dock field stays a possible follow-up.

## Phase 0 code-side results

### 3.1 Reference cross-check — PASS

Independently recomputed with `python3` `hashlib`+`base64` (NOT the function under test):

| (password, salt, challenge) | vector | |---|---| | `("password", "salt", "challenge")` | `zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA=` | | `("p@ss w0rd", "s01t", "chal-1")` | `OviXHTMUDxkuThqADhlITYdX+RovQ9rp+QknwnKk4MY=` | | `("", "", "")` | `XEB0z23rR/W2r5xf4+C70OQrlZb+iKxU1ca275h+DyA=` |

These are **exactly** the three constants the v1 `test_obs_client.gd` already claimed. The seed prompt doubted them ("computed by our own function"); that doubt is now settled — the vectors were independently correct. Pinned as fixed constants in `test_obs_client.gd` (hard regression lock). Algorithm confirmed: `_generate_auth` matches obs-websocket 5.x.

### 3.2 Plumbing proof — root cause FOUND (new evidence)

Probing the headless + editor environments on Godot **4.7.1**:

```
godot --headless -s probe.gd          → Engine.has_singleton("EditorSettings") == false
godot --headless --editor -s probe.gd → Engine.has_singleton("EditorSettings") == false   ← editor too!
EditorInterface.get_editor_settings()  → exists, works (editor mode)
```

**The v1 `Engine.has_singleton("EditorSettings")` check is dead code on 4.7.** That branch never fired, so `_get_setting_string()` *always* fell through to `ProjectSettings` (or default). Fold in the established codebase finding that the dock has no OBS UI at all, and the user's password, saved in Project > Editor Settings, could **never** reach `_get_obs_settings()` → empty password → close code 4009. That is the plumbing Bug 7 explanation, now with a concrete engine-level cause — not just "the docks has no UI".

Fix path adopted: reuse this codebase's proven `EditorSettingsConfigStore` pattern (config/editor_settings_store.gd) — `_editor_settings` injected seam, else `EditorInterface.get_editor_settings()` when `Engine.is_editor_hint()`, else null → `EditorSettings-first, then ProjectSettings, then default`. Headless GUT covers ProjectSettings via the real singleton; the EditorSettings-present branch is covered by injecting a fake store through `_editor_settings` (same seam the config store tests already use).

### 3.3 Real OBS (manual) — PASS, run by user 2026-08-14

Probe: `tools/obs_auth_probe.gd` (Phase 0 tooling, not addon code) connects to `ws://127.0.0.1:4455`, uses `OBSClient._generate_auth` on a real obs-websocket 5.x server:

| case | result | |---|---| | correct password (`obs-auth`), auth enabled | `RESULT IDENTIFIED` — real OBS accepted the auth response | | wrong password (`obs-auth2`), auth enabled | `RESULT AUTH_FAILED (close 4009): Authentication failed.` | | empty password, auth disabled | `RESULT IDENTIFIED` (no `authentication` field sent) |

**Phase 0 exit criteria met:** fixed vector test green, plumbing test green, real-OBS matrix behaves exactly as documented. (The `ObjectDB leaked` / `resources still in use` warnings at probe exit are the probe quitting without freeing its WebSocketPeer — tooling noise, not an addon issue.)

**Phase 0 COMPLETE. Next: Phase 1** (`vendor/obs_client.gd` full client port) once the user approves.

### Phase 0 test breakdown

`test_obs_client.gd`

- `test_generate_auth_matches_python_reference`
- `test_generate_auth_special_characters_matches_reference`
- `test_generate_auth_empty_input_matches_reference`
- `test_connect_to_obs_stores_password` (client half of the plumbing chain)
- `test_connect_to_obs_rejects_out_of_range_port`

`test_backend_obs.gd`

- `test_password_read_from_project_settings_fallback` (EditorSettings absent)
- `test_empty_password_default_when_unset`
- `test_editor_settings_shadow_project_settings` (fake store; precedence that lost the v1 password)
- `test_project_settings_reads_through_typed_reader`
- `test_port_reader_falls_back_to_default`

The single seam that joins the two halves (`start()`/`probe` forwarding settings-password into `connect_to_obs`) lands with Phase 2 — noted in the test doc-comments; Phase 0 proves the read half and the assign half.

## Files created (Phase 0 only)

- `vendor/obs_client.gd` — `@tool extends Node class_name OBSClient`, `_generate_auth` (static, pinned) + `connect_to_obs()` port/`_password` plumbing. State machine deliberately NOT ported (Phase 1).
- `vendor/NOTICE.txt` — obs-websocket-gd Apache-2.0 attribution (from v1).
- `backend/backend_obs.gd` — `@tool extends RecorderBackend class_name BackendOBS`, `_get_es()`/`_get_obs_settings()`/typed readers. No connection/state code (Phase 2).
- `test/unit/test_obs_client.gd`, `test/unit/test_backend_obs.gd`.

## Phase 1 — OBSClient full port (DONE)

Port of the v1 client (obs-backend-wip) into `vendor/obs_client.gd` per plan §4, with exactly ONE behavioral change.

### What landed

- **State machine** `DISCONNECTED → CONNECTING → AWAITING_HELLO → AWAITING_IDENTIFIED → READY → CLOSING`, polled every `_process` (no throttle), `_ready()` starts with `set_process(false)`.
- **Handshake** `connect_to_obs` → `_create_websocket_peer()` seam → `connect_to_url("ws://host:port", null)` with `SUBPROTOCOL`, `CONNECT_TIMEOUT = 5.0` deadline, `set_process(true)`. `_handle_hello` reads `authentication.{salt,challenge}`; Identify always carries `rpcVersion: 1` + `eventSubscriptions` (`EVENT_SUBSCRIPTIONS = (1<<0)|(1<<2)|(1<<3)|(1<<6)`).
- **The v2 auth rule (the one behavioral change):** `_handle_hello` now computes `_generate_auth` ONLY when `_password != ""` AND both salt+challenge are present. Empty password → Identify has **no** `authentication` field (auth-disabled server connects; auth-enabled closes 4009 → surfaced later by the backend). v1 computed auth even for empty password — the masking bug this port fixes.
- **Requests** `send_request(requestType, requestData, requestId=auto)` → `{"op":6,...}`, `{"op":7,...}` correlated by `requestId` → `request_completed`. Ops covered: GetVersion, GetRecordStatus, StartRecord, StopRecord (`outputPath`), GetSceneList, SetCurrentProgramScene. Ported `STATUS_SUCCESS/NOT_READY/OUTPUT_RUNNING` + `CLOSE_CODE_UNSUPPORTED_RPC`.
- **Signals** `connection_established`, `connection_authenticated`, `connection_closed(code, reason)`, `connection_failed(message)`, `request_completed(...)`, `event_received(...)`, plus v1's `data_received` low-level passthrough.
- **Failure classification** ported verbatim: `_on_socket_closed` (READY/CLOSING → `connection_closed`, else `connection_failed`) + `_describe_connect_failure` (4009 → "Authentication failed — OBS rejected the password (close code 4009)", 4010 → unsupported RPC, generic reach error with host:port) + `_check_connect_timeout` message.
- **Seams** `_create_websocket_peer()` (untyped), `_now()` (monotonic), `is_connected_to_obs()`, `get_ready_state()`, `get_state()`. No `OS.execute`, no Thread. **NOT ported** (scope lock §1): capture-source helpers (`create_input`, `get_scene_item_list`, `get_input_kind_list`, `INPUT_KIND_*`) — deferred to `platform_capture.gd`; `SetRecordDirectory`, auto-close teardown, backend/dock wiring.
- **Kept untouched:** `_generate_auth` (pinned) verbatim; `connect_to_obs` keeps `_password/_host/_port` storage and the out-of-range port → `ERR_INVALID_PARAMETER` (docstring upgraded from "Phase 0 records the target" to the real contract).

### Test delta (`test/unit/test_obs_client.gd`: 5 → 16)

All 5 Phase 0 tests untouched and green. Added (v1 `FakeWebSocketPeer`/`FakeOBSClient` seam pattern):

- `test_connect_defaults_and_handshake_happy_path` (established → authenticated)
- `test_hello_with_auth_sends_authentication_string` (challenge + non-empty password)
- `test_empty_password_sends_no_authentication_field` (**v2 rule** — v1 sent a bogus one)
- `test_send_request_shape_and_request_id_correlation` (+ unknown-id drop)
- `test_send_request_auto_generated_ids_increment`
- `test_event_forwarded_as_event_received`
- `test_close_after_ready_emits_connection_closed`
- `test_tcp_connect_failure_emits_connection_failed`
- `test_auth_failure_emits_distinct_connection_failed_message` (close 4009)
- `test_handshake_timeout_emits_connection_failed` (via `_now()` seam)
- `test_poll_processes_packets_every_frame_without_throttle`

`make test-godot`: 248 total (16 client + 232 baseline), all green, no ObjectDB leaks, no warnings. Pre-commit (gdformat, trailing-whitespace, end-of-file-fixer, gitleaks) passes on changed files.

### Deviations from plan §4 / seed

- **None in behavior.** Two test-file notes: (a) the seed's "no challenge → no authentication field" case is asserted inside the happy-path test (`test_connect_defaults_and_handshake_happy_path`, `assert_false(identify["d"].has("authentication"))`) rather than as a separate test; (b) v1's duplicate `test_generate_auth_matches_known_vectors` was dropped — the three Phase 0 pinned-vector tests already cover it.
- `_handle_hello` requires salt **and** challenge present before computing (seed says "challenge present"; requiring both is the safe reading — a challenge with no salt cannot be answered correctly).

### Cleanup

`tools/obs_auth_probe.gd` deleted (superseded by the real client + fake-peer tests, per seed §Cleanup). Historical references to it in Phase 0 evidence above are left as-is (record of what ran).

## Phase 2 — BackendOBS (`backend/backend_obs.gd`) (DONE)

Port of the v1 backend into the Phase 0 `backend_obs.gd` per plan §5. Two spec-open decisions were locked with the user before writing code — **A1** and **B1**, both the proven v1 behavior:

- **A1 — pending-start poll:** `_poll_timer` polls `_is_playing_scene()` (v1), not §5's literal GetRecordStatus. PENDING_START = "launched the scene, waiting for it"; when it starts, `_begin_recording()` connects + `StartRecord`, confirmed by its own response (`result || code==STATUS_OUTPUT_RUNNING` counts as success). Rationale recorded at decision time: GetRecordStatus says nothing about scene state, adds a request round-trip and a second failure surface, and no §5 test needs it.
- **B1 — start() unreachable path:** an explicit `is_obs_installed()` gate first with the actionable "OBS Studio not found … Tools → WebSocket Server Settings" error, then `is_obs_running()` → `ensure_obs_running()`, then `recording_error(_describe_start_error())` (which appends the 4009 password hint). Plan §9 wants "not installed" distinguishable; §5's single-funnel text lives beneath it for reachable-but-connect-fails.

### What landed

- **Two-axis availability** (plan §2, never conflated): `is_available()` = cached probe result `_available`; `is_obs_installed()` = `_resolve_and_cache_binary()` guarded by the `_obs_binary_resolved` flag (Bug 1). `_ready()` seeds+refreshes the probe on the `AVAILABILITY_TTL` 5 s cycle **only under `Engine.is_editor_hint()`** — headless GUT never opens a real socket, keeping Phase 0 plumbing tests deterministic.
- **Probe/launch/ownership:** `probe_obs_async()` (fire-and-forget, captures failures into `_last_connect_error`), `ensure_obs_running()` gating on `is_obs_running()` reachability (Bug 3), launch `--minimize-to-tray` when `auto_launch`, 10 s poll, kill own pid on timeout, `_we_launched` tracking. Never kills a pre-existing OBS.
- **Record flow:** `start()` parse + non-MP4 format guard (v1 records MP4 natively; webm/avi/ogv deferred §1) → B1 install gate → reachability → A1 scene-poll pending-start → `_begin_recording()` (connect 3 s, `SetCurrentProgramScene`, `StartRecord`). `stop()` → `StopRecord` → read `outputPath` → move-after-stop (`_resolve_and_move_output` with `globalize_path`/`path_join` fallback) → `_finalize_stopped()` single `recording_stopped` emission (guarded). 3 s fallback timer protects a dropped StopRecord response.
- **Error surfacing:** v1 `_last_connect_error` + `_describe_start_error()` — 4009 → "Authentication failed" + password guidance naming `gd_time_machine/obs/password`.
- **Seams** `_create_obs_client()`, `_get_obs_settings()`, `_is_playing_scene()`, `_play_scene()`, `_now()`, `_sleep()`, `_resolve_obs_binary()`, `_os_execute()`, `_launch_obs_process()`, `_kill_process()`. `_get_auto_close_setting()` reads via the Phase 0 `_read_setting` seam (EditorSettings-first), not the dead `Engine.has_singleton("EditorSettings")` branch.
- **Cut (scope lock §1):** capture-source machinery (`ensure_screen_capture`, token persistence, `needs_setup`, Wayland detect), `SetRecordDirectory` (move-after-stop only), ffmpeg tier-2 conversion/`recording_converted`, idle-timer `auto_close` teardown (only `_exit_tree` best-effort kill-if-`_we_launched` kept).

### Test delta (`test/unit/test_backend_obs.gd`: 5 → 26)

All 5 Phase 0 plumbing tests untouched and green. Added — contract; two-axis availability (installed true/false, resolve-exactly-once, is_available never-binary both directions, `is_obs_running` stale→re-probe / fresh→no); ensure_obs_running (reachable-no-launch, launch+own, kill-own-on-timeout); start paths (B1 not-installed error, format guard, happy `recording_started`, A1 pending-start launches scene then records, pending expiry, duration auto-stop); stop (never-kill + single emission, pending-stop without connecting); file-move fallback; probe failure capture + auth-guidance + generic error text (v1 Bug-7 pattern). Seam fakes: `FakeOBSClient` (synchronous connect-to-READY / `connection_failed`, **deferred one-frame request replies** to honor the async ordering `_pending_request_id` relies on), `FakeBackendOBS`, `RecordingBackend`, `LaunchTestBackend`, `ProbeFailureBackend`.

`make test-godot`: **266 total** (26 backend + 240 baseline), all green, 0 failures/warnings. Pre-commit (gdformat now fixing my form, trailing-whitespace, end-of-file-fixer, gitleaks) green on both files.

### Deviations from plan §5 / spec

- **A1 by user lock:** GetRecordStatus not used in the poll (client op still shipped in Phase 1 for Phase-3-era use).
- `_ready()` availability wiring is editor-gated (plan doesn't say; necessary for deterministic headless tests since the Phase 0 `_make_backend()` constructs the raw class).
- Format guard (non-MP4 → `recording_error`) added as a Phase-2-than-Phase-3 correctness cut; plan only mandates the MP4-native format set.

## Interactive driver (new Phase-2 tooling)

`tools/obs_backend_drive.gd` (`extends SceneTree`, runs via `godot --headless -s`) drives the REAL backend — real probe, connect, StartRecord/StopRecord, move-after-stop — against a live obs-websocket server, plus the B1 not-installed error path. Only seams stubbed: `_is_playing_scene()`/`_play_scene()` (back onto `EditorInterface`; the dock owns those in Phase 3). This supersedes the deleted Phase 0 probe as the pre-dock form of the §9 matrix (items 1–3).

Usage (mirrors matrix): `godot --headless -s --path . tools/obs_backend_drive.gd -- [--password X] [--binary PATH] [--wait SECONDS] [--output PATH] [--host/--port] [--launch] [--no-obs]`. Live mode gates on a fresh `probe_obs_async()` result first (cold-cache: `is_obs_running()` returns stale false and fires an async probe, so `start()`'s `ensure_obs_running()` would bail before the answer lands — this is Bug-3 behavior, not a driver bug); `--launch` bypasses the gate so `ensure_obs_running()` can spawn and poll for itself.

Verified live (2026-08-14, user confirmed OBS WebSocket up on 4455, auth disabled): `--no-obs` → `RESULT EXPECTED_ERROR` (B1 "OBS Studio not found"); live empty-password run → `RESULT OK`, 1.38 MB `res://media/captures/obs/obs_driver.mp4` moved into the repo (file present). Full suite stays green (266).

## Next actions

1. Execute the remaining Phase 3 via `notes/SEED_phase3_dock_wiring.md` — dock availability gating, install dialog, native-mp4 format filter, `hints/dont_show_obs_hint`, tests.
1. After Phase 3: run the §9 manual matrix against the real dock (OBS on 4455 — no password / matching / wrong password; not-installed + `auto_launch`), then mark the plan complete and merge `obs-backend-v2` back to `main`.
1. `make test-godot` — green (266 total) at time of writing.

## Session 2026-08-14 (afternoon) — editor-startup log fixes + Phase-3 registration

Startup logs showed two defects (user report via `make launch-editor`):

1. **`Unknown backend 'OBS Studio'` (×4)** — the saved dock profile still selects "OBS Studio" (v1 era), but the v2 plugin registered only Movie Maker + Screenshot; the fully-tested `BackendOBS` (Phases 1–2) was never wired in. Fixed: registered `BackendOBS` in `plugin.gd._enter_tree` after Screenshot (Movie Maker stays default), and extended `_ensure_editor_settings_defaults()` with the `gd_time_machine/obs/{host,port,password,scene,auto_launch,auto_close,binary_path}` defaults + property info per plan §6 (install-hint `hints/dont_show_obs_hint` and the dock gating/dialog deferred with the rest of Phase 3).
1. **`The Command 'GdTimeMachine: Toggle Recording' doesn't exists. Unable to remove it.`** — `_unregister_recording_shortcut()` passed `COMMAND_PALETTE_ACTION` (display name) to `EditorCommandPalette.remove_command()`, but that API keys by the key name (`COMMAND_PALETTE_KEY`). With the wrong identifier the C++ warn fired on the exit_tree during startup teardown. Fixed: remove by `COMMAND_PALETTE_KEY`, guarded by a `_command_palette_registered` flag set only when `add_command` actually ran (palette singleton can be null during early editor init).

Regression lock: `test_plugin_shortcut.gd` now pins that the palette action and key are distinct identifiers (the exact conflation behind the teardown error). Full suite green (266); headless `--editor --quit` cycle clean (plugins init + teardown, no warnings/errors). Remaining Phase-3 §6 dock work (availability gating, install dialog, native-format filter) is still deferred — OBS is selectable now and surfacing errors is backend-guaranteed.

## Phase 3 — plugin + dock wiring (IN PROGRESS)

Scoped in `notes/SEED_phase3_dock_wiring.md`. Done so far (2026-08-14 session, with the startup-log fixes above):

- `plugin.gd` registers `BackendOBS` after Screenshot (Movie Maker stays default) — the saved "OBS Studio" profile now resolves, no more `Unknown backend` warnings.
- `_ensure_editor_settings_defaults()` adds `gd_time_machine/obs/{host,port,password,scene,auto_launch,auto_close,binary_path}` with property info (the only source `_get_obs_settings()` reads).
- Note: plan §6's `_exit_tree` best-effort kill is already satisfied by `BackendOBS._exit_tree()` itself (`_we_launched && auto_close` → `_kill_process`, then `_release_obs_client`); `BackendOBS` has no `_debugger_plugin` to null.

Remaining (§6 / §7 / §9, per the seed): `hints/dont_show_obs_hint` default; `_populate_backends()` marks OBS "— not available" when `is_available()` is false; `_get_allowed_formats()` honors `get_native_formats()` (MP4) for OBS; one-time install dialog (dynamic text, Bug-6 lesson) with obsproject.com link on selecting an unavailable OBS; live availability refresh from `BackendOBS.availability_changed` (dock needs backend access — see seed's design notes); install-hint AcceptDialog node in `time_machine_dock.tscn`; gating/dialog/native-formats tests in `test_time_machine_dock.gd`.
