@tool
extends Node
class_name OBSClient

## Thin OBS WebSocket 5.x client used by BackendOBS. Owns a WebSocketPeer and
## pumps it from _process every frame (no throttle — recording Start/Stop are
## sub-frame) through DISCONNECTED → CONNECTING → AWAITING_HELLO →
## AWAITING_IDENTIFIED → READY → CLOSING. Requests (op 6) correlate to
## responses (op 7) by requestId; events (op 5) pass through.
##
## Auth rule: an EMPTY password sends NO `authentication` field in Identify;
## a server with auth enabled then closes with code 4009 (surfaced by the
## failure path). A non-empty password only ever accompanies a challenge
## from Hello.
##
## @tool-safe: no Thread, no OS.execute — everything happens from _process.
## Seams for GUT: _create_websocket_peer() (untyped — native WebSocketPeer
## methods aren't overridable, so tests fake it), _generate_auth() (static,
## pure), is_connected_to_obs(), get_ready_state(), _now().

enum State {
	DISCONNECTED,
	CONNECTING,
	AWAITING_HELLO,
	AWAITING_IDENTIFIED,
	READY,
	CLOSING,
}

## WebSocket op codes (obs-websocket 5.x).
const OP_HELLO := 0
const OP_IDENTIFY := 1
const OP_IDENTIFIED := 2
const OP_EVENT := 5
const OP_REQUEST := 6
const OP_REQUEST_RESPONSE := 7

## Negotiated RPC version we identify with.
const RPC_VERSION := 1

## WebSocket subprotocol required by obs-websocket.
const SUBPROTOCOL := "obswebsocket.json"

## Default connection target (obs-websocket default port 4455).
const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 4455

## OBS close codes used to classify connection failures.
const CLOSE_CODE_AUTH_FAILED := 4009
const CLOSE_CODE_UNSUPPORTED_RPC := 4010

## Request status codes surfaced verbatim via request_completed so BackendOBS
## can decide how to react.
const STATUS_SUCCESS := 100
const STATUS_NOT_READY := 207  ## e.g. scene collection still loading — retry.
const STATUS_OUTPUT_RUNNING := 500  ## StartRecord while outputActive.

## eventSubscriptions bitmask sent with Identify. Outputs (1<<6) is needed
## for RecordStateChanged; Scenes/Inputs/General round out the editor surface.
const EVENT_SUBSCRIPTIONS := (1 << 0) | (1 << 2) | (1 << 3) | (1 << 6)

## Seconds to wait for Hello before reporting connection_failed("timed out")
## — a websocket-disabled OBS accepts TCP but never sends Hello.
const CONNECT_TIMEOUT := 5.0

## The TCP/WebSocket connection is established and Identify has been sent.
signal connection_established

## OBS accepted our Identify (Identified received) — READY.
signal connection_authenticated

## A previously-established connection closed (not emitted for failed
## handshakes — those use connection_failed).
signal connection_closed(code: int, reason: String)

## The connection never reached READY: TCP refused, websocket disabled, auth
## rejected, or handshake timeout. message distinguishes the cause.
signal connection_failed(message: String)

## Every op 7 matched to a sent request. code is the raw requestStatus code.
signal request_completed(request_id: String, result: bool, code: int, response_data: Dictionary)

## Passthrough for op 5 events (e.g. RecordStateChanged).
signal event_received(event_type: String, event_data: Dictionary)

## Low-level passthrough for every inbound JSON frame, before dispatch.
signal data_received(raw: Dictionary)

## The WebSocketPeer (or a GUT fake thereof). Untyped so tests can substitute
## a plain RefCounted — native WebSocketPeer methods aren't overridable.
var _ws: Object = null

var _state: State = State.DISCONNECTED
var _password := ""
var _host := DEFAULT_HOST
var _port := DEFAULT_PORT
var _next_request_id := 0
var _connect_deadline := 0.0

## requestId → metadata for every request sent and not yet answered.
var _pending_requests: Dictionary = {}


func _ready() -> void:
	# Only run _process while a connection is (being) established.
	set_process(false)


## Connects to OBS at host:port (defaults 127.0.0.1:4455), requesting the
## obswebsocket.json subprotocol. Returns the connect Error; await
## connection_authenticated (or connection_failed) for the outcome.
## Out-of-range port (not 1–65535) is rejected with ERR_INVALID_PARAMETER
## before any state is touched; _password carries the settings password
## through to the Identify challenge-response.
func connect_to_obs(
	host: String = DEFAULT_HOST, port: int = DEFAULT_PORT, password: String = ""
) -> int:
	if port < 1 or port > 65535:
		return ERR_INVALID_PARAMETER
	if _ws != null:
		_ws.close()
		_ws = null
	_host = host
	_port = port
	_password = password
	_ws = _create_websocket_peer()
	_ws.supported_protocols = PackedStringArray([SUBPROTOCOL])
	_state = State.CONNECTING
	_connect_deadline = _now() + CONNECT_TIMEOUT
	set_process(true)
	# ws:// (non-TLS) — pass null TLS options; TLSOptions.client() would force TLS on a plain WS URL.
	return _ws.connect_to_url("ws://%s:%d" % [host, port], null)


## Sends an op 6 request, returning the requestId used (auto-generated
## incrementing "req_N" when empty). The matching op 7 fires request_completed
## with the same id; dropped with a warning if not connected.
func send_request(
	request_type: String, request_data: Dictionary = {}, request_id: String = ""
) -> String:
	if request_id == "":
		request_id = "req_%d" % _next_request_id
		_next_request_id += 1
	if _ws == null or get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("OBSClient.send_request('%s') ignored — not connected" % request_type)
		return request_id
	_pending_requests[request_id] = {"request_type": request_type}
	(
		_ws
		. send_text(
			(
				JSON
				. stringify(
					{
						"op": OP_REQUEST,
						"d":
						{
							"requestType": request_type,
							"requestId": request_id,
							"requestData": request_data,
						},
					}
				)
			)
		)
	)
	return request_id


## True once the handshake completed (Identified received) — named
## is_connected_to_obs because Node already owns is_connected(signal, callable).
func is_connected_to_obs() -> bool:
	return _state == State.READY


## Ready state of the underlying socket (WebSocketPeer.STATE_*).
func get_ready_state() -> int:
	if _ws == null:
		return WebSocketPeer.STATE_CLOSED
	return _ws.get_ready_state()


## Current handshake state, for diagnostics/UI.
func get_state() -> State:
	return _state


## Pumps the socket every frame while a connection is open.
func _process(_delta: float) -> void:
	if _ws == null:
		return
	_check_connect_timeout()
	if _ws == null:  # timeout tore the socket down
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if _state == State.CONNECTING:
				_state = State.AWAITING_HELLO
			_process_packets()
		WebSocketPeer.STATE_CLOSED:
			_on_socket_closed()


func _check_connect_timeout() -> void:
	if _state == State.READY or _state == State.CLOSING:
		return
	if _now() < _connect_deadline:
		return
	(
		connection_failed
		. emit(
			(
				"Connection timed out — no Hello from OBS within %.0f s (is the WebSocket server enabled?)"
				% CONNECT_TIMEOUT
			)
		)
	)
	_state = State.DISCONNECTED
	set_process(false)
	if _ws != null:
		_ws.close()
	_ws = null


func _process_packets() -> void:
	while _ws.get_available_packet_count() > 0:
		var packet: PackedByteArray = _ws.get_packet()
		if not _ws.was_string_packet():
			continue
		var data: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if data is Dictionary:
			_handle_message(data)


func _handle_message(data: Dictionary) -> void:
	data_received.emit(data)
	var d: Variant = data.get("d", {})
	if not d is Dictionary:
		return
	match int(data.get("op", -1)):
		OP_HELLO:
			if _state == State.AWAITING_HELLO:
				_handle_hello(d)
		OP_IDENTIFIED:
			if _state == State.AWAITING_IDENTIFIED:
				_state = State.READY
				connection_authenticated.emit()
		OP_EVENT:
			var event_data: Variant = d.get("eventData", {})
			(
				event_received
				. emit(
					str(d.get("eventType", "")),
					event_data if event_data is Dictionary else {},
				)
			)
		OP_REQUEST_RESPONSE:
			_handle_request_response(d)


func _handle_hello(d: Dictionary) -> void:
	_state = State.AWAITING_IDENTIFIED
	var authentication: Variant = d.get("authentication", {})
	var auth_string := ""
	# Only answer a real challenge with a real password: empty password →
	# no authentication field (auth-disabled connects, auth-enabled closes 4009).
	if _password != "" and authentication is Dictionary:
		var salt := str(authentication.get("salt", ""))
		var challenge := str(authentication.get("challenge", ""))
		if challenge != "" and salt != "":
			auth_string = _generate_auth(_password, salt, challenge)
	var identify_data := {"rpcVersion": RPC_VERSION, "eventSubscriptions": EVENT_SUBSCRIPTIONS}
	if auth_string != "":
		identify_data["authentication"] = auth_string
	_ws.send_text(JSON.stringify({"op": OP_IDENTIFY, "d": identify_data}))
	connection_established.emit()


func _handle_request_response(d: Dictionary) -> void:
	var request_id := str(d.get("requestId", ""))
	if request_id == "" or not _pending_requests.has(request_id):
		return
	_pending_requests.erase(request_id)
	var status: Dictionary = d.get("requestStatus", {})
	(
		request_completed
		. emit(
			request_id,
			bool(status.get("result", false)),
			int(status.get("code", -1)),
			d.get("responseData", {}),
		)
	)


func _on_socket_closed() -> void:
	var code: int = _ws.get_close_code() if _ws != null else 0
	var reason: String = _ws.get_close_reason() if _ws != null else ""
	if _state == State.READY or _state == State.CLOSING:
		connection_closed.emit(code, reason)
	else:
		# Never finished the handshake — distinguish the failure causes.
		connection_failed.emit(_describe_connect_failure(code, reason))
	_state = State.DISCONNECTED
	set_process(false)
	_ws = null


func _describe_connect_failure(code: int, reason: String) -> String:
	match code:
		CLOSE_CODE_AUTH_FAILED:
			return "Authentication failed — OBS rejected the password (close code 4009)"
		CLOSE_CODE_UNSUPPORTED_RPC:
			return "Unsupported RPC version (close code 4010)"
		_:
			if reason != "":
				return "Connection failed — %s (close code %d)" % [reason, code]
			return (
				"Connection failed — could not reach OBS at %s:%d (close code %d)"
				% [
					_host,
					_port,
					code,
				]
			)


## Socket factory seam for GUT — tests return a fake with the same surface.
## Untyped: a GDScript fake cannot extend WebSocketPeer (native methods
## aren't overridable).
func _create_websocket_peer():
	return WebSocketPeer.new()


## Monotonic time in seconds — seam for the connect-timeout tests.
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## OBS WebSocket 5.x auth challenge response:
## base64(sha256(base64(sha256(password + salt)) + challenge)). From
## you-win/obs-websocket-gd (Apache-2.0); upstream takes (password,
## challenge, salt) — see NOTICE.txt.
static func _generate_auth(password: String, salt: String, challenge: String) -> String:
	var combined_secret := "%s%s" % [password, salt]
	var base64_secret := Marshalls.raw_to_base64(combined_secret.sha256_buffer())
	var combined_auth := "%s%s" % [base64_secret, challenge]
	return Marshalls.raw_to_base64(combined_auth.sha256_buffer())
