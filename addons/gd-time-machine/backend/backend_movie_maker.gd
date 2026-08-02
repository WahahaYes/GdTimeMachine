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

## Whether a recording session is in progress (from start() until finalize).
var _active := false

## True after start() while waiting for playback to begin.
var _pending_start := false

## True while a graceful stop is in progress: awaiting poll-observed exit or
## the grace timer.
var _stopping := false

## Where the recording is written; resolved to DEFAULT_OUTPUT_PATH when unset.
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


## Human-readable backend name shown in the UI.
func get_backend_name() -> String:
	return "Godot Movie Maker"


## Short UI description of what this backend needs.
func get_description() -> String:
	return "Built-in Godot encoder. No extra software needed."


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
## and duration timer, then launches the scene.
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
	_prev_movie_file = _get_movie_file()
	_prev_fps = _get_movie_fps()
	_set_movie_file(_output_path)
	if fps > 0:
		_set_movie_fps(fps)
	_set_movie_maker_enabled(true)
	_start_polling()
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
## (finalizing the recording).
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
	_restore_settings()


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
