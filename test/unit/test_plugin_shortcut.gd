@tool
extends GutTest

## Shortcut, toggle-decision, and game-view button rules — static pure helpers
## on plugin.gd, so the full matrix runs headlessly. Keying remove_command() by
## the underscore identifier (not the display name) is pinned to avoid the
## "Command doesn't exist" teardown error.

const PluginScript := preload("res://addons/GdTimeMachine/plugin.gd")

const RESTART := RecorderBackend.CaptureMode.RESTART_SCENE
const IN_PLACE := RecorderBackend.CaptureMode.IN_PLACE


## Dock stand-in: build_config returns a known dict so the toggle test can
## assert the dock's config is the one handed to the backend.
class FakeDock:
	extends TimeMachineDock

	func build_config() -> Dictionary:
		return {"output_path": "res://media/captures/from_dock.avi", "fps": 30}


func _event_of(shortcut: Shortcut) -> InputEventKey:
	assert_eq(shortcut.events.size(), 1, "shortcut must hold exactly one event")
	return shortcut.events[0] as InputEventKey


## Shortcut construction


func test_default_branch_uses_ctrl_alt_r() -> void:
	var shortcut := PluginScript.build_toggle_shortcut(false)
	var event := _event_of(shortcut)
	assert_true(event is InputEventKey)
	assert_eq(event.keycode, PluginScript.SHORTCUT_KEYCODE)
	assert_eq(event.keycode, KEY_R)
	assert_true(event.ctrl_pressed)
	assert_false(event.meta_pressed)
	assert_true(event.alt_pressed)
	assert_false(event.shift_pressed)


func test_meta_branch_uses_meta_alt_r_without_ctrl() -> void:
	# macOS prefers Cmd (Meta) over Ctrl — Meta replaces Ctrl, Alt stays.
	var shortcut := PluginScript.build_toggle_shortcut(true)
	var event := _event_of(shortcut)
	assert_true(event.meta_pressed)
	assert_false(event.ctrl_pressed)
	assert_true(event.alt_pressed)
	assert_eq(event.keycode, KEY_R)


func test_default_branch_get_as_text_contains_combo() -> void:
	var shortcut := PluginScript.build_toggle_shortcut(false)
	var text := shortcut.get_as_text()
	assert_string_contains(text, "Ctrl")
	assert_string_contains(text, "Alt")
	assert_string_contains(text, "R")


func test_meta_branch_get_as_text_contains_combo() -> void:
	var shortcut := PluginScript.build_toggle_shortcut(true)
	var text := shortcut.get_as_text()
	assert_string_contains(text, "Meta")
	assert_string_contains(text, "Alt")
	assert_string_contains(text, "R")


func test_should_use_meta_matches_running_os() -> void:
	# Platform seam: _should_use_meta() is exactly (running OS == macOS). Pin
	# the concrete branch on the live OS so a wrong platform string or an
	# inverted comparison fails instead of a tautological bool check.
	assert_eq(PluginScript._should_use_meta(), OS.get_name() == "macOS")


## Palette identifiers


func test_palette_action_and_key_are_distinct() -> void:
	# remove_command() keys by the palette KEY (gd_time_machine_toggle_recording),
	# not the display name. The two identifiers must never be conflated — the
	# "command doesn't exists" teardown error came from passing the action name
	# to remove_command. Pin the mismatch so a const edit can't silently merge.
	assert_ne(PluginScript.COMMAND_PALETTE_ACTION, PluginScript.COMMAND_PALETTE_KEY)
	assert_false(PluginScript.COMMAND_PALETTE_KEY.contains(PluginScript.COMMAND_PALETTE_ACTION))


func test_palette_key_is_settings_style_identifier() -> void:
	# The key is unique and keyed in the palette namespace like EditorSettings
	# paths — underscore/lowercase, not a display string.
	assert_string_contains(PluginScript.COMMAND_PALETTE_KEY, "gd_time_machine")
	assert_false(
		PluginScript.COMMAND_PALETTE_KEY.contains(" "), "palette key must not contain spaces"
	)


## Toggle decision


func test_toggle_stops_when_recording() -> void:
	var action: Dictionary = PluginScript.compute_toggle_action(true, null)
	assert_eq(action["action"], "stop")


func test_toggle_starts_with_dock_config_when_idle() -> void:
	var dock: FakeDock = autofree(FakeDock.new())
	var action: Dictionary = PluginScript.compute_toggle_action(false, dock)
	assert_eq(action["action"], "start")
	assert_eq(action["config"], {"output_path": "res://media/captures/from_dock.avi", "fps": 30})


func test_toggle_starts_with_empty_config_when_dock_unavailable() -> void:
	var action: Dictionary = PluginScript.compute_toggle_action(false, null)
	assert_eq(action["action"], "start")
	assert_eq(action["config"], {})


## Game-view button grey-out rule


func test_record_disabled_when_idle_and_restart_backend() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(false, RESTART)
	assert_true(state["disabled"])
	assert_string_contains(state["tooltip"], "restarts the scene")


func test_stop_enabled_when_recording_with_restart_backend() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(true, RESTART)
	assert_false(state["disabled"])
	assert_eq(state["tooltip"], PluginScript.TOOLTIP_DEFAULT)


func test_record_enabled_when_idle_and_in_place_backend() -> void:
	var state: Dictionary = PluginScript.compute_game_view_button_state(false, IN_PLACE)
	assert_false(state["disabled"])
	assert_eq(state["tooltip"], PluginScript.TOOLTIP_DEFAULT)
