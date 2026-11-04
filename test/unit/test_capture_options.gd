extends GutTest

## Capture options shared by the CLI and the Movie Maker backend
## (core/capture_options.gd).


func test_validate_resolution_accepts_sizes_and_empty() -> void:
	for v in ["1920x1080", "2560X1440", " 640 x 360 ", ""]:
		assert_eq(GdTMCaptureOptions.validate_resolution(v), "", "'%s'" % v)


func test_validate_resolution_rejects_malformed() -> void:
	for v in ["1920", "1920x", "0x1080", "1920x1080x2", "wide", "99999x10", 1920]:
		assert_ne(GdTMCaptureOptions.validate_resolution(v), "", str(v))


func test_normalize_resolution() -> void:
	assert_eq(GdTMCaptureOptions.normalize_resolution(" 1920 X 1080 "), "1920x1080")
	assert_eq(GdTMCaptureOptions.normalize_resolution("nope"), "")
	assert_eq(GdTMCaptureOptions.parse_resolution("1280x720"), Vector2i(1280, 720))


func test_entry_options_entry_overrides_top_level() -> void:
	var top := {"resolution": "1280x720"}
	var inherited := GdTMCaptureOptions.entry_options({}, top)
	assert_eq(inherited["resolution"], "1280x720")
	assert_false(inherited["fullscreen"])
	var own := GdTMCaptureOptions.entry_options(
		{"resolution": "1920x1080", "fullscreen": true}, top
	)
	assert_eq(own["resolution"], "1920x1080")
	assert_true(own["fullscreen"])


func test_entry_options_defaults_to_project_size() -> void:
	assert_eq(GdTMCaptureOptions.entry_options({}, {})["resolution"], "")


func test_project_overrides_set_window_size() -> void:
	var o := GdTMCaptureOptions.project_overrides({"resolution": "1920x1080"})
	assert_eq(o[GdTMCaptureOptions.WIDTH_OVERRIDE_KEY], 1920)
	assert_eq(o[GdTMCaptureOptions.HEIGHT_OVERRIDE_KEY], 1080)
	assert_true(GdTMCaptureOptions.project_overrides({"resolution": ""}).is_empty())
	assert_true(GdTMCaptureOptions.project_overrides({}).is_empty())


func test_merge_override_cfg_keeps_existing_entries() -> void:
	var existing := '[application]\nconfig/name="Mine"\n\n[display]\nwindow/vsync/vsync_mode=0\n'
	var text := GdTMCaptureOptions.merge_override_cfg(
		existing, GdTMCaptureOptions.project_overrides({"resolution": "640x360"})
	)
	var cf := ConfigFile.new()
	assert_eq(cf.parse(text), OK)
	assert_eq(cf.get_value("application", "config/name"), "Mine")
	assert_eq(cf.get_value("display", "window/vsync/vsync_mode"), 0)
	assert_eq(cf.get_value("display", "window/size/window_width_override"), 640)
	assert_eq(cf.get_value("display", "window/size/window_height_override"), 360)


func test_merge_override_cfg_from_nothing() -> void:
	var text := GdTMCaptureOptions.merge_override_cfg(
		"", GdTMCaptureOptions.project_overrides({"resolution": "800x600"})
	)
	var cf := ConfigFile.new()
	assert_eq(cf.parse(text), OK)
	assert_eq(cf.get_value("display", "window/size/window_width_override"), 800)
