## Game-side graceful-stop autoload.
##
## The editor sends `gd_time_machine:graceful_stop` via EditorDebuggerSession.
## EngineDebugger strips the `gd_time_machine:` prefix at dispatch
## (remote_debugger.cpp:658-672), so this autoload's registered capture
## receives the payload `graceful_stop`. On receipt, the game quits via
## get_tree().quit() so the recorder can finalize (write idx1 + RIFF patch)
## before the process exits — instead of the editor SIGKILLing the game,
## which skips write_end() entirely.
##
## Registration is safe before the debugger handshake: the C++ side just
## inserts into a HashMap. The callable runs on the game main thread, so
## quit() from it is safe.
extends Node


func _ready() -> void:
	# Register unconditionally. Safe pre-handshake (HashMap insertion), and
	# harmless when EngineDebugger is inactive in a headless/CI build.
	if not EngineDebugger.has_capture("gd_time_machine"):
		EngineDebugger.register_message_capture("gd_time_machine", _on_debug_message)


func _exit_tree() -> void:
	if EngineDebugger.has_capture("gd_time_machine"):
		EngineDebugger.unregister_message_capture("gd_time_machine")


func _on_debug_message(message: String, data: Array) -> bool:
	if message == "graceful_stop":
		_quit_game()
		return true
	return false


## Seam for GUT: tests override this to observe the quit without exiting.
func _quit_game() -> void:
	get_tree().quit()
