@tool
extends EditorDebuggerPlugin
class_name GdTMDebuggerPlugin

## Editor-side bridge to the running game's debugger channel.
##
## API CORRECTION (verified 2026-08-01): `EditorDebuggerPlugin` does NOT have
## `send_message()`. Editor->game messages are sent on `EditorDebuggerSession`
## via `get_session(id).send_message(...)`. The editor sends the full
## `"prefix:payload"` wire form; the game side registers a capture on the
## prefix and receives the payload with the prefix stripped.
##
## This plugin only *sends* for Op 2 (graceful stop). `_has_capture` /
## `_capture` claim the `gd_time_machine` prefix so future Op 5 screenshot
## replies can be received editor-side; the actual handling is a placeholder.


func _has_capture(capture: String) -> bool:
	return capture == "gd_time_machine"


func _capture(message: String, data: Array, session_id: int) -> bool:
	# Placeholder for Op 5 screenshot replies. Nothing to consume yet.
	return false


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	# Session lifecycle is driven by the engine debugger itself; keep the
	# wiring present but inert so future Op 5 reply handling has hooks.
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


## Overridable seam for tests; also guards against a debugger that has
## detached mid-send so this never crashes the editor.
func _send_to_session(session: EditorDebuggerSession) -> void:
	if session == null or not session.is_active():
		return
	session.send_message("gd_time_machine:graceful_stop", [])
