@tool
class_name GdTMCaptureOptions
extends RefCounted

## Per-capture options shared by the CLI and the editor's Movie Maker backend:
## validation, manifest defaulting, and the project-settings override that
## sizes Movie Maker footage.
##
## Movie Maker fixes its frame size when the game starts, from the project's
## window size settings; `--resolution` alone resizes the window but not the
## footage (verified on 4.7). So a resolution is applied twice: `--resolution`
## on the command line for the window, and the window size override in the
## captured project's override.cfg for the footage.

## Largest accepted width or height.
const MAX_DIMENSION := 16384

## Project settings that size the window, and with it the Movie Maker footage.
const WIDTH_OVERRIDE_KEY := "display/window/size/window_width_override"
const HEIGHT_OVERRIDE_KEY := "display/window/size/window_height_override"


## Returns "" when value is a usable resolution string ("1920x1080"), else a
## reason. Empty string means "project default" and is valid.
static func validate_resolution(value: Variant) -> String:
	if typeof(value) != TYPE_STRING:
		return "must be a string like 1920x1080"
	if String(value).is_empty():
		return ""
	if parse_resolution(String(value)) == Vector2i.ZERO:
		return "'%s' must be WIDTHxHEIGHT, e.g. 1920x1080 (1-%d each)" % [value, MAX_DIMENSION]
	return ""


## Parses "WIDTHxHEIGHT" (case-insensitive x, surrounding spaces ignored).
## Returns Vector2i.ZERO when empty or invalid.
static func parse_resolution(text: String) -> Vector2i:
	var regex := RegEx.new()
	regex.compile("^\\s*(\\d+)\\s*[xX]\\s*(\\d+)\\s*$")
	var m := regex.search(text)
	if m == null:
		return Vector2i.ZERO
	var w := int(m.get_string(1))
	var h := int(m.get_string(2))
	if w < 1 or h < 1 or w > MAX_DIMENSION or h > MAX_DIMENSION:
		return Vector2i.ZERO
	return Vector2i(w, h)


## Canonical "WIDTHxHEIGHT" for a valid resolution string, "" otherwise.
static func normalize_resolution(text: String) -> String:
	var size := parse_resolution(text)
	if size == Vector2i.ZERO:
		return ""
	return "%dx%d" % [size.x, size.y]


## Effective options for one manifest capture: entry values win over the
## manifest's top-level defaults. Keys: fullscreen (bool), resolution
## (String, "" = project default).
static func entry_options(entry: Dictionary, top: Dictionary) -> Dictionary:
	return {
		"fullscreen": bool(entry.get("fullscreen", false)),
		"resolution": normalize_resolution(str(entry.get("resolution", top.get("resolution", "")))),
	}


## Project-setting overrides a capture needs, as {setting path: value}.
static func project_overrides(options: Dictionary) -> Dictionary:
	var result := {}
	var size := parse_resolution(str(options.get("resolution", "")))
	if size != Vector2i.ZERO:
		result[WIDTH_OVERRIDE_KEY] = size.x
		result[HEIGHT_OVERRIDE_KEY] = size.y
	return result


## Merges overrides ({"section/key...": value}) into the override.cfg text
## existing_text and returns the new text. Keys already in the file are
## replaced; everything else in it is kept.
static func merge_override_cfg(existing_text: String, overrides: Dictionary) -> String:
	var cf := ConfigFile.new()
	if not existing_text.strip_edges().is_empty():
		cf.parse(existing_text)
	for path in overrides.keys():
		var p := str(path)
		var slash := p.find("/")
		cf.set_value(p.substr(0, slash), p.substr(slash + 1), overrides[path])
	return cf.encode_to_text()
