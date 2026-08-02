extends GutTest


func _make_backend() -> RecorderBackend:
	return add_child_autofree(RecorderBackend.new())


func test_recorder_backend_is_a_node() -> void:
	var backend := _make_backend()
	assert_true(backend is Node)


func test_default_contract_stubs() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_backend_name(), "")
	assert_eq(backend.get_description(), "")
	assert_false(backend.is_available())
	assert_false(backend.is_recording())


func test_capture_mode_defaults_to_restart_scene() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)


func test_default_start_and_stop_do_not_crash() -> void:
	var backend := _make_backend()
	backend.start({})
	backend.stop()
	# Reaching here without error is the assertion.
	assert_true(true)
