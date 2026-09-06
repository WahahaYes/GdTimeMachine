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

## Registry injected by RecorderController.register_backend(). Null in bare
## unit tests, where derivation falls back to natives only and requests use
## the factory seam below.
var _transcoder_registry: TranscoderRegistry = null

## Backend-owned transcoder child (one per backend, same lifetime as before).
## Created via the factory seam, which defaults to a registry-spawned
## instance so a future second registered transcoder plugs in without
## touching backends.
var _ffmpeg_converter: RecorderTranscoder = null


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


## Install-hint card for backends with an installable dependency ({} means
## none). Keys: "title", "body", "url", "suppress_key" (an EditorSettings
## flag the dialog persists when "don't show again" is ticked). The dock
## shows the dialog for ANY backend returning a card — a future
## HandBrake-dependent backend gets hints free. The card is
## a pure descriptor; the dock still gates on availability, so an installed
## backend never triggers its own not-found dialog.
func get_install_hint() -> Dictionary:
	return {}


## Native artifact this backend produces, used for transcoder capability
## matching. File backends name their container (Movie Maker → AVI, OBS →
## MP4); the Screenshot backend produces {"kind": "frames"}. Backends without
## transcodable output leave the default {} (deliverable = natives only).
func get_native_artifact() -> Dictionary:
	return {}


## Formats the backend records without a transcoder. The dock uses this for
## the plain (no " - ffmpeg" suffix) label, the warning suppression, and the
## needs-transcoder gate. Backends offering post-record transcoding keep
## natives narrow; deliverables come from derivation below.
func get_native_formats() -> Array:
	return []


## Every output format the backend can deliver: natives first (declared
## order), then every format with a registry edge from the native artifact
## (canonical GdTMOutputFormat.all_formats() order). No registry attached
## (bare unit tests) or no artifact declared (pure test doubles) means
## natives only — never a hardcoded mode list.
func get_supported_formats() -> Array:
	var out: Array = []
	for f in get_native_formats():
		if not out.has(f):
			out.append(f)
	var artifact := get_native_artifact()
	if artifact.is_empty() or _transcoder_registry == null:
		return out
	for f in GdTMOutputFormat.all_formats():
		if out.has(f):
			continue
		if _transcoder_registry.is_target_reachable(artifact, f):
			out.append(f)
	return out


## Whether the backend can deliver the given format (natively or via a
## transcoder edge).
func is_format_supported(format: GdTMOutputFormat.Format) -> bool:
	return get_supported_formats().has(format)


## Whether delivering the given format requires a transcoder for this
## backend: anything outside natives. Unknown-natives doubles answer
## conservatively (everything needs one).
func format_needs_ffmpeg(format: GdTMOutputFormat.Format) -> bool:
	return not get_native_formats().has(format)


## Factory seam for the backend-owned converter — overridden in tests to
## inject a fake. Explicit overrides always win over registry resolution, so
## test doubles keep working with or without a registry attached. The default
## spawns the first registered transcoder type (registration order is the
## future transcoders/active preference point), else a built-in ffmpeg.
func _create_ffmpeg_converter() -> RecorderTranscoder:
	if _transcoder_registry != null:
		var spawned := _transcoder_registry.spawn_preferred()
		if spawned != null:
			return spawned
	return GdTMFFmpegConvert.new()


## Ensures the backend-owned converter child exists and wires the shared
## terminal handlers (exactly once per instance lifetime).
func _ensure_ffmpeg_converter() -> void:
	if _ffmpeg_converter != null:
		return
	_ffmpeg_converter = _create_ffmpeg_converter()
	if is_inside_tree():
		add_child(_ffmpeg_converter)
	_ffmpeg_converter.conversion_succeeded.connect(_on_shared_transcode_succeeded)
	_ffmpeg_converter.conversion_failed.connect(_on_shared_transcode_failed)
	_ffmpeg_converter.transcoder_not_found.connect(_on_shared_transcoder_not_found)


## Single transcode entry point shared by all backends (replaces the old
## per-backend adapter trios). Uses the backend-owned converter (same
## one-job-at-a-time concurrency as before), emits the Converting… notice,
## and dispatches. Input shapes: file {"kind":"file","path":...} or frames
## {"kind":"frames","dir":...,"frame_ext":...,"measured_fps":...}. Options:
## "target" (Format), "label" (String), "fps" (int), "clean" (bool).
func request_transcode(input: Dictionary, output_path: String, options: Dictionary) -> bool:
	var target: GdTMOutputFormat.Format = options.get("target", GdTMOutputFormat.Format.MP4)
	var label := str(options.get("label", GdTMOutputFormat.to_extension(target)))
	_ensure_ffmpeg_converter()
	if _ffmpeg_converter == null:
		recording_error.emit(get_backend_name(), "No transcoder available for %s." % label)
		return false
	recording_notice.emit(get_backend_name(), "Converting to %s…" % label.to_lower())
	_ffmpeg_converter.convert_async(input, output_path, options)
	return true


## Shared terminal handlers: the single signal-shape adapter
## (transcoder-level → backend-level recording_*).
func _on_shared_transcode_succeeded(clip_path: String) -> void:
	recording_converted.emit(get_backend_name(), clip_path)
	recording_notice.emit(
		get_backend_name(),
		"Converted to %s" % clip_path.get_file() if not clip_path.is_empty() else "Converted"
	)


func _on_shared_transcode_failed(error_message: String, detail: String) -> void:
	var full := error_message
	if not detail.is_empty():
		full = "%s\n%s" % [error_message, detail]
	recording_error.emit(get_backend_name(), full)


func _on_shared_transcoder_not_found(message: String) -> void:
	recording_notice.emit(get_backend_name(), message)


## EditorSettings store when running inside the editor, else null. Headless
## runs (unit tests, CLI) resolve settings from ProjectSettings only. Mirrors
## BackendOBS._get_es()'s access path: EditorInterface directly, since
## Engine.has_singleton("EditorSettings") is FALSE even in the editor.
func _editor_settings_store() -> Object:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_settings()


## First entry of the transcoders/active preference list (EditorSettings →
## ProjectSettings, default ["ffmpeg"]). Selects whose transcoders/* section
## _transcoder_setting() resolves from.
func _active_transcoder_name() -> String:
	var raw: Variant = null
	var es := _editor_settings_store()
	if es != null and es.has_method("get_setting"):
		raw = es.get_setting("transcoders/active")
	if raw == null and ProjectSettings.has_setting("transcoders/active"):
		raw = ProjectSettings.get_setting("transcoders/active")
	var names := TranscoderRegistry.parse_active_names(raw)
	return names[0] if not names.is_empty() else "ffmpeg"


## Transcoder-scoped setting: reads transcoders/<active>/<suffix>
## (EditorSettings → ProjectSettings), else default.
func _transcoder_setting(suffix: String, default: Variant) -> Variant:
	var key := "transcoders/%s/%s" % [_active_transcoder_name(), suffix]
	var es := _editor_settings_store()
	if es != null and es.has_method("get_setting"):
		var v: Variant = es.get_setting(key)
		if v != null:
			return v
	if ProjectSettings.has_setting(key):
		return ProjectSettings.get_setting(key)
	return default


## Reads the auto-convert toggle: config override wins, otherwise the active
## transcoder's section (see _transcoder_setting), default true.
func _get_auto_convert_setting(config: Dictionary) -> bool:
	if config.has("auto_convert"):
		return bool(config["auto_convert"])
	return bool(_transcoder_setting("auto_convert", true))


## Whether frames/intermediates should be deleted after a successful
## convert. File backends keep their masters (clean: false at the call
## site); the frames backend honors this toggle.
func _get_clean_on_success_setting() -> bool:
	return bool(_transcoder_setting("clean_frames", true))


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
