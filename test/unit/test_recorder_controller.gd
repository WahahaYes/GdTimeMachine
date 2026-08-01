extends GutTest

# Mock backend exercising the RecorderBackend contract. Because it is an
# inner class it is not collected by GUT as a test script.
class MockBackend extends RecorderBackend:
	var display_name := "Mock"
	var available := true
	var recording := false
	var started_config: Dictionary = {}
	var stopped_calls := 0
	var emit_started_on_start := false

	func get_backend_name() -> String:
		return display_name

	func get_description() -> String:
		return "Mock backend for tests"

	func is_available() -> bool:
		return available

	func is_recording() -> bool:
		return recording

	func start(config: Dictionary) -> void:
		started_config = config
		recording = true
		if emit_started_on_start:
			recording_started.emit(display_name, str(config.get("output_path", "")))

	func stop() -> void:
		stopped_calls += 1
		recording = false


func _make_backend(display_name := "Mock") -> MockBackend:
	var backend := MockBackend.new()
	backend.display_name = display_name
	return backend


func test_register_backend_sets_active_when_none() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	assert_same(controller.active_backend, backend)
	assert_eq(controller.get_backend_names(), ["Mock"])


func test_register_null_backend_ignored() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	controller.register_backend(null)
	assert_eq(controller.backends.size(), 0)
	assert_null(controller.active_backend)


func test_register_empty_name_ignored() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	controller.register_backend(_make_backend(""))
	assert_eq(controller.backends.size(), 0)


func test_register_duplicate_name_replaces() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var first := _make_backend()
	var second := _make_backend()
	controller.register_backend(first)
	controller.register_backend(second)
	assert_eq(controller.backends.size(), 1)
	assert_same(controller.backends["Mock"], second)


func test_select_backend_switches_and_emits() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var a := _make_backend("A")
	var b := _make_backend("B")
	controller.register_backend(a)
	controller.register_backend(b)
	var changed: Array = []
	controller.backend_changed.connect(func(name): changed.append(name))
	controller.select_backend("B")
	assert_same(controller.active_backend, b)
	assert_eq(changed, ["B"])


func test_select_unknown_backend_fails_gracefully() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var a := _make_backend("A")
	controller.register_backend(a)
	controller.select_backend("nonexistent")
	assert_same(controller.active_backend, a)


func test_start_recording_routes_config_to_backend() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	controller.start_recording({"output_path": "res://media/captures/x.avi"})
	assert_true(backend.recording)
	assert_eq(backend.started_config.get("output_path"), "res://media/captures/x.avi")
	assert_true(controller.is_recording())


func test_start_recording_with_no_backend_emits_error() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var received: Array = []
	controller.recording_error.connect(func(name, message): received.append([name, message]))
	controller.start_recording({})
	assert_eq(received.size(), 1)


func test_recording_started_signal_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	backend.emit_started_on_start = true
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_started.connect(func(name, path): received.append([name, path]))
	controller.start_recording({"output_path": "res://media/captures/x.avi"})
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", "res://media/captures/x.avi"])


func test_recording_stopped_signal_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_stopped.connect(func(name, path): received.append([name, path]))
	backend.recording_stopped.emit(backend.get_backend_name(), "res://media/captures/x.avi")
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", "res://media/captures/x.avi"])


func test_recording_progress_signal_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_progress.connect(func(name, elapsed): received.append([name, elapsed]))
	backend.recording_progress.emit(backend.get_backend_name(), 12.5)
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", 12.5])


func test_recording_error_signal_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_error.connect(func(name, message): received.append([name, message]))
	backend.recording_error.emit(backend.get_backend_name(), "boom")
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", "boom"])


func test_stop_recording_returns_bool_and_stops_backend() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	assert_false(controller.stop_recording())
	controller.start_recording({})
	assert_true(controller.stop_recording())
	assert_eq(backend.stopped_calls, 1)
	assert_false(controller.is_recording())
	assert_false(controller.stop_recording())


func test_unregister_backend_removes_and_selects_remaining() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var a := _make_backend("A")
	var b := _make_backend("B")
	controller.register_backend(a)
	controller.register_backend(b)
	controller.select_backend("B")
	controller.unregister_backend("B")
	assert_eq(controller.backends.size(), 1)
	assert_same(controller.active_backend, a)
	# Unregistered backend no longer forwards signals to the controller.
	var received: Array = []
	controller.recording_error.connect(func(name, message): received.append([name, message]))
	b.recording_error.emit("B", "ghost")
	assert_eq(received.size(), 0)
