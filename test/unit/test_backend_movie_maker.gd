extends GutTest


# Fake backend that overrides every EditorInterface/ProjectSettings seam so
# tests never touch engine singletons. Mirrors the real seam set 1:1.
class FakeMovieMaker:
	extends BackendMovieMaker
	var playing := false
	var movie_maker_enabled := false
	var movie_file_set := ""
	var movie_fps_set := -1
	var played_custom_scene := ""
	var played_current_scene := false
	var stop_playing_calls := 0
	var project_save_calls := 0
	var graceful_sent := false
	var graceful_send_count := 0

	func _set_movie_file(path: String) -> void:
		movie_file_set = path
		project_save_calls += 1

	func _set_movie_fps(fps: int) -> void:
		movie_fps_set = fps
		project_save_calls += 1

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
		# Short grace window so tests exercise the force-stop fallback fast.
		return 0.1


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


func test_get_description_is_non_empty() -> void:
	var backend := _make_backend()
	assert_false(backend.get_description().is_empty())


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
	var save_calls_before: int = backend.project_save_calls
	_start_recording(backend, {"fps": 30})
	assert_eq(backend.project_save_calls, save_calls_before)
	assert_eq(backend.movie_fps_set, -1)


func test_poll_emits_recording_started_when_playback_begins() -> void:
	var backend := _make_backend()
	var started: Array = []
	backend.recording_started.connect(func(name, path): started.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	# Nothing yet — playback hasn't begun.
	assert_eq(started.size(), 0)
	backend.playing = true
	backend._on_poll_timeout()
	assert_eq(started.size(), 1)
	assert_eq(started[0], ["Godot Movie Maker", OUTPUT])
	# Second poll while playing must not re-emit.
	backend._on_poll_timeout()
	assert_eq(started.size(), 1)


func test_poll_detects_natural_exit_and_emits_stopped() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()  # recording starts
	backend.playing = false
	backend._on_poll_timeout()  # scene ended
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	# Natural exit does not call stop_playing_scene — playback already ended.
	assert_eq(backend.stop_playing_calls, 0)
	# Idle polls after the session ends are no-ops.
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
	# Graceful funnel: message sent, nothing finalized yet, playback untouched.
	assert_true(backend.graceful_sent)
	assert_eq(backend.stop_playing_calls, 0)
	assert_eq(stopped.size(), 0)
	assert_true(backend.is_recording())
	# Game exits on its own; poll observes it → single emission, no force-stop.
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
	backend._on_poll_timeout()  # natural exit
	backend.stop()  # explicit stop afterwards must not re-emit
	assert_eq(stopped.size(), 1)
	assert_false(backend.graceful_sent)


func test_stop_single_emission_when_poll_sees_exit() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.stop()
	backend.playing = false
	backend._on_poll_timeout()  # graceful exit observed
	assert_eq(stopped.size(), 1)
	backend._on_poll_timeout()  # idle poll after finalize must not re-emit
	assert_eq(stopped.size(), 1)


func test_grace_timer_forces_stop_and_single_emission() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.stop()
	# Game never quits; grace timer (0.1s in the fake) expires → force-stop.
	await wait_seconds(0.25)
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_eq(backend.stop_playing_calls, 1)
	assert_true(backend.graceful_sent)
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	# No second emission after the grace window.
	await wait_seconds(0.2)
	assert_eq(stopped.size(), 1)


func test_stop_during_grace_is_idempotent() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.stop()
	backend.stop()  # second stop during grace must not re-send or finalize
	assert_eq(backend.graceful_send_count, 1)
	assert_eq(stopped.size(), 0)
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)


func test_duration_timeout_during_grace_does_not_double_emit() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.stop()
	backend._on_duration_timeout()  # fires during grace → ignored
	backend.playing = false
	backend._on_poll_timeout()
	assert_eq(stopped.size(), 1)
	assert_false(backend.is_recording())


func test_natural_exit_does_not_send_graceful_message() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	backend.playing = false
	backend._on_poll_timeout()  # natural scene exit, no explicit stop
	assert_false(backend.graceful_sent)
	assert_eq(stopped.size(), 1)
	assert_eq(backend.stop_playing_calls, 0)


func test_duration_auto_stops_after_elapsed() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn", "duration": 0.1})
	backend.playing = true
	backend._on_poll_timeout()  # recording starts
	await wait_seconds(0.25)  # duration timer fires at 0.1s
	assert_eq(stopped.size(), 1)
	assert_eq(stopped[0], ["Godot Movie Maker", OUTPUT])
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	assert_eq(backend.stop_playing_calls, 1)


func test_duration_watchdog_errors_if_scene_never_starts() -> void:
	var backend := _make_backend()
	var errors: Array = []
	var stopped: Array = []
	backend.recording_error.connect(func(name, message): errors.append([name, message]))
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn", "duration": 0.1})
	await wait_seconds(0.25)  # scene never plays; duration timer fires
	assert_eq(errors.size(), 1)
	assert_eq(errors[0][0], "Godot Movie Maker")
	assert_false(stopped.size() > 0)
	assert_false(backend.is_recording())
	assert_false(backend.movie_maker_enabled)
	assert_eq(backend.stop_playing_calls, 1)


func test_recording_without_duration_has_no_auto_stop() -> void:
	var backend := _make_backend()
	var stopped: Array = []
	backend.recording_stopped.connect(func(name, path): stopped.append([name, path]))
	backend.start({"output_path": OUTPUT, "scene_path": "res://scenes/demo.tscn"})
	backend.playing = true
	backend._on_poll_timeout()
	await wait_seconds(0.25)  # no duration timer armed
	assert_eq(stopped.size(), 0)
	assert_true(backend.is_recording())
