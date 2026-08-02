extends GutTest


# Fake EditorSettings that wraps a Dictionary so tests never touch engine singletons.
class FakeEditorSettings:
	var data := {}

	func get_setting(key: String) -> Variant:
		if data.has(key):
			return data[key]
		return null

	func set_setting(key: String, value: Variant) -> void:
		data[key] = value


func test_editor_settings_store_default_profile_uses_values() -> void:
	var es := FakeEditorSettings.new()
	es.data[EditorSettingsConfigStore.KEY_OUTPUT_DIR] = "res://my_out"
	es.data[EditorSettingsConfigStore.KEY_OUTPUT_FORMAT] = "ogv"
	es.data[EditorSettingsConfigStore.KEY_DEFAULT_FPS] = 30
	es.data[EditorSettingsConfigStore.KEY_DEFAULT_DURATION] = 5.0
	es.data[EditorSettingsConfigStore.KEY_DEFAULT_BACKEND] = "Godot Movie Maker"
	var store := EditorSettingsConfigStore.new(es)
	var profile := store.get_default_profile()
	assert_eq(profile.output_dir, "res://my_out")
	assert_eq(profile.output_format, GdTMOutputFormat.Format.OGV)
	assert_eq(profile.fps, 30)
	assert_eq(profile.duration, 5.0)
	assert_eq(profile.backend_name, "Godot Movie Maker")


func test_editor_settings_store_default_profile_falls_back() -> void:
	var es := FakeEditorSettings.new()
	var store := EditorSettingsConfigStore.new(es)
	var profile := store.get_default_profile()
	assert_false(profile.output_dir.is_empty())
	assert_eq(profile.output_format, GdTMOutputFormat.DEFAULT)


func test_editor_settings_store_save_writes_keys() -> void:
	var es := FakeEditorSettings.new()
	var store := EditorSettingsConfigStore.new(es)
	var p := RecordingProfile.new()
	p.output_dir = "res://out2"
	p.output_format = GdTMOutputFormat.Format.PNG
	p.fps = 24
	p.duration = 10.0
	p.backend_name = "Godot Movie Maker"
	store.save_default_profile(p)
	assert_eq(es.data[EditorSettingsConfigStore.KEY_OUTPUT_DIR], "res://out2")
	assert_eq(es.data[EditorSettingsConfigStore.KEY_OUTPUT_FORMAT], "png")
	assert_eq(es.data[EditorSettingsConfigStore.KEY_DEFAULT_FPS], 24)
	assert_eq(es.data[EditorSettingsConfigStore.KEY_DEFAULT_DURATION], 10.0)


func test_editor_settings_store_scene_profile_always_null() -> void:
	var es := FakeEditorSettings.new()
	var store := EditorSettingsConfigStore.new(es)
	assert_null(store.get_scene_profile("res://a.tscn"))


func test_project_local_store_save_and_load_scene_profile() -> void:
	var cf := ConfigFile.new()
	var captured: Array = []
	var loader := func() -> ConfigFile: return cf
	var saver := func(c: ConfigFile) -> void: captured.append(c)

	var store := ProjectLocalConfigStore.new("res://test_local.cfg")
	store._loader = loader
	store._saver = saver

	var p := RecordingProfile.new()
	p.output_dir = "res://scene_out"
	p.output_format = GdTMOutputFormat.Format.OGV
	p.fps = 30
	p.duration = 15.0

	store.save_scene_profile("res://scenes/foo.tscn", p)

	assert_eq(captured.size(), 1)
	# Now load back
	var loaded := store.get_scene_profile("res://scenes/foo.tscn")
	assert_not_null(loaded)
	assert_eq(loaded.output_dir, "res://scene_out")
	assert_eq(loaded.output_format, GdTMOutputFormat.Format.OGV)
	assert_eq(loaded.fps, 30)
	assert_eq(loaded.duration, 15.0)


func test_project_local_store_clear_scene() -> void:
	var cf := ConfigFile.new()
	var store := ProjectLocalConfigStore.new("res://test_local.cfg")
	store._loader = func() -> ConfigFile: return cf
	store._saver = func(_c: ConfigFile) -> void: pass

	var p := RecordingProfile.new()
	store.save_scene_profile("res://a.tscn", p)
	assert_not_null(store.get_scene_profile("res://a.tscn"))
	store.clear_scene_profile("res://a.tscn")
	assert_null(store.get_scene_profile("res://a.tscn"))


func test_project_local_store_get_all_scene_paths() -> void:
	var cf := ConfigFile.new()
	var store := ProjectLocalConfigStore.new("res://test_local.cfg")
	store._loader = func() -> ConfigFile: return cf
	store._saver = func(_c: ConfigFile) -> void: pass

	store.save_scene_profile("res://a.tscn", RecordingProfile.new())
	store.save_scene_profile("res://b.tscn", RecordingProfile.new())
	var paths := store.get_all_scene_paths()
	assert_eq(paths.size(), 2)
	assert_true(paths.has("res://a.tscn"))
	assert_true(paths.has("res://b.tscn"))


func test_project_local_store_default_profile() -> void:
	var cf := ConfigFile.new()
	var store := ProjectLocalConfigStore.new("res://test_local.cfg")
	store._loader = func() -> ConfigFile: return cf
	store._saver = func(_c: ConfigFile) -> void: pass

	# No default section yet -> blank default
	var d0 := store.get_default_profile()
	assert_false(d0.output_dir.is_empty())

	# Save default
	var p := RecordingProfile.new()
	p.output_dir = "res://local_default"
	p.output_format = GdTMOutputFormat.Format.AVI
	store.save_default_profile(p)
	var d1 := store.get_default_profile()
	assert_eq(d1.output_dir, "res://local_default")


func test_composite_store_seeds_local_default_on_first_run() -> void:
	var es := FakeEditorSettings.new()
	es.data[EditorSettingsConfigStore.KEY_OUTPUT_DIR] = "res://editor_default"
	var editor_store := EditorSettingsConfigStore.new(es)

	var cf := ConfigFile.new()
	var local_store := ProjectLocalConfigStore.new("res://test_local.cfg")
	local_store._loader = func() -> ConfigFile: return cf
	local_store._saver = func(_c: ConfigFile) -> void: pass

	var composite := CompositeConfigStore.new(editor_store, local_store)

	# No [default] section yet -> first read returns editor default AND seeds
	# the local [default] section so profiles.cfg becomes the source of truth.
	var def_profile := composite.get_default_profile()
	assert_eq(def_profile.output_dir, "res://editor_default")
	assert_true(cf.has_section(ProjectLocalConfigStore.SECTION_DEFAULT))
	assert_eq(
		cf.get_value(ProjectLocalConfigStore.SECTION_DEFAULT, "output_dir"), "res://editor_default"
	)

	# Second read: local [default] now exists -> comes from the local file.
	# Change the local file directly to prove it is now authoritative.
	cf.set_value(ProjectLocalConfigStore.SECTION_DEFAULT, "output_dir", "res://user_edited")
	var def2 := composite.get_default_profile()
	assert_eq(def2.output_dir, "res://user_edited")


func test_composite_store_save_default_writes_through_to_local() -> void:
	var es := FakeEditorSettings.new()
	var editor_store := EditorSettingsConfigStore.new(es)

	var cf := ConfigFile.new()
	var local_store := ProjectLocalConfigStore.new("res://test_local.cfg")
	local_store._loader = func() -> ConfigFile: return cf
	local_store._saver = func(_c: ConfigFile) -> void: pass

	var composite := CompositeConfigStore.new(editor_store, local_store)

	var p := RecordingProfile.new()
	p.output_dir = "res://my_defaults"
	p.output_format = GdTMOutputFormat.Format.OGV
	p.fps = 30
	p.duration = 45.0
	p.backend_name = "Godot Movie Maker"
	composite.save_default_profile(p)

	# Both stores get the default.
	assert_eq(es.data[EditorSettingsConfigStore.KEY_OUTPUT_DIR], "res://my_defaults")
	assert_true(cf.has_section(ProjectLocalConfigStore.SECTION_DEFAULT))
	assert_eq(
		cf.get_value(ProjectLocalConfigStore.SECTION_DEFAULT, "output_dir"), "res://my_defaults"
	)
	assert_eq(cf.get_value(ProjectLocalConfigStore.SECTION_DEFAULT, "output_format"), "ogv")

	# And the composite reads it back as the authoritative default.
	var loaded := composite.get_default_profile()
	assert_eq(loaded.output_dir, "res://my_defaults")
	assert_eq(loaded.output_format, GdTMOutputFormat.Format.OGV)


func test_composite_store_resolves_scene_over_default() -> void:
	var es := FakeEditorSettings.new()
	es.data[EditorSettingsConfigStore.KEY_OUTPUT_DIR] = "res://editor_default"
	var editor_store := EditorSettingsConfigStore.new(es)

	var cf := ConfigFile.new()
	var local_store := ProjectLocalConfigStore.new("res://test_local.cfg")
	local_store._loader = func() -> ConfigFile: return cf
	local_store._saver = func(_c: ConfigFile) -> void: pass

	var composite := CompositeConfigStore.new(editor_store, local_store)

	# No scene override -> editor default
	var def_profile := composite.get_default_profile()
	assert_eq(def_profile.output_dir, "res://editor_default")

	# Save scene override
	var scene_p := RecordingProfile.new()
	scene_p.output_dir = "res://scene_specific"
	local_store.save_scene_profile("res://scenes/special.tscn", scene_p)

	var resolved := composite.resolve_profile("res://scenes/special.tscn")
	assert_eq(resolved.output_dir, "res://scene_specific")

	# Different scene -> default
	var other := composite.resolve_profile("res://scenes/other.tscn")
	assert_eq(other.output_dir, "res://editor_default")
