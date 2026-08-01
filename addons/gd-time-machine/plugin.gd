@tool
extends EditorPlugin

var _recorder_controller: RecorderController
var _movie_maker_backend: BackendMovieMaker
var _dock: Control


func _enter_tree() -> void:
	_recorder_controller = RecorderController.new()
	add_child(_recorder_controller)
	_movie_maker_backend = BackendMovieMaker.new()
	_recorder_controller.register_backend(_movie_maker_backend)
	_dock = preload("res://addons/gd-time-machine/ui/time_machine_dock.tscn").instantiate()
	_dock.setup(_recorder_controller)
	add_control_to_bottom_panel(_dock, "GdTimeMachine")


func _exit_tree() -> void:
	if _recorder_controller:
		_recorder_controller.stop_recording_if_active()
	if _dock:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
	if _recorder_controller:
		remove_child(_recorder_controller)
		_recorder_controller.queue_free()
		_recorder_controller = null
