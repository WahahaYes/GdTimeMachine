@tool
extends RecorderBackend
class_name BackendScreenshotCapture

## IN_PLACE backend that captures the running scene through the engine's
## debugger screenshot channel (scene:rq_screenshot → game_view:get_screenshot)
## on the Op-2 debugger plugin. The game keeps running — no restart, no
## graceful quit. Received PNGs are copied into `<output_path>.frames/` on
## receipt (the game may clean up its temp files at any point) and a
## manifest.json records the measured statistics for the dock notice and for
## Op 6's converter.
##
## The loop paces at the configured target fps with one request in flight at
## a time; the achievable rate is machine-bound (spike: ~16-18 fps @720p
## foreground on a low-power laptop, faster machines may reach 60). When the
## game window is backgrounded/occluded Godot throttles it to ~1 fps — the
## window must stay visible and focused.

## State machine: idle → start() → recording → stopped. All stop paths —
## manual stop(), duration expiry, and the no-reply timeout — converge on
## _finalize_stopped(), the single recording_stopped emission site. start()
## fails with recording_error when no scene is running (never auto-launches;
## that is RESTART_SCENE behavior). The no-reply timeout finalizes with the
## frames received so far; zero frames still emits recording_stopped + a
## notice — recording_error stays reserved for the no-game case.

## Default recording base path when the config provides no output_path; the
## frames land in "<this>.frames/".
const DEFAULT_OUTPUT_PATH := "res://media/captures/screenshot"

## Seconds without any frame reply before the capture finalizes with the
## frames received so far (game hung, occluded, or crashed mid-capture).
## Restarted on every reply, so a healthy-but-slow capture (e.g. 1 fps
## occluded) never trips it.
const NO_REPLY_TIMEOUT := 5.0

## Pacing fallback when the config provides no fps: ~15 fps.
const DEFAULT_FRAME_INTERVAL := 1.0 / 15.0

## A measured fps below this fraction of the target is flagged as low (the
## foreground hint fires).
const LOW_RATE_FRACTION := 0.25

## Whether a recording session is in progress (from start() until finalize).
var _active := false

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

## Number of frames copied so far (also the next frame index, 1-based).
var _frame_count := 0

## Width/height of the last received frame (from the reply).
var _last_frame_width := 0
var _last_frame_height := 0

## Timestamps (seconds, via _now) of the first and last received frames.
var _first_frame_time := 0.0
var _last_frame_time := 0.0

## Paces requests toward the target fps (one-in-flight bounds the actual rate).
var _pacing_timer: Timer

## One-shot timer that triggers _on_duration_timeout after _duration seconds.
var _duration_timer: Timer

## One-shot timer that finalizes when no reply arrives within the timeout.
var _no_reply_timer: Timer


## Human-readable backend name shown in the UI.
func get_backend_name() -> String:
	return "Screenshot"


## Short UI description of what this backend needs and its limits.
func get_description() -> String:
	return (
		"Captures the running scene via the engine's screenshot channel (no extra software). "
		+ "No audio, stills only. The game window must stay visible and focused — occluded "
		+ "windows throttle to ~1 fps. Dev-quality rate (~15 fps typical), machine-dependent."
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


## Begins a recording: requires a running game, claims the game_view capture
## prefix, starts the paced one-in-flight request loop, and emits
## recording_started. Fails with recording_error (no game launched) when
## nothing is playing.
func start(config: Dictionary) -> void:
	if _active:
		push_warning("Backend '%s' is already recording" % get_backend_name())
		return
	_output_path = str(config.get("output_path", ""))
	if _output_path.is_empty():
		_output_path = DEFAULT_OUTPUT_PATH
	_duration = float(config.get("duration", 0.0))
	_target_fps = int(config.get("fps", 0))
	if not _is_playing_scene():
		(
			recording_error
			. emit(
				get_backend_name(),
				"Play a scene first — screenshot capture records the running scene",
			)
		)
		return
	_active = true
	_stopping = false
	_frames_dir = "%s.frames" % _output_path
	_make_frames_dir(_frames_dir)
	_set_screenshot_capture_active(true)
	_connect_screenshot_signal()
	_request_window_focus()
	_start_pacing()
	if _duration > 0.0:
		_start_duration_timer()
	_start_no_reply_timer()
	recording_started.emit(get_backend_name(), _output_path)
	_send_next_request()


## Stops the capture: closes out the session (manifest + stopped + notice).
## The game keeps running — nothing is sent to it and nothing is killed.
func stop() -> void:
	if not _active:
		return
	if _stopping:
		# Already closing out — the no-reply/duration path will finalize.
		return
	_stopping = true
	_finalize_stopped()


## Pacing tick: sends the next request when none is in flight (the loop never
## issues a second request before the game replies to the first).
func _on_pacing_timeout() -> void:
	if not _active or _stopping:
		return
	_send_next_request()


## Duration expiry: closes out the capture with the frames received so far.
func _on_duration_timeout() -> void:
	if not _active or _stopping:
		return
	stop()


## No-reply expiry: the game stopped answering (hung/occluded/crashed) —
## finalize with the frames received so far.
func _on_no_reply_timeout() -> void:
	if not _active or _stopping:
		return
	_stopping = true
	_finalize_stopped()


## Handles a frame reply from the plugin: validates the request id, copies the
## PNG into the frames dir, updates stats, and restarts the no-reply timer.
func _on_screenshot_received(rq_id: int, width: int, height: int, path: String) -> void:
	if not _active or _stopping:
		return
	if rq_id != _in_flight_rq_id:
		# Stale or duplicate reply — nothing is in flight for this id anymore.
		return
	_in_flight_rq_id = -1
	_last_frame_width = width
	_last_frame_height = height
	var now := _now()
	if _first_frame_time <= 0.0:
		_first_frame_time = now
	_last_frame_time = now
	_frame_count += 1
	_copy_frame(path, _frames_dir.path_join("frame_%05d.png" % _frame_count))
	_restart_no_reply_timer()


## Sends the next screenshot request unless one is already in flight.
func _send_next_request() -> void:
	if not _active or _stopping:
		return
	if _in_flight_rq_id != -1:
		return
	_in_flight_rq_id = _next_rq_id
	_next_rq_id += 1
	_send_screenshot_request(_in_flight_rq_id)


## Ends the session and emits recording_stopped exactly once, then the
## summary notice: releases the game_view capture, disconnects the plugin,
## stops all timers, writes the manifest, and composes the dock message
## (stats, or the zero/low-frame hint).
func _finalize_stopped() -> void:
	if not _active and not _stopping:
		return
	_active = false
	_stopping = false
	_stop_pacing()
	_stop_duration_timer()
	_stop_no_reply_timer()
	_set_screenshot_capture_active(false)
	_disconnect_screenshot_signal()
	_write_manifest()
	recording_stopped.emit(get_backend_name(), _output_path)
	_emit_summary_notice()


## Writes manifest.json (frame count, measured/target fps, elapsed, size)
## into the frames dir — Op 6 reads it to drive the converter.
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


## Requests a frame from the running game via the plugin. No-op when the
## plugin is not injected.
func _send_screenshot_request(rq_id: int) -> void:
	if _debugger_plugin != null and _debugger_plugin.has_method("send_screenshot_request"):
		_debugger_plugin.send_screenshot_request(rq_id)


# --- Environment seams (isolated for testability) ----------------------------


## Whether a scene is currently playing in the editor.
func _is_playing_scene() -> bool:
	return EditorInterface.is_playing_scene()


## Monotonic seconds for frame timing.
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Creates the frames directory (absolute path).
func _make_frames_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


## Copies a received PNG into the frames dir. The game writes temp files, so
## the copy happens on receipt — a batch copy at stop would race the game's
## side cleanup.
func _copy_frame(src: String, dst: String) -> void:
	var err := DirAccess.copy_absolute(
		ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dst)
	)
	if err != OK:
		push_warning(
			(
				"Backend '%s': could not copy frame %s → %s (%s)"
				% [get_backend_name(), src, dst, error_string(err)]
			)
		)


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
