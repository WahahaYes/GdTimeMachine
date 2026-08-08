@tool
extends RecorderBackend
class_name BackendMovieMaker

## Godot's built-in Movie Maker backend: captures the playing scene as .avi
## with no extra software. Recording starts once the scene actually plays
## (Movie Maker only writes frames while a scene runs), so playback state is
## polled with a Timer — the editor exposes no play/stop signal.
##
## Stopping is graceful: the game is asked to quit so the AVI finalizes, a
## grace timer bounds the wait, and a force-stop is the fallback.

## State machine: idle → start() → pending-start (waiting for playback to
## begin) → recording → stopped. Stop paths — manual stop(), duration expiry,
## natural scene exit, or grace-timeout fallback — all converge on
## _finalize_stopped(), the single recording_stopped emission site. If the
## scene never starts playing before the duration elapses, recording_error is
## emitted instead. The grace timer forces a fallback _stop_playing_scene()
## if the game never quits on its own.

## Seconds between playback-state checks.
const POLL_INTERVAL := 0.5

## Default recording destination when the config provides no output_path.
const DEFAULT_OUTPUT_PATH := "res://movie.avi"

## Seconds to wait for the game to exit gracefully before forcing a stop.
const GRACE_PERIOD := 2.0

## Size at which recording auto-stops (bytes). Godot's MJPEG AVI writer uses a
## RIFF container with 32-bit offsets, so files past 4 GiB are corrupted. The
## dock warning is the soft notice; this guard stops the recording 256 MiB
## before the cap so the finalization write still lands inside it.
const AVI_SIZE_LIMIT_BYTES := 4 * 1024 * 1024 * 1024 - 256 * 1024 * 1024

## Whether a recording session is in progress (from start() until finalize).
var _active := false

## True after start() while waiting for playback to begin.
var _pending_start := false

## True while a graceful stop is in progress: awaiting poll-observed exit or
## the grace timer.
var _stopping := false

## True when the 4 GB AVI size guard triggered the current stop;
## _finalize_stopped() emits the notice for it. Reset on finalize.
var _stopped_for_size_limit := false

## Where the engine actually writes; for tier-2 targets this is the AVI
## intermediate. For native targets it's the final path. Consumers observe it
## via recording_stopped; converted targets are signaled separately.
var _output_path := ""

## Recording duration in seconds; 0 = record until stopped manually.
var _duration := 0.0

## Previous movie_file setting captured on start(), restored on finalize.
var _prev_movie_file: Variant = null

## Previous fps setting captured on start(), restored on finalize.
var _prev_fps: Variant = null

## Periodically checks whether the scene is still playing.
var _poll_timer: Timer

## One-shot timer that triggers _on_duration_timeout after _duration seconds.
var _duration_timer: Timer

## One-shot timer that triggers the force-stop fallback after the grace period.
var _grace_timer: Timer

## Injected by plugin.gd; used to send the graceful-stop request to the game.
var _debugger_plugin: Object = null

## ffmpeg converter for tier-2 MP4/WebM targets — created lazily.
var _ffmpeg_converter: GdTMFFmpegConvert = null

## Target output extension/format from build_config(): e.g. "avi" vs "mp4".
## Stored so _finalize_stopped can decide whether to transcode.
var _target_output_format: String = ""

## Final desired path when tier-2 conversion is active (mp4/webm).
## _output_path always points to what the engine writers actually wrote
## (avi intermediate for tier-2, native path otherwise).
var _final_output_path: String = ""

## Absolute/ res path to the engine intermediate file that ffmpeg reads.
var _intermediate_path: String = ""

## Whether to auto-convert AVI→MP4 via ffmpeg when target is MP4/WEBM.
var _auto_convert_enabled: bool = true

## Target FPS from config, preserved for ffmpeg output -r.
var _target_fps: int = 0


## Human-readable backend name shown in the UI.
func get_backend_name() -> String:
	return "Godot Movie Maker"


## Short UI description of what this backend needs, including its capture
## semantics: fixed-fps (non-real-time) — the scene is restarted and playback
## is deterministically paced, so the output rate equals the configured FPS
## regardless of editor performance.
func get_description() -> String:
	return (
		"Built-in Godot encoder. Fixed-fps, non-real-time: the scene is restarted "
		+ "and playback is deterministically paced — output rate equals the "
		+ "configured FPS regardless of editor performance. No extra software needed."
	)


## Movie Maker ships with the editor, so this backend is always available.
func is_available() -> bool:
	return true


## Whether a recording session is currently in progress.
func is_recording() -> bool:
	return _active


## Movie Maker needs --write-movie at game startup, so recording always
## relaunches the scene. Explicit even though it matches the base default —
## the default could change, this fact cannot.
func get_capture_mode() -> CaptureMode:
	return CaptureMode.RESTART_SCENE


## Begins a recording: captures previous ProjectSettings, configures Movie Maker
## settings without persisting to disk, enables Movie Maker, starts the poll
## and duration timer, then launches the scene. When the target format is a
## tier-2 type (MP4/WebM) the engine still writes AVI as intermediate; final
## transcoding happens in _finalize_stopped().
func start(config: Dictionary) -> void:
	if _active:
		push_warning("Backend '%s' is already recording" % get_backend_name())
		return
	_active = true
	_pending_start = true
	_stopping = false
	_stopped_for_size_limit = false
	var raw_path := str(config.get("output_path", ""))
	if raw_path.is_empty():
		raw_path = DEFAULT_OUTPUT_PATH
	_duration = float(config.get("duration", 0.0))
	_target_output_format = str(config.get("output_format", "")).to_lower()
	_auto_convert_enabled = _get_auto_convert_setting(config)
	_target_fps = int(config.get("fps", 0))
	_output_path = raw_path
	_final_output_path = raw_path
	_intermediate_path = raw_path
	var fmt := GdTMOutputFormat.from_string(_target_output_format)
	if GdTMOutputFormat.is_tier2_format(fmt):
		var base := raw_path
		var ext := base.get_extension().to_lower()
		if ext in ["mp4", "webm"]:
			base = base.substr(0, base.length() - ext.length() - 1)
		_intermediate_path = "%s.avi" % base
		_output_path = _intermediate_path
	var fps: int = _target_fps
	_prev_movie_file = _get_movie_file()
	_prev_fps = _get_movie_fps()
	_set_movie_file(_output_path)
	if fps > 0:
		_set_movie_fps(fps)
	_set_movie_maker_enabled(true)
	_start_polling()
	# Don't start duration timer yet for RESTART_SCENE — it should measure
	# actual recording time, not launch overhead. Timer starts when poll sees
	# playback begin (see _on_poll_timeout). If scene never starts, the
	# duration expiry still needs to fire, so we arm a separate pending watchdog
	# that treats lack of start as error (same as before, but via same timer).
	# Simplest: start timer now for pending detection, but restart it on
	# recording start so footage duration matches user request.
	if _duration > 0.0:
		_start_duration_timer()
	_play_scene(str(config.get("scene_path", "")))


## Gracefully stops the recording: asks the game to quit so Movie Maker can
## finalize the AVI, arms the grace timer as a fallback, and keeps polling to
## observe the game exiting.
func stop() -> void:
	if not _active:
		return
	if _stopping:
		# Already gracefully stopping — the poll or grace timer will finalize.
		return
	# Ask the game to quit gracefully so Movie Maker finalizes the AVI. This
	# must run before any _stop_playing_scene() fallback would SIGKILL it.
	_send_graceful_stop_message()
	_stopping = true
	_stop_duration_timer()
	_start_grace_timer()
	# Keep polling so we observe the game exiting and finalize without the
	# grace-timer fallback when it quits promptly.
	_start_polling()


## Poll tick: while stopping, waits for the scene to exit; otherwise detects
## playback start (emitting recording_started) or a natural scene exit
## (finalizing the recording). Duration timer is restarted when playback
## actually begins so the requested duration measures footage, not launch
## overhead (5s request was giving 2.5s file when scene took ~2.5s to start).
func _on_poll_timeout() -> void:
	if not _active:
		return
	if _stopping:
		if not _is_playing_scene():
			_finalize_stopped()
		return
	if _is_playing_scene():
		if _pending_start:
			_pending_start = false
			recording_started.emit(get_backend_name(), _output_path)
			if _duration > 0.0:
				# Restart so duration counts from first rendered frame.
				_start_duration_timer()
		else:
			# While recording, enforce the hard 4 GB AVI cap (the dock warning
			# is the soft notice; this is the enforcement).
			_check_avi_size_limit()
	else:
		_finalize_stopped()


## Duration expiry: if the scene never started playing, emits recording_error
## and cleans up; otherwise triggers a graceful stop.
func _on_duration_timeout() -> void:
	if not _active:
		return
	if _stopping:
		# Already gracefully stopping — ignore the timer; finalize will clear it.
		return
	if _pending_start:
		# The scene never started playing — treat as a failure, not a stop.
		_pending_start = false
		_stopping = false
		_active = false
		_stop_polling()
		_stop_grace_timer()
		recording_error.emit(
			get_backend_name(), "Scene did not start playing before the duration elapsed"
		)
		_set_movie_maker_enabled(false)
		_restore_settings()
		_stop_playing_scene()
	else:
		stop()


## Grace expiry: the game did not exit during the grace period, so force-stop
## it and finalize the recording.
func _on_grace_timeout() -> void:
	if not _active:
		return
	if not _stopping:
		return
	# The game did not exit during the grace period — force it to stop, then
	# finalize. _stop_playing_scene() here is the fallback that would SIGKILL,
	# so it only runs once the graceful path has had its chance.
	_stop_playing_scene()
	_finalize_stopped()


## Ends the session and emits recording_stopped exactly once: restores
## previous ProjectSettings, disables Movie Maker and stops all timers.
## For tier-2 targets (MP4/WebM) triggers async ffmpeg conversion after stopped.
func _finalize_stopped() -> void:
	# Single-emission guard: after the first finalize both flags are false, so
	# any later call (idle poll, grace timer, explicit stop) is a no-op.
	if not _active and not _stopping:
		return
	_active = false
	_pending_start = false
	_stopping = false
	_stop_polling()
	_stop_duration_timer()
	_stop_grace_timer()
	recording_stopped.emit(get_backend_name(), _output_path)
	if _stopped_for_size_limit:
		_stopped_for_size_limit = false
		(
			recording_notice
			. emit(
				get_backend_name(),
				"Stopped at the AVI 4 GB cap — file finalized before corruption",
			)
		)
	_set_movie_maker_enabled(false)
	_restore_settings()
	# Tier-2: AVI just finalized, now transcode to MP4/WebM if requested.
	var fmt := GdTMOutputFormat.from_string(_target_output_format)
	if _auto_convert_enabled and GdTMOutputFormat.is_tier2_format(fmt):
		_trigger_ffmpeg_convert()


# --- Settings snapshot/restore (no ProjectSettings.save()) -------------------


## Restores movie_file and fps to what they were before start().
func _restore_settings() -> void:
	if _prev_movie_file == null:
		_clear_movie_file()
	else:
		_set_movie_file_no_restore(str(_prev_movie_file))
	if _prev_fps == null:
		_clear_movie_fps()
	else:
		_set_movie_fps_no_restore(int(_prev_fps))
	_prev_movie_file = null
	_prev_fps = null


# --- Editor interaction (isolated for testability) ---------------------------


## Reads current movie_file setting.
func _get_movie_file() -> Variant:
	return ProjectSettings.get_setting("editor/movie_writer/movie_file")


## Reads current fps setting.
func _get_movie_fps() -> Variant:
	return ProjectSettings.get_setting("editor/movie_writer/fps")


## Writes the output path to ProjectSettings without saving to disk.
## The child process sees it via GLOBAL_GET already, so no save() is needed.
func _set_movie_file(path: String) -> void:
	ProjectSettings.set_setting("editor/movie_writer/movie_file", path)


func _set_movie_file_no_restore(path: String) -> void:
	ProjectSettings.set_setting("editor/movie_writer/movie_file", path)


func _clear_movie_file() -> void:
	if ProjectSettings.has_setting("editor/movie_writer/movie_file"):
		ProjectSettings.set_setting("editor/movie_writer/movie_file", null)


## Writes the target FPS to ProjectSettings without saving to disk.
func _set_movie_fps(fps: int) -> void:
	ProjectSettings.set_setting("editor/movie_writer/fps", fps)


func _set_movie_fps_no_restore(fps: int) -> void:
	ProjectSettings.set_setting("editor/movie_writer/fps", fps)


func _clear_movie_fps() -> void:
	if ProjectSettings.has_setting("editor/movie_writer/fps"):
		ProjectSettings.set_setting("editor/movie_writer/fps", null)


## Enables or disables Movie Maker in the editor.
func _set_movie_maker_enabled(enabled: bool) -> void:
	EditorInterface.set_movie_maker_enabled(enabled)


## Whether Movie Maker is currently enabled in the editor.
func _is_movie_maker_enabled() -> bool:
	return EditorInterface.is_movie_maker_enabled()


## Whether a scene is currently playing in the editor.
func _is_playing_scene() -> bool:
	return EditorInterface.is_playing_scene()


## Launches the given scene, or the current scene when the path is empty.
func _play_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_custom_scene(scene_path)


## Stops the running scene; the force-stop fallback after a graceful stop
## fails to make the game quit on its own.
func _stop_playing_scene() -> void:
	EditorInterface.stop_playing_scene()


## Asks the running game to quit gracefully via the injected debugger plugin
## so Movie Maker finalizes the AVI. No-op when the plugin is not injected.
func _send_graceful_stop_message() -> void:
	if _debugger_plugin != null and _debugger_plugin.has_method("send_graceful_stop"):
		_debugger_plugin.send_graceful_stop()


## Returns the grace period; overridable so tests can shorten the window.
func _get_grace_period() -> float:
	return GRACE_PERIOD


# --- ffmpeg tier-2 conversion (Op6) ------------------------------------------


func _get_auto_convert_setting(config: Dictionary) -> bool:
	if config.has("auto_convert"):
		return bool(config["auto_convert"])
	if ProjectSettings.has_setting("gd_time_machine/ffmpeg/auto_convert"):
		return bool(ProjectSettings.get_setting("gd_time_machine/ffmpeg/auto_convert"))
	if Engine.has_singleton("EditorSettings"):
		var es: Object = Engine.get_singleton("EditorSettings")
		if es != null and es.has_method("get_setting"):
			var v: Variant = es.get_setting("gd_time_machine/ffmpeg/auto_convert")
			if v != null:
				return bool(v)
	return true


func _create_ffmpeg_converter() -> GdTMFFmpegConvert:
	return GdTMFFmpegConvert.new()


func _ensure_ffmpeg_converter() -> void:
	if _ffmpeg_converter != null:
		return
	_ffmpeg_converter = _create_ffmpeg_converter()
	if is_inside_tree():
		add_child(_ffmpeg_converter)
	_ffmpeg_converter.conversion_succeeded.connect(_on_ffmpeg_convert_succeeded)
	_ffmpeg_converter.conversion_failed.connect(_on_ffmpeg_convert_failed)
	_ffmpeg_converter.ffmpeg_not_found.connect(_on_ffmpeg_not_found)


func _trigger_ffmpeg_convert() -> void:
	_ensure_ffmpeg_converter()
	recording_notice.emit(
		get_backend_name(), "Converting to %s…" % _target_output_format.to_lower()
	)
	_ffmpeg_converter.convert_file_async(_intermediate_path, _final_output_path, false, _target_fps)


func _on_ffmpeg_convert_succeeded(clip_path: String) -> void:
	recording_converted.emit(get_backend_name(), clip_path)
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
	if _ffmpeg_converter != null:
		_ffmpeg_converter.wait_for_completion()


# --- Timer plumbing ----------------------------------------------------------


## Starts the playback poll timer.
func _start_polling() -> void:
	_ensure_timers()
	if _poll_timer:
		_poll_timer.start(POLL_INTERVAL)


## Starts the one-shot duration timer.
func _start_duration_timer() -> void:
	_ensure_timers()
	if _duration_timer:
		_duration_timer.start(_duration)


## Stops the playback poll timer.
func _stop_polling() -> void:
	if _poll_timer:
		_poll_timer.stop()


## Stops the duration timer.
func _stop_duration_timer() -> void:
	if _duration_timer:
		_duration_timer.stop()


## Starts the one-shot grace timer.
func _start_grace_timer() -> void:
	_ensure_timers()
	if _grace_timer:
		_grace_timer.start(_get_grace_period())


## Stops the grace timer.
func _stop_grace_timer() -> void:
	if _grace_timer:
		_grace_timer.stop()


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
	if _duration_timer == null and is_inside_tree():
		_duration_timer = Timer.new()
		_duration_timer.one_shot = true
		_duration_timer.autostart = false
		_duration_timer.timeout.connect(_on_duration_timeout)
		add_child(_duration_timer)
	if _grace_timer == null and is_inside_tree():
		_grace_timer = Timer.new()
		_grace_timer.wait_time = _get_grace_period()
		_grace_timer.one_shot = true
		_grace_timer.autostart = false
		_grace_timer.timeout.connect(_on_grace_timeout)
		add_child(_grace_timer)


# --- AVI 4 GB hard guard ------------------------------------------------------


## Current size in bytes of the engine's output file; 0 when the file cannot
## be opened. Overridable seam so tests can fake sizes without a real file.
func _get_output_file_size() -> int:
	var abs_path := ProjectSettings.globalize_path(_output_path)
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size


## Hard 4 GB cap enforcement: once the output approaches the RIFF limit, stops
## gracefully so the engine finalizes the AVI inside the cap (the graceful
## quit path writes the remaining RIFF headers). The dock warning is the soft
## notice; this is the enforcement.
func _check_avi_size_limit() -> void:
	if not _writes_avi():
		return
	if _get_output_file_size() < AVI_SIZE_LIMIT_BYTES:
		return
	_stopped_for_size_limit = true
	stop()


## Whether the engine is currently writing an AVI: native .avi output, or the
## .avi intermediate for tier-2 MP4/WebM targets — both go through the same
## MJPEG AVI writer with the hard 4 GB RIFF cap.
func _writes_avi() -> bool:
	return _output_path.get_extension().to_lower() == "avi"
