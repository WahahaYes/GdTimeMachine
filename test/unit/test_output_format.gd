extends GutTest


func test_output_format_to_extension() -> void:
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.AVI), "avi")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.OGV), "ogv")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.PNG), "png")


func test_output_format_display_name() -> void:
	assert_true(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.AVI).contains("AVI"))
	assert_true(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.OGV).contains("OGV"))
	assert_true(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.PNG).contains("PNG"))


func test_output_format_from_string_bare() -> void:
	assert_eq(GdTMOutputFormat.from_string("avi"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string("ogv"), GdTMOutputFormat.Format.OGV)
	assert_eq(GdTMOutputFormat.from_string("png"), GdTMOutputFormat.Format.PNG)
	assert_eq(GdTMOutputFormat.from_string(".avi"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string(".ogv"), GdTMOutputFormat.Format.OGV)
	assert_eq(GdTMOutputFormat.from_string(".png"), GdTMOutputFormat.Format.PNG)


func test_output_format_from_string_case_insensitive() -> void:
	assert_eq(GdTMOutputFormat.from_string("AVI"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string("Ogv"), GdTMOutputFormat.Format.OGV)


func test_output_format_from_string_unknown_defaults_to_avi() -> void:
	assert_eq(GdTMOutputFormat.from_string("mov"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string(""), GdTMOutputFormat.Format.AVI)


func test_output_format_all_formats() -> void:
	var all := GdTMOutputFormat.all_formats()
	assert_eq(all.size(), 3)
	assert_true(all.has(GdTMOutputFormat.Format.AVI))
	assert_true(all.has(GdTMOutputFormat.Format.OGV))
	assert_true(all.has(GdTMOutputFormat.Format.PNG))


func test_output_format_warning() -> void:
	assert_true(GdTMOutputFormat.needs_size_warning(GdTMOutputFormat.Format.AVI))
	assert_false(GdTMOutputFormat.needs_size_warning(GdTMOutputFormat.Format.OGV))
	assert_false(GdTMOutputFormat.needs_size_warning(GdTMOutputFormat.Format.PNG))
	assert_false(GdTMOutputFormat.warning_text(GdTMOutputFormat.Format.AVI).is_empty())
	assert_false(GdTMOutputFormat.warning_text(GdTMOutputFormat.Format.OGV).is_empty())
	assert_true(GdTMOutputFormat.warning_text(GdTMOutputFormat.Format.PNG).is_empty())


func test_recording_profile_roundtrip() -> void:
	var p := RecordingProfile.new()
	p.output_dir = "res://out"
	p.output_format = GdTMOutputFormat.Format.OGV
	p.fps = 30
	p.duration = 5.0
	p.backend_name = "Godot Movie Maker"
	var d := p.to_dict()
	var p2 := RecordingProfile.from_dict(d)
	assert_eq(p2.output_dir, "res://out")
	assert_eq(p2.output_format, GdTMOutputFormat.Format.OGV)
	assert_eq(p2.fps, 30)
	assert_eq(p2.duration, 5.0)
	assert_eq(p2.backend_name, "Godot Movie Maker")


func test_recording_profile_unknown_format_falls_back() -> void:
	var p := RecordingProfile.from_dict({"output_format": "bogus"})
	assert_eq(p.output_format, GdTMOutputFormat.DEFAULT)


func test_recording_profile_duplicate() -> void:
	var p := RecordingProfile.new()
	p.output_dir = "res://a"
	p.fps = 24
	var dup := p.duplicate_profile()
	assert_eq(dup.output_dir, "res://a")
	assert_eq(dup.fps, 24)
	dup.output_dir = "res://b"
	assert_eq(p.output_dir, "res://a")
