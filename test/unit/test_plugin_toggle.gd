extends GutTest

## Tests for the plugin-level record/stop toggle decision
## (PluginScript.compute_toggle_action): stop when recording, start with the
## dock's config when idle, and the empty-config fallback when the dock is
## unavailable. The rule lives in a static (like compute_game_view_button_state)
## so the matrix runs headlessly — an EditorPlugin is a virtual class that only
## the editor can instantiate.

const PluginScript := preload("res://addons/GdTimeMachine/plugin.gd")


# Dock stand-in: build_config returns a known dict so the toggle test can
# assert the dock's config is the one handed to the backend.
class FakeDock:
	extends TimeMachineDock

	func build_config() -> Dictionary:
		return {"output_path": "res://media/captures/from_dock.avi", "fps": 30}


func test_toggle_stops_when_recording() -> void:
	var action: Dictionary = PluginScript.compute_toggle_action(true, null)
	assert_eq(action["action"], "stop")


func test_toggle_starts_with_dock_config_when_idle() -> void:
	var dock := FakeDock.new()
	var action: Dictionary = PluginScript.compute_toggle_action(false, dock)
	dock.free()
	assert_eq(action["action"], "start")
	assert_eq(action["config"], {"output_path": "res://media/captures/from_dock.avi", "fps": 30})


func test_toggle_starts_with_empty_config_when_dock_unavailable() -> void:
	var action: Dictionary = PluginScript.compute_toggle_action(false, null)
	assert_eq(action["action"], "start")
	assert_eq(action["config"], {})
