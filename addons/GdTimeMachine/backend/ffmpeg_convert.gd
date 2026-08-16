@tool
extends Node
class_name GdTMFFmpegConvert

## Backend-agnostic ffmpeg conversion hook (tier-2).
##
## Probe: OS.execute(ffmpeg -version) → present. Setting
## gd_time_machine/ffmpeg/path overrides PATH.
##
## Thread: blocking OS.execute inside a Thread with stdout/stderr capture array,
## call_deferred back to main, wait_to_finish() before free/_exit_tree.
## License stays arms-length — the addon never links ffmpeg.
##
## Seams: _get_ffmpeg_binary(), _os_execute_blocking(), _read_manifest_file(),
## _get_video_quality(), _delete_frames_dir() etc are overridable for GUT.

## Emitted on exit 0 after optional cleanup.
signal conversion_succeeded(output_path: String)

## Emitted when ffmpeg exits nonzero: keeps frames, error with stderr tail.
signal conversion_failed(error_message: String, stderr_tail: String)

## Emitted when ffmpeg binary is not found: frames kept, notice path.
signal ffmpeg_not_found(message: String)

## Default h264 CRF for MP4 (quality/size tradeoff).
const DEFAULT_CRF := 18

## Tail length for stderr on failure (avoid spamming huge logs).
const STDERR_TAIL_CHARS := 2000

## Whether a conversion thread is currently running.
var _thread: Thread = null

## Result populated by the worker thread and read on main via call_deferred.
var _pending_result: Dictionary = {}

## Output path of the current/last conversion (main thread).
var _current_output_path: String = ""

## Input frames dir for cleanup decision (main thread).
var _current_frames_dir: String = ""

## Whether to delete the frames dir on success. Default: true.
var _clean_on_success: bool = true

## True after _exit_tree started waiting — guards double wait.
var _finishing := false


## Returns the ffmpeg binary path: EditorSettings override if present,
## otherwise "ffmpeg" on PATH.
func _get_ffmpeg_binary() -> String:
	var custom := ""
	# EditorSettings key lives under gd_time_machine/ffmpeg/path.
	# Use Engine.get_singleton("EditorSettings") seam via EditorInterface
	# when available; fall back to ProjectSettings for testability.
	if Engine.has_singleton("EditorSettings"):
		var es: Object = Engine.get_singleton("EditorSettings")
		if es != null and es.has_method("get_setting"):
			var v: Variant = es.get_setting("gd_time_machine/ffmpeg/path")
			if v != null:
				custom = str(v).strip_edges()
	if custom.is_empty() and ProjectSettings.has_setting("gd_time_machine/ffmpeg/path"):
		var pv: Variant = ProjectSettings.get_setting("gd_time_machine/ffmpeg/path")
		if pv != null:
			custom = str(pv).strip_edges()
	if not custom.is_empty():
		return custom
	return "ffmpeg"


## Reads editor/movie_writer/video_quality (float 0..1) for quality-aware crf.
## Returns -1 when not set.
func _get_video_quality() -> float:
	if ProjectSettings.has_setting("editor/movie_writer/video_quality"):
		return float(ProjectSettings.get_setting("editor/movie_writer/video_quality"))
	return -1.0


## Whether ffmpeg is installed. Real check: "ffmpeg -version" exit 0.
## Overridable in tests: return false to simulate missing binary.
func probe_ffmpeg() -> bool:
	var bin_path := _get_ffmpeg_binary()
	var out: Array = []
	var exit_code := _os_execute_blocking(bin_path, ["-version"], out, true)
	return exit_code == 0


## Blocking OS.execute seam. Tests override to fake responses and capture args.
## Returns exit code; output array receives stdout+stderr lines when read_stdout true.
func _os_execute_blocking(
	binary: String, args: PackedStringArray, output: Array, read_stdout: bool
) -> int:
	return OS.execute(binary, args, output, read_stdout)


## Reads a text file (manifest) — seam for tests.
func _read_text_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var txt := f.get_as_text()
	f.close()
	return txt


## Deletes the frames dir on success (recursive). Returns true on success.
## Seam for tests.
func _delete_frames_dir(frames_dir: String) -> bool:
	return _delete_dir_recursive(frames_dir)


## Recursive dir delete via DirAccess — real implementation.
func _delete_dir_recursive(dir_path: String) -> bool:
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return true
	var err := DirAccess.remove_absolute(abs_dir)
	if err == OK:
		return true
	# Fallback: list and delete contents.
	var da := DirAccess.open(abs_dir)
	if da == null:
		return false
	da.list_dir_begin()
	var file_name := da.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var child := abs_dir.path_join(file_name)
			if DirAccess.dir_exists_absolute(child):
				_delete_dir_recursive(child)
			else:
				DirAccess.remove_absolute(child)
		file_name = da.get_next()
	da.list_dir_end()
	return DirAccess.remove_absolute(abs_dir) == OK


## Computes h264 crf from editor quality setting if present. Quality 0..1 maps
## 1→18 (high) 0→28 (low); -1 → DEFAULT_CRF. 1 = highest quality anchor.
func _crf_for_quality() -> int:
	var q := _get_video_quality()
	if q < 0.0:
		return DEFAULT_CRF
	# Clamp 0..1, invert: high quality (q~1) → low crf (18), low quality → high crf.
	var qn := clampf(q, 0.0, 1.0)
	if qn >= 0.99:
		return DEFAULT_CRF
	return int(round(lerpf(28.0, float(DEFAULT_CRF), qn)))


## Whether the target format is natively frames (no conversion needed).
func _is_frames_native_target(target_format: String) -> bool:
	var t := target_format.to_lower().strip_edges()
	if t.begins_with("."):
		t = t.substr(1)
	return t == "png" or t == "jpg" or t == "jpeg"


## Builds ffmpeg args for converting a frames directory into a video.
## frames_dir: absolute or res:// path to <base>.frames/
## target_format: mp4, webm, avi, ogv, png, jpg (extension or full display name parsed via
##                GdTMOutputFormat.from_string)
## measured_fps: from manifest (frame_count-1)/elapsed, not target.
## frame_ext: "png" or "jpg" — extension of frames on disk.
## Returns Dictionary: {binary: String, args: PackedStringArray, output_path: String, skip: bool, reason: String}
func build_frames_convert_command(
	frames_dir: String,
	base_output_path: String,
	target_format: String,
	measured_fps: float,
	frame_ext: String
) -> Dictionary:
	var fmt := GdTMOutputFormat.from_string(target_format)
	var ext := GdTMOutputFormat.to_extension(fmt)
	var fps := measured_fps
	if fps <= 0.0:
		fps = 15.0
	# Normalize base: strip .frames suffix if caller passed it.
	var base := base_output_path.strip_edges()
	if base.ends_with(".frames"):
		base = base.substr(0, base.length() - 7)
	# If base already has an extension that matches native frames output,
	# strip it — we always produce <base>.<ext>.
	if base.get_extension().to_lower() in ["png", "jpg", "jpeg", "avi", "ogv", "mp4", "webm"]:
		# Legacy path helper; no-op for current OBS/Movie Maker flows.
		pass
	var out_path := "%s.%s" % [base, ext]
	# Native frames → no-op.
	if not GdTMOutputFormat.frames_need_ffmpeg(fmt):
		return {
			"binary": _get_ffmpeg_binary(),
			"args": PackedStringArray(),
			"output_path": out_path,
			"skip": true,
			"reason": "frames-native",
		}
	var abs_frames := ProjectSettings.globalize_path(frames_dir)
	var pattern := abs_frames.path_join("frame_%%05d.%s" % frame_ext)
	var out_abs := ProjectSettings.globalize_path(out_path)
	var crf := _crf_for_quality()
	var args: PackedStringArray = []
	# Input: framerate from measured avg. Frames are 1-indexed (frame_00001…).
	args.append("-framerate")
	args.append(str(fps))
	args.append("-start_number")
	args.append("1")
	args.append("-i")
	args.append(pattern)
	# Overwrite output if exists (user re-records same second).
	args.append("-y")
	# Codec map per target.
	match fmt:
		GdTMOutputFormat.Format.MP4:
			args.append("-c:v")
			args.append("libx264")
			args.append("-crf")
			args.append(str(crf))
			args.append("-pix_fmt")
			args.append("yuv420p")
			# Faststart for web playback.
			args.append("-movflags")
			args.append("+faststart")
		GdTMOutputFormat.Format.WEBM:
			args.append("-c:v")
			args.append("libvpx-vp9")
			# vp9 crf 0..63, 31 ~ decent. Map h264 crf 18→31 inverse.
			var vp9_crf := 31
			if crf <= 18:
				vp9_crf = 31
			elif crf >= 28:
				vp9_crf = 40
			else:
				vp9_crf = 31 + int((crf - 18) * 0.9)
			args.append("-crf")
			args.append(str(vp9_crf))
			args.append("-b:v")
			args.append("0")
			args.append("-pix_fmt")
			args.append("yuv420p")
		GdTMOutputFormat.Format.AVI:
			args.append("-c:v")
			args.append("mjpeg")
			args.append("-q:v")
			args.append(str(maxi(2, 31 - crf)))
		GdTMOutputFormat.Format.OGV:
			args.append("-c:v")
			args.append("libtheora")
			args.append("-q:v")
			args.append(str(maxi(2, 10 - int(crf / 3))))
			args.append("-an")
		_:
			# Fallback treated as mp4.
			args.append("-c:v")
			args.append("libx264")
			args.append("-crf")
			args.append(str(crf))
			args.append("-pix_fmt")
			args.append("yuv420p")
	args.append(out_abs)
	return {
		"binary": _get_ffmpeg_binary(),
		"args": args,
		"output_path": out_path,
		"skip": false,
		"reason": ""
	}


## Builds ffmpeg args for converting a single file (Movie Maker AVI → MP4).
## input_path: existing clip (avi, ogv, ...).
## output_path: desired output (mp4, webm, ...).
## target_fps: optional, used to force correct output rate (WebM reports duration N/A otherwise)
## but we avoid double -r + -vf which was observed to shorten clips when timestamps jitter.
## Returns Dictionary: {binary, args, output_path}.
func build_file_convert_command(
	input_path: String, output_path: String, target_fps: int = 0
) -> Dictionary:
	var fmt := GdTMOutputFormat.from_string(output_path.get_extension())
	var abs_in := ProjectSettings.globalize_path(input_path)
	var abs_out := ProjectSettings.globalize_path(output_path)
	var crf := _crf_for_quality()
	var args: PackedStringArray = []
	args.append("-i")
	args.append(abs_in)
	args.append("-y")
	# For VP9/WebM the container duration can be N/A in ffprobe but playback is
	# actually full duration. To guarantee the requested fps is respected we use
	# a single fps video filter — NOT -r which can cause frame drops when combined
	# with -vf. MP4 keeps source timing unless target_fps explicitly differs.
	if target_fps > 0:
		# Only force filter when format needs it or fps differs; keep simple and safe.
		# VP9 benefits from explicit fps, h264 generally preserves source fps.
		if fmt == GdTMOutputFormat.Format.WEBM or fmt == GdTMOutputFormat.Format.MP4:
			args.append("-vf")
			args.append("fps=%d:round=near" % target_fps)
		else:
			args.append("-r")
			args.append(str(target_fps))
	match fmt:
		GdTMOutputFormat.Format.MP4:
			args.append("-c:v")
			args.append("libx264")
			args.append("-crf")
			args.append(str(crf))
			args.append("-pix_fmt")
			args.append("yuv420p")
			args.append("-movflags")
			args.append("+faststart")
			# Keep audio if present: aac fallback.
			args.append("-c:a")
			args.append("aac")
		GdTMOutputFormat.Format.WEBM:
			args.append("-c:v")
			args.append("libvpx-vp9")
			args.append("-crf")
			args.append("31")
			args.append("-b:v")
			args.append("0")
			args.append("-c:a")
			args.append("libopus")
		GdTMOutputFormat.Format.AVI:
			args.append("-c:v")
			args.append("mjpeg")
			args.append("-q:v")
			args.append(str(maxi(2, 31 - crf)))
		GdTMOutputFormat.Format.OGV:
			args.append("-c:v")
			args.append("libtheora")
			args.append("-an")
		_:
			args.append("-c:v")
			args.append("libx264")
			args.append("-crf")
			args.append(str(crf))
			args.append("-pix_fmt")
			args.append("yuv420p")
	args.append(abs_out)
	return {
		"binary": _get_ffmpeg_binary(),
		"args": args,
		"output_path": output_path,
		"skip": false,
		"reason": ""
	}


## Sync conversion for a frames dir (probe + execute inline). Used by tests and
## as the worker body for async. Returns Dictionary with exit_code, output_path,
## skip, reason, stdout.
func convert_frames_sync(
	frames_dir: String,
	base_output_path: String,
	target_format: String,
	measured_fps: float,
	frame_ext: String
) -> Dictionary:
	if _is_frames_native_target(target_format):
		# Native → no-op, but still compute output path for callers.
		var fmt := GdTMOutputFormat.from_string(target_format)
		var ext := GdTMOutputFormat.to_extension(fmt)
		var base := base_output_path
		if base.ends_with(".frames"):
			base = base.substr(0, base.length() - 7)
		return {
			"exit_code": 0,
			"output_path": "%s.%s" % [base, ext],
			"skip": true,
			"reason": "frames-native",
			"stdout": "",
		}
	if not probe_ffmpeg():
		return {
			"exit_code": -1, "output_path": "", "skip": false, "reason": "not-found", "stdout": ""
		}
	var cmd := build_frames_convert_command(
		frames_dir, base_output_path, target_format, measured_fps, frame_ext
	)
	if cmd.get("skip", false):
		return {
			"exit_code": 0,
			"output_path": cmd.get("output_path", ""),
			"skip": true,
			"reason": cmd.get("reason", ""),
			"stdout": "",
		}
	var out: Array = []
	var code := _os_execute_blocking(cmd["binary"], cmd["args"], out, true)
	var stdout_txt := "\n".join(out) if not out.is_empty() else ""
	return {
		"exit_code": code,
		"output_path": cmd.get("output_path", ""),
		"skip": false,
		"reason": "",
		"stdout": stdout_txt,
	}


## Sync conversion for a single file (Movie Maker path).
func convert_file_sync(input_path: String, output_path: String, target_fps: int = 0) -> Dictionary:
	if not probe_ffmpeg():
		return {
			"exit_code": -1, "output_path": "", "skip": false, "reason": "not-found", "stdout": ""
		}
	var cmd := build_file_convert_command(input_path, output_path, target_fps)
	var out: Array = []
	var code := _os_execute_blocking(cmd["binary"], cmd["args"], out, true)
	var stdout_txt := "\n".join(out) if not out.is_empty() else ""
	return {
		"exit_code": code,
		"output_path": cmd.get("output_path", ""),
		"skip": false,
		"reason": "",
		"stdout": stdout_txt,
	}


## Async: convert frames dir → video. Thread + call_deferred back.
## Keeps frames on probe-missing or nonzero; on success emits conversion_succeeded
## and optionally deletes the frames dir per _clean_on_success.
func convert_frames_async(
	frames_dir: String,
	base_output_path: String,
	target_format: String,
	measured_fps: float,
	frame_ext: String,
	clean_on_success: bool = true
) -> void:
	if _thread != null and _thread.is_started():
		push_warning("GdTMFFmpegConvert: conversion already running")
		return
	if _is_frames_native_target(target_format):
		# No conversion needed — signal success immediately with frames path logic.
		var fmt := GdTMOutputFormat.from_string(target_format)
		var ext := GdTMOutputFormat.to_extension(fmt)
		var base := base_output_path
		if base.ends_with(".frames"):
			base = base.substr(0, base.length() - 7)
		var out_path := "%s.%s" % [base, ext]
		# For PNG/JPG native the "output" is the frames dir itself; emit frames dir.
		# Caller (screenshot) will not call convert for native anyway, so this is moot.
		_current_output_path = out_path
		call_deferred("_deferred_emit_success", out_path)
		return
	if not probe_ffmpeg():
		call_deferred(
			"_deferred_emit_not_found", "ffmpeg not found — frames kept at %s" % frames_dir
		)
		return
	var cmd := build_frames_convert_command(
		frames_dir, base_output_path, target_format, measured_fps, frame_ext
	)
	if cmd.get("skip", false):
		_current_output_path = cmd.get("output_path", "")
		call_deferred("_deferred_emit_success", _current_output_path)
		return
	_current_output_path = cmd.get("output_path", "")
	_current_frames_dir = frames_dir
	_clean_on_success = clean_on_success
	_pending_result = {}
	_thread = Thread.new()
	var callable := func() -> void:
		_thread_convert_worker(
			cmd["binary"], cmd["args"], _current_output_path, _current_frames_dir
		)
	_thread.start(callable)


## Async: convert single file → file.
func convert_file_async(
	input_path: String, output_path: String, clean_on_success: bool = false, target_fps: int = 0
) -> void:
	if _thread != null and _thread.is_started():
		push_warning("GdTMFFmpegConvert: conversion already running")
		return
	if not probe_ffmpeg():
		call_deferred("_deferred_emit_not_found", "ffmpeg not found — %s kept" % input_path)
		return
	var cmd := build_file_convert_command(input_path, output_path, target_fps)
	_current_output_path = cmd.get("output_path", "")
	_current_frames_dir = ""
	_clean_on_success = clean_on_success
	_pending_result = {}
	_thread = Thread.new()
	var callable := func() -> void:
		_thread_convert_worker(
			cmd["binary"], cmd["args"], _current_output_path, _current_frames_dir
		)
	_thread.start(callable)


## Worker executed on a Thread: blocking OS.execute + store result + call_deferred back.
func _thread_convert_worker(
	binary: String, args: PackedStringArray, out_path: String, frames_dir: String
) -> void:
	var out: Array = []
	var code := _os_execute_blocking(binary, args, out, true)
	var stdout_txt := "\n".join(out) if not out.is_empty() else ""
	_pending_result = {
		"exit_code": code,
		"output_path": out_path,
		"frames_dir": frames_dir,
		"stdout": stdout_txt,
	}
	call_deferred("_on_thread_finished")


## Main-thread continuation after the worker finishes.
func _on_thread_finished() -> void:
	var code: int = int(_pending_result.get("exit_code", -1))
	var out_path: String = str(_pending_result.get("output_path", ""))
	var frames_dir: String = str(_pending_result.get("frames_dir", ""))
	var stdout_txt: String = str(_pending_result.get("stdout", ""))
	# Thread has finished its work; wait_to_finish to reclaim it.
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	if code == 0:
		if _clean_on_success and not frames_dir.is_empty():
			_delete_frames_dir(frames_dir)
		conversion_succeeded.emit(out_path)
	else:
		var tail := stdout_txt
		if tail.length() > STDERR_TAIL_CHARS:
			tail = tail.substr(tail.length() - STDERR_TAIL_CHARS)
		conversion_failed.emit("ffmpeg failed (exit %d): %s" % [code, out_path], tail)
	_pending_result = {}


## Deferred helpers for probe-missing and skip paths that don't need a Thread.
func _deferred_emit_success(path: String) -> void:
	conversion_succeeded.emit(path)


func _deferred_emit_not_found(message: String) -> void:
	ffmpeg_not_found.emit(message)


## Waits for any running Thread — must be called before free/_exit_tree.
func wait_for_completion() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null


func _exit_tree() -> void:
	if _finishing:
		return
	_finishing = true
	wait_for_completion()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _finishing:
			return
		_finishing = true
		wait_for_completion()
