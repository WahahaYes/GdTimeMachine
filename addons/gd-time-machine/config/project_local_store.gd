@tool
extends ConfigStore
class_name ProjectLocalConfigStore

## Per-scene overrides stored in a project-local ConfigFile.
##
## Default location: res://addons/gd-time-machine/config/state/profiles.cfg
## This file lives under the addon so all GdTimeMachine state is localized in
## one place (addons/gd-time-machine/config/state/). It is gitignored by
## default; teams can commit it if they want shared recording profiles.
##
## File format (ConfigFile = INI):
##   [default]
##   output_dir = res://media/captures
##   output_format = avi
##   fps = 60
##   duration = 30
##   backend_name = Godot Movie Maker
##
##   ["res://scenes/my_scene.tscn"]
##   output_dir = ...
##   ...

const DEFAULT_PATH := "res://addons/gd-time-machine/config/state/profiles.cfg"
const SECTION_DEFAULT := "default"

## Injected file path for testing. When empty, DEFAULT_PATH is used.
var _file_path: String = ""

## Optional injected file content provider for tests: Callable that returns
## ConfigFile or null on load. When null, real file I/O is used.
var _loader: Callable
var _saver: Callable


func _init(file_path: String = "") -> void:
	_file_path = file_path if not file_path.is_empty() else DEFAULT_PATH


func get_default_profile() -> RecordingProfile:
	var cf := _load_config()
	if cf == null:
		return RecordingProfile.new()
	if not cf.has_section(SECTION_DEFAULT):
		return RecordingProfile.new()
	return _profile_from_section(cf, SECTION_DEFAULT)


func get_scene_profile(scene_path: String) -> RecordingProfile:
	var key := scene_path.strip_edges()
	if key.is_empty():
		return null
	var cf := _load_config()
	if cf == null:
		return null
	if not cf.has_section(key):
		return null
	return _profile_from_section(cf, key)


func save_default_profile(profile: RecordingProfile) -> void:
	var cf := _load_config()
	if cf == null:
		cf = ConfigFile.new()
	_write_profile_to_section(cf, SECTION_DEFAULT, profile)
	_save_config(cf)


func save_scene_profile(scene_path: String, profile: RecordingProfile) -> void:
	var key := scene_path.strip_edges()
	if key.is_empty():
		return
	var cf := _load_config()
	if cf == null:
		cf = ConfigFile.new()
	_write_profile_to_section(cf, key, profile)
	_save_config(cf)


func clear_scene_profile(scene_path: String) -> void:
	var key := scene_path.strip_edges()
	if key.is_empty():
		return
	var cf := _load_config()
	if cf == null:
		return
	if not cf.has_section(key):
		return
	cf.erase_section(key)
	_save_config(cf)


func get_all_scene_paths() -> Array:
	var cf := _load_config()
	if cf == null:
		return []
	var paths: Array = []
	for section in cf.get_sections():
		if section == SECTION_DEFAULT:
			continue
		paths.append(section)
	return paths


func _effective_path() -> String:
	return _file_path if not _file_path.is_empty() else DEFAULT_PATH


func _load_config() -> ConfigFile:
	if _loader.is_valid():
		return _loader.call() as ConfigFile
	var cf := ConfigFile.new()
	var err := cf.load(_effective_path())
	if err != OK:
		return null
	return cf


func _save_config(cf: ConfigFile) -> void:
	if _saver.is_valid():
		_saver.call(cf)
		return
	var path := _effective_path()
	# Ensure parent dir exists for project-local path.
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	cf.save(path)


func _profile_from_section(cf: ConfigFile, section: String) -> RecordingProfile:
	var d := {}
	for key in ["output_dir", "output_format", "fps", "duration", "backend_name"]:
		if cf.has_section_key(section, key):
			d[key] = cf.get_value(section, key)
	var p := RecordingProfile.from_dict(d)
	# Scene profiles already keyed by path; keep scene_path empty so resolution
	# doesn't double-encode it, but callers can fill it if needed.
	return p


func _write_profile_to_section(cf: ConfigFile, section: String, profile: RecordingProfile) -> void:
	var dict := profile.to_dict()
	for key in dict.keys():
		cf.set_value(section, key, dict[key])
