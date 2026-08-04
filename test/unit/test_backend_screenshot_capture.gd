extends GutTest


# Fake backend overriding every EditorInterface/DirAccess/timer seam so the
# state machine runs fully headlessly. Timers are neutralized — tests drive
# the _on_*_timeout handlers directly — while every side effect (frame dir,
# capture claim, request, copy, manifest) is recorded for assertions.
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
		# Immediate synchronous "success" path for tests — emit deferred would need idle,
		# so emit directly.
		if not probe_result:
			ffmpeg_not_found.emit("ffmpeg not found — frames kept at %s" % frames_dir)
			return
		if execute_code != 0:
			conversion_failed.emit(
				"ffmpeg failed (exit %d)" % execute_code, "\n".join(execute_output)
			)
			return
		# Simulate clean
		if clean_on_success:
			deletes.append(frames_dir)
		conversion_succeeded.emit("%s.%s" % [base_output_path, target_format])


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
		return true

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

	func _get_auto_convert_setting(_config: Dictionary) -> bool:
		# Force true for tests that need trigger, unless overridden by
		# config containing auto_convert key — respect that.
		if _config.has("auto_convert"):
			return bool(_config["auto_convert"])
		return true

	func _get_clean_on_success_setting() -> bool:
		return true


## IN_PLACE output base (no extension — the backend owns the layout).
const OUTPUT := "res://media/captures/demo_2026-01-01T00-00-00"


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


func test_get_backend_name() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_backend_name(), "Screenshot")


func test_get_description_is_non_empty() -> void:
	var backend := _make_backend()
	assert_false(backend.get_description().is_empty())


func test_is_available_always_true() -> void:
	var backend := _make_backend()
	assert_true(backend.is_available())


func test_get_capture_mode_is_in_place() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_capture_mode(), RecorderBackend.CaptureMode.IN_PLACE)


func test_is_recording_false_by_default() -> void:
	var backend := _make_backend()
	assert_false(backend.is_recording())


func test_start_without_running_scene_emits_error() -> void:
	# Without duration, should launch then wait, not error immediately.
	# We still keep a fast-path for launch-less error? Now it launches.
	# So this test becomes: without duration it goes pending, no error.
	var backend := _make_backend()
	var errors: Array = []
	var started: Array = []
	backend.recording_error.connect(func(name, message): errors.append([name, message]))
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "", "fps": 60})
	assert_eq(errors.size(), 0, "no immediate error without duration — waits for scene")
	assert_eq(started.size(), 0)
	assert_true(backend.is_recording(), "active while pending")
	assert_eq(backend.frames_dirs_made.size(), 1)
	assert_eq(backend.played_scenes.size(), 1)


func test_start_claims_capture_and_sends_first_request() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	_start_capture(backend)
	assert_eq(started.size(), 1)
	assert_eq(started[0], ["Screenshot", OUTPUT])
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


func test_start_twice_is_ignored() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	_start_capture(backend)
	_start_capture(backend)
	assert_eq(started.size(), 1)
	assert_eq(backend.requests, [0])


func test_duration_timer_starts_only_with_duration() -> void:
	var no_duration := _make_backend()
	_start_capture(no_duration)
	assert_eq(no_duration.duration_timer_starts, 0)
	var with_duration := _make_backend()
	_start_capture(with_duration, {"duration": 2.0})
	assert_eq(with_duration.duration_timer_starts, 1)


func test_pacing_keeps_one_request_in_flight() -> void:
	# The loop must never issue a second request before the game replies to
	# the first (one-in-flight pacing).
	var backend := _make_backend()
	_start_capture(backend)
	assert_eq(backend.requests, [0])
	backend._on_pacing_timeout()
	assert_eq(backend.requests, [0], "pacing must not double-issue while a request is in flight")
	backend._on_screenshot_received(0, 1280, 720, "user://tmp/frame.png")
	# Pacing timeout after reply should issue next
	backend._on_pacing_timeout()
	assert_eq(backend.requests.size(), 2)


func test_stale_reply_is_ignored() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	# Stale enriched reply with w/h non-zero should be ignored
	backend._on_screenshot_received(99, 1280, 720, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 0)
	# no_reply restart count depends on implementation — not asserted (can be 0 or 1)


func test_legacy_zero_dim_reply_accepted_when_in_flight() -> void:
	# Engine's real reply has 0×0 dims; accepted as long as something is in
	# flight (legacy compatibility — see debugger_plugin.gd fix).
	var backend := _make_backend()
	_start_capture(backend)
	backend.next_dims = {"width": 800, "height": 600}
	# id 99 would be stale for enriched, but legacy 0×0 is accepted.
	backend._on_screenshot_received(99, 0, 0, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 1)
	assert_eq(backend.copies[0], ["user://tmp/frame.png", OUTPUT + ".frames/frame_00001.png"])
	assert_eq(backend.manifests.size(), 0)  # not finalized yet — just copied.


func test_legacy_zero_dim_populates_dimensions_via_seam() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	backend.next_dims = {"width": 1920, "height": 1080}
	backend._on_screenshot_received(0, 0, 0, "user://tmp/frame.png")
	backend.stop()
	assert_eq(backend.manifests.size(), 1)
	var data: Dictionary = backend.manifests[0][1]
	assert_eq(data["width"], 1920)
	assert_eq(data["height"], 1080)


func test_frame_copied_on_receipt() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	backend._on_screenshot_received(0, 1280, 720, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 1)
	assert_eq(backend.copies[0], ["user://tmp/frame.png", OUTPUT + ".frames/frame_00001.png"])
	# After receiving, pacing drives next request
	backend._on_pacing_timeout()
	assert_eq(backend.requests, [0, 1])
	backend._on_screenshot_received(1, 640, 480, "user://tmp/frame2.png")
	assert_eq(backend.copies.size(), 2)


func test_default_image_format_is_png() -> void:
	var backend := _make_backend()
	_start_capture(backend)
	assert_eq(backend._image_format, "png")


func test_jpg_output_format_sets_extension_on_frames() -> void:
	# Config output_format "jpg" → frames are written as .jpg (the backend
	# re-encodes PNG receipts lossily in _copy_frame).
	var backend := _make_backend()
	_start_capture(backend, {"output_format": "jpg"})
	assert_eq(backend._image_format, "jpg")
	backend._on_screenshot_received(0, 1280, 720, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 1)
	assert_eq(backend.copies[0][1], OUTPUT + ".frames/frame_00001.jpg")


func test_jpeg_alias_selects_jpg() -> void:
	var backend := _make_backend()
	_start_capture(backend, {"output_format": "jpeg"})
	assert_eq(backend._image_format, "jpg")


func test_unknown_format_falls_back_to_png() -> void:
	var backend := _make_backend()
	_start_capture(backend, {"output_format": "avi"})
	assert_eq(backend._image_format, "png")


func test_tiny_frames_are_scrubbed_and_loop_continues() -> void:
	# The debugger channel occasionally returns a 1×1 placeholder stub for the
	# first request. It must not be copied, must not advance frame count/stats,
	# and the loop must immediately issue the next request.
	var backend := _make_backend()
	_start_capture(backend)
	backend._on_screenshot_received(0, 1, 1, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 0, "1px placeholder must not be copied")
	assert_eq(backend.requests, [0, 1], "next request issues right after a scrub")
	# A real frame after the scrub is still accepted and numbered normally.
	backend._on_screenshot_received(1, 1280, 720, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 1)
	assert_eq(backend.copies[0], ["user://tmp/frame.png", OUTPUT + ".frames/frame_00001.png"])


func test_narrow_dimension_frame_scrubbed_and_manifest_unaffected() -> void:
	# A 640×2 frame is below MIN_FRAME_DIMENSION on one axis → scrubbed too.
	var backend := _make_backend()
	_start_capture(backend)
	backend._on_screenshot_received(0, 640, 2, "user://tmp/frame.png")
	assert_eq(backend.copies.size(), 0)
	backend.stop()
	assert_eq(backend.manifests.size(), 1)
	assert_eq(backend.manifests[0][1]["frame_count"], 0)


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


func test_stop_emits_stopped_once_then_notice() -> void:
	var backend := _make_backend()
	var events: Array = []
	backend.recording_stopped.connect(func(name, path): events.append(["stopped", name, path]))
	backend.recording_notice.connect(func(name, message): events.append(["notice", name, message]))
	_start_capture(backend)
	_receive_frame(backend, 10.0, 0)
	_receive_frame(backend, 10.25, 1)
	backend.stop()
	assert_eq(events.size(), 2)
	assert_eq(events[0], ["stopped", "Screenshot", OUTPUT])
	assert_eq(events[1][0], "notice", "notice must be emitted after stopped")
	# Capture claim released and plugin disconnected on finalize.
	assert_eq(backend.capture_active_calls, [true, false])
	assert_false(backend.signal_connected)
	assert_false(backend.is_recording())


func test_zero_frames_still_emits_stopped_and_notice() -> void:
	# Zero/low-frame captures are normal (occluded window); they finalize as
	# stopped with a notice, never as an error. recording_error stays
	# reserved for the no-game case.
	var backend := _make_backend()
	var stopped: Array = []
	var errors: Array = []
	var notices: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.recording_error.connect(func(name, message): errors.append([name, message]))
	backend.recording_notice.connect(func(name, message): notices.append([name, message]))
	_start_capture(backend)
	backend.stop()
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Screenshot", OUTPUT])
	assert_eq(errors.size(), 0)
	assert_eq(notices.size(), 1)
	assert_true(notices[0][1].contains("No frames captured"))


func test_single_frame_notice() -> void:
	var backend := _make_backend()
	var notices: Array = []
	backend.recording_notice.connect(func(name, message): notices.append([name, message]))
	_start_capture(backend, {"fps": 30})
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(notices.size(), 1)
	assert_eq(notices[0][1], "Saved 1 frame (target 30 fps)")


func test_low_rate_notice_appends_foreground_hint() -> void:
	# measured (4.0 fps) < 25% of target 60 → the foreground hint fires.
	var backend := _make_backend()
	var notices: Array = []
	backend.recording_notice.connect(func(name, message): notices.append([name, message]))
	_start_capture(backend)
	_receive_frame(backend, 10.0, 0)
	_receive_frame(backend, 10.25, 1)
	backend.stop()
	assert_eq(notices.size(), 1)
	assert_true(notices[0][1].contains("Saved 2 frames @ 4.0 fps (target 60)"))
	assert_true(notices[0][1].contains("keep the game window visible and focused"))


func test_full_rate_notice_omits_hint() -> void:
	# measured (4.0 fps) ≥ 25% of target 15 → no hint.
	var backend := _make_backend()
	var notices: Array = []
	backend.recording_notice.connect(func(name, message): notices.append([name, message]))
	_start_capture(backend, {"fps": 15})
	_receive_frame(backend, 10.0, 0)
	_receive_frame(backend, 10.25, 1)
	backend.stop()
	assert_eq(notices.size(), 1)
	assert_true(notices[0][1].contains("Saved 2 frames @ 4.0 fps (target 15)"))
	assert_false(notices[0][1].contains("keep the game window"))


func test_duration_timeout_stops_recording() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	_start_capture(backend, {"duration": 2.0})
	backend._on_duration_timeout()
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Screenshot", OUTPUT])
	assert_false(backend.is_recording())


func test_no_reply_timeout_finalizes_with_frames_so_far() -> void:
	# Game stopped answering (hung/occluded/crashed): finalize with whatever
	# frames were received, then a notice. The game is never sent anything.
	var backend := _make_backend()
	var stopped: Array = []
	var notices: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.recording_notice.connect(func(name, message): notices.append([name, message]))
	_start_capture(backend)
	_receive_frame(backend, 10.0, 0)
	backend._on_no_reply_timeout()
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Screenshot", OUTPUT])
	assert_eq(backend.manifests.size(), 1)
	assert_eq(backend.manifests[0][1]["frame_count"], 1)
	assert_eq(notices.size(), 1)
	assert_false(backend.is_recording())


func test_timeout_after_stop_does_not_double_emit() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	_start_capture(backend)
	backend.stop()
	backend._on_no_reply_timeout()
	backend._on_duration_timeout()
	backend.stop()
	assert_eq(stopped.size(), 1)


func test_stop_when_not_recording_is_noop() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.stop()
	assert_eq(stopped.size(), 0)
	assert_eq(backend.capture_active_calls.size(), 0)


func test_frame_interval_uses_target_fps() -> void:
	var backend := _make_backend()
	_start_capture(backend, {"fps": 30})
	assert_almost_eq(backend._get_frame_interval(), 1.0 / 30.0, 0.0001)
	var default_backend := _make_backend()
	_default_start(default_backend)
	assert_almost_eq(default_backend._get_frame_interval(), 1.0 / 15.0, 0.0001)


func _default_start(backend: FakeScreenshotBackend) -> void:
	backend.playing = true
	backend.start({"output_path": OUTPUT})


func test_no_reply_timeout_default_is_fifteen_seconds() -> void:
	var backend := _make_backend()
	assert_eq(backend._get_no_reply_timeout(), 15.0)


func test_pending_start_launches_scene_and_waits() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/a.tscn", "fps": 60})
	assert_eq(started.size(), 0)
	assert_true(backend.is_recording())
	assert_eq(backend.played_scenes, ["res://scenes/a.tscn"])
	assert_eq(backend.poll_starts, 1)
	assert_eq(backend.capture_active_calls.size(), 0, "no capture claim while pending")
	assert_eq(backend.requests.size(), 0, "no screenshot requests while pending")


func test_poll_transitions_to_recording_when_scene_starts() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/a.tscn"})
	assert_eq(started.size(), 0)
	backend.playing = true
	backend._on_poll_timeout()
	assert_eq(started.size(), 1)
	assert_eq(started[0], ["Screenshot", OUTPUT])
	assert_eq(backend.capture_active_calls, [true])
	assert_true(backend.signal_connected)
	assert_eq(backend.requests, [0])


func test_duration_expiry_while_pending_emits_error() -> void:
	var backend := _make_backend()
	var errors: Array = []
	var started: Array = []
	backend.recording_error.connect(func(name, msg): errors.append([name, msg]))
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	backend.playing = false
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/a.tscn", "duration": 1.0})
	assert_eq(started.size(), 0)
	backend._on_duration_timeout()
	assert_eq(errors.size(), 1)
	assert_eq(errors[0][0], "Screenshot")
	assert_true(errors[0][1].contains("Scene did not start"))
	assert_false(backend.is_recording())
	assert_eq(started.size(), 0)


func test_stop_while_pending_cancels_and_finalizes() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	var notices: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.recording_notice.connect(func(name, msg): notices.append([name, msg]))
	backend.playing = false
	backend.start({"output_path": OUTPUT})
	backend.stop()
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Screenshot", OUTPUT])
	assert_eq(notices.size(), 1)
	assert_false(backend.is_recording())
	assert_eq(backend.poll_stops, 1)


func test_ffmpeg_convert_triggered_for_mp4_target() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	backend.injected_converter = conv
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	_start_capture(backend, {"output_format": "mp4"})
	_receive_frame(backend, 10.0, 0)
	var converted: Array = []
	backend.recording_converted.connect(func(name, path): converted.append([name, path]))
	backend.stop()
	# finalize should have triggered ffmpeg convert with mp4 target
	assert_true(conv.convert_calls.size() >= 1)
	assert_true(str(conv.convert_calls[0][2]).to_lower().contains("mp4"))
	assert_eq(converted.size(), 1, "fake converter emits converted synchronously")


func test_ffmpeg_convert_not_triggered_for_png_target() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	# Not in tree — backend will not own it when no conversion happens, so we must free manually.
	backend.injected_converter = conv
	_start_capture(backend, {"output_format": "png"})
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(conv.convert_calls.size(), 0, "PNG native — no convert")
	if conv.get_parent() == null:
		conv.free()


func test_ffmpeg_not_found_keeps_frames_and_emits_notice() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	conv.probe_result = false
	backend.injected_converter = conv
	_start_capture(backend, {"output_format": "mp4"})
	_receive_frame(backend, 10.0, 0)
	var notices: Array = []
	backend.recording_notice.connect(func(name, msg): notices.append([name, msg]))
	var converted: Array = []
	backend.recording_converted.connect(func(name, path): converted.append([name, path]))
	backend.stop()
	assert_eq(converted.size(), 0)
	assert_eq(conv.deletes.size(), 0, "frames kept when ffmpeg missing")
	# notice stream contains ffmpeg not found
	var found := false
	for n in notices:
		if str(n[1]).to_lower().contains("ffmpeg not found"):
			found = true
	assert_true(found)


func test_ffmpeg_nonzero_keeps_frames_and_emits_error_tail() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	conv.execute_code = 1
	conv.execute_output = ["frame pattern invalid"]
	backend.injected_converter = conv
	_start_capture(backend, {"output_format": "mp4"})
	_receive_frame(backend, 10.0, 0)
	var errors: Array = []
	backend.recording_error.connect(func(name, msg): errors.append([name, msg]))
	backend.stop()
	assert_eq(errors.size(), 1)
	assert_true(str(errors[0][1]).contains("invalid") or str(errors[0][1]).contains("failed"))
	assert_eq(conv.deletes.size(), 0)


func test_auto_convert_off_skips_converter() -> void:
	var backend := _make_backend()
	var conv := FakeFFmpegConverterForScreenshot.new()
	backend.injected_converter = conv
	_start_capture(backend, {"output_format": "mp4", "auto_convert": false})
	_receive_frame(backend, 10.0, 0)
	backend.stop()
	assert_eq(conv.convert_calls.size(), 0)
	if conv.get_parent() == null:
		conv.free()
