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

## Wire message that asks the running game to bring its own window to focus.
## Sent when a screenshot recording starts, so an occluded/unfocused game
## window (which Godot throttles to ~1 fps) comes to the front for full rate.
const FOCUS_WINDOW_MESSAGE := "gd_time_machine:focus_window"

## Capture prefix for screenshot replies (game_view:get_screenshot).
const SCREENSHOT_CAPTURE_PREFIX := "game_view"

## Whether a screenshot recording currently owns the game_view capture prefix.
var _screenshot_capture_active := false

## Last screenshot request id handed to the game; used as fallback when
## the reply shape doesn't include an id.
var _last_screenshot_rq_id := -1

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
##
## Engine reality (verified 4.7 source):
##   SceneDebugger::_msg_rq_screenshot saves viewport PNG to OS temp and replies
##   game_view:get_screenshot [p_args[0], width, height, path] (4 fields).
##   GameViewDebugger::capture() checks message == "game_view:get_screenshot"
##   (full prefixed), so EditorDebuggerPlugin._capture receives full form:
##   typically "game_view:get_screenshot" or stripped "get_screenshot".
##   Be aggressively tolerant: accept StringName, handle int-as-string, and
##   always try to find a png path.
func _capture(message: String, data: Array, _session_id: int) -> bool:
	if not _screenshot_capture_active:
		return false
	var m := str(message)
	if m != "get_screenshot" and not m.ends_with("get_screenshot"):
		return false
	# Fast path: exact engine shape [id, w, h, path] — engine always
	# sends .png, but accept .jpg too for forward compat.
	if data.size() >= 4:
		var path_candidate := str(data[3])
		if (
			path_candidate.ends_with(".png")
			or path_candidate.contains(".png")
			or path_candidate.ends_with(".jpg")
			or path_candidate.ends_with(".jpeg")
			or path_candidate.contains(".jpg")
		):
			var id_val := _last_screenshot_rq_id if _last_screenshot_rq_id >= 0 else 0
			var w_val := 0
			var h_val := 0
			# id may be int or float Variant, or even StringName numeric
			if data[0] is int or data[0] is float:
				id_val = int(data[0])
			else:
				var s0 := str(data[0])
				if s0.is_valid_int():
					id_val = s0.to_int()
				elif s0.is_valid_float():
					id_val = int(s0.to_float())
			if data[1] is int or data[1] is float:
				w_val = int(data[1])
			elif str(data[1]).is_valid_int():
				w_val = str(data[1]).to_int()
			if data[2] is int or data[2] is float:
				h_val = int(data[2])
			elif str(data[2]).is_valid_int():
				h_val = str(data[2]).to_int()
			screenshot_received.emit(id_val, w_val, h_val, path_candidate)
			return true
	# Fallback permissive: find any png path and up to 3 numeric values
	var png_path := ""
	var found_id := -1
	var found_w := 0
	var found_h := 0
	var numeric: Array = []
	for elem in data:
		var s := str(elem)
		if s.ends_with(".png") or s.ends_with(".jpg") or s.ends_with(".jpeg"):
			png_path = s
			continue
		if (
			png_path.is_empty()
			and s.contains("/")
			and (
				s.contains("scr-")
				or s.contains("tmp")
				or s.contains("Temp")
				or s.contains(".png")
				or s.contains(".jpg")
			)
		):
			png_path = s
			continue
		if s.is_valid_int() or s.is_valid_float():
			# Avoid treating a pure path that happens to parse as int — but
			# our png_path already captured, so remaining numerics are dims/id
			numeric.append(int(float(s)))
		elif elem is int or elem is float:
			numeric.append(int(elem))
	if png_path.is_empty():
		for elem in data:
			var s2 := str(elem)
			if s2.contains("/"):
				png_path = s2
				break
	if png_path.is_empty():
		return false
	if numeric.size() >= 3:
		found_id = int(numeric[0])
		found_w = int(numeric[1])
		found_h = int(numeric[2])
	elif numeric.size() >= 1:
		found_id = int(numeric[0])
	if found_id < 0:
		found_id = _last_screenshot_rq_id if _last_screenshot_rq_id >= 0 else 0
	screenshot_received.emit(found_id, found_w, found_h, png_path)
	return true


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
	_last_screenshot_rq_id = rq_id
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
	_last_screenshot_rq_id = rq_id
	session.send_message(SCREENSHOT_REQUEST_MESSAGE, [rq_id])
	return true


## Asks the FIRST active debugger session's game to bring its window to
## focus (multi-session editors target the first live game, same as
## screenshot requests). Returns true when the message was sent; false when
## no live session exists (e.g. no game running).
func send_focus_request() -> bool:
	var sessions := get_sessions()
	for i in range(sessions.size()):
		if _send_focus_to_session(get_session(i)):
			return true
	if not sessions.is_empty():
		return false
	var fallback := get_session(0)
	if fallback != null:
		return _send_focus_to_session(fallback)
	return false


## Sends the focus-window message to a session. Returns true when the
## message was sent to a live session. Overridable seam for tests.
func _send_focus_to_session(session: EditorDebuggerSession) -> bool:
	if session == null or not session.is_active():
		return false
	session.send_message(FOCUS_WINDOW_MESSAGE, [])
	return true
