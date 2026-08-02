@tool
extends EditorDebuggerPlugin
class_name GdTMDebuggerPlugin

## Editor-side bridge to the running game's debugger channel.
##
## Two channels share this one plugin registration:
##   1. Graceful-stop broadcast (Op 2): messages are sent on
##      EditorDebuggerSession instances via send_message(), using the
##      gd_time_machine prefix (full "prefix:payload" wire form); the game
##      side registers a capture on the prefix and receives the payload with
##      the prefix stripped.
##   2. Screenshot capture (Op 5): the editor sends scene:rq_screenshot with
##      an id, and the game replies with game_view:get_screenshot
##      [id, w, h, path]. The game_view capture prefix is claimed ONLY while
##      a screenshot recording is active — claiming it while idle would
##      shadow the engine's GameViewDebugger and break the embedded preview
##      (spike-verified). Replies are re-emitted as screenshot_received for
##      the active backend to consume.

## Wire message sent to the running game to request a screenshot frame.
const SCREENSHOT_REQUEST_MESSAGE := "scene:rq_screenshot"

## Capture prefix for screenshot replies (game_view:get_screenshot).
const SCREENSHOT_CAPTURE_PREFIX := "game_view"

## Whether a screenshot recording currently owns the game_view capture prefix.
var _screenshot_capture_active := false

## Emitted when the game replies to a scene:rq_screenshot request with a
## frame: [rq_id, width, height, path-to-png]. Only emitted while
## _screenshot_capture_active is true (the capture is claimed during a
## recording); consumers must copy the PNG promptly — the game may clean up
## its temp files at any time.
signal screenshot_received(rq_id: int, width: int, height: int, path: String)


## Whether this plugin claims a capture prefix. gd_time_machine is always
## claimed (graceful-stop broadcast); game_view is claimed only while a
## screenshot recording is active, so the engine's GameViewDebugger keeps the
## embedded preview when idle.
func _has_capture(capture: String) -> bool:
	if capture == "gd_time_machine":
		return true
	return capture == SCREENSHOT_CAPTURE_PREFIX and _screenshot_capture_active


## Routes game→editor messages. Only screenshot replies are consumed (and
## only while a screenshot recording is active); everything else falls
## through so other plugins keep their captures.
func _capture(message: String, data: Array, _session_id: int) -> bool:
	if _screenshot_capture_active and message == "get_screenshot" and data.size() >= 4:
		screenshot_received.emit(int(data[0]), int(data[1]), int(data[2]), str(data[3]))
		return true
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


## Claims or releases the game_view capture prefix. Call with true while a
## screenshot recording runs, false when it stops. The embedded game-view
## preview stalls while the prefix is claimed (frames are not forwarded back
## in v1) — documented tradeoff.
func set_screenshot_capture_active(active: bool) -> void:
	_screenshot_capture_active = active


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


## Requests a screenshot frame from the FIRST active debugger session
## (multi-session editors target the first live game). Returns true when the
## request was sent. Falls back to the canonical session 0 when
## get_sessions() is empty, mirroring send_graceful_stop.
func send_screenshot_request(rq_id: int) -> bool:
	var sessions := get_sessions()
	for i in range(sessions.size()):
		if _send_screenshot_to_session(get_session(i), rq_id):
			return true
	if not sessions.is_empty():
		return false
	var fallback := get_session(0)
	if fallback != null:
		return _send_screenshot_to_session(fallback, rq_id)
	return false


## Sends a scene:rq_screenshot request to a session. Returns true when the
## message was sent to a live session. Overridable seam for tests.
func _send_screenshot_to_session(session: EditorDebuggerSession, rq_id: int) -> bool:
	if session == null or not session.is_active():
		return false
	session.send_message(SCREENSHOT_REQUEST_MESSAGE, [rq_id])
	return true
