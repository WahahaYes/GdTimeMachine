@tool
extends GutTest


## Fake EditorSettings for tests. No has_method override — Object.has_method
## already resolves script methods, and an override would clash with the
## native signature.
class FakeEditorSettings:
	var _data: Dictionary = {}

	func get_setting(key: String) -> Variant:
		return _data.get(key)

	func set_setting(key: String, value: Variant) -> void:
		_data[key] = value


func before_each() -> void:
	pass


## EditorSettingsConfigStore tests


func test_editor_store_returns_defaults_when_no_settings() -> void:
	var fake_es := FakeEditorSettings.new()
	var store := EditorSettingsConfigStore.new(fake_es)
	var profile := store.get_default_profile()
	assert_eq(profile.output_dir, "res://media/captures")
	assert_eq(profile.fps, 60)
	assert_eq(profile.duration, 30.0)
	assert_eq(profile.output_format, GdTMOutputFormat.DEFAULT)
	assert_eq(profile.backend_name, "")


func test_editor_store_reads_custom_settings() -> void:
	var fake_es := FakeEditorSettings.new()
	fake_es.set_setting("gd_time_machine/recorder/output_dir", "res://custom")
	fake_es.set_setting("gd_time_machine/recorder/default_fps", 30)
	fake_es.set_setting("gd_time_machine/recorder/default_duration", 10.0)
	fake_es.set_setting("gd_time_machine/recorder/output_format", "mp4")
	fake_es.set_setting("gd_time_machine/recorder/default_backend", "OBS Studio")
	var store := EditorSettingsConfigStore.new(fake_es)
	var profile := store.get_default_profile()
	assert_eq(profile.output_dir, "res://custom")
	assert_eq(profile.fps, 30)
	assert_eq(profile.duration, 10.0)
	assert_eq(profile.output_format, GdTMOutputFormat.Format.MP4)
	assert_eq(profile.backend_name, "OBS Studio")


func test_editor_store_save_write_through() -> void:
	var fake_es := FakeEditorSettings.new()
	var store := EditorSettingsConfigStore.new(fake_es)
	var profile := RecordingProfile.new()
	profile.output_dir = "res://saved"
	profile.fps = 45
	profile.duration = 15.0
	profile.output_format = GdTMOutputFormat.Format.OGV
	profile.backend_name = "Custom Backend"
	store.save_default_profile(profile)
	assert_eq(fake_es.get_setting("gd_time_machine/recorder/output_dir"), "res://saved")
	assert_eq(fake_es.get_setting("gd_time_machine/recorder/default_fps"), 45)
	assert_eq(fake_es.get_setting("gd_time_machine/recorder/default_duration"), 15.0)
	assert_eq(fake_es.get_setting("gd_time_machine/recorder/output_format"), "ogv")
	assert_eq(fake_es.get_setting("gd_time_machine/recorder/default_backend"), "Custom Backend")


func test_editor_store_scene_profile_returns_null() -> void:
	var store := EditorSettingsConfigStore.new()
	assert_null(store.get_scene_profile("res://scene.tscn"))
	assert_eq(store.get_all_scene_paths(), [])


## ProjectLocalConfigStore tests.
## The _loader/_saver seams take no-arg/one-arg callables; the loader must
## return the in-memory ConfigFile the store mutates.


func _wire_store(store: ProjectLocalConfigStore, cf: ConfigFile) -> void:
	store._loader = func() -> ConfigFile: return cf
	store._saver = func(_c: ConfigFile) -> void: pass


func test_project_local_store_returns_defaults_when_no_file() -> void:
	var store := ProjectLocalConfigStore.new("")
	store._loader = func() -> ConfigFile: return ConfigFile.new()
	store._saver = func(_c: ConfigFile) -> void: pass
	var profile := store.get_default_profile()
	assert_eq(profile.output_dir, "res://media/captures")
	assert_eq(profile.fps, 60)
	assert_eq(profile.duration, 30.0)


func test_project_local_store_reads_default_section() -> void:
	var cf := ConfigFile.new()
	cf.set_value("default", "output_dir", "res://local")
	cf.set_value("default", "fps", 24)
	cf.set_value("default", "duration", 5.0)
	cf.set_value("default", "output_format", "png")
	cf.set_value("default", "backend_name", "Local Backend")
	var store := ProjectLocalConfigStore.new("")
	_wire_store(store, cf)
	var profile := store.get_default_profile()
	assert_eq(profile.output_dir, "res://local")
	assert_eq(profile.fps, 24)
	assert_eq(profile.duration, 5.0)
	assert_eq(profile.output_format, GdTMOutputFormat.Format.PNG)
	assert_eq(profile.backend_name, "Local Backend")


func test_project_local_store_scene_override() -> void:
	var cf := ConfigFile.new()
	cf.set_value("default", "output_dir", "res://default")
	# Section keys are stored unquoted in memory (the INI writer only quotes
	# on disk); the store reads them via the raw scene path.
	cf.set_value("res://scenes/level1.tscn", "output_dir", "res://scene_override")
	var store := ProjectLocalConfigStore.new("")
	_wire_store(store, cf)
	var default_p := store.get_default_profile()
	var scene_p := store.get_scene_profile("res://scenes/level1.tscn")
	assert_eq(default_p.output_dir, "res://default")
	assert_eq(scene_p.output_dir, "res://scene_override")


func test_project_local_store_save_and_clear_scene_profile() -> void:
	var cf := ConfigFile.new()
	var store := ProjectLocalConfigStore.new("")
	store._loader = func() -> ConfigFile: return cf
	store._saver = func(_c: ConfigFile) -> void: pass
	var p := RecordingProfile.new()
	p.output_dir = "res://new_scene"
	p.fps = 120
	store.save_scene_profile("res://new.tscn", p)
	assert_true(cf.has_section("res://new.tscn"))
	assert_eq(cf.get_value("res://new.tscn", "fps"), 120)
	store.clear_scene_profile("res://new.tscn")
	assert_false(cf.has_section("res://new.tscn"))


func test_project_local_store_get_all_scene_paths() -> void:
	var cf := ConfigFile.new()
	cf.set_value("default", "output_dir", "res://default")
	cf.set_value("res://a.tscn", "output_dir", "res://a")
	cf.set_value("res://b.tscn", "output_dir", "res://b")
	var store := ProjectLocalConfigStore.new("")
	_wire_store(store, cf)
	var paths := store.get_all_scene_paths()
	assert_true("res://a.tscn" in paths)
	assert_true("res://b.tscn" in paths)
	assert_false("default" in paths)


## CompositeConfigStore tests


func test_composite_store_seeds_local_default_on_first_run() -> void:
	var fake_es := FakeEditorSettings.new()
	fake_es.set_setting("gd_time_machine/recorder/output_dir", "res://editor")
	var cf := ConfigFile.new()
	var comp := CompositeConfigStore.new(
		EditorSettingsConfigStore.new(fake_es), ProjectLocalConfigStore.new("")
	)
	(comp.get_local_store() as ProjectLocalConfigStore)._loader = func() -> ConfigFile: return cf
	(comp.get_local_store() as ProjectLocalConfigStore)._saver = func(_c: ConfigFile) -> void: pass
	# No local [default] section yet → first read returns the editor default
	# AND seeds profiles.cfg so it becomes the source of truth.
	var p1 := comp.get_default_profile()
	assert_eq(p1.output_dir, "res://editor")
	assert_true(cf.has_section(ProjectLocalConfigStore.SECTION_DEFAULT))


func test_composite_store_precedence_scene_over_local_default_over_editor() -> void:
	var fake_es := FakeEditorSettings.new()
	fake_es.set_setting("gd_time_machine/recorder/output_dir", "res://editor")
	var cf := ConfigFile.new()
	cf.set_value("default", "output_dir", "res://local_default")
	var comp := CompositeConfigStore.new(
		EditorSettingsConfigStore.new(fake_es), ProjectLocalConfigStore.new("")
	)
	(comp.get_local_store() as ProjectLocalConfigStore)._loader = func() -> ConfigFile: return cf
	(comp.get_local_store() as ProjectLocalConfigStore)._saver = func(_c: ConfigFile) -> void: pass
	# Local [default] present → it wins over the editor default.
	var p1 := comp.get_default_profile()
	assert_eq(p1.output_dir, "res://local_default")
	# Scene override wins over both.
	cf.set_value("res://scene.tscn", "output_dir", "res://scene_override")
	var p2 := comp.get_scene_profile("res://scene.tscn")
	assert_eq(p2.output_dir, "res://scene_override")


func test_composite_store_save_default_writes_both() -> void:
	var fake_es := FakeEditorSettings.new()
	var cf := ConfigFile.new()
	var comp := CompositeConfigStore.new(
		EditorSettingsConfigStore.new(fake_es), ProjectLocalConfigStore.new("")
	)
	(comp.get_local_store() as ProjectLocalConfigStore)._loader = func() -> ConfigFile: return cf
	(comp.get_local_store() as ProjectLocalConfigStore)._saver = func(_c: ConfigFile) -> void: pass
	var p := RecordingProfile.new()
	p.output_dir = "res://written"
	comp.save_default_profile(p)
	assert_eq(fake_es.get_setting("gd_time_machine/recorder/output_dir"), "res://written")
	assert_true(cf.has_section("default"))
	assert_eq(cf.get_value("default", "output_dir"), "res://written")


func test_composite_store_get_all_scene_paths_delegates() -> void:
	var cf := ConfigFile.new()
	cf.set_value("res://a.tscn", "output_dir", "res://a")
	var comp := CompositeConfigStore.new(
		EditorSettingsConfigStore.new(), ProjectLocalConfigStore.new("")
	)
	(comp.get_local_store() as ProjectLocalConfigStore)._loader = func() -> ConfigFile: return cf
	(comp.get_local_store() as ProjectLocalConfigStore)._saver = func(_c: ConfigFile) -> void: pass
	var paths := comp.get_all_scene_paths()
	assert_eq(paths, ["res://a.tscn"])
