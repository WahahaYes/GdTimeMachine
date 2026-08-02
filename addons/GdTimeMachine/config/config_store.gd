@tool
extends RefCounted
class_name ConfigStore

## Abstract config store for per-scene and default recording profiles.
##
## Subclasses persist profiles in different media.
## Composite lookup (scene override > default) is implemented by the consumer;
## the store itself just reads/writes primitives.


func get_default_profile() -> RecordingProfile:
	return RecordingProfile.new()


func get_scene_profile(scene_path: String) -> RecordingProfile:
	return null


func save_default_profile(profile: RecordingProfile) -> void:
	pass


func save_scene_profile(scene_path: String, profile: RecordingProfile) -> void:
	pass


func clear_scene_profile(scene_path: String) -> void:
	pass


func get_all_scene_paths() -> Array:
	return []


## Resolves effective profile: scene override if present, otherwise default.
## Public so dock and tests can share the same resolution order.
func resolve_profile(scene_path: String) -> RecordingProfile:
	var sp: String = scene_path.strip_edges()
	if not sp.is_empty():
		var scene_profile := get_scene_profile(sp)
		if scene_profile != null:
			return scene_profile
	return get_default_profile()
