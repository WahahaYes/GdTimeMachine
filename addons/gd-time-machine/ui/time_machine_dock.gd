@tool
extends VBoxContainer
class_name TimeMachineDock

## Minimal GdTimeMachine dock UI.
##
## Backend selector, scene picker, duration/FPS, output directory, status
## line, and a Record/Stop toggle. All recording control goes through the
## RecorderController — the dock never talks to a backend directly.
##
## Per-project values persist in EditorSettings under the `gd_time_machine/`
## prefix so they survive editor restarts.

## EditorSettings key for the output directory.
const SETTING_OUTPUT_DIR := "gd_time_machine/recorder/output_dir"

## EditorSettings key for the default recording duration.
const SETTING_DEFAULT_DURATION := "gd_time_machine/recorder/default_duration"

## EditorSettings key for the default capture FPS.
const SETTING_DEFAULT_FPS := "gd_time_machine/recorder/default_fps"

## EditorSettings key for the preferred backend name.
const SETTING_DEFAULT_BACKEND := "gd_time_machine/recorder/default_backend"

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
const ICON_RECORD_PATH := "res://addons/gd-time-machine/ui/icons/icon_record.svg"

## Icon path for the stop state.
const ICON_STOP_PATH := "res://addons/gd-time-machine/ui/icons/icon_stop.svg"

## Loaded record icon (lazy-loaded — see _ready()).
var _icon_record: Texture2D

## Loaded stop icon (lazy-loaded — see _ready()).
var _icon_stop: Texture2D

## Controller the dock talks to; injected via setup() before _ready().
var _controller: RecorderController

## Guards the one-time UI wiring in _apply_setup().
var _setup_applied := false

## Dock title icon (shows the record icon).
@onready var _title_icon: TextureRect = $TitleBar/TitleIcon
## Backend selector dropdown.
@onready var _backend_option: OptionButton = $BackendRow/BackendOption
## Row holding the scene picker (hidden for in-place backends).
@onready var _scene_row: HBoxContainer = $SettingsGroup/SceneRow
## Scene path to record.
@onready var _scene_edit: LineEdit = $SettingsGroup/SceneRow/SceneEdit
## Fills _scene_edit with the currently open scene.
@onready var _use_current_button: Button = $SettingsGroup/SceneRow/UseCurrentButton
## Recording duration in seconds (0 = manual).
@onready var _duration_spin: SpinBox = $SettingsGroup/DurationRow/DurationSpin
## Capture FPS.
@onready var _fps_spin: SpinBox = $SettingsGroup/FpsRow/FpsSpin
## Output directory for recordings.
@onready var _output_edit: LineEdit = $SettingsGroup/OutputRow/OutputEdit
## Status indicator light.
@onready var _status_light: ColorRect = $StatusRow/StatusLight
## Status text label.
@onready var _status_label: Label = $StatusRow/StatusLabel
## Record/Stop toggle button.
@onready var _record_button: Button = $RecordButton


## Called by plugin.gd before the dock enters the tree; stores the
## controller. UI wiring happens in _ready() once the nodes exist.
func setup(controller: RecorderController) -> void:
	_controller = controller
	if is_inside_tree():
		_apply_setup()


## Loads icons, wires signals, sets tooltips, and applies the controller
## setup (if the controller is already available).
func _ready() -> void:
	# Icons are loaded lazily (not preloaded): during the editor's first
	# import scan the SVG files are not yet imported, and a parse-time
	# preload would fail. After import they resolve on the next load.
	_icon_record = load(ICON_RECORD_PATH) as Texture2D
	_icon_stop = load(ICON_STOP_PATH) as Texture2D
	_title_icon.texture = _icon_record
	_record_button.icon = _icon_record
	_record_button.text = "Record"
	_backend_option.item_selected.connect(_on_backend_selected)
	_use_current_button.pressed.connect(_on_use_current_pressed)
	_record_button.pressed.connect(_on_record_pressed)
	_output_edit.text_changed.connect(func(_text): _persist_settings())
	_output_edit.tooltip_text = "Directory where recordings are saved. File names are auto-generated from scene name + timestamp."
	_duration_spin.value_changed.connect(func(_value): _persist_settings())
	_fps_spin.value_changed.connect(func(_value): _persist_settings())
	if _controller != null:
		_apply_setup()


## One-time setup: minimums and tooltips, controller signal wiring, backend
## population, settings load, scene prefill, and initial UI state.
func _apply_setup() -> void:
	if _setup_applied:
		return
	_setup_applied = true
	_duration_spin.min_value = 0.0
	_duration_spin.tooltip_text = "0 = record until Stop is pressed. Positive value auto-stops after that many seconds."
	$SettingsGroup/DurationRow.tooltip_text = _duration_spin.tooltip_text
	$SettingsGroup/DurationRow/DurationLabel.tooltip_text = _duration_spin.tooltip_text

	_backend_option.tooltip_text = "Recording backend. Movie Maker restarts the scene; in-place backends record the running scene without restarting it."
	_scene_edit.tooltip_text = "Scene to launch when recording starts. Empty uses the current or main scene."
	_use_current_button.tooltip_text = "Fill with the currently open scene."
	_fps_spin.tooltip_text = "Target frames per second for the recording."
	$SettingsGroup/FpsRow.tooltip_text = _fps_spin.tooltip_text
	$SettingsGroup/FpsRow/FpsLabel.tooltip_text = _fps_spin.tooltip_text
	$SettingsGroup/SceneRow.tooltip_text = _scene_edit.tooltip_text
	$SettingsGroup/OutputRow.tooltip_text = _output_edit.tooltip_text
	_record_button.tooltip_text = "Start or stop recording with the settings above."
	_controller.backend_changed.connect(_on_backend_changed)
	_controller.recording_started.connect(_on_recording_started)
	_controller.recording_stopped.connect(_on_recording_stopped)
	_controller.recording_error.connect(_on_recording_error)
	_populate_backends()
	_load_settings()
	_prefill_scene()
	_update_scene_row_visibility()
	_set_recording_ui(false)
	_set_status("Ready", COLOR_IDLE)


## Fills the backend dropdown from the controller's registered backends and
## selects the active one.
func _populate_backends() -> void:
	_backend_option.clear()
	for name in _controller.get_backend_names():
		_backend_option.add_item(str(name))
	_select_backend_item(
		_controller.active_backend.get_backend_name() if _controller.active_backend else ""
	)


## Selects the dropdown item whose text matches backend_name, if present.
func _select_backend_item(backend_name: String) -> void:
	for i in _backend_option.item_count:
		if _backend_option.get_item_text(i) == backend_name:
			_backend_option.select(i)
			return


## Switches the controller to the backend chosen in the dropdown and
## persists the preference.
func _on_backend_selected(index: int) -> void:
	if _controller == null:
		return
	_controller.select_backend(_backend_option.get_item_text(index))
	_persist_settings()


## Reacts to a backend change made elsewhere (e.g. another UI surface):
## re-selects the dropdown, updates scene-row visibility, and persists.
func _on_backend_changed(backend_name: String) -> void:
	_select_backend_item(backend_name)
	_update_scene_row_visibility()
	_persist_settings()


## In-place backends record the running scene, so the "which scene to launch"
## row is meaningless for them — hide it rather than let it imply a restart.
func _update_scene_row_visibility() -> void:
	if _controller == null or _scene_row == null:
		return
	_scene_row.visible = _controller.get_capture_mode() != RecorderBackend.CaptureMode.IN_PLACE


## Handles the "Use Current" button: fills the scene field with the
## currently open scene.
func _on_use_current_pressed() -> void:
	_use_current_scene_path()


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


## Loads the persisted settings (output dir, duration, FPS, preferred
## backend) into the UI; falls back to defaults for missing values.
func _load_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	var output_dir: Variant = es.get_setting(SETTING_OUTPUT_DIR)
	_output_edit.text = str(output_dir) if output_dir != null else DEFAULT_OUTPUT_DIR
	var duration: Variant = es.get_setting(SETTING_DEFAULT_DURATION)
	_duration_spin.value = float(duration) if duration != null else DEFAULT_DURATION
	var fps: Variant = es.get_setting(SETTING_DEFAULT_FPS)
	_fps_spin.value = float(fps) if fps != null else DEFAULT_FPS
	var preferred: Variant = es.get_setting(SETTING_DEFAULT_BACKEND)
	if preferred != null:
		_controller.select_backend(str(preferred))


## Writes the current UI values back to EditorSettings.
func _persist_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(SETTING_OUTPUT_DIR, _output_edit.text.strip_edges())
	es.set_setting(SETTING_DEFAULT_DURATION, int(_duration_spin.value))
	es.set_setting(SETTING_DEFAULT_FPS, int(_fps_spin.value))
	if _backend_option.selected >= 0:
		es.set_setting(
			SETTING_DEFAULT_BACKEND, _backend_option.get_item_text(_backend_option.selected)
		)


## Toggles recording via the controller, persisting settings first; starts
## with the config built by build_config().
func _on_record_pressed() -> void:
	if _controller == null:
		return
	_persist_settings()
	if _controller.is_recording():
		_controller.stop_recording()
	else:
		_controller.start_recording(build_config())


## Builds the recording config from the currently configured UI fields.
## Public so other surfaces (e.g. the run-bar record button) reuse the exact
## settings shown in this tab.
func build_config() -> Dictionary:
	return {
		"output_path": _build_output_path(),
		"scene_path": _scene_edit.text.strip_edges(),
		"fps": int(_fps_spin.value),
		"duration": 0.0 if _duration_spin.value <= 0.0 else float(_duration_spin.value),
	}


## Builds the full output file path: output dir + scene name + timestamp,
## creating the directory if needed. Empty dir falls back to
## DEFAULT_OUTPUT_DIR; empty scene falls back to "scene".
func _build_output_path() -> String:
	var dir := _output_edit.text.strip_edges()
	if dir.is_empty():
		dir = DEFAULT_OUTPUT_DIR
	var scene_path := _scene_edit.text.strip_edges()
	var scene_name := "scene"
	if not scene_path.is_empty():
		scene_name = scene_path.get_file().get_basename()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/%s_%s.avi" % [dir, scene_name, stamp]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return path


## Updates the UI when a recording starts (button → Stop, green status).
func _on_recording_started(_backend_name: String, output_path: String) -> void:
	_set_recording_ui(true)
	_set_status("Recording → %s" % output_path.get_file(), COLOR_RECORDING)


## Updates the UI when a recording stops (button → Record, idle status).
func _on_recording_stopped(_backend_name: String, output_path: String) -> void:
	_set_recording_ui(false)
	_set_status("Saved %s" % output_path.get_file(), COLOR_IDLE)


## Updates the UI when a recording errors (button → Record, error status).
func _on_recording_error(_backend_name: String, message: String) -> void:
	_set_recording_ui(false)
	_set_status("Error: %s" % message, COLOR_ERROR)


## Switches the record button between Record/Stop look and enables or
## disables the configuration controls accordingly.
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


## Enables or disables the configuration controls (backends, scene,
## duration, FPS, output dir) while a recording is in progress.
func _set_controls_enabled(enabled: bool) -> void:
	_backend_option.disabled = not enabled
	_scene_edit.editable = enabled
	_use_current_button.disabled = not enabled
	_duration_spin.editable = enabled
	_fps_spin.editable = enabled
	_output_edit.editable = enabled


## Sets the status label text and status light color.
func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_light.color = color
