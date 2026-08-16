extends GutTest

## The OBS password the user sets in Project > Editor Settings must reach
## _password on the client. These tests prove the read half —
## _get_obs_settings()/typed readers resolve the password from the settings
## store, EditorSettings-first then ProjectSettings-fallback. The assign half
## (connect_to_obs → _password) lives in test_obs_client.gd; the seam joining
## them (the backend's start()/probe forwarding settings-password into
## connect_to_obs) is exercised in the start() tests below.
##
## EditorSettings cannot exist in headless GUT — Engine.has_singleton(
## "EditorSettings") is FALSE in 4.7 even under --editor — so the
## EditorSettings-present branch is covered by injecting a fake store through
## _editor_settings, the same seam EditorSettingsConfigStore already uses.

const PASSWORD_KEY := "gd_time_machine/obs/password"
const TEST_PASSWORD := "phase0-plumbing-password"
## Budget for awaiting fake-deferred request replies (wait_for_signal).
## Must stay < the backend's 3.0 s StopRecord fallback timer so a test can
## never pass via the fallback; the fake replies ~1 frame later, so 2.0 s is
## orders of magnitude above the reply latency.
const REPLY_BUDGET := 2.0


## Fake EditorSettings store: get_setting() returns per-key values or null,
## exactly like the real singleton's missing-key behavior.
class FakeEditorSettings:
	extends RefCounted
	var _values := {}

	func set_v(key: String, value: Variant) -> void:
		_values[key] = value

	func get_setting(name: String) -> Variant:
		return _values.get(name, null)


func before_each() -> void:
	ProjectSettings.clear(PASSWORD_KEY)


func _read_password(backend: BackendOBS) -> String:
	return str(backend._get_obs_settings().get("password", ""))


func _make_backend() -> BackendOBS:
	# add_child_autofree returns an untyped value, so the caller must annotate.
	return add_child_autofree(BackendOBS.new())


func test_password_read_from_project_settings_fallback() -> void:
	# EditorSettings absent (headless; _editor_settings null) → readers must
	# fall through to ProjectSettings, not to the default.
	ProjectSettings.set_setting(PASSWORD_KEY, TEST_PASSWORD)
	assert_eq(_read_password(_make_backend()), TEST_PASSWORD)


func test_empty_password_default_when_unset() -> void:
	# Nothing set anywhere → empty password (server auth disabled case).
	assert_eq(_read_password(_make_backend()), "")


func test_editor_settings_shadow_project_settings() -> void:
	# EditorSettings present (fake injected) → its password wins even when
	# ProjectSettings holds a different value. This is the precedence that
	# produced an OBS auth 4009 close when the two stores disagreed.
	var fake := FakeEditorSettings.new()
	fake.set_v(PASSWORD_KEY, TEST_PASSWORD)
	ProjectSettings.set_setting(PASSWORD_KEY, "shadowed")
	var backend: BackendOBS = _make_backend()
	backend._editor_settings = fake
	assert_eq(_read_password(backend), TEST_PASSWORD)


func test_project_settings_reads_through_typed_reader() -> void:
	ProjectSettings.set_setting(PASSWORD_KEY, TEST_PASSWORD)
	assert_eq(_make_backend()._get_setting_string(PASSWORD_KEY, "default"), TEST_PASSWORD)


func test_port_reader_falls_back_to_default() -> void:
	assert_eq(_make_backend()._get_obs_settings().get("port", 0), OBSClient.DEFAULT_PORT)


## ───────────────────────────────────────────────────────────────────────────

## An always-present file so the binary-install fakes resolve deterministically,
## independent of whether OBS is installed on the runner.
const EXISTING_BINARY := "res://addons/GdTimeMachine/plugin.gd"
const MISSING_BINARY := "/nonexistent/gd_time_machine_obs_binary"
## The exact message OBSClient._describe_connect_failure() produces for close
## code 4009 — what the probe's on_fail lambda must capture, not discard.
const AUTH_FAIL_MESSAGE := "Authentication failed — OBS rejected the password (close code 4009)"


## Fake OBSClient whose connect_to_obs() never opens a socket: with
## fail_message set it emits connection_failed synchronously (probe capture is
## deterministic); otherwise it jumps straight to READY. send_request() records
## the call and replies synchronously via signal so request→response wiring runs
## without a live OBS.
class FakeOBSClient:
	extends OBSClient
	var fail_message := ""
	var respond_result := true
	var respond_code := OBSClient.STATUS_SUCCESS
	var respond_data := {}
	var requests: Array = []

	func connect_to_obs(
		_host: String = OBSClient.DEFAULT_HOST,
		_port: int = OBSClient.DEFAULT_PORT,
		_password: String = ""
	) -> int:
		if not fail_message.is_empty():
			connection_failed.emit(fail_message)
			return ERR_CONNECTION_ERROR
		_state = OBSClient.State.READY
		return OK

	func send_request(
		request_type: String, request_data: Dictionary = {}, request_id: String = ""
	) -> String:
		if request_id == "":
			request_id = "req_%d" % _next_request_id
			_next_request_id += 1
		requests.append([request_type, request_data, request_id])
		var rid := request_id
		var ok := respond_result
		var code := respond_code
		var data: Dictionary = respond_data
		# A real OBS answers asynchronously, so the backend's
		# _pending_request_id/_kind are already assigned by the time a reply
		# lands. Emit one frame later to preserve that ordering; tests wait on
		# the resulting backend signal (wait_for_signal), not on frame counts.
		var tree := get_tree()
		if tree == null:
			request_completed.emit(rid, ok, code, data)
			return rid
		tree.process_frame.connect(
			func() -> void: request_completed.emit(rid, ok, code, data), CONNECT_ONE_SHOT
		)
		return rid


## Neutralized BackendOBS for binary/availability tests. _ready() is a no-op
## (base's editor-only probe wiring never runs headless anyway); settings and
## the binary resolve are injected. probe_obs_async() is stubbed to a counter
## so is_available()/is_obs_running() dynamics are deterministic.
class FakeBackendOBS:
	extends BackendOBS
	var binary_path := ""
	var stub_resolve := ""
	var force_missing := false
	var resolve_calls := 0
	var probe_calls := 0
	var fake_now := 0.0

	func _ready() -> void:
		pass

	func _get_obs_settings() -> Dictionary:
		return {"binary_path": binary_path, "auto_launch": true}

	func probe_obs_async() -> void:
		probe_calls += 1
		_probe_in_flight = false
		_last_probe_time = _now()

	func _resolve_obs_binary() -> String:
		resolve_calls += 1
		if force_missing:
			return ""
		if not stub_resolve.is_empty():
			return stub_resolve
		if not binary_path.is_empty():
			return binary_path
		return ""

	func _now() -> float:
		return fake_now


## End-to-end start/stop backend. is_obs_installed() resolves to EXISTING_BINARY
## (or empty), _create_obs_client() returns the configurable FakeOBSClient, and
## the scene is faked via the playing flag so start() can drive the
## pending-start and begin-recording paths deterministically. A successful
## "launch" returns a pretend pid; _probe_once() uses the fake client, so ensure
## is exercised (no real launch, no real WebSocket).
class RecordingBackend:
	extends BackendOBS
	var installed := true
	var playing := false
	var play_calls: Array = []
	var kill_calls := 0
	var client_fail_message := ""
	var fake_now := 0.0

	func _ready() -> void:
		pass

	func _get_obs_settings() -> Dictionary:
		return {
			"host": OBSClient.DEFAULT_HOST,
			"port": OBSClient.DEFAULT_PORT,
			"password": "",
			"scene": "",
			"auto_launch": true,
			"binary_path": "",
		}

	func _is_playing_scene() -> bool:
		return playing

	func _play_scene(scene_path: String) -> void:
		play_calls.append(scene_path)

	func _resolve_obs_binary() -> String:
		if not installed:
			return ""
		return ProjectSettings.globalize_path(EXISTING_BINARY)

	func probe_obs_async() -> void:
		_probe_in_flight = false
		_last_probe_time = _now()

	func _create_obs_client() -> OBSClient:
		var client := FakeOBSClient.new()
		client.fail_message = client_fail_message
		return client

	func _launch_obs_process(_binary: String) -> int:
		return 4711

	func _kill_process(_pid: int) -> void:
		kill_calls += 1

	func _now() -> float:
		return fake_now


## Deterministic launch loop: fake clock + immediate _sleep advance fake_now, so
## ensure_obs_running()'s 10 s wait collapses to a bounded iteration count.
class LaunchTestBackend:
	extends BackendOBS
	var launch_calls := 0
	var kill_calls := 0
	var probe_ok := false
	var fake_now := 0.0

	func _ready() -> void:
		pass

	func _get_obs_settings() -> Dictionary:
		return {"auto_launch": true, "binary_path": ""}

	func _resolve_obs_binary() -> String:
		return ProjectSettings.globalize_path(EXISTING_BINARY)

	func probe_obs_async() -> void:
		_probe_in_flight = false
		_last_probe_time = _now()

	func _probe_once() -> bool:
		return probe_ok

	func _launch_obs_process(_binary: String) -> int:
		launch_calls += 1
		return 4711

	func _kill_process(_pid: int) -> void:
		kill_calls += 1

	func _now() -> float:
		return fake_now

	func _sleep(seconds: float) -> void:
		fake_now += seconds


## BackendOBS with a stubbed client factory + binary resolve so the real
## probe_obs_async()/start() wiring runs against FakeOBSClient. Keeps the base
## probe/start paths so _last_connect_error capture and the start() error
## assembly are exercised end-to-end.
class ProbeFailureBackend:
	extends BackendOBS
	var auth_fail_message := ""

	func _ready() -> void:
		pass

	func _get_obs_settings() -> Dictionary:
		return {
			"host": OBSClient.DEFAULT_HOST,
			"port": OBSClient.DEFAULT_PORT,
			"password": "",
			"auto_launch": true,
		}

	func _resolve_obs_binary() -> String:
		return ProjectSettings.globalize_path(EXISTING_BINARY)

	func _create_obs_client() -> OBSClient:
		var client := FakeOBSClient.new()
		client.fail_message = auth_fail_message
		return client

	func _launch_obs_process(_binary: String) -> int:
		return 0  # pretend the spawn failed → ensure_obs_running() bails out


func _make_fake_backend() -> FakeBackendOBS:
	return add_child_autofree(FakeBackendOBS.new())


func _make_recording_backend() -> RecordingBackend:
	return add_child_autofree(RecordingBackend.new())


func _make_launch_backend() -> LaunchTestBackend:
	return add_child_autofree(LaunchTestBackend.new())


func _make_probe_backend() -> ProbeFailureBackend:
	return add_child_autofree(ProbeFailureBackend.new())


func _obs_path(name: String) -> String:
	return "res://media/captures/obs/%s.mp4" % name


# --- contract ---


func test_contract_reports_in_place_mp4_only_backend() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_backend_name(), "OBS Studio")
	assert_false(backend.get_description().is_empty())
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)
	assert_false(backend.is_recording())
	assert_eq(backend.get_native_formats(), [GdTMOutputFormat.Format.MP4])
	# is_available() is the probe cache — never true merely because a binary
	# would resolve.
	assert_false(backend.is_available())


# --- two-axis availability ---


func test_is_obs_installed_true_when_binary_exists() -> void:
	var backend := _make_fake_backend()
	backend.binary_path = ProjectSettings.globalize_path(EXISTING_BINARY)
	assert_true(backend.is_obs_installed())
	assert_false(backend.is_available(), "install must not imply reachability (two-axis lock)")


func test_is_obs_installed_false_when_binary_missing() -> void:
	var backend := _make_fake_backend()
	backend.force_missing = true
	assert_false(backend.is_obs_installed())


func test_binary_resolves_exactly_once_across_calls() -> void:
	var backend := _make_fake_backend()
	backend.stub_resolve = ProjectSettings.globalize_path(EXISTING_BINARY)
	assert_true(backend.is_obs_installed())
	assert_true(backend.is_obs_installed())
	assert_eq(backend.resolve_calls, 1)


func test_is_available_is_probe_cache_never_binary() -> void:
	# Reachable wins even when the binary would not resolve…
	var reachable := _make_fake_backend()
	reachable.force_missing = true
	reachable._available = true
	assert_true(reachable.is_available())
	# …and an installed binary alone never makes the probe cache true.
	var installed := _make_fake_backend()
	installed.binary_path = ProjectSettings.globalize_path(EXISTING_BINARY)
	assert_false(installed.is_available())


func test_is_obs_running_reprobes_only_when_stale() -> void:
	var backend := _make_fake_backend()
	backend.fake_now = 10.0
	backend._last_probe_time = 10.0  # fresh
	backend._available = true
	assert_true(backend.is_obs_running())
	assert_eq(backend.probe_calls, 0, "fresh cache must not re-probe")
	backend._last_probe_time = 2.0  # > 5 s stale
	assert_true(backend.is_obs_running())
	assert_eq(backend.probe_calls, 1, "stale cache must force a fresh probe")


# --- ensure_obs_running (launch/ownership) ---


func test_ensure_obs_running_returns_true_without_launch_when_reachable() -> void:
	var backend := _make_launch_backend()
	backend._available = true
	var result = await backend.ensure_obs_running()
	assert_true(result)
	assert_eq(backend.launch_calls, 0, "reachable OBS must not be (re)launched")
	assert_false(backend._we_launched)


func test_ensure_obs_running_launches_and_owns_launched_obs() -> void:
	var backend := _make_launch_backend()
	backend.probe_ok = true
	var result = await backend.ensure_obs_running()
	assert_true(result)
	assert_eq(backend.launch_calls, 1)
	assert_true(backend._we_launched)
	assert_eq(backend.kill_calls, 0)


func test_ensure_obs_running_kills_own_process_on_timeout() -> void:
	var backend := _make_launch_backend()
	backend.probe_ok = false
	var result = await backend.ensure_obs_running()
	assert_false(result)
	assert_eq(backend.launch_calls, 1)
	assert_eq(backend.kill_calls, 1, "must kill only the OBS it launched")
	assert_false(backend._we_launched)
	assert_eq(backend._launched_pid, 0)


# --- start() paths ---


func test_start_not_installed_emits_actionable_error() -> void:
	var backend := _make_recording_backend()
	backend.installed = false
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_missing"})
	assert_signal_emitted(backend, "recording_error")
	var params = get_signal_parameters(backend, "recording_error")
	assert_true(
		str(params[1]).contains("OBS Studio not found"),
		"not-installed error must say so, got: '%s'" % params[1],
	)
	assert_false(backend.is_recording())


func test_start_rejects_non_native_format() -> void:
	var backend := _make_recording_backend()
	watch_signals(backend)
	await backend.start(
		{"output_path": "res://media/captures/obs/obs_fmt", "output_format": "webm"}
	)
	assert_signal_emitted(backend, "recording_error")
	var params = get_signal_parameters(backend, "recording_error")
	assert_true(str(params[1]).contains("MP4"), "got: '%s'" % params[1])
	assert_signal_not_emitted(backend, "recording_started")


func test_start_happy_path_emits_recording_started() -> void:
	var backend := _make_recording_backend()
	backend.playing = true
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_happy"})
	# wait_for_signal, not wait_frames: the StartRecord reply rides a
	# process_frame one-shot while GUT's wait_frames clocks physics frames,
	# and headless process↔physics interleaving let the reply miss the short
	# window (recording stayed pending, recording_started never fired).
	assert_true(
		await wait_for_signal(backend.recording_started, REPLY_BUDGET),
		"the StartRecord reply must arrive",
	)
	assert_signal_emitted_with_parameters(
		backend, "recording_started", ["OBS Studio", _obs_path("obs_happy")]
	)
	assert_true(backend.is_recording())
	var client := backend._obs_client as FakeOBSClient
	assert_eq(client.requests[0][0], "StartRecord")
	assert_eq(client.requests[0][1], {})


func test_start_pending_start_launches_scene_then_records() -> void:
	# Scene not playing → _play_scene + pending-start poll; when the scene
	# starts, _on_poll_timeout() begins recording.
	var backend := _make_recording_backend()
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_pending"})
	assert_eq(backend.play_calls, [""])
	assert_true(backend._pending_start)
	assert_signal_not_emitted(backend, "recording_started")
	backend.playing = true
	backend._on_poll_timeout()
	assert_true(
		await wait_for_signal(backend.recording_started, REPLY_BUDGET),
		"the pending-start path must send StartRecord and get the reply after the scene plays",
	)
	assert_false(backend._pending_start)
	assert_signal_emitted(backend, "recording_started")


func test_pending_start_expiry_emits_error() -> void:
	var backend := _make_recording_backend()
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_expire", "duration": 3.0})
	assert_true(backend._pending_start)
	backend._on_duration_timeout()
	assert_signal_emitted_with_parameters(
		backend,
		"recording_error",
		["OBS Studio", "Scene did not start playing before the duration elapsed"],
	)
	assert_false(backend.is_recording())


func test_duration_auto_stops_recording() -> void:
	var backend := _make_recording_backend()
	backend.playing = true
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_dur", "duration": 5.0})
	assert_true(
		await wait_for_signal(backend.recording_started, REPLY_BUDGET),
		"the StartRecord reply must arrive before the duration path is exercised",
	)
	assert_signal_emitted(backend, "recording_started")
	backend._on_duration_timeout()
	assert_true(
		await wait_for_signal(backend.recording_stopped, REPLY_BUDGET),
		"the duration auto-stop must complete its StopRecord reply",
	)
	assert_signal_emitted(backend, "recording_stopped")
	assert_false(backend.is_recording())


# --- stop()/single emission/no-kill ---


func test_stop_never_kills_and_emits_once() -> void:
	var backend := _make_recording_backend()
	backend.playing = true
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_stop"})
	assert_true(
		await wait_for_signal(backend.recording_started, REPLY_BUDGET),
		"the StartRecord reply must arrive before stop() is exercised",
	)
	assert_signal_emitted(backend, "recording_started")
	backend.stop()
	assert_true(
		await wait_for_signal(backend.recording_stopped, REPLY_BUDGET),
		"the StopRecord reply (not the 3 s fallback timer) must finalize the stop",
	)
	assert_signal_emitted_with_parameters(
		backend, "recording_stopped", ["OBS Studio", _obs_path("obs_stop")]
	)
	var client := backend._obs_client as FakeOBSClient
	assert_eq(client.requests[1][0], "StopRecord")
	assert_eq(backend.kill_calls, 0, "IN_PLACE stop must never kill the game")
	assert_false(backend.is_recording())
	backend.stop()
	assert_signal_emit_count(backend, "recording_stopped", 1, "single emission funnel")


func test_stop_while_pending_start_finalizes_without_connecting() -> void:
	var backend := _make_recording_backend()
	watch_signals(backend)
	await backend.start({"output_path": "res://media/captures/obs/obs_pendstop"})
	assert_true(backend._pending_start)
	backend.stop()
	assert_signal_emitted_with_parameters(
		backend, "recording_stopped", ["OBS Studio", _obs_path("obs_pendstop")]
	)
	assert_eq(backend.kill_calls, 0)


# --- file move fallback ---


func test_file_move_falls_back_to_output_dir_when_output_path_is_bare_name() -> void:
	var dir := "user://gdtm_test_move"
	var src := dir.path_join("shoot.mp4")
	var dst := dir.path_join("cap.mp4")
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(src, FileAccess.WRITE).store_string("x")
	var backend := _make_recording_backend()
	backend._output_dir = dir
	backend._output_path = dir.path_join("cap")
	backend._intermediate_path = dst
	backend._actual_obs_output = "shoot.mp4"
	backend._resolve_and_move_output()
	assert_true(FileAccess.file_exists(dst), "clipped file must be moved into output_dir")
	assert_false(FileAccess.file_exists(src), "source must be renamed away")
	DirAccess.remove_absolute(src)
	DirAccess.remove_absolute(dst)
	DirAccess.remove_absolute(dir)


# --- error surfacing ---


func test_probe_failure_captures_last_connect_error() -> void:
	var backend := _make_probe_backend()
	backend.auth_fail_message = AUTH_FAIL_MESSAGE
	backend.probe_obs_async()
	await wait_process_frames(1)
	assert_true(
		backend._last_connect_error.contains("Authentication failed"),
		"probe must capture the auth failure message, got: '%s'" % backend._last_connect_error,
	)
	assert_false(backend._available, "auth-rejected probe must stay unavailable")


func test_start_error_surfaces_auth_failure_with_password_guidance() -> void:
	var backend := _make_probe_backend()
	backend.auth_fail_message = AUTH_FAIL_MESSAGE
	watch_signals(backend)
	await backend.start({})
	# Auth failure propagates synchronously; the tick is just a settle buffer.
	await wait_process_frames(1)
	assert_signal_emitted(backend, "recording_error")
	var params = get_signal_parameters(backend, "recording_error")
	var error_message := str(params[1])
	assert_true(
		error_message.contains("Authentication failed"),
		"start() error must surface the auth failure, got: '%s'" % error_message,
	)
	assert_true(
		error_message.contains("gd_time_machine/obs/password"),
		"start() error must point at the password setting, got: '%s'" % error_message,
	)


func test_start_error_stays_generic_without_connect_failure() -> void:
	var backend := _make_probe_backend()
	var msg := backend._describe_start_error()
	assert_false(msg.contains("Authentication failed"), "good: '%s'" % msg)
	assert_true(msg.contains("port 4455"), "generic hint must remain, got: '%s'" % msg)
