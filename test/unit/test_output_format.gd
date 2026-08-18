@tool
extends GutTest


func before_each() -> void:
	pass


## Enum <-> extension <-> display_name roundtrips


func test_format_to_extension_all() -> void:
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.AVI), "avi")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.OGV), "ogv")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.PNG), "png")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.JPG), "jpg")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.MP4), "mp4")
	assert_eq(GdTMOutputFormat.to_extension(GdTMOutputFormat.Format.WEBM), "webm")


func test_from_string_case_insensitive() -> void:
	assert_eq(GdTMOutputFormat.from_string("AVI"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string("avi"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string("Avi"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string(".MP4"), GdTMOutputFormat.Format.MP4)
	assert_eq(GdTMOutputFormat.from_string("webm"), GdTMOutputFormat.Format.WEBM)


func test_from_string_display_name_prefix() -> void:
	assert_eq(GdTMOutputFormat.from_string("AVI (.avi)"), GdTMOutputFormat.Format.AVI)
	assert_eq(GdTMOutputFormat.from_string("MP4 (.mp4) - ffmpeg"), GdTMOutputFormat.Format.MP4)
	assert_eq(GdTMOutputFormat.from_string("PNG sequence"), GdTMOutputFormat.Format.PNG)
	assert_eq(GdTMOutputFormat.from_string("JPG sequence (.jpg)"), GdTMOutputFormat.Format.JPG)


func test_from_string_unknown_fallbacks_to_default() -> void:
	assert_eq(GdTMOutputFormat.from_string("unknown"), GdTMOutputFormat.DEFAULT)
	assert_eq(GdTMOutputFormat.from_string(""), GdTMOutputFormat.DEFAULT)
	assert_eq(GdTMOutputFormat.from_string("mov"), GdTMOutputFormat.DEFAULT)


func test_from_string_jpg_jpeg_aliases() -> void:
	assert_eq(GdTMOutputFormat.from_string("jpg"), GdTMOutputFormat.Format.JPG)
	assert_eq(GdTMOutputFormat.from_string("jpeg"), GdTMOutputFormat.Format.JPG)
	assert_eq(GdTMOutputFormat.from_string("JPEG"), GdTMOutputFormat.Format.JPG)


func test_display_name_all_formats() -> void:
	assert_eq(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.AVI), "AVI (.avi)")
	assert_eq(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.OGV), "OGV (.ogv)")
	assert_eq(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.PNG), "PNG sequence (.png)")
	assert_eq(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.JPG), "JPG sequence (.jpg)")
	assert_true(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.MP4).contains("ffmpeg"))
	assert_true(GdTMOutputFormat.display_name(GdTMOutputFormat.Format.WEBM).contains("ffmpeg"))


## Tier-2 and frames source classification


func test_is_tier2_format() -> void:
	assert_true(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.MP4))
	assert_true(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.WEBM))
	assert_false(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.AVI))
	assert_false(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.OGV))
	assert_false(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.PNG))
	assert_false(GdTMOutputFormat.is_tier2_format(GdTMOutputFormat.Format.JPG))


func test_is_frames_source_format() -> void:
	assert_true(GdTMOutputFormat.is_frames_source_format(GdTMOutputFormat.Format.PNG))
	assert_true(GdTMOutputFormat.is_frames_source_format(GdTMOutputFormat.Format.JPG))
	assert_false(GdTMOutputFormat.is_frames_source_format(GdTMOutputFormat.Format.AVI))
	assert_false(GdTMOutputFormat.is_frames_source_format(GdTMOutputFormat.Format.MP4))


func test_frames_need_ffmpeg() -> void:
	assert_false(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.PNG))
	assert_false(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.JPG))
	assert_true(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.AVI))
	assert_true(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.MP4))
	assert_true(GdTMOutputFormat.frames_need_ffmpeg(GdTMOutputFormat.Format.WEBM))


## Size warning


func test_needs_size_warning_avi_only() -> void:
	assert_true(GdTMOutputFormat.needs_size_warning(GdTMOutputFormat.Format.AVI))
	assert_false(GdTMOutputFormat.needs_size_warning(GdTMOutputFormat.Format.OGV))
	assert_false(GdTMOutputFormat.needs_size_warning(GdTMOutputFormat.Format.MP4))


func test_warning_text_returns_nonempty_for_warned_formats() -> void:
	var avi_warn := GdTMOutputFormat.warning_text(GdTMOutputFormat.Format.AVI)
	assert_false(avi_warn.is_empty())
	assert_true(avi_warn.contains("4 GB"))
	var mp4_warn := GdTMOutputFormat.warning_text(GdTMOutputFormat.Format.MP4)
	assert_false(mp4_warn.is_empty())
	assert_true(mp4_warn.contains("ffmpeg"))


## RecordingProfile serialization roundtrip


func test_profile_to_dict_from_dict_roundtrip() -> void:
	var p := RecordingProfile.new()
	p.output_dir = "res://test"
	p.output_format = GdTMOutputFormat.Format.WEBM
	p.fps = 30
	p.duration = 10.5
	p.backend_name = "Test Backend"
	var dict := p.to_dict()
	var p2 := RecordingProfile.from_dict(dict)
	assert_eq(p2.output_dir, "res://test")
	assert_eq(p2.output_format, GdTMOutputFormat.Format.WEBM)
	assert_eq(p2.fps, 30)
	assert_eq(p2.duration, 10.5)
	assert_eq(p2.backend_name, "Test Backend")


func test_profile_from_dict_handles_missing_keys() -> void:
	var p := RecordingProfile.from_dict({})
	assert_eq(p.output_dir, "res://media/captures")
	assert_eq(p.output_format, GdTMOutputFormat.DEFAULT)
	assert_eq(p.fps, 60)
	assert_eq(p.duration, 30.0)
	assert_eq(p.backend_name, "")


func test_profile_duplicate() -> void:
	var p := RecordingProfile.new()
	p.output_dir = "res://dup"
	p.output_format = GdTMOutputFormat.Format.PNG
	p.fps = 120
	var d := p.duplicate_profile()
	assert_eq(d.output_dir, "res://dup")
	assert_eq(d.output_format, GdTMOutputFormat.Format.PNG)
	assert_eq(d.fps, 120)
	assert_ne(d, p)
