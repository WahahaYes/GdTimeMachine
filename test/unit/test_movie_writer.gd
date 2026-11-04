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
