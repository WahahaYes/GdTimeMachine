# Session 2026-08-02: Screenshot backend debugging + lingering UX fixes

Date: 2026-08-02 ~22:00 Starting doc: notes/last_session_lingering_issues.md (3 items)

- Issue 1: screenshot mode can't open scene on Record (scene picker hidden)
- Issue 2: no feedback on run-bar / game-view record buttons
- Issue 3: folder+manifest but 0 screenshots (real bug, unit green but integration failing)

## What we completed

### Issue 2: console feedback for toolbar buttons - FIXED & VERIFIED green

File: `addons/GdTimeMachine/plugin.gd`

Added `_connect_controller_feedback()` called in `_enter_tree`, `_disconnect_controller_feedback()` in `_exit_tree`:

- `recording_started` -> `print("[GdTM] %s recording -> %s")`
- `recording_stopped` -> `print("[GdTM] %s stopped: %s")`
- `recording_error` -> `push_warning("[GdTM] %s error: %s")`
- `recording_notice` -> `print("[GdTM] %s: %s")` mirrors dock status line stats/hints

This is addon-level, not wired to buttons, so users using run-bar/game-view see Output even when dock closed. Decision per user suggestion.

### Issue 1 (partial): scene picker launch for screenshot - IMPLEMENTED

Files:

- `addons/GdTimeMachine/backend/backend_screenshot_capture.gd` - full pending-start state machine added (mirrors MovieMaker):

  - const `POLL_INTERVAL = 0.5`
  - vars `_pending_start: bool`, `_poll_timer: Timer`
  - `start()` now:
    - if playing -> `_begin_capture()` immediate (old path)
    - if not playing -> makes `.frames` dir, calls `_play_scene(scene_path)` (new shim: `play_current_scene` / `play_custom_scene`), starts poll timer + duration timer if set, sets `_pending_start=true`, waits
  - `_begin_capture()` extracted: claims game_view prefix, connects signal, starts pacing/no-reply/duration timers, stops poll, emits recording_started, sends first request
  - `_on_poll_timeout()` -> if pending and `is_playing_scene()` -> `_begin_capture()`
  - `_on_duration_timeout()` if pending -> error "Scene did not start..."
  - `stop()` while pending -> cancels, emits stopped+notice
  - All receive/send paths bail if pending

- `addons/GdTimeMachine/ui/time_machine_dock.gd`:

  - `_update_backend_visibility()` — scene row ALWAYS visible now (per request: "only used when not active"), format row still hidden for IN_PLACE until ffmpeg Op6.

Tests:

- `FakeScreenshotBackend` gained `poll_starts/stops`, `played_scenes`, overrides for `_play_scene`, `_start_polling/_stop_polling`
- Updated `test_start_without_running_scene_emits_error` -> now expects launch+pending
- New: `test_pending_start_launches_scene_and_waits`, `test_poll_transitions_to_recording_when_scene_starts`, `test_duration_expiry_while_pending_emits_error`, `test_stop_while_pending_cancels_and_finalizes`
- `test_time_machine_dock.gd`: `test_in_place_backend_hides_scene_and_format_rows` now expects scene visible, format hidden

Status: code green 171 tests, editor parse error fixed.

### Issue 3: 0 screenshots — ROOT CAUSE INVESTIGATION IN PROGRESS (not yet fixed in production)

#### What we learned (critical correction)

Earlier claim that engine replies `[path, size]` was WRONG per actual source verification (websearch web_search_exa):

`scene/debugger/scene_debugger.cpp: _msg_rq_screenshot`:

```
Array arr;
arr.append(p_args[0]);           // id we sent
arr.append(img->get_width());
arr.append(img->get_height());
arr.append(path);                // OS temp scr-*.png
send_message("game_view:get_screenshot", arr);
```

So reply is 4-field `[id, w, h, path]`, NOT 2-field. Initial fix that assumed legacy 2-field was misdirection.

GameViewDebugger in `editor/run/game_view_plugin.cpp`:

- `has_capture("game_view")` -> true when it owns prefix
- `capture(p_message="game_view:get_screenshot", data)` -> `_msg_get_screenshot(data)` checks size==4, looks up `screenshot_callbacks[id]`, calls callback if exists, erases, returns true even if id not found.

`EditorDebuggerNode::plugins_capture()`:

```
for plugin in debugger_plugins:
  if has_capture(cap):
    parsed |= capture(message, data, session_index)
```

So it ORs results — our plugin should still get chance even if GameViewDebugger returns true first, UNLESS engine stops after first? Websearch said it continues. But competition still possible.

#### What we changed trying to fix 0 frames

**debugger_plugin.gd** — made `_capture` ultra-permissive:

- Now accepts both `get_screenshot` and `game_view:get_screenshot` (docs: EditorDebuggerPlugin receives full "prefix:payload", so actual string is `game_view:get_screenshot`; earlier code checked only `get_screenshot` and returned false)
- Fast path for exact [id,w,h,path] where last elem .png
- Fallback scan: any string containing .png or /scr- /tmp => path, numeric scan for id/w/h including StringName handling, is_valid_int/float string parsing
- `_last_screenshot_rq_id` stored on send, used fallback
- Added temporary prints `[GdTM] _capture ...` which later removed
- `_send_screenshot_request()` now returns bool -> true if sent to active session, false if no session yet (handshake race)
- `send_focus_request()` unchanged

**backend_screenshot_capture.gd** robustification:

- `NO_REPLY_TIMEOUT` 5s -> 15s (covers slow first PNG encode)
- `_send_screenshot_request(rq_id) -> bool` (seam returns bool; test double returns true now)
- `_send_next_request()` returns early if send bool false, restarts no-reply timer to avoid timeout during handshake; sets in_flight only after successful send
- `_begin_capture()` now also `_stop_polling()` (cleanup)
- `_copy_frame(src,dst)`:
  - old: `DirAccess.copy_absolute(globalized_src, dst)` single try
  - new: try globalized src->dst, then raw src->globalized dst, then stream fallback `FileAccess.open READ -> WRITE store_buffer`. Fixes cross-device /tmp -> res:// copy failures (we saw /tmp scr-\*.png files lingering).
- `_on_screenshot_received`:
  - old: strict `if in_flight==-1 return`, `if rq_id != in_flight and w!=0 return`
  - new intermediate debug version: accepted even when in_flight==-1 (handshake race), logged everything. Final version stripped prints but keeps permissive.

**Test fixes:**

- `test_backend_screenshot_capture.gd`: `_send_screenshot_request` signature changed `-> void` to `-> bool` — this was the editor parse error blocking `make launch-editor` (`SCRIPT ERROR: Parse Error: The function signature doesn't match the parent. Parent signature is "_send_screenshot_request(int) -> bool". at test_backend_screenshot_capture.gd:45`). Fixed, then 3 tests failed due to no_reply restarts / request counts altered by auto-retry. Fixed by relaxing asserts and updating expected timeout 5->15.

#### Current blocker: STILL reproducing "No frames captured"

User reports still seeing folder+manifest but no frames after all above changes. Logs not captured yet because editor was blocked by parse error right at close.

Hypotheses remaining (to check next session):

1. **Session not ready race**: After `play_custom_scene`, `get_sessions()` may be empty for some frames until debugger handshake completes. Our code now retries, but if `_no_reply_timer` 15s expires before handshake, we finalize with 0 frames. The pacing timer should keep retrying; need to verify pacing timer actually started in pending->capture transition (yes) and continues.

1. **has_capture competition**: When we claim `game_view`, we shadow GameViewDebugger's preview (documented tradeoff). But if GameViewDebugger is still registered, both have `has_capture("game_view")`. Order of plugins in `debugger_plugins` list may matter. If editor calls our `_capture` AFTER GameViewDebugger, and GameViewDebugger's `_msg_get_screenshot` returns true even when callback missing, does editor still call ours? `parsed |=` suggests yes (OR). Need to verify by adding temporary print in both paths during live editor run.

1. **Message string mismatch still?**: Docs say `_capture` receives full "game_view:get_screenshot". We now accept suffix `get_screenshot`, so should match. But maybe session_id matters? We ignore it.

1. **Copy still failing**: `/tmp` scr-\*.png files seen in `/tmp` leftover from previous runs, indicating copy never succeeded. New stream fallback should fix, but need to confirm FileAccess can read OS temp path (permissions). Could need `ProjectSettings.globalize_path` for dst but src as-is — we do both.

#### Next steps checklist for resume

- [ ] Remove any remaining debug prints (we stripped most, verify debugger_plugin.gd has no prints now — currently clean)
- [ ] Re-run `make launch-editor`, enable Screenshot backend, open `test/manual/recording_smoke.tscn`, Record with game window focused, watch Output for `[GdTM]` lines. If none, `_capture` never called.
- [ ] Add diagnostic button in dock temporarily: show `get_sessions().size()` and `is_active()` state
- [ ] If `_capture` called but copy fails, check `FileAccess.open(src)` returns null due to sandbox? Try `OS.execute("cp", ...)` fallback or `DirAccess.copy_absolute(src, dst)` with src already absolute.
- [ ] Verify `backend_screenshot_capture.gd` pacing continues after handshake: log `_send_next_request` return false count vs no-reply expiry.
- [ ] Consider claiming `game_view` EARLIER: currently claimed at `_begin_capture()` (after poll). If game screenshot arrives before we claim, we miss it. But we wait for playing anyway. Could claim before `_play_scene()` to catch early replies? No, need session.
- [ ] Potential fix: don't claim `game_view` at all — use different prefix? No, engine only sends to `game_view` prefix, must claim it.
- [ ] As last resort, look at `GameViewDebugger.add_screenshot_callback` flow: it adds callback then sends `scene:rq_screenshot`. Our flow mirrors it. Should work.

## Files modified in this session (git diff)

- `addons/GdTimeMachine/backend/backend_screenshot_capture.gd` — major rework (pending-start + robust copy + bool send + timeout 15s)
- `addons/GdTimeMachine/editor/debugger_plugin.gd` — permissive capture + bool returns
- `addons/GdTimeMachine/ui/time_machine_dock.gd` — scene row always visible
- `addons/GdTimeMachine/plugin.gd` — feedback prints (Issue 2) — already committed earlier but check diff
- `test/unit/test_backend_screenshot_capture.gd` — signature fix + test adjustments
- `test/unit/test_time_machine_dock.gd` — visibility test updated

Parse error fixed at close: `_send_screenshot_request(int)->void` vs `->bool` mismatch.

Unit: 171/171 green after fixes (was 171 before, 140 filtered).

## How to resume

1. `make launch-editor` — should now load without parse error (verify)
1. Enable GdTimeMachine, select Screenshot backend
1. Open `test/manual/recording_smoke.tscn`, press Record (should launch scene now per Issue 1 fix)
1. Observe Output — should see our `[GdTM]` diagnostics if still present, or check manifest + frames dir inside `media/captures/...frames/`
1. If still 0 frames, add back minimal logging in `debugger_plugin.gd::_capture` and `backend_screenshot_capture.gd::_send_next_request` and `_on_screenshot_received`, capture log, then strip.

## Editor error that blocked close

```
SCRIPT ERROR: Parse Error: The function signature doesn't match the parent. Parent signature is "_send_screenshot_request(int) -> bool".
  at: GDScript::reload (res://test/unit/test_backend_screenshot_capture.gd:45)
```

Fixed by changing fake override to `-> bool` return true.

# User Update

Screen recording is working!

However, on scene close the editor attempts to import all the produced PNGs. We should add a .gdignore to the captures dir.

Is it possible to add a jpg mode to our screenshot backend? PNGs are quite large files for something we're going to be stitching into a video.

Caveat for stitching together: Frame 1's png is a single pixel, so we'll need some error handling / scrubbing frames that aren't the proper size.

On next session, let's clean up the debug outputs, and align on these improvements.
