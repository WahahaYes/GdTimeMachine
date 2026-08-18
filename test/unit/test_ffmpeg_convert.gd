@tool
extends GutTest

## GdTMFFmpegConvert tests: binary probe, command builders, sync convert paths,
## and worker result/emission logic through the _os_execute_blocking seams. The
## async entry points (real Thread) are not exercised; their continuations are
## tested directly. Output-format classification lives in test_output_format.gd.


## Fake converter: deterministic OS.execute result, recorded argv, and a
## recorded delete seam. Probe is exercised through the real probe_ffmpeg()
## (which calls _os_execute_blocking with ["-version"]), not overridden.
class FakeFFmpegConvert:
	extends GdTMFFmpegConvert
	var probe_code := 0
	var execute_code := 0
	var execute_output: Array = []
	var executed: Array = []
	var deletes: Array = []
	var quality := -1.0

	func _get_ffmpeg_binary() -> String:
		return "ffmpeg"

	func _get_video_quality() -> float:
		return quality

	func _os_execute_blocking(
		binary: String, args: PackedStringArray, output: Array, _read_stdout: bool
	) -> int:
		executed.append([binary, args])
		for line in execute_output:
			output.append(line)
		# The probe is the `-version` call; the convert exit comes from
		# execute_code so a probe can pass while the convert itself fails.
		if args.size() == 1 and args[0] == "-version":
			return probe_code
		return execute_code

	func _delete_frames_dir(frames_dir: String) -> bool:
		deletes.append(frames_dir)
		return true


## Members capture signal payloads: GDScript lambdas capture outer locals BY
## VALUE in this Godot version, so lambdas write through self.
var _captured_success_paths: Array = []
var _captured_failures: Array = []


func before_each() -> void:
	_captured_success_paths = []
	_captured_failures = []


func _make_converter() -> FakeFFmpegConvert:
	return autofree(FakeFFmpegConvert.new())


## Probe


func test_probe_returns_true_when_version_call_succeeds() -> void:
	var conv := _make_converter()
	conv.execute_code = 0
	assert_true(conv.probe_ffmpeg())
	# The probe is an execute of `ffmpeg -version`, not a convert command.
	assert_eq(conv.executed[0][0], "ffmpeg")
	var args: PackedStringArray = conv.executed[0][1]
	assert_eq(args, PackedStringArray(["-version"]))


func test_probe_returns_false_when_version_call_fails() -> void:
	var conv := _make_converter()
	conv.probe_code = 127
	assert_false(conv.probe_ffmpeg())


## Native-frames classification


func test_frames_native_target_recognizes_png_jpg_jpeg() -> void:
	var conv := _make_converter()
	assert_true(conv._is_frames_native_target("png"))
	assert_true(conv._is_frames_native_target("jpg"))
	assert_true(conv._is_frames_native_target("jpeg"))
	assert_true(conv._is_frames_native_target(".png"))
	assert_true(conv._is_frames_native_target("JPG"))


func test_frames_native_target_false_for_video_formats() -> void:
	var conv := _make_converter()
	assert_false(conv._is_frames_native_target("mp4"))
	assert_false(conv._is_frames_native_target("webm"))
	assert_false(conv._is_frames_native_target("avi"))
	assert_false(conv._is_frames_native_target("ogv"))


## Frames command builder


func test_frame_command_mp4_uses_measured_fps_and_libx264() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 14.5, "png"
	)
	assert_false(cmd.get("skip", true))
	var s := " ".join(cmd["args"])
	assert_true(s.contains("14.5"))
	assert_true(s.contains("-start_number 1"))
	assert_true(s.contains(".frames/frame_%05d.png"))
	assert_true(s.contains("-y"))
	assert_true(s.contains("libx264"))
	assert_true(s.contains("yuv420p"))
	assert_true(s.contains("+faststart"))
	assert_true(str(cmd["output_path"]).ends_with(".mp4"))
	var out_abs := ProjectSettings.globalize_path("res://media/captures/demo.mp4")
	assert_true(cmd["args"][cmd["args"].size() - 1] == out_abs)


func test_frame_command_falls_back_to_15_fps_when_measured_zero() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 0.0, "png"
	)
	assert_true(" ".join(cmd["args"]).contains("15"))


func test_frame_command_png_native_returns_skip() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "png", 30.0, "png"
	)
	assert_true(cmd.get("skip", false))
	assert_true(str(cmd.get("reason", "")).contains("native"))


func test_frame_command_webm_uses_vp9() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "webm", 30.0, "png"
	)
	var s := " ".join(cmd["args"])
	assert_true(s.contains("libvpx-vp9"))
	assert_true(s.contains("-crf 31"))
	assert_true(str(cmd["output_path"]).ends_with(".webm"))


func test_frame_command_avi_uses_mjpeg() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "avi", 30.0, "png"
	)
	assert_true(" ".join(cmd["args"]).contains("mjpeg"))
	assert_true(str(cmd["output_path"]).ends_with(".avi"))


## CRF mapping


func test_crf_for_quality_maps_settings_to_crf_range() -> void:
	var conv := _make_converter()
	conv.quality = -1.0
	assert_eq(conv._crf_for_quality(), conv.DEFAULT_CRF)
	conv.quality = 1.0
	assert_eq(conv._crf_for_quality(), conv.DEFAULT_CRF)
	conv.quality = 0.0
	assert_eq(conv._crf_for_quality(), 28)
	conv.quality = 0.5
	assert_eq(conv._crf_for_quality(), 23)


## File command builder


func test_file_command_mp4_uses_libx264_aac_and_abs_paths() -> void:
	var conv := _make_converter()
	var cmd := conv.build_file_convert_command(
		"res://media/captures/demo.avi", "res://media/captures/demo.mp4"
	)
	var crf := str(conv._crf_for_quality())
	var expected := PackedStringArray(
		[
			"-i",
			ProjectSettings.globalize_path("res://media/captures/demo.avi"),
			"-y",
			"-c:v",
			"libx264",
			"-crf",
			crf,
			"-pix_fmt",
			"yuv420p",
			"-movflags",
			"+faststart",
			"-c:a",
			"aac",
			ProjectSettings.globalize_path("res://media/captures/demo.mp4"),
		]
	)
	assert_eq(cmd["args"], expected)
	assert_eq(cmd["output_path"], "res://media/captures/demo.mp4")
	assert_false(cmd.get("skip", true))


func test_file_command_webm_forces_fps_filter_when_target_fps_given() -> void:
	var conv := _make_converter()
	var cmd := conv.build_file_convert_command(
		"res://media/captures/demo.mp4", "res://media/captures/demo.webm", 30
	)
	var s := " ".join(cmd["args"])
	assert_true(s.contains("-vf"))
	assert_true(s.contains("fps=30"))


func test_file_command_avi_uses_rate_flag_for_target_fps() -> void:
	var conv := _make_converter()
	var cmd := conv.build_file_convert_command(
		"res://media/captures/demo.mp4", "res://media/captures/demo.avi", 30
	)
	var s := " ".join(cmd["args"])
	assert_true(s.contains("-r 30"))
	assert_true(s.contains("mjpeg"))


## Sync convert paths


func test_convert_frames_sync_reports_not_found_when_probe_fails() -> void:
	var conv := _make_converter()
	conv.probe_code = 127
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["reason"], "not-found")
	assert_eq(res["exit_code"], -1)


func test_convert_frames_sync_success_joins_stdout() -> void:
	var conv := _make_converter()
	conv.execute_code = 0
	conv.execute_output = ["x264 encoded", "done"]
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["exit_code"], 0)
	assert_false(res.get("skip", true))
	assert_eq(res["stdout"], "x264 encoded\ndone")


func test_convert_frames_sync_nonzero_keeps_stdout() -> void:
	var conv := _make_converter()
	conv.execute_code = 1
	conv.execute_output = ["[error] something failed"]
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["exit_code"], 1)
	assert_true(str(res["stdout"]).contains("something failed"))


func test_convert_frames_sync_png_native_skips_without_probe() -> void:
	var conv := _make_converter()
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "png", 18.0, "png"
	)
	assert_true(res.get("skip", false))
	assert_eq(res["exit_code"], 0)
	assert_eq(conv.executed.size(), 0, "native target never probes")


func test_convert_file_sync_not_found_when_probe_fails() -> void:
	var conv := _make_converter()
	conv.probe_code = 127
	var res := conv.convert_file_sync(
		"res://media/captures/demo.avi", "res://media/captures/demo.mp4"
	)
	assert_eq(res["reason"], "not-found")
	assert_eq(res["exit_code"], -1)


## Worker result/emission (main-thread continuation, no real Thread)


func _pending_success(frames_dir: String = "") -> Dictionary:
	return {
		"exit_code": 0,
		"output_path": "res://media/captures/demo.mp4",
		"frames_dir": frames_dir,
		"stdout": "ok",
	}


func test_worker_success_emits_and_cleans_frames_dir() -> void:
	var conv := _make_converter()
	conv.conversion_succeeded.connect(func(p: String) -> void: _captured_success_paths.append(p))
	conv._clean_on_success = true
	conv._pending_result = _pending_success("res://media/captures/demo.frames")
	conv._on_thread_finished()
	assert_eq(_captured_success_paths, ["res://media/captures/demo.mp4"])
	assert_eq(conv.deletes, ["res://media/captures/demo.frames"])


func test_worker_success_keeps_frames_when_clean_disabled() -> void:
	var conv := _make_converter()
	conv.conversion_succeeded.connect(func(_p: String) -> void: _captured_success_paths.append(_p))
	conv._clean_on_success = false
	conv._pending_result = _pending_success("res://media/captures/demo.frames")
	conv._on_thread_finished()
	assert_eq(_captured_success_paths.size(), 1)
	assert_eq(conv.deletes.size(), 0)


func test_worker_success_keeps_frames_when_frames_dir_empty() -> void:
	var conv := _make_converter()
	conv.conversion_succeeded.connect(func(_p: String) -> void: _captured_success_paths.append(_p))
	conv._clean_on_success = true
	conv._pending_result = _pending_success()
	conv._on_thread_finished()
	assert_eq(_captured_success_paths.size(), 1)
	assert_eq(conv.deletes.size(), 0)


func test_worker_failure_emits_failed_and_keeps_frames() -> void:
	var conv := _make_converter()
	conv.conversion_failed.connect(
		func(msg: String, tail: String) -> void: _captured_failures.append([msg, tail])
	)
	conv._clean_on_success = true
	conv._pending_result = {
		"exit_code": 1,
		"output_path": "res://media/captures/demo.mp4",
		"frames_dir": "res://media/captures/demo.frames",
		"stdout": "[error] something failed",
	}
	conv._on_thread_finished()
	assert_eq(_captured_failures.size(), 1)
	assert_true(str(_captured_failures[0][0]).contains("ffmpeg failed"))
	assert_true(str(_captured_failures[0][1]).contains("something failed"))
	assert_eq(conv.deletes.size(), 0, "frames kept on failure")


func test_worker_failure_truncates_long_stdout_tail() -> void:
	var conv := _make_converter()
	conv.conversion_failed.connect(
		func(_msg: String, tail: String) -> void: _captured_failures.append([_msg, tail])
	)
	var long_stdout := "X".repeat(conv.STDERR_TAIL_CHARS + 500)
	conv._pending_result = {
		"exit_code": 1,
		"output_path": "res://media/captures/demo.mp4",
		"frames_dir": "",
		"stdout": long_stdout,
	}
	conv._on_thread_finished()
	assert_eq(_captured_failures.size(), 1)
	assert_eq(
		str(_captured_failures[0][1]).length(),
		conv.STDERR_TAIL_CHARS,
		"tail must be capped at STDERR_TAIL_CHARS",
	)


func test_wait_for_completion_noop_when_no_thread() -> void:
	var conv := _make_converter()
	conv.wait_for_completion()  # Must not crash or hang with no worker.
	assert_null(conv._thread)
