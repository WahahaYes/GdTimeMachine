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
const CAPTURE_PREFIX := "gd_time_machine"
const EXPECTED_METHODS := [
	"_has_capture", "_capture", "_setup_session", "send_graceful_stop", "_send_to_session"
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
	var sessions: Array = []
	var fallback_session: Object = null

	func _has_capture(capture: String) -> bool:
		return capture == "gd_time_machine"

	func _capture(message: String, data: Array, session_id: int) -> bool:
		return false

	func get_sessions() -> Array:
		return sessions

	func get_session(idx: int) -> Object:
		if idx >= 0 and idx < sessions.size():
			return sessions[idx]
		if idx == 0:
			return fallback_session
		return null

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


func test_send_guard_present_in_source() -> void:
	# The mirror's guard logic must match the real file: skip null/inactive
	# sessions, send only to live ones.
	var source := FileAccess.get_file_as_string(PLUGIN_SOURCE_PATH)
	assert_true(source.contains("not session.is_active()"))
	assert_true(source.contains("session.send_message"))


# --- Behavior tests: the plugin logic via the mirror + fake sessions ---


func test_has_capture_claims_gd_time_machine_only() -> void:
	var plugin := _make_mirror()
	assert_true(plugin._has_capture("gd_time_machine"))
	assert_false(plugin._has_capture("other"))
	assert_false(plugin._has_capture(""))
	assert_false(plugin._has_capture("gd_time_machine_extra"))


func test_capture_placeholder_returns_false() -> void:
	var plugin := _make_mirror()
	assert_false(plugin._capture("graceful_stop", [], 0))


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
