# Phase 3 dock wiring — design decisions (2026-08-16)

Two spec-open design decisions from `notes/SEED_phase3_dock_wiring.md` §6, settled before coding. Read alongside `notes/PLAN_obs_backend_v2.md` §6 and `notes/PROGRESS_obs_backend_v2.md`.

## D1 — Gating + install dialog (item 2): keep OBS selectable, suffix-mark it

Spec tension: §6 wanted the OBS item "— not available" *greyed*, but §9 item 5 also expects the one-time install dialog to be reachable. A fully `set_item_disabled`'d item cannot fire `item_selected`, so the dialog would be unreachable — unless we bypass selection entirely (over-engineering).

**Chosen:** the item stays selectable. It is marked with the `" — not available"` suffix plus an explanatory per-item tooltip ("greyed" = the suffix marker; the visual disabled-gray would cost the dialog). The install dialog fires from `_on_backend_selected()` when an unavailable *OBS Studio* is chosen. Recording while unavailable still fails actionably from the backend's own B1 error path ("OBS Studio not found … Tools → WebSocket Server Settings"), so no silent failure is introduced.

Identity fallout: item text is no longer the backend name, so the dropdown switches from text-matching to `set_item_metadata`/`get_item_metadata` everywhere it resolves an item's backend name (`_select_backend_item`, `_on_backend_selected`, `_build_profile_from_ui`).

## D2 — Live availability refresh (item 5): forward at the controller level

The probe is async (`BackendOBS.availability_changed`), so the dock must re-mark when availability flips. Two candidate paths from the seed: (a) a `RecorderController.get_backend(name)` accessor + the dock subscribing to the backend's own signal; (b) a controller-level availability signal.

**Chosen:** (b), plus a thin `RecorderController.is_backend_available(name)` read-only wrapper for initial marking. The controller already forwards every other backend signal (`recording_*`); forwarding `availability_changed` keeps the invariant "the dock never holds a backend reference / never reaches into a backend" literally true — the dock only ever subscribes to controller signals and calls controller methods. `get_backend()` is not added because nothing needs the backend object itself. The forwarding is guarded with `has_signal("availability_changed")` (not in the base contract) and bound with the backend name at connect time.

## Non-decisions (spec text, no latitude)

- Native formats: `_get_allowed_formats()` consults `get_native_formats()` via a `has_method` guard when it exists on the active backend (OBS → `[MP4]`); the IN_PLACE/blanket lists remain the fallback for Movie Maker / Screenshot.
- Hint flag: `hints/dont_show_obs_hint`, default `false`, registered in `plugin.gd._ensure_editor_settings_defaults()` with property info; read/written by the dock via an injected-settings seam (mirrors `BackendOBS._editor_settings`, so headless GUT never touches the real EditorSettings).
- Dialog text is built dynamically from the real settings host/port (Bug-6 lesson; the key reference already lives in `BackendOBS._get_obs_settings()`).
- Status line: OBS `recording_error` / `recording_notice` flow through the existing `recording_*` handlers unchanged (verify by test, no rework).

## Validator amendment (2026-08-16)

Two findings from the final review pass, both fixed in code + tests:

- **M1 (implementation bug → D1 enforcement):** the first cut of `_maybe_show_obs_install_hint` never checked availability, so the hint popped even for a *reachable* OBS (its text asserts the opposite). Fixed with an `is_backend_available(backend_name)` guard; regression-tested (`test_selecting_available_obs_does_not_request_install_dialog`). Wording normalized from "one-time hint" to "hint repeatable until suppressed".
- **S2 (Phase-3-introduced status dangle):** native-format narrowing makes OBS's format dropdown always `[MP4]`, and the pre-existing `_expects_conversion()` returned true for IN_PLACE + MP4 — but BackendOBS emits only `recording_stopped` (never `recording_converted`), so every OBS stop would have left "Converting to mp4…" on the status line forever. Fixed by exempting the active backend's own `get_native_formats()` in `_expects_conversion()`; regression-tested (`test_obs_stop_shows_saved_not_converting`).
