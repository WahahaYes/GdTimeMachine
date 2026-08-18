@tool
extends GutTest

## OBSClient tests: auth challenge-response, the WebSocket state machine
## (Hello → Identify → Identified → READY), request/response correlation, event
## passthrough, close/failure surfacing, and connect timeout — synchronous
## through the _create_websocket_peer/_now seams. The reference vectors below
## were computed independently with python3 hashlib/base64, NOT by the code
## under test: base64(sha256(base64(sha256(password + salt)) + challenge)).

const REF_PASSWORD_1 := "password"
const REF_SALT_1 := "salt"
const REF_CHALLENGE_1 := "challenge"
const REF_VECTOR_1 := "zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA="

const REF_PASSWORD_2 := "p@ss w0rd"
const REF_SALT_2 := "s01t"
const REF_CHALLENGE_2 := "chal-1"
const REF_VECTOR_2 := "OviXHTMUDxkuThqADhlITYdX+RovQ9rp+QknwnKk4MY="

const REF_VECTOR_EMPTY := "XEB0z23rR/W2r5xf4+C70OQrlZb+iKxU1ca275h+DyA="

# UTF-8 password regression vector (independently computed with python3).
const REF_PASSWORD_UTF8 := "café🔑"
const REF_SALT_UTF8 := "salt"
const REF_CHALLENGE_UTF8 := "challenge"
const REF_VECTOR_UTF8 := "xLgCHa9UGHBW8cFQB4EeVRjs7iBLiH9KhO3pob6jeHU="


## Fake WebSocketPeer standing in for the native class, which cannot be
## subclassed in GDScript (its native methods are not overridable). Exposes the
## exact surface OBSClient touches. `incoming` feeds inbound JSON frames; `sent`
## records outbound text frames; `ready_state`/`close_code`/`close_reason` are
## driven by the test.
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


## Client under test with the fake peer injected and a controllable clock.
class FakeOBSClient:
	extends OBSClient
	var peer := FakeWebSocketPeer.new()
	var fake_now := 0.0

	func _create_websocket_peer():
		return peer

	func _now() -> float:
		return fake_now


## Members capture signal payloads: GDScript lambdas capture outer locals BY
## VALUE in this Godot version, so a lambda writing a captured local cannot be
## read back afterwards. Writing through self works.
var _captured_established := false
var _captured_authenticated := false
var _captured_failure_msg := ""
var _captured_failure_emitted := false
var _captured_close_code := 0
var _captured_close_reason := ""
var _captured_rid := ""
var _captured_result := false
var _captured_req_code := 0
var _captured_resp_data := {}
var _captured_req_count := 0
var _captured_event_type := ""
var _captured_event_data := {}
var _captured_event_count := 0
var _captured_auth_fail_msg := ""
var _captured_rpc_fail_msg := ""


func before_each() -> void:
	_captured_established = false
	_captured_authenticated = false
	_captured_failure_msg = ""
	_captured_failure_emitted = false
	_captured_close_code = 0
	_captured_close_reason = ""
	_captured_rid = ""
	_captured_result = false
	_captured_req_code = 0
	_captured_resp_data = {}
	_captured_req_count = 0
	_captured_event_type = ""
	_captured_event_data = {}
	_captured_event_count = 0
	_captured_auth_fail_msg = ""
	_captured_rpc_fail_msg = ""


func _make_client() -> FakeOBSClient:
	var client: FakeOBSClient = add_child_autofree(FakeOBSClient.new())
	return client


## Auth vector tests


func test_generate_auth_matches_pinned_reference_vectors() -> void:
	assert_eq(OBSClient._generate_auth(REF_PASSWORD_1, REF_SALT_1, REF_CHALLENGE_1), REF_VECTOR_1)
	assert_eq(OBSClient._generate_auth(REF_PASSWORD_2, REF_SALT_2, REF_CHALLENGE_2), REF_VECTOR_2)
	assert_eq(OBSClient._generate_auth("", "", ""), REF_VECTOR_EMPTY)
	assert_eq(
		OBSClient._generate_auth(REF_PASSWORD_UTF8, REF_SALT_UTF8, REF_CHALLENGE_UTF8),
		REF_VECTOR_UTF8,
	)


## Connection setup tests


func test_connect_to_obs_rejects_out_of_range_port() -> void:
	# Port must be 1–65535; rejection happens before any state is touched.
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	assert_eq(client.connect_to_obs("localhost", 0, "pw"), ERR_INVALID_PARAMETER)
	assert_eq(client.connect_to_obs("localhost", 65536, "pw"), ERR_INVALID_PARAMETER)
	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)
	assert_eq(peer.connect_urls, [])


func test_connect_to_obs_stores_password_and_requests_subprotocol() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	var err := client.connect_to_obs("obs.example.com", 4456, "pw")
	assert_eq(err, OK)
	assert_eq(peer.connect_urls, ["ws://obs.example.com:4456"])
	assert_eq(peer.supported_protocols, PackedStringArray([OBSClient.SUBPROTOCOL]))
	assert_eq(client._password, "pw")
	assert_eq(client.get_state(), OBSClient.State.CONNECTING)


## Handshake tests


func _hello_frame(authentication: Dictionary = {}) -> PackedByteArray:
	var d := {"obsWebSocketVersion": "5.5.0", "rpcVersion": 1}
	if not authentication.is_empty():
		d["authentication"] = authentication
	return JSON.stringify({"op": OBSClient.OP_HELLO, "d": d}).to_utf8_buffer()


func _identified_frame() -> PackedByteArray:
	return (
		JSON
		. stringify({"op": OBSClient.OP_IDENTIFIED, "d": {"negotiatedRpcVersion": 1}})
		. to_utf8_buffer()
	)


func _connect_and_authenticate(client: FakeOBSClient, peer: FakeWebSocketPeer) -> void:
	client.connect_to_obs()
	peer.incoming.append(_hello_frame())
	client._process(0.0)
	peer.incoming.append(_identified_frame())
	client._process(0.0)


func test_handshake_without_auth_sends_identify_and_authenticates() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connection_established.connect(func() -> void: _captured_established = true)
	client.connection_authenticated.connect(func() -> void: _captured_authenticated = true)
	assert_eq(client.connect_to_obs(), OK)
	assert_false(client.is_connected_to_obs())
	# Hello without a challenge → Identify (op 1, no authentication).
	peer.incoming.append(_hello_frame())
	client._process(0.0)
	assert_true(_captured_established)
	assert_eq(client.get_state(), OBSClient.State.AWAITING_IDENTIFIED)
	var identify: Dictionary = JSON.parse_string(peer.sent[0])
	# JSON.parse_string yields floats; int-cast before comparing with the int op-code constants.
	assert_eq(int(identify["op"]), OBSClient.OP_IDENTIFY)
	var identify_data: Dictionary = identify["d"]
	assert_eq(int(identify_data["rpcVersion"]), OBSClient.RPC_VERSION)
	assert_eq(int(identify_data["eventSubscriptions"]), OBSClient.EVENT_SUBSCRIPTIONS)
	assert_false(identify_data.has("authentication"))
	# Identified → READY + authenticated.
	peer.incoming.append(_identified_frame())
	client._process(0.0)
	assert_true(_captured_authenticated)
	assert_true(client.is_connected_to_obs())
	assert_eq(client.get_state(), OBSClient.State.READY)


func test_handshake_with_challenge_sends_pinned_auth_vector() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connect_to_obs("localhost", 4455, REF_PASSWORD_1)
	peer.incoming.append(_hello_frame({"challenge": REF_CHALLENGE_1, "salt": REF_SALT_1}))
	client._process(0.0)
	assert_eq(client.get_state(), OBSClient.State.AWAITING_IDENTIFIED)
	var identify: Dictionary = JSON.parse_string(peer.sent[0])
	var identify_data: Dictionary = identify["d"]
	assert_eq(identify_data["authentication"], REF_VECTOR_1)


func test_empty_password_omits_authentication_field() -> void:
	# Challenge present + EMPTY password → NO authentication field: the server
	# is left to accept (auth disabled) or close 4009 (auth enabled).
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connect_to_obs("localhost", 4455, "")
	peer.incoming.append(_hello_frame({"challenge": REF_CHALLENGE_1, "salt": REF_SALT_1}))
	client._process(0.0)
	var identify: Dictionary = JSON.parse_string(peer.sent[0])
	var identify_data: Dictionary = identify["d"]
	assert_false(identify_data.has("authentication"))


## Request/response and event tests


func _event_frame(event_type: String, event_data: Dictionary = {}) -> PackedByteArray:
	return (
		JSON
		. stringify(
			{
				"op": OBSClient.OP_EVENT,
				"d": {"eventType": event_type, "eventData": event_data},
			}
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
				"op": OBSClient.OP_REQUEST_RESPONSE,
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


func test_send_request_frame_shape_and_id_generation() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	var rid := client.send_request("StartRecord", {"sceneName": "x"})
	assert_eq(rid, "req_0")
	assert_eq(client.send_request("GetVersion"), "req_1")
	# A custom id is honored verbatim and does not advance the counter.
	assert_eq(client.send_request("GetVersion", {}, "custom"), "custom")
	assert_eq(client.send_request("GetVersion"), "req_2")
	var payload: Dictionary = JSON.parse_string(peer.sent[1])
	assert_eq(int(payload["op"]), OBSClient.OP_REQUEST)
	var request: Dictionary = payload["d"]
	assert_eq(request["requestType"], "StartRecord")
	assert_eq(request["requestId"], "req_0")
	var request_data: Dictionary = request["requestData"]
	assert_eq(request_data["sceneName"], "x")


func test_request_response_correlation_and_unknown_drop() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	client.request_completed.connect(
		func(request_id: String, result: bool, code: int, response_data: Dictionary) -> void:
			_captured_rid = request_id
			_captured_result = result
			_captured_req_code = code
			_captured_resp_data = response_data
			_captured_req_count += 1
	)
	client.send_request("StartRecord")
	peer.incoming.append(
		_response_frame("req_0", true, OBSClient.STATUS_SUCCESS, {"outputActive": true})
	)
	client._process(0.0)
	assert_eq(_captured_rid, "req_0")
	assert_true(_captured_result)
	assert_eq(_captured_req_code, OBSClient.STATUS_SUCCESS)
	assert_eq(_captured_resp_data, {"outputActive": true})
	assert_eq(_captured_req_count, 1)
	# A response for an unknown requestId is dropped, not forwarded.
	peer.incoming.append(_response_frame("nope", false, 500, {}))
	client._process(0.0)
	assert_eq(_captured_req_count, 1)


func test_event_frame_forwarded_as_event_received() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	client.event_received.connect(
		func(event_type: String, event_data: Dictionary) -> void:
			_captured_event_type = event_type
			_captured_event_data = event_data
			_captured_event_count += 1
	)
	var data := {"outputActive": true, "outputState": "OBS_WEBSOCKET_OUTPUT_STARTED"}
	peer.incoming.append(_event_frame("RecordStateChanged", data))
	client._process(0.0)
	assert_eq(_captured_event_type, "RecordStateChanged")
	assert_eq(_captured_event_data, data)
	assert_eq(_captured_event_count, 1)


## Close/failure classification tests


func test_close_codes_classify_auth_and_rpc_failures() -> void:
	# 4009 → authentication failure; 4010 → unsupported RPC version.
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connection_failed.connect(func(msg: String) -> void: _captured_auth_fail_msg = msg)
	client.connect_to_obs("localhost", 4455, "wrong-password")
	peer.incoming.append(_hello_frame({"challenge": "c", "salt": "s"}))
	client._process(0.0)
	assert_eq(client.get_state(), OBSClient.State.AWAITING_IDENTIFIED)
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	peer.close_code = OBSClient.CLOSE_CODE_AUTH_FAILED
	peer.close_reason = "Authentication failed."
	client._process(0.0)
	assert_true(
		_captured_auth_fail_msg.contains("Authentication failed"),
		"got: '%s'" % _captured_auth_fail_msg,
	)
	assert_true(
		_captured_auth_fail_msg.contains("rejected the password"),
		"got: '%s'" % _captured_auth_fail_msg,
	)
	var client2 := _make_client()
	var peer2: FakeWebSocketPeer = client2.peer
	client2.connection_failed.connect(func(msg: String) -> void: _captured_rpc_fail_msg = msg)
	client2.connect_to_obs()
	peer2.ready_state = WebSocketPeer.STATE_CLOSED
	peer2.close_code = OBSClient.CLOSE_CODE_UNSUPPORTED_RPC
	client2._process(0.0)
	assert_true(
		_captured_rpc_fail_msg.contains("Unsupported RPC"),
		"got: '%s'" % _captured_rpc_fail_msg,
	)


func test_close_1006_with_empty_reason_reports_unreachable_host() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connection_failed.connect(func(msg: String) -> void: _captured_failure_msg = msg)
	client.connect_to_obs("127.0.0.1", 4455)
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	peer.close_code = 1006
	client._process(0.0)
	assert_true(
		_captured_failure_msg.contains("could not reach"),
		"got: '%s'" % _captured_failure_msg,
	)
	assert_true(
		_captured_failure_msg.contains("127.0.0.1:4455"),
		"got: '%s'" % _captured_failure_msg,
	)
	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)


func test_close_after_ready_emits_connection_closed() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	_connect_and_authenticate(client, peer)
	client.connection_closed.connect(
		func(code: int, reason: String) -> void:
			_captured_close_code = code
			_captured_close_reason = reason
	)
	client.connection_failed.connect(func(_msg: String) -> void: _captured_failure_emitted = true)
	peer.close_code = 1000
	peer.close_reason = "Shutting down"
	peer.ready_state = WebSocketPeer.STATE_CLOSED
	client._process(0.0)
	assert_eq(_captured_close_code, 1000)
	assert_eq(_captured_close_reason, "Shutting down")
	assert_false(_captured_failure_emitted)
	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)
	assert_false(client.is_connected_to_obs())


## Clock/process tests


func test_handshake_timeout_reports_timed_out() -> void:
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.connection_failed.connect(func(msg: String) -> void: _captured_failure_msg = msg)
	client.connect_to_obs()
	assert_eq(client.get_state(), OBSClient.State.CONNECTING)
	# The deadline was set to fake_now (0.0) + CONNECT_TIMEOUT; jump past it
	# with no Hello received.
	client.fake_now = 10.0
	client._process(0.0)
	assert_true(
		_captured_failure_msg.contains("timed out"),
		"got: '%s'" % _captured_failure_msg,
	)
	assert_eq(peer.close_calls.size(), 1)
	assert_eq(client.get_state(), OBSClient.State.DISCONNECTED)


func test_poll_processes_every_frame_without_throttle() -> void:
	# Two queued frames are each handled by the very next _process(0.0) — no
	# polling interval gates inbound messages.
	var client := _make_client()
	var peer: FakeWebSocketPeer = client.peer
	client.event_received.connect(
		func(_event_type: String, _event_data: Dictionary) -> void: _captured_event_count += 1
	)
	client.connect_to_obs()
	peer.incoming.append(_hello_frame())
	client._process(0.0)
	assert_eq(client.get_state(), OBSClient.State.AWAITING_IDENTIFIED)
	peer.incoming.append(_identified_frame())
	client._process(0.0)
	assert_true(client.is_connected_to_obs())
	peer.incoming.append(_event_frame("A"))
	client._process(0.0)
	peer.incoming.append(_event_frame("B"))
	client._process(0.0)
	assert_eq(_captured_event_count, 2)
