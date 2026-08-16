@tool
extends RecorderBackend
class_name BackendOBS

## IN_PLACE backend that records via OBS Studio over obs-websocket 5.x.
##
## State machine: idle → start() → [pending-start] → recording → stopped.
## All stop paths converge on _finalize_stopped() (single recording_stopped
## emission). IN_PLACE: the game is never killed or gracefully quit.
##
## Availability: is_available() = last WebSocket probe result (cached, never
## binary presence); is_obs_installed() = OBS binary resolved exactly once.
## A fresh probe runs in the editor on a 5 s TTL; a stale cache is re-probed
## on demand from is_obs_running().
##
## Startup semantics: pending-start polls _is_playing_scene() (not
## GetRecordStatus), and StartRecord is confirmed by its own response — OBS
## status 500 "already recording" counts as success. start() gates on
## is_obs_installed() with install instructions before launching/connecting.

## Emitted when a probe result flips the is_available() cache.
signal availability_changed(available: bool)

## Injected EditorSettings; when null, falls back to the EditorInterface
## singleton in tool context (GUT injects a fake store).
## Engine.has_singleton("EditorSettings") is FALSE even in the 4.7 editor, so
## the settings store must be reached via EditorInterface.get_editor_settings()
## — the wrong access path silently never reaches the stored password.
var _editor_settings: Object = null

const DEFAULT_OUTPUT_PATH := "res://media/captures/obs"
const POLL_INTERVAL := 0.5
const AVAILABILITY_TTL := 5.0
const PROBE_TIMEOUT := 1.5
const CONNECT_TIMEOUT := 3.0
const LAUNCH_WAIT_TIMEOUT := 10.0
const LAUNCH_POLL_INTERVAL := 0.5

var _active := false
var _pending_start := false
var _stopping := false

var _output_path := ""
var _final_output_path := ""
var _intermediate_path := ""
var _actual_obs_output := ""
var _duration := 0.0
var _target_fps := 0
var _target_output_format := ""
var _scene_path := ""
var _output_dir := ""

var _obs_client: OBSClient = null

var _available := false
var _last_probe_time := -1000.0
var _probe_in_flight := false

## Last connect-failure message from a probe or _await_auth(). Surfaced in
## start()'s error so an auth mismatch (close code 4009) isn't hidden behind
## the generic install/WebSocket hint.
var _last_connect_error := ""

var _we_launched := false
var _launched_pid := 0
var _obs_binary_cached: String = ""
# True once _obs_binary_cached holds the result of _resolve_obs_binary().
# A String cache slot starts as "" (never null), so a `== null` lazy-init guard
# can't distinguish "unresolved" from "resolved empty" — the flag can.
var _obs_binary_resolved := false

var _poll_timer: Timer
var _duration_timer: Timer

var _pending_request_id := ""
var _pending_request_kind := ""


func get_backend_name() -> String:
	return "OBS Studio"


func get_description() -> String:
	return (
		"Records the running scene via OBS Studio (WebSocket). Full fps with "
		+ "audio when OBS is configured; no scene restart. IN_PLACE — the game "
		+ "keeps running and is never killed on Stop."
	)


func get_capture_mode() -> CaptureMode:
	return CaptureMode.IN_PLACE


func is_recording() -> bool:
	return _active


func get_native_formats() -> Array:
	# Records MP4 natively; other formats are handled via ffmpeg elsewhere.
	return [GdTMOutputFormat.Format.MP4]


## WebSocket-reachable cache, never binary presence. Refresh happens on the
## editor's AVAILABILITY_TTL cycle or on demand from is_obs_running().
func is_available() -> bool:
	return _available


## True only when a WebSocket probe has succeeded recently. Forces a fresh
## probe when the cache is stale, then reports the last known result — the
## gate ensure_obs_running()/start() use (reachability, not install status).
func is_obs_running() -> bool:
	if _now() - _last_probe_time >= AVAILABILITY_TTL and not _probe_in_flight:
		probe_obs_async()
	return _available


## Installed means the OBS binary resolved (or binary_path override) — used
## for install hints and launch eligibility, never as "reachable".
func is_obs_installed() -> bool:
	return not _resolve_and_cache_binary().is_empty()


## Resolves the OBS binary exactly once and caches it. Both the install gate
## and launch share this single resolve — see the _obs_binary_resolved flag.
func _resolve_and_cache_binary() -> String:
	if not _obs_binary_resolved:
		_obs_binary_cached = _resolve_obs_binary()
		_obs_binary_resolved = true
	return _obs_binary_cached


func _ready() -> void:
	_probe_in_flight = false
	_last_probe_time = -1000.0
	# Editor-only availability wiring: seed the cache one frame after the pane
	# loads, then refresh every AVAILABILITY_TTL while idle. Gated so headless
	# GUT (Engine.is_editor_hint() == false) never opens a real WebSocket.
	if not Engine.is_editor_hint():
		return
	if not is_inside_tree():
		return
	get_tree().process_frame.connect(func() -> void: probe_obs_async(), CONNECT_ONE_SHOT)
	var t := Timer.new()
	t.name = "AvailabilityPoll"
	t.wait_time = AVAILABILITY_TTL
	t.one_shot = false
	t.autostart = true
	t.timeout.connect(
		func() -> void:
			if not _active and not _probe_in_flight:
				probe_obs_async()
	)
	add_child(t)


## Fire-and-forget probe; the result lands in _available via connection
## callbacks (never awaits — is_available() is synchronous).
func probe_obs_async() -> void:
	if _probe_in_flight:
		return
	_probe_in_flight = true
	var settings := _get_obs_settings()
	var host: String = str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port: int = int(settings.get("port", OBSClient.DEFAULT_PORT))
	var password: String = str(settings.get("password", ""))
	var client := _create_obs_client()
	if not is_inside_tree():
		_probe_in_flight = false
		_last_probe_time = _now()
		client.queue_free()
		return
	add_child(client)
	var finished := false
	var tout := Timer.new()
	tout.one_shot = true
	tout.wait_time = PROBE_TIMEOUT
	var on_done := func(ok: bool) -> void:
		if finished:
			return
		finished = true
		if tout.is_inside_tree():
			tout.stop()
			tout.queue_free()
		_probe_in_flight = false
		_last_probe_time = _now()
		_available = ok
		availability_changed.emit(ok)
		if client.is_inside_tree():
			client.get_parent().remove_child(client)
		client.queue_free()
	var on_auth := func() -> void: on_done.call(true)
	var on_fail := func(message: String) -> void:
		_last_connect_error = message
		on_done.call(false)
	client.connection_authenticated.connect(on_auth, CONNECT_ONE_SHOT)
	client.connection_failed.connect(on_fail, CONNECT_ONE_SHOT)
	tout.timeout.connect(func() -> void: on_done.call(false))
	add_child(tout)
	tout.start()
	var err := client.connect_to_obs(host, port, password)
	if err != OK:
		push_warning("OBS probe connect_to_obs returned error: %s" % error_string(err))
		on_done.call(false)


## Waits up to timeout for the client to reach READY, capturing any
## connection_failed message into _last_connect_error.
func _await_auth(client: OBSClient, timeout: float) -> bool:
	if client.is_connected_to_obs():
		return true
	var deadline := _now() + timeout
	var done := false
	var ok := false
	var on_auth := func() -> void:
		ok = true
		done = true
	var on_fail := func(message: String) -> void:
		_last_connect_error = message
		done = true
	client.connection_authenticated.connect(on_auth, CONNECT_ONE_SHOT)
	client.connection_failed.connect(on_fail, CONNECT_ONE_SHOT)
	while not done and _now() < deadline:
		if client.is_connected_to_obs():
			ok = true
			done = true
			break
		if client.get_state() == OBSClient.State.DISCONNECTED:
			done = true
			break
		await _sleep(0.05)
	if client.connection_authenticated.is_connected(on_auth):
		client.connection_authenticated.disconnect(on_auth)
	if client.connection_failed.is_connected(on_fail):
		client.connection_failed.disconnect(on_fail)
	return ok


## Ensures OBS is running and reachable, launching it (auto_launch) if not.
## Gates on is_obs_running() (reachability), never on install status. Launched
## processes are owned via _we_launched/_launched_pid; a pre-existing OBS is
## never killed. Narrates the launch/wait flow via recording_notice so the
## plugin's [GdTM] terminal log and the dock status line show what is happening
## while the user waits (OBS itself may open minimized to the tray).
func ensure_obs_running() -> bool:
	if is_obs_running():
		_we_launched = false
		return true
	var settings := _get_obs_settings()
	if not bool(settings.get("auto_launch", true)):
		return false
	var binary := _resolve_obs_binary()
	if binary.is_empty():
		return false
	(
		recording_notice
		. emit(
			get_backend_name(),
			(
				"OBS Studio isn't reachable — launching it now (auto_launch). "
				+ "It may start minimized to the tray."
			),
		)
	)
	var pid := _launch_obs_process(binary)
	if pid <= 0:
		return false
	_launched_pid = pid
	_we_launched = true
	recording_notice.emit(
		get_backend_name(), "Launched OBS Studio (pid %d) — waiting for the WebSocket server…" % pid
	)
	var deadline := _now() + LAUNCH_WAIT_TIMEOUT
	while _now() < deadline:
		var ok := await _probe_once()
		_last_probe_time = _now()
		_available = ok
		if ok:
			availability_changed.emit(true)
			recording_notice.emit(get_backend_name(), "OBS Studio is reachable.")
			return true
		await _sleep(LAUNCH_POLL_INTERVAL)
	_kill_process(_launched_pid)
	_we_launched = false
	_launched_pid = 0
	return false


## One-shot reachability probe on the settings target. Used by
## ensure_obs_running()'s launch loop (fresh probe each iteration).
func _probe_once() -> bool:
	var settings := _get_obs_settings()
	var host: String = str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port: int = int(settings.get("port", OBSClient.DEFAULT_PORT))
	var password: String = str(settings.get("password", ""))
	var client := _create_obs_client()
	if not is_inside_tree():
		client.queue_free()
		return false
	add_child(client)
	var err := client.connect_to_obs(host, port, password)
	if err != OK:
		if client.is_inside_tree():
			client.get_parent().remove_child(client)
		client.queue_free()
		return false
	var ok := await _await_auth(client, PROBE_TIMEOUT)
	if client.is_inside_tree():
		client.get_parent().remove_child(client)
	client.queue_free()
	return ok


func start(config: Dictionary) -> void:
	if _active:
		push_warning("Backend '%s' is already recording" % get_backend_name())
		return
	_output_path = str(config.get("output_path", ""))
	if _output_path.is_empty():
		_output_path = DEFAULT_OUTPUT_PATH
	_duration = float(config.get("duration", 0.0))
	_target_fps = int(config.get("fps", 0))
	_target_output_format = str(config.get("output_format", "mp4")).to_lower()
	_scene_path = str(config.get("scene_path", ""))
	_output_dir = str(config.get("output_dir", ""))
	if _output_dir.is_empty():
		_output_dir = _output_path.get_base_dir()
	# OBS records MP4 natively; anything else is rejected here.
	if GdTMOutputFormat.from_string(_target_output_format) != GdTMOutputFormat.Format.MP4:
		(
			recording_error
			. emit(
				get_backend_name(),
				"OBS records MP4 natively; format '%s' is not available" % _target_output_format,
			)
		)
		return
	var ext := GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.MP4)
	_final_output_path = "%s.%s" % [_output_path, ext]
	_intermediate_path = _final_output_path
	_actual_obs_output = ""
	_active = true
	_stopping = false
	_pending_start = false

	# Distinct, actionable "not installed" error before any launch attempt.
	if not is_obs_installed():
		_active = false
		(
			recording_error
			. emit(
				get_backend_name(),
				(
					"OBS Studio not found. Please install OBS Studio and enable the "
					+ "WebSocket server (Tools → WebSocket Server Settings → Enable "
					+ "WebSocket Server, default port 4455)."
				),
			)
		)
		return

	# Ensure OBS is running (auto-launch if needed); unreachable → error.
	if not is_obs_running():
		var ok := await ensure_obs_running()
		if not ok:
			_active = false
			recording_error.emit(get_backend_name(), _describe_start_error())
			return

	# Pending-start: launch the scene, poll _is_playing_scene(), then record.
	if not _is_playing_scene():
		_pending_start = true
		if _duration > 0.0:
			_start_duration_timer()
		_start_polling()
		_play_scene(_scene_path)
		return
	_begin_recording()


## Composes the error message for start()'s ensure_obs_running() failure path.
## Surfaces the last connect-failure message (e.g. an OBS auth rejection) when
## one was captured, and appends actionable password guidance when the failure
## was an authentication mismatch instead of the generic install/WebSocket hint.
func _describe_start_error() -> String:
	var connect_msg := "Could not start OBS or connect to WebSocket."
	if not _last_connect_error.is_empty():
		connect_msg += " %s" % _last_connect_error
	if _last_connect_error.contains("Authentication failed"):
		connect_msg += " Set the matching password in Project > Editor Settings → gd_time_machine/obs/password, or clear the password in OBS → Tools → WebSocket Server Settings."
	else:
		connect_msg += " Check that OBS is installed and WebSocket is enabled on port 4455."
	return connect_msg


func _begin_recording() -> void:
	_pending_start = false
	_stop_polling()
	var client := _ensure_obs_client()
	if client == null or not client.is_connected_to_obs():
		var ok := await _connect_obs_with_timeout()
		if not ok:
			_active = false
			(
				recording_error
				. emit(
					get_backend_name(),
					"Could not connect to OBS WebSocket — check host/port/password in Editor Settings.",
				)
			)
			return
		client = _obs_client
	_switch_scene_if_needed()
	_send_start_record()


func _connect_obs_with_timeout() -> bool:
	var client := _ensure_obs_client()
	if client == null:
		return false
	if client.is_connected_to_obs():
		return true
	var settings := _get_obs_settings()
	var err := client.connect_to_obs(
		str(settings.get("host", OBSClient.DEFAULT_HOST)),
		int(settings.get("port", OBSClient.DEFAULT_PORT)),
		str(settings.get("password", ""))
	)
	if err != OK:
		return false
	return await _await_auth(client, CONNECT_TIMEOUT)


func _switch_scene_if_needed() -> void:
	if _obs_client == null or not _obs_client.is_connected_to_obs():
		return
	var settings := _get_obs_settings()
	var target := str(settings.get("scene", "")).strip_edges()
	if target.is_empty():
		return
	_obs_client.send_request("SetCurrentProgramScene", {"sceneName": target})


func _send_start_record() -> void:
	if _obs_client == null:
		_active = false
		recording_error.emit(get_backend_name(), "OBS client not available")
		return
	_pending_request_kind = "start"
	_pending_request_id = _obs_client.send_request("StartRecord", {})
	if _pending_request_id.is_empty():
		_active = false
		recording_error.emit(get_backend_name(), "Failed to send StartRecord to OBS")
		return
	# response handled in _on_request_completed; if no response, duration/poll covers it


func _on_request_completed(
	request_id: String, result: bool, code: int, response_data: Dictionary
) -> void:
	if request_id != _pending_request_id:
		return
	var kind := _pending_request_kind
	_pending_request_id = ""
	_pending_request_kind = ""
	match kind:
		"start":
			if result or code == OBSClient.STATUS_OUTPUT_RUNNING:
				if _duration > 0.0:
					_start_duration_timer()
				recording_started.emit(get_backend_name(), _final_output_path)
			else:
				_active = false
				_pending_start = false
				_stop_polling()
				_stop_duration_timer()
				recording_error.emit(
					get_backend_name(), "OBS could not start recording (code %d)" % code
				)
		"stop":
			if result:
				_actual_obs_output = str(response_data.get("outputPath", ""))
			_resolve_and_move_output()
			_finalize_stopped()


func stop() -> void:
	if not _active:
		return
	if _stopping:
		return
	if _pending_start:
		_pending_start = false
		_active = false
		_stop_polling()
		_stop_duration_timer()
		recording_stopped.emit(get_backend_name(), _final_output_path)
		return
	_stopping = true
	_stop_duration_timer()
	if _obs_client != null and _obs_client.is_connected_to_obs():
		_pending_request_kind = "stop"
		_pending_request_id = _obs_client.send_request("StopRecord", {})
		# _on_request_completed will finalize; also arm a fallback timer so a
		# dropped response never leaves the backend stuck recording.
		var t := Timer.new()
		t.one_shot = true
		t.wait_time = 3.0
		t.timeout.connect(
			func() -> void:
				if _stopping:
					_resolve_and_move_output()
					_finalize_stopped()
				if t.is_inside_tree():
					t.queue_free()
		)
		add_child(t)
		t.start()
	else:
		_finalize_stopped()


## StopRecord outputPath (file name or full path, per OBS version) → the dock's
## output_dir. Falls back to scanning _output_dir/output_path base when OBS
## returns a bare file name (move-after-stop only).
func _resolve_and_move_output() -> void:
	var src := _resolve_actual_output_path()
	if src.is_empty():
		return
	var dst := _intermediate_path
	if src == dst or ProjectSettings.globalize_path(src) == ProjectSettings.globalize_path(dst):
		return
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dst)
	)
	if err != OK:
		push_warning("BackendOBS: could not move %s -> %s (%s)" % [src, dst, error_string(err)])


func _resolve_actual_output_path() -> String:
	if _actual_obs_output.is_empty():
		return ""
	if FileAccess.file_exists(_actual_obs_output):
		return _actual_obs_output
	var abs1 := ProjectSettings.globalize_path(_actual_obs_output)
	if FileAccess.file_exists(abs1):
		return abs1
	for dir in [_output_dir, _output_path.get_base_dir()]:
		if dir.is_empty():
			continue
		var cand := str(dir).path_join(_actual_obs_output.get_file())
		if FileAccess.file_exists(cand):
			return cand
		var cand_abs := ProjectSettings.globalize_path(cand)
		if FileAccess.file_exists(cand_abs):
			return cand_abs
	return _actual_obs_output


func _finalize_stopped() -> void:
	if not _active and not _stopping:
		return
	_active = false
	_pending_start = false
	_stopping = false
	_pending_request_id = ""
	_pending_request_kind = ""
	_stop_polling()
	_stop_duration_timer()
	recording_stopped.emit(get_backend_name(), _final_output_path)


func _on_poll_timeout() -> void:
	if not _active or _stopping:
		return
	if _pending_start and _is_playing_scene():
		_begin_recording()


func _on_duration_timeout() -> void:
	if not _active:
		return
	if _stopping:
		return
	if _pending_start:
		_pending_start = false
		_active = false
		_stop_polling()
		_stop_duration_timer()
		recording_error.emit(
			get_backend_name(), "Scene did not start playing before the duration elapsed"
		)
		return
	stop()


func _get_auto_close_setting() -> bool:
	# _exit_tree does a best-effort kill of a launched OBS only. The setting is
	# read EditorSettings-first via _read_setting, never through a dead
	# Engine.has_singleton("EditorSettings") branch (see _editor_settings).
	var v := _read_setting("gd_time_machine/obs/auto_close")
	return bool(v) if v != null else true


# --- settings plumbing ---


## Returns the settings store to read, or null when running outside the editor
## (headless GUT) and no fake was injected.
func _get_es() -> Object:
	if _editor_settings != null:
		return _editor_settings
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return null


## The single source of OBS connection settings. EditorSettings wins over
## ProjectSettings (Editor Settings > project.godot copy); empty password means
## "server auth disabled" and must be sent as NO authentication field.
func _get_obs_settings() -> Dictionary:
	return {
		"host": _get_setting_string("gd_time_machine/obs/host", OBSClient.DEFAULT_HOST),
		"port": _get_setting_int("gd_time_machine/obs/port", OBSClient.DEFAULT_PORT),
		"password": _get_setting_string("gd_time_machine/obs/password", ""),
		"scene": _get_setting_string("gd_time_machine/obs/scene", ""),
		"auto_launch": _get_setting_bool("gd_time_machine/obs/auto_launch", true),
		"auto_close": _get_setting_bool("gd_time_machine/obs/auto_close", true),
		"binary_path": _get_setting_string("gd_time_machine/obs/binary_path", ""),
	}


## First non-null value across EditorSettings → ProjectSettings → default.
func _read_setting(key: String) -> Variant:
	var es := _get_es()
	if es != null and es.has_method("get_setting"):
		var v: Variant = es.get_setting(key)
		if v != null:
			return v
	if ProjectSettings.has_setting(key):
		return ProjectSettings.get_setting(key)
	return null


func _get_setting_string(key: String, default: String) -> String:
	var v := _read_setting(key)
	return str(v) if v != null else default


func _get_setting_int(key: String, default: int) -> int:
	var v := _read_setting(key)
	return int(v) if v != null else default


func _get_setting_bool(key: String, default: bool) -> bool:
	var v := _read_setting(key)
	return bool(v) if v != null else default


# --- environment seams ---


func _is_playing_scene() -> bool:
	return EditorInterface.is_playing_scene()


func _play_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_custom_scene(scene_path)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _sleep(seconds: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	await tree.create_timer(seconds).timeout


func _create_obs_client() -> OBSClient:
	return OBSClient.new()


func _ensure_obs_client() -> OBSClient:
	if _obs_client != null and is_inside_tree() and _obs_client.is_inside_tree():
		return _obs_client
	if _obs_client != null:
		_release_obs_client()
	_obs_client = _create_obs_client()
	_obs_client.request_completed.connect(_on_request_completed)
	if is_inside_tree():
		add_child(_obs_client)
	return _obs_client


func _release_obs_client() -> void:
	if _obs_client == null:
		return
	if _obs_client.request_completed.is_connected(_on_request_completed):
		_obs_client.request_completed.disconnect(_on_request_completed)
	if _obs_client.is_inside_tree():
		_obs_client.get_parent().remove_child(_obs_client)
	_obs_client.queue_free()
	_obs_client = null


func _resolve_obs_binary() -> String:
	var settings := _get_obs_settings()
	var custom := str(settings.get("binary_path", "")).strip_edges()
	if not custom.is_empty() and FileAccess.file_exists(custom):
		return custom
	var os_name := OS.get_name()
	var candidates: Array = []
	match os_name:
		"Windows":
			candidates = [
				"C:/Program Files/obs-studio/bin/64bit/obs64.exe",
				"C:/Program Files (x86)/obs-studio/bin/64bit/obs64.exe",
			]
		"macOS":
			candidates = ["/Applications/OBS.app/Contents/MacOS/obs"]
		_:
			candidates = [
				"/usr/bin/obs",
				"/usr/local/bin/obs",
				"/snap/bin/obs-studio",
			]
	for c in candidates:
		if FileAccess.file_exists(str(c)):
			return str(c)
	# PATH lookup (seam _os_execute keeps OS.execute stubbable in GUT).
	var which := "where" if os_name == "Windows" else "which"
	var bin_name := "obs64.exe" if os_name == "Windows" else "obs"
	var out: Array = []
	var code := _os_execute(which, PackedStringArray([bin_name]), out)
	if code == 0 and not out.is_empty():
		var found := str(out[0]).strip_edges()
		if not found.is_empty() and FileAccess.file_exists(found):
			return found
	return ""


func _launch_obs_process(binary: String) -> int:
	return OS.create_process(binary, ["--minimize-to-tray"])


func _kill_process(pid: int) -> void:
	if pid > 0:
		OS.kill(pid)


func _os_execute(binary: String, args: PackedStringArray, out: Array) -> int:
	return OS.execute(binary, args, out, true)


func _ensure_timers() -> void:
	if _poll_timer == null and is_inside_tree():
		_poll_timer = Timer.new()
		_poll_timer.wait_time = POLL_INTERVAL
		_poll_timer.one_shot = false
		_poll_timer.autostart = false
		_poll_timer.timeout.connect(_on_poll_timeout)
		add_child(_poll_timer)
	if _duration_timer == null and is_inside_tree():
		_duration_timer = Timer.new()
		_duration_timer.one_shot = true
		_duration_timer.autostart = false
		_duration_timer.timeout.connect(_on_duration_timeout)
		add_child(_duration_timer)


func _start_polling() -> void:
	_ensure_timers()
	if _poll_timer:
		_poll_timer.start(POLL_INTERVAL)


func _stop_polling() -> void:
	if _poll_timer:
		_poll_timer.stop()


func _start_duration_timer() -> void:
	_ensure_timers()
	if _duration_timer:
		_duration_timer.start(_duration)


func _stop_duration_timer() -> void:
	if _duration_timer:
		_duration_timer.stop()


func _exit_tree() -> void:
	_stop_polling()
	_stop_duration_timer()
	var launched_pid := _launched_pid
	if _we_launched and _get_auto_close_setting():
		_kill_process(launched_pid)
		# Direct print, not a recording_notice: by the time _exit_tree runs the
		# plugin has already disconnected its [GdTM] feedback handlers
		# (plugin._exit_tree → _disconnect_controller_feedback), so a notice
		# would be silently lost. This line is the auto_close bookend to the
		# launch narration in ensure_obs_running().
		print(
			(
				"[GdTM] %s: closed — auto_close stopped the OBS instance we launched (pid %d)"
				% [get_backend_name(), launched_pid]
			)
		)
		_we_launched = false
		_launched_pid = 0
	_release_obs_client()
