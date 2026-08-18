@tool
extends GutTest

## BackendScreenshotCapture tests: the IN_PLACE capture state machine, frame
## receipt handling (copy/scrub/rq-mismatch), stats/notice composition, the
## pending-start flow, and the ffmpeg tier-2 handoff. All synchronous — the
## fake backend neutralizes every EditorInterface/DirAccess/timer seam and
## records side effects for assertions; timeout handlers are driven directly.

## IN_PLACE output base (no extension — the backend owns the layout).
const OUTPUT := "res://media/captures/demo_2026-01-01T00-00-00"


## Fake converter: records the convert call and emits synchronously so stop()
## hands off to tier-2 without any async/thread involvement.
class FakeFFmpegConverterForScreenshot:
	extends GdTMFFmpegConvert
	var probe_result := true
	var execute_code := 0
	var execute_output: Array = []
	var deletes: Array = []
	var convert_calls: Array = []

	func probe_ffmpeg() -> bool:
		return probe_result

	func convert_frames_async(
		frames_dir: String,
		base_output_path: String,
		target_format: String,
		measured_fps: float,
		frame_ext: String,
		clean_on_success: bool = true
	) -> void:
		convert_calls.append(
			[frames_dir, base_output_path, target_format, measured_fps, frame_ext, clean_on_success]
		)
		if not probe_result:
			ffmpeg_not_found.emit("ffmpeg not found — frames kept at %s" % frames_dir)
			return
		if execute_code != 0:
			conversion_failed.emit(
				"ffmpeg failed (exit %d)" % execute_code, "\n".join(execute_output)
			)
			return
		if clean_on_success:
			deletes.append(frames_dir)
		conversion_succeeded.emit("%s.%s" % [base_output_path, target_format])


## Backend under test: every environment/timer seam is a recorded no-op or a
## test-driven stub.
class FakeScreenshotBackend:
	extends BackendScreenshotCapture
	var playing := false
	var fake_now := 0.0
	var capture_active_calls: Array = []
	var signal_connected := false
	var requests: Array = []
	var frames_dirs_made: Array = []
	var copies: Array = []
	var manifests: Array = []
	var pacing_starts := 0
	var duration_timer_starts := 0
	var no_reply_starts := 0
	var no_reply_restarts := 0
	var poll_starts := 0
	var poll_stops := 0
	var played_scenes: Array = []
	var next_dims := {"width": 1280, "height": 720}
	var injected_converter: FakeFFmpegConverterForScreenshot = null
	# When false, _send_screenshot_request reports failure (request denied).
	var send_ok := true

	func _is_playing_scene() -> bool:
		return playing

	func _now() -> float:
		return fake_now

	func _make_frames_dir(path: String) -> void:
		frames_dirs_made.append(path)

	func _set_screenshot_capture_active(active: bool) -> void:
		capture_active_calls.append(active)

	func _connect_screenshot_signal() -> void:
		signal_connected = true

	func _disconnect_screenshot_signal() -> void:
		signal_connected = false

	func _send_screenshot_request(rq_id: int) -> bool:
		requests.append(rq_id)
		return send_ok

	func _copy_frame(src: String, dst: String) -> void:
		copies.append([src, dst])

	func _write_json_file(path: String, data: Dictionary) -> void:
		manifests.append([path, data])

	func _get_image_dimensions(_path: String) -> Dictionary:
		return next_dims

	func _play_scene(scene_path: String) -> void:
		played_scenes.append(scene_path)

	func _start_polling() -> void:
		poll_starts += 1

	func _stop_polling() -> void:
		poll_stops += 1

	func _start_pacing() -> void:
		pacing_starts += 1

	func _start_duration_timer() -> void:
		duration_timer_starts += 1

	func _start_no_reply_timer() -> void:
		no_reply_starts += 1

	func _restart_no_reply_timer() -> void:
		no_reply_restarts += 1

	func _stop_pacing() -> void:
		pass

	func _stop_duration_timer() -> void:
		pass

	func _stop_no_reply_timer() -> void:
		pass

	func _create_ffmpeg_converter() -> GdTMFFmpegConvert:
		if injected_converter != null:
			return injected_converter
		injected_converter = FakeFFmpegConverterForScreenshot.new()
		return injected_converter

	func _get_auto_convert_setting(config: Dictionary) -> bool:
		if config.has("auto_convert"):
			return bool(config["auto_convert"])
		return true

	func _get_clean_on_success_setting() -> bool:
		return true


func _make_backend() -> FakeScreenshotBackend:
	return add_child_autofree(FakeScreenshotBackend.new())


func _start_capture(backend: FakeScreenshotBackend, overrides: Dictionary = {}) -> void:
	var config := {"output_path": OUTPUT, "fps": 60}
	config.merge(overrides, true)
	backend.playing = true
	backend.start(config)


## Delivers a frame reply as the plugin would: sets the fake clock, feeds
## _on_screenshot_received with the in-flight request id, then lets the
## pacing tick issue the next request (mirrors the real loop).
func _receive_frame(
	backend: FakeScreenshotBackend, t: float, rq_id: int, width := 1280, height := 720
) -> void:
	backend.fake_now = t
	backend._on_screenshot_received(rq_id, width, height, "user://tmp/frame.png")
	backend._on_pacing_timeout()


## Contract


func test_contract_name_in_place_and_always_available() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_backend_name(), "Screenshot")
	assert_true(backend.is_available())
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)
	assert_false(backend.is_recording())


func test_description_mentions_real_time_capture() -> void:
	# Tooltip contract: the backend must state its real-time capture semantics
	# (machine-bound rate, window must stay visible).
	var backend: BackendScreenshotCapture = add_child_autofree(BackendScreenshotCapture.new())
	assert_string_contains(backend.get_description().to_lower(), "real-time")


## Start


func test_start_claims_capture_and_sends_first_request() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(_n: String, path: String) -> void: started.append(path))
	_start_capture(backend)
	assert_eq(started, [OUTPUT])
	assert_true(backend.is_recording())
	assert_eq(backend.frames_dirs_made, [OUTPUT + ".frames"])
	assert_eq(backend.capture_active_calls, [true])
	assert_true(backend.signal_connected)
	assert_eq(backend.requests, [0])
	assert_eq(backend.pacing_starts, 1)
	assert_eq(backend.no_reply_starts, 1)


func test_start_defaults_output_path_when_empty() -> void:
	var backend := _make_backend()
	backend.playing = true
	backend.start({"fps": 60})
	assert_eq(backend.frames_dirs_made, [BackendScreenshotCapture.DEFAULT_OUTPUT_PATH + ".frames"])


func test_start_without_running_scene_launches_and_waits() -> void:
	# No scene playing → pending-start: launch the scene, no error, no capture
	# claim and no requests until playback begins.
	var backend := _make_backend()
	var errors: Array = []
	var started: Array = []
	backend.recording_error.connect(func(_n: String, _m: String) -> void: errors.append(true))
	backend.recording_started.connect(func(_n: String, _p: String) -> void: started.append(true))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/a.tscn", "fps": 60})
	assert_eq(errors.size(), 0, "no immediate error — waits for the scene")
	assert_eq(started.size(), 0)
	assert_true(backend.is_recording(), "active while pending")
	assert_eq(backend.frames_dirs_made.size(), 1)
	assert_eq(backend.played_scenes, ["res://scenes/a.tscn"])
	assert_eq(backend.poll_starts, 1)
	assert_eq(backend.capture_active_calls.size(), 0, "no capture claim while pending")
	assert_eq(backend.requests.size(), 0, "no screenshot requests while pending")


func test_start_twice_is_ignored() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(_n: String, _p: String) -> void: started.append(true))
	_start_capture(backend)
	_start_capture(backend)
	assert_push_warning("already recording")
	assert_eq(started.size(), 1)
	assert_eq(backend.requests, [0])


func test_duration_timer_starts_only_with_duration() -> void:
	var no_duration := _make_backend()
	_start_capture(no_duration)
	assert_eq(no_duration.duration_timer_starts, 0)
	var with_duration := _make_backend()
	_start_capture(with_duration, {"duration": 2.0})
	assert_eq(with_duration.duration_timer_starts, 1)


## Request loop


func test_pacing_keeps_one_request_in_flight() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	assert_eq(backend.requests, [0])
	backend._on_pacing_timeout()
	assert_eq(backend.requests, [0], "pacing must not double-issue while in flight")
	backend._on_screenshot_received(0, 1280, 720, "user://tmp/frame.png")
	backend._on_pacing_timeout()
	assert_eq(backend.requests, [0, 1])


func test_stale_reply_is_ignored() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	backend._on_screenshot_received(99, 1280, 720, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 0)


func test_denied_request_retries_without_consuming_rq_id() -> void:
	# When the send seam reports failure the request must not be consumed and
	# never become an error: in-flight stays -1 so the retry reuses the same id.
	var backend := _make_backend()
	var errors: Array = []
	backend.recording_error.connect(func(_n: String, _m: String) -> void: errors.append(true))
	backend.send_ok = false
	_start_capture(backend)
	assert_eq(errors.size(), 0, "denied send is not an error")
	assert_true(backend.is_recording(), "capture claim stays active")
	assert_eq(backend._in_flight_rq_id, -1, "failed send must not consume the request id")
	assert_eq(backend._next_rq_id, 0, "denied send must not advance the rq id counter")
	assert_eq(backend.no_reply_restarts, 1, "no-reply timer re-armed after denied send")
	backend.send_ok = true
	backend._on_pacing_timeout()
	assert_eq(backend._in_flight_rq_id, 0, "retry reuses the unconsumed request id")
	assert_eq(backend.requests, [0, 0])


## Frame receipt


func test_frame_copied_on_receipt() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	backend._on_screenshot_received(0, 1280, 720, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 1)
	assert_eq(backend.copies[0], ["user://tmp/frame.png", OUTPUT + ".frames/frame_00001.png"])
	backend._on_pacing_timeout()
	assert_eq(backend.requests, [0, 1])
	backend._on_screenshot_received(1, 640, 480, "user://tmp/frame2.png")
	assert_eq(backend.copies.size(), 2)


func test_legacy_zero_dim_reply_accepted_and_dimensions_filled() -> void:
	# The engine's real reply carries 0×0 dims; accepted while something is in
	# flight, with dimensions filled via the seam for the manifest.
	var backend := _make_backend()
	_start_capture(backend)
	backend.next_dims = {"width": 1920, "height": 1080}
	backend._on_screenshot_received(0, 0, 0, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 1, "legacy 0×0 reply still copies the frame")
	backend.stop()
	assert_eq(backend.manifests.size(), 1)
	assert_eq(backend.manifests[0][1]["width"], 1920)
	assert_eq(backend.manifests[0][1]["height"], 1080)


func test_image_format_selection() -> void:
	# "jpg"/"jpeg" → frames re-encoded as .jpg; anything else stays .png.
	var jpg := _make_backend()
	_start_capture(jpg, {"output_format": "jpg"})
	assert_eq(jpg._image_format, "jpg")
	jpg._on_screenshot_received(0, 1280, 720, "user://tmp/frame.png")
	assert_eq(jpg.copies[0][1], OUTPUT + ".frames/frame_00001.jpg")
	var jpeg := _make_backend()
	_start_capture(jpeg, {"output_format": "jpeg"})
	assert_eq(jpeg._image_format, "jpg")
	var fallback := _make_backend()
	_start_capture(fallback, {"output_format": "avi"})
	assert_eq(fallback._image_format, "png")


func test_tiny_and_narrow_frames_scrubbed_loop_continues() -> void:
	# The debugger channel sometimes returns a 1×1 placeholder; anything below
	# MIN_FRAME_DIMENSION on either axis is scrubbed (no copy, no stats), and
	# the loop immediately issues the next request.
	var backend := _make_backend()
	_start_capture(backend)
	backend._on_screenshot_received(0, 1, 1, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 0, "1px placeholder must not be copied")
	assert_eq(backend.requests, [0, 1], "next request issues right after a scrub")
	backend._on_screenshot_received(1, 640, 2, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 0, "narrow frame scrubbed too")
	backend.stop()
	assert_eq(backend.manifests[0][1]["frame_count"], 0, "scrubs never reach the manifest")


## Stop / finalize


func test_manifest_written_on_stop() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	_receive_frame(backend, 10.0, 0)
	_receive_frame(backend, 10.25, 1)
	backend.stop()
	assert_eq(backend.manifests.size(), 1)
	assert_eq(backend.manifests[0][0], OUTPUT + ".frames/manifest.json")
	var data: Dictionary = backend.manifests[0][1]
	assert_eq(data["frame_count"], 2)
	assert_eq(data["target_fps"], 60)
	assert_almost_eq(data["measured_fps"], 4.0, 0.001)
	assert_almost_eq(data["elapsed_sec"], 0.25, 0.001)
	assert_eq(data["width"], 1280)
	assert_eq(data["height"], 720)


func test_stop_emits_once_then_notice_and_releases_capture() -> void:
	var backend := _make_backend()
	var events: Array = []
	backend.recording_stopped.connect(
		func(_n: String, p: String) -> void: events.append(["stopped", p])
	)
	backend.recording_notice.connect(
		func(_n: String, m: String) -> void: events.append(["notice", m])
	)
	_start_capture(backend)
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(events.size(), 2)
	assert_eq(events[0], ["stopped", OUTPUT])
	assert_eq(events[1][0], "notice", "notice must be emitted after stopped")
	assert_eq(backend.capture_active_calls, [true, false])
	assert_false(backend.signal_connected)
	assert_false(backend.is_recording())


func test_notice_composition_zero_single_and_rate_hint() -> void:
	var notices: Array = []
	var zero := _make_backend()
	zero.recording_notice.connect(func(_n: String, m: String) -> void: notices.append(m))
	_start_capture(zero)
	zero.stop()
	assert_true(notices[0].contains("No frames captured"))

	notices = []
	var single := _make_backend()
	single.recording_notice.connect(func(_n: String, m: String) -> void: notices.append(m))
	_start_capture(single, {"fps": 30})
	_receive_frame(single, 10.0, 0)
	single.stop()
	assert_eq(notices[0], "Saved 1 frame (target 30 fps)")

	notices = []
	var low := _make_backend()
	low.recording_notice.connect(func(_n: String, m: String) -> void: notices.append(m))
	_start_capture(low, {"fps": 60})
	_receive_frame(low, 10.0, 0)
	_receive_frame(low, 10.25, 1)
	low.stop()
	# measured 4.0 < 25% of target 60 → foreground hint appended.
	assert_true(notices[0].contains("Saved 2 frames @ 4.0 fps (target 60)"))
	assert_true(notices[0].contains("keep the game window visible and focused"))

	notices = []
	var full := _make_backend()
	full.recording_notice.connect(func(_n: String, m: String) -> void: notices.append(m))
	_start_capture(full, {"fps": 15})
	_receive_frame(full, 10.0, 0)
	_receive_frame(full, 10.25, 1)
	full.stop()
	# measured 4.0 ≥ 25% of target 15 → no hint.
	assert_true(notices[0].contains("Saved 2 frames @ 4.0 fps (target 15)"))
	assert_false(notices[0].contains("keep the game window"))


func test_duration_timeout_stops_recording() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(_n: String, p: String) -> void: stopped.append(p))
	_start_capture(backend, {"duration": 2.0})
	backend._on_duration_timeout()
	assert_eq(stopped, [OUTPUT])
	assert_false(backend.is_recording())


func test_no_reply_timeout_finalizes_with_frames_so_far() -> void:
	# Game stopped answering: finalize with whatever frames were received,
	# then a notice — the game is never sent anything.
	var backend := _make_backend()
	var stopped: Array = []
	var notices: Array = []
	backend.recording_stopped.connect(func(_n: String, p: String) -> void: stopped.append(p))
	backend.recording_notice.connect(func(_n: String, m: String) -> void: notices.append(m))
	_start_capture(backend)
	_receive_frame(backend, 10.0, 0)
	backend._on_no_reply_timeout()
	assert_eq(stopped, [OUTPUT])
	assert_eq(backend.manifests[0][1]["frame_count"], 1)
	assert_eq(notices.size(), 1)
	assert_false(backend.is_recording())


func test_timeout_after_stop_does_not_double_emit() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(_n: String, _p: String) -> void: stopped.append(true))
	_start_capture(backend)
	backend.stop()
	backend._on_no_reply_timeout()
	backend._on_duration_timeout()
	backend.stop()
	assert_eq(stopped.size(), 1)


func test_stop_when_not_recording_is_noop() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(_n: String, _p: String) -> void: stopped.append(true))
	backend.stop()
	assert_eq(stopped.size(), 0)
	assert_eq(backend.capture_active_calls.size(), 0)


func test_frame_interval_uses_target_fps() -> void:
	var backend := _make_backend()
	_start_capture(backend, {"fps": 30})
	assert_almost_eq(backend._get_frame_interval(), 1.0 / 30.0, 0.0001)
	var default_backend := _make_backend()
	default_backend.playing = true
	default_backend.start({"output_path": OUTPUT})
	assert_almost_eq(default_backend._get_frame_interval(), 1.0 / 15.0, 0.0001)


func test_no_reply_timeout_default_is_fifteen_seconds() -> void:
	var backend := _make_backend()
	assert_eq(backend._get_no_reply_timeout(), 15.0)


## Pending-start flow


func test_poll_transitions_to_recording_when_scene_starts() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(_n: String, p: String) -> void: started.append(p))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/a.tscn"})
	assert_eq(started.size(), 0)
	backend.playing = true
	backend._on_poll_timeout()
	assert_eq(started, [OUTPUT])
	assert_eq(backend.capture_active_calls, [true])
	assert_true(backend.signal_connected)
	assert_eq(backend.requests, [0])


func test_duration_expiry_while_pending_emits_error() -> void:
	var backend := _make_backend()
	var errors: Array = []
	backend.recording_error.connect(func(_n: String, m: String) -> void: errors.append(m))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/a.tscn", "duration": 1.0})
	backend._on_duration_timeout()
	assert_eq(errors.size(), 1)
	assert_true(errors[0].contains("Scene did not start"))
	assert_false(backend.is_recording())


func test_stop_while_pending_cancels_and_finalizes() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	var notices: Array = []
	backend.recording_stopped.connect(func(_n: String, p: String) -> void: stopped.append(p))
	backend.recording_notice.connect(func(_n: String, _m: String) -> void: notices.append(true))
	backend.playing = false
	backend.start({"output_path": OUTPUT})
	backend.stop()
	assert_eq(stopped, [OUTPUT])
	assert_eq(notices.size(), 1)
	assert_false(backend.is_recording())
	assert_eq(backend.poll_stops, 1)


## ffmpeg tier-2 handoff


func test_ffmpeg_convert_triggered_for_mp4_target() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	backend.injected_converter = conv
	var converted: Array = []
	backend.recording_converted.connect(func(_n: String, p: String) -> void: converted.append(p))
	_start_capture(backend, {"output_format": "mp4"})
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(conv.convert_calls.size(), 1)
	assert_true(str(conv.convert_calls[0][2]).to_lower().contains("mp4"))
	assert_eq(converted.size(), 1, "fake converter emits converted synchronously")


func test_ffmpeg_convert_not_triggered_for_native_or_disabled() -> void:
	var png := _make_backend()
	var conv_png := FakeFFmpegConverterForScreenshot.new()
	png.injected_converter = conv_png
	_start_capture(png, {"output_format": "png"})
	_receive_frame(png, 10.0, 0)
	png.stop()
	assert_eq(conv_png.convert_calls.size(), 0, "PNG native — no convert")
	conv_png.free()

	var off := _make_backend()
	var conv_off := FakeFFmpegConverterForScreenshot.new()
	off.injected_converter = conv_off
	_start_capture(off, {"output_format": "mp4", "auto_convert": false})
	_receive_frame(off, 10.0, 0)
	off.stop()
	assert_eq(conv_off.convert_calls.size(), 0, "auto_convert off — no convert")
	conv_off.free()


func test_ffmpeg_not_found_keeps_frames_and_emits_notice() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	conv.probe_result = false
	backend.injected_converter = conv
	var notices: Array = []
	backend.recording_notice.connect(func(_n: String, m: String) -> void: notices.append(m))
	var converted: Array = []
	backend.recording_converted.connect(
		func(_n: String, _p: String) -> void: converted.append(true)
	)
	_start_capture(backend, {"output_format": "mp4"})
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(converted.size(), 0)
	assert_eq(conv.deletes.size(), 0, "frames kept when ffmpeg missing")
	var found := false
	for n in notices:
		if str(n).to_lower().contains("ffmpeg not found"):
			found = true
	assert_true(found)


func test_ffmpeg_failure_emits_error_with_tail_and_keeps_frames() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	conv.execute_code = 1
	conv.execute_output = ["frame pattern invalid"]
	backend.injected_converter = conv
	var errors: Array = []
	backend.recording_error.connect(func(_n: String, m: String) -> void: errors.append(m))
	_start_capture(backend, {"output_format": "mp4"})
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(errors.size(), 1)
	assert_true(errors[0].contains("invalid") or errors[0].contains("failed"))
	assert_eq(conv.deletes.size(), 0)
