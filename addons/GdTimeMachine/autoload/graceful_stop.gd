## Game-side graceful-stop autoload.
##
## Listens for the editor's graceful-stop request arriving over the debugger
## channel (`gd_time_machine:graceful_stop`, dispatched with the
## `gd_time_machine:` prefix stripped) and quits the game in response, so the
## recorder can finalize the recording file before the process exits — instead
## of the editor killing the process abruptly and skipping finalization.
##
## Registration is safe to attempt even headless: when EngineDebugger is
## inactive the capture registration is a harmless no-op, and the callback
## runs on the game main thread, so calling quit() from it is safe.
extends Node


## Registers the debugger message capture for the gd_time_machine prefix,
## unconditionally (no-op when EngineDebugger is inactive, e.g. headless/CI).
func _ready() -> void:
	# Register unconditionally. Safe pre-handshake, and harmless when
	# EngineDebugger is inactive in a headless/CI build.
	if not EngineDebugger.has_capture("gd_time_machine"):
		EngineDebugger.register_message_capture("gd_time_machine", _on_debug_message)


## Unregisters the debugger message capture when the autoload leaves the tree.
func _exit_tree() -> void:
	if EngineDebugger.has_capture("gd_time_machine"):
		EngineDebugger.unregister_message_capture("gd_time_machine")


## Handles messages dispatched to the gd_time_machine capture. On
## "graceful_stop", quits the game and reports the message handled; on
## "focus_window", brings the game's own window to the foreground. Other
## messages are left unhandled.
func _on_debug_message(message: String, data: Array) -> bool:
	if message == "graceful_stop":
		_quit_game()
		return true
	if message == "focus_window":
		_focus_window()
		return true
	return false


## Quits the game tree. Seam for GUT: tests override this to observe the quit
## without exiting.
func _quit_game() -> void:
	get_tree().quit()


## Brings the game's own OS window to focus. Called when the editor starts a
## screenshot recording, so the game window (which Godot throttles to ~1 fps
## when occluded) comes to the front for full capture rate. Seam for GUT:
## tests override this to observe the focus without touching windowing.
func _focus_window() -> void:
	get_window().grab_focus()
