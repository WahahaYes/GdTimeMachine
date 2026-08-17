extends GutTest

# Description/tooltip contract tests for the concrete backends (Movie Maker,
# Screenshot) live with their own suites — test_backend_movie_maker.gd and
# test_backend_screenshot_capture.gd — not here in the abstract base suite.


func _make_backend() -> RecorderBackend:
	return add_child_autofree(RecorderBackend.new())


func test_default_contract_stubs() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_backend_name(), "")
	assert_eq(backend.get_description(), "")
	assert_false(backend.is_available())
	assert_false(backend.is_recording())


func test_capture_mode_defaults_to_restart_scene() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.RESTART_SCENE)
