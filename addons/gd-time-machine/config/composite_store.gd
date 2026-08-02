@tool
extends ConfigStore
class_name CompositeConfigStore

## Combines an EditorSettings-backed default store with an optional per-scene
## local store (ConfigFile under addons/gd-time-machine/config/state/).
##
## The local [default] section is the source of truth for the default profile:
##   - First read with no local [default] seeds it from the EditorSettings default.
##   - save_default_profile() writes through to both stores.
##   - get_scene_profile() → local per-scene override (only place scene profiles live).
##   - resolve_profile(scene_path) → scene override > local default > editor default.

var _editor_store: ConfigStore
var _local_store: ConfigStore


func _init(editor_store: ConfigStore = null, local_store: ConfigStore = null) -> void:
	_editor_store = editor_store if editor_store != null else EditorSettingsConfigStore.new()
	_local_store = local_store if local_store != null else ProjectLocalConfigStore.new()


func get_default_profile() -> RecordingProfile:
	var editor_default := _editor_store.get_default_profile()
	# Local default is the source of truth when its file has a default section.
	if _local_store is ProjectLocalConfigStore:
		var local_store := _local_store as ProjectLocalConfigStore
		var cf := local_store._load_config()
		if cf == null or not cf.has_section(ProjectLocalConfigStore.SECTION_DEFAULT):
			# First run: seed the local [default] from the editor default so
			# profiles.cfg becomes the single editable source of truth.
			local_store.save_default_profile(editor_default)
			return editor_default
		return _local_store.get_default_profile()
	return editor_default


func get_scene_profile(scene_path: String) -> RecordingProfile:
	return _local_store.get_scene_profile(scene_path)


func save_default_profile(profile: RecordingProfile) -> void:
	_editor_store.save_default_profile(profile)
	# Write through to the local file too: profiles.cfg [default] is the
	# user-facing place for global defaults.
	if _local_store is ProjectLocalConfigStore:
		(_local_store as ProjectLocalConfigStore).save_default_profile(profile)


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
