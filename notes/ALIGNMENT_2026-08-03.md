# Alignment 2026-08-03 — post screenshot fork

Date: 2026-08-03 Previous: `SESSION_PLAN_engine_native_recording.md` (Op1-7) + emergency debug session `SESSION_2026-08-02_screenshot_debug.md` (archived)

## Where we are (actual)

### Shipped — engine-native track (Ops 1-5 + fixes)

- **Op1 CaptureMode** — `RecorderBackend.CaptureMode {RESTART_SCENE, IN_PLACE}`, controller forwarder, GameView button grey-out logic with pure `compute_game_view_button_state()`. SHIPPED.
- **Op2 Graceful-stop** — `autoload/graceful_stop.gd` + `editor/debugger_plugin.gd` `send_graceful_stop()` broadcast, backend funnel single-emission, grace timer 2s. Fixes AVI no-idx1 bug. SHIPPED, 66→178 green.
- **Op3 FPS spike** — measured 16-18 fps @720p fg / 1 fps bg, doc'd in archived `SPIKE_screenshot_fps.md`. GO. SHIPPED.
- **Op4 Hardening batch (#5+#6)** — format dropdown OGV/AVI/PNG, warning label, `output_format.gd` shared, restore-on-stop no `ProjectSettings.save()` pollution. metadata NO-GO verified. SHIPPED.
- **Op5 Screenshot backend core** — `backend_screenshot_capture.gd` IN_PLACE, one-in-flight loop, copy-on-receipt, manifest.json, zero-frame → stopped+notice, polling pending-start (scene picker usable while idle — Issue 1 fix from archived debug session), `recording_notice` channel, console feedback in `plugin.gd` for run-bar/game-view buttons (Issue 2 fix). SHIPPED 152 green.

### Shipped — fork fixes (2026-08-02/03 debug session, now archived)

User update at bottom of archived file confirmed "Screen recording is working!" after robustification.

- **Issue 3 root cause**: engine reply is `[id,w,h,path]` 4-field, not 2-field; `_capture` string is `game_view:get_screenshot`, not `get_screenshot`; copy race `/tmp` scr-\*.png.
- Fixes applied in that session: permissive `_capture` (StringName, int-as-string tolerant), bool `send_screenshot_request`, NO_REPLY 5→15s, `_copy_frame` stream fallback, pending-start state machine mirroring Movie Maker.
- **This session (2026-08-03 continuation)**:
  - Stripped debug `print("[GdTM] _capture...")` leaving only intentional feedback prints in `plugin.gd`.
  - Added `.gdignore` creation: `media/captures/.gdignore` tracked via `!` negation in `.gitignore` (was blocking negation before), backend + dock ensure it exists at runtime for any custom output_dir.
  - Added **JPG mode**: `GdTMOutputFormat.Format.JPG`, `to_extension=jpg`, dock `_get_allowed_formats()` — IN_PLACE → PNG/JPG, RESTART → AVI/OGV/PNG, format row now visible for both, `_repopulate_formats_for_backend()` fallback logic. Backend: `_image_format` from config, `frame_%05d.{ext}`, `_copy_frame` decodes PNG → `save_jpg(0.85)` with fallback copy. `debugger_plugin.gd` fast/fallback paths accept `.jpg/.jpeg`.
  - Added **1px scrub**: `MIN_FRAME_DIMENSION=8`, drops placeholder 1x1 first-frame stub, immediately issues next request so loop doesn't stall.

Result: **178/178 GUT green**, editor no longer tries to import captures.

### Not shipped

From `SESSION_PLAN_engine_native_recording.md`:

- **Op6 #4a ffmpeg auto-convert** — the tier-2 hook (BRAINSTORM_tier2_ffmpeg_exports). Design exists fully in that file + `BRAINSTORM_tier2_ffmpeg_exports.md`. Not built. This is what stitches `*.frames/` into video.
- **Op7 nice-to-haves** — shortcut, status-bar elapsed, tooltip semantics per backend.

From `IMPLEMENTATION_PLAN.md` original:

- **Phase 3/4 OBS backend** — vendor `obs-websocket-gd`, `backend_obs.gd`, platform capture. Fully specced in `RESEARCH.md` but no code. This is the long-term primary IN_PLACE answer (real-time + audio).
- **Phase 5 polish** already partially done (format dropdown, restore-on-stop). Transcode sketch absorbed into Op6 tier-2.

From `ENHANCEMENT_CLI_COMPANION.md`:

- CLI companion + batch manifest UI — core differentiator, intentionally deferred.

## Fork impact assessment

We diverged from `SESSION_PLAN` after Op5 to fix production bugs (pending-start + zero frames). This was correct — Op5 was green on unit but broken in integration. The fork:

- Made IN_PLACE UX consistent with RESTART (scene picker launch) — now matches plan intent, removes inconsistency.
- Added JPG as output_format — extends Op4's dropdown rather than contradicting it; tier-2 model still holds (tier-1 for screenshot is now PNG/JPG, not just PNG).
- Gdignore fix is orthogonal, no plan conflict.

No rework needed for prior Ops.

## Proposed next line (pick one)

### A. Op6 — ffmpeg tier-2 converter (RECOMMENDED next, 4-6h)

**Why:** User explicitly noted "JPGs are quite large for something we're going to be stitching into a video. Caveat: Frame 1's png is a single pixel" — they want video output. Screenshot backend currently only produces frames dir + manifest. Without Op6, user must manual `ffmpeg -framerate X -i frame_%05d.jpg out.mp4`.

**Scope (from BRAINSTORM_tier2 + ENHANCEMENTS 4a):**

- New `backend/ffmpeg_convert.gd` — probe `ffmpeg -version` (setting `ffmpeg_path` overrides PATH), codec map (format dropdown → args: AVI→mjpeg, OGV→libtheora -an for now, MP4→libx264 crf 18, PNG→no-op), quality from `editor/movie_writer/video_quality`, framerate from manifest measured avg (not target).
- `Thread` + blocking `OS.execute` stderr capture, `call_deferred` back, `recording_converted(backend_name, clip_path)` on base + controller forwarder, frames cleanup on success.
- Dock: "Converting…" status between stopped→converted, auto-convert toggle, ffmpeg-path row, graceful "ffmpeg not found — frames kept" (not error).
- Thread lifecycle `wait_to_finish()` before free.
- Add MP4 to `GdTMOutputFormat` as tier-2 target (dropdown shows native vs converted — "Converted (ffmpeg)" suffix internal? User-facing still simple).

**Depends on:** Op5 (done). Value: any backend (Movie Maker AVI→MP4 avoids 4GB cap anxiety, screenshot JPG/PNG→MP4).

**Acceptance:**

- probe-present → converted clip + frames cleaned; probe-missing → frames kept + status notice; nonzero exit → frames kept + error tail.
- Manifest's `_get_image_dimensions` + MIN scrub already done, so first frame won't poison concat.

### B. OBS backend (Phase 3/4, 6-10h)

**Why:** Real-time + audio, the product answer for "record running scene". Engine-native screenshot is dev-quality (~15 fps, no audio). OBS is what docs recommend.

**Scope:** vendor `you-win/obs-websocket-gd`, `backend_obs.gd` IN_PLACE, platform capture helpers, needs_setup() guided Wayland flow, auto-detect, dock selector.

**Tradeoff:** Higher complexity, OBS dependency, but obsoletes screenshot for many users. Can be parallel with Op6 (one dev on each).

### C. Polish + docs (Op7, 2-3h)

Record/stop shortcut, status-bar elapsed, semantics tooltip (fixed-fps vs real-time), README sync for new JPG + .gdignore behavior.

### D. CLI companion (9-11h)

Batch manifest JSON schema + dock export UI + Python `gdclip-cli`. Core differentiator but only useful once backends are video-producing (needs Op6 for screenshot).

## Recommended order

**Op6 (ffmpeg) → Op7 polish → OBS or CLI — decide based on user priority.**

Rationale: Op6 closes the loop for the backend we just fixed, gives JPG→MP4 stitching the user asked for, and is backend-agnostic (also gives Movie Maker MP4). OBS is bigger and decoupled. CLI wants Op6 done.

## Housekeeping done this session

- `notes/archive/` created, 10 completed notes moved.
- Remaining in `notes/`: 6 active docs (see header). `IMPLEMENTATION_PLAN.md` and `RESEARCH.md` still contain useful reference but reference pre-Op1 architecture — consider moving `RESEARCH.md` to archive after Op6 decision (its Phase 0-2 already shipped).
- `media/captures/.gdignore` now tracked.
- `.gitignore` fixed for negation.

## Open questions for user

1. Op6 as next? If yes, should MP4 be default converted target for screenshot, or keep PNG/JPG frames as primary with opt-in convert?
1. Should frames dir be deleted after successful convert, or kept? (Current 4a spec says clean on success).
1. OBS next after Op6, or CLI companion?
