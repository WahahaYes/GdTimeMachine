@tool
extends GutTest

## TranscoderRegistry tests: capability matching, preference order,
## reachability vs availability, and availability events. No engine
## singletons, no real probes — scripted stub transcoders only.


class StubTranscoder:
	extends RecorderTranscoder
	var tool_name := "stub"
	var available := true
	var file_targets: Array = []
	var frames_targets: Array = []

	func get_transcoder_name() -> String:
		return tool_name

	func is_available() -> bool:
		return available

	func can_convert(input: Dictionary, target: GdTMOutputFormat.Format) -> bool:
		if str(input.get("kind", "file")) == "frames":
			return target in frames_targets
		return target in file_targets


func _file_input() -> Dictionary:
	return {"kind": "file", "path": "res://clip.mp4", "format": GdTMOutputFormat.Format.MP4}


func _make_registry() -> TranscoderRegistry:
	return TranscoderRegistry.new()


func test_find_prefers_first_available_covering_transcoder() -> void:
	var registry := _make_registry()
	var first := StubTranscoder.new()
	first.tool_name = "first"
	first.file_targets = [GdTMOutputFormat.Format.WEBM]
	var second := StubTranscoder.new()
	second.tool_name = "second"
	second.file_targets = [GdTMOutputFormat.Format.WEBM]
	add_child_autofree(first)
	add_child_autofree(second)
	registry.register_transcoder(first)
	registry.register_transcoder(second)
	assert_eq(registry.find_transcoder(_file_input(), GdTMOutputFormat.Format.WEBM), first)


func test_find_skips_unavailable_transcoder() -> void:
	var registry := _make_registry()
	var down := StubTranscoder.new()
	down.tool_name = "down"
	down.available = false
	down.file_targets = [GdTMOutputFormat.Format.WEBM]
	var up := StubTranscoder.new()
	up.tool_name = "up"
	up.file_targets = [GdTMOutputFormat.Format.WEBM]
	add_child_autofree(down)
	add_child_autofree(up)
	registry.register_transcoder(down)
	registry.register_transcoder(up)
	assert_eq(registry.find_transcoder(_file_input(), GdTMOutputFormat.Format.WEBM), up)


func test_find_returns_null_when_nothing_available() -> void:
	var registry := _make_registry()
	var down := StubTranscoder.new()
	down.available = false
	down.file_targets = [GdTMOutputFormat.Format.WEBM]
	add_child_autofree(down)
	registry.register_transcoder(down)
	assert_null(registry.find_transcoder(_file_input(), GdTMOutputFormat.Format.WEBM))


func test_reachable_ignores_availability() -> void:
	# Reachability (any edge) feeds the deliverable list + "disabled with
	# reason"; availability feeds only the disabled gate.
	var registry := _make_registry()
	var down := StubTranscoder.new()
	down.available = false
	down.file_targets = [GdTMOutputFormat.Format.WEBM]
	add_child_autofree(down)
	registry.register_transcoder(down)
	assert_true(registry.is_target_reachable(_file_input(), GdTMOutputFormat.Format.WEBM))
	assert_false(
		registry.is_target_reachable(_file_input(), GdTMOutputFormat.Format.AVI),
		"no edge at all means unsupported, not disabled"
	)


func test_refresh_emits_only_on_flip() -> void:
	var registry := _make_registry()
	var stub := StubTranscoder.new()
	stub.file_targets = [GdTMOutputFormat.Format.WEBM]
	add_child_autofree(stub)
	registry.register_transcoder(stub)
	var events: Array = []
	registry.transcoder_availability_changed.connect(
		func(n: String, a: bool) -> void: events.append([n, a])
	)
	assert_false(registry.refresh_availability(), "baseline already snapshotted at register")
	stub.available = false
	assert_true(registry.refresh_availability())
	assert_eq(events, [["stub", false]])
	assert_false(registry.refresh_availability(), "steady state emits nothing")


func test_unregister_stops_matching() -> void:
	var registry := _make_registry()
	var stub := StubTranscoder.new()
	stub.tool_name = "gone"
	stub.file_targets = [GdTMOutputFormat.Format.WEBM]
	add_child_autofree(stub)
	registry.register_transcoder(stub)
	assert_eq(registry.transcoder_count(), 1)
	registry.unregister_transcoder("gone")
	assert_eq(registry.transcoder_count(), 0)
	assert_false(registry.is_target_reachable(_file_input(), GdTMOutputFormat.Format.WEBM))


func test_spawn_preferred_instantiates_first_registered_type() -> void:
	var registry := _make_registry()
	assert_null(registry.spawn_preferred(), "empty registry spawns nothing")
	var stub := StubTranscoder.new()
	stub.tool_name = "proto"
	add_child_autofree(stub)
	registry.register_transcoder(stub)
	var fresh := registry.spawn_preferred()
	assert_not_null(fresh)
	assert_true(fresh is StubTranscoder)
	assert_ne(fresh, stub, "spawn returns a fresh instance, never the registered one")
	fresh.free()
