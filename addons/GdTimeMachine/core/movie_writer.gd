class_name GdTMMovieWriter
extends RefCounted


## Records scene in worktree_path via `godot --write-movie` (Vulkan, no --headless). Converts AVI→mp4/webm via ffmpeg if requested. Returns 0 on success.
static func record(
	worktree_path: String,
	scene: String,
	output: String,
	fps: int,
	duration: float,
	godot_bin: String
) -> int:
	var output_dir := output.get_base_dir()
	if not output_dir.is_empty() and not DirAccess.dir_exists_absolute(output_dir):
		DirAccess.make_dir_recursive_absolute(output_dir)
	var movie_path := output
	if movie_path.get_extension().to_lower() in ["mp4", "webm"]:
		movie_path = movie_path.substr(0, movie_path.rfind(".")) + ".avi"
	elif movie_path.get_extension().is_empty():
		movie_path += ".avi"
	print("movie_writer: %s -> %s (%d fps, duration %s)" % [scene, movie_path, fps, str(duration)])
	var args := PackedStringArray(
		["--path", worktree_path, "--write-movie", movie_path, "--fixed-fps", str(fps)]
	)
	if duration > 0:
		args.append("--quit-after")
		args.append(str(int(duration * fps)))
	args.append(scene)
	var pid := OS.create_process(godot_bin, args)
	if pid <= 0:
		printerr("movie_writer: failed to launch godot --write-movie")
		return 1
	var wait_ms := int((duration + 5) * 1000) if duration > 0 else 30000
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < wait_ms:
		OS.delay_msec(100)
		if not OS.is_process_running(pid):
			break
	if OS.is_process_running(pid):
		print("movie_writer: still running, killing pid %d" % pid)
		OS.kill(pid)
		OS.delay_msec(500)
	if FileAccess.file_exists(movie_path):
		print("movie_writer: output exists %s" % movie_path)
		if output.get_extension().to_lower() in ["mp4", "webm"] and output != movie_path:
			print("movie_writer: converting %s -> %s" % [movie_path, output])
			# Sync (blocking) convert: this context already blocks on
			# OS.delay_msec above, which starves call_deferred, so the async
			# API's completion signals could never be observed here. The sync
			# call probes + executes inline and needs no tree parent.
			var conv244 := preload("res://addons/GdTimeMachine/backend/ffmpeg_convert.gd").new()
			var res: Dictionary = conv244.convert_file_sync(movie_path, output, fps)
			conv244.free()
			if int(res.get("exit_code", -1)) == 0:
				print("movie_writer: converted -> %s" % res.get("output_path", output))
				return 0
			if str(res.get("reason", "")) == "not-found":
				printerr("movie_writer: ffmpeg not found — %s kept" % movie_path)
			else:
				printerr("movie_writer: ffmpeg conversion failed")
			return 1
		return 0
	else:
		printerr("movie_writer: output not found %s" % movie_path)
		return 1
