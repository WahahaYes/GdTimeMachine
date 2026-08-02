@tool
extends ConfigStore
class_name EditorSettingsConfigStore

## Stores the default RecordingProfile in EditorSettings under gd_time_machine/*.
##
## Keys match the pre-existing default_* settings plus output_format.
## Scene profiles are not stored here — they live in ProjectLocalStore.

const KEY_OUTPUT_DIR := "gd_time_machine/recorder/output_dir"
const KEY_DEFAULT_DURATION := "gd_time_machine/recorder/default_duration"
const KEY_DEFAULT_FPS := "gd_time_machine/recorder/default_fps"
const KEY_DEFAULT_BACKEND := "gd_time_machine/recorder/default_backend"
const KEY_OUTPUT_FORMAT := "gd_time_machine/recorder/output_format"

const FALLBACK_DIR := "res://media/captures"
const FALLBACK_DURATION := 30.0
const FALLBACK_FPS := 60

## Injected EditorSettings. When null, falls back to EditorInterface singleton
## in tool context; tests inject a fake Dictionary-wrapped object.
var _editor_settings: Object = null


func _init(editor_settings: Object = null) -> void:
	_editor_settings = editor_settings


func _get_es() -> Object:
	if _editor_settings != null:
		return _editor_settings
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return null


func _get_setting(key: String) -> Variant:
	var es := _get_es()
	if es == null:
		return null
	if es.has_method("get_setting"):
		return es.get_setting(key)
	return null


func _set_setting(key: String, value: Variant) -> void:
	var es := _get_es()
	if es == null:
		return
	if es.has_method("set_setting"):
		es.set_setting(key, value)


func get_default_profile() -> RecordingProfile:
	var p := RecordingProfile.new()
	var v: Variant
	v = _get_setting(KEY_OUTPUT_DIR)
	p.output_dir = str(v) if v != null and not str(v).is_empty() else FALLBACK_DIR
	v = _get_setting(KEY_OUTPUT_FORMAT)
	if v != null:
		p.output_format = GdTMOutputFormat.from_string(str(v))
	else:
		p.output_format = GdTMOutputFormat.DEFAULT
	v = _get_setting(KEY_DEFAULT_FPS)
	p.fps = int(v) if v != null else FALLBACK_FPS
	v = _get_setting(KEY_DEFAULT_DURATION)
	p.duration = float(v) if v != null else FALLBACK_DURATION
	v = _get_setting(KEY_DEFAULT_BACKEND)
	p.backend_name = str(v) if v != null else ""
	return p


func save_default_profile(profile: RecordingProfile) -> void:
	_set_setting(KEY_OUTPUT_DIR, profile.output_dir)
	_set_setting(KEY_OUTPUT_FORMAT, GdTMOutputFormat.to_extension(profile.output_format))
	_set_setting(KEY_DEFAULT_FPS, profile.fps)
	_set_setting(KEY_DEFAULT_DURATION, profile.duration)
	if not profile.backend_name.is_empty():
		_set_setting(KEY_DEFAULT_BACKEND, profile.backend_name)


func get_scene_profile(_scene_path: String) -> RecordingProfile:
	return null


func get_all_scene_paths() -> Array:
	return []
