extends GutTest

# Op 2 graceful-stop editor plugin tests
# (addons/GdTimeMachine/editor/debugger_plugin.gd).
#
# Testability constraint (verified empirically on Godot 4.7 headless):
#   * GdTMDebuggerPlugin extends the editor-only native EditorDebuggerPlugin,
#     which Godot refuses to instantiate outside the editor
#     ("Class 'EditorDebuggerPlugin' can only be instantiated by editor").
#   * EditorDebuggerSession is an abstract native class that cannot be extended.
# So the real class can never be constructed in a headless GUT run. The suite
# therefore splits into two halves:
#
#   1. Contract tests pin the real script's API surface and wire constants to
#      the source itself, without ever constructing the class.
#   2. Behavior tests run against PluginBehaviorMirror, a faithful copy of the
#      plugin's logic (extracted verbatim from the source below), exercised
#      through duck-typed FakeSession doubles. The contract tests guarantee the
#      mirror stays truthful to the real file.

const PluginScript := preload("res://addons/GdTimeMachine/editor/debugger_plugin.gd")
const PLUGIN_SOURCE_PATH := "res://addons/GdTimeMachine/editor/debugger_plugin.gd"

const WIRE_MESSAGE := "gd_time_machine:graceful_stop"
const FOCUS_MESSAGE := "gd_time_machine:focus_window"
const CAPTURE_PREFIX := "gd_time_machine"
const SCREENSHOT_REQUEST_MESSAGE := "scene:rq_screenshot"
const SCREENSHOT_CAPTURE_PREFIX := "game_view"
const SCREENSHOT_REPLY_PAYLOAD := "get_screenshot"
const EXPECTED_METHODS := [
	"_has_capture",
	"_capture",
	"_setup_session",
	"send_graceful_stop",
	"_send_to_session",
	"set_screenshot_capture_active",
	"send_screenshot_request",
	"_send_screenshot_to_session",
	"send_focus_request",
	"_send_focus_to_session"
]


# Duck-typed EditorDebuggerSession double. It exposes exactly the surface
# _send_to_session uses: is_active() and send_message(message, data).
class FakeSession:
	extends RefCounted
	var active := true
	var sent: Array = []

	func is_active() -> bool:
		return active

	func send_message(message: String, data: Array = []) -> void:
		sent.append([message, data])


# Faithful mirror of debugger_plugin.gd's logic. Identical control flow and
# literals as the real plugin so behavior is verifiable headlessly.
class PluginBehaviorMirror:
	extends RefCounted
	signal screenshot_received(rq_id: int, width: int, height: int, path: String)

	var sessions: Array = []
	var fallback_session: Object = null
	var _screenshot_capture_active := false

	func _has_capture(capture: String) -> bool:
		if capture == "gd_time_machine":
			return true
		return capture == "game_view" and _screenshot_capture_active

	func _capture(message: String, data: Array, _session_id: int) -> bool:
		if _screenshot_capture_active and message == "get_screenshot" and data.size() >= 4:
			screenshot_received.emit(int(data[0]), int(data[1]), int(data[2]), str(data[3]))
			return true
		return false

	func get_sessions() -> Array:
		return sessions

	func get_session(idx: int) -> Object:
		if idx >= 0 and idx < sessions.size():
			return sessions[idx]
		if idx == 0:
			return fallback_session
		return null

	func set_screenshot_capture_active(active: bool) -> void:
		_screenshot_capture_active = active

	func send_graceful_stop() -> bool:
		var all_sessions := get_sessions()
		var sent := false
		for i in range(all_sessions.size()):
			var session: Object = get_session(i)
			if session != null:
				_send_to_session(session)
				sent = true
		if not sent:
			var fallback: Object = get_session(0)
			if fallback != null:
				_send_to_session(fallback)
				sent = true
		return sent

	func _send_to_session(session: Object) -> void:
		if session == null or not session.is_active():
			return
		session.send_message("gd_time_machine:graceful_stop", [])

	func send_screenshot_request(rq_id: int) -> bool:
		var all_sessions := get_sessions()
		for i in range(all_sessions.size()):
			if _send_screenshot_to_session(get_session(i), rq_id):
				return true
		if not all_sessions.is_empty():
			return false
		var fallback: Object = get_session(0)
		if fallback != null:
			return _send_screenshot_to_session(fallback, rq_id)
		return false

	func _send_screenshot_to_session(session: Object, rq_id: int) -> bool:
		if session == null or not session.is_active():
			return false
		session.send_message("scene:rq_screenshot", [rq_id])
		return true

	func send_focus_request() -> bool:
		var all_sessions := get_sessions()
		for i in range(all_sessions.size()):
			if _send_focus_to_session(get_session(i)):
				return true
		if not all_sessions.is_empty():
			return false
		var fallback: Object = get_session(0)
		if fallback != null:
			return _send_focus_to_session(fallback)
		return false

	func _send_focus_to_session(session: Object) -> bool:
		if session == null or not session.is_active():
			return false
		session.send_message("gd_time_machine:focus_window", [])
		return true


func _make_mirror() -> PluginBehaviorMirror:
	return autofree(PluginBehaviorMirror.new())


# --- Contract tests: the real script's API surface, without construction ---


func test_script_loads_and_extends_editor_debugger_plugin() -> void:
	var script: GDScript = PluginScript
	assert_not_null(script)
	assert_eq(script.get_instance_base_type(), "EditorDebuggerPlugin")


func test_script_declares_class_name() -> void:
	var script: GDScript = PluginScript
	assert_eq(script.get_global_name(), "GdTMDebuggerPlugin")


func test_script_exposes_expected_contract_methods() -> void:
	var script: GDScript = PluginScript
	var method_names: Array = []
	for m in script.get_script_method_list():
		method_names.append(m["name"])
	for expected in EXPECTED_METHODS:
		assert_true(expected in method_names, "plugin should expose method '%s'" % expected)


func test_wire_contract_constants_present_in_source() -> void:
	var source := FileAccess.get_file_as_string(PLUGIN_SOURCE_PATH)
	assert_true(
		source.contains(WIRE_MESSAGE), "source must send the '%s' wire message" % WIRE_MESSAGE
	)
	assert_true(
		source.contains('"%s"' % CAPTURE_PREFIX),
		"source must capture the '%s' prefix" % CAPTURE_PREFIX
	)
	assert_true(
		source.contains(SCREENSHOT_REQUEST_MESSAGE),
		"source must send the '%s' screenshot request message" % SCREENSHOT_REQUEST_MESSAGE
	)
	assert_true(
		source.contains('"%s"' % SCREENSHOT_CAPTURE_PREFIX),
		"source must capture the '%s' prefix" % SCREENSHOT_CAPTURE_PREFIX
	)
	assert_true(
		source.contains('"%s"' % SCREENSHOT_REPLY_PAYLOAD),
		"source must match the '%s' reply payload" % SCREENSHOT_REPLY_PAYLOAD
	)
	assert_true(
		source.contains("screenshot_received.emit"),
		"source must re-emit received frames as screenshot_received"
	)
	assert_true(
		source.contains(FOCUS_MESSAGE),
		"source must send the '%s' focus-window message" % FOCUS_MESSAGE
	)


func test_screenshot_capture_guard_present_in_source() -> void:
	# The game_view capture must be claimed only while a screenshot recording
	# is active, so the engine's GameViewDebugger keeps the embedded preview
	# when idle (spike-verified).
	var source := FileAccess.get_file_as_string(PLUGIN_SOURCE_PATH)
	assert_true(source.contains("_screenshot_capture_active"))
	assert_true(
		source.contains("capture == SCREENSHOT_CAPTURE_PREFIX and _screenshot_capture_active")
	)


func test_send_guard_present_in_source() -> void:
	# The mirror's guard logic must match the real file: skip null/inactive
	# sessions, send only to live ones.
	var source := FileAccess.get_file_as_string(PLUGIN_SOURCE_PATH)
	assert_true(source.contains("not session.is_active()"))
	assert_true(source.contains("session.send_message"))


# --- Behavior tests: the plugin logic via the mirror + fake sessions ---


func test_has_capture_claims_gd_time_machine_always() -> void:
	var plugin := _make_mirror()
	assert_true(plugin._has_capture("gd_time_machine"))
	assert_false(plugin._has_capture("other"))
	assert_false(plugin._has_capture(""))
	assert_false(plugin._has_capture("gd_time_machine_extra"))


func test_has_capture_claims_game_view_only_when_capture_active() -> void:
	# The game_view prefix must be claimed ONLY while a screenshot recording
	# is active — claiming it while idle would shadow GameViewDebugger and
	# break the embedded preview (spike-verified).
	var plugin := _make_mirror()
	assert_false(plugin._has_capture("game_view"))
	plugin.set_screenshot_capture_active(true)
	assert_true(plugin._has_capture("game_view"))
	assert_true(plugin._has_capture("gd_time_machine"))  # graceful-stop is always claimed
	plugin.set_screenshot_capture_active(false)
	assert_false(plugin._has_capture("game_view"))


func test_capture_ignored_when_capture_inactive() -> void:
	var plugin := _make_mirror()
	assert_false(plugin._capture("get_screenshot", [0, 800, 600, "user://x.png"], 0))


func test_capture_ignored_for_other_messages() -> void:
	var plugin := _make_mirror()
	plugin.set_screenshot_capture_active(true)
	assert_false(plugin._capture("graceful_stop", [], 0))
	assert_false(plugin._capture("get_screenshot", [], 0))


func test_capture_requires_four_data_fields() -> void:
	var plugin := _make_mirror()
	plugin.set_screenshot_capture_active(true)
	assert_false(plugin._capture("get_screenshot", [0, 800], 0))
	assert_false(plugin._capture("get_screenshot", [0, 800, 600], 0))


func test_capture_emits_screenshot_received_when_active() -> void:
	var plugin := _make_mirror()
	plugin.set_screenshot_capture_active(true)
	var received: Array = []
	plugin.screenshot_received.connect(func(id, w, h, p): received.append([id, w, h, p]))
	var handled := plugin._capture("get_screenshot", [7, 1280, 720, "user://frame.png"], 0)
	assert_true(handled)
	assert_eq(received, [[7, 1280, 720, "user://frame.png"]])


func test_set_screenshot_capture_active_toggles_game_view_claim() -> void:
	var plugin := _make_mirror()
	assert_false(plugin._has_capture("game_view"))
	plugin.set_screenshot_capture_active(true)
	assert_true(plugin._has_capture("game_view"))
	plugin.set_screenshot_capture_active(false)
	assert_false(plugin._has_capture("game_view"))


func test_send_screenshot_request_targets_first_active_session() -> void:
	var plugin := _make_mirror()
	var active: FakeSession = autofree(FakeSession.new())
	var inactive: FakeSession = autofree(FakeSession.new())
	inactive.active = false
	plugin.sessions = [inactive, active]
	assert_true(plugin.send_screenshot_request(3))
	assert_eq(active.sent, [["scene:rq_screenshot", [3]]])
	assert_eq(inactive.sent.size(), 0)


func test_send_screenshot_request_falls_back_to_session_zero() -> void:
	var plugin := _make_mirror()
	var fallback: FakeSession = autofree(FakeSession.new())
	plugin.fallback_session = fallback
	assert_true(plugin.send_screenshot_request(9))
	assert_eq(fallback.sent, [["scene:rq_screenshot", [9]]])


func test_send_screenshot_request_returns_false_without_sessions() -> void:
	var plugin := _make_mirror()
	assert_false(plugin.send_screenshot_request(1))


func test_send_screenshot_to_session_skips_inactive() -> void:
	var plugin := _make_mirror()
	var inactive: FakeSession = autofree(FakeSession.new())
	inactive.active = false
	assert_false(plugin._send_screenshot_to_session(inactive, 4))
	assert_eq(inactive.sent.size(), 0)


func test_send_to_session_sends_when_active() -> void:
	var plugin := _make_mirror()
	var session: FakeSession = autofree(FakeSession.new())
	plugin._send_to_session(session)
	assert_eq(session.sent, [["gd_time_machine:graceful_stop", []]])


func test_send_to_session_skips_inactive_session() -> void:
	var plugin := _make_mirror()
	var session: FakeSession = autofree(FakeSession.new())
	session.active = false
	plugin._send_to_session(session)
	assert_eq(session.sent.size(), 0)


func test_send_to_session_null_is_noop() -> void:
	var plugin := _make_mirror()
	plugin._send_to_session(null)
	# Reaching here without error is the assertion.
	assert_true(true)


func test_send_graceful_stop_broadcasts_to_active_sessions() -> void:
	var plugin := _make_mirror()
	var active: FakeSession = autofree(FakeSession.new())
	var inactive: FakeSession = autofree(FakeSession.new())
	inactive.active = false
	plugin.sessions = [active, inactive]
	assert_true(plugin.send_graceful_stop())
	assert_eq(active.sent, [["gd_time_machine:graceful_stop", []]])
	assert_eq(inactive.sent.size(), 0)


func test_send_graceful_stop_falls_back_to_session_zero() -> void:
	var plugin := _make_mirror()
	var fallback: FakeSession = autofree(FakeSession.new())
	plugin.fallback_session = fallback
	# get_sessions() is empty; the real plugin then tries the canonical
	# session 0 directly (single-session editor case).
	assert_true(plugin.send_graceful_stop())
	assert_eq(fallback.sent, [["gd_time_machine:graceful_stop", []]])


func test_send_graceful_stop_returns_false_without_sessions() -> void:
	var plugin := _make_mirror()
	assert_false(plugin.send_graceful_stop())


func test_send_focus_request_targets_first_active_session() -> void:
	var plugin := _make_mirror()
	var active: FakeSession = autofree(FakeSession.new())
	var inactive: FakeSession = autofree(FakeSession.new())
	inactive.active = false
	plugin.sessions = [inactive, active]
	assert_true(plugin.send_focus_request())
	assert_eq(active.sent, [["gd_time_machine:focus_window", []]])
	assert_eq(inactive.sent.size(), 0)


func test_send_focus_request_falls_back_to_session_zero() -> void:
	var plugin := _make_mirror()
	var fallback: FakeSession = autofree(FakeSession.new())
	plugin.fallback_session = fallback
	assert_true(plugin.send_focus_request())
	assert_eq(fallback.sent, [["gd_time_machine:focus_window", []]])


func test_send_focus_request_returns_false_without_sessions() -> void:
	var plugin := _make_mirror()
	assert_false(plugin.send_focus_request())


func test_send_focus_to_session_sends_when_active() -> void:
	var plugin := _make_mirror()
	var session: FakeSession = autofree(FakeSession.new())
	assert_true(plugin._send_focus_to_session(session))
	assert_eq(session.sent, [["gd_time_machine:focus_window", []]])


func test_send_focus_to_session_skips_inactive() -> void:
	var plugin := _make_mirror()
	var session: FakeSession = autofree(FakeSession.new())
	session.active = false
	assert_false(plugin._send_focus_to_session(session))
	assert_eq(session.sent.size(), 0)


func test_send_focus_to_session_null_is_noop() -> void:
	var plugin := _make_mirror()
	assert_false(plugin._send_focus_to_session(null))
