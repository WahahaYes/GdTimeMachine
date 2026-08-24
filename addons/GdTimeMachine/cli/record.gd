extends SceneTree

## Editor record entry — reuses backend wiring (requires EditorInterface).
## For headless CLI batch, use core/movie_writer.gd via cli/main.gd (no EditorInterface).

const RecorderController := preload("res://addons/GdTimeMachine/controller/recorder_controller.gd")
const BackendOBS := preload("res://addons/GdTimeMachine/backend/backend_obs.gd")
const BackendScreenshotCapture := preload(
	"res://addons/GdTimeMachine/backend/backend_screenshot_capture.gd"
)
const BackendMovieMaker := preload("res://addons/GdTimeMachine/backend/backend_movie_maker.gd")
const GdTMFFmpegConvert := preload("res://addons/GdTimeMachine/backend/ffmpeg_convert.gd")

var _args: PackedStringArray


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		var all := OS.get_cmdline_args()
		var sep := all.find("--")
		if sep != -1:
			args = all.slice(sep + 1)
	_args = args


func _initialize() -> void:
	if _args.is_empty():
		printerr(
			"record: missing args, usage: --scene res://... --output <path> [--duration N] [--fps N] [--backend NAME]"
		)
		quit(1)
		return
	var scene := _get_arg("--scene", "")
	var output := _get_arg("--output", "")
	var duration_s := _get_arg("--duration", "0")
	var fps_s := _get_arg("--fps", "60")
	var backend_name := _get_arg("--backend", "OBS Studio")
	if scene.is_empty() or output.is_empty():
		printerr("record: --scene and --output are required")
		quit(1)
		return
	var duration := float(duration_s) if duration_s.is_valid_float() else 0.0
	var fps := int(fps_s) if fps_s.is_valid_int() else 60
	# Defer to _ready-like via call_deferred to ensure tree is ready
	call_deferred("_run_record", scene, output, duration, fps, backend_name)


func _get_arg(name: String, default: String) -> String:
	for i in range(_args.size()):
		if String(_args[i]) == name and i + 1 < _args.size():
			return String(_args[i + 1])
		if String(_args[i]).begins_with(name + "="):
			return String(_args[i]).substr(name.length() + 1)
	return default


func _run_record(
	scene: String, output: String, duration: float, fps: int, backend_name: String
) -> void:
	print(
		(
			"record: scene=%s output=%s duration=%s fps=%d backend=%s"
			% [scene, output, str(duration), fps, backend_name]
		)
	)
	print("record: editor path (requires EditorInterface)")
	# Editor path — reuses same wiring as plugin
	var controller := RecorderController.new()
	var backends_to_register: Array = []
	var obs_backend := BackendOBS.new()
	var screenshot_backend := BackendScreenshotCapture.new()
	var movie_backend := BackendMovieMaker.new()
	backends_to_register = [movie_backend, screenshot_backend, obs_backend]
	for b in backends_to_register:
		controller.register_backend(b)
	var names := controller.get_backend_names()
	if backend_name not in names:
		print(
			(
				"record: backend '%s' not found, available: %s — using %s"
				% [
					backend_name,
					", ".join(names),
					str(names[0]) if not names.is_empty() else "none"
				]
			)
		)
		backend_name = str(names[0]) if not names.is_empty() else ""
	else:
		controller.select_backend(backend_name)
	# Add controller to tree so backends get _ready and signals
	root.add_child(controller)
	# Also add our own root for signal handling
	var output_dir := output.get_base_dir()
	if not output_dir.is_empty() and not DirAccess.dir_exists_absolute(output_dir):
		DirAccess.make_dir_recursive_absolute(output_dir)
	var output_path_no_ext := output
	if (
		output.ends_with(".avi")
		or output.ends_with(".mp4")
		or output.ends_with(".webm")
		or output.ends_with(".ogv")
	):
		output_path_no_ext = output.substr(0, output.rfind("."))
	var config := {
		"output_path": output_path_no_ext,
		"output_dir": output_dir,
		"scene_path": scene,
		"duration": duration,
		"fps": fps,
	}
	# Connect signals
	var success := false
	var error_msg := ""
	var done := false
	controller.recording_started.connect(
		func(_bn: String, _path: String): print("record: started %s" % _path)
	)
	controller.recording_stopped.connect(
		func(_bn: String, _path: String):
			print("record: stopped %s" % _path)
			success = true
			done = true
	)
	controller.recording_error.connect(
		func(_bn: String, msg: String):
			printerr("record: error %s" % msg)
			error_msg = msg
			done = true
	)
	controller.recording_converted.connect(
		func(_bn: String, clip: String):
			print("record: converted %s" % clip)
			success = true
			done = true
	)
	# For IN_PLACE backends, need to handle that they may need scene to be playing
	# For RESTART_SCENE, controller will handle via _play_scene
	print("record: starting with backend %s" % backend_name)
	controller.start_recording(config)
	# Wait for result with timeout: duration + 10s buffer, max 60s
	var timeout := duration + 10.0 if duration > 0 else 30.0
	timeout = min(timeout, 60.0)
	var start_ticks := Time.get_ticks_msec()
	while not done and (Time.get_ticks_msec() - start_ticks) / 1000.0 < timeout:
		await process_frame
		# Also handle that some backends may need manual stop at duration
		if (
			duration > 0
			and controller.is_recording()
			and (Time.get_ticks_msec() - start_ticks) / 1000.0 >= duration + 2.0
		):
			print("record: duration reached, stopping")
			controller.stop_recording()
			await process_frame
			# Give stop time
			var stop_start := Time.get_ticks_msec()
			while controller.is_recording() and (Time.get_ticks_msec() - stop_start) / 1000.0 < 5.0:
				await process_frame
			done = true
			success = true
			break
	if not done:
		# If still recording after timeout, try to stop
		if controller.is_recording():
			print("record: timeout, forcing stop")
			controller.stop_recording()
			var stop_start2 := Time.get_ticks_msec()
			while (
				controller.is_recording() and (Time.get_ticks_msec() - stop_start2) / 1000.0 < 5.0
			):
				await process_frame
			success = true
			done = true
		else:
			# No signal received, check if error already
			if not error_msg.is_empty():
				printerr("record: failed %s" % error_msg)
				quit(1)
				return
			# For some backends (MovieMaker), recording may have completed without stopped signal yet
			# Check output file exists
			var check_path := (
				output if FileAccess.file_exists(output) else output_path_no_ext + ".avi"
			)
			if (
				FileAccess.file_exists(check_path)
				or FileAccess.file_exists(output_path_no_ext + ".mp4")
			):
				print("record: output exists, assuming success")
				success = true
			else:
				printerr("record: no output and no signal, assuming failure")
				quit(1)
				return
	if success:
		print("record: success")
		quit(0)
	else:
		printerr("record: failed %s" % error_msg)
		quit(1)
