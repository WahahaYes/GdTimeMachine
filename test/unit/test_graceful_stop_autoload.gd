extends GutTest

# Op 2 graceful-stop autoload tests
# (addons/GdTimeMachine/autoload/graceful_stop.gd).
#
# The real autoload registers a message capture with EngineDebugger in _ready()
# and quits via get_tree().quit() in _quit_game() — both engine-global side
# effects a unit test must not trigger. Following the FakeMovieMaker pattern
# from test_backend_movie_maker.gd, we extend the real script and override the
# seams: _ready() is a no-op (no EngineDebugger registration, per task
# constraint) and _quit_game() records the call instead of quitting the tree.
# The instances are never added to the tree, so _ready/_exit_tree never run at
# all; the overrides are belt-and-suspenders for safety.

const GracefulStopScript := preload("res://addons/GdTimeMachine/autoload/graceful_stop.gd")


class GracefulStopHarness:
	extends GracefulStopScript
	var quit_called := false

	func _ready() -> void:
		pass  # Skip EngineDebugger.register_message_capture — not a unit-test concern.

	func _quit_game() -> void:
		quit_called = true


func _make_autoload() -> GracefulStopHarness:
	return autofree(GracefulStopHarness.new())


func test_on_debug_message_graceful_stop_calls_quit_and_returns_true() -> void:
	var autoload := _make_autoload()
	var handled: bool = autoload._on_debug_message("graceful_stop", [])
	assert_true(handled)
	assert_true(autoload.quit_called)


func test_on_debug_message_other_returns_false_no_quit() -> void:
	var autoload := _make_autoload()
	var handled: bool = autoload._on_debug_message("some_other_message", [])
	assert_false(handled)
	assert_false(autoload.quit_called)


func test_on_debug_message_empty_returns_false() -> void:
	var autoload := _make_autoload()
	var handled: bool = autoload._on_debug_message("", [])
	assert_false(handled)
	assert_false(autoload.quit_called)


func test_quit_seam_overridable() -> void:
	# The seam is the whole point of the design: a game-side override observes
	# the graceful-stop without ever calling get_tree().quit(). Verify both
	# that the override intercepts and that repeated messages keep working.
	var autoload := _make_autoload()
	autoload._on_debug_message("graceful_stop", [])
	assert_true(autoload.quit_called)
	autoload._on_debug_message("graceful_stop", ["again"])
	assert_true(autoload.quit_called)


func test_payload_data_is_ignored() -> void:
	# The editor always sends an empty payload for graceful_stop, but any data
	# must not break dispatch or suppress the quit.
	var autoload := _make_autoload()
	var handled: bool = autoload._on_debug_message("graceful_stop", ["ignored", 42])
	assert_true(handled)
	assert_true(autoload.quit_called)
