# Progress — OBS Backend v2, Phase 0 (auth gate, code-side)

Date: 2026-08-14. Branch: `obs-backend-v2`. Working: Phase 0 only — every Phase-0 position here is evidence, not code.

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

## Next actions

1. `make test-godot` — green (248 baseline + new client tests).
1. Review Phase 1 with the user, then Phase 2 (`backend/backend_obs.gd` — plan §5) once approved. Real-OBS matrix remains the user's manual check.
