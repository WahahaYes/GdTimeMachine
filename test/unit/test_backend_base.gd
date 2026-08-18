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
	pass


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
