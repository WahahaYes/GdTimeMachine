@tool
extends EditorDebuggerPlugin
class_name GdTMDebuggerPlugin

## Editor-side bridge to the running game's debugger channel.
##
## API correction (verified 2026-08-01): `EditorDebuggerPlugin` does NOT have
## `send_message()`. Editor→game messages are sent on `EditorDebuggerSession`
## via `get_session(id).send_message(...)`. The editor sends the full
## `"prefix:payload"` wire form; the game side registers a capture on the
## prefix and receives the payload with the prefix stripped.
##
## Current roles (Op 2-3):
## - Op 2 graceful-stop: send-only `gd_time_machine:graceful_stop` → game quit
## - Op 5 future BackendScreenshotCapture: will be extended to pace
##   `scene:rq_screenshot` [rq_id] → `game_view:get_screenshot` [id,w,h,path],
##   one-in-flight with deferred idle yield, id tracking, has_capture only
##   while measuring/capturing to avoid shadowing GameViewDebugger (see
##   notes/SPIKE_screenshot_fps.md for pitfalls: sync _send_rq inside _capture
##   starves editor, claiming game_view always shadows builtin).
## `_has_capture` / `_capture` are placeholder for that future use.


func _has_capture(capture: String) -> bool:
	# Today: only gd_time_machine for graceful-stop. Future Op 5 will also
	# claim game_view while actively capturing — but only then, to avoid
	# shadowing GameViewDebugger's own screenshots (see spike notes).
	return capture == "gd_time_machine"


func _capture(message: String, data: Array, session_id: int) -> bool:
	# Placeholder for Op 5 screenshot replies. Nothing to consume yet — and
	# returning false here lets GameViewDebugger handle game_view messages
	# until Op 5 claims it.
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
