@tool
extends Node
class_name OBSClient

## OBS WebSocket 5.x client (Phase 0 surface only).
##
## Base stream for BackendOBS. Phase 0 (the auth gate in
## PLAN_obs_backend_v2.md §3) locks only the authentication plumbing surface:
## connect_to_obs() carries the settings password into _password, and
## _generate_auth() is pinned to an independently-computed reference vector in
## test_obs_client.gd. The full WebSocket state machine (Connect → Hello →
## Identify → Identified → READY) lands in Phase 1 (§4).
## @tool-safe: no Thread, no OS.execute.

## Default connection target (OBS v5 default port is 4455; v4 was 4444).
const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 4455

## WebSocket subprotocol required by obs-websocket.
const SUBPROTOCOL := "obswebsocket.json"

## Negotiated RPC version we identify with.
const RPC_VERSION := 1

## OBS close code meaning an authenticated server rejected our credentials.
const CLOSE_CODE_AUTH_FAILED := 4009

var _password := ""
var _host := DEFAULT_HOST
var _port := DEFAULT_PORT


## Connects to OBS at host:port (defaults 127.0.0.1:4455), requesting the
## obswebsocket.json subprotocol. Phase 0 records the target + password so the
## settings-plumbing test can assert the password lands in _password; the real
## WebSocket handshake arrives in Phase 1.
func connect_to_obs(
	host: String = DEFAULT_HOST, port: int = DEFAULT_PORT, password: String = ""
) -> int:
	if port < 1 or port > 65535:
		return ERR_INVALID_PARAMETER
	_host = host
	_port = port
	_password = password
	return OK


## OBS WebSocket 5.x auth challenge response:
## base64(sha256(base64(sha256(password + salt)) + challenge)). Ported
## verbatim from you-win/obs-websocket-gd (Apache-2.0); upstream takes
## (password, challenge, salt) — see NOTICE.txt. Pinned to an independent
## Python (hashlib/base64) reference vector in test_obs_client.gd.
static func _generate_auth(password: String, salt: String, challenge: String) -> String:
	var combined_secret := "%s%s" % [password, salt]
	var base64_secret := Marshalls.raw_to_base64(combined_secret.sha256_buffer())
	var combined_auth := "%s%s" % [base64_secret, challenge]
	return Marshalls.raw_to_base64(combined_auth.sha256_buffer())
