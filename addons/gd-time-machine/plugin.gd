@tool
extends EditorPlugin

const ICON_RECORD_PATH := "res://addons/gd-time-machine/ui/icons/icon_record.svg"
const ICON_STOP_PATH := "res://addons/gd-time-machine/ui/icons/icon_stop.svg"
const TOOLTIP_DEFAULT := "GdTimeMachine — Start/stop recording (uses the dock settings)"
const TOOLTIP_RESTART_DISABLED := "Recording with this backend restarts the scene — disabled here to protect the running game.\nStart from the dock or run bar instead, or switch to an in-place backend in the dock."

var _recorder_controller: RecorderController
var _movie_maker_backend: BackendMovieMaker
var _dock: TimeMachineDock
var _run_bar_button: Button
var _game_view_button: Button
var _game_view_section: HBoxContainer


func _enter_tree() -> void:
	_recorder_controller = RecorderController.new()
	add_child(_recorder_controller)
	_movie_maker_backend = BackendMovieMaker.new()
	_recorder_controller.register_backend(_movie_maker_backend)
	_dock = preload("res://addons/gd-time-machine/ui/time_machine_dock.tscn").instantiate()
	_dock.setup(_recorder_controller)
	add_control_to_bottom_panel(_dock, "GdTimeMachine")
	# The run bar and game view are constructed during editor init, after
	# plugin _enter_tree (and after end-of-frame deferred calls). Wait for the
	# first process frame so the traversals reliably find them.
	get_tree().process_frame.connect(_setup_run_bar_button, CONNECT_ONE_SHOT)
	get_tree().process_frame.connect(_setup_game_view_button, CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	if _recorder_controller:
		_recorder_controller.stop_recording_if_active()
	if _run_bar_button:
		if _run_bar_button.is_inside_tree():
			_run_bar_button.get_parent().remove_child(_run_bar_button)
		_run_bar_button.queue_free()
		_run_bar_button = null
	if _game_view_section:
		if _game_view_section.is_inside_tree():
			_game_view_section.get_parent().remove_child(_game_view_section)
		_game_view_section.queue_free()
		_game_view_section = null
		_game_view_button = null
	if _dock:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
	if _recorder_controller:
		remove_child(_recorder_controller)
		_recorder_controller.queue_free()
		_recorder_controller = null


# --- Record buttons (run bar + game view toolbar) --------------------------
#
# Both the editor's run bar and the embedded game view's toolbar (the
# "Input / 2D / 3D" bar shown while a scene plays) are internal C++ UI with
# no official plugin container, so the buttons are inserted by traversal.
# The game view toolbar is built once in the GameView constructor and never
# rebuilt, so the inserted button survives play/stop cycles. These are UI
# conveniences only — the bottom-panel tab remains the supported surface, and
# every failure path below degrades to "no button" without affecting recording.


func _setup_run_bar_button() -> void:
	var row := _find_run_bar_button_row()
	if row == null:
		push_warning(
			"GdTimeMachine: editor run bar not found; run-bar record button unavailable (bottom-panel tab still works)"
		)
		return
	_run_bar_button = _build_record_button()
	row.add_child(_run_bar_button)
	_apply_button_state(_run_bar_button, false)


func _setup_game_view_button() -> void:
	var row := _find_game_view_toolbar_row()
	if row == null:
		push_warning(
			"GdTimeMachine: game view toolbar not found; toolbar record button unavailable (bottom-panel tab still works)"
		)
		return
	# GameView persists across plugin re-enables; do not insert a duplicate.
	var existing := row.find_child("GdTimeMachineRecord", true, false)
	if existing is Button:
		_game_view_button = existing
		_game_view_section = _game_view_button.get_parent() as HBoxContainer
		# The previous plugin instance's signal connections died with it —
		# re-establish, then re-apply state.
		if not _game_view_button.pressed.is_connected(_on_record_button_pressed):
			_game_view_button.pressed.connect(_on_record_button_pressed)
		_connect_game_view_signals()
		_refresh_game_view_button()
		return
	var section := HBoxContainer.new()
	section.add_child(VSeparator.new())
	_game_view_button = _build_record_button()
	section.add_child(_game_view_button)
	row.add_child(section)
	# Place right after the Input/2D/3D button group (index 2) and before the
	# node-selection group, keeping the stretch/FPS label at the far right.
	if row.get_child_count() > 2:
		row.move_child(section, 2)
	_game_view_section = section
	_connect_game_view_signals()
	_refresh_game_view_button()


func _build_record_button() -> Button:
	var button := Button.new()
	button.name = "GdTimeMachineRecord"
	button.flat = true
	button.tooltip_text = TOOLTIP_DEFAULT
	button.pressed.connect(_on_record_button_pressed)
	_recorder_controller.recording_started.connect(func(_n, _p): _apply_button_state(button, true))
	_recorder_controller.recording_stopped.connect(func(_n, _p): _apply_button_state(button, false))
	return button


func _find_run_bar_button_row() -> HBoxContainer:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var run_bar := _find_node_by_class(base, "EditorRunBar")
	if run_bar == null:
		return null
	# EditorRunBar → HBoxContainer → [Button, PanelContainer → HBoxContainer (button row)]
	var panel := _find_node_by_class(run_bar, "PanelContainer")
	if panel == null:
		return null
	for row in panel.get_children():
		if row is HBoxContainer:
			return row
	return null


func _find_game_view_toolbar_row() -> HBoxContainer:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var game_view := _find_node_by_class(base, "GameView")
	if game_view == null:
		return null
	# GameView → MarginContainer (toolbar margin) → HBoxContainer (toolbar row).
	for child in game_view.get_children():
		if child is MarginContainer:
			for row in child.get_children():
				if row is HBoxContainer:
					return row
	return null


func _find_node_by_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children():
		var found := _find_node_by_class(child, target_class)
		if found:
			return found
	return null


func _on_record_button_pressed() -> void:
	if _recorder_controller == null:
		return
	if _recorder_controller.is_recording():
		_recorder_controller.stop_recording()
	else:
		_recorder_controller.start_recording(_dock.build_config())


func _apply_button_state(button: Button, recording: bool) -> void:
	if button == null:
		return
	if recording:
		button.text = "Stop"
		button.icon = load(ICON_STOP_PATH) as Texture2D
	else:
		button.text = "Record"
		button.icon = load(ICON_RECORD_PATH) as Texture2D


# --- Game-view button grey-out ---------------------------------------------
#
# The game view shows the *running* scene; a RESTART_SCENE backend would
# destroy it on Record, so Record greys out with an explanatory tooltip.
# Stop is always allowed, and the run-bar/dock buttons are unaffected
# (restart is the expected price there). Re-applied on backend_changed and
# recording_* signals via _connect_game_view_signals().


## Pure button-state rule, extracted as a static so GUT can exercise the full
## matrix without standing up editor UI.
static func compute_game_view_button_state(
	recording: bool, mode: RecorderBackend.CaptureMode
) -> Dictionary:
	if not recording and mode == RecorderBackend.CaptureMode.RESTART_SCENE:
		return {"disabled": true, "tooltip": TOOLTIP_RESTART_DISABLED}
	return {"disabled": false, "tooltip": TOOLTIP_DEFAULT}


func _refresh_game_view_button() -> void:
	if _game_view_button == null or _recorder_controller == null:
		return
	var recording := _recorder_controller.is_recording()
	_apply_button_state(_game_view_button, recording)
	var state: Dictionary = compute_game_view_button_state(
		recording, _recorder_controller.get_capture_mode()
	)
	_game_view_button.disabled = state["disabled"]
	_game_view_button.tooltip_text = state["tooltip"]


# Default-param signature so it can connect to backend_changed (1 arg) and
# recording_started/stopped (2 args) alike.
func _on_game_view_refresh_triggered(_arg1: Variant = null, _arg2: Variant = null) -> void:
	_refresh_game_view_button()


func _connect_game_view_signals() -> void:
	if not _recorder_controller.recording_started.is_connected(_on_game_view_refresh_triggered):
		_recorder_controller.recording_started.connect(_on_game_view_refresh_triggered)
	if not _recorder_controller.recording_stopped.is_connected(_on_game_view_refresh_triggered):
		_recorder_controller.recording_stopped.connect(_on_game_view_refresh_triggered)
	if not _recorder_controller.backend_changed.is_connected(_on_game_view_refresh_triggered):
		_recorder_controller.backend_changed.connect(_on_game_view_refresh_triggered)
