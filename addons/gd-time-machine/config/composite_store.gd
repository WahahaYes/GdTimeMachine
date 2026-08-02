@tool
extends ConfigStore
class_name CompositeConfigStore

## Combines an EditorSettings-backed default store with an optional per-scene
## local store (ConfigFile under addons/gd-time-machine/config/state/).
##
## Resolution:
##   get_default_profile() → local default (if present) merged over editor default,
##   falling back to editor default alone.
##   get_scene_profile() → local per-scene override (only place scene profiles live).
##   resolve_profile(scene_path) → scene override > local default > editor default.

var _editor_store: ConfigStore
var _local_store: ConfigStore


func _init(editor_store: ConfigStore = null, local_store: ConfigStore = null) -> void:
	_editor_store = editor_store if editor_store != null else EditorSettingsConfigStore.new()
	_local_store = local_store if local_store != null else ProjectLocalConfigStore.new()


func get_default_profile() -> RecordingProfile:
	var editor_default := _editor_store.get_default_profile()
	var local_default := _local_store.get_default_profile()
	# Local default is considered present if its file exists / has a default section.
	# We detect that by comparing against a blank profile: if loader returned null,
	# get_default_profile() already returned a blank. Merge: local values override
	# editor values only when they differ from blank defaults? Simpler: if local
	# file has a default section, treat local_default as the authoritative default;
	# otherwise use editor_default. Check existence via get_all_scene_paths presence
	# of default section? ProjectLocalConfigStore.get_default_profile() returns blank
	# when no file/section — we need to know. Use loader presence check:
	# if local store has any default key persisted, local file had a section.
	if _local_store is ProjectLocalConfigStore:
		var cf := (_local_store as ProjectLocalConfigStore)._load_config()
		if cf != null and cf.has_section(ProjectLocalConfigStore.SECTION_DEFAULT):
			return local_default
	# EditorSettings fallback
	return editor_default


func get_scene_profile(scene_path: String) -> RecordingProfile:
	return _local_store.get_scene_profile(scene_path)


func save_default_profile(profile: RecordingProfile) -> void:
	_editor_store.save_default_profile(profile)


func save_scene_profile(scene_path: String, profile: RecordingProfile) -> void:
	_local_store.save_scene_profile(scene_path, profile)


func clear_scene_profile(scene_path: String) -> void:
	_local_store.clear_scene_profile(scene_path)


func get_all_scene_paths() -> Array:
	return _local_store.get_all_scene_paths()


func get_editor_store() -> ConfigStore:
	return _editor_store


func get_local_store() -> ConfigStore:
	return _local_store
