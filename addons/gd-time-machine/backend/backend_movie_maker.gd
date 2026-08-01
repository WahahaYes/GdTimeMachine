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

const POLL_INTERVAL := 0.5  # seconds between is_playing_scene() checks
const DEFAULT_OUTPUT_PATH := "res://movie.avi"

var _active := false          # a recording session is in progress
var _pending_start := false   # start() called, waiting for playback to begin
var _output_path := ""
var _duration := 0.0          # 0 = record until stopped manually
var _poll_timer: Timer
var _duration_timer: Timer


func get_backend_name() -> String:
	return "Godot Movie Maker"


func get_description() -> String:
	return "Built-in Godot encoder. No extra software needed."


func is_available() -> bool:
	return true


func is_recording() -> bool:
	return _active


func start(config: Dictionary) -> void:
	if _active:
		push_warning("Backend '%s' is already recording" % get_backend_name())
		return
	_active = true
	_pending_start = true
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
	_active = false
	_pending_start = false
	_stop_polling()
	_stop_duration_timer()
	recording_stopped.emit(get_backend_name(), _output_path)
	_set_movie_maker_enabled(false)
	_stop_playing_scene()


func _on_poll_timeout() -> void:
	if not _active:
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
	if _pending_start:
		# The scene never started playing — treat as a failure, not a stop.
		_pending_start = false
		_active = false
		_stop_polling()
		recording_error.emit(get_backend_name(),
			"Scene did not start playing before the duration elapsed")
		_set_movie_maker_enabled(false)
		_stop_playing_scene()
	else:
		stop()


func _finalize_stopped() -> void:
	_active = false
	_pending_start = false
	_stop_polling()
	_stop_duration_timer()
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
