@tool
extends EditorPlugin

## GdTimeMachine EditorPlugin lifecycle.
##
## On enter: registers the debugger plugin, the graceful-stop autoload
## singleton, builds the RecorderController with its Movie Maker, Screenshot
## and OBS Studio backends, adds the dock as a bottom panel, and (best-effort)
## inserts record buttons into the editor run bar and game view toolbar via UI
## traversal. Every traversal failure degrades to "no button" without affecting
## recording — the bottom-panel tab is the supported surface. On exit the
## same pieces are torn down in reverse order.

## Icon shown on the record buttons while idle.
const ICON_RECORD_PATH := "res://addons/GdTimeMachine/ui/icons/icon_record.svg"

## Icon shown on the record buttons while recording.
const ICON_STOP_PATH := "res://addons/GdTimeMachine/ui/icons/icon_stop.svg"

## Default tooltip for the record buttons.
const TOOLTIP_DEFAULT := "GdTimeMachine — Start/stop recording (uses the dock settings)"

## Tooltip for the game-view record button when the active backend
## restarts the scene on Record (which would destroy the running game).
const TOOLTIP_RESTART_DISABLED := "This backend restarts the scene to record. Use the dock or run bar, or switch to an in-place backend."

## Autoload singleton through which the running game receives the editor's
## graceful-stop message and quits cleanly, so Movie Maker finalizes the
## AVI instead of the process being killed. Registered alongside the
## debugger plugin and removed on exit.
const AUTOLOAD_NAME := "GdTimeMachineGracefulStop"

## Script backing the graceful-stop autoload singleton.
const AUTOLOAD_PATH := "res://addons/GdTimeMachine/autoload/graceful_stop.gd"

## EditorSettings path under which the editor-wide record/stop shortcut is
## registered (user-rebindable via Project > Editor Settings > Shortcuts).
const SHORTCUT_SETTINGS_PATH := "gd_time_machine/toggle_recording"

## Default keycode for the record/stop shortcut.
const SHORTCUT_KEYCODE := KEY_R

## Command-palette action name for the record/stop toggle.
const COMMAND_PALETTE_ACTION := "GdTimeMachine: Toggle Recording"

## Command-palette key name for the record/stop toggle.
const COMMAND_PALETTE_KEY := "gd_time_machine_toggle_recording"

## Owns backends and exposes the recording API used by the dock and buttons.
var _recorder_controller: RecorderController

## Movie Maker backend registered with the controller.
var _movie_maker_backend: BackendMovieMaker

## Screenshot (in-place) backend registered with the controller.
var _screenshot_backend: BackendScreenshotCapture

## OBS Studio backend registered with the controller.
var _obs_backend: BackendOBS

## True once the command-palette action has been added, so _exit_tree only
## removes what was actually registered (the palette singleton can be null
## during early editor init while removal must stay error-free regardless).
var _command_palette_registered := false

## Registered debugger plugin; injected into the backend for graceful stop.
var _debugger_plugin: EditorDebuggerPlugin = null

## Bottom-panel dock instance (plain Control UI hosted inside _editor_dock).
var _dock: TimeMachineDock

## EditorDock wrapper hosting _dock in the bottom panel (4.6+ add_dock API).
var _editor_dock: EditorDock

## Config store for default and per-scene profiles.
var _config_store: ConfigStore

## Record button inserted into the editor run bar.
var _run_bar_button: Button

## Record button inserted into the game view toolbar.
var _game_view_button: Button

## Container holding the game view button and its separator.
var _game_view_section: HBoxContainer


## Registers the debugger plugin, autoload, config store, controller and
## backend, adds the dock to the bottom panel, and schedules run-bar /
## game-view button setup for the first process frame (those UI bars are
## constructed after plugin _enter_tree).
func _enter_tree() -> void:
	_debugger_plugin = preload("res://addons/GdTimeMachine/editor/debugger_plugin.gd").new()
	add_debugger_plugin(_debugger_plugin)
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_ensure_editor_settings_defaults()
	_register_recording_shortcut()
	_config_store = CompositeConfigStore.new()
	_recorder_controller = RecorderController.new()
	_recorder_controller._debugger_plugin = _debugger_plugin
	add_child(_recorder_controller)
	_movie_maker_backend = BackendMovieMaker.new()
	_movie_maker_backend._debugger_plugin = _debugger_plugin
	_recorder_controller.register_backend(_movie_maker_backend)
	# Registered after Movie Maker so Movie Maker stays the default backend
	# (AVI remains the default format; no behavior change for existing users).
	_screenshot_backend = BackendScreenshotCapture.new()
	_screenshot_backend._debugger_plugin = _debugger_plugin
	_recorder_controller.register_backend(_screenshot_backend)
	# OBS Studio is registered after Movie Maker and Screenshot so the existing
	# defaults are unchanged (Movie Maker stays the default backend; OBS is a
	# per-project opt-in via the backend dropdown / saved profile).
	_obs_backend = BackendOBS.new()
	_recorder_controller.register_backend(_obs_backend)
	_connect_controller_feedback()
	_dock = preload("res://addons/GdTimeMachine/ui/time_machine_dock.tscn").instantiate()
	_dock.setup(_recorder_controller, _config_store)
	# Bottom-panel placement via the EditorDock API (4.6+). The legacy
	# add_control_to_bottom_panel() is deprecated; an EditorDock owns the tab
	# title/slot, and the dock content is added as its child.
	_editor_dock = EditorDock.new()
	_editor_dock.name = "GdTimeMachineDock"
	_editor_dock.title = "GdTimeMachine"
	_editor_dock.default_slot = EditorDock.DOCK_SLOT_BOTTOM
	_editor_dock.available_layouts = EditorDock.DOCK_LAYOUT_ALL
	_editor_dock.add_child(_dock)
	add_dock(_editor_dock)
	# Follow the edited scene: the engine emits scene_changed on this plugin
	# whenever the active scene tab changes, with the new scene root as arg.
	scene_changed.connect(_on_scene_changed)
	# Flush the current scene's profile when its tab is closed — the one path
	# (e.g. closing the last scene) where no scene_changed fires.
	scene_closed.connect(_on_scene_closed)
	# The run bar and game view are constructed during editor init, after
	# plugin _enter_tree (and after end-of-frame deferred calls). Wait for the
	# first process frame so the traversals reliably find them.
	get_tree().process_frame.connect(_setup_run_bar_button, CONNECT_ONE_SHOT)
	get_tree().process_frame.connect(_setup_game_view_button, CONNECT_ONE_SHOT)


## Stops any active recording and tears down everything _enter_tree set up:
## debugger plugin, autoload singleton, run-bar/game-view buttons, dock,
## and controller.
func _exit_tree() -> void:
	if _recorder_controller:
		_disconnect_controller_feedback()
		_recorder_controller.stop_recording_if_active()
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if scene_closed.is_connected(_on_scene_closed):
		scene_closed.disconnect(_on_scene_closed)
	# Drop the backend's reference to the debugger plugin before removal so
	# teardown is clean; EditorDebuggerPlugin is RefCounted, so
	# remove_debugger_plugin() is enough — no queue_free() needed.
	if _debugger_plugin:
		if _movie_maker_backend:
			_movie_maker_backend._debugger_plugin = null
		if _screenshot_backend:
			_screenshot_backend._debugger_plugin = null
		if _recorder_controller:
			_recorder_controller._debugger_plugin = null
		remove_debugger_plugin(_debugger_plugin)
		_debugger_plugin = null
	remove_autoload_singleton(AUTOLOAD_NAME)
	_unregister_recording_shortcut()
	if _run_bar_button:
		if _run_bar_button.is_inside_tree():
			_run_bar_button.get_parent().remove_child(_run_bar_button)
		_run_bar_button.queue_free()
		_run_bar_button = null
	if _game_view_section:
		if _game_view_section.is_inside_tree():
			_game_view_section.get_parent().remove_child(_game_view_section)
		_game_view_section.queue_free()
		_game_view_section = null
		_game_view_button = null
	if _editor_dock:
		remove_dock(_editor_dock)
		_editor_dock.queue_free()
		_editor_dock = null
		_dock = null
	if _recorder_controller:
		remove_child(_recorder_controller)
		_recorder_controller.queue_free()
		_recorder_controller = null


# --- Record buttons (run bar + game view toolbar) --------------------------
#
# Both the editor's run bar and the embedded game view's toolbar (the
# "Input / 2D / 3D" bar shown while a scene plays) are internal C++ UI with
# no official plugin container, so the buttons are inserted by traversal.
# The game view toolbar is built once in the GameView constructor and never
# rebuilt, so the inserted button survives play/stop cycles. These are UI
# conveniences only — the bottom-panel tab remains the supported surface, and
# every failure path below degrades to "no button" without affecting recording.


## Finds the run bar row and inserts the record button into it. Warns and
## gives up (recording still works from the dock) if the row is not found.
func _setup_run_bar_button() -> void:
	var row := _find_run_bar_button_row()
	if row == null:
		push_warning(
			"GdTimeMachine: editor run bar not found; run-bar record button unavailable (bottom-panel tab still works)"
		)
		# The dock's permanent Record button is always in the tree, so it can
		# safely carry the editor-wide shortcut as the fallback surface.
		_attach_dock_shortcut_fallback()
		return
	_run_bar_button = _build_record_button()
	row.add_child(_run_bar_button)
	# The run-bar button lives in the editor tree permanently, so it is the
	# primary surface that carries the editor-wide record/stop shortcut. The
	# game-view button (shared factory) exists only while a scene plays —
	# attaching there would create a second, intermittently-active binding.
	_attach_shortcut_to_button(_run_bar_button)
	_apply_button_state(_run_bar_button, false)


## Attaches the editor-wide record/stop shortcut to a button and appends the
## combo to its tooltip for discoverability. No-op when the button or the
## shortcut is unavailable (e.g. headless).
func _attach_shortcut_to_button(button: Button) -> void:
	if button == null:
		return
	var shortcut := _get_recording_shortcut()
	if shortcut == null:
		return
	button.shortcut = shortcut
	var hint := shortcut.get_as_text()
	if not hint.is_empty() and not button.tooltip_text.contains(hint):
		button.tooltip_text = "%s (%s)" % [button.tooltip_text, hint]


## When the run bar can't be traversed, the dock's permanent Record button
## carries the editor-wide shortcut instead — the dock is always in the tree,
## so there is exactly one binding either way.
func _attach_dock_shortcut_fallback() -> void:
	if _dock == null:
		return
	_dock.set_record_shortcut(_get_recording_shortcut())


## Finds the game view toolbar row and inserts the record button. If the
## button survives from a previous plugin instance (GameView persists
## across re-enables), re-establishes its signals and state instead of
## inserting a duplicate.
func _setup_game_view_button() -> void:
	var row := _find_game_view_toolbar_row()
	if row == null:
		push_warning(
			"GdTimeMachine: game view toolbar not found; toolbar record button unavailable (bottom-panel tab still works)"
		)
		return
	# GameView persists across plugin re-enables; do not insert a duplicate.
	var existing := row.find_child("GdTimeMachineRecord", true, false)
	if existing is Button:
		_game_view_button = existing
		_game_view_section = _game_view_button.get_parent() as HBoxContainer
		# The previous plugin instance's signal connections died with it —
		# re-establish, then re-apply state.
		if not _game_view_button.pressed.is_connected(_on_record_button_pressed):
			_game_view_button.pressed.connect(_on_record_button_pressed)
		_connect_game_view_signals()
		_refresh_game_view_button()
		return
	var section := HBoxContainer.new()
	section.add_child(VSeparator.new())
	_game_view_button = _build_record_button()
	section.add_child(_game_view_button)
	row.add_child(section)
	# Place right after the Input/2D/3D button group (index 2) and before the
	# node-selection group, keeping the stretch/FPS label at the far right.
	if row.get_child_count() > 2:
		row.move_child(section, 2)
	_game_view_section = section
	_connect_game_view_signals()
	_refresh_game_view_button()


## Builds a flat toggle button wired to the controller's recording state
## (icon/text follow recording_started/stopped via _apply_button_state).
func _build_record_button() -> Button:
	var button := Button.new()
	button.name = "GdTimeMachineRecord"
	button.flat = true
	button.tooltip_text = TOOLTIP_DEFAULT
	button.pressed.connect(_on_record_button_pressed)
	_recorder_controller.recording_started.connect(func(_n, _p): _apply_button_state(button, true))
	_recorder_controller.recording_stopped.connect(func(_n, _p): _apply_button_state(button, false))
	return button


## Traverses the editor UI for the run bar's button row:
## EditorRunBar → PanelContainer → HBoxContainer. Returns null when absent.
func _find_run_bar_button_row() -> HBoxContainer:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var run_bar := _find_node_by_class(base, "EditorRunBar")
	if run_bar == null:
		return null
	# EditorRunBar → HBoxContainer → [Button, PanelContainer → HBoxContainer (button row)]
	var panel := _find_node_by_class(run_bar, "PanelContainer")
	if panel == null:
		return null
	for row in panel.get_children():
		if row is HBoxContainer:
			return row
	return null


## Traverses the editor UI for the game view's toolbar row:
## GameView → MarginContainer → HBoxContainer. Returns null when absent.
func _find_game_view_toolbar_row() -> HBoxContainer:
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var game_view := _find_node_by_class(base, "GameView")
	if game_view == null:
		return null
	# GameView → MarginContainer (toolbar margin) → HBoxContainer (toolbar row).
	for child in game_view.get_children():
		if child is MarginContainer:
			for row in child.get_children():
				if row is HBoxContainer:
					return row
	return null


## Depth-first search for a descendant with the given class name; returns
## the first match or null.
func _find_node_by_class(node: Node, target_class: String) -> Node:
	if node.get_class() == target_class:
		return node
	for child in node.get_children():
		var found := _find_node_by_class(child, target_class)
		if found:
			return found
	return null


## Pure toggle-decision rule, extracted as a static so GUT can exercise the
## full matrix without instantiating an EditorPlugin (virtual class — the
## editor instantiates it, tests cannot). Returns {"action": "stop"} when a
## recording is running, else {"action": "start", "config": Dictionary} — the
## dock's current config, or {} when the dock is unavailable (backends apply
## their defaults instead of the editor crashing).
static func compute_toggle_action(recording: bool, dock: TimeMachineDock) -> Dictionary:
	if recording:
		return {"action": "stop"}
	var config: Dictionary = dock.build_config() if dock != null else {}
	return {"action": "start", "config": config}


## Toggles recording via the controller; starts a recording using the
## dock's current config.
func _on_record_button_pressed() -> void:
	if _recorder_controller == null:
		return
	var action := compute_toggle_action(_recorder_controller.is_recording(), _dock)
	if action["action"] == "stop":
		_recorder_controller.stop_recording()
		return
	_recorder_controller.start_recording(action["config"])


## Syncs a record button's text and icon with the recording state.
func _apply_button_state(button: Button, recording: bool) -> void:
	if button == null:
		return
	if recording:
		button.text = "Stop"
		button.icon = GdTMIconFactory.scaled_texture(ICON_STOP_PATH, GdTMIconFactory.BUTTON_HEIGHT)
	else:
		button.text = "Record"
		button.icon = GdTMIconFactory.scaled_texture(
			ICON_RECORD_PATH, GdTMIconFactory.BUTTON_HEIGHT
		)


# --- Editor-wide record/stop shortcut ----------------------------------------
#
# A user-rebindable shortcut (EditorSettings.add_shortcut + BaseButton.shortcut,
# Godot 4.6+) lets the record/stop toggle fire from anywhere in the editor —
# no need to hit the tiny run-bar button. EditorSettings.add_shortcut never
# clobbers a user rebind (the engine keeps the user's events when the stored
# "original" meta differs), so calling it on every _enter_tree is safe and the
# binding survives plugin disable/re-enable. Ctrl+Alt+R is deliberately
# uncommon: unmodified letters collide with script-editor chords, and F5–F8
# are taken by the run bar.


## Returns true on macOS, where the record/stop shortcut uses Meta (Cmd)
## instead of Ctrl (Ctrl+Alt conflicts with common macOS chords). Static seam
## so GUT can pin the platform decision.
static func _should_use_meta() -> bool:
	return OS.get_name() == "macOS"


## Builds the record/stop Shortcut: exactly one InputEventKey, Ctrl+Alt+R on
## most platforms, Cmd+Alt+R on macOS. `use_meta` selects the platform
## modifier and is parameterized so tests can exercise both branches.
static func build_toggle_shortcut(use_meta: bool) -> Shortcut:
	var shortcut := Shortcut.new()
	var event := InputEventKey.new()
	event.keycode = SHORTCUT_KEYCODE
	event.alt_pressed = true
	if use_meta:
		event.meta_pressed = true
	else:
		event.ctrl_pressed = true
	shortcut.events = [event]
	return shortcut


## Registers the record/stop shortcut under EditorSettings (it shows up under
## Project > Editor Settings > Shortcuts, user-rebindable) and adds the
## command-palette action for discoverability (display-only shortcut text).
## Tracks _command_palette_registered so teardown removes only what was added —
## the palette singleton can be null during early editor init.
func _register_recording_shortcut() -> void:
	if not Engine.is_editor_hint():
		return
	var es: Object = EditorInterface.get_editor_settings()
	if es == null or not es.has_method("add_shortcut"):
		return
	var shortcut := build_toggle_shortcut(_should_use_meta())
	es.add_shortcut(SHORTCUT_SETTINGS_PATH, shortcut)
	var palette := EditorInterface.get_command_palette()
	if palette != null and palette.has_method("add_command"):
		(
			palette
			. add_command(
				COMMAND_PALETTE_ACTION,
				COMMAND_PALETTE_KEY,
				_on_record_button_pressed,
				shortcut.get_as_text(),
			)
		)
		_command_palette_registered = true


## Removes the command-palette action on _exit_tree so re-enables don't leave
## stale entries. Removes by the palette KEY (the same identifier add_command
## used — remove_command looks up by key name, not the display name). The
## EditorSettings shortcut itself is left in place — that's the point: user
## rebinds survive plugin disable/re-enable.
func _unregister_recording_shortcut() -> void:
	if not Engine.is_editor_hint():
		return
	if not _command_palette_registered:
		return
	var palette := EditorInterface.get_command_palette()
	if palette != null and palette.has_method("remove_command"):
		palette.remove_command(COMMAND_PALETTE_KEY)
	_command_palette_registered = false


## Returns the registered record/stop shortcut (the user's rebind if any), or
## null when EditorSettings is unavailable — the run-bar button then simply has
## no key binding (degradation: still clickable).
func _get_recording_shortcut() -> Shortcut:
	if not Engine.is_editor_hint():
		return null
	var es: Object = EditorInterface.get_editor_settings()
	if es == null or not es.has_method("get_shortcut"):
		return null
	return es.get_shortcut(SHORTCUT_SETTINGS_PATH) as Shortcut


# --- Game-view button grey-out ---------------------------------------------
#
# The game view shows the *running* scene; a RESTART_SCENE backend would
# destroy it on Record, so Record greys out with an explanatory tooltip.
# Stop is always allowed, and the run-bar/dock buttons are unaffected
# (restart is the expected price there). Re-applied on backend_changed and
# recording_* signals via _connect_game_view_signals().


## Pure button-state rule, extracted as a static so GUT can exercise the full
## matrix without standing up editor UI.
##
## State table:
##   recording=false, mode=RESTART_SCENE → disabled, TOOLTIP_RESTART_DISABLED
##   recording=true,  mode=any          → enabled,  TOOLTIP_DEFAULT
##   recording=false, mode=other        → enabled,  TOOLTIP_DEFAULT
static func compute_game_view_button_state(
	recording: bool, mode: RecorderBackend.CaptureMode
) -> Dictionary:
	if not recording and mode == RecorderBackend.CaptureMode.RESTART_SCENE:
		return {"disabled": true, "tooltip": TOOLTIP_RESTART_DISABLED}
	return {"disabled": false, "tooltip": TOOLTIP_DEFAULT}


## Re-applies icon/text, enabled state, and tooltip to the game view button
## based on the controller's current recording state and capture mode.
func _refresh_game_view_button() -> void:
	if _game_view_button == null or _recorder_controller == null:
		return
	var recording := _recorder_controller.is_recording()
	_apply_button_state(_game_view_button, recording)
	var state: Dictionary = compute_game_view_button_state(
		recording, _recorder_controller.get_capture_mode()
	)
	_game_view_button.disabled = state["disabled"]
	_game_view_button.tooltip_text = state["tooltip"]


## Signal adapter with default args so it can connect to backend_changed
## (1 arg) and recording_started/stopped (2 args) alike.
func _on_game_view_refresh_triggered(_arg1: Variant = null, _arg2: Variant = null) -> void:
	_refresh_game_view_button()


## Connects the controller signals (recording started/stopped, backend
## changed) that drive game-view button refresh; safe to call repeatedly.
func _connect_game_view_signals() -> void:
	if not _recorder_controller.recording_started.is_connected(_on_game_view_refresh_triggered):
		_recorder_controller.recording_started.connect(_on_game_view_refresh_triggered)
	if not _recorder_controller.recording_stopped.is_connected(_on_game_view_refresh_triggered):
		_recorder_controller.recording_stopped.connect(_on_game_view_refresh_triggered)
	if not _recorder_controller.backend_changed.is_connected(_on_game_view_refresh_triggered):
		_recorder_controller.backend_changed.connect(_on_game_view_refresh_triggered)


# --- Scene-change tracking ---------------------------------------------------
#
# The engine emits EditorPlugin.scene_changed(scene_root) on this plugin
# whenever the active scene tab changes (EditorData::notify_edited_scene_changed
# -> EditorPlugin::notify_scene_changed), and EditorPlugin.scene_closed(filepath)
# when a scene tab is closed. We forward both to the dock, which auto-saves the
# previous scene's profile (when per-scene mode is on) and auto-loads the new
# scene's profile.


## Wires unconditional console feedback for users not looking at the dock.
## The dock's status line is great, but the run-bar / game-view record
## buttons have no status label. Printing to Output alongside icons gives
## those users a signal without touching the button plumbing.
func _connect_controller_feedback() -> void:
	if _recorder_controller == null:
		return
	if not _recorder_controller.recording_started.is_connected(_on_feedback_started):
		_recorder_controller.recording_started.connect(_on_feedback_started)
	if not _recorder_controller.recording_stopped.is_connected(_on_feedback_stopped):
		_recorder_controller.recording_stopped.connect(_on_feedback_stopped)
	if not _recorder_controller.recording_error.is_connected(_on_feedback_error):
		_recorder_controller.recording_error.connect(_on_feedback_error)
	if not _recorder_controller.recording_notice.is_connected(_on_feedback_notice):
		_recorder_controller.recording_notice.connect(_on_feedback_notice)
	if _recorder_controller.has_signal("recording_converted"):
		if not _recorder_controller.recording_converted.is_connected(_on_feedback_converted):
			_recorder_controller.recording_converted.connect(_on_feedback_converted)


func _disconnect_controller_feedback() -> void:
	if _recorder_controller == null:
		return
	if _recorder_controller.recording_started.is_connected(_on_feedback_started):
		_recorder_controller.recording_started.disconnect(_on_feedback_started)
	if _recorder_controller.recording_stopped.is_connected(_on_feedback_stopped):
		_recorder_controller.recording_stopped.disconnect(_on_feedback_stopped)
	if _recorder_controller.recording_error.is_connected(_on_feedback_error):
		_recorder_controller.recording_error.disconnect(_on_feedback_error)
	if _recorder_controller.recording_notice.is_connected(_on_feedback_notice):
		_recorder_controller.recording_notice.disconnect(_on_feedback_notice)
	if _recorder_controller.has_signal("recording_converted"):
		if _recorder_controller.recording_converted.is_connected(_on_feedback_converted):
			_recorder_controller.recording_converted.disconnect(_on_feedback_converted)


## Registers EditorSettings defaults for ffmpeg (path, auto_convert, clean_frames)
## so the settings appear in Project > Editor Settings. Safe to call repeatedly.
func _ensure_editor_settings_defaults() -> void:
	if not Engine.is_editor_hint():
		return
	var es: Object = EditorInterface.get_editor_settings()
	if es == null:
		return
	if es.has_method("has_setting") and es.has_method("set_setting"):
		# Only set when absent — don't overwrite user's existing preference.
		if not es.has_setting("gd_time_machine/ffmpeg/path"):
			es.set_setting("gd_time_machine/ffmpeg/path", "")
			# Add property info so it shows up with hint in EditorSettings UI.
			if es.has_method("add_property_info"):
				(
					es
					. add_property_info(
						{
							"name": "gd_time_machine/ffmpeg/path",
							"type": TYPE_STRING,
							"hint": PROPERTY_HINT_GLOBAL_FILE,
						}
					)
				)
		if not es.has_setting("gd_time_machine/ffmpeg/auto_convert"):
			es.set_setting("gd_time_machine/ffmpeg/auto_convert", true)
			if es.has_method("add_property_info"):
				(
					es
					. add_property_info(
						{
							"name": "gd_time_machine/ffmpeg/auto_convert",
							"type": TYPE_BOOL,
						}
					)
				)
		if not es.has_setting("gd_time_machine/ffmpeg/clean_frames"):
			es.set_setting("gd_time_machine/ffmpeg/clean_frames", true)
			if es.has_method("add_property_info"):
				(
					es
					. add_property_info(
						{
							"name": "gd_time_machine/ffmpeg/clean_frames",
							"type": TYPE_BOOL,
						}
					)
				)
		# OBS backend settings (PLAN_obs_backend_v2.md §6) — the only source
		# BackendOBS._get_obs_settings() reads. Only set when absent so user
		# preferences (host/port/password) survive plugin re-enables.
		var obs_defaults: Array = [
			[
				"gd_time_machine/obs/host",
				"127.0.0.1",
				{"type": TYPE_STRING},
			],
			[
				"gd_time_machine/obs/port",
				4455,
				{
					"type": TYPE_INT,
					"hint": PROPERTY_HINT_RANGE,
					"hint_string": "1,65535",
				},
			],
			[
				"gd_time_machine/obs/password",
				"",
				{"type": TYPE_STRING, "hint": PROPERTY_HINT_PASSWORD},
			],
			["gd_time_machine/obs/scene", "", {"type": TYPE_STRING}],
			["gd_time_machine/obs/auto_launch", true, {"type": TYPE_BOOL}],
			["gd_time_machine/obs/auto_close", true, {"type": TYPE_BOOL}],
			[
				"gd_time_machine/obs/binary_path",
				"",
				{"type": TYPE_STRING, "hint": PROPERTY_HINT_GLOBAL_FILE},
			],
		]
		for entry in obs_defaults:
			var key: String = entry[0]
			if not es.has_setting(key):
				es.set_setting(key, entry[1])
				if es.has_method("add_property_info"):
					var info: Dictionary = entry[2].duplicate()
					info["name"] = key
					es.add_property_info(info)


func _on_feedback_started(backend_name: String, output_path: String) -> void:
	print("[GdTM] %s recording → %s" % [backend_name, output_path])


func _on_feedback_stopped(backend_name: String, output_path: String) -> void:
	print("[GdTM] %s stopped: %s" % [backend_name, output_path])


func _on_feedback_error(backend_name: String, message: String) -> void:
	var label := backend_name if not backend_name.is_empty() else "GdTimeMachine"
	push_warning("[GdTM] %s error: %s" % [label, message])


func _on_feedback_notice(backend_name: String, message: String) -> void:
	# Notice is info-level (stats / hints) — print, not warning, so it
	# doesn't spam the Errors panel. Mirrors the dock status line.
	print("[GdTM] %s: %s" % [backend_name, message])


func _on_feedback_converted(backend_name: String, clip_path: String) -> void:
	print("[GdTM] %s converted → %s" % [backend_name, clip_path])


## EditorPlugin.scene_changed handler: forwards the newly active scene root's
## path to the dock. The argument is null for a new/untitled scene.
func _on_scene_changed(scene_root: Node) -> void:
	if _dock == null:
		return
	var path := scene_root.scene_file_path if scene_root != null else ""
	_dock.on_editor_scene_changed(path)


## EditorPlugin.scene_closed handler: forwards the closed scene's path to the
## dock so it can flush that scene's per-scene profile (covers closing the
## last/active tab, where no scene_changed follows).
func _on_scene_closed(filepath: String) -> void:
	if _dock == null:
		return
	_dock.on_editor_scene_closed(filepath)
