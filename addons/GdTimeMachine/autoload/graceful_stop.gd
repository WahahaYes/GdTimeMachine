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
## "focus_window", brings the game's own window to the foreground; on
## "rq_window_handle", reports the game's OS window identity back to the
## editor (see _reply_window_identity) so OBS can target this exact window.
## Other messages are left unhandled.
func _on_debug_message(message: String, data: Array) -> bool:
	if message == "graceful_stop":
		_quit_game()
		return true
	if message == "focus_window":
		_focus_window()
		return true
	if message == "rq_window_handle":
		var rq_id := 0
		if not data.is_empty() and (data[0] is int or data[0] is float):
			rq_id = int(data[0])
		_reply_window_identity(rq_id)
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


## Collects this game's OS window identity for the editor's OBS backend.
## Pure (no EngineDebugger): handle is the X11 xid / HWND (0 when the display
## server exposes none, e.g. headless); display is e.g. "X11"/"Windows";
## exe is the running binary's file name; title_guess is the project name
## (the exact OS title is not queryable — no window_get_title exists).
func _collect_window_identity() -> Dictionary:
	var handle := 0
	var display := str(DisplayServer.get_name())
	handle = int(
		DisplayServer.window_get_native_handle(
			DisplayServer.WINDOW_HANDLE, DisplayServer.MAIN_WINDOW_ID
		)
	)
	var exe := OS.get_executable_path().get_file()
	var title_guess := ""
	if ProjectSettings.has_setting("application/config/name"):
		title_guess = str(ProjectSettings.get_setting("application/config/name"))
	return {
		"handle": handle,
		"display": display,
		"exe": exe,
		"title_guess": title_guess,
		"debug": 1 if OS.is_debug_build() else 0,
	}


## Sends the collected window identity to the editor, tagged with the
## request id. Guarded by is_active: with no debugger attached there is
## nobody to answer, and the send must stay a harmless no-op (headless/CI).
func _reply_window_identity(rq_id: int) -> void:
	if not EngineDebugger.is_active():
		return
	var identity := _collect_window_identity()
	(
		EngineDebugger
		. send_message(
			"gd_time_machine:window_handle",
			[
				rq_id,
				int(identity.get("handle", 0)),
				str(identity.get("display", "")),
				str(identity.get("exe", "")),
				str(identity.get("title_guess", "")),
				int(identity.get("debug", 0)),
			]
		)
	)
