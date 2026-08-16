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

## Backend name the install-hint dialog applies to (BackendOBS.get_backend_name()).
## OBS is the only backend that can be unavailable; the suffix + tooltip marking
## below applies to any unavailable backend, but the dialog is OBS-specific.
const OBS_BACKEND_NAME := "OBS Studio"

## Suffix appended to a dropdown item whose backend reports itself unavailable.
const UNAVAILABLE_SUFFIX := " — not available"

## EditorSettings key for the install-hint suppression flag (default false,
## registered in plugin.gd). True = never show the hint again.
const OBS_HINT_DONT_SHOW_SETTING := "hints/dont_show_obs_hint"

## OBS download/install page opened by the dialog's link.
const OBS_DOWNLOAD_URL := "https://obsproject.com"

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

## Monotonic seconds (via _now()) when the current recording started; 0 while
## idle. Drives the live elapsed status in the status line.
var _recording_started_at := 0.0

## Backend name of the active recording (from recording_started).
var _recording_backend_name := ""

## Output path of the active recording (from recording_started).
var _recording_output_path := ""

## One-second repeating timer that refreshes the live elapsed status while
## recording; created lazily behind an is_inside_tree() guard.
var _status_timer: Timer

## Test seam: when >= 0.0, _now() returns this fixed value instead of the real
## clock, so GUT can drive elapsed-time assertions deterministically.
var _fake_time := -1.0

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

## Editor-wide record/stop shortcut to attach once the Record button exists;
## used as the fallback surface when the run-bar button is unavailable.
var _pending_record_shortcut: Shortcut = null

## Injected EditorSettings stand-in for headless GUT (mirrors BackendOBS's
## seam). When null, falls back to EditorInterface in editor context, else null.
var _editor_settings: Object = null

## Test seam: count of times the OBS install hint was requested to pop up.
## A headless DisplayServer can't reflect Window.visible, so tests assert on
## this counter instead of dialog.visible.
var _install_hint_popups := 0

## OBS install-hint AcceptDialog (tscn node). Built once; text set per show.
@onready var _obs_install_dialog: AcceptDialog = $ObsInstallDialog

## Dynamic body of the install hint (rebuilt per show).
@onready var _obs_hint_label: Label = $ObsInstallDialog/HintContent/HintLabel

## "Open obsproject.com" link button.
@onready
var _obs_hint_download: LinkButton = $ObsInstallDialog/HintContent/DownloadRow/DownloadButton

## "Don't show this hint again" checkbox.
@onready var _obs_hint_dont_show: CheckBox = $ObsInstallDialog/HintContent/DontShowAgain


## Called by plugin.gd before the dock enters the tree; stores the
## controller and optional config store. UI wiring happens in _ready().
func setup(controller: RecorderController, config_store: ConfigStore = null) -> void:
	_controller = controller
	_config_store = config_store
	if is_inside_tree():
		_apply_setup()


## Attaches the editor-wide record/stop shortcut to the dock's Record button
## and appends the combo to its tooltip for discoverability. Used as the
## fallback surface when the run-bar button is unavailable; no-op when the
## shortcut is null. If the button is not ready yet, the shortcut is applied
## once _ready() builds the UI.
func set_record_shortcut(shortcut: Shortcut) -> void:
	if shortcut == null:
		return
	if _record_button == null:
		_pending_record_shortcut = shortcut
		return
	_record_button.shortcut = shortcut
	var hint := shortcut.get_as_text()
	if not hint.is_empty() and not _record_button.tooltip_text.contains(hint):
		_record_button.tooltip_text = "%s (%s)" % [_record_button.tooltip_text, hint]


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
	# OBS install-hint dialog: persist "don't show again" on either exit path.
	_obs_install_dialog.confirmed.connect(_on_obs_install_dialog_closed)
	_obs_install_dialog.close_requested.connect(_on_obs_install_dialog_closed)
	_obs_hint_download.pressed.connect(_open_obs_download)
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

	# Apply a shortcut that arrived before the button was ready (plugin-level
	# fallback when the run-bar button is unavailable).
	if _pending_record_shortcut != null:
		var pending := _pending_record_shortcut
		_pending_record_shortcut = null
		set_record_shortcut(pending)

	_format_option.item_selected.connect(_on_format_selected)
	_per_scene_check.toggled.connect(_on_per_scene_toggled)

	_controller.backend_changed.connect(_on_backend_changed)
	_controller.recording_started.connect(_on_recording_started)
	_controller.recording_stopped.connect(_on_recording_stopped)
	_controller.recording_error.connect(_on_recording_error)
	_controller.recording_notice.connect(_on_recording_notice)
	if _controller.has_signal("recording_converted"):
		_controller.recording_converted.connect(_on_recording_converted)
	_controller.backend_availability_changed.connect(_on_backend_availability_changed)
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


## Fills the backend dropdown from the controller's registered backends. Each
## item's metadata carries the raw backend name (the item text may carry the
## " — not available" suffix), so selection/profile reads never see the suffix.
## Unavailable backends are kept selectable: a hard set_item_disabled would
## make the OBS install hint unreachable, and selection must be able to fire it.
func _populate_backends() -> void:
	_backend_option.clear()
	for name in _controller.get_backend_names():
		var backend_name := str(name)
		var i := _backend_option.item_count
		var available := _controller.is_backend_available(backend_name)
		_backend_option.add_item(_backend_label(backend_name, available))
		_backend_option.set_item_metadata(i, backend_name)
		if not available:
			_backend_option.set_item_tooltip(i, _unavailable_tooltip(backend_name))
	_select_backend_item(
		_controller.active_backend.get_backend_name() if _controller.active_backend else ""
	)


## Dropdown label for a backend: the plain name when available, otherwise the
## name plus the " — not available" suffix.
func _backend_label(backend_name: String, available: bool) -> String:
	if available:
		return backend_name
	return "%s%s" % [backend_name, UNAVAILABLE_SUFFIX]


## Tooltip for an unavailable backend item explaining why it is marked and
## what to do. OBS gets actionable WebSocket guidance naming the actual
## host/port from settings (never a hardcoded "OBS must be running"); other
## backends get a generic note.
func _unavailable_tooltip(backend_name: String) -> String:
	if backend_name != OBS_BACKEND_NAME:
		return "%s is currently unavailable." % backend_name
	return (
		(
			"%s is not reachable at %s. Install OBS Studio, enable the WebSocket "
			+ "server (Tools → WebSocket Server Settings → Enable WebSocket Server), "
			+ "and check gd_time_machine/obs/* (host/port/password) under Project > "
			+ "Editor Settings."
		)
		% [backend_name, _obs_target_text()]
	)


## Formats the active backend actually supports. A backend may declare exact
## native formats (BackendOBS → [MP4]) — then the dropdown offers exactly
## those. Guarded with has_method so Movie Maker / Screenshot keep their
## existing lists: screenshot (IN_PLACE) natively writes PNG/JPG frames but can
## convert to any container via ffmpeg; Movie Maker natively writes AVI/OGV/PNG
## and needs ffmpeg for MP4/WebM.
func _get_allowed_formats() -> Array:
	var backend := _controller.active_backend if _controller != null else null
	if backend != null and backend.has_method("get_native_formats"):
		return backend.get_native_formats()
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


## Selects the dropdown item whose metadata matches backend_name. Item text
## is not the identity (it can carry the " — not available" suffix).
func _select_backend_item(backend_name: String) -> void:
	for i in _backend_option.item_count:
		if str(_backend_option.get_item_metadata(i)) == backend_name:
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
		# Metadata carries the raw backend name (the item text may carry the
		# " — not available" suffix, which must never reach the stored profile).
		var meta: Variant = _backend_option.get_item_metadata(_backend_option.selected)
		var stored_name := str(meta) if meta != null else ""
		if stored_name.is_empty():
			stored_name = _backend_option.get_item_text(_backend_option.selected)
		p.backend_name = stored_name
	return p


## Switches the controller to the backend chosen in the dropdown and persists
## the preference to the default profile. When an unavailable OBS Studio is
## chosen, fires the install hint (repeatable until suppressed; recording
## itself still fails actionably from the backend's error path).
func _on_backend_selected(index: int) -> void:
	if _controller == null:
		return
	var name := str(_backend_option.get_item_metadata(index))
	if name.is_empty():
		name = _backend_option.get_item_text(index)
	_controller.select_backend(name)
	_maybe_show_obs_install_hint(name)
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


## Re-marks a backend's dropdown item when its availability flips async (OBS
## probe result), so the " — not available" suffix un-greys when OBS starts.
func _on_backend_availability_changed(backend_name: String, available: bool) -> void:
	for i in _backend_option.item_count:
		if str(_backend_option.get_item_metadata(i)) != backend_name:
			continue
		_backend_option.set_item_text(i, _backend_label(backend_name, available))
		if available:
			_backend_option.set_item_tooltip(i, "")
		else:
			_backend_option.set_item_tooltip(i, _unavailable_tooltip(backend_name))
		return


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


## Shows the OBS install hint when an unavailable OBS Studio item is selected
## (repeatable as a reminder until the user sets hints/dont_show_obs_hint; the
## flag is persisted when the box is ticked and the dialog closes). Suppressed
## while the flag is true. The body is rebuilt dynamically with the real
## settings host/port.
func _maybe_show_obs_install_hint(backend_name: String) -> void:
	if backend_name != OBS_BACKEND_NAME:
		return
	if _obs_install_dialog == null:
		return
	if bool(_read_setting(OBS_HINT_DONT_SHOW_SETTING, false)):
		return
	# Never hint at an OBS that is actually reachable — the dialog asserts the
	# opposite, so it must only appear while availability is false.
	if _controller != null and _controller.is_backend_available(backend_name):
		return
	_update_obs_install_dialog_text()
	_obs_hint_dont_show.button_pressed = false
	_install_hint_popups += 1
	_obs_install_dialog.popup_centered()


## "ws://host:port" resolved from the same OBS settings the backend reads.
func _obs_target_text() -> String:
	var host := str(_read_setting("gd_time_machine/obs/host", "127.0.0.1"))
	var port := int(_read_setting("gd_time_machine/obs/port", 4455))
	return "ws://%s:%d" % [host, port]


## Builds the install-hint body from the real settings host/port — never
## assume OBS is running; the text always names the actual target the backend
## would connect to.
func _update_obs_install_dialog_text() -> void:
	_obs_hint_label.text = (
		(
			"OBS Studio isn't running or reachable at %s.\n\n"
			+ "To record with OBS Studio:\n"
			+ "1. Install OBS Studio (obsproject.com — use the link below).\n"
			+ "2. Start OBS and enable the WebSocket server: Tools → WebSocket "
			+ "Server Settings → Enable WebSocket Server.\n"
			+ "3. If the server requires a password, set the same password under "
			+ "Project > Editor Settings → gd_time_machine/obs/password."
		)
		% _obs_target_text()
	)


## Opens the OBS download page in the system browser.
func _open_obs_download() -> void:
	OS.shell_open(OBS_DOWNLOAD_URL)


## Persists the "don't show again" flag when the dialog closes with the box
## ticked. Fires on both the OK button (confirmed) and the window X
## (close_requested) so the choice survives either exit path.
func _on_obs_install_dialog_closed() -> void:
	if _obs_hint_dont_show != null and _obs_hint_dont_show.button_pressed:
		var es := _get_es()
		if es != null and es.has_method("set_setting"):
			es.set_setting(OBS_HINT_DONT_SHOW_SETTING, true)


## Returns the settings store to read, or null outside the editor when no fake
## was injected. Mirrors BackendOBS._get_es() (the proven 4.x access path —
## Engine.has_singleton("EditorSettings") is dead code on 4.7).
func _get_es() -> Object:
	if _editor_settings != null:
		return _editor_settings
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return null


## First non-null value across EditorSettings → ProjectSettings → default.
func _read_setting(key: String, default: Variant) -> Variant:
	var es := _get_es()
	if es != null and es.has_method("get_setting"):
		var v: Variant = es.get_setting(key)
		if v != null:
			return v
	if ProjectSettings.has_setting(key):
		return ProjectSettings.get_setting(key)
	return default


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


## Updates the UI when a recording starts (button → Stop, green status, live
## elapsed timer armed). The status line becomes live: a 1-second timer
## refreshes "Recording [backend] → file (mm:ss)" until stop/error/converted.
func _on_recording_started(backend_name: String, output_path: String) -> void:
	_set_recording_ui(true)
	_recording_backend_name = backend_name
	_recording_output_path = output_path
	_recording_started_at = _now()
	_start_status_timer()
	_set_status(compose_recording_status(backend_name, output_path, 0.0), COLOR_RECORDING)


## Updates the UI when a recording stops (button → Record, idle status). The
## live status timer stops here; the existing Converting… / Saved flow
## takes over the status line unchanged.
func _on_recording_stopped(_backend_name: String, output_path: String) -> void:
	_stop_status_timer()
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


## Whether the current selected format requires ffmpeg conversion given the
## capture mode. A backend that declares exact native formats (BackendOBS →
## [MP4]) produces them itself, so its own formats never expect a Converting…
## status (that path would dangle: OBS emits only recording_stopped, never
## recording_converted).
func _expects_conversion() -> bool:
	var fmt := _get_selected_format()
	var backend := _controller.active_backend if _controller != null else null
	if (
		backend != null
		and backend.has_method("get_native_formats")
		and backend.get_native_formats().has(fmt)
	):
		return false
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
	_stop_status_timer()
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
	_stop_status_timer()
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


# --- Live recording status ---------------------------------------------------
#
# While recording, the status line shows "Recording [backend] → file (mm:ss)"
# refreshed once per second by a lazy timer. The elapsed time is computed from
# _recording_started_at against the _now() seam; the timer stops on
# stop/error/converted so the existing "Converting…" / "Saved" flows take over
# unchanged. The controller's is_recording() is the single source of truth —
# the tick self-stops if a terminal signal was somehow missed.


## Formats a duration in seconds as mm:ss, or h:mm:ss past an hour. Pure
## static so GUT can exercise both branches headlessly.
static func format_elapsed(seconds: float) -> String:
	var total := int(floor(seconds))
	var hours := total / 3600
	var minutes := (total % 3600) / 60
	var secs := total % 60
	if hours > 0:
		return "%d:%02d:%02d" % [hours, minutes, secs]
	return "%02d:%02d" % [minutes, secs]


## Composes the live recording status line for the given backend, output path
## and elapsed seconds. Pure static for testability.
static func compose_recording_status(
	backend_name: String, output_path: String, elapsed_seconds: float
) -> String:
	return (
		"Recording [%s] → %s (%s)"
		% [
			backend_name,
			output_path.get_file(),
			format_elapsed(elapsed_seconds),
		]
	)


## Monotonic seconds for the live status timer; returns the _fake_time seam
## when set, otherwise the real engine clock. Mirrors the backends' _now().
func _now() -> float:
	if _fake_time >= 0.0:
		return _fake_time
	return Time.get_ticks_msec() / 1000.0


## Timer tick: refreshes the status line's elapsed time while recording.
## Guards on the controller's is_recording() (single source of truth) so the
## timer self-stops if a stop/error/converted signal was missed.
func _on_status_tick() -> void:
	if _controller == null or not _controller.is_recording():
		_stop_status_timer()
		return
	if _recording_started_at <= 0.0:
		return
	var elapsed := _now() - _recording_started_at
	_set_status(
		compose_recording_status(_recording_backend_name, _recording_output_path, elapsed),
		COLOR_RECORDING
	)


## Starts the 1-second repeating status timer (created lazily).
func _start_status_timer() -> void:
	_ensure_status_timer()
	if _status_timer:
		_status_timer.start(1.0)


## Stops the status timer; no-op when it was never started.
func _stop_status_timer() -> void:
	if _status_timer:
		_status_timer.stop()


## Lazily creates the status timer (requires being inside the scene tree) and
## wires its tick callback. Mirrors the backends' _ensure_timers() pattern.
func _ensure_status_timer() -> void:
	if _status_timer == null and is_inside_tree():
		_status_timer = Timer.new()
		_status_timer.wait_time = 1.0
		_status_timer.one_shot = false
		_status_timer.autostart = false
		_status_timer.timeout.connect(_on_status_tick)
		add_child(_status_timer)
