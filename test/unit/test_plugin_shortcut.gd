extends GutTest

# Editor-wide record/stop shortcut (Op 7 of notes/SESSION_PLAN_engine_native_recording.md).
# The shortcut construction lives in a static pure helper on plugin.gd
# (build_toggle_shortcut) so both platform branches run headlessly — no
# EditorSettings, no editor UI. The registration/attach wiring (add_shortcut,
# BaseButton.shortcut) is editor-side and covered by the manual playbook.

const PluginScript := preload("res://addons/GdTimeMachine/plugin.gd")


func _event_of(shortcut: Shortcut) -> InputEventKey:
	assert_eq(shortcut.events.size(), 1, "shortcut must hold exactly one event")
	return shortcut.events[0] as InputEventKey


func test_default_branch_uses_ctrl_alt_r() -> void:
	var shortcut := PluginScript.build_toggle_shortcut(false)
	var event := _event_of(shortcut)
	assert_true(event is InputEventKey)
	assert_eq(event.keycode, PluginScript.SHORTCUT_KEYCODE)
	assert_eq(event.keycode, KEY_R)
	assert_true(event.ctrl_pressed)
	assert_false(event.meta_pressed)
	assert_true(event.alt_pressed)
	assert_false(event.shift_pressed)


func test_meta_branch_uses_meta_alt_r_without_ctrl() -> void:
	# macOS prefers Cmd (Meta) over Ctrl — Meta replaces Ctrl, Alt stays.
	var shortcut := PluginScript.build_toggle_shortcut(true)
	var event := _event_of(shortcut)
	assert_true(event.meta_pressed)
	assert_false(event.ctrl_pressed)
	assert_true(event.alt_pressed)
	assert_eq(event.keycode, KEY_R)


func test_default_branch_get_as_text_contains_combo() -> void:
	var shortcut := PluginScript.build_toggle_shortcut(false)
	var text := shortcut.get_as_text()
	assert_string_contains(text, "Ctrl")
	assert_string_contains(text, "Alt")
	assert_string_contains(text, "R")


func test_meta_branch_get_as_text_contains_combo() -> void:
	var shortcut := PluginScript.build_toggle_shortcut(true)
	var text := shortcut.get_as_text()
	assert_string_contains(text, "Meta")
	assert_string_contains(text, "Alt")
	assert_string_contains(text, "R")


func test_should_use_meta_returns_bool() -> void:
	# Platform seam: deterministic per-OS; smoke-check it returns a bool so
	# _register_recording_shortcut's branch selection is exercised headlessly.
	assert_true(PluginScript._should_use_meta() is bool)
