@tool
extends GutTest


## Fake backend for controller tests.
class FakeBackend:
	extends RecorderBackend
	signal availability_changed(available: bool)

	var _name: String = "Fake Backend"
	var _available: bool = true
	var _recording: bool = false
	var _capture_mode: RecorderBackend.CaptureMode = RecorderBackend.CaptureMode.RESTART_SCENE
	var _start_config: Dictionary
	var _start_called: bool = false
	var _stop_called: bool = false
	var _should_emit_started: bool = true
	var _should_emit_stopped: bool = true
	var _should_emit_error: bool = false
	var _error_message: String = "Test error"

	func _init(
		name: String = "Fake Backend",
		available: bool = true,
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

	func start(config: Dictionary) -> void:
		_start_config = config
		_start_called = true
		_recording = true
		if _should_emit_started:
			recording_started.emit(_name, config.get("output_path", "test_path"))
		if _should_emit_error:
			recording_error.emit(_name, _error_message)
			_recording = false

	func stop() -> void:
		_stop_called = true
		if _recording and _should_emit_stopped:
			recording_stopped.emit(_name, _start_config.get("output_path", "test_path"))
		_recording = false

	func set_availability(available: bool) -> void:
		_available = available
		if has_signal("availability_changed"):
			availability_changed.emit(available)

	func set_should_emit_started(emit: bool) -> void:
		_should_emit_started = emit

	func set_should_emit_stopped(emit: bool) -> void:
		_should_emit_stopped = emit

	func set_should_emit_error(emit: bool, msg: String = "Error") -> void:
		_should_emit_error = emit
		_error_message = msg


## Tests use member variables to capture signal payloads: GDScript lambdas
## capture outer locals BY VALUE in this Godot version, so a lambda writing a
## captured local cannot be read back. Members (written through self) work.
var _captured_bool := false
var _captured_name := ""
var _captured_path := ""
var _captured_msg := ""


func before_each() -> void:
	_captured_bool = false
	_captured_name = ""
	_captured_path = ""
	_captured_msg = ""


func make_controller() -> RecorderController:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	return controller


## Backend registration tests


func test_register_backend_accepts_valid_backend() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test Backend")
	controller.register_backend(backend)
	assert_eq(controller.get_backend_names(), ["Test Backend"])
	assert_eq(controller.active_backend, backend)


func test_register_backend_rejects_null() -> void:
	var controller := make_controller()
	controller.register_backend(null)
	assert_push_warning("Cannot register a null backend")
	assert_eq(controller.get_backend_names(), [])


func test_register_backend_rejects_empty_name() -> void:
	var controller := make_controller()
	var backend: FakeBackend = autofree(FakeBackend.new(""))
	controller.register_backend(backend)
	assert_push_warning("empty name")
	assert_eq(controller.get_backend_names(), [])


func test_register_backend_replaces_duplicate() -> void:
	var controller := make_controller()
	var b1 := FakeBackend.new("Same Name")
	var b2 := FakeBackend.new("Same Name")
	controller.register_backend(b1)
	controller.register_backend(b2)
	assert_push_warning("already registered")
	assert_eq(controller.get_backend_names(), ["Same Name"])
	assert_eq(controller.active_backend, b2)
	if is_instance_valid(b1) and b1.get_parent() == null:
		b1.free()


func test_unregister_backend_removes_and_reselects() -> void:
	var controller := make_controller()
	var b1 := FakeBackend.new("Backend 1")
	var b2 := FakeBackend.new("Backend 2")
	controller.register_backend(b1)
	controller.register_backend(b2)
	controller.unregister_backend("Backend 1")
	assert_eq(controller.get_backend_names(), ["Backend 2"])
	assert_eq(controller.active_backend, b2)
	if is_instance_valid(b1) and b1.get_parent() == null:
		b1.free()


func test_unregister_backend_warns_unknown() -> void:
	# Unregistering an unknown name warns but must not disturb registrations.
	var controller := make_controller()
	var b1 := FakeBackend.new("Backend 1")
	controller.register_backend(b1)
	controller.unregister_backend("Unknown")
	assert_push_warning("Cannot unregister unknown backend")
	assert_eq(controller.get_backend_names(), ["Backend 1"])
	assert_eq(controller.active_backend, b1)


func test_select_backend_switches_and_emits() -> void:
	var controller := make_controller()
	var b1 := FakeBackend.new("Backend 1")
	var b2 := FakeBackend.new("Backend 2")
	controller.register_backend(b1)
	controller.register_backend(b2)
	controller.backend_changed.connect(
		func(name: String) -> void:
			_captured_bool = true
			_captured_name = name
	)
	controller.select_backend("Backend 2")
	assert_true(_captured_bool)
	assert_eq(_captured_name, "Backend 2")
	assert_eq(controller.active_backend, b2)


func test_select_backend_noop_when_already_active() -> void:
	var controller := make_controller()
	var b1 := FakeBackend.new("Backend 1")
	controller.register_backend(b1)
	controller.backend_changed.connect(func(_name: String) -> void: _captured_bool = true)
	controller.select_backend("Backend 1")
	assert_false(_captured_bool)


func test_select_backend_warns_unknown() -> void:
	var controller := make_controller()
	var b1 := FakeBackend.new("Backend 1")
	controller.register_backend(b1)
	controller.select_backend("Unknown")
	assert_push_warning("Unknown backend")
	assert_eq(controller.active_backend, b1)


## Availability forwarding tests


func test_is_backend_available_delegates() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test", true)
	controller.register_backend(backend)
	assert_true(controller.is_backend_available("Test"))
	backend.set_availability(false)
	assert_false(controller.is_backend_available("Test"))


func test_backend_availability_changed_forwarded() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test", true)
	controller.register_backend(backend)
	controller.backend_availability_changed.connect(
		func(_name: String, available: bool) -> void: _captured_bool = available
	)
	backend.set_availability(false)
	assert_false(_captured_bool)


## Capture mode propagation


func test_get_capture_mode_returns_active_backend_mode() -> void:
	var controller := make_controller()
	var b1 := FakeBackend.new("Backend 1", true, RecorderBackend.CaptureMode.RESTART_SCENE)
	var b2 := FakeBackend.new("Backend 2", true, RecorderBackend.CaptureMode.IN_PLACE)
	controller.register_backend(b1)
	controller.register_backend(b2)
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)
	controller.select_backend("Backend 2")
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)


func test_get_capture_mode_defaults_when_no_backend() -> void:
	var controller := make_controller()
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)


## Start/stop recording routing


func test_start_recording_routes_config_to_active_backend() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	var config := {
		"output_path": "res://out.avi",
		"fps": 60,
		"duration": 10.0,
		"scene_path": "res://scene.tscn",
		"fullscreen": true
	}
	controller.start_recording(config)
	assert_true(backend._start_called)
	assert_eq(backend._start_config, config)


func test_start_recording_emits_error_when_no_backend() -> void:
	var controller := make_controller()
	controller.recording_error.connect(
		func(_name: String, _msg: String) -> void: _captured_bool = true
	)
	controller.start_recording({})
	assert_push_warning("No backend selected")
	assert_true(_captured_bool)


func test_start_recording_warns_when_already_recording() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	backend._recording = true
	controller.register_backend(backend)
	controller.start_recording({})
	assert_push_warning("already recording")
	assert_false(backend._start_called)


func test_stop_recording_calls_backend_stop() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	backend._recording = true
	controller.register_backend(backend)
	var result := controller.stop_recording()
	assert_true(result)
	assert_true(backend._stop_called)


func test_stop_recording_returns_false_when_no_backend() -> void:
	var controller := make_controller()
	assert_false(controller.stop_recording())


func test_stop_recording_returns_false_when_not_recording() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	assert_false(controller.stop_recording())


## Signal forwarding tests


func test_recording_started_forwarded() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	controller.recording_started.connect(
		func(name: String, path: String) -> void:
			_captured_name = name
			_captured_path = path
	)
	backend.recording_started.emit("Test", "res://out.avi")
	assert_eq(_captured_name, "Test")
	assert_eq(_captured_path, "res://out.avi")


func test_recording_stopped_forwarded() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	controller.recording_stopped.connect(
		func(_name: String, path: String) -> void: _captured_path = path
	)
	backend.recording_stopped.emit("Test", "res://out.avi")
	assert_eq(_captured_path, "res://out.avi")


func test_recording_error_forwarded() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	controller.recording_error.connect(
		func(_name: String, msg: String) -> void: _captured_msg = msg
	)
	backend.recording_error.emit("Test", "Something failed")
	assert_eq(_captured_msg, "Something failed")


func test_recording_notice_forwarded() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	controller.recording_notice.connect(
		func(_name: String, msg: String) -> void: _captured_msg = msg
	)
	backend.recording_notice.emit("Test", "Notice message")
	assert_eq(_captured_msg, "Notice message")


func test_recording_converted_forwarded_when_backend_has_signal() -> void:
	var controller := make_controller()
	var backend := FakeBackend.new("Test")
	controller.register_backend(backend)
	controller.recording_converted.connect(
		func(_name: String, path: String) -> void: _captured_path = path
	)
	backend.recording_converted.emit("Test", "res://converted.mp4")
	assert_eq(_captured_path, "res://converted.mp4")
