@tool
extends RecorderBackend
class_name BackendOBS

## IN_PLACE backend that records via OBS Studio over obs-websocket 5.x.
##
## State machine: idle → start() → [pending-start] → recording → stopped.
## All stop paths converge on _finalize_stopped() (single recording_stopped
## emission). IN_PLACE: the game is never killed or gracefully quit.
##
## Availability (two layers, common interface with ffmpeg formats):
## is_available() = installed/launchable (binary resolved) — the dropdown's
## disabled gate. Reachability (WebSocket probe cache _available) is NOT
## availability: installed-but-idle stays selectable and auto-launches on
## Record. Use is_obs_running() for reachability and get_runtime_hint() for
## the "will auto-launch" tooltip. A fresh reachability probe runs in the
## editor on a 5 s TTL; a stale cache is re-probed on demand from
## is_obs_running().
##
## Startup semantics: pending-start polls _is_playing_scene() (not
## GetRecordStatus), and StartRecord is confirmed by its own response — OBS
## status 500 "already recording" counts as success. start() gates on
## is_obs_installed() with install instructions before launching/connecting.

## Emitted when the reachability probe flips (payload = reachable, not
## selectable). The dock recomputes disabled state from is_available()
## (installed) on every emission, so live tooltip updates keep working while
## the disabled gate stays install-based.
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
## Per-request timeout for the empty-scene preflight in _begin_recording().
const SCENE_CHECK_TIMEOUT := 2.0
## Settle delay after RemoveInput before CreateInput re-uses the name
## (seconds). OBS processes input teardown asynchronously AFTER replying:
## re-creating in the same tick fails 601 (name still registered) or binds
## source-less (black recording — reproduced live Sep 2026: stale-PipeWire
## RemoveInput → immediate CreateInput → 601/black; settled re-create →
## live pixels). Only the cross-kind replacement path sleeps; the steady
## path (reuse/SetInputSettings, healthy placement kept) sleeps nothing.
## Wall clock via _sleep (real delay even when tests freeze _now()).
const SETTLE_DELAY := 1.5


## Seam for the settle grace above: tests return 0 so the ordering
## assertions run without the wall-clock wait.
func _get_settle_delay() -> float:
	return SETTLE_DELAY


## Scene owned by this backend for window capture. Only this scene is ever
## cleared/rebuilt; a user-configured obs/scene is managed gently (our input
## ensured, everything else left alone).
const AUTO_SETUP_SCENE_NAME := "GdTimeMachine"
## Capture source name for the game window.
const AUTO_SETUP_INPUT_NAME := "GdTimeMachine Capture"
## Programmatic per-window capture, per OS. Linux xcomposite matches the game
## by window id (validated live: SetInputSettings capture_window, no dialog).
## Windows window_capture matches "[exe]: title" (best-effort, unvalidated —
## no Windows host here; exact-title risk documented at the builder).
const XCOMPOSITE_KIND := "xcomposite_input"
const WINDOW_CAPTURE_KIND := "window_capture"
## PipeWire portal capture (fallback tier only). First human pick is
## mandatory and the share is opaque — hence fallback, never default.
const PIPEWIRE_CAPTURE_KIND := "pipewire-screen-capture-source"
## Bounds the game-identity round-trip over the debugger channel (seconds).
## Wall clock (not _now(), which tests freeze).
const IDENTITY_TIMEOUT := 3.0
## How long the PipeWire fallback waits for the human to complete the portal
## share-picker (seconds). Overridable via _get_setup_wait_timeout().
const SETUP_WAIT_TIMEOUT := 120.0
## Poll interval while waiting for the portal pick (seconds).
const SETUP_WAIT_POLL := 1.0
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

## Whether to auto-convert MP4 → tier-2 targets via the matched transcoder
## when requested.
var _auto_convert_enabled := true

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
# True once _obs_binary_cached holds a non-empty resolve. Empty results are
# retried on the next check so a mid-session install is detected.
var _obs_binary_resolved := false

var _poll_timer: Timer
var _duration_timer: Timer

var _pending_request_id := ""
var _pending_request_kind := ""

## Injected by plugin.gd; carries the game-window-identity round-trip used
## to target the exact game window. Null in bare unit tests (identity then
## reports unavailable and the PipeWire fallback path is taken).
var _debugger_plugin: Object = null

## Monotonic id for game-identity requests; replies echo it back.
var _next_win_rq_id := 0


## OS name seam: Linux/Windows carry programmatic window capture; tests pin
## other values to exercise the unsupported-platform gate.
func _get_os_name() -> String:
	return OS.get_name()


func get_backend_name() -> String:
	return "OBS Studio"


func get_description() -> String:
	return (
		"Records the running scene via OBS Studio (WebSocket). Full fps with "
		+ "audio when OBS is configured; no scene restart. MP4 natively, "
		+ "WEBM/AVI/OGV via ffmpeg post-convert. IN_PLACE — the game "
		+ "keeps running and is never killed on Stop."
	)


func get_capture_mode() -> CaptureMode:
	return CaptureMode.IN_PLACE


func is_recording() -> bool:
	return _active


func get_native_formats() -> Array:
	# OBS itself records MP4 (its other native containers — MKV/MOV/TS — are
	# outside our format enum). Anything else our file converter can write
	# (WEBM/AVI/OGV) is offered as a post-stop transcode — same pattern as
	# Movie Maker's AVI → MP4 — with honest "- ffmpeg" labeling, no taste
	# policing. Stills sequences stay with the Screenshot backend (file →
	# frames extraction has no converter yet).
	return [GdTMOutputFormat.Format.MP4]


## Native artifact for transcoder matching: an MP4 file.
func get_native_artifact() -> Dictionary:
	return {"kind": "file", "format": GdTMOutputFormat.Format.MP4}


## Selectability gate (common RecorderBackend interface): Linux or Windows
## with OBS installed (start() auto-launches an idle OBS). Programmatic
## window capture only exists on those two; elsewhere the backend stays
## unselectable with the reason below. Reachability lives in
## is_obs_running(), never here.
func is_available() -> bool:
	return _get_os_name() in ["Linux", "Windows"] and is_obs_installed()


## Actionable install reason for the disabled tooltip/dialog ("" when
## available). Part of the common availability interface. Names the actual
## WebSocket target from settings, never a hardcoded "must be running".
func get_unavailable_reason() -> String:
	if _get_os_name() not in ["Linux", "Windows"]:
		return (
			"OBS window capture is supported on Linux and Windows only "
			+ "(this machine reports %s)." % _get_os_name()
		)
	if is_available():
		return ""
	var settings := _get_obs_settings()
	var host := str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port := int(settings.get("port", OBSClient.DEFAULT_PORT))
	return (
		(
			"OBS Studio not found (expected WebSocket target ws://%s:%d). Install OBS Studio, enable the WebSocket "
			% [host, port]
		)
		+ "server (Tools → WebSocket Server Settings → Enable WebSocket Server), "
		+ "and check gd_time_machine/obs/* (host/port/password) under Project > "
		+ "Editor Settings."
	)


## Transient hint when selectable but idle: installed but not reachable.
## "" when unavailable or already reachable — no tooltip noise then.
func get_runtime_hint() -> String:
	if not is_available():
		return ""
	if _available:
		return ""
	var settings := _get_obs_settings()
	var host := str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port := int(settings.get("port", OBSClient.DEFAULT_PORT))
	return (
		"OBS Studio is installed but not running (ws://%s:%d) — it will auto-launch on Record."
		% [host, port]
	)


## Install-hint card (see base): title, body naming the real WebSocket
## target, download URL, and the suppression flag key.
func get_install_hint() -> Dictionary:
	var settings := _get_obs_settings()
	var host := str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port := int(settings.get("port", OBSClient.DEFAULT_PORT))
	var target := "ws://%s:%d" % [host, port]
	return {
		"title": "OBS Studio not detected",
		"body":
		(
			(
				"OBS Studio was not found (expected WebSocket target %s).\n\n"
				+ "To record with OBS Studio:\n"
				+ "1. Install OBS Studio (obsproject.com — use the link below).\n"
				+ "2. Start OBS and enable the WebSocket server: Tools → WebSocket "
				+ "Server Settings → Enable WebSocket Server.\n"
				+ "3. If the server requires a password, set the same password under "
				+ "Project > Editor Settings → gd_time_machine/obs/password."
			)
			% target
		),
		"url": "https://obsproject.com",
		"suppress_key": "hints/dont_show_obs_hint",
	}


## True only when a WebSocket probe has succeeded recently. Forces a fresh
## probe when the cache is stale, then reports the last known result — the
## gate ensure_obs_running()/start() use (reachability, not install status).
func is_obs_running() -> bool:
	if _now() - _last_probe_time >= AVAILABILITY_TTL and not _probe_in_flight:
		probe_obs_async()
	return _available


## Installed means the OBS binary resolved (or binary_path override) — the
## selectability gate and launch eligibility, never "reachable".
func is_obs_installed() -> bool:
	return not _resolve_and_cache_binary().is_empty()


## Resolves the OBS binary and caches a non-empty result. An empty result is
## retried on the next call so a mid-session install is picked up without an
## editor restart; a found binary is resolved exactly once.
func _resolve_and_cache_binary() -> String:
	if not _obs_binary_cached.is_empty():
		return _obs_binary_cached
	_obs_binary_cached = _resolve_obs_binary()
	_obs_binary_resolved = not _obs_binary_cached.is_empty()
	return _obs_binary_cached


func _ready() -> void:
	_probe_in_flight = false
	_last_probe_time = -1000.0
	# Startup orphan sweep (D2): fire-and-forget so _ready never blocks, and
	# before the editor gate so the headless drive tool reaps leftovers too.
	# GUT fakes override _ready with pass, so the real sweep never runs in
	# tests (no user:// ledger access during a test run).
	_reap_orphaned_launches()
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
		# D4: narrate the reuse so a leftover OBS (reused instead of launched)
		# shows up in the terminal log and the dock status line.
		recording_notice.emit(get_backend_name(), "OBS Studio is already running — reusing it.")
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
	# D1: record ownership so a later session's orphan sweep can prove the
	# process is ours before ever killing it.
	_persist_launched_pid(pid, binary)
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
	# C2 escalation: TERM, then a short grace poll, then SIGKILL. The ledger is
	# cleared only when the process is confirmed gone.
	var confirmed := await _kill_process_and_wait(_launched_pid)
	if confirmed:
		_clear_launched_ledger()
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
	_auto_convert_enabled = _get_auto_convert_setting(config)
	_scene_path = str(config.get("scene_path", ""))
	_output_dir = str(config.get("output_dir", ""))
	if _output_dir.is_empty():
		_output_dir = _output_path.get_base_dir()
	var fmt := GdTMOutputFormat.from_string(_target_output_format)
	if not is_format_supported(fmt):
		(
			recording_error
			. emit(
				get_backend_name(),
				(
					"OBS records MP4 natively (WEBM/AVI/OGV via ffmpeg); format '%s' is not available"
					% _target_output_format
				),
			)
		)
		return
	# OBS always records an MP4 intermediate; tier-2 targets transcode after
	# stop (same pattern as Movie Maker's AVI intermediate). The dock passes a
	# bare base for IN_PLACE, but strip a stale video extension defensively so
	# CLI callers passing "clip.mp4" don't yield "clip.mp4.mp4".
	var base := _output_path
	var base_ext := base.get_extension().to_lower()
	if base_ext in ["mp4", "webm", "avi", "ogv"]:
		base = base.substr(0, base.length() - base_ext.length() - 1)
	_intermediate_path = (
		"%s.%s" % [base, GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.MP4)]
	)
	if fmt == GdTMOutputFormat.Format.MP4:
		_final_output_path = _intermediate_path
	else:
		_final_output_path = "%s.%s" % [base, GdTMOutputFormat.to_extension(fmt)]
	_output_path = base
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
	# Capture targeting, exactly two tiers and no chains: tier 1 assigns the
	# game window programmatically (xcomposite id on Linux, "[exe]: title" on
	# Windows — no picker, ever). Anything that makes tier 1 unavailable
	# (no game answer, wrong display server, kind missing) falls through ONCE
	# to the PipeWire tier below, which ends in StartRecord or its own error.
	var resolved := await _resolve_programmatic_spec()
	var spec: Dictionary = resolved.get("spec", {})
	if not spec.is_empty():
		if await _ensure_window_capture(client, spec):
			_send_start_record()
			return
		(
			recording_notice
			. emit(
				get_backend_name(),
				"OBS window capture could not be configured — trying PipeWire screen capture instead.",
			)
		)
		_pipewire_begin()
		return
	(
		recording_notice
		. emit(
			get_backend_name(),
			(
				"Programmatic window capture unavailable (%s) — falling back to PipeWire screen capture."
				% str(resolved.get("reason", "unknown cause"))
			),
		)
	)
	_pipewire_begin()


## Single-tier PipeWire fallback: the pre-existing empty-scene preflight +
## auto-setup + record chain, entered from exactly one place (above) and
## never re-entering programmatic code. Ends in StartRecord or error.
func _pipewire_begin() -> void:
	# Callers narrate the fallback with the specific reason; this function
	# stays silent and just runs the chain.
	# Preflight: an OBS scene with no enabled sources records a black video
	# of correct length that looks successful (confirmed Sep 2026: empty
	# "Scene" produced 1280×720 black MP4s). With auto-setup on (default),
	# build a dedicated scene + capture source instead of refusing; without
	# it (or when setup can't run), refuse fast with an actionable error
	# instead of a black file. Unknown/query-failed stays fail-open so
	# an older OBS never blocks a valid recording.
	var preflight := await _check_record_scene_ready()
	if not bool(preflight.get("ok", true)):
		if bool(preflight.get("setup_eligible", false)) and _get_auto_setup_setting():
			recording_notice.emit(
				get_backend_name(),
				(
					"OBS scene '%s' is empty — setting up a capture scene automatically…"
					% str(preflight.get("scene", "current"))
				)
			)
			var setup := await _auto_setup_record_scene()
			if bool(setup.get("ok", false)):
				# Setup already set the program scene to the new record
				# scene (and remembered it) — go straight to StartRecord.
				_send_start_record()
				return
			_fail_begin(str(setup.get("message", preflight.get("message", ""))))
			return
		_fail_begin(str(preflight.get("message", "")))
		return
	_switch_scene_if_needed()
	_send_start_record()


## Terminal failure for _begin_recording/_pipewire_begin: clears session
## state and emits exactly one recording_error. The single funnel keeps the
## two tiers from ever double-emitting or leaving a half-open session.
func _fail_begin(message: String) -> void:
	_active = false
	_pending_start = false
	_stop_polling()
	_stop_duration_timer()
	recording_error.emit(get_backend_name(), message)


## Asks the running game for its OS window identity over the debugger
## channel: {ok, handle, display, exe, title, debug}. handle is the X11 xid
## (0 when the display server exposes none); display e.g. "X11"/"Windows";
## exe the binary file name; title the project name; debug whether the game
## runs a debug build (its OS title gains a " (DEBUG)" suffix then — the
## exact title is NOT queryable, so Windows matching accounts for it).
## Overridable seam: the RecordingBackend double answers canned identities.
func _request_game_window_identity() -> Dictionary:
	var failed := {"ok": false, "handle": 0, "display": "", "exe": "", "title": "", "debug": 0}
	if _debugger_plugin == null or not _debugger_plugin.has_method("send_window_handle_request"):
		return failed
	_next_win_rq_id += 1
	var rq_id := _next_win_rq_id
	var box := {"done": false, "handle": 0, "display": "", "exe": "", "title": "", "debug": 0}
	var on_reply := func(
		id: int, handle: int, display: String, exe: String, title: String, debug: int
	) -> void:
		if id != rq_id:
			return
		box["done"] = true
		box["handle"] = handle
		box["display"] = display
		box["exe"] = exe
		box["title"] = title
		box["debug"] = debug
	_debugger_plugin.connect("window_handle_received", on_reply)
	var sent: bool = _debugger_plugin.send_window_handle_request(rq_id)
	if not sent:
		if _debugger_plugin.is_connected("window_handle_received", on_reply):
			_debugger_plugin.disconnect("window_handle_received", on_reply)
		return failed
	var deadline := Time.get_ticks_msec() / 1000.0 + IDENTITY_TIMEOUT
	while not bool(box["done"]) and Time.get_ticks_msec() / 1000.0 < deadline:
		await _sleep(0.05)
	if _debugger_plugin.is_connected("window_handle_received", on_reply):
		_debugger_plugin.disconnect("window_handle_received", on_reply)
	if not bool(box["done"]):
		return failed
	return {
		"ok": true,
		"handle": int(box["handle"]),
		"display": str(box["display"]),
		"exe": str(box["exe"]),
		"title": str(box["title"]),
		"debug": int(box["debug"]),
	}


## Builds the Windows window_capture selector: "[exe]: title" (OBS format).
## The engine suffixes debug-run titles with " (DEBUG)", which live queries
## can't see — the game reports its debug flag so the suffix is applied only
## then. UNVALIDATED (no Windows host here); pure for easy testing. ""
## when unusable.
static func _build_windows_capture_window(identity: Dictionary) -> String:
	var exe := str(identity.get("exe", "")).strip_edges()
	var title := str(identity.get("title", "")).strip_edges()
	if exe.is_empty() or title.is_empty():
		return ""
	if bool(identity.get("debug", false)):
		title += " (DEBUG)"
	return "[%s]: %s" % [exe, title]


## Resolves the programmatic capture spec for this record:
## {"spec": {...}} on success, {"spec": {}, "reason": "..."} when the tier is
## unavailable (→ PipeWire fallback). The reason names the exact failed gate
## so the fallback notice tells the user what to fix (this confusion bit us:
## a native-Wayland OBS was reused, kinds gate, with no word on why).
## Requires BOTH a complete game identity AND the platform kind registered in
## OBS; anything less is not a partial record, it's the fallback. Takes an
## optional open client for the kinds query so callers that already hold one
## (run_setup_now) don't open a second; otherwise opens/closes its own
## transient. Never touches the record client's StartRecord bookkeeping.
func _resolve_programmatic_spec(client: OBSClient = null) -> Dictionary:
	var identity := await _request_game_window_identity()
	if not bool(identity.get("ok", false)):
		return {"spec": {}, "reason": "no game window answer (is the game running?)"}
	var own_client := false
	if client == null:
		client = await _open_transient_client()
		own_client = true
	if client == null:
		return {"spec": {}, "reason": "OBS query client could not connect"}
	var kinds := await _obs_request_await_on(
		client, "GetInputKindList", {"unversioned": true}, SCENE_CHECK_TIMEOUT
	)
	if own_client:
		_close_transient_client(client)
	if not bool(kinds.get("ok", false)) or not bool(kinds.get("result", false)):
		return {"spec": {}, "reason": "OBS would not list its capture kinds"}
	var available: Array = Dictionary(kinds.get("data", {})).get("inputKinds", [])
	if _get_os_name() == "Linux":
		if str(identity.get("display", "")) != "X11":
			return {
				"spec": {},
				"reason":
				"game runs on %s, not X11" % str(identity.get("display", "an unknown display")),
			}
		if int(identity.get("handle", 0)) <= 0:
			return {"spec": {}, "reason": "game window has no OS handle"}
		if available.has(XCOMPOSITE_KIND):
			var handle := int(identity.get("handle", 0))
			return {
				"spec":
				{
					"kind": XCOMPOSITE_KIND,
					"settings": {"capture_window": "%d\r\n\r\n" % handle},
					"target": "window 0x%x" % handle,
				}
			}
		return {
			"spec": {},
			"reason":
			"OBS lacks xcomposite capture (native Wayland instance?) — quit OBS and press Record so it relaunches for window capture",
		}
	if _get_os_name() == "Windows":
		if not available.has(WINDOW_CAPTURE_KIND):
			return {"spec": {}, "reason": "OBS lacks window_capture"}
		var window := _build_windows_capture_window(identity)
		if window.is_empty():
			return {"spec": {}, "reason": "game exe/title unresolvable"}
		return {
			"spec":
			{
				"kind": WINDOW_CAPTURE_KIND,
				"settings": {"window": window},
				"target": "'%s'" % window,
			}
		}
	return {"spec": {}, "reason": "unsupported OS %s" % _get_os_name()}


## Record target scene: the configured obs/scene, else our owned scene.
func _record_target_scene() -> String:
	var target := str(_get_obs_settings().get("scene", "")).strip_edges()
	return target if not target.is_empty() else AUTO_SETUP_SCENE_NAME


## Ensures the target scene captures exactly our input with fresh settings,
## then points the program output at it and remembers the scene. Input names
## are global in OBS (one name = one kind), so a PipeWire-era source holding
## our name is removed before the window-capture input is created — a
## same-name CreateInput with a different kind fails 601 and would otherwise
## send every record down the PipeWire fallback. CreateInput already places
## a scene item, so the item phase only removes WHAT SHOULDN'T BE THERE
## (other sources in our owned scene, duplicate own items) and creates
## what's missing — it never destroys and re-creates a healthy placement.
## (Reproduced live Sep 2026: RemoveSceneItem→immediate CreateSceneItem→600
## "no source found" + black MP4; RemoveInput→immediate CreateInput→601 or
## source-less black. Both need the settle below.) Our owned scene is
## cleared of strangers; a user-configured scene is managed gently (our
## input ensured, everything else untouched). The xid changes every game
## launch, so an existing input always gets SetInputSettings — never trusted
## as-is. Returns true only when the program scene shows our input.
func _ensure_window_capture(client: OBSClient, spec: Dictionary) -> bool:
	var scene := _record_target_scene()
	var kind := str(spec.get("kind", ""))
	var fresh: Dictionary = spec.get("settings", {})
	var scenes := await _obs_request_await_on(client, "GetSceneList", {}, SCENE_CHECK_TIMEOUT)
	var have_scene := false
	if bool(scenes.get("ok", false)) and bool(scenes.get("result", false)):
		for sc in Dictionary(scenes.get("data", {})).get("scenes", []):
			if sc is Dictionary and str(sc.get("sceneName", "")) == scene:
				have_scene = true
	if not have_scene:
		var created := await _obs_request_await_on(
			client, "CreateScene", {"sceneName": scene}, SCENE_CHECK_TIMEOUT
		)
		if not bool(created.get("ok", false)) or not bool(created.get("result", false)):
			return false
	var input_uuid := ""
	var input_kind := ""
	var listed := await _obs_request_await_on(client, "GetInputList", {}, SCENE_CHECK_TIMEOUT)
	if bool(listed.get("ok", false)) and bool(listed.get("result", false)):
		for inp in Dictionary(listed.get("data", {})).get("inputs", []):
			if inp is Dictionary and str(inp.get("inputName", "")) == AUTO_SETUP_INPUT_NAME:
				input_uuid = str(inp.get("inputUuid", ""))
				input_kind = str(inp.get("inputKind", ""))
	if not input_uuid.is_empty() and input_kind != kind:
		# Cross-kind collision: the stale input (e.g. PipeWire) owns our
		# name, so CreateInput with our kind would fail 601. Remove it and
		# WAIT for the removal to settle: CreateInput in the same tick as
		# RemoveInput leaves the new input source-less (black recording —
		# reproduced live Sep 2026: Create→RemoveItem-same-tick→black MP4).
		var dropped := await _obs_request_await_on(
			client, "RemoveInput", {"inputName": AUTO_SETUP_INPUT_NAME}, SCENE_CHECK_TIMEOUT
		)
		if not bool(dropped.get("ok", false)) or not bool(dropped.get("result", false)):
			return false
		await _sleep(_get_settle_delay())
		input_uuid = ""
		input_kind = ""
	var ident := {"inputName": AUTO_SETUP_INPUT_NAME}
	if not input_uuid.is_empty():
		ident = {"inputUuid": input_uuid}
	if input_uuid.is_empty():
		var made := await _obs_request_await_on(
			client,
			"CreateInput",
			{
				"sceneName": scene,
				"inputName": AUTO_SETUP_INPUT_NAME,
				"inputKind": kind,
				"inputSettings": fresh,
			},
			SCENE_CHECK_TIMEOUT
		)
		if not bool(made.get("ok", false)) or not bool(made.get("result", false)):
			return false
		input_uuid = str(Dictionary(made.get("data", {})).get("inputUuid", ""))
		ident = (
			{"inputName": AUTO_SETUP_INPUT_NAME}
			if input_uuid.is_empty()
			else {"inputUuid": input_uuid}
		)
	else:
		var refreshed := await _obs_request_await_on(
			client, "SetInputSettings", ident.merged({"inputSettings": fresh}), SCENE_CHECK_TIMEOUT
		)
		if not bool(refreshed.get("ok", false)) or not bool(refreshed.get("result", false)):
			return false
	var items := await _obs_request_await_on(
		client, "GetSceneItemList", {"sceneName": scene}, SCENE_CHECK_TIMEOUT
	)
	if not bool(items.get("ok", false)) or not bool(items.get("result", false)):
		return false
	if scene == AUTO_SETUP_SCENE_NAME:
		# Owned scene: exactly our input, nothing else. Remove strangers
		# (PipeWire-era twins) and duplicate own items, keep ONE healthy
		# placement, create it only when missing. Never destroy-then-rebuild
		# a lone correct item — that same-tick cycle goes source-less/black.
		var own_ids: Array = []
		var stranger_ids: Array = []
		for it in Dictionary(items.get("data", {})).get("sceneItems", []):
			if not (it is Dictionary):
				continue
			var item_id := int(it.get("sceneItemId", -1))
			if item_id < 0:
				continue
			if (
				str(it.get("sourceUuid", "")) == input_uuid
				or str(it.get("sourceName", "")) == AUTO_SETUP_INPUT_NAME
			):
				own_ids.append(item_id)
			else:
				stranger_ids.append(item_id)
		for item_id in stranger_ids:
			await _obs_request_await_on(
				client,
				"RemoveSceneItem",
				{"sceneName": scene, "sceneItemId": item_id},
				SCENE_CHECK_TIMEOUT
			)
		for item_id in own_ids.slice(1):
			await _obs_request_await_on(
				client,
				"RemoveSceneItem",
				{"sceneName": scene, "sceneItemId": item_id},
				SCENE_CHECK_TIMEOUT
			)
		if own_ids.is_empty():
			# Fresh input (or cross-kind replacement): CreateInput may
			# already have placed an item — re-list before creating so we
			# don't stack a twin on it.
			var relist := await _obs_request_await_on(
				client, "GetSceneItemList", {"sceneName": scene}, SCENE_CHECK_TIMEOUT
			)
			var placed_elsewhere := false
			if bool(relist.get("ok", false)) and bool(relist.get("result", false)):
				for it in Dictionary(relist.get("data", {})).get("sceneItems", []):
					if (
						it is Dictionary
						and (
							str(it.get("sourceUuid", "")) == input_uuid
							or str(it.get("sourceName", "")) == AUTO_SETUP_INPUT_NAME
						)
					):
						placed_elsewhere = true
			if not placed_elsewhere:
				var placed := await _obs_request_await_on(
					client,
					"CreateSceneItem",
					{"sceneName": scene, "sourceName": AUTO_SETUP_INPUT_NAME},
					SCENE_CHECK_TIMEOUT
				)
				if not bool(placed.get("ok", false)):
					return false
	else:
		var own_id := -1
		var own_enabled := false
		for it in Dictionary(items.get("data", {})).get("sceneItems", []):
			if (
				it is Dictionary
				and (
					str(it.get("sourceUuid", "")) == input_uuid
					or str(it.get("sourceName", "")) == AUTO_SETUP_INPUT_NAME
				)
			):
				own_id = int(it.get("sceneItemId", -1))
				own_enabled = bool(it.get("sceneItemEnabled", true))
				break
		if own_id < 0:
			var placed := await _obs_request_await_on(
				client,
				"CreateSceneItem",
				{"sceneName": scene, "sourceName": AUTO_SETUP_INPUT_NAME},
				SCENE_CHECK_TIMEOUT
			)
			if not bool(placed.get("ok", false)):
				return false
		elif not own_enabled:
			await _obs_request_await_on(
				client,
				"SetSceneItemEnabled",
				{"sceneName": scene, "sceneItemId": own_id, "sceneItemEnabled": true},
				SCENE_CHECK_TIMEOUT
			)
	var switched := await _obs_request_await_on(
		client, "SetCurrentProgramScene", {"sceneName": scene}, SCENE_CHECK_TIMEOUT
	)
	if not bool(switched.get("ok", false)) or not bool(switched.get("result", false)):
		return false
	await _fit_owned_item_to_canvas(client, scene, input_uuid)
	_remember_scene(scene)
	return true


## Fits our owned-scene item to the canvas with aspect-preserving bounds
## (SCALE_INNER against the live base size): an unscaled 1152×648 game on a
## 1920×1080 canvas otherwise records as a top-left stamp with black bars
## (reproduced Sep 2026: live pixels in a 769×432 corner of 1280×720).
## Best-effort and idempotent: any failed query or set is skipped, never
## fatal to the record. Only the owned scene is ever touched.
func _fit_owned_item_to_canvas(client: OBSClient, scene: String, input_uuid: String) -> void:
	if scene != AUTO_SETUP_SCENE_NAME:
		return
	var video := await _obs_request_await_on(client, "GetVideoSettings", {}, SCENE_CHECK_TIMEOUT)
	if not bool(video.get("ok", false)) or not bool(video.get("result", false)):
		return
	var canvas := Dictionary(video.get("data", {}))
	var base_w := float(canvas.get("baseWidth", 0))
	var base_h := float(canvas.get("baseHeight", 0))
	if base_w <= 0.0 or base_h <= 0.0:
		return
	var items := await _obs_request_await_on(
		client, "GetSceneItemList", {"sceneName": scene}, SCENE_CHECK_TIMEOUT
	)
	if not bool(items.get("ok", false)) or not bool(items.get("result", false)):
		return
	for it in Dictionary(items.get("data", {})).get("sceneItems", []):
		if not (it is Dictionary):
			continue
		if (
			str(it.get("sourceUuid", "")) != input_uuid
			and str(it.get("sourceName", "")) != AUTO_SETUP_INPUT_NAME
		):
			continue
		var xf := Dictionary((it as Dictionary).get("sceneItemTransform", {}))
		if (
			str(xf.get("boundsType", "")) == "OBS_BOUNDS_SCALE_INNER"
			and float(xf.get("boundsWidth", 0)) == base_w
			and float(xf.get("boundsHeight", 0)) == base_h
		):
			return
		await _obs_request_await_on(
			client,
			"SetSceneItemTransform",
			{
				"sceneName": scene,
				"sceneItemId": int(it.get("sceneItemId", -1)),
				"sceneItemTransform":
				{
					"boundsType": "OBS_BOUNDS_SCALE_INNER",
					"boundsAlignment": 5,
					"boundsWidth": base_w,
					"boundsHeight": base_h,
				},
			},
			SCENE_CHECK_TIMEOUT
		)
		return


## Preflight for the black-video failure: resolves the scene OBS would record
## (the configured obs/scene setting, else the current program scene) and
## verifies it contains at least one enabled source via a transient OBS
## client (kept off _obs_client so start/stop request bookkeeping is
## untouched). Returns {"ok": true} to proceed, or {"ok": false, "message":
## error} to abort. Any query failure (unknown scene, timeout, old OBS
## without GetSceneItemList) is fail-open {"ok": true}.
func _check_record_scene_ready() -> Dictionary:
	var settings := _get_obs_settings()
	var target := str(settings.get("scene", "")).strip_edges()
	var host: String = str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port: int = int(settings.get("port", OBSClient.DEFAULT_PORT))
	var password: String = str(settings.get("password", ""))
	var client := _create_obs_client()
	if client == null or not is_inside_tree():
		if client != null:
			client.queue_free()
		return {"ok": true}
	add_child(client)
	var cleanup := func() -> void:
		if client.is_inside_tree():
			client.get_parent().remove_child(client)
		client.queue_free()
	if client.connect_to_obs(host, port, password) != OK:
		cleanup.call()
		return {"ok": true}
	if not await _await_auth(client, CONNECT_TIMEOUT):
		cleanup.call()
		return {"ok": true}
	var scene_name := target
	if scene_name.is_empty():
		var cur := await _obs_request_await_on(
			client, "GetCurrentProgramScene", {}, SCENE_CHECK_TIMEOUT
		)
		if not bool(cur.get("ok", false)) or not bool(cur.get("result", false)):
			cleanup.call()
			return {"ok": true}
		scene_name = str(Dictionary(cur.get("data", {})).get("currentProgramSceneName", ""))
		if scene_name.is_empty():
			cleanup.call()
			return {"ok": true}
	var items_resp := await _obs_request_await_on(
		client, "GetSceneItemList", {"sceneName": scene_name}, SCENE_CHECK_TIMEOUT
	)
	cleanup.call()
	if not bool(items_resp.get("ok", false)) or not bool(items_resp.get("result", false)):
		return {"ok": true}
	var data: Dictionary = items_resp.get("data", {})
	# Fail open when the key is absent (unexpected shape / older OBS) — only
	# an explicitly empty (or all-disabled) item list aborts the recording.
	if not data.has("sceneItems"):
		return {"ok": true}
	var items: Array = data.get("sceneItems", [])
	if items.is_empty():
		return {
			"ok": false,
			"message": _describe_empty_scene_error(scene_name),
			"setup_eligible": true,
			"scene": scene_name,
		}
	for it in items:
		if it is Dictionary and bool(it.get("sceneItemEnabled", true)):
			return {"ok": true}
	return {
		"ok": false,
		"message": _describe_empty_scene_error(scene_name),
		"setup_eligible": true,
		"scene": scene_name,
	}


## Actionable error for the empty-scene preflight above: names the scene and
## steers the picker at the game window (a monitor-sized share of the wrong
## screen is the "VSCode behind the scenes" failure).
func _describe_empty_scene_error(scene_name: String) -> String:
	var shown := scene_name if not scene_name.is_empty() else "current"
	return (
		(
			"OBS scene '%s' has no enabled sources — recording now would produce a black video. "
			% shown
		)
		+ "In OBS, add a Screen Capture (PipeWire) source to that scene. "
		+ _pick_window_guidance()
	)


## Whether the preflight may build the capture scene automatically on
## Record. EditorSettings key `gd_time_machine/obs/auto_setup_scene`
## (default true, registered by plugin.gd): when the PipeWire fallback would
## otherwise create a capture source from nothing, refusing fast keeps a
## stale monitor-sized portal share from ever being the thing a Record
## silently reuses (that reuse is exactly the "VSCode behind the game"
## failure). True keeps the historic behavior (empty scene → create PipeWire
## source + wait for the human pick); tests flip the static seam below to
## pin the refuse-fast path. The programmatic xcomposite path is unaffected
## (its own scene/input logic).
static var AUTO_SETUP_PIPEWIRE := true


func _get_auto_setup_setting() -> bool:
	var v := _read_setting("gd_time_machine/obs/auto_setup_scene")
	if v != null:
		return bool(v)
	return BackendOBS.AUTO_SETUP_PIPEWIRE


## Title of the game window, for picker guidance ("select '<title>'").
## Falls back to a generic noun when the project name is unset (headless).
func _game_window_title() -> String:
	if ProjectSettings.has_setting("application/config/name"):
		var title := str(ProjectSettings.get_setting("application/config/name")).strip_edges()
		if not title.is_empty():
			return title
	return "the game"


## The one sentence every share-picker prompt must carry: Window, not
## monitor, and the actual game window. A monitor-sized (1920×1080) capture
## of the wrong screen is exactly the "VSCode behind the scenes" failure.
func _pick_window_guidance() -> String:
	return (
		"In the share picker, choose Window (not Entire screen) and select '%s'."
		% _game_window_title()
	)


## Opens a connected + authed transient OBS client for one-off queries.
## Returns null when OBS can't be reached. Pair with _close_transient_client().
## Kept off _obs_client so start/stop request bookkeeping is untouched.
func _open_transient_client() -> OBSClient:
	var settings := _get_obs_settings()
	var client := _create_obs_client()
	if client == null or not is_inside_tree():
		if client != null:
			client.queue_free()
		return null
	add_child(client)
	if (
		client.connect_to_obs(
			str(settings.get("host", OBSClient.DEFAULT_HOST)),
			int(settings.get("port", OBSClient.DEFAULT_PORT)),
			str(settings.get("password", ""))
		)
		!= OK
	):
		_close_transient_client(client)
		return null
	if not await _await_auth(client, CONNECT_TIMEOUT):
		_close_transient_client(client)
		return null
	return client


## Frees a client opened with _open_transient_client().
func _close_transient_client(client: OBSClient) -> void:
	if client == null:
		return
	if client.is_inside_tree():
		client.get_parent().remove_child(client)
	client.queue_free()


## Resolves the record scene OBS would capture (configured obs/scene, else the
## current program scene). Returns "" when it can't be determined.
func _resolve_record_scene_name(client: OBSClient) -> String:
	var target := str(_get_obs_settings().get("scene", "")).strip_edges()
	if not target.is_empty():
		return target
	var cur := await _obs_request_await_on(
		client, "GetCurrentProgramScene", {}, SCENE_CHECK_TIMEOUT
	)
	if bool(cur.get("ok", false)) and bool(cur.get("result", false)):
		return str(Dictionary(cur.get("data", {})).get("currentProgramSceneName", ""))
	return ""


## Finds the first enabled pixel-capturing item in the scene: {"name", "uuid",
## "kind", "item_id"}. {} when the scene has no enabled capture source.
## Remembers the record scene in the obs/scene setting so the next Record
## targets it explicitly. Best-effort: silently skips when no settings store
## is reachable (headless tests).
func _remember_scene(scene_name: String) -> void:
	var es := _get_es()
	if es != null and es.has_method("set_setting"):
		es.set_setting("gd_time_machine/obs/scene", scene_name)


## Capture-setup summary for the dock's setup dialog:
## {"scene", "source", "mode", "detail"}, or {"error": message} when OBS
## can't be reached/queried. mode is "window" (our input present with a
## readable target), "pipewire" (a saved portal share would be reused —
## silent-reuse suspect), or "none". Runs on a transient client; never
## touches recording state or bookkeeping.
func get_setup_summary() -> Dictionary:
	var summary := {"scene": "", "source": "", "mode": "none", "detail": ""}
	var settings := _get_obs_settings()
	var client := _create_obs_client()
	if client == null or not is_inside_tree():
		if client != null:
			client.queue_free()
		summary["error"] = "No OBS client."
		return summary
	add_child(client)
	var cleanup := func() -> void:
		if client.is_inside_tree():
			client.get_parent().remove_child(client)
		client.queue_free()
	if (
		client.connect_to_obs(
			str(settings.get("host", OBSClient.DEFAULT_HOST)),
			int(settings.get("port", OBSClient.DEFAULT_PORT)),
			str(settings.get("password", ""))
		)
		!= OK
	):
		cleanup.call()
		summary["error"] = "Could not connect to OBS."
		return summary
	if not await _await_auth(client, CONNECT_TIMEOUT):
		cleanup.call()
		summary["error"] = _describe_start_error()
		return summary
	var scene_name := str(settings.get("scene", "")).strip_edges()
	if scene_name.is_empty():
		var cur := await _obs_request_await_on(
			client, "GetCurrentProgramScene", {}, SCENE_CHECK_TIMEOUT
		)
		if bool(cur.get("ok", false)) and bool(cur.get("result", false)):
			scene_name = str(Dictionary(cur.get("data", {})).get("currentProgramSceneName", ""))
	if scene_name.is_empty():
		cleanup.call()
		summary["error"] = "Could not determine the program scene."
		return summary
	summary["scene"] = scene_name
	var items_resp := await _obs_request_await_on(
		client, "GetSceneItemList", {"sceneName": scene_name}, SCENE_CHECK_TIMEOUT
	)
	if not bool(items_resp.get("ok", false)) or not bool(items_resp.get("result", false)):
		cleanup.call()
		summary["error"] = "Could not list scene items."
		return summary
	var found := _describe_scene_capture(
		Dictionary(items_resp.get("data", {})).get("sceneItems", [])
	)
	if not found.is_empty():
		summary["source"] = str(found.get("source", ""))
		summary["mode"] = str(found.get("mode", "none"))
		if str(found.get("mode", "")) == "window":
			var ident := {"inputName": str(found.get("source", ""))}
			if not str(found.get("uuid", "")).is_empty():
				ident = {"inputUuid": str(found.get("uuid", ""))}
			var cur_settings := await _obs_request_await_on(
				client, "GetInputSettings", ident, SCENE_CHECK_TIMEOUT
			)
			if bool(cur_settings.get("ok", false)) and bool(cur_settings.get("result", false)):
				summary["detail"] = _describe_window_target(
					str(found.get("kind", "")),
					Dictionary(Dictionary(cur_settings.get("data", {})).get("inputSettings", {}))
				)
			else:
				summary["detail"] = "configured (settings unreadable)"
		else:
			summary["detail"] = "saved portal share — reused silently on Record"
	else:
		summary["detail"] = "no capture source — recordings would be black"
	cleanup.call()
	return summary


## Classifies a scene-item list for the summary: {"source", "uuid", "kind",
## "mode"} with mode "window" (our programmatic kinds), "pipewire" (portal
## kinds holding a saved share — checked by the caller via settings), or {}
## when no enabled capture item exists. Pure: no OBS I/O, easy to test.
func _describe_scene_capture(items: Array) -> Dictionary:
	for it in items:
		if (
			it is Dictionary
			and bool(it.get("sceneItemEnabled", true))
			and (
				str(it.get("inputKind", "")) == XCOMPOSITE_KIND
				or str(it.get("inputKind", "")) == WINDOW_CAPTURE_KIND
			)
		):
			return {
				"source": str(it.get("sourceName", "")),
				"uuid": str(it.get("sourceUuid", "")),
				"kind": str(it.get("inputKind", "")),
				"mode": "window",
			}
	for it in items:
		if (
			it is Dictionary
			and bool(it.get("sceneItemEnabled", true))
			and str(it.get("inputKind", "")).begins_with("pipewire-")
		):
			return {
				"source": str(it.get("sourceName", "")),
				"uuid": str(it.get("sourceUuid", "")),
				"kind": str(it.get("inputKind", "")),
				"mode": "pipewire",
			}
	return {}


## Human description of a window-capture target from live input settings:
## the xcomposite window id, or the Windows "[exe]: title" selector.
static func _describe_window_target(kind: String, input_settings: Dictionary) -> String:
	if kind == XCOMPOSITE_KIND:
		var first := str(input_settings.get("capture_window", "")).split("\r\n")[0].strip_edges()
		if first.is_empty():
			return "window target unset"
		return "window %s" % first
	if kind == WINDOW_CAPTURE_KIND:
		var window := str(input_settings.get("window", "")).strip_edges()
		if window.is_empty():
			return "window target unset"
		return "window '%s'" % window
	return "configured"


## Runs programmatic window-capture setup on demand (dock setup dialog),
## outside any recording: resolves the game identity, ensures the input, and
## reports. Refuses while recording — the Record flow owns setup then. No
## PipeWire here (that fallback only makes sense with a record attached).
func run_setup_now() -> Dictionary:
	if is_recording():
		return {"ok": false, "message": "Stop the current recording before setting up OBS."}
	var client := await _open_transient_client()
	if client == null:
		return {
			"ok": false,
			"message":
			"Could not connect to OBS — check it is running with the WebSocket server enabled.",
		}
	var resolved := await _resolve_programmatic_spec(client)
	var spec: Dictionary = resolved.get("spec", {})
	if spec.is_empty():
		_close_transient_client(client)
		return {
			"ok": false,
			"message":
			(
				"Window capture unavailable (%s). Start the game and retry — PipeWire setup still runs automatically on Record."
				% str(resolved.get("reason", "unknown cause"))
			),
		}
	if not await _ensure_window_capture(client, spec):
		_close_transient_client(client)
		return {
			"ok": false, "message": "OBS rejected the window-capture setup — check the OBS log."
		}
	_close_transient_client(client)
	return {"ok": true}


## How long to wait for the portal share-picker after auto-setup creates the
## source. Seam so tests don't sit in the wait loop.
func _get_setup_wait_timeout() -> float:
	return SETUP_WAIT_TIMEOUT


## Auto-setup: builds a dedicated record scene + desktop-capture source after
## the preflight found the current scene empty. Runs on its own transient
## client (same bookkeeping isolation as the preflight). Steps:
## kinds → scene (reuse ours when present) → input → scene item → program
## scene → properties dialog (parks the human on the picker) → wait for the
## portal RestoreToken. Returns {"ok": true} when OBS is ready to StartRecord,
## else {"ok": false, "message": actionable error}. Any unexpected shape is
## fail-closed here with guidance (unlike the preflight: we already know the
## scene is empty, so proceeding can only make black).
##
## for_record=true (the Record path) aborts silently when the session ends
## mid-setup (user pressed Stop — the stop flow owns the signals). false (the
## dock's "set up now") runs to completion/timeout and always reports.
func _auto_setup_record_scene(for_record := true) -> Dictionary:
	var refuse := func(detail: String) -> Dictionary:
		return {
			"ok": false,
			"message":
			(
				"OBS auto-setup could not create a capture source (%s). " % detail
				+ "In OBS, add a Screen Capture (PipeWire) source to a scene. "
				+ _pick_window_guidance()
				+ " Then press Record again."
			),
		}
	var settings := _get_obs_settings()
	var host: String = str(settings.get("host", OBSClient.DEFAULT_HOST))
	var port: int = int(settings.get("port", OBSClient.DEFAULT_PORT))
	var password: String = str(settings.get("password", ""))
	var client := _create_obs_client()
	if client == null or not is_inside_tree():
		if client != null:
			client.queue_free()
		return refuse.call("no OBS client")
	add_child(client)
	var cleanup := func() -> void:
		if client.is_inside_tree():
			client.get_parent().remove_child(client)
		client.queue_free()
	if client.connect_to_obs(host, port, password) != OK:
		cleanup.call()
		return refuse.call("connect failed")
	if not await _await_auth(client, CONNECT_TIMEOUT):
		cleanup.call()
		return refuse.call("authentication failed")
	# Capture kind: PipeWire desktop capture on Wayland. Anything else is a
	# platform this path doesn't know — bail with guidance, don't guess.
	var kinds := await _obs_request_await_on(
		client, "GetInputKindList", {"unversioned": true}, SCENE_CHECK_TIMEOUT
	)
	if not bool(kinds.get("ok", false)) or not bool(kinds.get("result", false)):
		cleanup.call()
		return refuse.call("could not list input kinds")
	var available: Array = Dictionary(kinds.get("data", {})).get("inputKinds", [])
	if not available.has(PIPEWIRE_CAPTURE_KIND):
		cleanup.call()
		return refuse.call("no PipeWire capture (need Wayland + OBS PipeWire support)")
	# Scene: reuse ours when a previous setup already made it.
	var scene_list := await _obs_request_await_on(client, "GetSceneList", {}, SCENE_CHECK_TIMEOUT)
	var have_scene := false
	if bool(scene_list.get("ok", false)) and bool(scene_list.get("result", false)):
		for sc in Dictionary(scene_list.get("data", {})).get("scenes", []):
			if sc is Dictionary and str(sc.get("sceneName", "")) == AUTO_SETUP_SCENE_NAME:
				have_scene = true
	if not have_scene:
		var created := await _obs_request_await_on(
			client, "CreateScene", {"sceneName": AUTO_SETUP_SCENE_NAME}, SCENE_CHECK_TIMEOUT
		)
		if not bool(created.get("ok", false)) or not bool(created.get("result", false)):
			cleanup.call()
			return refuse.call("could not create scene '%s'" % AUTO_SETUP_SCENE_NAME)
	# Input: reuse ours when a previous setup already made it — creating it
	# again would stack same-named duplicate sources (each with its own
	# portal share), and the record scene would capture whichever share,
	# e.g. a stale monitor-sized one of an IDE. Missing keys fail forward to
	# creation, preserving the old blind-create behavior.
	var input_uuid := ""
	var listed := await _obs_request_await_on(
		client, "GetInputList", {"inputKind": PIPEWIRE_CAPTURE_KIND}, SCENE_CHECK_TIMEOUT
	)
	if bool(listed.get("ok", false)) and bool(listed.get("result", false)):
		for inp in Dictionary(listed.get("data", {})).get("inputs", []):
			if inp is Dictionary and str(inp.get("inputName", "")) == AUTO_SETUP_INPUT_NAME:
				input_uuid = str(inp.get("inputUuid", ""))
	if input_uuid.is_empty():
		var made_input := await _obs_request_await_on(
			client,
			"CreateInput",
			{
				"sceneName": AUTO_SETUP_SCENE_NAME,
				"inputName": AUTO_SETUP_INPUT_NAME,
				"inputKind": PIPEWIRE_CAPTURE_KIND,
			},
			SCENE_CHECK_TIMEOUT
		)
		if not bool(made_input.get("ok", false)) or not bool(made_input.get("result", false)):
			cleanup.call()
			return refuse.call("could not create input '%s'" % AUTO_SETUP_INPUT_NAME)
		input_uuid = str(Dictionary(made_input.get("data", {})).get("inputUuid", ""))
	# Scene item: ensure exactly one present + enabled reference for the input.
	# A failed item query falls through to a blind create (old behavior).
	var own_items := await _obs_request_await_on(
		client, "GetSceneItemList", {"sceneName": AUTO_SETUP_SCENE_NAME}, SCENE_CHECK_TIMEOUT
	)
	var own_item_id := -1
	var own_item_enabled := false
	if bool(own_items.get("ok", false)) and bool(own_items.get("result", false)):
		for it in Dictionary(own_items.get("data", {})).get("sceneItems", []):
			if (
				it is Dictionary
				and (
					str(it.get("sourceUuid", "")) == input_uuid
					or str(it.get("sourceName", "")) == AUTO_SETUP_INPUT_NAME
				)
			):
				own_item_id = int(it.get("sceneItemId", -1))
				own_item_enabled = bool(it.get("sceneItemEnabled", true))
				break
	if own_item_id < 0:
		var made_item := await _obs_request_await_on(
			client,
			"CreateSceneItem",
			{"sceneName": AUTO_SETUP_SCENE_NAME, "sourceName": AUTO_SETUP_INPUT_NAME},
			SCENE_CHECK_TIMEOUT
		)
		if not bool(made_item.get("ok", false)):
			cleanup.call()
			return refuse.call("no reply creating the scene item")
	elif not own_item_enabled:
		await _obs_request_await_on(
			client,
			"SetSceneItemEnabled",
			{
				"sceneName": AUTO_SETUP_SCENE_NAME,
				"sceneItemId": own_item_id,
				"sceneItemEnabled": true,
			},
			SCENE_CHECK_TIMEOUT
		)
	# Heal twins from earlier runs before anyone records through them.
	await _heal_own_scene_duplicates(client)
	# Show it: program scene so OBS records it, and pop the properties dialog
	# so the human lands on the picker (fire-and-forget — OBS may be trayed).
	await _obs_request_await_on(
		client, "SetCurrentProgramScene", {"sceneName": AUTO_SETUP_SCENE_NAME}, SCENE_CHECK_TIMEOUT
	)
	await _obs_request_await_on(
		client,
		"OpenInputPropertiesDialog",
		{"inputName": AUTO_SETUP_INPUT_NAME},
		SCENE_CHECK_TIMEOUT
	)
	_remember_scene(AUTO_SETUP_SCENE_NAME)
	recording_notice.emit(
		get_backend_name(),
		(
			"Created OBS scene '%s' — %s Recording starts automatically once picked."
			% [AUTO_SETUP_SCENE_NAME, _pick_window_guidance()]
		)
	)
	# Wait for the portal pick: the source persists a RestoreToken once the
	# human shares. On the Record path, abort promptly when the user stops
	# the pending record (the stop flow owns the signals then).
	var deadline := Time.get_ticks_msec() / 1000.0 + _get_setup_wait_timeout()
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if for_record and (not _active or _stopping):
			cleanup.call()
			return {"ok": false, "message": ""}
		var cur := await _obs_request_await_on(
			client, "GetInputSettings", {"inputName": AUTO_SETUP_INPUT_NAME}, SCENE_CHECK_TIMEOUT
		)
		if bool(cur.get("ok", false)) and bool(cur.get("result", false)):
			var token := str(
				Dictionary(Dictionary(cur.get("data", {})).get("inputSettings", {})).get(
					"RestoreToken", ""
				)
			)
			if not token.is_empty():
				cleanup.call()
				return {"ok": true}
		await _sleep(SETUP_WAIT_POLL)
	cleanup.call()
	return {
		"ok": false,
		"message":
		(
			(
				"OBS scene '%s' was created but no screen share was picked in time. "
				% AUTO_SETUP_SCENE_NAME
			)
			+ _pick_window_guidance()
			+ " Then press Record again."
		),
	}


## Removes same-named duplicate items of our input in our scene, keeping the
## first enabled one (else the first listed). Every match is provably ours
## (our scene + our input name) — earlier runs could stack them, and each twin
## carries its own portal share, so the record composites whichever share,
## stale monitor-sized ones included. Best-effort: failures are ignored.
func _heal_own_scene_duplicates(client: OBSClient) -> void:
	var resp := await _obs_request_await_on(
		client, "GetSceneItemList", {"sceneName": AUTO_SETUP_SCENE_NAME}, SCENE_CHECK_TIMEOUT
	)
	if not bool(resp.get("ok", false)) or not bool(resp.get("result", false)):
		return
	var own: Array = []
	for it in Dictionary(resp.get("data", {})).get("sceneItems", []):
		if it is Dictionary and str(it.get("sourceName", "")) == AUTO_SETUP_INPUT_NAME:
			own.append(it)
	if own.size() < 2:
		return
	var keep := -1
	for it in own:
		if bool((it as Dictionary).get("sceneItemEnabled", true)):
			keep = int((it as Dictionary).get("sceneItemId", -1))
			break
	if keep < 0:
		keep = int((own[0] as Dictionary).get("sceneItemId", -1))
	for it in own:
		var item_id := int((it as Dictionary).get("sceneItemId", -1))
		if item_id >= 0 and item_id != keep:
			await _obs_request_await_on(
				client,
				"RemoveSceneItem",
				{"sceneName": AUTO_SETUP_SCENE_NAME, "sceneItemId": item_id},
				SCENE_CHECK_TIMEOUT
			)


## One-off OBS request/response on the given client (never touches
## _pending_request_id/kind, which belong to start/stop). The request id is
## pre-generated so the one-shot matcher closes over a fixed value.
## Returns {"ok": bool, "result": bool, "code": int, "data": Dictionary}.
## Uses the wall clock (not _now(), which tests freeze) so a lost reply can
## never hang the loop.
func _obs_request_await_on(
	client: OBSClient, request_type: String, request_data: Dictionary, timeout: float
) -> Dictionary:
	var fallback := {"ok": false, "result": false, "code": -1, "data": {}}
	if client == null or not client.is_connected_to_obs():
		return fallback
	var rq_id := "gdtime_preflight_%d" % absi(randi())
	var box := {"done": false, "result": false, "code": -1, "data": {}}
	var on_resp := func(resp_id: String, res: bool, resp_code: int, resp_data: Dictionary) -> void:
		if resp_id != rq_id:
			return
		box["done"] = true
		box["result"] = res
		box["code"] = resp_code
		box["data"] = resp_data
	client.request_completed.connect(on_resp)
	var sent_id := client.send_request(request_type, request_data, rq_id)
	if sent_id.is_empty() or sent_id != rq_id:
		if client.request_completed.is_connected(on_resp):
			client.request_completed.disconnect(on_resp)
		return fallback
	var deadline := Time.get_ticks_msec() / 1000.0 + timeout
	while not bool(box["done"]) and Time.get_ticks_msec() / 1000.0 < deadline:
		await _sleep(0.05)
	if client.request_completed.is_connected(on_resp):
		client.request_completed.disconnect(on_resp)
	if not bool(box["done"]):
		return fallback
	return {
		"ok": true,
		"result": bool(box["result"]),
		"code": int(box["code"]),
		"data": box["data"],
	}


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
	# Tier-2: MP4 intermediate just finalized, now transcode to WEBM/AVI/OGV
	# when requested (same pattern as Movie Maker). The dock's Converting…
	# status (via format_needs_ffmpeg) bridges the gap until converted.
	if _auto_convert_enabled and _needs_ffmpeg_convert():
		_trigger_ffmpeg_convert()


## Whether the recorded MP4 intermediate still needs a transcode for the
## requested target: supported, non-native, convert-enabled is checked by the
## caller — here only the format relationship.
func _needs_ffmpeg_convert() -> bool:
	if _target_output_format.is_empty():
		return false
	var fmt := GdTMOutputFormat.from_string(_target_output_format)
	return is_format_supported(fmt) and format_needs_ffmpeg(fmt)


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


# --- tier-2 transcode (file → file, MP4 intermediate, registry-matched) ------


func _trigger_ffmpeg_convert() -> void:
	request_transcode(
		{
			"kind": "file",
			"path": _intermediate_path,
			"format": GdTMOutputFormat.Format.MP4,
		},
		_final_output_path,
		{
			"target": GdTMOutputFormat.from_string(_target_output_format),
			"label": _target_output_format,
			"fps": _target_fps,
			"clean": false,
		}
	)


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
	if _get_os_name() == "Linux":
		# xcomposite window capture only registers when OBS itself runs on
		# X11: force XWayland so the programmatic path is available. Native
		# Wayland OBS instances (user-launched) fall back to PipeWire.
		return OS.create_process(
			"/usr/bin/env", ["QT_QPA_PLATFORM=xcb", binary, "--minimize-to-tray"]
		)
	return OS.create_process(binary, ["--minimize-to-tray"])


func _kill_process(pid: int) -> void:
	if pid > 0:
		OS.kill(pid)


func _os_execute(binary: String, args: PackedStringArray, out: Array) -> int:
	return OS.execute(binary, args, out, true)


# --- OBS ownership record + orphan sweep (D1/D2/D3) ---


## Records that this session launched OBS (pid + resolved binary) in user:// so
## a later session's orphan sweep can prove ownership before killing anything.
## Save errors are ignored: the ledger is best-effort bookkeeping.
func _persist_launched_pid(pid: int, binary: String) -> void:
	if pid <= 0:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("obs", "pid", pid)
	cfg.set_value("obs", "binary", binary)
	cfg.save("user://gdtime_obs_launched.cfg")


## Reads the persisted launch record. Missing file or pid <= 0 means "no entry".
func _load_launched_ledger() -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load("user://gdtime_obs_launched.cfg") != OK:
		return {}
	var pid := int(cfg.get_value("obs", "pid", 0))
	if pid <= 0:
		return {}
	return {"pid": pid, "binary": str(cfg.get_value("obs", "binary", ""))}


## Drops the persisted launch record. Delete errors are ignored.
func _clear_launched_ledger() -> void:
	DirAccess.remove_absolute("user://gdtime_obs_launched.cfg")


func _is_process_alive(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)


## True when pid is provably our OBS launch: the stored binary as argv[0] plus
## our --minimize-to-tray flag, read from /proc/<pid>/cmdline. On non-Linux
## there is no reliable /proc, so the check is best-effort true (documented
## limitation — we never kill by pid alone on platforms that can verify).
func _process_is_ours(pid: int, binary: String) -> bool:
	if OS.get_name() != "Linux":
		return true
	if pid <= 0 or binary.is_empty():
		return false
	var cmdline := FileAccess.get_file_as_string("/proc/%d/cmdline" % pid)
	if cmdline.is_empty():
		return false
	var parts := cmdline.split(String.chr(0))
	if parts.is_empty():
		return false
	return (
		_normalize_binary_path(parts[0]) == _normalize_binary_path(binary)
		and parts.has("--minimize-to-tray")
	)


## Trims and resolves res:///user:// prefixes so a /proc cmdline entry and the
## stored binary path compare as equal absolute filesystem paths.
func _normalize_binary_path(path: String) -> String:
	var p := path.strip_edges()
	if p.begins_with("res://") or p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	return p


## SIGKILL-level kill for processes that ignore TERM (OS.kill is one shot, no
## escalation). Per-OS force-kill command; falls back to OS.kill elsewhere.
func _force_kill_process(pid: int) -> void:
	if pid <= 0:
		return
	match OS.get_name():
		"Linux":
			OS.execute("kill", ["-9", str(pid)])
		"Windows":
			OS.execute("taskkill", ["/F", "/PID", str(pid)])
		_:
			OS.kill(pid)


## TERM first, then up to ~2 s grace polling liveness, then SIGKILL.
## Returns whether the process is confirmed gone afterwards.
func _kill_process_and_wait(pid: int) -> bool:
	if pid <= 0:
		return true
	_kill_process(pid)
	var deadline := _now() + 2.0
	while _is_process_alive(pid) and _now() < deadline:
		await _sleep(0.25)
	if _is_process_alive(pid):
		_force_kill_process(pid)
	return not _is_process_alive(pid)


## Startup orphan sweep (D2): a previous session may have died hard (crash,
## SIGKILL) and left an OBS it launched behind. Only processes we can prove we
## launched are touched; everything else is logged and the stale ledger entry
## dropped. auto_close off means we manage nothing, orphans included.
func _reap_orphaned_launches() -> void:
	if not _get_auto_close_setting():
		return
	var ledger := _load_launched_ledger()
	if ledger.is_empty():
		return
	var pid: int = int(ledger.get("pid", 0))
	if pid <= 0:
		_clear_launched_ledger()
		return
	if not _is_process_alive(pid):
		_clear_launched_ledger()
		return
	if not _process_is_ours(pid, str(ledger.get("binary", ""))):
		push_warning(
			(
				"[GdTM] %s: found pid %d at the recorded OBS ledger, but it is not our OBS launch — leaving it alone."
				% [get_backend_name(), pid]
			)
		)
		_clear_launched_ledger()
		return
	var confirmed := await _kill_process_and_wait(pid)
	if confirmed:
		print(
			(
				"[GdTM] %s: reaped a leftover OBS from a previous session (pid %d)"
				% [get_backend_name(), pid]
			)
		)
	else:
		push_warning(
			(
				"[GdTM] %s: could not stop the leftover OBS (pid %d) — it may still be running."
				% [get_backend_name(), pid]
			)
		)
	_clear_launched_ledger()


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
	if _ffmpeg_converter != null:
		_ffmpeg_converter.wait_for_completion()
	var launched_pid := _launched_pid
	if _we_launched and _get_auto_close_setting():
		_kill_process(launched_pid)
		# Direct print, not a recording_notice: by the time _exit_tree runs the
		# plugin has already disconnected its [GdTM] feedback handlers
		# (plugin._exit_tree → _disconnect_controller_feedback), so a notice
		# would be silently lost. This line is the auto_close bookend to the
		# launch narration in ensure_obs_running(). The ledger entry is
		# deliberately left behind so the next startup's orphan sweep (D2) is
		# the safety net if TERM silently fails.
		print(
			(
				"[GdTM] %s: closed — auto_close stopped the OBS instance we launched (pid %d)"
				% [get_backend_name(), launched_pid]
			)
		)
		_we_launched = false
		_launched_pid = 0
	_release_obs_client()
