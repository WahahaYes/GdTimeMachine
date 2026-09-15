# Plan: programmatic OBS capture (Linux x11 primary, Windows equivalent)

Scope: Linux + Windows only. macOS explicitly unsupported (backend unavailable with reason). PipeWire portal flow stays as a SINGLE fallback tier: programmatic → PipeWire → hard error. No chains, no retries across tiers, no new settings.

Background: `notes/OBS_CAPTURE_TARGET_RESEARCH.md` (bug, evidence, per-OS matrix). This note is the implementation plan.

## Target design (Record path, `_begin_recording`)

```
ensure OBS reachable (existing)
  → request game window identity over debugger (new, ~3 s timeout)
  → resolve platform spec:
       Linux + display==X11 + handle!=0 + kind xcomposite_input present
         → ensure xcomposite input in target scene, Set capture_window=id
       Windows + exe/title present + kind window_capture present
         → ensure window_capture input, Set window="[exe]: title" (UNVALIDATED)
       else → PipeWire fallback (existing code, untouched) → StartRecord
  → SetCurrentProgramScene(target) → StartRecord
```

Rules that keep it cascade-free:

- Exactly ONE branch point. Each branch ends in StartRecord or recording_error. The PipeWire branch never re-enters programmatic code.
- The programmatic branch fully verifies before touching StartRecord (kind present AND identity complete); anything missing goes to fallback, never to a half-configured record.
- No new EditorSettings. No polling loops added (one bounded wait already exists inside PipeWire fallback; the identity request has its own 3 s timeout).

## Game → editor identity protocol (new)

- Autoload (`autoload/graceful_stop.gd`): on `rq_window_handle [rq_id]`, reply `EngineDebugger.send_message("gd_time_machine:window_handle", [rq_id, handle, display, exe, title_guess])` guarded by `EngineDebugger.is_active()`, where:
  - `handle` = `DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, DisplayServer.MAIN_WINDOW_ID)` (0 when unsupported)
  - `display` = `DisplayServer.get_name()` ("X11", "Windows", "Wayland", …)
  - `exe` = `OS.get_executable_path().get_file()`
  - `title_guess` = project `application/config/name` (exact title is NOT queryable — no `window_get_title` exists; Windows suffix risk documented)
- Editor (`editor/debugger_plugin.gd`): route `gd_time_machine:window_handle` in `_capture` (outside the screenshot gate), emit `window_handle_received(rq_id, handle, display, exe, title)`; add `send_window_handle_request(rq_id)` mirroring `send_screenshot_request` (first live session + session-0 fallback).
- Backend (`backend_obs.gd`): `_request_game_window_identity()` awaits the signal with rq-id match on the wall clock (3 s), then disconnects. Test seam: override in the RecordingBackend double with canned dicts (same pattern as existing `_get_setup_wait_timeout` seam).

## Backend changes (`backend_obs.gd`)

- ADD: `_debugger_plugin: Object` member (mirror movie maker); `_next_win_rq_id`.
- ADD: `_get_os_name()` seam (`OS.get_name()`; tests pin "macOS"/"Windows").
- `is_available()`: false with reason outside Linux/Windows.
- ADD: `_platform_capture_spec(identity, kinds)` pure-ish (no OBS I/O): returns `{kind, settings}` or `{error}`. Linux/X11/handle → xcomposite + `{"capture_window": "%d\r\n\r\n" % handle}`; Windows/exe/title → ...[truncated 3881 chars]
