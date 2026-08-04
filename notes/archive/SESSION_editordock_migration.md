# EditorDock Migration — `add_control_to_bottom_panel` → `add_dock(EditorDock)` — SHIPPED 2026-08-01

Status: Shipped. 104/104 GUT green (was 103; +1 new dock test).

Fixes the deprecation flagged in `SESSION_scene_aware_profiles.md`: `add_control_to_bottom_panel()` / `add_control_to_dock()` are deprecated in 4.6+ in favor of `EditorPlugin.add_dock(EditorDock)`.

## The new API (verified against 4.7 source + docs)

- `EditorDock` — ClassDB-registered (`GDREGISTER_CLASS(EditorDock)` at register_editor_types.cpp#L160), inherits `MarginContainer < Container < Control < CanvasItem < Node < Object`. Can be `EditorDock.new()`, `extends EditorDock` in GDScript, or used as a `.tscn` root (`type="EditorDock"`).
- `default_slot = EditorDock.DOCK_SLOT_BOTTOM` (value 8) → bottom panel; `title` → tab title. `DockSlot` enum: NONE=-1, LEFT_UL=0 … RIGHT_BR=7, BOTTOM=8, BOTTOM_L=9, BOTTOM_R=10, MAX=11.
- `DockLayout` bitfield: VERTICAL=1, HORIZONTAL=2, FLOATING=4, ALL=7; default `available_layouts` is VERTICAL|FLOATING — for a bottom-panel tool set at least HORIZONTAL (we use ALL).
- `add_dock(dock)` / `remove_dock(dock)` — thin delegations to `EditorDockManager` (editor_plugin.cpp#L133-L139). Manager reads `default_slot` once at add time and opens the dock there.
- Old API still functions in 4.7 (wrapped in `#ifndef DISABLE_DEPRECATED`, editor_plugin.cpp#L88-L131) — low urgency, but migrated anyway. `add_control_to_dock` is now itself a shim that builds an `EditorDock` wrapper.
- Gotchas: dock is **not** a child of the plugin (manager reparents it); teardown is `remove_dock(dock)` → `queue_free()` → null; skipping `remove_dock` leaves it in `all_docks` and re-add fails hard. Class is marked Experimental in 4.7 docs.

## Changes

- `plugin.gd` — `_enter_tree` now builds an `EditorDock` (`title = "GdTimeMachine"`, `default_slot = DOCK_SLOT_BOTTOM`, `available_layouts = DOCK_LAYOUT_ALL`), adds the existing dock scene as its child, then `add_dock(_editor_dock)`; `_exit_tree` does `remove_dock` → `queue_free()` → null. New `_editor_dock: EditorDock` member.
- `test/unit/test_time_machine_dock.gd` — +1 test: `test_scene_switch_from_override_scene_to_unchecked_scene_loads_defaults`.

## Fallback requirement (user request, verified)

"If remember settings for a new scene is unchecked, moving to a new scene should still fall back to the default settings rather than do nothing."

Verified: `on_editor_scene_changed()` unconditionally calls `_load_settings()` → `_config_store.resolve_profile(new_path)` (scene override > default), so a new scene with no per-scene override loads the default profile and the checkbox unchecks — it does not "do nothing". The previous scene's per-scene values (checkbox checked) do not leak into the new scene. Pinned by the new test: start on a scene with an override (checkbox on, override values in the UI), switch to an override-less scene → checkbox off, default profile loaded into the UI.
