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


## Returns true if the backend can be selected right now (e.g. external tools
## installed, platform supported). UI disables the dropdown item when false.
## For launchable backends (e.g. OBS) this means installed/launchable — not
## merely "currently running". Runtime reachability is surfaced via
## get_runtime_hint(), never by greying out a launchable backend.
func is_available() -> bool:
	return false


## Human reason why the backend is unavailable ("" when available). UI shows
## this as the disabled item's tooltip and in the install-hint dialog.
## Common interface shared with ffmpeg-dependent formats (see
## GdTMOutputFormat.warning_text / GdTMFFmpegConvert plumbing).
func get_unavailable_reason() -> String:
	if is_available():
		return ""
	var n := get_backend_name()
	if n.is_empty():
		return "Backend is currently unavailable."
	return "%s is currently unavailable." % n


## Transient ready-state hint when available but not in steady state ("" when
## nothing to say). E.g. OBS installed-but-idle returns "will auto-launch".
## UI shows this as the enabled item's tooltip; the status line narration
## during Record covers the live progress.
func get_runtime_hint() -> String:
	return ""


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

## Emitted when a recording fails; carries the backend name and an error
## message describing what went wrong.
signal recording_error(backend_name: String, error_message: String)

## Info-level message shown in the dock status line. Optional per backend —
## the dock falls back to its default "Saved …" line when none is sent. The
## backend composes its own message (it owns the data and semantics); the UI
## only prints strings. Ordering contract: emit after recording_stopped when
## the message summarizes a finished capture, so the notice is the final
## status line. Consumers that re-emit this signal must forward it verbatim.
signal recording_notice(backend_name: String, message: String)

## Emitted when ffmpeg auto-conversion succeeds; carries the backend name and
## the converted clip path. Dock shows the converted path; the frames dir may
## be cleaned per the backend's policy.
signal recording_converted(backend_name: String, clip_path: String)
