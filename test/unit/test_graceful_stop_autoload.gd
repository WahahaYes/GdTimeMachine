@tool
extends GutTest

## Game-side autoload tests (autoload/graceful_stop.gd). The script is a
## plain Node so it instantiates headlessly; paths touching the tree or a
## live debugger are kept to routing-only assertions (is_active() is false
## headless, making sends safe no-ops).

const AutoloadScript := preload("res://addons/GdTimeMachine/autoload/graceful_stop.gd")


func _make_autoload() -> Node:
	return add_child_autofree(AutoloadScript.new())


func test_rq_window_handle_is_routed_without_debugger() -> void:
	var autoload := _make_autoload()
	assert_true(autoload._on_debug_message("rq_window_handle", [42]))
	assert_false(autoload._on_debug_message("bogus_message", []))


func test_collect_window_identity_shape() -> void:
	var autoload := _make_autoload()
	var identity: Dictionary = autoload._collect_window_identity()
	for key in ["handle", "display", "exe", "title_guess", "debug"]:
		assert_true(identity.has(key), "identity must carry '%s'" % key)
	assert_true(int(identity.get("handle", -1)) >= 0)
	assert_false(str(identity.get("display", "")).is_empty(), "display server must be named")
