@tool
extends GutTest

## GdTimeMachine dock UI logic tests: a real RecorderController (mock backends)
## and an in-memory FakeStore — no engine singletons and no async; signals are
## synchronous and dock/controller methods are called directly.

const DOCK_SCENE := "res://addons/GdTimeMachine/ui/time_machine_dock.tscn"


## Mock backend exercising the RecorderBackend contract (mirrors the one in
## test_recorder_controller.gd). Inner class so GUT doesn't collect it.
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


## Mock OBS backend exercising the BackendOBS surface the dock's OBS wiring
## depends on: availability + native formats + the async availability signal.
## Inner class so GUT doesn't collect it.
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

	func is_recording() -> bool:
		return recording

	func get_capture_mode() -> CaptureMode:
		return CaptureMode.IN_PLACE

	func get_native_formats() -> Array:
		return [GdTMOutputFormat.Format.MP4]

	func start(_config: Dictionary) -> void:
		recording = true

	func stop() -> void:
		recording = false


## In-memory ConfigStore stand-in that records every scene-profile save/clear.
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


## In-memory EditorSettings stand-in for the dock's injected settings seam
## (_editor_settings).
class FakeSettings:
	extends RefCounted
	var values := {}

	func has_setting(key: String) -> bool:
		return values.has(key)

	func get_setting(key: String) -> Variant:
		return values.get(key)

	func set_setting(key: String, value: Variant) -> void:
		values[key] = value


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
## so IN_PLACE output-path behavior can be exercised.
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


## Index of the Godot Movie Maker item in the backend dropdown (searched by
## metadata, mirroring _obs_item_index).
func _movie_maker_item_index(dock: TimeMachineDock) -> int:
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	for i in option.item_count:
		if str(option.get_item_metadata(i)) == "Godot Movie Maker":
			return i
	return -1


## Setup


func test_setup_loads_default_profile_into_ui() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	var fps: SpinBox = dock.get_node("Split/RightColumn/SettingsGroup/FpsRow/FpsSpin")
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	assert_eq(output.text, "res://my_default")
	assert_eq(fps.value, 60.0)
	assert_eq(dock._get_selected_format(), GdTMOutputFormat.DEFAULT)
	assert_false(check.button_pressed)


func test_setup_checks_per_scene_when_override_exists() -> void:
	var store := FakeStore.new()
	var override := RecordingProfile.new()
	override.output_dir = "res://a_specific"
	store.scenes["res://scenes/a.tscn"] = override
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	assert_true(check.button_pressed)
	assert_eq(output.text, "res://a_specific")


## Scene switching


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


func test_scene_switch_does_not_save_untitled_previous() -> void:
	# An empty field means the previous scene has no stable profile key. The
	# check is re-asserted after clearing the field because _refresh_per_scene_state
	# may programmatically uncheck it on the empty path.
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = ""
	check.button_pressed = true
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)


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
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	var fps: SpinBox = dock.get_node("Split/RightColumn/SettingsGroup/FpsRow/FpsSpin")
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	assert_eq(output.text, "res://scene_specific")
	assert_eq(dock._get_selected_format(), GdTMOutputFormat.Format.OGV)
	assert_eq(fps.value, 30.0)
	assert_true(check.button_pressed)


func test_scene_switch_falls_back_to_defaults_without_override() -> void:
	var store := FakeStore.new()
	store.default.output_dir = "res://my_default"
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	dock.on_editor_scene_changed("res://scenes/b.tscn")
	var output: LineEdit = dock.get_node("Split/RightColumn/SettingsGroup/OutputRow/OutputEdit")
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	assert_eq(output.text, "res://my_default")
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


## Scene close


func test_scene_close_saves_when_field_matches() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	check.button_pressed = true
	dock.on_editor_scene_closed("res://scenes/a.tscn")
	assert_eq(store.saved_scene_calls.size(), 1)
	assert_eq(store.saved_scene_calls[0][0], "res://scenes/a.tscn")


func test_scene_close_skips_when_per_scene_off_or_field_differs() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var check: CheckBox = dock.get_node("Split/LeftColumn/PerSceneRow/PerSceneCheck")
	# Closing a background tab (b) while a is reflected in the field: the UI
	# never showed b's settings, so nothing should be saved to b.
	check.button_pressed = true
	dock.on_editor_scene_closed("res://scenes/b.tscn")
	assert_eq(store.saved_scene_calls.size(), 0)
	# Closing the reflected scene with per-scene mode off: no save either.
	check.button_pressed = false
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


## Per-scene checkbox


func test_uncheck_clears_override_and_reloads_default() -> void:
	# The checkbox is the single per-scene control: unchecking must drop the
	# stored override (so the unchecked state is durable across sessions) and
	# fall back to the default profile.
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
	assert_true(check.button_pressed)
	assert_eq(output.text, "res://a_specific")
	check.button_pressed = false
	assert_eq(store.cleared_scene_calls.size(), 1)
	assert_eq(store.cleared_scene_calls[0], "res://scenes/a.tscn")
	assert_false(check.button_pressed)
	assert_eq(output.text, "res://my_default")


func test_programmatic_uncheck_does_not_clear() -> void:
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


## Backend dropdown


func test_obs_unavailable_item_marked_with_suffix_and_default_tooltip() -> void:
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false)
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	var obs_i := _obs_item_index(dock)
	assert_true(option.get_item_text(obs_i).ends_with(TimeMachineDock.UNAVAILABLE_SUFFIX))
	assert_true(option.get_item_tooltip(obs_i).contains("ws://127.0.0.1:4455"))
	assert_eq(option.get_item_text(_movie_maker_item_index(dock)), "Godot Movie Maker")


func test_obs_unavailable_tooltip_names_custom_host_port() -> void:
	# The tooltip must name the host/port from settings, never a hardcoded
	# default.
	var settings := FakeSettings.new()
	settings.values["gd_time_machine/obs/host"] = "10.0.0.7"
	settings.values["gd_time_machine/obs/port"] = 9999
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false, settings)
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	assert_true(option.get_item_tooltip(_obs_item_index(dock)).contains("ws://10.0.0.7:9999"))


func test_obs_available_item_unmarked_with_empty_tooltip() -> void:
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	var obs_i := _obs_item_index(dock)
	assert_eq(option.get_item_text(obs_i), "OBS Studio")
	assert_eq(option.get_item_tooltip(obs_i), "")


func test_availability_flip_remarks_item_live() -> void:
	# A backend declaring availability_changed flips the dropdown synchronously
	# via the controller's forwarding: un-greys on become-available, re-marks
	# when it drops again.
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", false)
	var dock := ctx["dock"] as TimeMachineDock
	var obs := ctx["obs"] as MockOBSBackend
	var option: OptionButton = dock.get_node("Split/RightColumn/BackendRow/BackendOption")
	var obs_i := _obs_item_index(dock)
	assert_true(option.get_item_text(obs_i).ends_with(TimeMachineDock.UNAVAILABLE_SUFFIX))
	obs.available = true
	obs.availability_changed.emit(true)
	assert_eq(option.get_item_text(obs_i), "OBS Studio")
	assert_eq(option.get_item_tooltip(obs_i), "")
	obs.available = false
	obs.availability_changed.emit(false)
	assert_true(option.get_item_text(obs_i).ends_with(TimeMachineDock.UNAVAILABLE_SUFFIX))


## Format dropdown


func test_obs_active_limits_format_to_mp4_and_restores_on_switch() -> void:
	# Selecting OBS (which exposes get_native_formats()) narrows the format row
	# to its MP4 list; switching back to Movie Maker restores the multi-format
	# list (the has_method fallback).
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var option: OptionButton = dock.get_node(
		"Split/RightColumn/SettingsGroup/FormatRow/FormatOption"
	)
	controller.select_backend("OBS Studio")
	assert_true(option.item_count >= 1)
	for i in option.item_count:
		assert_true(option.get_item_text(i).contains("mp4"))
	controller.select_backend("Godot Movie Maker")
	assert_true(option.item_count >= 3)
	assert_eq(option.get_item_text(0), GdTMOutputFormat.display_name(GdTMOutputFormat.Format.AVI))


## OBS install dialog


func test_selecting_unavailable_obs_requests_install_dialog() -> void:
	var ctx := _build_dock_with_obs(
		FakeStore.new(), "res://scenes/a.tscn", false, FakeSettings.new()
	)
	var dock := ctx["dock"] as TimeMachineDock
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(dock._install_hint_popups, 1)
	assert_true(dock._obs_hint_label.text.contains("ws://127.0.0.1:4455"))


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


func test_selecting_available_obs_does_not_request_dialog() -> void:
	# The hint asserts OBS is NOT reachable, so it must never appear while an
	# available OBS Studio is selected — even with the suppression flag unset.
	var settings := FakeSettings.new()
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true, settings)
	var dock := ctx["dock"] as TimeMachineDock
	dock._on_backend_selected(_obs_item_index(dock))
	assert_eq(dock._install_hint_popups, 0)


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


## Recording status


func test_format_elapsed_mm_ss_and_h_mm_ss() -> void:
	assert_eq(TimeMachineDock.format_elapsed(0.0), "00:00")
	assert_eq(TimeMachineDock.format_elapsed(65.0), "01:05")
	assert_eq(TimeMachineDock.format_elapsed(599.0), "09:59")
	assert_eq(TimeMachineDock.format_elapsed(3600.0), "1:00:00")
	assert_eq(TimeMachineDock.format_elapsed(3661.0), "1:01:01")


func test_compose_recording_status() -> void:
	var s := TimeMachineDock.compose_recording_status("Screenshot", "res://dir/clip.png", 65.0)
	assert_true(s.begins_with("Recording ["))
	assert_true(s.contains("Screenshot"))
	assert_true(s.contains("clip.png"))
	assert_true(s.ends_with("(01:05)"))


func test_recording_started_arms_live_status() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var backend := ctx["backend"] as MockBackend
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	backend.recording = true
	dock._fake_time = 10.0
	controller.recording_started.emit("Mock", "res://media/captures/demo.png")
	assert_true(label.text.begins_with("Recording ["))
	assert_eq(dock._recording_started_at, 10.0)
	assert_eq(dock._recording_backend_name, "Mock")
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
	controller.recording_started.emit("Mock", "res://media/captures/demo.png")
	# 65s elapsed → mm:ss.
	dock._fake_time = 75.0
	dock._on_status_tick()
	assert_true(label.text.begins_with("Recording ["))
	assert_true(label.text.ends_with("(01:05)"))
	# Past an hour → h:mm:ss.
	dock._fake_time = 10.0 + 3661.0
	dock._on_status_tick()
	assert_true(label.text.ends_with("(1:01:01)"))


func test_recording_error_sets_error_status() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	var message := "Scene did not start"
	controller.recording_error.emit("Mock", message)
	assert_true(label.text.begins_with("Error:"))
	assert_true(label.text.contains(message))


func test_recording_notice_sets_status_message() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	var message := "Captured 60 frames at 60 fps (target 60)"
	controller.recording_notice.emit("Mock", message)
	assert_eq(label.text, message)


func test_obs_stop_shows_saved_not_converting() -> void:
	# BackendOBS records MP4 natively (get_native_formats → [MP4]) and never
	# emits recording_converted, so a stopped OBS recording must land on
	# "Saved …", not a dangling "Converting to mp4…" status.
	var ctx := _build_dock_with_obs(FakeStore.new(), "res://scenes/a.tscn", true)
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	controller.select_backend("OBS Studio")
	controller.recording_stopped.emit("OBS Studio", "res://media/captures/obs_happy.mp4")
	assert_true(label.text.begins_with("Saved "))
	assert_true(label.text.ends_with("obs_happy.mp4"))
	assert_false(label.text.contains("Converting"))


func test_recording_converted_shows_saved_file() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/a.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var controller := ctx["controller"] as RecorderController
	var label: Label = dock.get_node("Split/RightColumn/StatusRow/StatusLabel")
	controller.recording_converted.emit("Mock", "res://media/captures/demo.mp4")
	assert_true(label.text.begins_with("Saved "))
	assert_true(label.text.ends_with("demo.mp4"))


## Record shortcut


func test_set_record_shortcut_attaches_shortcut_and_tooltip() -> void:
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
	assert_true(button.tooltip_text.begins_with(original_tooltip))
	assert_true(button.tooltip_text.contains("(%s)" % shortcut.get_as_text()))


func test_set_record_shortcut_before_ready_applies_later() -> void:
	# The plugin fallback may attach the shortcut before the dock's button
	# exists; it must be applied once _ready builds the UI.
	var controller: RecorderController = add_child_autofree(RecorderController.new())
	var backend := MockBackend.new()
	controller.register_backend(backend)
	var dock: TimeMachineDock = load(DOCK_SCENE).instantiate()
	dock.get_node("Split/RightColumn/SettingsGroup/SceneRow/SceneEdit").text = "res://scenes/a.tscn"
	dock.setup(controller, FakeStore.new())
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


## Output path building


func test_in_place_output_path_has_no_extension() -> void:
	# The IN_PLACE backend owns the output layout ("<base>.frames/…"); a
	# format extension would just pollute the base path. Output goes to an
	# absolute /tmp dir so DirAccess.make_dir_recursive_absolute never touches
	# the repo.
	var store := FakeStore.new()
	var ctx := _build_dock_with_mode(
		store, "res://scenes/demo.tscn", RecorderBackend.CaptureMode.IN_PLACE
	)
	var dock := ctx["dock"] as TimeMachineDock
	var profile := RecordingProfile.new()
	profile.scene_path = "res://scenes/demo.tscn"
	profile.output_format = GdTMOutputFormat.Format.PNG
	profile.output_dir = "/tmp/gdtime_dock_io_inplace"
	var path: String = dock._build_output_path_for_profile(profile, profile.output_dir)
	assert_false(path.ends_with(".png"))
	assert_true(path.contains("/demo_"))


func test_restart_output_path_appends_extension() -> void:
	var store := FakeStore.new()
	var ctx := _build_dock(store, "res://scenes/demo.tscn")
	var dock := ctx["dock"] as TimeMachineDock
	var profile := RecordingProfile.new()
	profile.scene_path = "res://scenes/demo.tscn"
	profile.output_format = GdTMOutputFormat.Format.PNG
	profile.output_dir = "/tmp/gdtime_dock_io_restart"
	var path: String = dock._build_output_path_for_profile(profile, profile.output_dir)
	assert_true(path.ends_with(".png"))
	assert_true(path.contains("/demo_"))
