@tool
extends RecorderBackend
class_name BackendMovieMaker

## Godot's built-in Movie Maker backend. No extra software needed.
##
## Recordings are written as .avi via the engine's Movie Maker. Recording
## starts when the scene actually begins playing (Movie Maker only writes
## frames while a scene runs), so playback state is polled with a Timer —
## there is no editor signal for play/stop (see godot-proposals#3504).
##
## All EditorInterface/ProjectSettings access goes through `_`-prefixed seam
## methods so tests can subclass this backend and fake the editor without
## touching engine singletons.
##
## State machine:
##   start() → _active=true, _pending_start=true → scene plays (poll) →
##   recording_started → duration timer (if any) or manual stop() or natural
##   scene exit (poll) → recording_stopped. If the scene never starts playing
##   before the duration elapses, recording_error is emitted instead.
##
## stop() is a graceful-stop funnel: it sends a graceful-stop message to the
## running game (via the injected debugger plugin), sets _stopping=true and
## arms a grace timer, then lets the poll observe the game exiting. Every stop
## path (manual, duration expiry, natural exit, grace-timeout fallback)
## converges on _finalize_stopped(), the single recording_stopped emission
## site. The grace timer forces a fallback _stop_playing_scene() if the game
## never quits on its own.

const POLL_INTERVAL := 0.5  # seconds between is_playing_scene() checks
const DEFAULT_OUTPUT_PATH := "res://movie.avi"
const GRACE_PERIOD := 2.0  # seconds to wait for graceful game exit before force-stop

var _active := false  # a recording session is in progress
var _pending_start := false  # start() called, waiting for playback to begin
var _stopping := false  # graceful stop in progress; awaiting poll exit or grace timer
var _output_path := ""
var _duration := 0.0  # 0 = record until stopped manually
var _poll_timer: Timer
var _duration_timer: Timer
var _grace_timer: Timer
var _debugger_plugin: Object = null  # injected by plugin.gd; used to send graceful-stop message


func get_backend_name() -> String:
	return "Godot Movie Maker"


func get_description() -> String:
	return "Built-in Godot encoder. No extra software needed."


func is_available() -> bool:
	return true


func is_recording() -> bool:
	return _active


func get_capture_mode() -> CaptureMode:
	# Movie Maker is a process-launch feature: --write-movie is appended at
	# game startup, so recording always relaunches the scene (constraint 1 in
	# notes/BRAINSTORM_in_place_recording.md). Explicit even though it matches
	# the base default — the default could change, this fact cannot.
	return CaptureMode.RESTART_SCENE


func start(config: Dictionary) -> void:
	if _active:
		push_warning("Backend '%s' is already recording" % get_backend_name())
		return
	_active = true
	_pending_start = true
	_stopping = false
	_output_path = str(config.get("output_path", ""))
	if _output_path.is_empty():
		_output_path = DEFAULT_OUTPUT_PATH
	_duration = float(config.get("duration", 0.0))
	var fps: int = int(config.get("fps", 0))
	_set_movie_file(_output_path)
	if fps > 0:
		_set_movie_fps(fps)
	_set_movie_maker_enabled(true)
	_start_polling()
	if _duration > 0.0:
		_start_duration_timer()
	_play_scene(str(config.get("scene_path", "")))


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


func _on_poll_timeout() -> void:
	if not _active:
		return
	if _stopping:
		# Graceful stop: waiting for the game to exit on its own.
		if not _is_playing_scene():
			_finalize_stopped()
		return
	if _is_playing_scene():
		if _pending_start:
			_pending_start = false
			recording_started.emit(get_backend_name(), _output_path)
	else:
		# Playback ended without an explicit stop (natural scene exit).
		_finalize_stopped()


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
		_stop_playing_scene()
	else:
		stop()


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
	_set_movie_maker_enabled(false)


# --- Seam methods (overridable in tests) -----------------------------------


func _set_movie_file(path: String) -> void:
	ProjectSettings.set_setting("editor/movie_writer/movie_file", path)
	ProjectSettings.save()


func _set_movie_fps(fps: int) -> void:
	ProjectSettings.set_setting("editor/movie_writer/fps", fps)
	ProjectSettings.save()


func _set_movie_maker_enabled(enabled: bool) -> void:
	EditorInterface.set_movie_maker_enabled(enabled)


func _is_movie_maker_enabled() -> bool:
	return EditorInterface.is_movie_maker_enabled()


func _is_playing_scene() -> bool:
	return EditorInterface.is_playing_scene()


func _play_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_custom_scene(scene_path)


func _stop_playing_scene() -> void:
	EditorInterface.stop_playing_scene()


func _send_graceful_stop_message() -> void:
	# Asks the running game to quit gracefully (via plugin.gd's debugger
	# plugin) so Movie Maker finalizes the AVI. No-op when the plugin has not
	# been injected; overridable in tests to record call order.
	if _debugger_plugin != null and _debugger_plugin.has_method("send_graceful_stop"):
		_debugger_plugin.send_graceful_stop()


func _get_grace_period() -> float:
	# Overridable so tests can shorten the grace window.
	return GRACE_PERIOD


# --- Timer plumbing ----------------------------------------------------------


func _start_polling() -> void:
	_ensure_timers()
	if _poll_timer:
		_poll_timer.start(POLL_INTERVAL)


func _start_duration_timer() -> void:
	_ensure_timers()
	if _duration_timer:
		_duration_timer.start(_duration)


func _stop_polling() -> void:
	if _poll_timer:
		_poll_timer.stop()


func _stop_duration_timer() -> void:
	if _duration_timer:
		_duration_timer.stop()


func _start_grace_timer() -> void:
	_ensure_timers()
	if _grace_timer:
		_grace_timer.start(_get_grace_period())


func _stop_grace_timer() -> void:
	if _grace_timer:
		_grace_timer.stop()


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
