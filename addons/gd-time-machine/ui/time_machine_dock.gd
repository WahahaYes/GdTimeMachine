@tool
extends VBoxContainer
class_name TimeMachineDock

## GdTimeMachine dock UI (Phase 2, minimal).
##
## Backend selector, scene picker, duration/FPS, output directory, status
## line, and a Record/Stop toggle. All recording control goes through the
## RecorderController — the dock never talks to a backend directly.
##
## Per-project values persist in EditorSettings under the `gd_time_machine/`
## prefix so they survive editor restarts.

const SETTING_OUTPUT_DIR := "gd_time_machine/recorder/output_dir"
const SETTING_DEFAULT_DURATION := "gd_time_machine/recorder/default_duration"
const SETTING_DEFAULT_FPS := "gd_time_machine/recorder/default_fps"
const SETTING_DEFAULT_BACKEND := "gd_time_machine/recorder/default_backend"

const DEFAULT_OUTPUT_DIR := "res://media/captures"
const DEFAULT_DURATION := 30.0
const DEFAULT_FPS := 60.0

const COLOR_IDLE := Color("9e9e9e")
const COLOR_RECORDING := Color("4caf50")
const COLOR_ERROR := Color("e03131")

const ICON_RECORD_PATH := "res://addons/gd-time-machine/ui/icons/icon_record.svg"
const ICON_STOP_PATH := "res://addons/gd-time-machine/ui/icons/icon_stop.svg"

var _icon_record: Texture2D
var _icon_stop: Texture2D
var _controller: RecorderController
var _setup_applied := false

@onready var _title_icon: TextureRect = $TitleBar/TitleIcon
@onready var _backend_option: OptionButton = $BackendRow/BackendOption
@onready var _scene_row: HBoxContainer = $SettingsGroup/SceneRow
@onready var _scene_edit: LineEdit = $SettingsGroup/SceneRow/SceneEdit
@onready var _use_current_button: Button = $SettingsGroup/SceneRow/UseCurrentButton
@onready var _duration_spin: SpinBox = $SettingsGroup/DurationRow/DurationSpin
@onready var _fps_spin: SpinBox = $SettingsGroup/FpsRow/FpsSpin
@onready var _output_edit: LineEdit = $SettingsGroup/OutputRow/OutputEdit
@onready var _status_light: ColorRect = $StatusRow/StatusLight
@onready var _status_label: Label = $StatusRow/StatusLabel
@onready var _record_button: Button = $RecordButton


## Called by plugin.gd before the dock enters the tree; UI wiring happens in
## _ready() once the nodes exist.
func setup(controller: RecorderController) -> void:
	_controller = controller
	if is_inside_tree():
		_apply_setup()


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
	_duration_spin.value_changed.connect(func(_value): _persist_settings())
	_fps_spin.value_changed.connect(func(_value): _persist_settings())
	if _controller != null:
		_apply_setup()


func _apply_setup() -> void:
	if _setup_applied:
		return
	_setup_applied = true
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


func _populate_backends() -> void:
	_backend_option.clear()
	for name in _controller.get_backend_names():
		_backend_option.add_item(str(name))
	_select_backend_item(
		_controller.active_backend.get_backend_name() if _controller.active_backend else ""
	)


func _select_backend_item(backend_name: String) -> void:
	for i in _backend_option.item_count:
		if _backend_option.get_item_text(i) == backend_name:
			_backend_option.select(i)
			return


func _on_backend_selected(index: int) -> void:
	if _controller == null:
		return
	_controller.select_backend(_backend_option.get_item_text(index))
	_persist_settings()


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


func _on_use_current_pressed() -> void:
	_use_current_scene_path()


func _prefill_scene() -> void:
	if _scene_edit.text.strip_edges().is_empty():
		_use_current_scene_path()


func _use_current_scene_path() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root != null and not root.scene_file_path.is_empty():
		_scene_edit.text = root.scene_file_path
		return
	var main: Variant = ProjectSettings.get_setting("application/run/main_scene")
	if main != null and not str(main).is_empty():
		_scene_edit.text = str(main)


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


func _persist_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting(SETTING_OUTPUT_DIR, _output_edit.text.strip_edges())
	es.set_setting(SETTING_DEFAULT_DURATION, int(_duration_spin.value))
	es.set_setting(SETTING_DEFAULT_FPS, int(_fps_spin.value))
	if _backend_option.selected >= 0:
		es.set_setting(
			SETTING_DEFAULT_BACKEND, _backend_option.get_item_text(_backend_option.selected)
		)


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
		"duration": float(_duration_spin.value),
	}


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


func _on_recording_started(_backend_name: String, output_path: String) -> void:
	_set_recording_ui(true)
	_set_status("Recording → %s" % output_path.get_file(), COLOR_RECORDING)


func _on_recording_stopped(_backend_name: String, output_path: String) -> void:
	_set_recording_ui(false)
	_set_status("Saved %s" % output_path.get_file(), COLOR_IDLE)


func _on_recording_error(_backend_name: String, message: String) -> void:
	_set_recording_ui(false)
	_set_status("Error: %s" % message, COLOR_ERROR)


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


func _set_controls_enabled(enabled: bool) -> void:
	_backend_option.disabled = not enabled
	_scene_edit.editable = enabled
	_use_current_button.disabled = not enabled
	_duration_spin.editable = enabled
	_fps_spin.editable = enabled
	_output_edit.editable = enabled


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_light.color = color
