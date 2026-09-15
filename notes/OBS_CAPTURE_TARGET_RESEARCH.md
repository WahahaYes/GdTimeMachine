# OBS capture-target bug: research + proposed fix

> Follow-up: `notes/OBS_PROGRAMMATIC_CAPTURE_PLAN.md` turns this research into the two-tier build (programmatic primary, single PipeWire fallback). The research below stands as the evidence.

Date: 2026-09-08. Status: implemented 2026-09-15 (two-tier Record in `_begin_recording`, committed).

## The bug

OBS recordings capture the wrong content: VSCode (behind the game) instead of the game window, or a frozen "last frame". Two distinct mechanisms found:

1. **Wrong share target.** The PipeWire portal share pointed at a monitor (or the wrong window). Live probe of this machine (2026-09-07/08) showed the `GdTimeMachine` scene holding **two** same-named `GdTimeMachine Capture` inputs (`pipewire-screen-capture-source`), each 1920x1080 (full-monitor sized) with a saved `RestoreToken`. Every Record captured the whole monitor — frontmost window wins, which was VSCode. Auto-setup had stacked the duplicate instead of reusing (fixed: input reuse + twin healing in `_auto_setup_record_scene` / `_heal_own_scene_duplicates`, `backend_obs.gd`).
1. **Frozen frame.** When a saved portal share goes stale (target window gone, token invalidated), the source keeps rendering its last buffers. OBS cannot tell us the share is dead — the token is opaque.

Related pre-existing defects already fixed on the way here (all in `backend_obs.gd` + `time_machine_dock.gd` + `recorder_controller.gd`, all covered by GUT tests, suite green 2026-09-08):

- Empty OBS scene recorded black video of correct length with no complaint → fail-fast preflight (`_check_record_scene_ready`) + auto-setup on Record.
- Auto-setup created a scene+source but the human still had to complete the portal picker → wait-for-`RestoreToken` loop, `OpenInputPropertiesDialog` parking, setup gear dialog (`ObsSetupDialog`) with status / auto-setup toggle / set-up-now / **re-pick** (`repick_capture_target` clears the token and re-opens the picker — the current wrong-window remedy).

## Research: can we assign the target at Record time?

Question asked: can the preflight accurately assign EITHER the entire desktop OR a specific app when recording starts?

### Native Wayland + PipeWire: NO to both (verified)

- The portal `SelectSources` API takes only `types` (monitor/window), `multiple`, `cursor_mode`, `restore_token`, `persist_mode`. There is no "capture this window" parameter. ([portal docs](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html))
- OBS's `screencast-portal.c` confirms the input settings are ONLY `ShowCursor` + `RestoreToken` — the window/monitor choice lives entirely inside the portal session.
- The exact feature request exists upstream and is still open: [xdg-desktop-portal#1064](https://github.com/flatpak/xdg-desktop-portal/issues/1064) ("request windows by name or process"). Even the compromise (filter the picker list) doesn't exist.
- Consequences: first pick is always human; the token is opaque, single-use-rotating, and silently falls back to the dialog when the target is gone. A trayed/auto-launched OBS never gets that dialog completed.

### X11 window capture: YES to specific app (validated live, 2026-09-08)

- OBS `xcomposite_input` takes a `capture_window` setting (`"<winid>\r\n<title>\r\n<class>"`) via `SetInputSettings` — no dialog, ever. Precedent: `obs.call('CreateInput', {inputKind: 'xcomposite_input', inputSettings: {capture_window: '\r\nCounter-Strike 2\r\ncs2'}})`.
- Validated end-to-end on this machine: portable OBS under `QT_QPA_PLATFORM=xcb` registers `xcomposite_input`; created the input, set `capture_window` to the running game's window id, and `SaveSourceScreenshot` returned the **live game frame** (1152x648, real pixels). OBS log resolved `title: GdTimeMachine (DEBUG)`, `class: Godot_Engine` from the id.
- The game is X11: `"GdTimeMachine (DEBUG)": ("Godot_Engine" "GdTimeMachine")` in the X tree. (Godot 4 defaults to the X11 display driver on Linux.)
- Match by **window id**, not title: the `(DEBUG)` suffix differs between debug/release builds. Id source without external tools: extend the game-side autoload (`autoload/graceful_stop.gd` already lives in the game process) to report `DisplayServer.window_get_native_handle()` over the debugger channel. Returns unusable on Wayland → fall back to PipeWire.
- Hazard found: enumerating the window list via `GetInputPropertiesListPropertyItems(capture_window)` **crashed** portable OBS here (null-named window in the tree). Never enumerate — set the id directly, which bypasses the enumeration path.

### Entire desktop at runtime: NO clean option anywhere

- Native Wayland: picker mandatory first time (see above).
- XWayland `xshm_input`: absent from this OBS build's kind list, and under a rootless XWayland it only sees X11 windows anyway — not the whole desktop.
- (`xdg-desktop-portal-wlr` `chooser_type=none` can hardcode an output, but that's wlroots-only; this project targets GNOME. GNOME Shell's private `Screencast` D-Bus API records a monitor rect without consent, but it's a fixed rect, fixed encoding, no follow — documented here only as a last-resort note, not proposed.)

### Cross-OS compatibility of "replace PipeWire with X11"

X11 capture is **Linux-only**. Per-OS programmatic story:

| OS | Window (specific app) | Monitor (desktop) | Notes | |----|----------------------|-------------------|-------| | Linux X11 session | `xcomposite_input` + `capture_window` id — validated | `xshm_input` (kind absent in this build; verify per build) | No dialogs. Game must be X11 (Godot default). | | Linux Wayland session | Same, with OBS under `QT_QPA_PLATFORM=xcb` + X11 game — validated | Same caveat as above | PipeWire flow stays as fallback (Wayland-native game, or xcb impossible). | | Windows | `window_capture`/`game_capture` `window` string — settable, no dialog | `monitor_capture`/`dxgi` — settable | Same architecture, different kinds. Not yet validated. | | macOS | ScreenCaptureKit `window`/`application` ids — settable after one-time OS Screen Recording permission | display capture — same permission | Window-id discovery needs work (ids are dynamic). Not yet validated. |

So: X11 wipes out PipeWire **on Linux only**, and only when both OBS (xcb flag) and the game (X11 driver) cooperate — detection + fallback required. Windows/macOS keep their own programmatic kinds; PipeWire remains the Linux fallback, never the default when xcomposite is available.

## Proposed fix (implemented 2026-09-15 — summary, see code)

1. Game-side autoload reports `DisplayServer.window_get_native_handle()` (+ a Wayland/X11 flag) over the debugger channel on request, with timeout.
1. Preflight/Record path: if OBS exposes `xcomposite_input` (Linux) and the game reports a nonzero X11 handle → `SetInputSettings capture_window` (`"<id>\r\n\r\n"`) on the record input, then `StartRecord`. No picker.
1. Per-OS kind table (`xcomposite_input` / `window_capture` / ScreenCapture kinds) with the same "resolve handle → set → record" shape; PipeWire flow (auto-setup + re-pick dialog) stays as fallback.
1. Auto-launch gains `QT_QPA_PLATFORM=xcb` (Linux, gated behind a setting) so the kind is registered.
1. Never call `GetInputPropertiesListPropertyItems` on xcomposite kinds (crash, see above).

## Validation performed

- `GetInputKindList` on xcb OBS: `xcomposite_input` present.
- `SetInputSettings(capture_window=<game xid>)` → log resolves title/class → `SaveSourceScreenshot` returns live 1152x648 game pixels.
- All 14 obs-websocket request types the flows use verified present on the project's OBS 32.1 / websocket 5.7.2 (`RemoveSceneItem`, `SetSceneItemEnabled`, `SetInputSettings` included).
- GUT suite green at implementation time (covers preflight, auto-setup, dedupe/heal, re-pick, summary, dialog, controller guards). Live E2E 2026-09-15: real `BackendOBS.start()` recorded the live smoke scene (`media/captures/live_backend_e2e.mp4`, 1280×720, hue-cycling frames).

## Open questions

- Exact `convert_encoded_window_id` id format (decimal xid worked; hex untested — keep decimal).
- Godot window class element for title-based fallback (`Godot_Engine` vs project name) — moot if id path works, needed only as fallback.
- Windows/macOS kind names + handle discovery — unvalidated.
- Whether to keep auto-creating the PipeWire scene when xcomposite wins (proposal: no — create `xcomposite_input` in the `GdTimeMachine` scene instead, same scene name, no portal involved).
