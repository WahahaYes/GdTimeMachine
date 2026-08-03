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

const DOCK_SCENE := "res://addons/GdTimeMachine/ui/time_machine_dock.tscn"


# Mock backend exercising the RecorderBackend contract (mirrors the one in
# test_recorder_controller.gd). Inner class so GUT doesn't collect it.
class MockBackend:
	extends RecorderBackend
	var display_name := "Godot Movie Maker"
	var recording := false
	var capture_mode := RecorderBackend.CaptureMode.RESTART_SCENE

	func get_backend_name() -> String:
		return display_name

	func get_description() -> String:
		return "Mock backend for dock tests"

	func is_available() -> bool:
		return true

	func is_recording() -> bool:
		return recording

	func get_capture_mode() -> CaptureMode:
		return capture_mode

	func start(_config: Dictionary) -> void:
		recording = true

	func stop() -> void:
		recording = false


# In-memory ConfigStore stand-in that records every scene-profile save/clear.
class FakeStore:
	extends ConfigStore
	var default: RecordingProfile = RecordingProfile.new()
	var scenes := {}
	var saved_scene_calls: Array = []
	var cleared_scene_calls: Array = []
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
		cleared_scene_calls.append(scene_path)
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
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = scene_path
	dock.setup(controller, store)
	add_child_autofree(dock)
	return {"dock": dock, "controller": controller, "backend": backend}


## Like _build_dock but with a MockBackend preset to the given capture mode,
## so IN_PLACE visibility/output-path behavior can be exercised.
func _build_dock_with_mode(
	store: FakeStore, scene_path: String, capture_mode: RecorderBackend.CaptureMode
) -> Dictionary:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := MockBackend.new()
	backend.capture_mode = capture_mode
	controller.register_backend(backend)
	var dock: TimeMachineDock = load(DOCK_SCENE).instantiate()
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = scene_path
	dock.setup(controller, store)
	add_child_autofree(dock)
	return {"dock": dock, "controller": controller, "backend": backend}


func test_setup_loads_default_profile_into_ui() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://my_default"
	)
	assert_false(dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck").button_pressed)


func test_scene_switch_saves_previous_profile_when_per_scene_on() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	output.text = "res://a_specific"
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(store.saved_scene_calls[0][0], "res://scenes/a.tscn")
	assert_eq((store.saved_scene_calls[0][1] as RecordingProfile).output_dir, "res://a_specific")
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text,
		"res://scenes/b.tscn"
	)


func test_scene_switch_does_not_save_when_per_scene_off() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text,
		"res://scenes/b.tscn"
	)


func test_scene_switch_does_not_save_untitled_previous_scene() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	# Simulate an untitled previous scene: clear the field after setup (an
	# empty seed at build time would hit EditorInterface in _prefill_scene).
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = ""
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text,
		"res://scenes/b.tscn"
	)


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
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://scene_specific"
	)
	assert_eq(dock._get_selected_format(), GdTMOutputFormat.Format.OGV)
	assert_eq(dock.get_node("Split/RightColumn/SettingsGroup/FpsRow/FpsSpin").value, 30.0)
	assert_true(dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck").button_pressed)


func test_scene_switch_loads_defaults_when_no_override() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://my_default"
	)
	assert_false(dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck").button_pressed)


func test_scene_switch_from_override_scene_to_unchecked_scene_loads_defaults() -> void:
	# User requirement: when moving to a new scene whose "Remember settings
	# for this scene" box is unchecked (no override), the UI must fall back
	# to the default profile — not keep showing the previous scene's override
	# values (i.e. not "do nothing").
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var override := RecordingProfile.new()
	override.output_dir = "res://a_specific"
	override.fps = 30
	store.scenes["res://scenes/a.tscn"] = override
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	# Scene a has an override → checkbox on, override loaded into the UI.
	assert_true(check.button_pressed)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://a_specific"
	)
	# Moving to b (no override, unchecked): falls back to the default profile.
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_false(check.button_pressed)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://my_default"
	)


func test_scene_switch_to_untitled_saves_previous_and_loads_defaults() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.on_editor_scene_changed("")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(store.saved_scene_calls[0][0], "res://scenes/a.tscn")
	assert_eq(dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text, "")
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://my_default"
	)
	assert_true(check.disabled)
	assert_false(check.button_pressed)


func test_scene_switch_ignored_while_recording() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	backend.recording = true
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text,
		"res://scenes/a.tscn"
	)


func test_scene_close_saves_profile_when_matching_field() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
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
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
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
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	backend.recording = true
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)


func test_close_then_switch_does_not_double_save() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	# Closing the active tab flushes a; the editor then switches to b, which
	# would normally re-save a. The _flushed_on_close guard must prevent it.
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text,
		"res://scenes/b.tscn"
	)


func test_uncheck_clears_override_and_falls_back_to_defaults() -> void:
	# The checkbox is the single per-scene control: unchecking must drop the
	# stored override (so the unchecked state is durable across sessions) and
	# fall back to the default profile — the removed Clear button's job.
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var override := RecordingProfile.new()
	override.output_dir = "res://a_specific"
	override.fps = 30
	store.scenes["res://scenes/a.tscn"] = override
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	# Override exists → checkbox on, override loaded into the UI.
	assert_true(check.button_pressed)
	assert_eq(output.text, "res://a_specific")
	# User unchecks: override cleared, UI falls back to defaults.
	check.button_pressed = false
	assert_eq(store.cleared_scene_calls.size(), 1)
	assert_eq(store.cleared_scene_calls[0], "res://scenes/a.tscn")
	assert_false(check.button_pressed)
	assert_eq(output.text, "res://my_default")


func test_uncheck_without_override_falls_back_to_defaults() -> void:
	# Unchecking a scene with no stored override reloads the default profile
	# into the UI. (Whether clear_scene_profile fires is an implementation
	# detail here — assert the observable UI.)
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	assert_false(check.button_pressed)
	assert_eq(output.text, "res://media/captures")
	# Change the store's default after setup: the UI must not pick it up until
	# per-scene mode is toggled off and defaults are reloaded.
	store.default.output_dir = "res://my_default"
	check.button_pressed = true  # Enter per-scene mode: no override → UI kept.
	assert_eq(output.text, "res://media/captures")
	check.button_pressed = false  # Leave per-scene mode → defaults reloaded.
	assert_eq(output.text, "res://my_default")


func test_programmatic_uncheck_via_scene_switch_does_not_clear() -> void:
	# Switching to a scene without an override programmatically unchecks the
	# box inside _refresh_per_scene_state; that internal sync must not fire
	# the clear/fallback side effects (the _syncing_scene_state guard).
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var override := RecordingProfile.new()
	override.output_dir = "res://a_specific"
	store.scenes["res://scenes/a.tscn"] = override
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	assert_true(check.button_pressed)
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_false(check.button_pressed)
	assert_eq(store.cleared_scene_calls.size(), 0)
	assert_eq(
		dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit").text,
		"res://my_default"
	)


func test_uncheck_untitled_scene_does_not_clear() -> void:
	# Untitled scenes (empty field) have no stable profile key: no clear may
	# fire for them, and the internal uncheck-sync must not either. Switching
	# to an untitled scene drives _refresh_per_scene_state with an empty path
	# (note: programmatic LineEdit.text sets do not emit text_changed, so the
	# switch path is what exercises this).
	var store := FakeStore.new()
	var override := RecordingProfile.new()
	override.output_dir = "res://a_specific"
	store.scenes["res://scenes/a.tscn"] = override
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	assert_true(check.button_pressed)
	dock.on_editor_scene_changed("")
	assert_false(check.button_pressed)
	assert_true(check.disabled)
	assert_eq(store.cleared_scene_calls.size(), 0)


# --- IN_PLACE backend behavior (Op 5 screenshot backend) ---


func test_in_place_backend_hides_scene_and_format_rows() -> void:
	# Scene row is now always visible (IN_PLACE launches scene when idle, then
	# captures in place). Format row stays hidden pre-Op-6 (PNG-only).
	var store := FakeStore.new()
	var ctx := _build_dock_with_mode(
		store, "res://scenes/a.tscn", RecorderBackend.CaptureMode.IN_PLACE
	)
	var dock := ctx["dock"] as TimeMachineDock
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/SceneRow").visible)
	assert_false(dock.get_node("Split/RightColumn/SettingsGroup/FormatRow").visible)


func test_restart_backend_shows_scene_and_format_rows() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/SceneRow").visible)
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/FormatRow").visible)


func test_in_place_output_path_has_no_extension() -> void:
	# The IN_PLACE backend owns the output layout ("<base>.frames/…"); a
	# format extension would just pollute the base path.
	var store := FakeStore.new()
	store.default.output_dir = "res://media/captures"
	store.default.output_format = GdTMOutputFormat.Format.PNG
	var ctx := _build_dock_with_mode(
		store, "res://scenes/demo.tscn", RecorderBackend.CaptureMode.IN_PLACE
	)
	var dock := ctx["dock"] as TimeMachineDock
	var path: String = dock._build_output_path()
	assert_false(path.ends_with(".png"))
	assert_false(path.get_extension() == "png")
	assert_true(path.contains("/demo_"), "expected scene-prefixed base path, got %s" % path)


func test_restart_output_path_keeps_extension() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://media/captures"
	store.default.output_format = GdTMOutputFormat.Format.PNG
	var ctx := _build_dock(store, "res://scenes/demo.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var path: String = dock._build_output_path()
	assert_true(path.ends_with(".png"))
	assert_true(path.contains("/demo_"), "expected scene-prefixed path, got %s" % path)


func test_recording_notice_sets_status_line() -> void:
	# The backend composes its own notice (capture statistics / zero-frame
	# hint); the dock just prints it verbatim in the status line.
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	controller.recording_notice.emit("Mock", "Saved 5 frames @ 14.2 fps (target 60)")
	assert_eq(label.text, "Saved 5 frames @ 14.2 fps (target 60)")
