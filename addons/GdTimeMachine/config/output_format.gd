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
	MP4,  ## .mp4 — H.264 via ffmpeg tier-2. No native engine writer.
	WEBM,  ## .webm — VP9 via ffmpeg tier-2.
}

## Default format: AVI (.avi MJPEG, 4 GB cap).
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
		Format.MP4:
			return "mp4"
		Format.WEBM:
			return "webm"
	return "avi"


## Plain base label with no dependency suffix (the " - ffmpeg" marker is
## applied per-backend by display_name_for_backend()).
static func base_display_name(format: Format) -> String:
	match format:
		Format.AVI:
			return "AVI (.avi)"
		Format.OGV:
			return "OGV (.ogv)"
		Format.PNG:
			return "PNG sequence (.png)"
		Format.JPG:
			return "JPG sequence (.jpg)"
		Format.MP4:
			return "MP4 (.mp4)"
		Format.WEBM:
			return "WebM (.webm)"
	return "AVI (.avi)"


## Human-readable label for the dock dropdown.
## NOTE: the " - ffmpeg" suffix describes the Movie Maker / Screenshot path
## (MP4/WebM via ffmpeg tier-2). Backends that record a format natively
## (OBS → MP4) must use display_name_for_backend() so the suffix is dropped.
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
		Format.MP4:
			return "MP4 (.mp4) - ffmpeg"
		Format.WEBM:
			return "WebM (.webm) - ffmpeg"
	return "AVI (.avi)"


## Backend-aware label: plain base name when the active backend records the
## format natively, base + " - ffmpeg" otherwise — driven by need, not by
## format identity, so transcoded AVI/OGV (Screenshot, OBS) label honestly.
static func display_name_for_backend(format: Format, is_native: bool) -> String:
	var base := base_display_name(format)
	if is_native:
		return base
	return "%s - ffmpeg" % base


## Parses a stored string ("avi", "ogv", "png", "jpg"/"jpeg", mp4, webm or full
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
	if t in ["mp4", "mp4 (.mp4)"] or t.begins_with("mp4"):
		return Format.MP4
	if t in ["webm", "webm (.webm)"] or t.begins_with("webm"):
		return Format.WEBM
	return DEFAULT


## All format values in dropdown order. The dock filters this per-backend
## (Movie Maker offers AVI/OGV/PNG; the screenshot backend offers PNG/JPG).
static func all_formats() -> Array:
	return [Format.AVI, Format.OGV, Format.PNG, Format.JPG, Format.MP4, Format.WEBM]


## Whether this format has known size limits that warrant a warning.
static func needs_size_warning(format: Format) -> bool:
	return format == Format.AVI


## User-facing warning for a format, or empty string when none needed.
static func warning_text(format: Format) -> String:
	if format == Format.AVI:
		return "AVI is capped at 4 GB — long or high-res recordings may hit the cap."
	if format == Format.OGV:
		return "OGV uses Theora+Vorbis and is only available in editor binaries."
	if format == Format.MP4 or format == Format.WEBM:
		return "Requires ffmpeg on PATH (or set transcoders/ffmpeg/path)."
	return ""


## Backend-aware warning: native warnings unchanged (MP4/WEBM natives need no
## ffmpeg note); transcoded formats always carry the ffmpeg requirement since
## the generic per-format text can't know the backend (e.g. AVI's 4 GB cap
## describes Godot's writer, not an ffmpeg transcode, and OGV's editor-binaries
## note describes engine output, not ffmpeg libtheora).
static func warning_text_for_backend(format: Format, is_native: bool) -> String:
	if is_native:
		if format == Format.MP4 or format == Format.WEBM:
			return ""
		return warning_text(format)
	return (
		"Requires ffmpeg on PATH (or set transcoders/ffmpeg/path). "
		+ "Transcoded from the native recording after Stop."
	)
