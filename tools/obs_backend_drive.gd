extends SceneTree

## Interactive driver for BackendOBS (`backend/backend_obs.gd`). Runs the REAL
## backend against a live obs-websocket server — real WebSocket probe, real
## connect/StartRecord/StopRecord, real move-after-stop, real settings read —
## or the "OBS Studio not found" error path with no OBS at all.
##
## The only seams stubbed are the scene seams (_is_playing_scene/_play_scene),
## which would back onto EditorInterface — this driver records "the scene is
## already playing".
##
## Usage:
##   godot --headless -s --path . tools/obs_backend_drive.gd -- [options]
##
## Options:
##   --host H           OBS host (default 127.0.0.1)
##   --port P           OBS WebSocket port (default 4455)
##   --password X       OBS password; omit for an auth-disabled server
##   --binary PATH      force the OBS binary for is_obs_installed() (needed when
##                      OBS runs but isn't resolvable on PATH)
##   --output PATH      dock-side output base (default res://media/captures/obs/obs_driver)
##   --wait SECONDS     record this long before stop() (default 3)
##   --launch           auto_launch OBS (requires --binary)
##   --no-obs           B1 path: force "not installed", expect the actionable error
##
## Expected RESULT lines:
##   live server, no password      → RESULT OK (recording started+stopped, file moved)
##   live server, matching password→ RESULT OK
##   live server, wrong password   → RESULT ERROR with the 4009 password guidance
##   no OBS running                → RESULT TIMEOUT (probe can't authenticate)
##   --no-obs                      → RESULT EXPECTED_ERROR "OBS Studio not found"

const DEFAULT_OUTPUT := "res://media/captures/obs/obs_driver"
const START_TIMEOUT := 10.0
const STOP_TIMEOUT := 10.0
const AVAIL_TIMEOUT := 6.0

var _args := {}
var _backend: DriverBackend
var _outcome := {}
var _watched := {}


## BackendOBS with scene seams stubbed and a forced binary resolve.
class DriverBackend:
	extends BackendOBS
	var no_obs := false
	var binary_override := ""

	func _ready() -> void:
		pass

	func _is_playing_scene() -> bool:
		return true

	func _play_scene(scene_path: String) -> void:
		print(
			(
				(
					"[driver] scene seam (stubbed — the dock launches the game in "
					+ "the editor): play_scene('%s')"
				)
				% scene_path
			)
		)

	func _resolve_obs_binary() -> String:
		if no_obs:
			return ""
		if not binary_override.is_empty():
			return binary_override
		return super()


func _init() -> void:
	_parse_args()
	_configure_settings()
	_run()


func _run() -> void:
	await process_frame  # let the tree settle before adding the backend
	_backend = DriverBackend.new()
	_backend.no_obs = _flag("no-obs")
	_backend.binary_override = _opt("binary", "")
	root.add_child(_backend)
	_connect_watchers()
	var password := _opt("password", "")
	var mask := "***" if not password.is_empty() else "(empty)"
	print(
		(
			"OBS backend driver → ws://%s:%s  password: %s  auto_launch: %s  no_obs: %s"
			% [
				_opt("host", "127.0.0.1"),
				_opt("port", "4455"),
				mask,
				_flag("launch"),
				_flag("no-obs"),
			]
		)
	)
	if _flag("no-obs"):
		await _run_no_obs()
		return
	await _run_live()


## B1 path: is_obs_installed() returns false via the forced empty resolve, so
## start() must emit the actionable "OBS Studio not found" error before any
## connection attempt.
func _run_no_obs() -> void:
	_watch_outcome(["recording_error"])
	await _backend.start(_base_config())
	var out := await _wait_outcome(START_TIMEOUT)
	if out.get("name", "") != "recording_error":
		print("RESULT UNEXPECTED — no recording_error within %.0f s" % START_TIMEOUT)
		quit(2)
		return
	var msg := _outcome_message(out)
	if msg.contains("OBS Studio not found"):
		print("RESULT EXPECTED_ERROR — not-installed path surfaced the actionable B1 error")
		quit(0)
		return
	print("RESULT UNEXPECTED_ERROR — %s" % msg)
	quit(2)


func _run_live() -> void:
	var output := _opt("output", DEFAULT_OUTPUT)
	var wait_s := float(_opt("wait", "3.0"))
	var out_dir := output.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	# Cold cache: is_obs_running() returns stale false and fires an async probe,
	# so start() would bail out of ensure_obs_running() before the answer lands.
	# Gate on a fresh probe first. --launch bypasses the gate so start()'s
	# ensure_obs_running() can launch and poll for itself.
	if not _flag("launch"):
		_watch_outcome(["availability_changed"])
		_backend.probe_obs_async()
		var avail_out := await _wait_outcome(AVAIL_TIMEOUT)
		if avail_out.get("name", "") != "availability_changed":
			print(
				(
					"RESULT TIMEOUT — no probe answer within %.0f s (is the WebSocket server enabled?)"
					% AVAIL_TIMEOUT
				)
			)
			quit(1)
			return
		var avail_args: Array = avail_out.get("args", [])
		if avail_args.size() == 0 or not bool(avail_args[0]):
			var probe_msg := str(_backend._last_connect_error)
			if probe_msg.contains("Authentication failed"):
				print("RESULT ERROR — %s" % probe_msg)
				print(
					(
						"[driver] password mismatch — the server IS reachable but rejected the "
						+ "identify; fix OBS → Tools → WebSocket Server Settings, or rerun with "
						+ "--password <matching>"
					)
				)
			else:
				print(
					(
						"RESULT ERROR — OBS unreachable on ws://%s:%s (%s)"
						% [_opt("host", "127.0.0.1"), _opt("port", "4455"), probe_msg]
					)
				)
				print("[driver] start OBS (or rerun with --launch and --binary <path>)")
			quit(2)
			return
	_watch_outcome(["recording_started", "recording_error"])
	await _backend.start(_base_config())
	var out := await _wait_outcome(START_TIMEOUT)
	match out.get("name", ""):
		"recording_error":
			_print_start_error(_outcome_message(out))
			quit(2)
			return
		"timeout":
			print(
				(
					(
						"RESULT TIMEOUT — no recording_started within %.0f s (is OBS "
						+ "running with the WebSocket server enabled?)"
					)
					% START_TIMEOUT
				)
			)
			quit(1)
			return
	print("[driver] recording for %.1f s, then stop…" % wait_s)
	await create_timer(wait_s).timeout
	_backend.stop()
	_watch_outcome(["recording_stopped", "recording_error"])
	var stop_out := await _wait_outcome(STOP_TIMEOUT)
	match stop_out.get("name", ""):
		"recording_stopped":
			var final_path := "%s.mp4" % output
			var exists := (
				FileAccess.file_exists(final_path)
				or FileAccess.file_exists(ProjectSettings.globalize_path(final_path))
			)
			print(
				(
					"RESULT OK — recorded %.1f s → %s (file %s)"
					% [wait_s, final_path, "present" if exists else "MISSING"]
				)
			)
			quit(0)
			return
		"recording_error":
			print("RESULT STOP_ERROR — %s" % _outcome_message(stop_out))
			quit(2)
			return
		_:
			print("RESULT STOP_TIMEOUT — no recording_stopped within %.0f s" % STOP_TIMEOUT)
			quit(1)
			return


func _print_start_error(msg: String) -> void:
	print("RESULT ERROR — %s" % msg)
	if msg.contains("Authentication failed"):
		print(
			(
				"[driver] password mismatch — fix OBS → Tools → WebSocket Server "
				+ "Settings, then rerun with --password <matching>"
			)
		)
	elif msg.contains("OBS Studio not found"):
		print(
			"[driver] hint: pass --binary <path> so is_obs_installed() resolves (or use --no-obs)"
		)
	print(
		"RESULT ERROR path complete — session ends with an actionable message (the B1/Bug-7 invariants)"
	)


func _base_config() -> Dictionary:
	var output := _opt("output", DEFAULT_OUTPUT)
	return {
		"output_path": output,
		"output_dir": output.get_base_dir(),
		"duration": 0.0,
		"fps": 60,
		"output_format": "mp4",
		"scene_path": "",
	}


# --- signal plumbing ---


## Typed handlers. BackendOBS signal signatures are fixed, so each connection
## uses its exact arity (GDScript lambdas can't be variadic).
func _connect_watchers() -> void:
	_backend.availability_changed.connect(_on_availability)
	_backend.recording_started.connect(_on_started)
	_backend.recording_stopped.connect(_on_stopped)
	_backend.recording_error.connect(_on_error)


func _record(signal_name: String, args: Array) -> void:
	if _outcome.is_empty() and _watched.has(signal_name):
		_outcome = {"name": signal_name, "args": args}


func _on_availability(v: bool) -> void:
	print("[signal] availability_changed → %s" % v)
	_record("availability_changed", [v])


func _on_started(_name: String, path: String) -> void:
	print("[signal] recording_started → %s" % path)
	_record("recording_started", [_name, path])


func _on_stopped(_name: String, path: String) -> void:
	print("[signal] recording_stopped → %s" % path)
	_record("recording_stopped", [_name, path])


func _on_error(_name: String, message: String) -> void:
	print("[signal] recording_error → %s" % message)
	_record("recording_error", [_name, message])


## Sets which signals the next _wait_outcome() phase should capture. Call this
## BEFORE start()/stop() so even a synchronous recording_error (e.g. the B1
## gate) is recorded.
func _watch_outcome(names: Array) -> void:
	_outcome = {}
	_watched = {}
	for n in names:
		_watched[n] = true


func _wait_outcome(timeout: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() / 1000.0 + timeout
	while _outcome.is_empty() and Time.get_ticks_msec() / 1000.0 < deadline:
		await process_frame
	return _outcome if not _outcome.is_empty() else {"name": "timeout", "args": []}


func _outcome_message(out: Dictionary) -> String:
	var args: Array = out.get("args", [])
	if args.size() > 1:
		return str(args[1])
	if args.size() > 0:
		return str(args[0])
	return ""


# --- arg parsing + settings ---


func _parse_args() -> void:
	var raw := OS.get_cmdline_user_args()
	_args = {}
	var i := 0
	while i < raw.size():
		var a := str(raw[i])
		if not a.begins_with("--"):
			i += 1
			continue
		var key := a.trim_prefix("--")
		var value := ""
		if key.contains("="):
			value = key.get_slice("=", 1)
			key = key.get_slice("=", 0)
		elif i + 1 < raw.size() and not str(raw[i + 1]).begins_with("--"):
			value = str(raw[i + 1])
			i += 1
		_args[key] = value
		i += 1


func _opt(key: String, default: String) -> String:
	return str(_args.get(key, default))


func _flag(key: String) -> bool:
	if not _args.has(key):
		return false
	var v := str(_args[key]).strip_edges().to_lower()
	return v.is_empty() or v == "true" or v == "1"


func _configure_settings() -> void:
	# ProjectSettings is the fallback store headless (_get_es() → null outside
	# the editor), so these land in the exact path _get_obs_settings() reads.
	ProjectSettings.set_setting("gd_time_machine/obs/host", _opt("host", "127.0.0.1"))
	ProjectSettings.set_setting("gd_time_machine/obs/port", int(_opt("port", "4455")))
	ProjectSettings.set_setting("gd_time_machine/obs/password", _opt("password", ""))
	ProjectSettings.set_setting("gd_time_machine/obs/auto_launch", _flag("launch"))
	ProjectSettings.set_setting("gd_time_machine/obs/binary_path", _opt("binary", ""))
