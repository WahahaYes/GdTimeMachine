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


## Whether a format requires ffmpeg conversion (tier-2).
static func is_tier2_format(format: Format) -> bool:
	return format == Format.MP4 or format == Format.WEBM


## Whether a format is a native screenshot frames source (PNG/JPG stored
## in .frames/). Encoding to tier-1 container targets (AVI/OGV) also requires
## ffmpeg when coming from screenshots.
static func is_frames_source_format(format: Format) -> bool:
	return format == Format.PNG or format == Format.JPG


## Whether capturing into the given format as final output needs ffmpeg when
## the backend's native artifact is a frames directory (screenshot backend).
## PNG/JPG are native frames (no-op), everything else requires ffmpeg.
static func frames_need_ffmpeg(format: Format) -> bool:
	return format != Format.PNG and format != Format.JPG


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
		Format.MP4:
			return "MP4 (.mp4) - ffmpeg"
		Format.WEBM:
			return "WebM (.webm) - ffmpeg"
	return "AVI (.avi)"


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
		return "Requires ffmpeg on PATH (or set gd_time_machine/ffmpeg/path)."
	return ""
