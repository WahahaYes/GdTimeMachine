@tool
extends RefCounted
class_name GdTMOutputFormat

## Shared output format definition, used by both the config store and backends.
##
## This is the single source of truth for format → extension → display name.

enum Format {
	AVI,  ## .avi — MJPEG. Largest files, 4 GB cap.
	OGV,  ## .ogv — Theora+Vorbis. Smaller, editor binaries only.
	PNG,  ## .png — PNG sequence + WAV. Lossless master for external encode.
	JPG,  ## .jpg — JPG sequence. Compact lossy frames (screenshot backend).
}

## Default format. Kept as AVI so existing users see no behavior change.
const DEFAULT := Format.AVI


## Extension (without dot) for a format value.
static func to_extension(format: Format) -> String:
	match format:
		Format.AVI:
			return "avi"
		Format.OGV:
			return "ogv"
		Format.PNG:
			return "png"
		Format.JPG:
			return "jpg"
	return "avi"


## Human-readable label for the dock dropdown.
static func display_name(format: Format) -> String:
	match format:
		Format.AVI:
			return "AVI (.avi)"
		Format.OGV:
			return "OGV (.ogv)"
		Format.PNG:
			return "PNG sequence (.png)"
		Format.JPG:
			return "JPG sequence (.jpg)"
	return "AVI (.avi)"


## Parses a stored string ("avi", "ogv", "png", "jpg"/"jpeg", or full
## display name) into a Format. Unknown values fall back to DEFAULT.
static func from_string(s: String) -> Format:
	var t := s.strip_edges().to_lower()
	if t.begins_with("."):
		t = t.substr(1)
	# Allow both bare extension and display-name prefix.
	if t in ["avi", "avi (.avi)", "avi (.avi)"] or t.begins_with("avi"):
		return Format.AVI
	if t in ["ogv", "ogv (.ogv)"] or t.begins_with("ogv"):
		return Format.OGV
	if t in ["png", "png sequence", "png sequence (.png)"] or t.begins_with("png"):
		return Format.PNG
	if (
		t in ["jpg", "jpeg", "jpg sequence", "jpg sequence (.jpg)"]
		or t.begins_with("jpg")
		or t.begins_with("jpeg")
	):
		return Format.JPG
	return DEFAULT


## All format values in dropdown order. The dock filters this per-backend
## (Movie Maker offers AVI/OGV/PNG; the screenshot backend offers PNG/JPG).
static func all_formats() -> Array:
	return [Format.AVI, Format.OGV, Format.PNG, Format.JPG]


## Whether this format has known size limits that warrant a warning.
static func needs_size_warning(format: Format) -> bool:
	return format == Format.AVI


## User-facing warning for a format, or empty string when none needed.
static func warning_text(format: Format) -> String:
	if format == Format.AVI:
		return "AVI is capped at 4 GB — long or high-res recordings may hit the cap."
	if format == Format.OGV:
		return "OGV uses Theora+Vorbis and is only available in editor binaries."
	return ""
