# Scene-Aware Profiles — auto load/save on scene switch — SHIPPED 2026-08-01

Status: Shipped. 98/98 GUT green (was 90; +8 new dock tests).

Removes the two clunky manual steps from the dock's per-scene workflow: the scene field now follows the open scene automatically, and per-scene settings save/load themselves on scene switch.

## Mechanism: `EditorPlugin.scene_changed(scene_root: Node)`

The engine emits this signal **on the plugin instance** whenever the active scene tab changes, with the newly active scene root as the argument. Official, documented, present since 4.0. Verified against 4.7 source:

- `EditorPlugin::_bind_methods()` — `ADD_SIGNAL("scene_changed", scene_root: Node)` — editor/plugins/editor_plugin.cpp#L717
- `EditorPlugin::notify_scene_changed(const Node *scn_root)` → `emit_signal("scene_changed", scn_root)` — editor_plugin.cpp#L268
- `EditorData::notify_edited_scene_changed()` loops all plugins — editor/editor_data.cpp#L366
- Fired on every switch in `EditorNode::_set_current_scene_nocheck()` — editor_node.cpp#L4730

Docs: *"Emitted when the scene is changed in the editor. The argument will return the root node of the scene that has just become active. If this scene is new and empty, the argument will be null."*

Path semantics: `scene_root.scene_file_path` is the `res://` path for saved scenes and `""` for untitled/new scenes (engine treats non-empty as "is an instance" — `Node::is_instance()`).

Rejected alternatives (all worse):

- Polling `EditorInterface.get_edited_scene_root()` in `_process()` — works but wasteful.
- `EditorInterface` signals — **none exist** (the class is signal-less in 4.0–4.7).
- `EditorSceneTabs` — internal/refactored since 4.5, not ClassDB-registered; only reachable by UI-tree walking.
- `SceneTree.scene_changed` — runtime-only (running game), not editor tab switching. Common trap.

## Behavior (user-confirmed design)

- **Always follow**: the scene field mirrors the open scene on every switch.
- **Gated auto-save**: when "Remember settings for this scene" is checked, leaving a scene saves the current UI as that scene's per-scene profile (`save_scene_profile`). Unchecked → nothing per-scene saved (default profile still tracks edits as before).
- **Auto-load**: entering a scene loads its resolved profile (scene override > default) and syncs the checkbox. Untitled scenes (empty path) → defaults, no save (no stable key).
- **Recording guard**: scene switches are ignored while recording — an active session is never disturbed.

The manual Save/Clear buttons remain as "save now without switching" conveniences; the "Current" button becomes a re-sync affordance. profiles.cfg format untouched. ~~(Superseded 2026-08-02: both buttons removed — the checkbox is now the single per-scene control, see Update below.)~~

## Changes

- `plugin.gd` — `scene_changed.connect(_on_scene_changed)` in `_enter_tree` (disconnect in `_exit_tree`), forwards `scene_root.scene_file_path` (or `""`) to the dock.
- `ui/time_machine_dock.gd` — new public `on_editor_scene_changed(new_path)`: `_auto_save_current_scene_profile()` → sync field → `_load_settings()` → `_refresh_per_scene_state()`. Header docs + tooltips updated.
- `ui/time_machine_dock.tscn` — checkbox retitled "Remember settings for this scene".
- `test/unit/test_time_machine_dock.gd` (new) — real `RecorderController` + `MockBackend` (mirrors test_recorder_controller.gd) + in-memory `FakeStore extends ConfigStore`; SceneEdit pre-seeded so `_prefill_scene` skips `EditorInterface` (unavailable headless). 8 tests: save-on-leave on/off, untitled-previous no-save, override loaded, defaults when no override, untitled target → defaults + checkbox disabled, recording guard.

## Heads-up (now addressed)

`add_control_to_bottom_panel()` / `add_control_to_dock()` are deprecated in 4.6+ in favor of `add_dock(EditorDock)` with `default_slot = DOCK_SLOT_BOTTOM`. **Migrated 2026-08-01** — see `SESSION_editordock_migration.md`.

## Default source of truth: profiles.cfg `[default]` (2026-08-01)

`CompositeConfigStore` now treats `profiles.cfg` `[default]` as the authoritative default profile:

- **First run**: no local `[default]` section → `get_default_profile()` seeds it from the `EditorSettings` default (EditorSettings remains the seed source), then returns the editor values.
- **After seeding**: the local `[default]` wins on every read — users hand-edit `profiles.cfg` to change global defaults.
- **Write-through**: `save_default_profile()` writes to both stores, so dock edits materialize in `profiles.cfg` `[default]`.

106/106 GUT green. README "Settings" + Architecture updated; `make sync-docs`/`check-docs` pass.

## Update 2026-08-02 — Save/Clear buttons removed

The "Save scene profile" and "Clear" buttons are removed from the dock (tscn nodes, vars, tooltips, signal wiring, and both handlers deleted). The per-scene checkbox ("Remember settings for this scene") is now the single per-scene control:

- **Checked** → auto-save on scene switch / reload on return, exactly as before (`_auto_save_current_scene_profile` untouched). Checking does not save immediately — the save still happens on the next switch.
- **Unchecked** (non-empty scene path) → `clear_scene_profile(scene_path)` drops the stored override (so the unchecked state is durable across sessions — the override can no longer force the checkbox back on at next load), then `_load_profile_into_ui(get_default_profile())` falls back to global defaults. This replaces the removed Clear button.
- **Empty scene path** → no save/clear (checkbox is disabled in that state).
- A new `_syncing_scene_state` guard wraps programmatic checkbox sync in `_refresh_per_scene_state`, so internal `button_pressed` sets (which emit `toggled`) don't fire the clear/fallback side effects.

Untouched: `_auto_save_current_scene_profile`, `on_editor_scene_changed`/`on_editor_scene_closed`, `_flushed_on_close`, `build_config`, `_load_settings`, the ConfigStore API, and the `scene_path = ""` store convention.

Tests: 110/110 GUT green (was 106; +4 dock tests: uncheck-with-override clears + falls back, uncheck-without-override falls back, programmatic uncheck on scene switch records no clear, untitled scene records no clear). No existing tests were modified.
