# Screenshot-channel FPS spike — 2026-08-01

Machine: AMD RENoir integrated (Radeon), Vulkan 1.4.335 Forward+, Linux, Godot 4.7.1 monolithic Method: one-in-flight `scene:rq_screenshot` (args [rq_id]) -> `game_view:get_screenshot` [id, w, h, path], deferred to next idle frame (doesn't hog editor main loop). Measured via `GdTMScreenshotSpikePlugin` in dock, 10s window.

Scene: `test/manual/screenshot_spike.tscn` moving ColorRect 200px/s loop.

## Raw Results (interactive)

```
[screenshot_spike] window=(1152, 648) viewport=(1152.0, 648.0)
[GdTimeMachine spike] 720p: 8 frames, 1.0 fps (1000.4 ms avg, min 993.0 max 1007.0 stddev 4.8)     # editor fg, game bg — throttled
[GdTimeMachine spike] 1080p: 74 frames, 9.4 fps (106.9 ms avg, min 48.0 max 1010.0 stddev 201.2)   # mixed
[GdTimeMachine spike] 720p: 136 frames, 16.2 fps (61.9 ms avg, min 48.0 max 669.0 stddev 59.7)    # game fg, steady
[GdTimeMachine spike] 720p: 11 frames, 1.0 fps (987.2 ms avg, min 849.0 max 1008.0 stddev 44.2)   # bg again

# After attempting game-side OS.low_processor_usage_mode=false + sleep_usec=0 + max_fps=0
# (in graceful_stop.gd autoload) — did NOT fix throttling:
[screenshot_spike] window=(1152, 648) viewport=(1152.0, 648.0)
[GdTimeMachine spike] 720p: 8 frames, 1.0 fps (999.5 ms avg, min 993.0 max 1014.0 stddev 7.2)   # bg still 1fps
[GdTimeMachine spike] 720p: 143 frames, 18.0 fps (55.4 ms avg, min 48.0 max 86.0 stddev 7.1)   # fg 18fps (better, jitter lower)
```

## Interpretation

- When game window background/unfocused, engine sleeps main thread ~1000ms regardless of OS.low_processor_usage_mode=false. Verified on 4.7.1: setting bool + set_low_processor_usage_mode(false) + sleep_usec=0 + Engine.max_fps=0 did NOT prevent 1fps throttling when editor foreground. Likely DisplayServer platform layer or Wayland compositor throttles offscreen/occluded windows beyond OS setting. Decided to NOT keep OS-level hacks — revert to clean autoload and document foreground requirement.
- SceneDebugger::\_msg_rq_screenshot does viewport.get_texture().get_image().save_png(temp) on game main thread — CPU PNG encode cost scales with viewport, hence 720p > 1080p.
- First sample often includes spin-up (669/1010ms max).
- Deferred idle pacing keeps editor responsive vs tight loop.

| resolution | focused? | frames 10s | avg fps | avg ms | min/max | stddev | steady? | |------------|----------|------------|---------|--------|---------|--------|---------| | ~720p 1152x648 | yes | 136-143 | 16-18 | 55-62 | 48/86 | 7-60 | yes | | ~720p | no | 8 | 1.0 | 999.5-1000.4 | 993/1014 | 4.8-7.2 | yes throttled |

## Go/No-Go

- > 15 fps @720p -> product viable
- 10-15 fps -> dev-tool only
- \<10 fps -> defer

Result: 16-18 fps @720p foreground = low-end product viable, 9.4 fps @1080p = dev-tool, 1fps background = must be foreground. GO for Op 5 as IN_PLACE zero-dep backend scoped as dev-tool/bug-report quality.

## Foreground requirement (for Op 5 docs + tooltip)

> **Screenshot capture (in-place, zero-dep):** Game window must be visible/on-screen. When editor is in foreground and game is backgrounded/occluded, Godot throttles the game to ~1fps (1000ms sleep) regardless of low_processor_usage_mode — this is platform/window-manager behavior beyond addon control. Attempted fix via OS.low_processor_usage_mode=false + sleep usec 0 + Engine.max_fps=0 did NOT help (verified 2026-08-01, reverted). Document in backend description tooltip and BackendScreenshotCapture docs: use embedded GameView with Game tab active, or floating game window Always on Top, and keep game focused for full-rate capture.

Thread ffmpeg probe: verify via dock button if re-enabled — expects exit 0 without freeze.
