@tool
extends VBoxContainer
class_name TimeMachineDock

## Minimal GdTimeMachine dock UI.
##
## Backend selector, scene picker, format selector, duration/FPS, output
## directory, per-scene override, status line, and a Record/Stop toggle.
## All recording control goes through the RecorderController — the dock never
## talks to a backend directly.
##
## Configuration persists in two layers:
## - Defaults in EditorSettings under gd_time_machine/* (user-wide).
## - Per-scene overrides in addons/GdTimeMachine/config/state/profiles.cfg
##   (project-local, localized under the addon).
##
## The scene field follows the open scene automatically (plugin forwards
## EditorPlugin.scene_changed). On a scene switch the previous scene's profile
## is saved when per-scene mode is on, then the new scene's profile (scene
## override > default) is loaded.
##
## The per-scene checkbox ("Remember settings for this scene") is the single
## per-scene control: checked = the scene's settings are saved to and loaded
## from its own profile on scene switch; unchecked = the default profile is
## used, and any stored override for the current scene is cleared.

## Fallback output directory when no setting is stored.
const DEFAULT_OUTPUT_DIR := "res://media/captures"

## Default recording duration in seconds (0 means manual in build_config()).
const DEFAULT_DURATION := 30.0

## Default capture FPS.
const DEFAULT_FPS := 60.0

## Status light color for the idle state.
const COLOR_IDLE := Color("9e9e9e")

## Status light color while recording.
const COLOR_RECORDING := Color("4caf50")

## Status light color after a recording error.
const COLOR_ERROR := Color("e03131")

## Icon path for the record state.
const ICON_RECORD_PATH := "res://addons/GdTimeMachine/ui/icons/icon_record.svg"

## Icon path for the stop state.
const ICON_STOP_PATH := "res://addons/GdTimeMachine/ui/icons/icon_stop.svg"

## Icon path for the dock's brand logo (title bar).
const ICON_LOGO_PATH := "res://addons/GdTimeMachine/ui/icons/icon_logo.svg"

## Loaded record icon (scaled to button height — see _ready()).
var _icon_record: Texture2D

## Loaded stop icon (scaled to button height — see _ready()).
var _icon_stop: Texture2D

## Loaded brand logo (full-size; the TitleIcon TextureRect scales it to fit).
var _icon_logo: Texture2D

## Controller the dock talks to; injected via setup() before _ready().
var _controller: RecorderController

## Config store (defaults + per-scene overrides); injected via setup().
var _config_store: ConfigStore

## Guards the one-time UI wiring in _apply_setup().
var _setup_applied := false

## True while _load_profile_into_ui is applying values, to suppress _persist.
var _applying_profile := false

## True while _refresh_per_scene_state is syncing the checkbox programmatically;
## setting button_pressed emits toggled, which must not trigger the
## clear/fallback side effects of _on_per_scene_toggled.
var _syncing_scene_state := false

## Scene path whose per-scene profile was just flushed by on_editor_scene_closed.
## The scene_changed that follows a tab close must not re-save it.
var _flushed_on_close := ""

## Dock title icon (shows the brand logo).
@onready var _title_icon: TextureRect = $Split/LeftColumn/TitleIcon

## Backend selector dropdown.
@onready var _backend_option: OptionButton = $Split/RightColumn/BackendRow/BackendOption

## Row holding the scene picker (hidden for in-place backends).
@onready var _scene_row: HBoxContainer = $Split/RightColumn/SettingsGroup/SceneRow

## Scene path to record.
@onready var _scene_edit: LineEdit = $Split/RightColumn/SettingsGroup/SceneRow/SceneEdit

## Fills _scene_edit with the currently open scene.
@onready var _use_current_button: Button = $Split/RightColumn/SettingsGroup/SceneRow/UseCurrentButton

## Row holding the format picker.
@onready var _format_row: HBoxContainer = $Split/RightColumn/SettingsGroup/FormatRow

## Format selector dropdown.
@onready var _format_option: OptionButton = $Split/RightColumn/SettingsGroup/FormatRow/FormatOption

## Warning label for formats that need a notice (e.g. AVI 4GB).
@onready
var _format_warning_label: Label = $Split/RightColumn/SettingsGroup/FormatWarningRow/FormatWarningLabel

## Recording duration in seconds (0 = manual).
@onready var _duration_spin: SpinBox = $Split/RightColumn/SettingsGroup/DurationRow/DurationSpin

## Capture FPS.
@onready var _fps_spin: SpinBox = $Split/RightColumn/SettingsGroup/FpsRow/FpsSpin

## Output directory for recordings.
@onready var _output_edit: LineEdit = $Split/RightColumn/SettingsGroup/OutputRow/OutputEdit

## Per-scene override checkbox.
@onready var _per_scene_check: CheckBox = $Split/LeftColumn/PerSceneRow/PerSceneCheck

## Status indicator light.
@onready var _status_light: ColorRect = $Split/RightColumn/StatusRow/StatusLight

## Status text label.
@onready var _status_label: Label = $Split/RightColumn/StatusRow/StatusLabel

## Record/Stop toggle button.
@onready var _record_button: Button = $Split/LeftColumn/RecordButton


## Called by plugin.gd before the dock enters the tree; stores the
## controller and optional config store. UI wiring happens in _ready().
func setup(controller: RecorderController, config_store: ConfigStore = null) -> void:
	_controller = controller
	_config_store = config_store
	if is_inside_tree():
		_apply_setup()


## Loads icons, wires signals, sets tooltips, and applies the controller
## setup (if the controller is already available).
func _ready() -> void:
	# Icons are loaded lazily (not preloaded): during the editor's first
	# import scan the SVG files are not yet imported, and a parse-time
	# preload would fail. After import they resolve on the next load. The
	# record/stop glyphs are large non-square SVGs, so they're scaled down to
	# button height via GdTMIconFactory; the logo needs no pre-scale (the
	# TitleIcon TextureRect fits it into the title bar).
	_icon_record = GdTMIconFactory.scaled_texture(
		ICON_RECORD_PATH, GdTMIconFactory.DOCKS_BUTTON_HEIGHT
	)
	_icon_stop = GdTMIconFactory.scaled_texture(ICON_STOP_PATH, GdTMIconFactory.DOCKS_BUTTON_HEIGHT)
	_icon_logo = load(ICON_LOGO_PATH) as Texture2D
	_title_icon.texture = _icon_logo
	_record_button.icon = _icon_record
	_record_button.text = "Record"
	_backend_option.item_selected.connect(_on_backend_selected)
	_use_current_button.pressed.connect(_on_use_current_pressed)
	_record_button.pressed.connect(_on_record_pressed)
	_output_edit.text_changed.connect(func(_t): _on_output_changed())
	_output_edit.tooltip_text = "Directory where recordings are saved. File names are auto-generated from scene name + timestamp."
	_duration_spin.value_changed.connect(func(_v): _on_duration_changed())
	_fps_spin.value_changed.connect(func(_v): _on_fps_changed())
	_scene_edit.text_changed.connect(_on_scene_edit_changed)
	if _controller != null:
		_apply_setup()


## One-time setup: tooltips, signal wiring, backend/format population,
## settings load, scene prefill, and initial UI state.
func _apply_setup() -> void:
	if _setup_applied:
		return
	_setup_applied = true
	_ensure_config_store()
	_duration_spin.min_value = 0.0
	_duration_spin.tooltip_text = "0 = record until Stop is pressed. Positive value auto-stops after that many seconds."
	$Split/RightColumn/SettingsGroup/DurationRow.tooltip_text = _duration_spin.tooltip_text
	$Split/RightColumn/SettingsGroup/DurationRow/DurationLabel.tooltip_text = (
		_duration_spin.tooltip_text
	)

	_update_backend_tooltip()
	_scene_edit.tooltip_text = "Scene to launch when recording starts. Follows the open scene automatically; empty uses the current or main scene."
	_use_current_button.tooltip_text = "Re-sync the field to the currently open scene (the field follows it automatically)."
	_fps_spin.tooltip_text = "Target frames per second for the recording."
	$Split/RightColumn/SettingsGroup/FpsRow.tooltip_text = _fps_spin.tooltip_text
	$Split/RightColumn/SettingsGroup/FpsRow/FpsLabel.tooltip_text = _fps_spin.tooltip_text
	$Split/RightColumn/SettingsGroup/SceneRow.tooltip_text = _scene_edit.tooltip_text
	$Split/RightColumn/SettingsGroup/OutputRow.tooltip_text = _output_edit.tooltip_text
	$Split/RightColumn/SettingsGroup/FormatRow.tooltip_text = (
		"Output format. AVI has a 4 GB cap, OGV is smaller, PNG is a lossless "
		+ "sequence, JPG is a compact lossy sequence. MP4/WebM require ffmpeg."
	)
	_format_option.tooltip_text = "Output format for recordings."
	_format_warning_label.tooltip_text = "Format-specific notice."
	_per_scene_check.tooltip_text = "When checked, this scene's settings are saved as its own profile when you switch away, and reloaded when you come back.\nWhen unchecked, the default profile is used and any stored per-scene profile for this scene is cleared."
	_record_button.tooltip_text = "Start or stop recording with the settings above."

	_format_option.item_selected.connect(_on_format_selected)
	_per_scene_check.toggled.connect(_on_per_scene_toggled)

	_controller.backend_changed.connect(_on_backend_changed)
	_controller.recording_started.connect(_on_recording_started)
	_controller.recording_stopped.connect(_on_recording_stopped)
	_controller.recording_error.connect(_on_recording_error)
	_controller.recording_notice.connect(_on_recording_notice)
	if _controller.has_signal("recording_converted"):
		_controller.recording_converted.connect(_on_recording_converted)
	_populate_backends()
	_populate_formats()
	_load_settings()
	# Guarantee a valid format selection for the active backend (a stored
	# format the backend doesn't support falls back to its first allowed one).
	_repopulate_formats_for_backend()
	_prefill_scene()
	_update_backend_visibility()
	_refresh_per_scene_state()
	_set_recording_ui(false)
	_set_status("Ready", COLOR_IDLE)


## Ensures _config_store exists; creates a composite store by default.
func _ensure_config_store() -> void:
	if _config_store == null:
		_config_store = CompositeConfigStore.new()


## Fills the backend dropdown from the controller's registered backends.
func _populate_backends() -> void:
	_backend_option.clear()
	for name in _controller.get_backend_names():
		_backend_option.add_item(str(name))
	_select_backend_item(
		_controller.active_backend.get_backend_name() if _controller.active_backend else ""
	)


## Formats the active backend actually supports: screenshot (IN_PLACE) natively
## writes PNG/JPG frames but can convert to any container via ffmpeg; Movie Maker
## natively writes AVI/OGV/PNG and needs ffmpeg for MP4/WebM.
func _get_allowed_formats() -> Array:
	if (
		_controller != null
		and _controller.get_capture_mode() == RecorderBackend.CaptureMode.IN_PLACE
	):
		return [
			GdTMOutputFormat.Format.PNG,
			GdTMOutputFormat.Format.JPG,
			GdTMOutputFormat.Format.MP4,
			GdTMOutputFormat.Format.WEBM,
			GdTMOutputFormat.Format.AVI,
			GdTMOutputFormat.Format.OGV,
		]
	return [
		GdTMOutputFormat.Format.AVI,
		GdTMOutputFormat.Format.OGV,
		GdTMOutputFormat.Format.PNG,
		GdTMOutputFormat.Format.MP4,
		GdTMOutputFormat.Format.WEBM,
	]


## Fills the format dropdown from the formats the active backend supports.
func _populate_formats() -> void:
	_format_option.clear()
	for fmt in _get_allowed_formats():
		_format_option.add_item(GdTMOutputFormat.display_name(fmt))


## Selects the dropdown item whose text matches backend_name.
func _select_backend_item(backend_name: String) -> void:
	for i in _backend_option.item_count:
		if _backend_option.get_item_text(i) == backend_name:
			_backend_option.select(i)
			return


## Selects the format dropdown item matching the given format enum. Returns
## true when a matching item was found and selected.
func _select_format_item(format: GdTMOutputFormat.Format) -> bool:
	var target := GdTMOutputFormat.display_name(format)
	for i in _format_option.item_count:
		if _format_option.get_item_text(i) == target:
			_format_option.select(i)
			return true
	# Fallback: match by extension substring.
	var ext := GdTMOutputFormat.to_extension(format)
	for i in _format_option.item_count:
		if _format_option.get_item_text(i).to_lower().contains(ext):
			_format_option.select(i)
			return true
	return false


## Returns the currently selected output format from the dropdown.
func _get_selected_format() -> GdTMOutputFormat.Format:
	if _format_option.selected < 0:
		return GdTMOutputFormat.DEFAULT
	var text := _format_option.get_item_text(_format_option.selected)
	return GdTMOutputFormat.from_string(text)


## Updates the warning label for the selected format.
func _update_format_warning() -> void:
	var fmt := _get_selected_format()
	var warning := GdTMOutputFormat.warning_text(fmt)
	_format_warning_label.text = warning
	_format_warning_label.visible = not warning.is_empty()


## Loads a RecordingProfile's values into the UI controls.
func _load_profile_into_ui(profile: RecordingProfile) -> void:
	_applying_profile = true
	_output_edit.text = (
		profile.output_dir if not profile.output_dir.is_empty() else DEFAULT_OUTPUT_DIR
	)
	_duration_spin.value = profile.duration
	_fps_spin.value = float(profile.fps) if profile.fps > 0 else DEFAULT_FPS
	_select_format_item(profile.output_format)
	_update_format_warning()
	if not profile.backend_name.is_empty():
		_select_backend_item(profile.backend_name)
		if _controller != null:
			_controller.select_backend(profile.backend_name)
	_applying_profile = false


## Builds a RecordingProfile from the current UI values.
func _build_profile_from_ui() -> RecordingProfile:
	var p := RecordingProfile.new()
	p.output_dir = _output_edit.text.strip_edges()
	if p.output_dir.is_empty():
		p.output_dir = DEFAULT_OUTPUT_DIR
	p.output_format = _get_selected_format()
	p.fps = int(_fps_spin.value)
	p.duration = 0.0 if _duration_spin.value <= 0.0 else float(_duration_spin.value)
	p.scene_path = _scene_edit.text.strip_edges()
	if _backend_option.selected >= 0:
		p.backend_name = _backend_option.get_item_text(_backend_option.selected)
	return p


## Switches the controller to the backend chosen in the dropdown and
## persists the preference to the default profile.
func _on_backend_selected(index: int) -> void:
	if _controller == null:
		return
	var name := _backend_option.get_item_text(index)
	_controller.select_backend(name)
	if not _applying_profile:
		_persist_default_profile()


## Switches format and updates warning + persistence.
func _on_format_selected(_index: int) -> void:
	_update_format_warning()
	if not _applying_profile:
		_persist_default_profile()


## Handles output directory edits.
func _on_output_changed() -> void:
	if _applying_profile:
		return
	_persist_default_profile()


## Handles duration edits.
func _on_duration_changed() -> void:
	if _applying_profile:
		return
	_persist_default_profile()


## Handles FPS edits.
func _on_fps_changed() -> void:
	if _applying_profile:
		return
	_persist_default_profile()


## Handles scene path edits — refresh per-scene state.
func _on_scene_edit_changed(_new_text: String) -> void:
	_refresh_per_scene_state()


## Handles per-scene checkbox toggle. The checkbox is the single per-scene
## control: unchecking clears the stored override for the current scene and
## falls back to the default profile; checking loads the stored override if
## one exists (the save happens on the next scene switch, not here).
func _on_per_scene_toggled(button_pressed: bool) -> void:
	if _syncing_scene_state:
		# Programmatic checkbox sync (e.g. _refresh_per_scene_state) must not
		# trigger the clear/fallback side effects.
		return
	var sp := _scene_edit.text.strip_edges()
	if sp.is_empty():
		return
	if not button_pressed:
		# Leaving per-scene mode: drop the stored override so the unchecked
		# state is durable across sessions, then fall back to the default
		# profile (this replaces the removed Clear button).
		_config_store.clear_scene_profile(sp)
		_load_profile_into_ui(_config_store.get_default_profile())
	else:
		# Entering per-scene mode: if a scene profile exists, load it;
		# otherwise keep current UI values as the candidate profile (the save
		# happens on the next scene switch via _auto_save_current_scene_profile).
		var scene_profile := _config_store.get_scene_profile(sp)
		if scene_profile != null:
			_load_profile_into_ui(scene_profile)


## Refreshes per-scene checkbox and optionally loads the scene profile.
func _refresh_per_scene_state() -> void:
	_ensure_config_store()
	var sp := _scene_edit.text.strip_edges()
	if sp.is_empty():
		_per_scene_check.disabled = true
		_syncing_scene_state = true
		_per_scene_check.button_pressed = false
		_syncing_scene_state = false
		return
	_per_scene_check.disabled = false
	var existing := _config_store.get_scene_profile(sp)
	if existing != null:
		# Scene override exists — reflect it and load it.
		if not _per_scene_check.button_pressed:
			_syncing_scene_state = true
			_per_scene_check.button_pressed = true
			_syncing_scene_state = false
		_applying_profile = true
		_load_profile_into_ui(existing)
		_applying_profile = false
	else:
		# No override — checkbox unchecked.
		_syncing_scene_state = true
		_per_scene_check.button_pressed = false
		_syncing_scene_state = false
	_update_format_warning()


## Reacts to a backend change made elsewhere: re-selects dropdown, re-fills
## the format list for the new backend's supported formats, and updates
## visibility/per-scene state.
func _on_backend_changed(backend_name: String) -> void:
	_select_backend_item(backend_name)
	_update_backend_visibility()
	_update_backend_tooltip()
	_repopulate_formats_for_backend()
	_persist_default_profile()


## Rebuilds the format dropdown for the active backend, keeping the current
## selection when the backend still supports it and falling back to the first
## allowed format otherwise (so the dropdown always has a valid selection).
func _repopulate_formats_for_backend() -> void:
	var current := _get_selected_format()
	_populate_formats()
	if not _select_format_item(current):
		if _format_option.item_count > 0:
			_format_option.select(0)
	_update_format_warning()


## Backend dropdown tooltip: the generic behavior note plus the active
## backend's own description (e.g. the screenshot backend's foreground/no-audio
## limits come from get_description(), not the UI layer).
func _update_backend_tooltip() -> void:
	var note := (
		"Recording backend. Movie Maker restarts the scene; in-place backends "
		+ "record the running scene without restarting it."
	)
	var description := ""
	if _controller != null and _controller.active_backend != null:
		description = _controller.active_backend.get_description()
	if description.is_empty():
		_backend_option.tooltip_text = note
	else:
		_backend_option.tooltip_text = "%s\n%s" % [note, description]


## In-place backends record the running scene and stop without killing it,
## but they still honor the scene picker when no scene is playing: pressing
## Record launches the requested scene first (same UX as Movie Maker),
## then starts screenshot capture. The scene row stays visible for both
## modes; the format row is visible too, filtered to the backend's supported
## formats by _get_allowed_formats() (PNG/JPG for screenshot, AVI/OGV/PNG for
## Movie Maker).
func _update_backend_visibility() -> void:
	if _controller == null:
		return
	var in_place := _controller.get_capture_mode() == RecorderBackend.CaptureMode.IN_PLACE
	# Scene picker is always visible — used as launch target when idle.
	if _scene_row != null:
		_scene_row.visible = true
	if _format_row != null:
		_format_row.visible = true


## Handles the "Use Current" button: fills the scene field and refreshes
## per-scene state.
func _on_use_current_pressed() -> void:
	_use_current_scene_path()
	_refresh_per_scene_state()


## Prefills the scene field with the current scene on first open, unless
## the user already entered a path.
func _prefill_scene() -> void:
	if _scene_edit.text.strip_edges().is_empty():
		_use_current_scene_path()


## Sets _scene_edit to the currently edited scene, falling back to the
## project's main scene if none is open.
func _use_current_scene_path() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root != null and not root.scene_file_path.is_empty():
		_scene_edit.text = root.scene_file_path
		return
	var main: Variant = ProjectSettings.get_setting("application/run/main_scene")
	if main != null and not str(main).is_empty():
		_scene_edit.text = str(main)


## Called by plugin.gd when the editor's active scene changes (scene tab
## switch). The scene field always follows the open scene:
##   1. Auto-save: the current UI is saved as the per-scene profile of the
##      scene being left — but only when per-scene mode is checked (opt-in).
##   2. Sync: the scene field is set to the newly open scene.
##   3. Auto-load: the new scene's resolved profile (scene override > default)
##      is loaded into the UI, and per-scene state is refreshed.
## No-op while recording, so a scene switch never disturbs an active session.
func on_editor_scene_changed(new_path: String) -> void:
	if not _setup_applied:
		return
	if _controller != null and _controller.is_recording():
		return
	_auto_save_current_scene_profile()
	_scene_edit.text = new_path
	_load_settings()
	_refresh_per_scene_state()


## Called by plugin.gd when a scene tab is closed (EditorPlugin.scene_closed).
## If the closed scene is the one currently reflected in the field, the
## current UI is saved as its per-scene profile — covering the close paths
## where no scene_changed follows (e.g. closing the last open scene). The
## _flushed_on_close guard stops the immediately following scene_changed (the
## editor switches to the next tab after a close) from re-saving the same
## values.
func on_editor_scene_closed(closed_path: String) -> void:
	if not _setup_applied:
		return
	if _controller != null and _controller.is_recording():
		return
	var sp := _scene_edit.text.strip_edges()
	if sp != closed_path.strip_edges():
		return
	_auto_save_current_scene_profile()
	_flushed_on_close = sp


## Saves the current UI values as the per-scene profile for the scene in the
## field — the "auto-save on switch" half of scene tracking. Only fires when
## per-scene mode is checked and the scene has a saved path (untitled scenes
## have no stable profile key). This is the only place per-scene profiles are
## written.
func _auto_save_current_scene_profile() -> void:
	if not _per_scene_check.button_pressed:
		return
	var sp := _scene_edit.text.strip_edges()
	if sp.is_empty():
		return
	if sp == _flushed_on_close:
		# The scene was just flushed by on_editor_scene_closed; the switch
		# that follows a tab close must not write it a second time.
		_flushed_on_close = ""
		return
	_ensure_config_store()
	var profile := _build_profile_from_ui()
	# The store key carries the scene path; never embed it in the values.
	profile.scene_path = ""
	_config_store.save_scene_profile(sp, profile)


## Loads persisted settings into the UI. Uses the config store's default and
## per-scene resolution, falling back to local constants.
func _load_settings() -> void:
	_ensure_config_store()
	var scene_path := _scene_edit.text.strip_edges()
	var profile: RecordingProfile
	if not scene_path.is_empty():
		profile = _config_store.resolve_profile(scene_path)
	else:
		profile = _config_store.get_default_profile()
	_load_profile_into_ui(profile)
	# Also sync controller backend from profile if set.
	if not profile.backend_name.is_empty() and _controller != null:
		_controller.select_backend(profile.backend_name)


## Persists current UI as the default profile via the config store.
func _persist_default_profile() -> void:
	if _applying_profile:
		return
	_ensure_config_store()
	var profile := _build_profile_from_ui()
	# Default profile should not carry scene_path.
	profile.scene_path = ""
	_config_store.save_default_profile(profile)


## Back-compat alias: writes the current UI values to the default store.
func _persist_settings() -> void:
	_persist_default_profile()


## Toggles recording via the controller, persisting default first; starts
## with the config built by build_config().
func _on_record_pressed() -> void:
	if _controller == null:
		return
	if not _per_scene_check.button_pressed:
		_persist_default_profile()
	if _controller.is_recording():
		_controller.stop_recording()
	else:
		_controller.start_recording(build_config())


## Builds the recording config from the currently configured UI fields and
## resolved effective profile (scene override > default).
## Public so other surfaces reuse the exact settings shown in this tab.
func build_config() -> Dictionary:
	var effective: RecordingProfile
	var scene_path := _scene_edit.text.strip_edges()
	_ensure_config_store()
	if not scene_path.is_empty() and _per_scene_check.button_pressed:
		# If per-scene checkbox is on and a scene profile exists, use it;
		# otherwise use current UI as effective.
		var sp := _config_store.get_scene_profile(scene_path)
		if sp != null:
			effective = sp
			# Scene path still comes from the UI so the file timestamp uses it.
			effective.scene_path = scene_path
		else:
			effective = _build_profile_from_ui()
	else:
		effective = _build_profile_from_ui()

	# Resolve output dir fallback.
	var output_dir := effective.output_dir
	if output_dir.is_empty():
		output_dir = DEFAULT_OUTPUT_DIR

	return {
		"output_path": _build_output_path_for_profile(effective, output_dir),
		"scene_path": effective.scene_path if not effective.scene_path.is_empty() else scene_path,
		"fps": effective.fps,
		"duration": effective.duration,
		"output_format": GdTMOutputFormat.to_extension(effective.output_format),
	}


## Builds output file path for a given profile and resolved dir.
func _build_output_path_for_profile(profile: RecordingProfile, output_dir: String) -> String:
	var dir := output_dir.strip_edges()
	if dir.is_empty():
		dir = DEFAULT_OUTPUT_DIR
	var scene_path := (
		profile.scene_path if not profile.scene_path.is_empty() else _scene_edit.text.strip_edges()
	)
	var scene_name := "scene"
	if not scene_path.is_empty():
		scene_name = scene_path.get_file().get_basename()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	# In-place backends get a bare base path: the backend owns the output
	# layout ("<base>.frames/…"), and a format extension would just pollute it.
	var in_place := (
		_controller != null
		and _controller.get_capture_mode() == RecorderBackend.CaptureMode.IN_PLACE
	)
	var path := "%s/%s_%s" % [dir, scene_name, stamp]
	if not in_place:
		var ext := GdTMOutputFormat.to_extension(profile.output_format)
		path = "%s.%s" % [path, ext]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_ensure_gdignore(dir)
	return path


## Creates an empty .gdignore in the given output dir (if not already present)
## so Godot skips importing any PNG/JPG frames written there. Handles both
## res:// and absolute paths.
func _ensure_gdignore(dir: String) -> void:
	var abs_dir := ProjectSettings.globalize_path(dir)
	var gdignore_path := abs_dir.path_join(".gdignore")
	if FileAccess.file_exists(gdignore_path):
		return
	var file := FileAccess.open(gdignore_path, FileAccess.WRITE)
	if file == null:
		push_warning("GdTimeMachine: could not create .gdignore in %s" % abs_dir)
		return
	file.close()


## Builds the full output file path (back-compat): dir + scene + timestamp.
func _build_output_path() -> String:
	var profile := _build_profile_from_ui()
	return _build_output_path_for_profile(profile, profile.output_dir)


## Updates the UI when a recording starts (button → Stop, green status).
func _on_recording_started(_backend_name: String, output_path: String) -> void:
	_set_recording_ui(true)
	_set_status("Recording → %s" % output_path.get_file(), COLOR_RECORDING)


## Updates the UI when a recording stops (button → Record, idle status).
func _on_recording_stopped(_backend_name: String, output_path: String) -> void:
	_set_recording_ui(false)
	# If MP4/WebM conversion is expected (any backend that writes via ffmpeg tier-2),
	# show Converting… until converted. Heuristic: when output is still AVI but
	# selected format is MP4/WebM, or when backend is screenshot with non-native
	# format.
	if _expects_conversion():
		_set_status(
			"Converting to %s…" % GdTMOutputFormat.to_extension(_get_selected_format()), COLOR_IDLE
		)
	else:
		_set_status("Saved %s" % output_path.get_file(), COLOR_IDLE)


## Whether the current selected format requires ffmpeg conversion given the capture mode.
func _expects_conversion() -> bool:
	var fmt := _get_selected_format()
	# IN_PLACE: PNG/JPG are native frames, rest need ffmpeg.
	if (
		_controller != null
		and _controller.get_capture_mode() == RecorderBackend.CaptureMode.IN_PLACE
	):
		return GdTMOutputFormat.frames_need_ffmpeg(fmt)
	# RESTART: only MP4/WEBM need ffmpeg (AVI/OGV/PNG native via engine).
	return GdTMOutputFormat.is_tier2_format(fmt)


## Updates the UI when a recording errors (button → Record, error status).
func _on_recording_error(_backend_name: String, message: String) -> void:
	_set_recording_ui(false)
	_set_status("Error: %s" % message, COLOR_ERROR)


## Shows an info-level message from the active backend (capture statistics, a
## zero/low-frame hint, …) in the status line. The backend composes the
## message; this handler only prints it. Converting… status is preserved when
## appropriate by _on_recording_stopped's heuristic; after conversion finishes
## the converted handler takes over.
func _on_recording_notice(_backend_name: String, message: String) -> void:
	# If message is "Converting…" from backend itself, respect it.
	if "Converting" in message:
		_set_status(message, COLOR_IDLE)
		return
	_set_status(message, COLOR_IDLE)


func _on_recording_converted(_backend_name: String, clip_path: String) -> void:
	_set_recording_ui(false)
	_set_status("Saved %s" % clip_path.get_file(), COLOR_IDLE)


## Switches the record button between Record/Stop look and disables config.
func _set_recording_ui(recording: bool) -> void:
	if recording:
		_record_button.icon = _icon_stop
		_record_button.text = "Stop"
		_record_button.add_theme_color_override("font_color", COLOR_RECORDING)
	else:
		_record_button.icon = _icon_record
		_record_button.text = "Record"
		_record_button.remove_theme_color_override("font_color")
	_set_controls_enabled(not recording)


## Enables or disables the configuration controls while recording.
func _set_controls_enabled(enabled: bool) -> void:
	_backend_option.disabled = not enabled
	_scene_edit.editable = enabled
	_use_current_button.disabled = not enabled
	_format_option.disabled = not enabled
	_duration_spin.editable = enabled
	_fps_spin.editable = enabled
	_output_edit.editable = enabled
	_per_scene_check.disabled = not enabled or _scene_edit.text.strip_edges().is_empty()


## Sets the status label text and status light color.
func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_light.color = color
