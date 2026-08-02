@tool
extends RefCounted
class_name RecordingProfile

## Per-recording configuration, independent of editor ProjectSettings.
##
## Owned by ConfigStore. Serializable via to_dict()/from_dict() so stores can
## persist it in whatever medium they use (EditorSettings, ConfigFile).

## Output directory, res:// or absolute OS path.
var output_dir: String = "res://media/captures"

## Target format.
var output_format: GdTMOutputFormat.Format = GdTMOutputFormat.DEFAULT

## Target frames per second.
var fps: int = 60

## Desired duration in seconds; 0 = manual (record until Stop).
var duration: float = 30.0

## Scene path to launch. Empty = current or main scene.
## Not persisted as part of a "default" profile; only per-scene profiles store
## a scene_path implicitly via the store key. Kept here for local editing.
var scene_path: String = ""

## Preferred backend name (e.g. "Godot Movie Maker").
## Empty = use whatever the controller selects.
var backend_name: String = ""


## Duplicates this profile.
func duplicate_profile() -> RecordingProfile:
	var p := RecordingProfile.new()
	p.output_dir = output_dir
	p.output_format = output_format
	p.fps = fps
	p.duration = duration
	p.scene_path = scene_path
	p.backend_name = backend_name
	return p


## Serializes to a plain Dictionary (keys are store-agnostic).
func to_dict() -> Dictionary:
	return {
		"output_dir": output_dir,
		"output_format": GdTMOutputFormat.to_extension(output_format),
		"fps": fps,
		"duration": duration,
		"backend_name": backend_name,
	}


## Deserializes from a Dictionary. Unknown/invalid keys use defaults.
static func from_dict(d: Dictionary) -> RecordingProfile:
	var p := RecordingProfile.new()
	if d.has("output_dir"):
		p.output_dir = str(d["output_dir"])
	if d.has("output_format"):
		p.output_format = GdTMOutputFormat.from_string(str(d["output_format"]))
	if d.has("fps"):
		p.fps = int(d["fps"])
	if d.has("duration"):
		p.duration = float(d["duration"])
	if d.has("scene_path"):
		p.scene_path = str(d["scene_path"])
	if d.has("backend_name"):
		p.backend_name = str(d["backend_name"])
	return p
