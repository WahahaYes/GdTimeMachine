@tool
extends Node
class_name RecorderTranscoder

## Abstract base class for post-record transcoders (ffmpeg today, HandBrake
## or avconv tomorrow).
##
## A transcoder declares capability edges — (input artifact → output formats)
## it can transform — separately from availability (is the tool installed).
## Backends produce a native artifact; the TranscoderRegistry matches it to a
## transcoder; RecorderBackend.request_transcode() adapts the signals once,
## so per-backend adapter trios stay deleted.
##
## Input Dictionary shapes (see TranscoderRegistry / request_transcode):
##   file:   {"kind": "file", "path": String, "format": GdTMOutputFormat.Format}
##   frames: {"kind": "frames", "dir": String, "frame_ext": String,
##            "measured_fps": float}
## Options Dictionary keys: "target" (Format), "label" (String, for notices),
## "fps" (int, file converts), "clean" (bool, delete source on success).


## Transcoder name for registry order, doctor lines, and logs ("ffmpeg").
func get_transcoder_name() -> String:
	return ""


## Whether the tool is installed and usable right now. UI disables
## transcoded formats when no available transcoder covers them.
func is_available() -> bool:
	return false


## Human reason shown when transcoded items are disabled ("" when available).
func get_unavailable_reason() -> String:
	if is_available():
		return ""
	var n := get_transcoder_name()
	if n.is_empty():
		return "No transcoder available."
	return "Requires %s." % n


## Self-check entry for `gdtime doctor`. Returns {"ok": bool,
## "lines": Array[String]} with fully formatted lines the doctor prints
## verbatim (each transcoder owns its wording so output stays stable).
func doctor_check() -> Dictionary:
	return {"ok": true, "lines": []}


## Whether this transcoder can transform the given input into the target.
## Pure capability (ignores availability): builders and edges must agree, so
## offered formats can never drift from implementable ones.
func can_convert(input: Dictionary, target: GdTMOutputFormat.Format) -> bool:
	return false


## Starts an async conversion. Implementations must emit exactly one terminal
## signal: conversion_succeeded, conversion_failed, or transcoder_not_found.
func convert_async(_input: Dictionary, _output_path: String, _options: Dictionary) -> void:
	push_warning("RecorderTranscoder.convert_async() not implemented")


## Blocks until any in-flight conversion finishes. Called before free.
func wait_for_completion() -> void:
	pass


## Emitted with the converted clip path on success.
signal conversion_succeeded(output_path: String)

## Emitted with a message + detail tail when the tool runs but fails.
signal conversion_failed(error_message: String, detail: String)

## Emitted when the tool is not installed; inputs are kept. Generic name so a
## second transcoder needs no new signal shape.
signal transcoder_not_found(message: String)
