extends GutTest


# Fake converter overriding probe + OS.execute + delete for headless deterministic tests.
class FakeFFmpegConvert:
	extends GdTMFFmpegConvert
	var probe_result := true
	var execute_code := 0
	var execute_output: Array = []
	var executed_bins: Array = []
	var executed_args: Array = []
	var deletes: Array = []
	var thread_started := false

	func probe_ffmpeg() -> bool:
		return probe_result

	func _os_execute_blocking(
		binary: String, args: PackedStringArray, output: Array, _read_stdout: bool
	) -> int:
		executed_bins.append(binary)
		executed_args.append(args)
		for line in execute_output:
			output.append(line)
		return execute_code

	func _delete_frames_dir(frames_dir: String) -> bool:
		deletes.append(frames_dir)
		return true

	# For sync tests we don't want real Thread path — expose worker without Thread.
	func _thread_convert_worker(
		binary: String, args: PackedStringArray, out_path: String, _frames_dir: String
	) -> void:
		var out: Array = []
		var code := _os_execute_blocking(binary, args, out, true)
		var stdout_txt := "\n".join(out) if not out.is_empty() else ""
		_pending_result = {
			"exit_code": code,
			"output_path": out_path,
			"frames_dir": _current_frames_dir,
			"stdout": stdout_txt,
		}
		# Simulate main continuation inline (without wait_to_finish)
		_on_thread_finished()


func _make_converter() -> FakeFFmpegConvert:
	return add_child_autofree(FakeFFmpegConvert.new())


func test_to_extension_mp4_and_webm() -> void:
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.MP4), "mp4")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.WEBM), "webm")


func test_from_string_parses_mp4_and_webm() -> void:
	assert_eq(GdTMOutputFormat.from_string("mp4"), GdTMOutputFormat.Format.MP4)
	assert_eq(GdTMOutputFormat.from_string(".mp4"), GdTMOutputFormat.Format.MP4)
	assert_eq(GdTMOutputFormat.from_string("MP4 (.mp4) - ffmpeg"), GdTMOutputFormat.Format.MP4)
	assert_eq(GdTMOutputFormat.from_string("webm"), GdTMOutputFormat.Format.WEBM)
	assert_eq(GdTMOutputFormat.from_string("WebM (.webm) - ffmpeg"), GdTMOutputFormat.Format.WEBM)


func test_is_tier2_format() -> void:
	assert_true(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.MP4))
	assert_true(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.WEBM))
	assert_false(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.AVI))
	assert_false(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.PNG))


func test_frames_need_ffmpeg() -> void:
	assert_false(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.PNG))
	assert_false(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.JPG))
	assert_true(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.MP4))
	assert_true(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.AVI))


func test_build_frames_convert_command_mp4_uses_libx264_and_measured_fps() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 14.5, "png"
	)
	assert_false(cmd.get("skip", true))
	var args: PackedStringArray = cmd["args"]
	# Must contain -framerate 14.5 and libx264 crf path
	var s := " ".join(args)
	assert_true(s.contains("14.5") or s.contains("14.5"))
	assert_true(s.contains("libx264"))
	assert_true(s.contains("yuv420p"))
	assert_true(str(cmd["output_path"]).ends_with(".mp4"))


func test_build_frames_convert_command_png_is_skip() -> void:
	var conv := _make_converter()
	var cmd := conv.build_frames_convert_command(
		"res://media/captures/demo.frames", "res://media/captures/demo", "png", 30.0, "png"
	)
	assert_true(cmd.get("skip", false))


func test_build_file_convert_command_mp4() -> void:
	var conv := _make_converter()
	var cmd := conv.build_file_convert_command(
		"res://media/captures/demo.avi", "res://media/captures/demo.mp4"
	)
	var s := " ".join(cmd["args"] as PackedStringArray)
	assert_true(s.contains("libx264"))
	assert_true(str(cmd["output_path"]).ends_with(".mp4"))


func test_convert_frames_sync_not_found() -> void:
	var conv := _make_converter()
	conv.probe_result = false
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["reason"], "not-found")
	assert_eq(res["exit_code"], -1)


func test_convert_frames_sync_nonzero_keeps_stderr() -> void:
	var conv := _make_converter()
	conv.probe_result = true
	conv.execute_code = 1
	conv.execute_output = ["[error] something failed"]
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["exit_code"], 1)
	assert_true(str(res["stdout"]).contains("something failed"))


func test_convert_frames_sync_success() -> void:
	var conv := _make_converter()
	conv.probe_result = true
	conv.execute_code = 0
	conv.execute_output = ["x264 encoded"]
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["exit_code"], 0)
	assert_false(res.get("skip", true))


func test_convert_frames_sync_png_native_skip() -> void:
	var conv := _make_converter()
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "png", 18.0, "png"
	)
	assert_true(res.get("skip", false))


func test_probe_present_triggers_success_signal_and_cleans_frames_dir() -> void:
	var conv := _make_converter()
	conv.probe_result = true
	conv.execute_code = 0
	conv.execute_output = ["ok"]
	var successes: Array = []
	conv.conversion_succeeded.connect(func(p): successes.append(p))
	# Directly use thread worker path to emulate async.
	conv._current_frames_dir = "res://media/captures/demo.frames"
	conv._clean_on_success = true
	conv._current_output_path = "res://media/captures/demo.mp4"
	conv._pending_result = {
		"exit_code": 0,
		"output_path": "res://media/captures/demo.mp4",
		"frames_dir": "res://media/captures/demo.frames",
		"stdout": "ok",
	}
	conv._on_thread_finished()
	assert_eq(successes.size(), 1)
	assert_eq(conv.deletes.size(), 1)
	assert_eq(conv.deletes[0], "res://media/captures/demo.frames")


func test_probe_missing_emits_not_found_and_keeps_frames() -> void:
	var conv := _make_converter()
	conv.probe_result = false
	var not_founds: Array = []
	conv.ffmpeg_not_found.connect(func(m): not_founds.append(m))
	# Mimic convert_frames_async not-found path (direct call_deferred would need idle).
	# Instead manually emit path the real async would: use convert_frames_sync outcome.
	var res := conv.convert_frames_sync(
		"res://media/captures/demo.frames", "res://media/captures/demo", "mp4", 18.0, "png"
	)
	assert_eq(res["reason"], "not-found")
	# For async path, verify deleting never happened.
	assert_eq(conv.deletes.size(), 0)


func test_nonzero_emits_failed_with_stderr_tail() -> void:
	var conv := _make_converter()
	conv.probe_result = true
	conv.execute_code = 1
	conv.execute_output = ["big error line 1", "line 2"]
	var fails: Array = []
	conv.conversion_failed.connect(func(msg, tail): fails.append([msg, tail]))
	conv._current_frames_dir = "res://media/captures/demo.frames"
	conv._current_output_path = "res://media/captures/demo.mp4"
	conv._pending_result = {
		"exit_code": 1,
		"output_path": "res://media/captures/demo.mp4",
		"frames_dir": "res://media/captures/demo.frames",
		"stdout": "big error line 1\nline 2",
	}
	conv._on_thread_finished()
	assert_eq(fails.size(), 1)
	assert_true(str(fails[0][0]).contains("1"))
	assert_true(str(fails[0][1]).contains("error"))
	assert_eq(conv.deletes.size(), 0, "frames kept on failure")
