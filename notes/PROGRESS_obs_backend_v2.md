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

## Next actions

1. `make test-godot` — must stay green (224 baseline + new Phase 0 tests).
1. Review Phase 0 evidence with the user. Real-OBS matrix (correct/wrong/none password) is theirs; then Phase 1 (client port).
