extends GutTest

## Command-line building for CLI Movie Maker captures (core/movie_writer.gd).


func test_build_args_base_command() -> void:
	var args := GdTMMovieWriter.build_args("/wt", "res://main.tscn", "/out/a.avi", 30, 2.0)
	assert_eq(
		Array(args),
		[
			"--path",
			"/wt",
			"--write-movie",
			"/out/a.avi",
			"--fixed-fps",
			"30",
			"--quit-after",
			"60",
			"res://main.tscn",
		]
	)


func test_build_args_no_quit_after_without_duration() -> void:
	var args := GdTMMovieWriter.build_args("/wt", "res://main.tscn", "/out/a.avi", 30, 0.0)
	assert_false("--quit-after" in args)


func test_build_args_fullscreen() -> void:
	var args := GdTMMovieWriter.build_args(
		"/wt", "res://main.tscn", "/out/a.avi", 30, 1.0, {"fullscreen": true}
	)
	assert_true("--fullscreen" in args)
	assert_lt(args.find("--fullscreen"), args.find("res://main.tscn"))


func test_build_args_windowed_by_default() -> void:
	var args := GdTMMovieWriter.build_args(
		"/wt", "res://main.tscn", "/out/a.avi", 30, 1.0, {"fullscreen": false}
	)
	assert_false("--fullscreen" in args)


func test_build_args_resolution() -> void:
	var args := GdTMMovieWriter.build_args(
		"/wt", "res://main.tscn", "/out/a.avi", 30, 1.0, {"resolution": "1920x1080"}
	)
	var i := args.find("--resolution")
	assert_gt(i, -1)
	assert_eq(args[i + 1], "1920x1080")
	assert_lt(i, args.find("res://main.tscn"))


func test_prepare_project_writes_window_size_override() -> void:
	var wt := OS.get_temp_dir().path_join("gdtm_prepare_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(wt)
	var f := FileAccess.open(wt.path_join("override.cfg"), FileAccess.WRITE)
	f.store_string('[application]\nconfig/name="Kept"\n')
	f.close()
	assert_true(GdTMMovieWriter.prepare_project(wt, {"resolution": "1920x1080"}))
	var cf := ConfigFile.new()
	assert_eq(cf.load(wt.path_join("override.cfg")), OK)
	assert_eq(cf.get_value("display", "window/size/window_width_override"), 1920)
	assert_eq(cf.get_value("display", "window/size/window_height_override"), 1080)
	assert_eq(cf.get_value("application", "config/name"), "Kept")
	OS.execute("rm", PackedStringArray(["-rf", wt]))


func test_prepare_project_without_resolution_writes_nothing() -> void:
	var wt := OS.get_temp_dir().path_join("gdtm_prepare_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(wt)
	assert_true(GdTMMovieWriter.prepare_project(wt, {}))
	assert_false(FileAccess.file_exists(wt.path_join("override.cfg")))
	OS.execute("rm", PackedStringArray(["-rf", wt]))


func test_build_args_user_args_after_separator() -> void:
	var args := GdTMMovieWriter.build_args(
		"/wt",
		"res://main.tscn",
		"/out/a.avi",
		30,
		1.0,
		{"user_args": PackedStringArray(["--shot=wide", "--seed=3"]), "resolution": "640x360"}
	)
	var sep := args.find("--")
	assert_eq(sep, args.find("res://main.tscn") + 1)
	assert_eq(Array(args.slice(sep + 1)), ["--shot=wide", "--seed=3"])


func test_build_args_no_separator_without_user_args() -> void:
	var args := GdTMMovieWriter.build_args("/wt", "res://main.tscn", "/out/a.avi", 30, 1.0, {})
	assert_false("--" in args)


func test_start_log_writes_header_beside_movie() -> void:
	var dir := OS.get_temp_dir().path_join("gdtm_log_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var path := GdTMMovieWriter.start_log(
		dir.path_join("intro.avi"),
		PackedStringArray(["gdtime capture: intro", "commit: main -> abc"])
	)
	assert_eq(path, dir.path_join("intro.log"))
	var lines := FileAccess.get_file_as_string(path).split("\n")
	assert_eq(lines[0], "# gdtime capture: intro")
	assert_eq(lines[1], "# commit: main -> abc")
	assert_true(lines[2].begins_with("# lines: [frame N | T s]"))
	OS.execute("rm", PackedStringArray(["-rf", dir]))


func test_prepare_project_with_log_injects_capture_log_autoload() -> void:
	var wt := OS.get_temp_dir().path_join("gdtm_inject_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(wt)
	assert_true(GdTMMovieWriter.prepare_project(wt, {}, true))
	for script_name in GdTMMovieWriter.CAPTURE_LOG_SCRIPTS:
		# Compare digests: printing these sources would trip the Makefile's
		# error-string scan.
		var copied := FileAccess.get_md5(wt.path_join(".gdtime").path_join(script_name))
		var source := FileAccess.get_md5(
			"res://addons/GdTimeMachine/autoload".path_join(script_name)
		)
		assert_eq(copied, source, script_name)
	var cf := ConfigFile.new()
	assert_eq(cf.load(wt.path_join("override.cfg")), OK)
	assert_eq(cf.get_value("autoload", "GdTimeMachineCaptureLog"), "*res://.gdtime/capture_log.gd")
	OS.execute("rm", PackedStringArray(["-rf", wt]))


func test_wait_budget_allows_slower_than_real_time() -> void:
	# A 10 s clip rendering at 50% of real time takes 20 s; it must not be
	# killed before then.
	assert_gt(GdTMMovieWriter.wait_budget_ms(10.0), 20000)
	assert_eq(GdTMMovieWriter.wait_budget_ms(0.0), 30000)
