extends SceneTree

## Phase 0 live-OBS auth probe — the manual real-OBS matrix of
## PLAN_obs_backend_v2.md §3.3. Not part of the addon; Phase 0 tooling only.
##
## Verifies OBSClient._generate_auth against a real obs-websocket 5.x server.
## Usage (password as the first `--` user arg):
##   godot --headless --script res://tools/obs_auth_probe.gd -- <password>
##
## Documented matrix:
##   correct password + auth enabled  → RESULT IDENTIFIED
##   wrong password + auth enabled    → RESULT AUTH_FAILED (close 4009)
##   empty password + auth disabled   → RESULT IDENTIFIED (no authentication
##                                      field sent)

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 4455
const SUBPROTOCOL := "obswebsocket.json"
const OP_HELLO := 0
const OP_IDENTIFY := 1
const OP_IDENTIFIED := 2
const AUTH_FAILED_CLOSE := 4009
const TIMEOUT_S := 5.0


func _init() -> void:
	_run()


func _run() -> void:
	var user_args := OS.get_cmdline_user_args()
	var password := user_args[0] if user_args.size() > 0 else ""
	print(
		(
			"OBS auth probe → %s:%d, password: %s"
			% [
				DEFAULT_HOST,
				DEFAULT_PORT,
				"***" if not password.is_empty() else "(empty)",
			]
		)
	)
	var client_script := load("res://addons/GdTimeMachine/vendor/obs_client.gd")
	if client_script == null:
		push_error("cannot load res://addons/GdTimeMachine/vendor/obs_client.gd")
		quit(2)
		return
	var obs_client: Object = client_script.new()
	var peer := WebSocketPeer.new()
	peer.supported_protocols = PackedStringArray([SUBPROTOCOL])
	var err := peer.connect_to_url("ws://%s:%d" % [DEFAULT_HOST, DEFAULT_PORT])
	if err != OK:
		push_error("connect_to_url failed: %d" % err)
		quit(2)
		return
	var deadline := Time.get_ticks_msec() / 1000.0 + TIMEOUT_S
	var sent_identify := false
	while Time.get_ticks_msec() / 1000.0 < deadline:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			var code := peer.get_close_code()
			if code == AUTH_FAILED_CLOSE:
				print("RESULT AUTH_FAILED (close 4009): ", peer.get_close_reason())
			else:
				print("RESULT CLOSED code=", code, " reason=", peer.get_close_reason())
			quit(0)
			return
		if state != WebSocketPeer.STATE_OPEN:
			await process_frame
			continue
		while peer.get_available_packet_count() > 0:
			var packet: PackedByteArray = peer.get_packet()
			if not peer.was_string_packet():
				continue
			var msg: Dictionary = JSON.parse_string(packet.get_string_from_utf8())
			if msg.is_empty():
				continue
			var op: int = msg.get("op", -1)
			if op == OP_HELLO and not sent_identify:
				sent_identify = true
				var d: Dictionary = msg.get("d", {})
				var identify := {
					"op": OP_IDENTIFY,
					"d": {"rpcVersion": 1, "eventSubscriptions": 0},
				}
				var auth: Dictionary = d.get("authentication", {})
				if auth.is_empty() or password.is_empty():
					print("sending Identify WITHOUT authentication field")
				else:
					var salt: String = str(auth.get("salt", ""))
					var challenge: String = str(auth.get("challenge", ""))
					var auth_string: String = obs_client._generate_auth(password, salt, challenge)
					print("server challenged — computing _generate_auth(...)")
					identify["d"]["authentication"] = auth_string
				peer.send_text(JSON.stringify(identify))
			elif op == OP_IDENTIFIED:
				print("RESULT IDENTIFIED — real OBS accepted the auth response")
				peer.close(1000)
				quit(0)
				return
		await process_frame
	print("RESULT TIMEOUT after %ds — WebSocket enabled on port %d?" % [TIMEOUT_S, DEFAULT_PORT])
	quit(1)
