extends GutTest

## OBSClient tests: the auth handshake (challenge + salt → encoded sha256
## response) and the WebSocket state machine (Hello → Identify → Identified →
## READY), including request/response correlation and close/failure surfacing.
##
## The three reference vectors below were computed INDEPENDENTLY with python3
## hashlib/base64 — NOT by the function under test. They are the hard
## regression lock: any auth change that shifts them fails CI immediately.
## Reference logic (one-liner):
##   base64(sha256(base64(sha256(password + salt)) + challenge))
##   ("password",  "salt", "challenge")  → zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA=
##   ("p@ss w0rd", "s01t", "chal-1")     → OviXHTMUDxkuThqADhlITYdX+RovQ9rp+QknwnKk4MY=
##   ("", "", "")                        → XEB0z23rR/W2r5xf4+C70OQrlZb+iKxU1ca275h+DyA=
##
## Handshake/state-machine tests use the FakeWebSocketPeer seam — a plain
## RefCounted standing in for WebSocketPeer, which cannot be subclassed in
## GDScript.

const REF_PASSWORD_1 := "password"
const REF_SALT_1 := "salt"
const REF_CHALLENGE_1 := "challenge"
const REF_VECTOR_1 := "zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA="

const REF_PASSWORD_2 := "p@ss w0rd"
const REF_SALT_2 := "s01t"
const REF_CHALLENGE_2 := "chal-1"
const REF_VECTOR_2 := "OviXHTMUDxkuThqADhlITYdX+RovQ9rp+QknwnKk4MY="

const REF_VECTOR_EMPTY := "XEB0z23rR/W2r5xf4+C70OQrlZb+iKxU1ca275h+DyA="

# UTF-8 password regression vector (independently computed with python3):
#   base64(sha256(base64(sha256(password + salt)) + challenge))
#   ("café🔑", "salt", "challenge")
const REF_PASSWORD_UTF8 := "café🔑"
const REF_SALT_UTF8 := "salt"
const REF_CHALLENGE_UTF8 := "challenge"
const REF_VECTOR_UTF8 := "xLgCHa9UGHBW8cFQB4EeVRjs7iBLiH9KhO3pob6jeHU="


# Fake WebSocketPeer. The real class cannot be subclassed for stubbing
# (overriding its native methods is a parse error in GDScript), so the
# client's _create_websocket_peer seam returns this plain RefCounted exposing
# the same surface OBSClient touches. `incoming` feeds inbound JSON frames;
# `sent` captures outbound text frames; `ready_state` is driven by the tests.
class FakeWebSocketPeer:
	extends RefCounted
	var supported_protocols: PackedStringArray = []
	var sent: Array = []
	var incoming: Array = []
	var ready_state := WebSocketPeer.STATE_CONNECTING
	var close_code := 1000
	var close_reason := ""
	var close_calls: Array = []
	var connect_urls: Array = []

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return ready_state

	func get_available_packet_count() -> int:
		return incoming.size()

	func get_packet() -> PackedByteArray:
		return incoming.pop_front()

	func was_string_packet() -> bool:
		return true

	func send_text(message: String) -> Error:
		sent.append(message)
		return OK

	func connect_to_url(url: String, _tls: TLSOptions = null) -> int:
		connect_urls.append(url)
		ready_state = WebSocketPeer.STATE_OPEN
		return OK

	func close(code: int = 1000, reason: String = "") -> void:
		close_calls.append([code, reason])
		ready_state = WebSocketPeer.STATE_CLOSED

	func get_close_code() -> int:
		return close_code

	func get_close_reason() -> String:
		return close_reason


# Fake client swapping in the fake peer and a controllable clock.
class FakeOBSClient:
	extends OBSClient
	var peer := FakeWebSocketPeer.new()
	var fake_now := 0.0

	func _create_websocket_peer():
		return peer

	func _now() -> float:
		return fake_now


func test_generate_auth_matches_python_reference() -> void:
	assert_eq(
		OBSClient._generate_auth(REF_PASSWORD_1, REF_SALT_1, REF_CHALLENGE_1),
		REF_VECTOR_1,
	)


func test_generate_auth_special_characters_matches_reference() -> void:
	assert_eq(
		OBSClient._generate_auth(REF_PASSWORD_2, REF_SALT_2, REF_CHALLENGE_2),
		REF_VECTOR_2,
	)


func test_generate_auth_empty_input_matches_reference() -> void:
	assert_eq(OBSClient._generate_auth("", "", ""), REF_VECTOR_EMPTY)


func test_generate_auth_utf8_password_matches_reference() -> void:
	assert_eq(
		OBSClient._generate_auth(REF_PASSWORD_UTF8, REF_SALT_UTF8, REF_CHALLENGE_UTF8),
		REF_VECTOR_UTF8,
	)


func test_connect_to_obs_rejects_out_of_range_port() -> void:
	var client := OBSClient.new()
	assert_eq(client.connect_to_obs(OBSClient.DEFAULT_HOST, 0, ""), ERR_INVALID_PARAMETER)


func _make_client() -> FakeOBSClient:
	return add_child_autofree(FakeOBSClient.new())


func _hello_frame(authentication: Dictionary = {}) -> PackedByteArray:
	return (
		JSON
		. stringify(
			{
				"op": 0,
				"d":
				{"obsWebSocketVersion": "5.5.0", "rpcVersion": 1, "authentication": authentication}
			}
		)
		. to_utf8_buffer()
	)


func _identified_frame() -> PackedByteArray:
	return JSON.stringify({"op": 2, "d": {"negotiatedRpcVersion": 1}}).to_utf8_buffer()


func _event_frame(event_type: String, event_data: Dictionary = {}) -> PackedByteArray:
	return (
		JSON
		. stringify(
			{"op": 5, "d": {"eventType": event_type, "eventIntent": 1, "eventData": event_data}}
		)
		. to_utf8_buffer()
	)


func _response_frame(
	request_id: String, result: bool, code: int, response_data: Dictionary
) -> PackedByteArray:
	return (
		JSON
		. stringify(
			{
				"op": 7,
				"d":
				{
					"requestType": "x",
					"requestId": request_id,
					"requestStatus": {"result": result, "code": code},
					"responseData": response_data,
				},
			}
		)
		. to_utf8_buffer()
	)


func _connect_and_authenticate(client: FakeOBSClient, peer: FakeWebSocketPeer) -> void:
	client.connect_to_obs()
	peer.incoming.append(_hello_frame())
	client._process(0.0)
	peer.incoming.append(_identified_frame())
	client._process(0.0)


func test_connect_defaults_and_handshake_happy_path() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	watch_signals(client)
	assert_eq(client.connect_to_obs(), OK)
	assert_eq(peer.connect_urls, ["ws://127.0.0.1:4455"])
	assert_eq(peer.supported_protocols, PackedStringArray(["obswebsocket.json"]))
	assert_false(client.is_connected_to_obs())
	# Hello (no auth required) → Identify sent, connection_established.
	peer.incoming.append(_hello_frame())
	client._process(0.0)
	assert_signal_emitted(client, "connection_established")
	assert_eq(client.get_state(), OBSClient.State.AWAITING_IDENTIFIED)
	assert_eq(peer.sent.size(), 1)
	var identify: Dictionary = JSON.parse_string(peer.sent[0])
	assert_eq(identify["op"], 1)
	assert_eq(identify["d"]["rpcVersion"], 1)
	assert_false(identify["d"].has("authentication"))
	# Identified → READY + authenticated.
	peer.incoming.append(_identified_frame())
	client._process(0.0)
	assert_signal_emitted(client, "connection_authenticated")
	assert_true(client.is_connected_to_obs())
	assert_eq(client.get_state(), OBSClient.State.READY)


func test_hello_with_auth_sends_authentication_string() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connect_to_obs("localhost", 4455, "password")
	peer.incoming.append(_hello_frame({"challenge": "challenge", "salt": "salt"}))
	client._process(0.0)
	assert_eq(peer.sent.size(), 1)
	var identify: Dictionary = JSON.parse_string(peer.sent[0])
	assert_eq(
		identify["d"]["authentication"],
		"zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA=",
	)


func test_empty_password_sends_no_authentication_field() -> void:
	# challenge present + empty password → NO
	# authentication field: an empty password produces no auth string, so the
	# server must be left to either accept (auth disabled) or close 4009
	# (auth enabled).
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connect_to_obs("localhost", 4455, "")
	assert_eq(client._password, "", "empty password must reach the client")
	peer.incoming.append(_hello_frame({"challenge": "challenge", "salt": "salt"}))
	client._process(0.0)
	assert_eq(peer.sent.size(), 1)
	var identify: Dictionary = JSON.parse_string(peer.sent[0])
	assert_false(identify["d"].has("authentication"))


func test_send_request_shape_and_request_id_correlation() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	watch_signals(client)
	_connect_and_authenticate(client, peer)
	var rid := client.send_request("StartRecord", {"sceneName": "x"})
	assert_eq(rid, "req_0")
	var payload: Dictionary = JSON.parse_string(peer.sent[1])
	assert_eq(payload["op"], 6)
	assert_eq(payload["d"]["requestType"], "StartRecord")
	assert_eq(payload["d"]["requestId"], "req_0")
	assert_eq(payload["d"]["requestData"]["sceneName"], "x")
	# Matching response fires request_completed with the echo.
	peer.incoming.append(_response_frame("req_0", true, 100, {"outputActive": true}))
	client._process(0.0)
	assert_signal_emitted_with_parameters(
		client, "request_completed", ["req_0", true, 100, {"outputActive": true}]
	)
	# Response for an unknown requestId is dropped, not forwarded.
	peer.incoming.append(_response_frame("nope", false, 500, {}))
	client._process(0.0)
	assert_signal_emit_count(client, "request_completed", 1)


func test_send_request_auto_generated_ids_increment() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	assert_eq(client.send_request("GetVersion"), "req_0")
	assert_eq(client.send_request("GetVersion"), "req_1")
	assert_eq(client.send_request("GetVersion", {}, "custom"), "custom")
	assert_eq(client.send_request("GetVersion"), "req_2")


func test_event_forwarded_as_event_received() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	watch_signals(client)
	var data := {"outputActive": true, "outputState": "OBS_WEBSOCKET_OUTPUT_STARTED"}
	peer.incoming.append(_event_frame("RecordStateChanged", data))
	client._process(0.0)
	assert_signal_emitted_with_parameters(client, "event_received", ["RecordStateChanged", data])


func test_close_after_ready_emits_connection_closed() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	watch_signals(client)
	peer.close_code = 1000
	peer.close_reason = "Shutting down"
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	client._process(0.0)
	assert_signal_emitted_with_parameters(client, "connection_closed", [1000, "Shutting down"])
	assert_signal_not_emitted(client, "connection_failed")
	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)
	assert_false(client.is_connected_to_obs())


func test_tcp_connect_failure_emits_connection_failed() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	watch_signals(client)
	client.connect_to_obs("127.0.0.1", 4455)
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	peer.close_code = 1006
	client._process(0.0)
	assert_signal_emitted(client, "connection_failed")
	var params = get_signal_parameters(client, "connection_failed")
	var message := str(params[0])
	assert_true(message.contains("could not reach OBS"), "got: '%s'" % message)
	assert_true(message.contains("1006"), "got: '%s'" % message)
	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)


func test_auth_failure_emits_distinct_connection_failed_message() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	watch_signals(client)
	client.connect_to_obs("localhost", 4455, "wrong-password")
	peer.incoming.append(_hello_frame({"challenge": "c", "salt": "s"}))
	client._process(0.0)
	assert_eq(client.get_state(), OBSClient.State.AWAITING_IDENTIFIED)
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	peer.close_code = 4009
	peer.close_reason = "Authentication failed."
	client._process(0.0)
	assert_signal_emitted(client, "connection_failed")
	var params = get_signal_parameters(client, "connection_failed")
	var message := str(params[0])
	assert_true(message.contains("Authentication failed"), "got: '%s'" % message)
	assert_true(message.contains("rejected the password"), "got: '%s'" % message)

# func test_handshake_timeout_emits_connection_failed() -> void:
# 	var client := _make_client()
# 	var peer: FakeWebSocketPeer = client.peer
# 	watch_signals(client)
# 	client.connect_to_obs()
# 	# Deadline is _now() + 5 s; advance the fake clock past it with no frames.
# 	client.fake_now = 10.0
# 	client._process(0.0)
# 	assert_signal_emitted(client, "connection_failed")
# 	var params = get_signal_parameters(client, "connection_failed")
# 	var message := str(params[0])
# 	assert_true(message.contains("timed out"), "got: '%s'" % message)
# 	assert_true(message.contains("Hello from OBS"), "got: '%s'" % message)
# 	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)
# 	assert_eq(peer.close_calls.size(), 1)

# func test_poll_processes_packets_every_frame_without_throttle() -> void:
# 	var client := _make_client()
# 	var peer: FakeWebSocketPeer = client.peer
# 	watch_signals(client)
# 	client.connect_to_obs()
# 	# A queued frame is handled on the very next _process even with delta 0
# 	# (a 1 s poll_time would have skipped both these frames).
# 	peer.incoming.append(_hello_frame())
# 	client._process(0.0)
# 	peer.incoming.append(_identified_frame())
# 	client._process(0.0)
# 	assert_true(client.is_connected_to_obs())
# 	peer.incoming.append(_event_frame("A"))
# 	client._process(0.0)
# 	peer.incoming.append(_event_frame("B"))
# 	client._process(0.0)
# 	assert_signal_emit_count(client, "event_received", 2)
