@tool
extends RecorderBackend
class_name BackendScreenshotCapture

## IN_PLACE backend that captures the running scene through the engine's
## debugger screenshot channel (scene:rq_screenshot → game_view:get_screenshot)
## on the debugger plugin (editor/debugger_plugin.gd). The game keeps running — no restart, no
## graceful quit. Received PNGs are copied into `<output_path>.frames/` on
## receipt (the game may clean up its temp files at any point) — optionally
## lossily re-encoded as JPG (config output_format "jpg") to cut storage — and
## a manifest.json records the measured statistics for the dock notice and for
## the ffmpeg converter. Frames smaller than MIN_FRAME_DIMENSION in either axis
## (e.g. the debugger channel's occasional 1×1 first-frame stub) are scrubbed.
##
## The loop paces at the configured target fps with one request in flight at
## a time; the achievable rate is machine-bound. When the game window is
## backgrounded/occluded Godot throttles it to ~1 fps — the window must stay
## visible and focused.

## State machine: idle → start() → [pending-start] → recording → stopped.
## start() normally begins capturing immediately when a scene is already
## playing (IN_PLACE). When no scene is playing, it launches the requested
## scene (scene_path from the dock) first and waits for playback to begin
## — same UX as Movie Maker — polling for is_playing_scene() before
## transitioning into recording. All stop paths — manual stop(), duration
## expiry, natural scene exit, and the no-reply timeout — converge on
## _finalize_stopped(), the single recording_stopped emission site. If the
## scene never starts before the duration elapses, recording_error is emitted
## instead (mirrors BackendMovieMaker). The no-reply timeout finalizes with
## the frames received so far; zero frames still emits recording_stopped + a
## notice — recording_error stays reserved for the no-game / never-started
## case.

## Default recording base path when the config provides no output_path; the
## frames land in "<this>.frames/".
const DEFAULT_OUTPUT_PATH := "res://media/captures/screenshot"

## Seconds between playback-state checks while pending start.
const POLL_INTERVAL := 0.5

## Seconds without any frame reply before the capture finalizes with the
## frames received so far (game hung, occluded, or crashed mid-capture).
## Restarted on every reply AND on every successful send so a slow debugger
## handshake (session not yet active at launch) doesn't trip it prematurely.
## 15s covers slow launches and first-frame PNG encode cost.
const NO_REPLY_TIMEOUT := 15.0

## Pacing fallback when the config provides no fps: ~15 fps.
const DEFAULT_FRAME_INTERVAL := 1.0 / 15.0

## A measured fps below this fraction of the target is flagged as low (the
## foreground hint fires).
const LOW_RATE_FRACTION := 0.25

## Frames smaller than this (in either dimension) are discarded as invalid
## placeholder stubs — the debugger screenshot channel occasionally returns a
## 1×1 frame on the first request. Anything below this is not a real frame.
const MIN_FRAME_DIMENSION := 8

## Whether a recording session is in progress (from start() until finalize).
var _active := false

## True after start() while waiting for playback to begin.
var _pending_start := false

## True while the capture is being closed out (stop requested, finalize
## pending).
var _stopping := false

## Where the recording is written; the frames dir is "<output_path>.frames/".
var _output_path := ""

## Full path of the frames directory.
var _frames_dir := ""

## Recording duration in seconds; 0 = record until stopped manually.
var _duration := 0.0

## Target FPS from the config (0 = unset → DEFAULT_FRAME_INTERVAL pacing).
var _target_fps := 0

## Injected by plugin.gd; hosts the screenshot request/reply channel.
var _debugger_plugin: Object = null

## Monotonic id handed to the game for the next request; replies echo it back.
var _next_rq_id := 0

## Id of the request currently awaiting a reply; -1 when none is in flight.
var _in_flight_rq_id := -1

## Frame file extension and output kind: "png" (default, straight copy) or
## "jpg" (lossy re-encode on receipt). Set from config output_format in start().
var _image_format := "png"

## Number of frames copied so far (also the next frame index, 1-based).
var _frame_count := 0

## Width/height of the last received frame (from the reply).
var _last_frame_width := 0
var _last_frame_height := 0

## Timestamps (seconds, via _now) of the first and last received frames.
var _first_frame_time := 0.0
var _last_frame_time := 0.0

## Periodically checks whether the scene is still/now playing.
var _poll_timer: Timer

## Paces requests toward the target fps (one-in-flight bounds the actual rate).
var _pacing_timer: Timer

## One-shot timer that triggers _on_duration_timeout after _duration seconds.
var _duration_timer: Timer

## One-shot timer that finalizes when no reply arrives within the timeout.
var _no_reply_timer: Timer

## ffmpeg converter (tier-2) — created lazily, owned as child for lifecycle.
var _ffmpeg_converter: GdTMFFmpegConvert = null

## Target format string (extension) from the start() config for ffmpeg conversion.
var _target_output_format: String = ""

## Base output path without .frames suffix, used to build final clip path.
var _base_output_path: String = ""

## Whether auto-convert is enabled (from EditorSettings toggle).
var _auto_convert_enabled: bool = true


## Human-readable backend name shown in the UI.
func get_backend_name() -> String:
	return "Screenshot"


## Short UI description of what this backend needs and its limits, including
## its capture semantics: real-time — the game sim runs at normal speed, so
## capture is machine-bound (no fixed rate) and the window must stay visible.
func get_description() -> String:
	return (
		"Real-time capture of the running scene via the engine's screenshot "
		+ "channel (no extra software): the game sim runs at normal speed, so the "
		+ "rate is machine-bound (~15 fps typical), not fixed. No audio, stills "
		+ "only. The game window must stay visible and focused — occluded windows "
		+ "throttle to ~1 fps."
	)


## Ships with the editor, so this backend is always available.
func is_available() -> bool:
	return true


## Whether a recording session is currently in progress.
func is_recording() -> bool:
	return _active


## Records the already-running scene and stops without killing it.
func get_capture_mode() -> CaptureMode:
	return CaptureMode.IN_PLACE


## Begins a recording: if a scene is already playing, starts capturing
## immediately; otherwise launches the requested scene (from config
## scene_path) and waits for playback to begin before starting capture.
## Mirrors BackendMovieMaker's pending-start UX so the scene picker is
## meaningful for this backend too. Duration timer starts even while
## pending, so a scene that never starts is treated as an error only when a
## duration is set (same contract as movie maker).
func start(config: Dictionary) -> void:
	if _active:
		push_warning("Backend '%s' is already recording" % get_backend_name())
		return
	_output_path = str(config.get("output_path", ""))
	if _output_path.is_empty():
		_output_path = DEFAULT_OUTPUT_PATH
	_duration = float(config.get("duration", 0.0))
	_target_fps = int(config.get("fps", 0))
	# The engine always delivers PNGs; "jpg"/"jpeg" requests a lossy re-encode
	# on receipt, anything else stays PNG. For ffmpeg convert the target is the
	# user-selected output format (mp4/webm/avi/ogv/png/jpg) — native png/jpg
	# keeps frames as-is, others go through ffmpeg.
	var out_format := str(config.get("output_format", "png")).to_lower()
	_image_format = "jpg" if ("jpg" in out_format or "jpeg" in out_format) else "png"
	_target_output_format = out_format
	_base_output_path = _output_path
	# _output_path is the base without extension for IN_PLACE; frames dir is base.frames.
	# Auto-convert toggle from EditorSettings or config override.
	_auto_convert_enabled = _get_auto_convert_setting(config)
	_active = true
	_stopping = false
	_pending_start = false
	_frames_dir = "%s.frames" % _output_path
	_make_frames_dir(_frames_dir)
	if _is_playing_scene():
		_begin_capture()
		return
	# No scene playing — launch the requested scene and wait (same as Movie Maker).
	_pending_start = true
	if _duration > 0.0:
		_start_duration_timer()
	_start_polling()
	_play_scene(str(config.get("scene_path", "")))


## Shared capture start: claims the game_view prefix, starts timers, and
## emits recording_started. Single site for the transition into recording.
## The debugger session may not be active instantly after launch (the
## game→editor handshake is asynchronous), so the first screenshot request
## may be deferred — the no-reply timer bounds that eventuality.
func _begin_capture() -> void:
	_pending_start = false
	_set_screenshot_capture_active(true)
	_connect_screenshot_signal()
	_start_pacing()
	if _duration > 0.0:
		_start_duration_timer()
	_start_no_reply_timer()
	_stop_polling()
	recording_started.emit(get_backend_name(), _output_path)
	_send_next_request()


## Poll tick while pending-start: waits for playback to begin.
func _on_poll_timeout() -> void:
	if not _active:
		return
	if _pending_start:
		if _is_playing_scene():
			_begin_capture()
		return
	# Should never reach here outside pending-start — poll is only
	# supposed to run while pending. Kept as no-op.
	if not _active or _stopping:
		return


## Stops the capture: closes out the session (manifest + stopped + notice).
## The game keeps running — nothing is sent to it and nothing is killed.
func stop() -> void:
	if not _active:
		return
	if _stopping:
		# Already closing out — the no-reply/duration path will finalize.
		return
	if _pending_start:
		# Stop pressed while waiting for the scene to start.
		_pending_start = false
		_active = false
		_stop_polling()
		_stop_duration_timer()
		recording_stopped.emit(get_backend_name(), _output_path)
		_write_manifest()
		_emit_summary_notice()
		return
	_stopping = true
	_finalize_stopped()


## Pacing tick: sends the next request when none is in flight (the loop never
## issues a second request before the game replies to the first).
func _on_pacing_timeout() -> void:
	if not _active or _stopping or _pending_start:
		return
	_send_next_request()


## Duration expiry: if still pending-start, treat as failure; otherwise close
## out the capture with the frames received so far.
func _on_duration_timeout() -> void:
	if not _active:
		return
	if _stopping:
		return
	if _pending_start:
		_pending_start = false
		_active = false
		_stop_polling()
		_stop_duration_timer()
		recording_error.emit(
			get_backend_name(), "Scene did not start playing before the duration elapsed"
		)
		return
	stop()


## No-reply expiry: the game stopped answering (hung/occluded/crashed) —
## finalize with the frames received so far.
func _on_no_reply_timeout() -> void:
	if not _active or _stopping or _pending_start:
		return
	_stopping = true
	_finalize_stopped()


## Handles a frame reply from the plugin: validates the request id, scrubs
## undersized placeholder frames, copies (or JPG re-encodes) the frame into the
## frames dir, updates stats, and restarts the no-reply timer. Accepts legacy
## 0×0 replies as long as something is in flight.
func _on_screenshot_received(rq_id: int, width: int, height: int, path: String) -> void:
	if not _active or _stopping or _pending_start:
		return
	if _in_flight_rq_id == -1:
		# When in_flight is -1 (e.g. session-not-ready retry race), accept
		# any reply while active so first frame isn't lost.
		pass
	elif rq_id != _in_flight_rq_id:
		if width != 0 or height != 0:
			return
	_in_flight_rq_id = -1
	if width == 0 or height == 0:
		var dims := _get_image_dimensions(path)
		width = int(dims.get("width", width))
		height = int(dims.get("height", height))
	# Scrub invalid placeholder frames (the debugger screenshot channel
	# sometimes returns a 1×1 stub for the first request). Anything below
	# MIN_FRAME_DIMENSION is not a real frame: skip the copy and the stats
	# update, but keep the loop moving by immediately issuing the next
	# request.
	if width < MIN_FRAME_DIMENSION or height < MIN_FRAME_DIMENSION:
		_restart_no_reply_timer()
		_send_next_request()
		return
	_last_frame_width = width
	_last_frame_height = height
	var now := _now()
	if _first_frame_time <= 0.0:
		_first_frame_time = now
	_last_frame_time = now
	_frame_count += 1
	_copy_frame(path, _frames_dir.path_join("frame_%05d.%s" % [_frame_count, _image_format]))
	_restart_no_reply_timer()


## Returns image dimensions for the given png path. Isolated seam so tests
## don't touch the filesystem; real implementation loads the image header.
func _get_image_dimensions(path: String) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(path)
	var img := Image.new()
	var err := img.load(abs_path)
	if err != OK:
		# Fallback: try as-is if already absolute / editor temp.
		err = img.load(path)
		if err != OK:
			return {"width": _last_frame_width, "height": _last_frame_height}
	return {"width": img.get_width(), "height": img.get_height()}


## Sends the next screenshot request unless one is already in flight.
func _send_next_request() -> void:
	if not _active or _stopping or _pending_start:
		return
	if _in_flight_rq_id != -1:
		return
	var rq_id := _next_rq_id
	if not _send_screenshot_request(rq_id):
		_restart_no_reply_timer()
		return
	_in_flight_rq_id = rq_id
	_next_rq_id += 1
	_restart_no_reply_timer()


## Ends the session and emits recording_stopped exactly once, then the
## summary notice: releases the game_view capture, disconnects the plugin,
## stops all timers, writes the manifest, and composes the dock message
## (stats, or the zero/low-frame hint). When the output format requires ffmpeg
## (mp4/webm/avi/ogv from frames) and auto-convert is on, triggers async conversion.
func _finalize_stopped() -> void:
	if not _active and not _stopping:
		return
	_active = false
	_stopping = false
	_pending_start = false
	_stop_polling()
	_stop_pacing()
	_stop_duration_timer()
	_stop_no_reply_timer()
	_set_screenshot_capture_active(false)
	_disconnect_screenshot_signal()
	_write_manifest()
	recording_stopped.emit(get_backend_name(), _output_path)
	_emit_summary_notice()
	# After stats: if target requires ffmpeg and frames exist, kick off conversion.
	if _auto_convert_enabled and _frame_count > 0 and _needs_ffmpeg_convert():
		_trigger_ffmpeg_convert()


## Writes manifest.json (frame count, measured/target fps, elapsed, size)
## into the frames dir — the ffmpeg converter reads it to drive conversion.
func _write_manifest() -> void:
	var stats := _compute_stats()
	var data := {
		"frame_count": _frame_count,
		"target_fps": _target_fps,
		"measured_fps": stats["measured_fps"],
		"elapsed_sec": stats["elapsed_sec"],
		"width": _last_frame_width,
		"height": _last_frame_height,
	}
	_write_json_file(_frames_dir.path_join("manifest.json"), data)


## Composes and emits the recording_notice message: stats line, or the
## zero/low-frame hint (the general backend→dock message channel).
func _emit_summary_notice() -> void:
	var stats := _compute_stats()
	var measured := float(stats["measured_fps"])
	var message: String
	if _frame_count == 0:
		message = "No frames captured — is the game window visible and focused?"
	elif _frame_count == 1:
		message = "Saved 1 frame (target %d fps)" % _target_fps
	else:
		message = "Saved %d frames @ %.1f fps (target %d)" % [_frame_count, measured, _target_fps]
		if _target_fps > 0 and measured < _target_fps * LOW_RATE_FRACTION:
			message += " — keep the game window visible and focused for full rate"
	recording_notice.emit(get_backend_name(), message)


## Elapsed capture time and measured fps across received frames.
func _compute_stats() -> Dictionary:
	var elapsed := 0.0
	var measured := 0.0
	if _frame_count >= 2 and _last_frame_time > _first_frame_time:
		elapsed = _last_frame_time - _first_frame_time
		measured = float(_frame_count - 1) / elapsed
	return {"elapsed_sec": elapsed, "measured_fps": measured}


# --- Debugger channel (isolated for testability) -----------------------------


## Claims/releases the game_view capture via the plugin, so the embedded
## preview stalls only during capture. No-op when the plugin is not injected.
func _set_screenshot_capture_active(active: bool) -> void:
	if _debugger_plugin != null and _debugger_plugin.has_method("set_screenshot_capture_active"):
		_debugger_plugin.set_screenshot_capture_active(active)


## Subscribes to frame replies. No-op when the plugin is not injected.
func _connect_screenshot_signal() -> void:
	if _debugger_plugin != null and _debugger_plugin.has_signal("screenshot_received"):
		_debugger_plugin.connect("screenshot_received", _on_screenshot_received)


## Unsubscribes from frame replies.
func _disconnect_screenshot_signal() -> void:
	if (
		_debugger_plugin != null
		and _debugger_plugin.is_connected("screenshot_received", _on_screenshot_received)
	):
		_debugger_plugin.disconnect("screenshot_received", _on_screenshot_received)


## Requests a frame from the running game via the plugin. Returns true when
## the request was dispatched to a live debugger session. No-op/false when
## the plugin is not injected or no session is active yet (e.g. just after
## launching — the pacing loop will retry).
func _send_screenshot_request(rq_id: int) -> bool:
	if _debugger_plugin != null and _debugger_plugin.has_method("send_screenshot_request"):
		var res: Variant = _debugger_plugin.send_screenshot_request(rq_id)
		if res is bool:
			return res
		# Legacy seam that didn't return bool (test double) — treat as sent
		# when the method exists, unless it explicitly returned false.
		return true
	return false


# --- Environment seams (isolated for testability) ----------------------------


## Whether a scene is currently playing in the editor.
func _is_playing_scene() -> bool:
	return EditorInterface.is_playing_scene()


## Launches the given scene, or the current scene when the path is empty.
func _play_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_custom_scene(scene_path)


## Monotonic seconds for frame timing.
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Creates the frames directory (absolute path) and ensures the parent
## output dir carries a .gdignore so Godot doesn't import the captured PNGs.
func _make_frames_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	_ensure_gdignore_in_dir(path.get_base_dir())


## Creates an empty .gdignore in the given directory (if not already present)
## so Godot skips importing any PNG/JPG frames written there. Handles both
## res:// and absolute paths.
func _ensure_gdignore_in_dir(dir_path: String) -> void:
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	var gdignore_path := abs_dir.path_join(".gdignore")
	if FileAccess.file_exists(gdignore_path):
		return
	var file := FileAccess.open(gdignore_path, FileAccess.WRITE)
	if file == null:
		push_warning(
			"Backend '%s': could not create .gdignore in %s" % [get_backend_name(), abs_dir]
		)
		return
	file.close()


## Copies a received frame into the frames dir. The game writes temp files,
## so the copy happens on receipt — a batch copy at stop would race the game's
## side cleanup. In JPG mode the received PNG is decoded and re-encoded as a
## lossy JPG (quality 0.85) to cut storage for footage destined for video
## stitching; any decode/encode failure falls back to a straight copy so no
## frame is ever lost. The straight copy tries the globalized path first, then
## as-is, then a file-by-file stream copy (the game temp may be outside res://
## and copy_absolute can fail on cross-device in some envs).
func _copy_frame(src: String, dst: String) -> void:
	var src_abs := ProjectSettings.globalize_path(src)
	var dst_abs := ProjectSettings.globalize_path(dst)
	# JPG mode: decode the received PNG and re-encode it lossily.
	if _image_format == "jpg":
		var img := Image.new()
		var load_err := img.load(src_abs)
		if load_err != OK:
			load_err = img.load(src)
		if load_err == OK:
			var save_err := img.save_jpg(dst_abs, 0.85)
			if save_err != OK:
				save_err = img.save_jpg(dst, 0.85)
			if save_err == OK:
				return
			push_warning(
				(
					"Backend '%s': JPG encode failed for %s → %s (%s); copying as-is"
					% [get_backend_name(), src, dst, error_string(save_err)]
				)
			)
	# PNG (default) or JPG fallback: try DirAccess.copy_absolute first (fast path).
	var err := DirAccess.copy_absolute(src_abs, dst_abs)
	if err == OK:
		return
	# Retry with original src (could already be absolute OS temp path).
	err = DirAccess.copy_absolute(src, dst_abs)
	if err == OK:
		return
	# Stream fallback.
	var src_file := FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		src_file = FileAccess.open(src_abs, FileAccess.READ)
	if src_file == null:
		push_warning(
			(
				"Backend '%s': could not open source frame %s (%s) — will retry copy later if needed"
				% [get_backend_name(), src, src_abs]
			)
		)
		return
	var dst_file := FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		dst_file = FileAccess.open(dst_abs, FileAccess.WRITE)
	if dst_file == null:
		push_warning(
			"Backend '%s': could not open dest %s → %s" % [get_backend_name(), dst, dst_abs]
		)
		return
	dst_file.store_buffer(src_file.get_buffer(src_file.get_length()))
	src_file.close()
	dst_file.close()


## Writes the manifest JSON to the given path.
func _write_json_file(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Backend '%s': could not write manifest %s" % [get_backend_name(), path])
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


## Returns the no-reply timeout; overridable so tests can shorten the window.
func _get_no_reply_timeout() -> float:
	return NO_REPLY_TIMEOUT


## Returns the pacing interval for the configured target fps.
func _get_frame_interval() -> float:
	if _target_fps > 0:
		return 1.0 / float(_target_fps)
	return DEFAULT_FRAME_INTERVAL


# --- Timer plumbing ----------------------------------------------------------


## Starts the pacing timer (repeat).
func _start_pacing() -> void:
	_ensure_timers()
	if _pacing_timer:
		_pacing_timer.wait_time = _get_frame_interval()
		_pacing_timer.start()


## Starts the one-shot duration timer.
func _start_duration_timer() -> void:
	_ensure_timers()
	if _duration_timer:
		_duration_timer.start(_duration)


## Starts the one-shot no-reply timer.
func _start_no_reply_timer() -> void:
	_ensure_timers()
	if _no_reply_timer:
		_no_reply_timer.start(_get_no_reply_timeout())


## Restarts the no-reply timer after a successful reply.
func _restart_no_reply_timer() -> void:
	_start_no_reply_timer()


## Stops the pacing timer.
func _stop_pacing() -> void:
	if _pacing_timer:
		_pacing_timer.stop()


## Stops the duration timer.
func _stop_duration_timer() -> void:
	if _duration_timer:
		_duration_timer.stop()


## Stops the no-reply timer.
func _stop_no_reply_timer() -> void:
	if _no_reply_timer:
		_no_reply_timer.stop()


## Lazily creates all three timers on first use (requires being inside the
## scene tree) and wires their timeout callbacks.
func _ensure_timers() -> void:
	if _poll_timer == null and is_inside_tree():
		_poll_timer = Timer.new()
		_poll_timer.wait_time = POLL_INTERVAL
		_poll_timer.one_shot = false
		_poll_timer.autostart = false
		_poll_timer.timeout.connect(_on_poll_timeout)
		add_child(_poll_timer)
	if _pacing_timer == null and is_inside_tree():
		_pacing_timer = Timer.new()
		_pacing_timer.wait_time = _get_frame_interval()
		_pacing_timer.one_shot = false
		_pacing_timer.autostart = false
		_pacing_timer.timeout.connect(_on_pacing_timeout)
		add_child(_pacing_timer)
	if _duration_timer == null and is_inside_tree():
		_duration_timer = Timer.new()
		_duration_timer.one_shot = true
		_duration_timer.autostart = false
		_duration_timer.timeout.connect(_on_duration_timeout)
		add_child(_duration_timer)
	if _no_reply_timer == null and is_inside_tree():
		_no_reply_timer = Timer.new()
		_no_reply_timer.one_shot = true
		_no_reply_timer.autostart = false
		_no_reply_timer.timeout.connect(_on_no_reply_timeout)
		add_child(_no_reply_timer)


## Starts the playback poll timer.
func _start_polling() -> void:
	_ensure_timers()
	if _poll_timer:
		_poll_timer.start(POLL_INTERVAL)


## Stops the playback poll timer.
func _stop_polling() -> void:
	if _poll_timer:
		_poll_timer.stop()


# --- ffmpeg tier-2 conversion ------------------------------------------


## Reads auto-convert toggle: config override wins, otherwise EditorSettings
## gd_time_machine/ffmpeg/auto_convert, otherwise ProjectSettings same key,
## default true.
func _get_auto_convert_setting(config: Dictionary) -> bool:
	if config.has("auto_convert"):
		return bool(config["auto_convert"])
	if Engine.has_singleton("EditorSettings"):
		var es: Object = Engine.get_singleton("EditorSettings")
		if es != null and es.has_method("get_setting"):
			var v: Variant = es.get_setting("gd_time_machine/ffmpeg/auto_convert")
			if v != null:
				return bool(v)
	if ProjectSettings.has_setting("gd_time_machine/ffmpeg/auto_convert"):
		return bool(ProjectSettings.get_setting("gd_time_machine/ffmpeg/auto_convert"))
	return true


## Whether frames should be deleted after successful convert. Config key
## clean_frames or EditorSettings gd_time_machine/ffmpeg/clean_frames.
func _get_clean_on_success_setting() -> bool:
	if ProjectSettings.has_setting("gd_time_machine/ffmpeg/clean_frames"):
		return bool(ProjectSettings.get_setting("gd_time_machine/ffmpeg/clean_frames"))
	if Engine.has_singleton("EditorSettings"):
		var es: Object = Engine.get_singleton("EditorSettings")
		if es != null and es.has_method("get_setting"):
			var v: Variant = es.get_setting("gd_time_machine/ffmpeg/clean_frames")
			if v != null:
				return bool(v)
	return true


## Whether the current target format requires ffmpeg (from frames).
func _needs_ffmpeg_convert() -> bool:
	if _target_output_format.is_empty():
		return false
	var fmt := GdTMOutputFormat.from_string(_target_output_format)
	return GdTMOutputFormat.frames_need_ffmpeg(fmt)


## Factory seam — overridden in tests to inject a fake converter.
func _create_ffmpeg_converter() -> GdTMFFmpegConvert:
	return GdTMFFmpegConvert.new()


## Ensures the converter child exists and wires its signals.
func _ensure_ffmpeg_converter() -> void:
	if _ffmpeg_converter != null:
		return
	_ffmpeg_converter = _create_ffmpeg_converter()
	if is_inside_tree():
		add_child(_ffmpeg_converter)
	_ffmpeg_converter.conversion_succeeded.connect(_on_ffmpeg_convert_succeeded)
	_ffmpeg_converter.conversion_failed.connect(_on_ffmpeg_convert_failed)
	_ffmpeg_converter.ffmpeg_not_found.connect(_on_ffmpeg_not_found)


## Triggers async ffmpeg conversion for the just-finalized frames dir. Seam for
## tests: FakeScreenshotBackend overrides this to capture intent and emit its
## own outcomes synchronously.
func _trigger_ffmpeg_convert() -> void:
	_ensure_ffmpeg_converter()
	var stats := _compute_stats()
	var measured := float(stats.get("measured_fps", 0.0))
	# "Converting…" feedback for the dock status line.
	recording_notice.emit(
		get_backend_name(), "Converting to %s…" % _target_output_format.to_lower()
	)
	_ffmpeg_converter.convert_frames_async(
		_frames_dir,
		_base_output_path,
		_target_output_format,
		measured,
		_image_format,
		_get_clean_on_success_setting()
	)


func _on_ffmpeg_convert_succeeded(clip_path: String) -> void:
	recording_converted.emit(get_backend_name(), clip_path)
	# Keep the final path visible in status line; notice composes own message.
	recording_notice.emit(
		get_backend_name(),
		"Converted to %s" % clip_path.get_file() if not clip_path.is_empty() else "Converted"
	)


func _on_ffmpeg_not_found(message: String) -> void:
	recording_notice.emit(get_backend_name(), message)


func _on_ffmpeg_convert_failed(error_message: String, stderr_tail: String) -> void:
	var detail := error_message
	if not stderr_tail.is_empty():
		detail = "%s\n%s" % [error_message, stderr_tail]
	recording_error.emit(get_backend_name(), detail)


func _exit_tree() -> void:
	# Ensure any running ffmpeg thread is reclaimed before this Node is freed.
	if _ffmpeg_converter != null:
		_ffmpeg_converter.wait_for_completion()
