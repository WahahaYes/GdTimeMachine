@tool
extends EditorDebuggerPlugin
class_name GdTMDebuggerPlugin

## Editor-side bridge to the running game's debugger channel.
##
## Currently handles the graceful-stop broadcast: messages are sent on
## EditorDebuggerSession instances via send_message(), using the
## gd_time_machine prefix (full "prefix:payload" wire form); the game side
## registers a capture on the prefix and receives the payload with the prefix
## stripped.
##
## _has_capture / _capture are inert placeholders reserved for future
## game→editor message handling and claim nothing yet.


## Whether this plugin claims a capture prefix. Today only gd_time_machine is
## claimed, for the graceful-stop broadcast.
func _has_capture(capture: String) -> bool:
	return capture == "gd_time_machine"


## Entry point for future game→editor message handling. Returns false today
## so no message is consumed and other plugins keep their captures.
func _capture(message: String, data: Array, session_id: int) -> bool:
	return false


## Sets up per-session wiring. Session lifecycle is driven by the engine
## debugger itself; the started/stopped hooks are kept present but inert so
## future reply handling has a place to attach.
func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	session.started.connect(func() -> void: pass)
	session.stopped.connect(func() -> void: pass)


## Broadcast a graceful-stop message to every active debugger session.
## Returns true if the message was sent to at least one session.
func send_graceful_stop() -> bool:
	var sessions := get_sessions()
	var sent := false
	for i in range(sessions.size()):
		var session: EditorDebuggerSession = get_session(i)
		if session != null:
			_send_to_session(session)
			sent = true
	# Fallback: get_sessions() can be empty while session 0 still exists
	# (single-session editor). Try the canonical session directly.
	if not sent:
		var fallback := get_session(0)
		if fallback != null:
			_send_to_session(fallback)
			sent = true
	return sent


## Sends the graceful-stop message to a session. Overridable seam for tests;
## also guards against a debugger that has detached mid-send so this never
## crashes the editor.
func _send_to_session(session: EditorDebuggerSession) -> void:
	if session == null or not session.is_active():
		return
	session.send_message("gd_time_machine:graceful_stop", [])
