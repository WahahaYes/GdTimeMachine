extends Node

## Manual smoke scene for GdTimeMachine's Movie Maker backend.
##
## Visually verifies a recording: the background cycles through hues and the
## label shows a running clock, so a recorded .avi is obviously "live" when
## played back. Run it from the GdTimeMachine dock, then check the output
## directory for the .avi.

var _elapsed := 0.0

@onready var _color_rect: ColorRect = $ColorRect
@onready var _label: Label = $Label


func _process(delta: float) -> void:
	_elapsed += delta
	_color_rect.color = Color.from_hsv(fmod(_elapsed * 0.2, 1.0), 0.6, 0.9)
	_label.text = "GdTimeMachine smoke — %06.2f s" % _elapsed
