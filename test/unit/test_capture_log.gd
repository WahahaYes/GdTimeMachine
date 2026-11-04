extends GutTest

## Game-side capture log (autoload/capture_log.gd + capture_logger.gd): the
## file handshake, frame stamping, and line formatting.

const CAPTURE_LOG := preload("res://addons/GdTimeMachine/autoload/capture_log.gd")
const CAPTURE_LOGGER := preload("res://addons/GdTimeMachine/autoload/capture_logger.gd")


## Capture log with the movie path injected instead of read from the engine.
class FakeMovieCaptureLog:
	extends "res://addons/GdTimeMachine/autoload/capture_log.gd"
	var movie := ""

	func _movie_path() -> String:
		return movie


var _dir := ""


func before_each() -> void:
	_dir = OS.get_temp_dir().path_join("gdtm_caplog_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)


func after_each() -> void:
	OS.execute("rm", PackedStringArray(["-rf", _dir]))
	if Engine.has_meta(CAPTURE_LOG.ACTIVE_META):
		Engine.remove_meta(CAPTURE_LOG.ACTIVE_META)


func _read_lines(path: String) -> PackedStringArray:
	return FileAccess.get_file_as_string(path).strip_edges(false, true).split("\n")


func test_log_path_for_movie() -> void:
	assert_eq(CAPTURE_LOG.log_path_for_movie("/out/intro.avi"), "/out/intro.log")
	assert_eq(CAPTURE_LOG.log_path_for_movie("res://media/a_2026.png"), "res://media/a_2026.log")
	assert_eq(CAPTURE_LOG.log_path_for_movie(""), "")


func test_format_line() -> void:
	assert_eq(CAPTURE_LOGGER.format_line(0, 0.0, "ready"), "[frame 0 | 0.000s] ready")
	assert_eq(
		CAPTURE_LOGGER.format_line(123, 123.0 / 60.0, "RESULT plan"),
		"[frame 123 | 2.050s] RESULT plan"
	)


func test_logger_stamps_each_line_and_marks_stderr() -> void:
	var path := _dir.path_join("a.log")
	var file := FileAccess.open(path, FileAccess.WRITE)
	var logger: Object = CAPTURE_LOGGER.new(file)
	logger.call("_log_message", "one\ntwo\n", false)
	logger.call("_log_message", "oops\n", true)
	logger.call("close")
	var lines := _read_lines(path)
	assert_eq(lines.size(), 3)
	var stamp := "[frame %d | " % Engine.get_frames_drawn()
	assert_true(lines[0].begins_with(stamp), lines[0])
	assert_true(lines[0].ends_with("] one"), lines[0])
	assert_true(lines[1].ends_with("] two"), lines[1])
	assert_true(lines[2].ends_with("] (stderr) oops"), lines[2])


func test_logger_formats_engine_errors() -> void:
	var path := _dir.path_join("b.log")
	var file := FileAccess.open(path, FileAccess.WRITE)
	var logger: Object = CAPTURE_LOGGER.new(file)
	var no_bt: Array[ScriptBacktrace] = []
	logger.call("_log_error", "_ready", "res://a.gd", 7, "code", "bad thing", false, 1, no_bt)
	logger.call("close")
	assert_true(
		_read_lines(path)[0].ends_with("] WARNING: bad thing (res://a.gd:7 @ _ready())"),
		_read_lines(path)[0]
	)


func test_installs_only_when_recorder_created_the_log() -> void:
	var node: FakeMovieCaptureLog = FakeMovieCaptureLog.new()
	node.movie = _dir.path_join("clip.avi")
	add_child_autofree(node)
	assert_null(node._logger, "no log file → no logger")
	assert_false(FileAccess.file_exists(_dir.path_join("clip.log")))


func test_no_movie_no_logger() -> void:
	var node: FakeMovieCaptureLog = FakeMovieCaptureLog.new()
	add_child_autofree(node)
	assert_null(node._logger)


func test_appends_game_output_after_header() -> void:
	var log_path := _dir.path_join("clip.log")
	var f := FileAccess.open(log_path, FileAccess.WRITE)
	f.store_line("# header")
	f.close()
	var node: FakeMovieCaptureLog = FakeMovieCaptureLog.new()
	node.movie = _dir.path_join("clip.avi")
	add_child(node)
	assert_not_null(node._logger)
	print("RESULT capture-log-test")
	remove_child(node)
	node.free()
	assert_false(Engine.has_meta(CAPTURE_LOG.ACTIVE_META), "meta cleared on exit")
	var lines := _read_lines(log_path)
	assert_eq(lines[0], "# header")
	assert_true(lines[lines.size() - 1].ends_with("] RESULT capture-log-test"), str(lines))


func test_second_install_is_skipped() -> void:
	var log_path := _dir.path_join("clip.log")
	FileAccess.open(log_path, FileAccess.WRITE).close()
	var first: FakeMovieCaptureLog = FakeMovieCaptureLog.new()
	first.movie = _dir.path_join("clip.avi")
	var second: FakeMovieCaptureLog = FakeMovieCaptureLog.new()
	second.movie = first.movie
	add_child_autofree(first)
	add_child_autofree(second)
	assert_not_null(first._logger)
	assert_null(second._logger)
