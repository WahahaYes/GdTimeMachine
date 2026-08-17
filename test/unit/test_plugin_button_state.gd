extends GutTest

# Grey-out state transitions for the game-view record button. The rule lives
# in a static function on plugin.gd so the full matrix runs headlessly — no
# editor UI. Signal re-apply wiring (backend_changed / recording_*) is covered
# by the interactive playbook; the controller-level re-apply semantics are
# covered in test_recorder_controller.gd.

const PluginScript := preload("res://addons/GdTimeMachine/plugin.gd")

const RESTART := RecorderBackend.CaptureMode.RESTART_SCENE
const IN_PLACE := RecorderBackend.CaptureMode.IN_PLACE


func test_record_disabled_when_idle_and_restart_backend() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(false, RESTART)
	assert_true(state["disabled"])
	assert_eq(state["tooltip"], PluginScript.TOOLTIP_RESTART_DISABLED)


func test_stop_enabled_when_recording_with_restart_backend() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(true, RESTART)
	assert_false(state["disabled"])
	assert_eq(state["tooltip"], PluginScript.TOOLTIP_DEFAULT)


func test_record_enabled_when_idle_and_in_place_backend() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(false, IN_PLACE)
	assert_false(state["disabled"])
	assert_eq(state["tooltip"], PluginScript.TOOLTIP_DEFAULT)


func test_disabled_tooltip_explains_the_restart() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(false, RESTART)
	assert_string_contains(str(state["tooltip"]).to_lower(), "restart")
