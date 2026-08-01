@tool
extends Node
class_name RecorderBackend

## Abstract base class for recording backends.
##
## Subclasses implement the query/lifecycle methods and emit the recording
## signals. Backends are Nodes so they can use timers/process while attached
## to the scene tree (RecorderController owns their lifecycle).
##
## The `config` Dictionary passed to start() uses these keys:
##   output_path: String  — where the recording should be written
##   fps: int             — target FPS cap
##   duration: float      — desired duration in seconds
##   scene_path: String   — scene to launch (empty = current/main scene)
##   fullscreen: bool     — launch fullscreen

# NOTE: deliberately not named get_name() — Node already declares
# get_name() -> StringName, and an incompatible override is a compile error.
func get_backend_name() -> String:
	return ""


func get_description() -> String:
	return ""


func is_available() -> bool:
	return false


func is_recording() -> bool:
	return false


func start(config: Dictionary) -> void:
	pass


func stop() -> void:
	pass


signal recording_started(backend_name: String, output_path: String)
signal recording_stopped(backend_name: String, output_path: String)
signal recording_progress(backend_name: String, elapsed_sec: float)
signal recording_error(backend_name: String, error_message: String)
