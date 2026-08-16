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


# --- IN_PLACE backend behavior (screenshot backend) ---


func test_in_place_backend_shows_format_row_with_png_jpg() -> void:
	# The format row is visible for the screenshot backend and now offers PNG/JPG + tier-2
	# MP4/WebM/AVI/OGV (via ffmpeg). Old test counted 2, now counts more but PNG/JPG must stay first.
	var store := FakeStore.new()
	var ctx := _build_dock_with_mode(
		store, "res://scenes/a.tscn", RecorderBackend.CaptureMode.IN_PLACE
	)
	var dock := ctx["dock"] as TimeMachineDock
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/SceneRow").visible)
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/FormatRow").visible)
	var option: OptionButton = dock.get_node(
		"Split/RightColumn/SettingsGroup/FormatRow/FormatOption"
	)
	assert_true(option.item_count >= 2)
	# First two remain PNG/JPG per _get_allowed_formats order.
	assert_eq(option.get_item_text(0), "PNG sequence (.png)")
	assert_eq(option.get_item_text(1), "JPG sequence (.jpg)")
	# MP4 must be present.
	var has_mp4 := false
	for i in option.item_count:
		if option.get_item_text(i).contains(".mp4"):
			has_mp4 = true
	assert_true(has_mp4)


func test_restart_backend_shows_scene_and_format_rows() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/SceneRow").visible)
	assert_true(dock.get_node("Split/RightColumn/SettingsGroup/FormatRow").visible)


func test_restart_backend_format_row_offers_avi_ogv_png() -> void:
	# Movie Maker natively handles AVI/OGV/PNG and via ffmpeg MP4/WebM — total >=3, first three still AVI/OGV/PNG order.
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node(
		"Split/RightColumn/SettingsGroup/FormatRow/FormatOption"
	)
	assert_true(option.item_count >= 3)
	assert_eq(option.get_item_text(0), "AVI (.avi)")
	assert_eq(option.get_item_text(1), "OGV (.ogv)")
	assert_eq(option.get_item_text(2), "PNG sequence (.png)")
	var has_mp4 := false
	for i in option.item_count:
		if option.get_item_text(i).contains(".mp4"):
			has_mp4 = true
	assert_true(has_mp4)


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


# --- Live recording status in the status line ---


func test_format_elapsed_mm_ss() -> void:
	assert_eq(TimeMachineDock.format_elapsed(0.0), "00:00")
	assert_eq(TimeMachineDock.format_elapsed(65.0), "01:05")
	assert_eq(TimeMachineDock.format_elapsed(599.0), "09:59")


func test_format_elapsed_h_mm_ss_past_an_hour() -> void:
	assert_eq(TimeMachineDock.format_elapsed(3600.0), "1:00:00")
	assert_eq(TimeMachineDock.format_elapsed(3661.0), "1:01:01")


func test_compose_recording_status() -> void:
	assert_eq(
		TimeMachineDock.compose_recording_status("Screenshot", "res://dir/clip.png", 65.0),
		"Recording [Screenshot] → clip.png (01:05)"
	)


func test_recording_started_arms_live_status_and_timer() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Screenshot", "res://media/captures/demo_2026-08-07_12-00-00")
	assert_eq(label.text, "Recording [Screenshot] → demo_2026-08-07_12-00-00 (00:00)")
	assert_eq(dock._recording_backend_name, "Screenshot")
	assert_eq(dock._recording_output_path, "res://media/captures/demo_2026-08-07_12-00-00")
	assert_eq(dock._recording_started_at, 10.0)
	assert_not_null(dock._status_timer)
	assert_false(dock._status_timer.is_stopped())


func test_status_tick_computes_elapsed_from_faked_clock() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Screenshot", "res://media/captures/demo_2026-08-07_12-00-00")
	# 65s elapsed → mm:ss.
	dock._fake_time = 75.0
	dock._on_status_tick()
	assert_eq(label.text, "Recording [Screenshot] → demo_2026-08-07_12-00-00 (01:05)")
	# Past an hour → h:mm:ss.
	dock._fake_time = 10.0 + 3661.0
	dock._on_status_tick()
	assert_eq(label.text, "Recording [Screenshot] → demo_2026-08-07_12-00-00 (1:01:01)")


func test_status_timer_stops_on_recording_stopped() -> void:
	# The live timer stops on stop; the existing "Saved …" status flow takes
	# over and a stray tick must not resurrect the live status.
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Screenshot", "res://media/captures/demo_2026-08-07_12-00-00")
	assert_false(dock._status_timer.is_stopped())
	backend.recording = false
	controller.recording_stopped.emit("Screenshot", "res://media/captures/demo_2026-08-07_12-00-00")
	assert_true(dock._status_timer.is_stopped())
	# AVI + RESTART_SCENE → native, no conversion expected → "Saved".
	assert_eq(label.text, "Saved demo_2026-08-07_12-00-00")
	var before := label.text
	dock._on_status_tick()
	assert_eq(label.text, before)


func test_status_timer_stops_on_recording_error() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Mock", "res://media/captures/demo.png")
	assert_false(dock._status_timer.is_stopped())
	backend.recording = false
	controller.recording_error.emit("Mock", "Scene did not start")
	assert_true(dock._status_timer.is_stopped())
	assert_eq(label.text, "Error: Scene did not start")


func test_status_timer_stops_on_recording_converted() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Mock", "res://media/captures/demo.png")
	assert_false(dock._status_timer.is_stopped())
	backend.recording = false
	controller.recording_converted.emit("Mock", "res://media/captures/demo.mp4")
	assert_true(dock._status_timer.is_stopped())
	assert_eq(label.text, "Saved demo.mp4")


func test_status_tick_self_stops_when_controller_not_recording() -> void:
	# The tick guards on controller.is_recording() (single source of truth):
	# if a terminal signal was missed, the next tick stops the timer and leaves
	# the status line untouched instead of showing stale elapsed time.
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Mock", "res://media/captures/demo.png")
	assert_false(dock._status_timer.is_stopped())
	backend.recording = false
	var before := label.text
	dock._on_status_tick()
	assert_true(dock._status_timer.is_stopped())
	assert_eq(label.text, before)


func test_set_record_shortcut_attaches_shortcut_and_tooltip_hint() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var button: Button = dock.get_node("Split/LeftColumn/RecordButton")
	var original_tooltip := button.tooltip_text
	var shortcut := Shortcut.new()
	var event := InputEventKey.new()
	event.keycode = KEY_R
	event.ctrl_pressed = true
	event.alt_pressed = true
	shortcut.events = [event]
	dock.set_record_shortcut(shortcut)
	assert_eq(button.shortcut, shortcut)
	assert_string_contains(button.tooltip_text, original_tooltip)
	assert_string_contains(button.tooltip_text, "Ctrl+Alt+R")


func test_set_record_shortcut_before_ready_applies_later() -> void:
	# The plugin fallback may attach the shortcut before the dock's button
	# exists; it must be applied once _ready builds the UI.
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := MockBackend.new()
	controller.register_backend(backend)
	var dock: TimeMachineDock = load(DOCK_SCENE).instantiate()
	dock.setup(controller, FakeStore.new())
	# Pre-seed the scene field so _ready's _prefill_scene skips EditorInterface
	# (unavailable in headless test runs), mirroring _build_dock.
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = "res://scenes/a.tscn"
	var shortcut := Shortcut.new()
	var event := InputEventKey.new()
	event.keycode = KEY_R
	event.ctrl_pressed = true
	event.alt_pressed = true
	shortcut.events = [event]
	dock.set_record_shortcut(shortcut)
	assert_null(dock._record_button)  # not ready yet → deferred
	add_child_autofree(dock)
	assert_eq(dock._record_button.shortcut, shortcut)


# --- OBS backend wiring ---
#
# Dock behavior when an OBS backend (which exposes get_native_formats() and
# availability_changed) is registered: availability gating in the backend
# dropdown, a one-time install-hint dialog, and native-MP4 format filtering.
# The dock's settings seam (_editor_settings) is injected with FakeSettings so
# no engine singletons are touched.


# Mock OBS backend exercising the BackendOBS surface the dock's OBS wiring
# depends on: two-axis availability + native-formats + the async availability
# signal. Inner class so GUT doesn't collect it.
class MockOBSBackend:
	extends RecorderBackend
	var display_name := "OBS Studio"
	var available := false
	var recording := false
	signal availability_changed(available: bool)

	func get_backend_name() -> String:
		return display_name

	func get_description() -> String:
		return "Mock OBS backend for dock tests"

	func is_available() -> bool:
		return available

	func get_capture_mode() -> CaptureMode:
		return CaptureMode.IN_PLACE

	func get_native_formats() -> Array:
		return [GdTMOutputFormat.Format.MP4]

	func is_recording() -> bool:
		return recording

	func start(_config: Dictionary) -> void:
		recording = true

	func stop() -> void:
		recording = false


# In-memory EditorSettings stand-in for the dock's injected settings seam
# (_editor_settings). Mirrors EditorSettingsConfigStore's fake-store pattern.
class FakeSettings:
	extends RefCounted
	var values := {}

	func has_setting(key: String) -> bool:
		return values.has(key)

	func get_setting(key: String) -> Variant:
		return values.get(key)

	func set_setting(key: String, value: Variant) -> void:
		values[key] = value


## Like _build_dock but registers a MockBackend (Movie Maker) FIRST and a
## MockOBSBackend SECOND, so the dropdown order is [Godot Movie Maker, OBS
## Studio]. `obs_available` seeds the OBS backend's availability; settings
## may carry editor-settings values (e.g. hints/dont_show_obs_hint). Injects
## the dock's _editor_settings seam BEFORE the dock enters the tree.
func _build_dock_with_obs(
	store: FakeStore, scene_path: String, obs_available: bool, settings: FakeSettings = null
) -> Dictionary:
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var movie_maker := MockBackend.new()
	controller.register_backend(movie_maker)
	var obs := MockOBSBackend.new()
	obs.available = obs_available
	controller.register_backend(obs)
	var dock: TimeMachineDock = load(DOCK_SCENE).instantiate()
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = scene_path
	if settings != null:
		dock._editor_settings = settings
	dock.setup(controller, store)
	add_child_autofree(dock)
	return {"dock": dock, "controller": controller, "obs": obs, "movie_maker": movie_maker}


## Index of the OBS Studio item in the backend dropdown (searched by metadata,
## since the item text may carry the " — not available" suffix).
func _obs_item_index(dock: TimeMachineDock) -> int:
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	for i in option.item_count:
		if str(option.get_item_metadata(i)) == "OBS Studio":
			return i
	return -1


func test_obs_unavailable_item_marked_and_explained() -> void:
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false)
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	# _build_dock_with_obs registers Movie Maker first, so it's index 0.
	assert_true(option.get_item_text(_obs_item_index(dock)).ends_with(" — not available"))
	assert_string_contains(
		option.get_item_tooltip(_obs_item_index(dock)), "not reachable at ws://127.0.0.1:4455"
	)
	assert_eq(option.get_item_text(0), "Godot Movie Maker")


func test_obs_available_item_is_not_marked() -> void:
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	assert_eq(option.get_item_text(_obs_item_index(dock)), "OBS Studio")
	assert_eq(option.get_item_tooltip(_obs_item_index(dock)), "")


func test_obs_unavailable_tooltip_names_custom_host_port() -> void:
	# The tooltip must name the host/port from settings, never a hardcoded
	# default.
	var settings := FakeSettings.new()
	settings.values["gd_time_machine/obs/host"] = "10.0.0.7"
	settings.values["gd_time_machine/obs/port"] = 9999
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false, settings)
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	assert_string_contains(option.get_item_tooltip(_obs_item_index(dock)), "ws://10.0.0.7:9999")


func test_availability_flip_remarks_item_live() -> void:
	# A backend declaring availability_changed flips the dropdown synchronously:
	# un-greys on become-available, re-marks when it drops again.
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false)
	var dock := ctx["dock"] as TimeMachineDock
	var obs := ctx["obs"] as MockOBSBackend
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	assert_true(option.get_item_text(_obs_item_index(dock)).ends_with(" — not available"))
	obs.available = true
	obs.availability_changed.emit(true)
	assert_eq(option.get_item_text(_obs_item_index(dock)), "OBS Studio")
	obs.available = false
	obs.availability_changed.emit(false)
	assert_true(option.get_item_text(_obs_item_index(dock)).ends_with(" — not available"))


func test_obs_active_limits_format_dropdown_to_mp4() -> void:
	# Selecting OBS (which exposes get_native_formats()) narrows the format row
	# to its MP4 list; switching back to Movie Maker restores the pre-existing
	# multi-format list (the has_method fallback).
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var option: OptionButton = dock.get_node(
		"Split/RightColumn/SettingsGroup/FormatRow/FormatOption"
	)
	controller.select_backend("OBS Studio")
	assert_eq(option.item_count, 1)
	assert_true(option.get_item_text(0).contains("mp4"))
	controller.select_backend("Godot Movie Maker")
	assert_true(option.item_count >= 3)
	assert_eq(option.get_item_text(0), "AVI (.avi)")


func test_selecting_unavailable_obs_requests_install_dialog() -> void:
	var ctx := _build_dock_with_obs(
		FakeStore.new(), "res://scenes/a.tscn", false, FakeSettings.new()
	)
	var dock := ctx["dock"] as TimeMachineDock
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(dock._install_hint_popups, 1)
	assert_string_contains(dock._obs_hint_label.text, "ws://127.0.0.1:4455")


func test_install_dialog_suppressed_when_flag_set() -> void:
	var settings := FakeSettings.new()
	settings.values["hints/dont_show_obs_hint"] = true
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false, settings)
	var dock := ctx["dock"] as TimeMachineDock
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(dock._install_hint_popups, 0)


func test_dont_show_again_persists_flag_on_confirm() -> void:
	var settings := FakeSettings.new()
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false, settings)
	var dock := ctx["dock"] as TimeMachineDock
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(dock._install_hint_popups, 1)
	dock._obs_hint_dont_show.button_pressed = true
	dock._obs_install_dialog.confirmed.emit()
	assert_eq(settings.values.get("hints/dont_show_obs_hint"), true)


func test_obs_unavailable_selection_still_selects_backend() -> void:
	# The item stays selectable even when unavailable, so the persisted
	# default profile records the chosen backend by NAME (metadata), never the
	# " — not available" display text.
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false)
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(controller.active_backend.get_backend_name(), "OBS Studio")
	var profile := dock._build_profile_from_ui()
	assert_eq(profile.backend_name, "OBS Studio")
	assert_false(profile.backend_name.contains("not available"))


func test_obs_recording_error_surfaces_in_status_line() -> void:
	# Backend errors flow through the existing recording_error
	# handler unchanged — "Error:" prefix keeps the backend's actionable
	# message intact.
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	controller.recording_error.emit(
		"OBS Studio",
		"OBS Studio not found. Please install OBS Studio and enable the WebSocket server..."
	)
	assert_true(label.text.begins_with("Error:"))
	assert_string_contains(label.text, "OBS Studio not found")


func test_selecting_available_obs_does_not_request_install_dialog() -> void:
	# The hint asserts OBS is NOT reachable, so it must never appear while an
	# available OBS Studio is selected — even with the suppression flag unset.
	var settings := FakeSettings.new()
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true, settings)
	var dock := ctx["dock"] as TimeMachineDock
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(dock._install_hint_popups, 0)


func test_obs_stop_shows_saved_not_converting() -> void:
	# BackendOBS records MP4 natively (get_native_formats →
	# [MP4]) and never emits recording_converted, so a stopped OBS recording
	# must land on "Saved …", not a dangling "Converting to mp4…" status.
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	controller.select_backend("OBS Studio")  # narrows the format row to [MP4]
	controller.recording_stopped.emit("OBS Studio", "res://media/captures/obs/obs_happy.mp4")
	assert_eq(label.text, "Saved obs_happy.mp4")
	assert_false(label.text.contains("Converting"))
