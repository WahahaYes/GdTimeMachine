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
			var conv244 := preload("res://addons/GdTimeMachine/backend/ffmpeg_convert.gd").new()
			Engine.get_main_loop().root.add_child(conv244)
			var converted := false
			var failed := false
			conv244.conversion_succeeded.connect(func(_bn: String, clip: String): converted = true)
			conv244.conversion_failed.connect(func(_msg: String, _tail: String): failed = true)
			conv244.ffmpeg_not_found.connect(func(_msg: String): failed = true)
			conv244.convert_file_async(movie_path, output, false, fps)
			var cstart := Time.get_ticks_msec()
			while not converted and not failed and Time.get_ticks_msec() - cstart < 15000:
				OS.delay_msec(100)
			if converted:
				return 0
			else:
				printerr("movie_writer: ffmpeg conversion failed")
				return 1
		return 0
	else:
		printerr("movie_writer: output not found %s" % movie_path)
		return 1
