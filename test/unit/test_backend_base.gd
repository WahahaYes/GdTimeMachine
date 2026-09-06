@tool
extends GutTest


## Concrete implementation for testing base class defaults.
class TestBackend:
	extends RecorderBackend
	var _name: String = "Test Backend"
	var _available: bool = false
	var _recording: bool = false
	var _capture_mode: RecorderBackend.CaptureMode = RecorderBackend.CaptureMode.RESTART_SCENE

	func _init(
		name: String = "Test Backend",
		available: bool = false,
		capture_mode: RecorderBackend.CaptureMode = RecorderBackend.CaptureMode.RESTART_SCENE
	) -> void:
		_name = name
		_available = available
		_capture_mode = capture_mode

	func get_backend_name() -> String:
		return _name

	func is_available() -> bool:
		return _available

	func is_recording() -> bool:
		return _recording

	func get_capture_mode() -> RecorderBackend.CaptureMode:
		return _capture_mode


func before_each() -> void:
	for key in [
		"transcoders/active",
		"transcoders/ffmpeg/auto_convert",
		"gd_time_machine/ffmpeg/auto_convert",
		"transcoders/ffmpeg/clean_frames",
		"gd_time_machine/ffmpeg/clean_frames",
	]:
		if ProjectSettings.has_setting(key):
			ProjectSettings.clear(key)


## Abstract defaults tests


func test_get_backend_name_default_empty() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_eq(backend.get_backend_name(), "")


func test_get_description_default_empty() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_eq(backend.get_description(), "")


func test_is_available_default_false() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_false(backend.is_available())


func test_unavailable_reason_default_generic() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_false(backend.get_unavailable_reason().is_empty())


func test_runtime_hint_default_empty() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_true(backend.get_runtime_hint().is_empty())


func test_install_hint_default_empty() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_true(backend.get_install_hint().is_empty())


func test_auto_convert_prefers_config_then_section_then_legacy() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_true(backend._get_auto_convert_setting({}), "default true")
	ProjectSettings.set_setting("gd_time_machine/ffmpeg/auto_convert", false)
	assert_false(backend._get_auto_convert_setting({}), "legacy key honored")
	ProjectSettings.set_setting("transcoders/ffmpeg/auto_convert", true)
	assert_true(backend._get_auto_convert_setting({}), "section wins over legacy")
	assert_false(
		backend._get_auto_convert_setting({"auto_convert": false}),
		"config override wins over everything"
	)


func test_clean_frames_resolves_from_section() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_true(backend._get_clean_on_success_setting(), "default true")
	ProjectSettings.set_setting("transcoders/ffmpeg/clean_frames", false)
	assert_false(backend._get_clean_on_success_setting())


func test_active_transcoder_name_defaults_and_reads_list() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_eq(backend._active_transcoder_name(), "ffmpeg")
	ProjectSettings.set_setting("transcoders/active", ["handbrake", "ffmpeg"])
	assert_eq(backend._active_transcoder_name(), "handbrake")


func test_format_interface_defaults_follow_capture_mode() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_true(backend.get_native_formats().is_empty())
	assert_true(backend.get_native_artifact().is_empty())
	# No artifact and no registry: deliverable = natives only (empty here),
	# and every format conservatively needs a transcoder.
	assert_true(backend.get_supported_formats().is_empty())
	assert_false(backend.is_format_supported(GdTMOutputFormat.Format.MP4))
	assert_true(backend.format_needs_ffmpeg(GdTMOutputFormat.Format.MP4))
	assert_true(backend.format_needs_ffmpeg(GdTMOutputFormat.Format.AVI))


func test_is_recording_default_false() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_false(backend.is_recording())


func test_get_capture_mode_defaults_to_restart_scene() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)


func test_start_default_noop() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	backend.start({})  # Should not crash
	assert_false(backend.is_recording())


func test_stop_default_noop() -> void:
	var backend: RecorderBackend = autofree(RecorderBackend.new())
	backend.stop()  # Should not crash
	assert_false(backend.is_recording())


## Concrete subclass tests


func test_concrete_backend_name() -> void:
	var backend: TestBackend = autofree(TestBackend.new("Custom Name"))
	assert_eq(backend.get_backend_name(), "Custom Name")


func test_concrete_backend_availability() -> void:
	var backend: TestBackend = autofree(TestBackend.new("Test", true))
	assert_true(backend.is_available())
	var backend2: TestBackend = autofree(TestBackend.new("Test", false))
	assert_false(backend2.is_available())


func test_concrete_backend_recording_state() -> void:
	var backend: TestBackend = autofree(TestBackend.new("Test"))
	backend._recording = true
	assert_true(backend.is_recording())
	backend._recording = false
	assert_false(backend.is_recording())


func test_concrete_backend_capture_mode_in_place() -> void:
	var backend: TestBackend = autofree(
		TestBackend.new("Test", true, RecorderBackend.CaptureMode.IN_PLACE)
	)
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)


func test_concrete_backend_capture_mode_restart_scene() -> void:
	var backend: TestBackend = autofree(
		TestBackend.new("Test", true, RecorderBackend.CaptureMode.RESTART_SCENE)
	)
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)


## Signal declaration tests


func test_signals_declared() -> void:
	var backend: TestBackend = autofree(TestBackend.new())
	assert_true(backend.has_signal("recording_started"))
	assert_true(backend.has_signal("recording_stopped"))
	assert_true(backend.has_signal("recording_error"))
	assert_true(backend.has_signal("recording_notice"))
	assert_true(backend.has_signal("recording_converted"))
