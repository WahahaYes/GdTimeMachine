extends GutTest


# Fake backend overriding every EditorInterface/ProjectSettings seam.
class FakeMovieMaker:
	extends BackendMovieMaker
	var playing := false
	var movie_maker_enabled := false
	var movie_file_set := ""
	var movie_fps_set := -1
	var movie_file_clear_calls := 0
	var movie_fps_clear_calls := 0
	var stored_movie_file: Variant = null
	var stored_movie_fps: Variant = null
	var played_custom_scene := ""
	var played_current_scene := false
	var stop_playing_calls := 0
	var graceful_sent := false
	var graceful_send_count := 0
	var output_file_size := 0

	func _get_movie_file() -> Variant:
		return stored_movie_file

	func _get_movie_fps() -> Variant:
		return stored_movie_fps

	func _set_movie_file(path: String) -> void:
		movie_file_set = path
		stored_movie_file = path

	func _set_movie_file_no_restore(path: String) -> void:
		movie_file_set = path
		stored_movie_file = path

	func _clear_movie_file() -> void:
		movie_file_clear_calls += 1
		stored_movie_file = null
		movie_file_set = ""

	func _set_movie_fps(fps: int) -> void:
		movie_fps_set = fps
		stored_movie_fps = fps

	func _set_movie_fps_no_restore(fps: int) -> void:
		movie_fps_set = fps
		stored_movie_fps = fps

	func _clear_movie_fps() -> void:
		movie_fps_clear_calls += 1
		stored_movie_fps = null

	func _set_movie_maker_enabled(enabled: bool) -> void:
		movie_maker_enabled = enabled

	func _is_movie_maker_enabled() -> bool:
		return movie_maker_enabled

	func _is_playing_scene() -> bool:
		return playing

	func _play_scene(scene_path: String) -> void:
		if scene_path.is_empty():
			played_current_scene = true
		else:
			played_custom_scene = scene_path

	func _stop_playing_scene() -> void:
		stop_playing_calls += 1

	func _send_graceful_stop_message() -> void:
		graceful_sent = true
		graceful_send_count += 1

	func _get_grace_period() -> float:
		return 0.1

	func _get_output_file_size() -> int:
		return output_file_size


const OUTPUT := "res://media/captures/demo_2026-01-01T00-00-00.avi"


func _make_backend() -> FakeMovieMaker:
	var backend: FakeMovieMaker = add_child_autofree(FakeMovieMaker.new())
	return backend


func _start_recording(backend: FakeMovieMaker, overrides: Dictionary = {}) -> void:
	var config := {"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"}
	config.merge(overrides)
	backend.start(config)


func test_get_backend_name() -> void:
	var backend := _make_backend()
	assert_eq(backend.get_backend_name(), "Godot Movie Maker")


func test_movie_maker_description_mentions_fixed_fps() -> void:
	# Tooltip contract: the backend's get_description() must state the
	# capture semantics — Movie Maker is fixed-fps, non-real-time.
	var backend: BackendMovieMaker = add_child_autofree(BackendMovieMaker.new())
	var desc := backend.get_description().to_lower()
	assert_string_contains(desc, "fixed-fps")
	assert_string_contains(desc, "non-real-time")


func test_is_available_always_true() -> void:
	var backend := _make_backend()
	assert_true(backend.is_available())


func test_is_recording_false_by_default() -> void:
	var backend := _make_backend()
	assert_false(backend.is_recording())


func test_start_configures_movie_maker() -> void:
	var backend := _make_backend()
	_start_recording(backend, {"fps": 60})
	assert_eq(backend.movie_file_set, OUTPUT)
	assert_eq(backend.movie_fps_set, 60)
	assert_true(backend.movie_maker_enabled)
	assert_eq(backend.played_custom_scene, "res://scenes/demo.tscn")
	assert_true(backend.is_recording())


func test_start_without_fps_keeps_default() -> void:
	var backend := _make_backend()
	_start_recording(backend)
	assert_eq(backend.movie_fps_set, -1)


func test_start_plays_current_scene_when_path_empty() -> void:
	var backend := _make_backend()
	backend.start({"output_path": OUTPUT})
	assert_true(backend.played_current_scene)
	assert_eq(backend.played_custom_scene, "")


func test_start_defaults_output_path_when_empty() -> void:
	var backend := _make_backend()
	backend.start({"scene_path": "res://scenes/demo.tscn"})
	assert_eq(backend.movie_file_set, "res://movie.avi")


func test_start_twice_is_ignored() -> void:
	var backend := _make_backend()
	_start_recording(backend)
	var file_before: String = backend.movie_file_set
	_start_recording(backend, {"fps": 30})
	assert_eq(backend.movie_file_set, file_before)
	assert_eq(backend.movie_fps_set, -1)


func test_poll_emits_recording_started_when_playback_begins() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	assert_eq(started.size(), 0)
	backend.playing = true
	backend._on_poll_timeout()
	assert_eq(started.size(), 1)
	assert_eq(started[0], ["Godot Movie Maker", OUTPUT])
	backend._on_poll_timeout()
	assert_eq(started.size(), 1)


func test_poll_detects_natural_exit_and_emits_stopped() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	assert_eq(backend.stop_playing_calls, 0)
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)


func test_stop_emits_stopped_and_disables_movie_maker() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.stop()
	assert_true(backend.graceful_sent)
	assert_eq(backend.stop_playing_calls, 0)
	assert_eq(stopped.size(), 0)
	assert_true(backend.is_recording())
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	assert_eq(backend.stop_playing_calls, 0)


func test_stop_when_not_recording_is_noop() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.stop()
	assert_eq(stopped.size(), 0)
	assert_eq(backend.stop_playing_calls, 0)
	assert_false(backend.movie_maker_enabled)


func test_no_double_stopped_emission_after_natural_exit_then_stop() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.playing = false
	backend._on_poll_timeout()
	backend.stop()
	assert_eq(stopped.size(), 1)
	assert_false(backend.graceful_sent)


func test_grace_timer_forces_stop_and_single_emission() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.stop()
	await wait_seconds(0.25)
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_eq(backend.stop_playing_calls, 1)
	assert_true(backend.graceful_sent)
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	await wait_seconds(0.2)
	assert_eq(stopped.size(), 1)


func test_duration_auto_stops_after_elapsed() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn", "duration": 0.1})
	backend.playing = true
	backend._on_poll_timeout()
	await wait_seconds(0.25)
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	assert_eq(backend.stop_playing_calls, 1)


# --- New: snapshot/restore — no project.godot pollution ---


func test_snapshot_captures_previous_values() -> void:
	var backend := _make_backend()
	backend.stored_movie_file = "res://old.avi"
	backend.stored_movie_fps = 24
	_start_recording(backend, {"fps": 60})
	# Snapshot should have captured old values.
	assert_eq(backend._prev_movie_file, "res://old.avi")
	assert_eq(backend._prev_fps, 24)


func test_restore_on_natural_exit() -> void:
	var backend := _make_backend()
	backend.stored_movie_file = "res://old.avi"
	backend.stored_movie_fps = 30
	var stopped: Array = []
	backend.recording_stopped.connect(func(_n, _p): stopped.append(true))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn", "fps": 60})
	assert_eq(backend.stored_movie_file, OUTPUT)
	assert_eq(backend.stored_movie_fps, 60)
	backend.playing = true
	backend._on_poll_timeout()
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)
	assert_eq(backend.stored_movie_file, "res://old.avi")
	assert_eq(backend.stored_movie_fps, 30)


func test_restore_clears_when_no_previous() -> void:
	var backend := _make_backend()
	backend.stored_movie_file = null
	backend.stored_movie_fps = null
	var stopped: Array = []
	backend.recording_stopped.connect(func(_n, _p): stopped.append(true))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)
	assert_eq(backend.stored_movie_file, null)
	assert_eq(backend.movie_file_clear_calls, 1)
	assert_eq(backend.movie_fps_clear_calls, 1)


func test_avi_size_guard_ignores_output_below_limit() -> void:
	var backend := _make_backend()
	backend.output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES - 1
	_start_recording(backend)
	backend.playing = true
	backend._on_poll_timeout()  # recording_started
	backend._on_poll_timeout()  # size check below limit
	assert_false(backend.graceful_sent)
	assert_true(backend.is_recording())


func test_avi_size_guard_stops_when_limit_reached() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(_n, _p): stopped.append(true))
	backend.output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES
	_start_recording(backend)
	backend.playing = true
	backend._on_poll_timeout()  # recording_started
	backend._on_poll_timeout()  # size guard trips → graceful stop
	assert_true(backend.graceful_sent)
	assert_true(backend._stopping)
	# Simulate the game quitting; the poll observes the exit and finalizes.
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)
	assert_false(backend.is_recording())


func test_avi_size_guard_emits_notice_after_stop() -> void:
	var backend := _make_backend()
	var notices: Array[String] = []
	backend.recording_notice.connect(func(_n, m): notices.append(m))
	backend.output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES
	_start_recording(backend)
	backend.playing = true
	backend._on_poll_timeout()
	backend._on_poll_timeout()
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(notices.size(), 1)
	# Loosely pinned: the notice must mention the 4 GB cap (wording may vary).
	var notice := notices[0].to_lower()
	assert_true(notice.contains("4"), "notice names the cap size")
	assert_true(notice.contains("gb"), "notice names the unit")


func test_avi_size_guard_ignores_non_avi_output() -> void:
	var backend := _make_backend()
	backend.output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES
	(
		backend
		. start(
			{
				"output_path": "res://media/captures/demo.ogv",
				"scene_path": "res://scenes/demo.tscn",
			}
		)
	)
	backend.playing = true
	backend._on_poll_timeout()
	backend._on_poll_timeout()
	assert_false(backend.graceful_sent)
	assert_true(backend.is_recording())


func test_avi_size_guard_applies_to_tier2_intermediate() -> void:
	var backend := _make_backend()
	backend.output_file_size = BackendMovieMaker.AVI_SIZE_LIMIT_BYTES
	(
		backend
		. start(
			{
				"output_path": "res://media/captures/demo.mp4",
				"scene_path": "res://scenes/demo.tscn",
				"output_format": "mp4",
				"auto_convert": false,
			}
		)
	)
	backend.playing = true
	backend._on_poll_timeout()
	backend._on_poll_timeout()
	assert_true(backend.graceful_sent)
