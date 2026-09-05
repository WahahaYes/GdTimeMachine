@tool
extends RefCounted
class_name TranscoderRegistry

## Ordered set of transcoders plus capability matching. Owned by
## RecorderController (which fans availability out as its own signal); holds
## weak references so test doubles freed by GUT never dangle. Transcoder
## lifetime stays with whoever add_child'd them (controller in production).

## Emitted when a registered transcoder's availability flips. The controller
## forwards it; the dock re-derives disabled format items live.
signal transcoder_availability_changed(transcoder_name: String, available: bool)

## Weak references (weakref()) to registered RecorderTranscoder nodes.
var _entries: Array = []

## Last known availability per transcoder name.
var _last_known: Dictionary = {}


## Tracks a transcoder (no ownership transfer) and snapshots availability
## without emitting — the first refresh_availability() reports the baseline.
func register_transcoder(transcoder: RecorderTranscoder) -> void:
	if transcoder == null:
		push_warning("Cannot register a null transcoder")
		return
	_prune_dead()
	for wr in _entries:
		if wr.get_ref() == transcoder:
			return
	_entries.append(weakref(transcoder))
	_last_known[transcoder.get_transcoder_name()] = transcoder.is_available()


## Stops tracking a transcoder by name.
func unregister_transcoder(transcoder_name: String) -> void:
	_prune_dead()
	_entries = _entries.filter(
		func(wr: WeakRef) -> bool: return str(wr.get_ref().get_transcoder_name()) != transcoder_name
	)
	_last_known.erase(transcoder_name)


## Live transcoder nodes in registration order.
func list_transcoders() -> Array:
	_prune_dead()
	var out: Array = []
	for wr in _entries:
		out.append(wr.get_ref())
	return out


## Number of tracked transcoders (live). Lets callers distinguish "no
## coverage" from "coverage, none available".
func transcoder_count() -> int:
	_prune_dead()
	return _entries.size()


## First AVAILABLE transcoder covering input → target, or null. Registry
## order is preference order. Query-only: the returned instance stays
## registry-owned — never free it, never run jobs on it (capability and
## availability checks only; jobs run on backend-owned instances).
func find_transcoder(input: Dictionary, target: GdTMOutputFormat.Format) -> RecorderTranscoder:
	for t in list_transcoders():
		var transcoder := t as RecorderTranscoder
		if (
			transcoder != null
			and transcoder.is_available()
			and transcoder.can_convert(input, target)
		):
			return transcoder
	return null


## Whether ANY tracked transcoder covers input → target, regardless of
## availability. Drives "disabled with reason" (reachable but missing) vs
## "unsupported" (no edge at all).
func is_target_reachable(input: Dictionary, target: GdTMOutputFormat.Format) -> bool:
	for t in list_transcoders():
		var transcoder := t as RecorderTranscoder
		if transcoder != null and transcoder.can_convert(input, target):
			return true
	return false


## Fresh instance of the first registered transcoder type, or null when
## empty. Backends own the spawned instance (same one-per-backend lifetime
## as before). Registration order is the future transcoders/active
## preference point: a second transcoder plugs in here without touching
## backends.
func spawn_preferred() -> RecorderTranscoder:
	for t in list_transcoders():
		var transcoder := t as RecorderTranscoder
		if transcoder == null:
			continue
		var script: Script = transcoder.get_script() as Script
		if script == null or not script.can_instantiate():
			continue
		var fresh := script.new() as RecorderTranscoder
		if fresh != null:
			return fresh
	return null


## Re-probes every transcoder; emits transcoder_availability_changed for each
## flip. Returns true when anything changed. Called before format dropdown
## populates (same cost as the old single ffmpeg probe).
func refresh_availability() -> bool:
	var changed := false
	for t in list_transcoders():
		var transcoder := t as RecorderTranscoder
		if transcoder == null:
			continue
		var now_available := transcoder.is_available()
		var key := transcoder.get_transcoder_name()
		if _last_known.get(key, null) != now_available:
			_last_known[key] = now_available
			changed = true
			transcoder_availability_changed.emit(key, now_available)
	return changed


## Drops collected weak references.
func _prune_dead() -> void:
	_entries = _entries.filter(func(wr: WeakRef) -> bool: return wr.get_ref() != null)
