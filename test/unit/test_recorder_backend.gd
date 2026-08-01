extends GutTest


func test_recorder_backend_is_a_node() -> void:
	var backend := RecorderBackend.new()
	assert_true(backend is Node)


func test_default_contract_stubs() -> void:
	var backend := RecorderBackend.new()
	assert_eq(backend.get_backend_name(), "")
	assert_eq(backend.get_description(), "")
	assert_false(backend.is_available())
	assert_false(backend.is_recording())


func test_default_start_and_stop_do_not_crash() -> void:
	var backend := RecorderBackend.new()
	backend.start({})
	backend.stop()
	# Reaching here without error is the assertion.
	assert_true(true)
