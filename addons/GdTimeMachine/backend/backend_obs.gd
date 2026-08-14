@tool
extends RecorderBackend
class_name BackendOBS

## IN_PLACE backend that records via OBS Studio over obs-websocket 5.x.
##
## Phase 0 (the auth gate in PLAN_obs_backend_v2.md §3) locks the
## settings-read plumbing only: _get_obs_settings() resolves
## gd_time_machine/obs/* EditorSettings-first-then-ProjectSettings and is the
## single seam BackendOBS uses to obtain host/port/password. The connection /
## state machine / availability semantics land in Phase 2 (§5).

## Injected EditorSettings. When null, falls back to the EditorInterface
## singleton in tool context; GUT injects a fake store. Mirrors
## EditorSettingsConfigStore._get_es() — the proven 4.x access path.
## Engine.has_singleton("EditorSettings") is FALSE even in the 4.7 editor, so
## the v1 check could never fire — that dead branch is why the password set in
## Project > Editor Settings never reached _password (Bug 7 plumbing).
var _editor_settings: Object = null


## Returns the settings store to read, or null when running outside the editor
## (headless GUT) and no fake was injected.
func _get_es() -> Object:
	if _editor_settings != null:
		return _editor_settings
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return null


## The single source of OBS connection settings. EditorSettings wins over
## ProjectSettings (Editor Settings > project.godot copy); empty password means
## "server auth disabled" and must be sent as NO authentication field (Phase 1).
func _get_obs_settings() -> Dictionary:
	return {
		"host": _get_setting_string("gd_time_machine/obs/host", OBSClient.DEFAULT_HOST),
		"port": _get_setting_int("gd_time_machine/obs/port", OBSClient.DEFAULT_PORT),
		"password": _get_setting_string("gd_time_machine/obs/password", ""),
		"scene": _get_setting_string("gd_time_machine/obs/scene", ""),
		"auto_launch": _get_setting_bool("gd_time_machine/obs/auto_launch", true),
		"auto_close": _get_setting_bool("gd_time_machine/obs/auto_close", true),
		"binary_path": _get_setting_string("gd_time_machine/obs/binary_path", ""),
	}


## First non-null value across EditorSettings → ProjectSettings → default.
func _read_setting(key: String) -> Variant:
	var es := _get_es()
	if es != null and es.has_method("get_setting"):
		var v: Variant = es.get_setting(key)
		if v != null:
			return v
	if ProjectSettings.has_setting(key):
		return ProjectSettings.get_setting(key)
	return null


func _get_setting_string(key: String, default: String) -> String:
	var v := _read_setting(key)
	return str(v) if v != null else default


func _get_setting_int(key: String, default: int) -> int:
	var v := _read_setting(key)
	return int(v) if v != null else default


func _get_setting_bool(key: String, default: bool) -> bool:
	var v := _read_setting(key)
	return bool(v) if v != null else default
