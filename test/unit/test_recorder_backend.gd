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


func test_movie_maker_description_mentions_fixed_fps() -> void:
	# Tooltip contract: the backend's get_description() must state the
	# capture semantics — Movie Maker is fixed-fps, non-real-time.
	var backend: BackendMovieMaker = add_child_autofree(BackendMovieMaker.new())
	var desc := backend.get_description().to_lower()
	assert_string_contains(desc, "fixed-fps")
	assert_string_contains(desc, "non-real-time")


func test_screenshot_description_mentions_real_time() -> void:
	# Tooltip contract: the screenshot backend must state its real-time
	# capture semantics (game sim runs at normal speed, machine-bound rate).
	var backend: BackendScreenshotCapture = add_child_autofree(BackendScreenshotCapture.new())
	var desc := backend.get_description().to_lower()
	assert_string_contains(desc, "real-time")
