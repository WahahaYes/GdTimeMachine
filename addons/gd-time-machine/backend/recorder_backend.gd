@tool
extends Node
class_name RecorderBackend

## Abstract base class for recording backends.
##
## Subclasses implement the query/lifecycle methods and emit the recording
## signals. Backends are Nodes so they can use timers/process while attached
## to the scene tree; RecorderController owns their lifecycle.
##
## The `config` Dictionary passed to start() uses these keys:
##   output_path: String  — where the recording should be written
##   fps: int             — target FPS cap
##   duration: float      — desired duration in seconds
##   scene_path: String   — scene to launch (empty = current/main scene)
##   fullscreen: bool     — launch fullscreen

## How the backend captures footage: RESTART_SCENE backends (e.g. Movie
## Maker) can only record a freshly launched scene; IN_PLACE backends record
## the currently running scene and stop without killing it.
enum CaptureMode {
	RESTART_SCENE,  ## Needs a fresh scene launch; cannot capture the running scene.
	IN_PLACE,  ## Records the currently running scene and stops without killing it.
}


## Returns the backend's display name (e.g. "Movie Maker"). Deliberately not
## named get_name() — Node already declares get_name() -> StringName, and an
## incompatible override is a compile error.
func get_backend_name() -> String:
	return ""


## Returns a human-readable description of what this backend does and how it
## captures footage. Used by the UI to inform the user.
func get_description() -> String:
	return ""


## Returns true if the backend can be used right now (e.g. external tools
## available, platform supported). UI disables the backend when false.
func is_available() -> bool:
	return false


## Returns true while a recording is in progress.
func is_recording() -> bool:
	return false


## Returns the backend's capture mode. UI uses this to be honest about
## behavior (e.g. greying out the in-game record button when the backend
## would restart the scene the user is looking at). Defaults to
## RESTART_SCENE, the conservative answer; in-place backends override.
func get_capture_mode() -> CaptureMode:
	return CaptureMode.RESTART_SCENE


## Starts a recording with the given config. Keys: output_path (String,
## where the recording is written), fps (int, target FPS cap), duration
## (float, desired duration in seconds), scene_path (String, scene to
## launch, empty = current/main scene), fullscreen (bool, launch
## fullscreen). Emits recording_started on success or recording_error on
## failure. Subclasses override.
func start(config: Dictionary) -> void:
	pass


## Stops the current recording. Emits recording_stopped when finished.
## Subclasses override.
func stop() -> void:
	pass


## Emitted when a recording starts; carries the backend name and the
## output path being written to.
signal recording_started(backend_name: String, output_path: String)

## Emitted when a recording stops; carries the backend name and the
## output path that was written.
signal recording_stopped(backend_name: String, output_path: String)

## Emitted periodically while recording; carries the backend name and the
## number of seconds elapsed so far.
signal recording_progress(backend_name: String, elapsed_sec: float)

## Emitted when a recording fails; carries the backend name and an error
## message describing what went wrong.
signal recording_error(backend_name: String, error_message: String)
