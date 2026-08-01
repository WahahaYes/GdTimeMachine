@tool
extends EditorPlugin

var _recorder_controller: RecorderController


func _enter_tree() -> void:
	_recorder_controller = RecorderController.new()
	add_child(_recorder_controller)


func _exit_tree() -> void:
	if _recorder_controller:
		_recorder_controller.stop_recording_if_active()
		remove_child(_recorder_controller)
		_recorder_controller.queue_free()
