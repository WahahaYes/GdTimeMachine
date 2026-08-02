extends GutTest

## Tests for the dock's scene-change tracking: on_editor_scene_changed()
## auto-saves the previous scene's per-scene profile (when per-scene mode is
## on) and auto-loads the new scene's resolved profile (override > default).
##
## The dock is instantiated with a real RecorderController (registered with a
## MockBackend) and an in-memory FakeStore so no engine singletons
## (EditorInterface, EditorSettings) are touched. SceneEdit is pre-seeded
## before _ready so _prefill_scene skips EditorInterface, which is
## unavailable in headless test runs.

const DOCK_SCENE := "res://addons/gd-time-machine/ui/time_machine_dock.tscn"


# Mock backend exercising the RecorderBackend contract (mirrors the one in
# test_recorder_controller.gd). Inner class so GUT doesn't collect it.
class MockBackend:
	extends RecorderBackend
	var display_name := "Godot Movie Maker"
	var recording := false

	func get_backend_name() -> String:
		return display_name

	func get_description() -> String:
		return "Mock backend for dock tests"

	func is_available() -> bool:
		return true

	func is_recording() -> bool:
		return recording

	func get_capture_mode() -> CaptureMode:
		return RecorderBackend.CaptureMode.RESTART_SCENE

	func start(_config: Dictionary) -> void:
		recording = true

	func stop() -> void:
		recording = false


# In-memory ConfigStore stand-in that records every scene-profile save.
class FakeStore:
	extends ConfigStore
	var default: RecordingProfile = RecordingProfile.new()
	var scenes := {}
	var saved_scene_calls: Array = []
	var saved_default_calls := 0

	func get_default_profile() -> RecordingProfile:
		return default

	func get_scene_profile(scene_path: String) -> RecordingProfile:
		return scenes.get(scene_path)

	func save_scene_profile(scene_path: String, profile: RecordingProfile) -> void:
		saved_scene_calls.append([scene_path, profile])
		scenes[scene_path] = profile

	func save_default_profile(profile: RecordingProfile) -> void:
		saved_default_calls += 1
		default = profile

	func clear_scene_profile(scene_path: String) -> void:
		scenes.erase(scene_path)


## Instantiates the dock scene with a real controller (owning a MockBackend)
## and the given store, seeds the scene field (so _prefill_scene skips
## EditorInterface), and adds the dock to the tree. Returns the dock,
## controller and backend for assertions.
func _build_dock(store: FakeStore, scene_path: String) -> Dictionary:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := MockBackend.new()
	controller.register_backend(backend)
	var dock: TimeMachineDock = load(DOCK_SCENE).instantiate()
	dock.get_node("SettingsGroup/SceneRow/SceneEdit").text = scene_path
	dock.setup(controller, store)
	add_child_autofree(dock)
	return {"dock": dock, "controller": controller, "backend": backend}


func test_setup_loads_default_profile_into_ui() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	assert_eq(dock.get_node("SettingsGroup/OutputRow/OutputEdit").text, "res://my_default")
	assert_false(dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck").button_pressed)


func test_scene_switch_saves_previous_profile_when_per_scene_on() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	var output: LineEdit = dock.get_node("SettingsGroup/OutputRow/OutputEdit")
	output.text = "res://a_specific"
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(store.saved_scene_calls[0][0], "res://scenes/a.tscn")
	assert_eq((store.saved_scene_calls[0][1] as RecordingProfile).output_dir, "res://a_specific")
	assert_eq(dock.get_node("SettingsGroup/SceneRow/SceneEdit").text, "res://scenes/b.tscn")


func test_scene_switch_does_not_save_when_per_scene_off() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	assert_eq(dock.get_node("SettingsGroup/SceneRow/SceneEdit").text, "res://scenes/b.tscn")


func test_scene_switch_does_not_save_untitled_previous_scene() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	# Simulate an untitled previous scene: clear the field after setup (an
	# empty seed at build time would hit EditorInterface in _prefill_scene).
	dock.get_node("SettingsGroup/SceneRow/SceneEdit").text = ""
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	assert_eq(dock.get_node("SettingsGroup/SceneRow/SceneEdit").text, "res://scenes/b.tscn")


func test_scene_switch_loads_new_scene_override() -> void:
	var store := FakeStore.new()
	var override := RecordingProfile.new()
	override.output_dir = "res://scene_specific"
	override.output_format = GdTMOutputFormat.Format.OGV
	override.fps = 30
	store.scenes["res://scenes/b.tscn"] = override
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(dock.get_node("SettingsGroup/OutputRow/OutputEdit").text, "res://scene_specific")
	assert_eq(dock._get_selected_format(), GdTMOutputFormat.Format.OGV)
	assert_eq(dock.get_node("SettingsGroup/FpsRow/FpsSpin").value, 30.0)
	assert_true(dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck").button_pressed)


func test_scene_switch_loads_defaults_when_no_override() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(dock.get_node("SettingsGroup/OutputRow/OutputEdit").text, "res://my_default")
	assert_false(dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck").button_pressed)


func test_scene_switch_to_untitled_saves_previous_and_loads_defaults() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.on_editor_scene_changed("")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(store.saved_scene_calls[0][0], "res://scenes/a.tscn")
	assert_eq(dock.get_node("SettingsGroup/SceneRow/SceneEdit").text, "")
	assert_eq(dock.get_node("SettingsGroup/OutputRow/OutputEdit").text, "res://my_default")
	assert_true(check.disabled)
	assert_false(check.button_pressed)


func test_scene_switch_ignored_while_recording() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	backend.recording = true
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	assert_eq(dock.get_node("SettingsGroup/SceneRow/SceneEdit").text, "res://scenes/a.tscn")


func test_scene_close_saves_profile_when_matching_field() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(store.saved_scene_calls[0][0], "res://scenes/a.tscn")


func test_scene_close_does_not_save_when_per_scene_off() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)


func test_scene_close_skips_when_field_is_other_scene() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	# Closing a background tab (b) while a is reflected in the field: the UI
	# never showed b's settings, so nothing should be saved to b.
	dock.on_editor_scene_closed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)


func test_scene_close_skipped_while_recording() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	backend.recording = true
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)


func test_close_then_switch_does_not_double_save() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("SettingsGroup/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	# Closing the active tab flushes a; the editor then switches to b, which
	# would normally re-save a. The _flushed_on_close guard must prevent it.
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(dock.get_node("SettingsGroup/SceneRow/SceneEdit").text, "res://scenes/b.tscn")
