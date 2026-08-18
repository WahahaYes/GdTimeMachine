@tool
extends GutTest


## Fake EditorInterface for Movie Maker tests.
class FakeEditorInterface:
	var _movie_maker_enabled: bool = false
	var _playing_scene: bool = false
	var _movie_file: Variant = null
	var _movie_fps: Variant = null

	static var _instance: FakeEditorInterface = null

	static func get_singleton() -> FakeEditorInterface:
		if _instance == null:
			_instance = FakeEditorInterface.new()
		return _instance

	func is_movie_maker_enabled() -> bool:
		return _movie_maker_enabled

	func set_movie_maker_enabled(enabled: bool) -> void:
		_movie_maker_enabled = enabled

	func is_playing_scene() -> bool:
		return _playing_scene

	func play_current_scene() -> void:
		_playing_scene = true

	func play_custom_scene(scene_path: String) -> void:
		_playing_scene = true

	func stop_playing_scene() -> void:
		_playing_scene = false

	func get_movie_file() -> Variant:
		return _movie_file

	func set_movie_file(path: Variant) -> void:
		_movie_file = path

	func get_movie_fps() -> Variant:
		return _movie_fps

	func set_movie_fps(fps: Variant) -> void:
		_movie_fps = fps

	static func reset() -> void:
		_instance = null


## Fake ProjectSettings for Movie Maker tests.
class FakeProjectSettings:
	var _settings: Dictionary = {}

	static var _instance: FakeProjectSettings = null

	static func get_singleton() -> FakeProjectSettings:
		if _instance == null:
			_instance = FakeProjectSettings.new()
		return _instance

	func has_setting(key: String) -> bool:
		return _settings.has(key)

	func get_setting(key: String) -> Variant:
		return _settings.get(key)

	func set_setting(key: String, value: Variant) -> void:
		_settings[key] = value

	func globalize_path(path: String) -> String:
		if path.begins_with("res://"):
			return "/fake/project" + path.substr(5)
		return path

	static func reset() -> void:
		_instance = null


## Fake FileAccess for size checking.
class FakeFileAccess:
	var _files: Dictionary = {}
	var _open_path: String = ""

	static var _instance: FakeFileAccess = null

	static func get_singleton() -> FakeFileAccess:
		if _instance == null:
			_instance = FakeFileAccess.new()
		return _instance

	func open(path: String, mode: int) -> FakeFileAccess:
		if _files.has(path):
			_open_path = path
			return self
		return null

	func get_length() -> int:
		return _files.get(_open_path, 0)

	func close() -> void:
		pass

	static func set_file_size(path: String, size: int) -> void:
		if _instance != null:
			_instance._files[path] = size

	static func reset() -> void:
		_instance = null


## Fake Timer for Movie Maker tests.
class FakeTimer:
	var _wait_time: float = 1.0
	var _one_shot: bool = true
	var _autostart: bool = false
	var _running: bool = false
	var _timeout_callback: Callable = Callable()

	func start(seconds: float) -> void:
		_wait_time = seconds
		_running = true

	func stop() -> void:
		_running = false

	func is_stopped() -> bool:
		return not _running

	func connect_timeout(sig: String, callable: Callable) -> void:
		if sig == "timeout":
			_timeout_callback = callable

	func emit_timeout() -> void:
		if _timeout_callback.is_valid():
			_timeout_callback.call()


## Fake FFmpeg converter for tier-2 tests.
class FakeFFmpegConvert:
	extends GdTMFFmpegConvert
	var _convert_called: bool = false
	var _convert_args: Array = []
	var _should_succeed: bool = true
	var _success_path: String = ""
	var _error_message: String = "ffmpeg error"
	var _stderr_tail: String = ""

	func convert_file_async(
		intermediate: String, final: String, delete_intermediate: bool = false, fps: int = 0
	) -> void:
		_convert_called = true
		_convert_args = [intermediate, final, delete_intermediate, fps]
		if _should_succeed:
			conversion_succeeded.emit(_success_path)
		else:
			conversion_failed.emit(_error_message, _stderr_tail)

	func wait_for_completion() -> void:
		pass


## Testable Movie Maker backend with injected dependencies.
class TestableMovieMaker:
	extends BackendMovieMaker
	var _fake_editor: FakeEditorInterface
	var _fake_project_settings: FakeProjectSettings
	var _fake_file_access: FakeFileAccess
	var _fake_timer_factory: Callable
	var _fake_ffmpeg_factory: Callable
	var _grace_period_override: float = 0.1
	var _output_file_size: int = 0

	func _init() -> void:
		_fake_editor = FakeEditorInterface.get_singleton()
		_fake_project_settings = FakeProjectSettings.get_singleton()
		_fake_file_access = FakeFileAccess.get_singleton()

	func _get_editor_interface() -> Object:
		return _fake_editor

	func _get_project_settings() -> Object:
		return _fake_project_settings

	func _create_ffmpeg_converter() -> GdTMFFmpegConvert:
		if _fake_ffmpeg_factory.is_valid():
			return _fake_ffmpeg_factory.call()
		return super._create_ffmpeg_converter()

	func _get_grace_period() -> float:
		return _grace_period_override

	func _get_output_file_size() -> int:
		return _output_file_size

	func _get_movie_file() -> Variant:
		return _fake_editor.get_movie_file()

	func _get_movie_fps() -> Variant:
		return _fake_editor.get_movie_fps()

	func _set_movie_file(path: String) -> void:
		_fake_editor.set_movie_file(path)

	func _set_movie_file_no_restore(path: String) -> void:
		_fake_editor.set_movie_file(path)

	func _clear_movie_file() -> void:
		_fake_editor.set_movie_file(null)

	func _set_movie_fps(fps: int) -> void:
		_fake_editor.set_movie_fps(fps)

	func _set_movie_fps_no_restore(fps: int) -> void:
		_fake_editor.set_movie_fps(fps)

	func _clear_movie_fps() -> void:
		_fake_editor.set_movie_fps(null)

	func _set_movie_maker_enabled(enabled: bool) -> void:
		_fake_editor.set_movie_maker_enabled(enabled)

	func _is_movie_maker_enabled() -> bool:
		return _fake_editor.is_movie_maker_enabled()

	func _is_playing_scene() -> bool:
		return _fake_editor.is_playing_scene()

	func _play_scene(scene_path: String) -> void:
		_fake_editor.play_custom_scene(scene_path)

	func _stop_playing_scene() -> void:
		_fake_editor.stop_playing_scene()

	func _send_graceful_stop_message() -> void:
		if _debugger_plugin != null and _debugger_plugin.has_method("send_graceful_stop"):
			_debugger_plugin.send_graceful_stop()


func before_each() -> void:
	FakeEditorInterface.reset()
	FakeProjectSettings.reset()
	FakeFileAccess.reset()
	_captured_started = false
	_captured_started_path = ""
	_captured_stopped_count = 0
	_captured_error = false
	_captured_notice = false
	_captured_converted = false
	_captured_converted_path = ""


## Tests use member variables to capture signal payloads: GDScript lambdas
## capture outer locals BY VALUE in this Godot version, so a lambda writing a
## captured local cannot be read back. Members (written through self) work.
var _captured_started := false
var _captured_started_path := ""
var _captured_stopped_count := 0
var _captured_error := false
var _captured_notice := false
var _captured_converted := false
var _captured_converted_path := ""

## Basic contract tests


func test_get_backend_name() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	assert_eq(backend.get_backend_name(), "Godot Movie Maker")


func test_get_description_contains_key_terms() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	var desc: String = backend.get_description()
	assert_true(desc.contains("Built-in"))
	assert_true(desc.contains("Fixed-fps") or desc.contains("fixed-fps"))


func test_is_available_always_true() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	assert_true(backend.is_available())


func test_get_capture_mode_restart_scene() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)


## Start flow tests


func test_start_sets_active_and_pending() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._grace_period_override = 0.1
	backend.start({"output_path": "res://test.avi", "fps": 60, "duration": 5.0})
	assert_true(backend.is_recording())
	assert_eq(backend._pending_start, true)
	assert_eq(backend._active, true)


func test_start_configures_movie_maker_settings() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend.start({"output_path": "res://test.avi", "fps": 30})
	assert_eq(backend._fake_editor.get_movie_file(), "res://test.avi")
	assert_eq(backend._fake_editor.get_movie_fps(), 30)
	assert_true(backend._fake_editor.is_movie_maker_enabled())


func test_start_snapshots_prev_settings() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._fake_editor.set_movie_file("res://prev.avi")
	backend._fake_editor.set_movie_fps(24)
	backend.start({"output_path": "res://test.avi", "fps": 60})
	assert_eq(backend._prev_movie_file, "res://prev.avi")
	assert_eq(backend._prev_fps, 24)


func test_start_tier2_uses_avi_intermediate() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend.start({"output_path": "res://test.mp4", "fps": 60, "output_format": "mp4"})
	assert_true(backend._output_path.ends_with(".avi"))
	assert_eq(backend._target_output_format, "mp4")


func test_start_webm_uses_avi_intermediate() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend.start({"output_path": "res://test.webm", "fps": 60, "output_format": "webm"})
	assert_true(backend._output_path.ends_with(".avi"))
	assert_eq(backend._target_output_format, "webm")


func test_start_default_output_path_when_empty() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend.start({"fps": 60})
	assert_eq(backend._output_path, "res://movie.avi")


func test_start_warns_when_already_recording() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._output_path = "res://preset.avi"
	backend.start({"output_path": "res://test.avi"})
	assert_push_warning("already recording")
	# Already active: start must be a no-op (warn only), not re-enable
	# or clobber the in-flight session's output path.
	assert_true(backend.is_recording())
	assert_eq(backend._output_path, "res://preset.avi")


## Poll timeout tests


func test_poll_detects_playback_start_emits_started() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend.start({"output_path": "res://test.avi", "fps": 60, "duration": 5.0})
	backend.recording_started.connect(
		func(_name: String, path: String) -> void:
			_captured_started = true
			_captured_started_path = path
	)
	backend._fake_editor._playing_scene = true
	backend._on_poll_timeout()
	assert_true(_captured_started)
	assert_eq(_captured_started_path, "res://test.avi")
	assert_false(backend._pending_start)


func test_poll_while_recording_checks_avi_size() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._pending_start = false
	backend._output_path = "res://test.avi"
	backend._output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES + 100
	backend._fake_editor._playing_scene = true
	backend._on_poll_timeout()
	assert_true(backend._stopped_for_size_limit)


func test_poll_natural_scene_exit_finalizes() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._pending_start = false
	backend._output_path = "res://test.avi"
	backend._fake_editor._playing_scene = false
	backend.recording_stopped.connect(
		func(_name: String, _path: String) -> void: _captured_stopped_count += 1
	)
	backend._on_poll_timeout()
	assert_eq(_captured_stopped_count, 1)
	assert_false(backend._active)


## Duration timeout tests


func test_duration_timeout_before_playback_emits_error() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._grace_period_override = 0.1
	backend.start({"output_path": "res://test.avi", "fps": 60, "duration": 5.0})
	backend.recording_error.connect(
		func(_name: String, msg: String) -> void:
			_captured_error = true
			assert_true(msg.contains("Scene did not start"))
	)
	backend._on_duration_timeout()
	assert_true(_captured_error)
	assert_false(backend._active)


func test_duration_timeout_after_playback_triggers_stop() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	var mock_debugger := FakeDebuggerPlugin.new()
	backend._debugger_plugin = mock_debugger
	backend._grace_period_override = 0.1
	backend._active = true
	backend._pending_start = false
	backend._output_path = "res://test.avi"
	backend._fake_editor._playing_scene = true
	backend._on_duration_timeout()
	assert_true(backend._stopping)
	# Playback started, so duration expiry triggers a graceful stop:
	# the game is asked to quit (graceful-stop message) and the session
	# stays pending finalization until the poll observes the exit.
	assert_true(mock_debugger.graceful_stop_called)


## Stop flow tests


func test_stop_sends_graceful_stop_and_starts_grace_timer() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._grace_period_override = 0.1
	backend._active = true
	backend._pending_start = false
	backend._output_path = "res://test.avi"
	backend._fake_editor._playing_scene = true
	var mock_debugger := FakeDebuggerPlugin.new()
	backend._debugger_plugin = mock_debugger
	backend.stop()
	assert_true(backend._stopping)
	assert_true(mock_debugger.graceful_stop_called)


func test_stop_idempotent_when_already_stopping() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	var mock_debugger := FakeDebuggerPlugin.new()
	backend._debugger_plugin = mock_debugger
	backend._grace_period_override = 0.1
	backend._active = true
	backend._pending_start = false
	backend._stopping = true
	backend.stop()
	# Already gracefully stopping: must not re-send the graceful-stop
	# request or finalize the session.
	assert_false(mock_debugger.graceful_stop_called)
	assert_true(backend.is_recording())


## Grace timeout tests


func test_grace_timeout_force_stops_and_finalizes() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._grace_period_override = 0.1
	backend._active = true
	backend._stopping = true
	backend._output_path = "res://test.avi"
	backend._fake_editor._playing_scene = true
	backend.recording_stopped.connect(
		func(_name: String, _path: String) -> void: _captured_stopped_count += 1
	)
	backend._on_grace_timeout()
	assert_eq(_captured_stopped_count, 1)
	assert_false(backend._fake_editor.is_playing_scene())


func test_grace_timeout_noop_when_not_stopping() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._grace_period_override = 0.1
	backend._active = true
	backend._stopping = false
	backend._fake_editor._playing_scene = true
	backend._on_grace_timeout()
	# Should not call _stop_playing_scene
	assert_true(backend._fake_editor.is_playing_scene())


## Finalize tests


func test_finalize_emits_stopped_once() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._output_path = "res://test.avi"
	backend.recording_stopped.connect(
		func(_name: String, _path: String) -> void: _captured_stopped_count += 1
	)
	backend._finalize_stopped()
	backend._finalize_stopped()  # Second call should be no-op
	assert_eq(_captured_stopped_count, 1)


func test_finalize_restores_prev_settings() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._prev_movie_file = "res://prev.avi"
	backend._prev_fps = 24
	backend._output_path = "res://test.avi"
	backend._finalize_stopped()
	assert_eq(backend._fake_editor.get_movie_file(), "res://prev.avi")
	assert_eq(backend._fake_editor.get_movie_fps(), 24)


func test_finalize_clears_settings_when_no_prev() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._prev_movie_file = null
	backend._prev_fps = null
	backend._output_path = "res://test.avi"
	backend._finalize_stopped()
	assert_eq(backend._fake_editor.get_movie_file(), null)
	assert_eq(backend._fake_editor.get_movie_fps(), null)


func test_finalize_disables_movie_maker() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._fake_editor.set_movie_maker_enabled(true)
	backend._output_path = "res://test.avi"
	backend._finalize_stopped()
	assert_false(backend._fake_editor.is_movie_maker_enabled())


func test_finalize_emits_size_limit_notice() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._stopped_for_size_limit = true
	backend._output_path = "res://test.avi"
	backend.recording_notice.connect(
		func(_name: String, msg: String) -> void:
			_captured_notice = true
			assert_true(msg.contains("4 GB"))
	)
	backend._finalize_stopped()
	assert_true(_captured_notice)


## Tier-2 conversion tests


func test_finalize_triggers_ffmpeg_convert_for_mp4() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._target_output_format = "mp4"
	backend._auto_convert_enabled = true
	backend._intermediate_path = "res://test.avi"
	backend._final_output_path = "res://test.mp4"
	backend._output_path = "res://test.avi"
	var fake_ffmpeg: FakeFFmpegConvert = autofree(FakeFFmpegConvert.new())
	fake_ffmpeg._success_path = "res://test.mp4"
	backend._fake_ffmpeg_factory = func() -> Object: return fake_ffmpeg
	backend._finalize_stopped()
	assert_true(fake_ffmpeg._convert_called)


func test_finalize_triggers_ffmpeg_convert_for_webm() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._target_output_format = "webm"
	backend._auto_convert_enabled = true
	backend._intermediate_path = "res://test.avi"
	backend._final_output_path = "res://test.webm"
	backend._output_path = "res://test.avi"
	var fake_ffmpeg: FakeFFmpegConvert = autofree(FakeFFmpegConvert.new())
	fake_ffmpeg._success_path = "res://test.webm"
	backend._fake_ffmpeg_factory = func() -> Object: return fake_ffmpeg
	backend._finalize_stopped()
	assert_true(fake_ffmpeg._convert_called)


func test_finalize_skips_conversion_when_disabled() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	backend._target_output_format = "mp4"
	backend._auto_convert_enabled = false
	backend._intermediate_path = "res://test.avi"
	backend._output_path = "res://test.avi"
	var fake_ffmpeg: FakeFFmpegConvert = autofree(FakeFFmpegConvert.new())
	backend._fake_ffmpeg_factory = func() -> Object: return fake_ffmpeg
	backend._finalize_stopped()
	assert_false(fake_ffmpeg._convert_called)


func test_ffmpeg_convert_succeeded_emits_converted_and_notice() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._stopping = true
	var fake_ffmpeg: FakeFFmpegConvert = autofree(FakeFFmpegConvert.new())
	fake_ffmpeg._success_path = "res://test.mp4"
	backend._fake_ffmpeg_factory = func() -> Object: return fake_ffmpeg
	backend._intermediate_path = "res://test.avi"
	backend._final_output_path = "res://test.mp4"
	backend._output_path = "res://test.avi"
	backend._target_output_format = "mp4"
	backend._auto_convert_enabled = true
	backend.recording_converted.connect(
		func(_name: String, path: String) -> void:
			_captured_converted = true
			_captured_converted_path = path
	)
	backend._finalize_stopped()
	assert_true(_captured_converted)
	assert_eq(_captured_converted_path, "res://test.mp4")


## AVI size guard tests


func test_avi_size_limit_guard_triggers_stop() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._pending_start = false
	backend._output_path = "res://test.avi"
	backend._output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES + 1
	backend._check_avi_size_limit()
	assert_true(backend._stopped_for_size_limit)
	assert_true(backend._stopping)


func test_avi_size_limit_noop_for_non_avi() -> void:
	var backend: TestableMovieMaker = autofree(TestableMovieMaker.new())
	backend._active = true
	backend._pending_start = false
	backend._output_path = "res://test.mp4"
	backend._output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES + 1
	backend._check_avi_size_limit()
	# The RIFF 4 GB cap only applies while the engine writes an AVI
	# (native .avi or the tier-2 intermediate); a non-AVI path must skip.
	assert_false(backend._stopped_for_size_limit)


## Fake debugger plugin
class FakeDebuggerPlugin:
	var graceful_stop_called: bool = false

	func send_graceful_stop() -> void:
		graceful_stop_called = true
