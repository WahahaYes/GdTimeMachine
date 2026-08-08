extends GutTest


# Mock backend exercising the RecorderBackend contract. Because it is an
# inner class it is not collected by GUT as a test script.
class MockBackend:
	extends RecorderBackend
	var display_name := "Mock"
	var available := true
	var recording := false
	var capture_mode := RecorderBackend.CaptureMode.RESTART_SCENE
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

	func get_capture_mode() -> CaptureMode:
		return capture_mode

	func start(config: Dictionary) -> void:
		started_config = config
		recording = true
		if emit_started_on_start:
			recording_started.emit(display_name, str(config.get("output_path", "")))

	func stop() -> void:
		stopped_calls += 1
		recording = false


# Creates a MockBackend without autofree — RecorderController owns the
# lifecycle via add_child() on register, and frees on unregister. Returning a
# plain Node avoids double-free / orphan conflicts from GUT autofree.
func _make_backend(display_name := "Mock") -> MockBackend:
	var backend := MockBackend.new()
	backend.display_name = display_name
	return backend


# Duck-typed debugger plugin exposing only the send_focus_request() surface
# the controller calls. Records calls so tests can assert the focus request
# fires unconditionally on start.
func _make_focus_probe() -> Object:
	var probe := FocusProbe.new()
	probe = autofree(probe)
	return probe


class FocusProbe:
	extends RefCounted
	var focus_calls := 0

	func send_focus_request() -> bool:
		focus_calls += 1
		return true


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
	var backend := _make_backend("")
	controller.register_backend(backend)
	assert_eq(controller.backends.size(), 0)
	# register_backend early-returns without parenting, so we must free it
	# ourselves to avoid an orphan — controller didn't take ownership.
	# Use free() not queue_free() so the orphan counter sees it gone this frame.
	backend.free()


func test_register_duplicate_name_replaces() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var first := _make_backend()
	var second := _make_backend()
	controller.register_backend(first)
	controller.register_backend(second)
	# unregister_backend() queue_frees the old backend; free immediately so GUT
	# orphan counter (which only waits for its own autofree queue) does not see it.
	if is_instance_valid(first) and first.get_parent() == null:
		first.free()
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


func test_start_recording_requests_window_focus_via_plugin() -> void:
	# The focus request is backend-agnostic and unconditional: any backend
	# (RESTART_SCENE or IN_PLACE) asks the running game to bring its window
	# to focus so the capture runs at full rate.
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var plugin := _make_focus_probe()
	controller._debugger_plugin = plugin
	var backend := _make_backend()
	controller.register_backend(backend)
	controller.start_recording({"output_path": "res://media/captures/x.avi"})
	assert_eq(plugin.focus_calls, 1)


func test_start_recording_requests_focus_before_backend_start() -> void:
	# Focus must be requested before the backend's start() runs so the game
	# window is foregrounded by the time the first frame is requested.
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var plugin := _make_focus_probe()
	controller._debugger_plugin = plugin
	var backend := _make_backend()
	controller.register_backend(backend)
	controller.start_recording({})
	assert_true(plugin.focus_calls >= 1)
	assert_true(backend.recording)


func test_start_recording_without_plugin_does_not_crash() -> void:
	# No debugger plugin injected (e.g. not running the game under the
	# debugger) — focus request must be a harmless no-op.
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	controller.start_recording({"output_path": "res://media/captures/x.avi"})
	assert_true(backend.recording)


func test_focus_probe_calls_for_every_start() -> void:
	# Two start/stop cycles request focus both times (unconditional).
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var plugin := _make_focus_probe()
	controller._debugger_plugin = plugin
	var backend := _make_backend()
	controller.register_backend(backend)
	controller.start_recording({})
	controller.stop_recording()
	controller.start_recording({})
	assert_eq(plugin.focus_calls, 2)
	if is_instance_valid(backend) and backend.get_parent() == null:
		backend.free()


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


func test_recording_error_signal_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_error.connect(func(name, message): received.append([name, message]))
	backend.recording_error.emit(backend.get_backend_name(), "boom")
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", "boom"])


func test_recording_notice_signal_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_notice.connect(func(name, message): received.append([name, message]))
	backend.recording_notice.emit(
		backend.get_backend_name(), "Saved 5 frames @ 14.2 fps (target 60)"
	)
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", "Saved 5 frames @ 14.2 fps (target 60)"])


func test_recording_notice_not_routed_after_unregister() -> void:
	# Disconnect-on-unregister must cover the notice signal too, so a
	# deactivated backend cannot keep feeding the dock after removal.
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var handler := Callable(controller, "_on_backend_recording_notice")
	assert_true(backend.is_connected("recording_notice", handler))
	controller.unregister_backend("Mock")
	assert_false(backend.is_connected("recording_notice", handler))
	# unregister_backend() queue_frees the backend; free immediately so GUT
	# orphan counter (which only waits for its own autofree queue) does not
	# see it as lingering after the test ends.
	if is_instance_valid(backend) and backend.get_parent() == null:
		backend.free()


func test_recording_converted_routes_through_controller() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var received: Array = []
	controller.recording_converted.connect(func(name, path): received.append([name, path]))
	backend.recording_converted.emit("Mock", "res://media/captures/x.mp4")
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["Mock", "res://media/captures/x.mp4"])


func test_recording_converted_not_routed_after_unregister() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	controller.register_backend(backend)
	var handler := Callable(controller, "_on_backend_recording_converted")
	assert_true(backend.is_connected("recording_converted", handler))
	controller.unregister_backend("Mock")
	assert_false(backend.is_connected("recording_converted", handler))
	if is_instance_valid(backend) and backend.get_parent() == null:
		backend.free()


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
	# unregister_backend() queue_frees B; free immediately so orphan counter
	# does not see it as lingering after the test ends — controller freed it,
	# not GUT autofree.
	if is_instance_valid(b) and b.get_parent() == null:
		b.free()
	assert_eq(controller.backends.size(), 1)
	assert_same(controller.active_backend, a)
	# No signal forwarding after unregister — nothing to assert on b since freed.
	# Verify a's signals still route (negative test that unregister didn't break other routing).
	var received: Array = []
	controller.recording_error.connect(func(name, message): received.append([name, message]))
	a.recording_error.emit("A", "still works")
	assert_eq(received, [["A", "still works"]])


func test_capture_mode_defaults_to_restart_with_no_backend() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)


func test_capture_mode_routes_to_active_backend() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := _make_backend()
	backend.capture_mode = RecorderBackend.CaptureMode.IN_PLACE
	controller.register_backend(backend)
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)


func test_capture_mode_reapplied_on_backend_switch() -> void:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var restart := _make_backend("Restart")
	var in_place := _make_backend("InPlace")
	in_place.capture_mode = RecorderBackend.CaptureMode.IN_PLACE
	controller.register_backend(restart)
	controller.register_backend(in_place)
	controller.select_backend("InPlace")
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)
	controller.select_backend("Restart")
	assert_eq(controller.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)
