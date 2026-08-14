# Seed Prompt — Phase 1: `vendor/obs_client.gd` full client port

Use this as the opening prompt for the Phase 1 agent. It orients the worker to the mission, the locked spec, and the Phase 0 evidence that gates it. The worker MUST read the plan and v1 archive before writing code.

______________________________________________________________________

## Mission

Complete **Phase 1 of the OBS backend v2 rebuild** on branch **`obs-backend-v2`** of GdTimeMachine: port the v1 `OBSClient` (it held up) into the Phase 0 file `addons/GdTimeMachine/vendor/obs_client.gd` — state machine, Hello/Identify handshake, request plumbing — with exactly **ONE behavioral change**: empty password → send NO `authentication` field in Identify (v1 computed auth even for an empty password; that masked the plumbing bug).

## Gate status (do not re-litigate)

Phase 0 is DONE and verified — the auth algorithm is proven against a real obs-websocket 5.x server (`tools/obs_auth_probe.gd`): correct password → `Identified`; wrong → close 4009; empty + auth disabled → `Identified` with no `authentication` field. The settings read-path plumbing is fixed (`Engine.has_singleton("EditorSettings")` is false in 4.7 even under `--editor`; the fixed path uses `EditorInterface.get_editor_settings()` + injected seam). Evidence: `notes/PROGRESS_obs_backend_v2.md`.

## Read first (mandatory)

1. `notes/PLAN_obs_backend_v2.md` — **§4 is YOUR spec**. Also §2 locked decisions (the empty-password rule), §7 manifest, §8 testing strategy.
1. `notes/PROGRESS_obs_backend_v2.md` — Phase 0 evidence + what the current Phase 0 file already contains.
1. v1 reference implementation (port from it — it held up):
   - `git show obs-backend-wip:addons/GdTimeMachine/vendor/obs_client.gd`
   - `git show obs-backend-wip:test/unit/test_obs_client.gd` — its `FakeWebSocketPeer` + `FakeOBSClient` seam pattern is the test template.

## Current Phase 0 file (extend, don't regress)

`vendor/obs_client.gd` today: `@tool extends Node class_name OBSClient`, the auth constants (`DEFAULT_HOST/PORT`, `SUBPROTOCOL`, `RPC_VERSION`, `CLOSE_CODE_AUTH_FAILED`), `_password/_host/_port`, a plumbing-only `connect_to_obs()` that validates the port and stores `_password`, and the **pinned** `static _generate_auth` + `NOTICE.txt` attribution.

Constraints on the existing surface:

- **Do NOT change `_generate_auth`** or its signature — `test_obs_client.gd` pins it to an independent Python reference vector (hard regression lock).
- `connect_to_obs(host, port, password)` MUST keep storing `_password` (and `_host`/`_port`) and keep the out-of-range port → `ERR_INVALID_PARAMETER` behavior — the two Phase 0 plumbing tests assert both. Replace the "Phase 0 records the target + password" docstring with the real contract.
- `OBSClient` stays a `@tool` `Node`, `_password`/`_host`/`_port` stay as-is.

## Spec (plan §4, authoritative)

- **State machine:** `DISCONNECTED → CONNECTING → AWAITING_HELLO → AWAITING_IDENTIFIED → READY → CLOSING`; poll every `_process` (no throttle).
- **Handshake:** `connect_to_obs` creates the peer via the `_create_websocket_peer()` seam, `connect_to_url("ws://host:port")` with `SUBPROTOCOL`, arms the connect deadline (`CONNECT_TIMEOUT = 5.0`), `set_process(true)`. `_handle_hello` reads `d.authentication.{salt,challenge}`:
  - password **empty** (or no challenge present) → send Identify with NO `authentication` field (server auth disabled connects; server auth enabled closes 4009 → surfaced later by the backend);
  - password **non-empty** + challenge present → include `_generate_auth(password, salt, challenge)`.
  - Always send `rpcVersion: 1` + `eventSubscriptions` (plan's `EVENT_SUBSCRIPTIONS` bitmask from v1).
- **Requests:** `send_request(requestType, requestData, requestId=auto)` → `{"op":6,...}`; correlate `{"op":7,...}` by `requestId` → `request_completed(request_id, result, code, response_data)`. Ops needed: `GetVersion` (probe `availableRequests`), `GetRecordStatus`, `StartRecord`, `StopRecord` (read `outputPath`), `GetSceneList`, `SetCurrentProgramScene`. Port the op/status constants (`STATUS_SUCCESS`, `STATUS_NOT_READY`, `STATUS_OUTPUT_RUNNING`, `CLOSE_CODE_UNSUPPORTED_RPC`).
- **Signals:** `connection_established`, `connection_authenticated`, `connection_closed(code, reason)`, `connection_failed(message)`, `request_completed(...)`, `event_received(...)` (+ v1's `data_received` low-level passthrough if trivial).
- **Failure classification:** port v1 `_on_socket_closed` + `_describe_connect_failure` — `4009 → "Authentication failed — OBS rejected the password (close code 4009)"`, `4010 → unsupported RPC`, timeout message from `_check_connect_timeout`.
- **Seams:** `_create_websocket_peer()` (untyped), `_now()` (monotonic), the `is_connected_to_obs()` / `get_ready_state()` accessors. **No `OS.execute`, no Thread** (`@tool`-safe).

**Do NOT port** the v1 capture-source helpers (`create_input`, `get_scene_item_list`, `get_input_kind_list`, `INPUT_KIND_*`) — that's the deferred `platform_capture.gd` flow (§1 of the plan, scope-locked OUT). Deferred: `SetRecordDirectory`, auto-close teardown, anything touching the backend/dock/plugin.

## Tests (extend `test/unit/test_obs_client.gd`)

Keep the 5 Phase 0 tests (pinned vectors + `_password` plumbing + port range) green. Add, using v1's `FakeWebSocketPeer`/`FakeOBSClient` seam pattern:

- connect happy path → `connection_established` then `connection_authenticated`;
- `_handle_hello` with challenge + non-empty password → Identify carries the computed `authentication` string;
- challenge present + **empty password** → Identify has **no** `authentication` field (the v2 rule — v1 sent a bogus one);
- no challenge → Identify has no `authentication` field;
- auth-fail close 4009 → `connection_failed("Authentication failed…")`;
- request JSON shape (`op:6`, `requestId`, `requestType`, `requestData`) + `requestId` correlation to `op:7` → `request_completed`;
- poll pumps every frame (incoming frames processed in `_process`);
- connect timeout → `connection_failed(...timed out...)` via `_now()` seam.

## Verify

- `make test-godot` (headless GUT) — must stay green (234 baseline + new client tests).
- Run the pre-commit hooks on changed files before finishing: `gdformat`, `trailing-whitespace`, `end-of-file-fixer`, `mdformat` for any notes edits.
- Do NOT commit. Update `notes/PROGRESS_obs_backend_v2.md` with a Phase 1 summary (state machine done, test delta, anything deviating from §4).
- **Cleanup:** `tools/obs_auth_probe.gd` is temporary Phase 0 tooling — delete it once the real client + fake-peer tests land (they supersede it). Keep the handshake behavior identical: empty password → no `authentication` field.

## Style / anti-goals

- Tabs, snake_case, doc comments on new members; match the existing file.
- Never suppress type errors. Fix minimally — this phase is one file + its tests. Do not refactor the Phase 0 plumbing tests.
- Do NOT touch `backend/backend_obs.gd` (that's Phase 2), `plugin.gd`, `time_machine_dock.gd`, `recorder_backend.gd`, config/controller.
- Do NOT add deferred features even if "easy" (§1 scope lock).
