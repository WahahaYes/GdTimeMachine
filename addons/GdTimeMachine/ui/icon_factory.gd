@tool
class_name GdTMIconFactory
extends RefCounted

## Loads an icon texture and resizes it to a target height (pixels),
## preserving the source aspect ratio.
##
## The GdTimeMachine glyphs are authored as large, non-square SVGs (a record
## glyph ~1.8:1, the logo ~1.54:1). Buttons draw Button.icon at the texture's
## native size, so a 1760px-tall comp would blow the button up; TextureRects
## need the art to fit a fixed box. This factory returns a compact texture
## sized to the desired button/box height so every surface shows the glyph at
## a sane scale without hand-authoring square variants.
##
## Returns null when the path can't be loaded or the image can't be decoded
## (e.g. during the editor's first import scan when the SVG import is not yet
## present — mirroring the lazy-loading comment in time_machine_dock.gd).

## Target button-icon height for record/stop glyphs (px). Kept comfortably
## above the editor's ~16px baseline so the (large-source) glyphs stay legible
## after the downscale.
const BUTTON_HEIGHT := 24

## Target icon height for the dock's prominent Record/Stop button (px).
## The dock action button is larger and icon-led, so its glyph is bigger too.
const DOCKS_BUTTON_HEIGHT := 36


## Creates a texture from `path` resized so its height equals `target_height`.
## If `target_height <= 0` the source texture is returned unchanged.
static func scaled_texture(path: String, target_height: int) -> Texture2D:
	if target_height <= 0:
		return load(path) as Texture2D
	var source := load(path) as Texture2D
	if source == null:
		return null
	var image := source.get_image()
	if image == null:
		return null
	var h := image.get_height()
	if h <= 0:
		return null
	var w := image.get_width()
	var new_w := maxi(1, roundi(float(w) * float(target_height) / float(h)))
	# LANCZOS produces noticeably crisper edges than bilinear when shrinking a
	# large art source (the SVG glyphs are ~1000-1800px) down to button height.
	image.resize(new_w, target_height, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(image)
