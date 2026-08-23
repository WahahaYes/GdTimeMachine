# Test Suite Rewrite Specification

**Context**: Current suite (265 tests) works but suffers from async deadlocks, flaky timing, and maintenance burden. This spec defines what a clean rewrite should cover.

______________________________________________________________________

## Addon Overview

GdTimeMachine is a Godot editor plugin for gameplay recording with multiple backends:

- **Movie Maker** (restart-scene, native AVI/OGV/PNG, tier-2 MP4/WebM via ffmpeg)
- **Screenshot Capture** (in-place, real-time PNG/JPG capture via debugger)
- **OBS Studio** (in-place, WebSocket 5.x, auto-launch, orphan reaping, auth)
- **Debugger Plugin** (screenshot protocol: `game_view:get_screenshot`, legacy replies)

Shared infrastructure: Config system (EditorSettings > ProjectSettings), RecorderController (backend registry + signal routing), Dock UI (backend selection, format filtering, install dialog).

______________________________________________________________________

## Test Philosophy

| Principle | Rationale | |-----------|-----------| | **No async in tests** | Use sync fakes; `call_deferred`/`process_frame` cause GUT deadlocks | | **Test behavior, not internals** | Assert signals/emissions, not private fields | | **No verbatim string pins** | Use `contains()`, enums, constants — copy changes shouldn't break CI | | **No redundant twins** | One test per behavior; shared fixtures over copy-paste | | **Deterministic time** | Fake clocks (`_now`/`_sleep` seams), no `await wait_seconds` | | **Isolated per file** | Each test file runnable standalone; no cross-file state |

______________________________________________________________________

## Subsystems to Test

### 1. Config System (`config/`)

- **EditorSettingsStore**: Reads EditorSettings, falls back to defaults
- **ProjectLocalStore**: Scene-scoped profiles, `[default]` section, `get_all_scene_paths`
- **CompositeStore**: Precedence (scene > local default > editor default), write-through
- **Seams**: `FakeEditorSettings` injection, `ConfigFile` loader/saver overrides

### 2. Output Formats (`output_format.gd`)

- Enum ↔ extension ↔ display_name roundtrips
- Case-insensitive parsing, unknown → AVI fallback
- `RecordingProfile` serialization

### 3. RecorderController (`controller/`)

- Backend registration (null/empty/duplicate handling)
- Selection + `backend_availability_changed` forwarding
- `start_recording`/`stop_recording` routing config to active backend
- Signal forwarding: `recording_started/stopped/error/notice/converted`
- Capture mode propagation (IN_PLACE vs RESTART_SCENE)

### 4. Backend Base Contract (`backend/recorder_backend.gd`)

- Abstract defaults: name, description, capture mode, native formats
- `is_available()` / `is_recording()` defaults

### 5. Movie Maker Backend (`backend/backend_movie_maker.gd`)

- **Two-axis availability**: `is_available()` (probe cache) vs `is_obs_installed()` (binary)
- **Start flow**: format guard (MP4/WebM only) → pending-start (scene poll) → `_begin_recording`
- **Stop flow**: graceful `StopRecord` → fallback timer → single `recording_stopped`
- **File move**: `_resolve_and_move_output` with bare-name fallback
- **AVI size guard**: 4 GB cap → graceful stop + notice
- **Tier-2 conversion**: MP4/WebM → ffmpeg async, `recording_converted` on success
- **Snapshots**: `_prev_movie_file`/`_prev_fps` restore on stop
- **Duration watchdog**: error if scene never starts

### 6. Screenshot Capture Backend (`backend/backend_screenshot_capture.gd`)

- In-place capture, debugger protocol
- Frame copy on `screenshot_received` signal
- Request retry on deny (no rq_id consumption)
- Stats notice composition (frames, fps, duration)

### 7. FFmpeg Convert (`backend/ffmpeg_convert.gd`)

- Binary probe (`ffmpeg -version`)
- Command builder: codec map per format, quality→CRF, measured fps
- Sync + async paths, success/error/not-found signals
- PNG/JPG native skip, tier-2 only

### 8. OBS Client (`vendor/obs_client.gd`)

- **Auth**: `_generate_auth` (3 reference vectors + UTF-8), empty password → no auth field
- **State machine**: DISCONNECTED → CONNECTING → AWAIT_HELLO → AWAIT_IDENTIFIED → READY
- **Handshake**: challenge+salt, Identify with `rpcVersion=1` + subscriptions
- **Request/response**: op 6/7 correlation by `requestId`, unknown ID drop
- **Events**: op 5 → `event_received`
- **Failure classification**: 4009→auth, 4010→unsupported RPC, 1006→reach, timeout
- **Seams**: `_create_websocket_peer`, `_now`, `is_connected_to_obs`

### 9. OBS Backend (`backend/backend_obs.gd`)

- **Two-axis availability**: probe cache vs binary resolve (cached)
- **Auto-launch**: `--minimize-to-tray`, 10s poll, kill own PID on timeout
- **Orphan lifecycle (D1-D4)**:
  - Launch ledger (`user://gdtime_obs_launched.cfg`)
  - Startup sweep: TERM → 2s grace → SIGKILL, ownership via `/proc/<pid>/cmdline`
  - `_kill_process_and_wait` escalation
  - Fast-path reuse notice
- **Start**: install gate → reachability → pending-start → `_connect_obs_with_timeout` → `SetCurrentProgramScene` → `StartRecord`
- **Stop**: `StopRecord` → `outputPath` → file move → `_finalize_stopped`
- **Error surfacing**: `_last_connect_error` + `_describe_start_error` (4009→password hint)

### 10. Debugger Plugin (`editor/debugger_plugin.gd`)

- Contract methods: `_has_capture`, `_capture`, `_setup_session`, `send_*`
- `_capture`: `game_view:` prefix, string-coerced ids, `.png/.jpg/.jpeg`, legacy `[path, size]` fallback
- `send_screenshot_request` → first active session → fallback session 0
- `send_graceful_stop` / `send_focus_request` broadcast/fallback

### 11. Dock UI (`ui/time_machine_dock.gd`)

- **Backend dropdown**: metadata-based identity, availability suffix (`" — not available"`), tooltip with host:port
- **Live availability**: `backend_availability_changed` → re-mark, fast-path reuse notice
- **Format dropdown**: `get_native_formats()` → MP4 only for OBS, fallback to all
- **Install dialog**: one-time, dynamic host:port, "don't show again" → `hints/dont_show_obs_hint`
- **Status line**: live timer, `recording_notice`/`recording_error`/`recording_converted`
- **Profile persistence**: `_build_profile_from_ui` uses metadata (no suffix)

### 12. Plugin Integration (`plugin.gd`)

- Backend registration order (Movie Maker default)
- EditorSettings defaults: `gd_time_machine/obs/*` + `hints/dont_show_obs_hint`
- Shortcut registration (palette key vs action name)
- Clean teardown (no "Command doesn't exist" warnings)

______________________________________________________________________

## Test Architecture Requirements

### Fake/Seam Pattern (Mandatory)

```gdscript
# Every backend/testable class exposes:
func _create_dependency() -> Dependency:  # override in tests
func _now() -> float:  # fake clock
func _sleep(seconds: float) -> void:  # advance fake clock
```

### Test File Structure

```
test/unit/
  test_config_store.gd           # config subsystem
  test_output_format.gd          # format enum/serialization
  test_recorder_controller.gd    # controller routing
  test_backend_movie_maker.gd    # Movie Maker behavior
  test_backend_screenshot_capture.gd
  test_ffmpeg_convert.gd
  test_obs_client.gd             # client unit tests
  test_backend_obs.gd            # OBS backend integration
  test_debugger_plugin.gd        # debugger protocol
  test_time_machine_dock.gd      # dock UI logic
  test_plugin_shortcut.gd        # shortcut registration
```

### Shared Fixtures (in each file)

- `FakeEditorSettings` (dict wrapper)
- `FakeOBSClient` with `sync_reply` toggle
- `RecordingBackend` / `LaunchTestBackend` / `ReapTestBackend` (in-memory seams)
- `FakeSettings` (EditorSettings/ProjectSettings dict)

______________________________________________________________________

## What to Explicitly Avoid

| Pattern | Why | |---------|-----| | `await wait_seconds()` / `await wait_frames()` | Timing flakes, GUT deadlocks | | `call_deferred` / `process_frame` in fakes | Race with `wait_for_signal` | | Verbatim string assertions | Copy edits break CI | | Duplicate tests across files | Maintenance burden | | `assert_true(true)` no-op tests | No signal value | | Proving third-party/engine behavior | Mock the boundary, not the lib | | Cross-file shared state | Test isolation required |

______________________________________________________________________

## CI Integration

- `make test-godot` runs full suite, exits 0, prints `GUT-SUITE-OK (N passing)`
- Parse-error detection via grep (`SCRIPT ERROR`, `Failed to load script`, `Parse error`)
- Pre-commit: `gdformat`, `trailing-whitespace`, `end-of-file-fixer`, `gitleaks`
- No hardcoded test file lists in Makefile

______________________________________________________________________

## Acceptance Criteria for Rewrite

1. **Full suite passes** in < 10s, 0 flakes over 5 runs
1. **All 12 subsystems** have ≥ 1 test file with ≥ 5 tests each
1. **Zero verbatim string pins** in assertions
1. **Zero async deadlocks** — all fakes synchronous or `call_deferred` with bound callables
1. **Each file runnable standalone** (`-gselect="file"`)
1. **Pre-commit passes** on all test files
1. **Total test count ≤ 200** (consolidated from current 265)

______________________________________________________________________

## Handoff Notes

- Start with config/output_format (simplest, no async)
- OBS client/backend are highest complexity — budget 40% of effort
- Dock UI tests need `FakeSettings` + `MockOBSBackend` (availability_changed)
- Debugger plugin needs `PluginBehaviorMirror` (verbatim port of real `_capture`)
- All existing seam patterns in current codebase are reusable
- Original audit notes: `notes/TEST_SUITE_AUDIT_2026-08-16.md`
- Progress log: `notes/PROGRESS_obs_backend_v2.md`
