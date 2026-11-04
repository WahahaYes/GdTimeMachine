extends Node

## Manual smoke scene for GdTimeMachine's Movie Maker backend.
##
## Visually verifies a recording: the background cycles through hues and the
## label shows a running clock, so a recorded .avi is obviously "live" when
## played back. Run it from the GdTimeMachine dock, then check the output
## directory for the .avi. It also prints its user args and one line per
## second, so the game log beside the recording has something to stamp.

var _elapsed := 0.0
var _last_second := -1

@onready var _color_rect: ColorRect = $ColorRect
@onready var _label: Label = $Label


func _ready() -> void:
	print("smoke: user args %s" % [OS.get_cmdline_user_args()])


func _process(delta: float) -> void:
	if int(_elapsed) != _last_second:
		_last_second = int(_elapsed)
		print("smoke: second %d" % _last_second)
	_elapsed += delta
	_color_rect.color = Color.from_hsv(fmod(_elapsed * 0.2, 1.0), 0.6, 0.9)
	_label.text = "GdTimeMachine smoke — %06.2f s" % _elapsed
