# Transcoding architecture: from hand lists to capabilities

Status: IMPLEMENTED (Phases 0–4). No migration shims, aliases, or fallbacks — bare backends derive natives-only, test doubles declare artifacts, the `is_tier2_format` / `frames_need_ffmpeg` / `is_frames_source_format` classifiers plus the `ffmpeg_not_found` signal are deleted, and settings live only under `transcoders/` (the pre-namespace `ffmpeg/*` keys are gone without replacement). Related: `notes/availability_rework.md` (dropdown availability treatment).

## 1. Problem statement

Every transcoding decision today is a hand-maintained list or a backend-identity branch. Adding a backend (e.g. a second OBS-like recorder) or a transcoder (e.g. HandBrake, avconv) means touching the converter, every backend, the dock, `output_format`, the doctor, and the tests — with no compiler help when you miss one. Concrete symptoms already hit us:

- OBS offered AVI/OGV it can never record, with labels that couldn't display honestly (suffix lived in the static per-format string).
- `movie_writer.gd` connected a 2-arg lambda to a 1-arg signal (found in this audit; fixed by switching the CLI path to the blocking `convert_file_sync`).
- `auto_convert` lookup order differs between backends (`PS→ES` in Movie Maker/OBS, `ES→PS` in Screenshot); `clean_frames` is honored only by Screenshot while the others hardcode `false`.

## 2. Audit: where the knowledge lives today

(Line numbers refer to the pre-change codebase; every item below is resolved unless captioned "keep". Findings verified by two parallel code surveys.)

### 2.1 Backend-identity / format-identity branches (all must die or shrink)

| Site | Branch | Decides | |---|---|---| | `ui/time_machine_dock.gd:385-408` `_get_allowed_formats` | `has_method(get_supported_formats)` → natives → `IN_PLACE` list → RESTART list | dropdown contents (3 fallbacks) | | `dock:442-454` `_format_needs_ffmpeg` | `format_needs_ffmpeg` → natives → `IN_PLACE?frames:tier2` | disabled gate, tooltip, `Converting…` (3 fallbacks) | | `dock:461-467` `_is_format_native` | natives → `!needs_ffmpeg` | suffix, warning (2 fallbacks) | | `dock:346,796` | `backend_name == OBS_BACKEND_NAME` | tooltip text, install-hint eligibility | | `backend/recorder_backend.gd:83-119` | natives → capture-mode lists | base defaults duplicating the dock fallbacks | | `config/output_format.gd:41,55` | `is_tier2_format` / `frames_need_ffmpeg` | the two primitives everything keys off | | `plugin.gd:487` | `mode == RESTART_SCENE` | game-view button disable (legit — keep) | | `dock:1069` | `mode == IN_PLACE` | bare-base vs `base.ext` output path (legit — keep) |

Keep-worthy branches: capture-mode output paths, game-view button, OBS install hint (any backend with an installable dependency generalizes this — see §4.5).

### 2.2 Duplication: per-backend ffmpeg trios

Movie Maker, Screenshot, OBS each own: `_ffmpeg_converter` var, `_create/_ensure/_trigger`, `_on_succeeded/_on_not_found/_on_failed`, `_exit_tree: wait_for_completion`, `_get_auto_convert_setting`. The three `_ensure` bodies and the success/failed handlers are line-for-line identical; only the `convert_file_async` vs `convert_frames_async` call and the gate (`is_tier2` vs `frames_need_ffmpeg` vs native-check) differ.

### 2.3 Transcoder API surface (`backend/ffmpeg_convert.gd`, 575 lines)

- Availability: `probe_ffmpeg()` (`ffmpeg -version` == 0), `is_available()` alias, `get_unavailable_reason()`, `_get_ffmpeg_binary()` (\`ES → PS → "ffmpeg").
- Builders (pure): `build_frames_convert_command` (frames `%05d` + measured fps → mp4/webm/avi/ogv, PNG/JPG skip), `build_file_convert_command` (file → mp4/webm/avi/ogv + fps filter).
- Runners: `convert_*_sync` (blocking, `{exit_code,output_path,reason}`) and `convert_*_async` (single `_thread`, `call_deferred` back).
- Signals: 1-arg `conversion_succeeded`, 2-arg `conversion_failed`, 1-arg `ffmpeg_not_found` — vs backend-level 2-arg `recording_converted(backend, clip)`, forcing the per-backend adapter trio (§2.2).

### 2.4 Second-transcoder blockers

1. Hardcoded `ffmpeg` binary name, `["-version"]` probe, `ffmpeg/*` settings keys across 7 files; `which obs` pattern would repeat.
1. Single-converter assumption: typed `_ffmpeg_converter` vars, concrete `-> GdTMFFmpegConvert` factories, one-job `_thread` guard.
1. `ffmpeg_*` naming everywhere: methods, signals, dock seam (`_create_ffmpeg_checker`, `_ffmpeg_probe_override`), `display/warning` suffix strings, controller docs.
1. No capability query at transcoder level — `is_format_supported` lives on backends (hand lists), so availability can't re-derive deliverables.
1. Settings not namespaced for plurality (`transcoders/ffmpeg/*` needed) and lookup order inconsistent (§1).

## 3. Design principles

1. **Capabilities are queried, not listed.** Backends declare what they *produce* (native artifact); transcoders declare what they *transform* (input → outputs). The dock computes — never stores — the deliverable set.
1. **One adapter, not N trios.** Signal-shape translation (transcoder-level → backend-level) lives in exactly one shared helper.
1. **Availability is an event.** Registry fans transcoder up/down out to the dock, so mid-session installs re-derive the UI (today's lists are frozen at populate time).
1. **Incremental migration, suite green each step.** New types alongside old call sites; backends adopt one at a time; delete fallbacks last.

## 4. Proposed architecture

### 4.1 `RecorderTranscoder` interface (new base, `backend/transcoder.gd`)

```gdscript
class_name RecorderTranscoder extends Node
signal conversion_succeeded(output_path: String)   # unchanged shape
signal conversion_failed(error_message: String, detail: String)
signal transcoder_not_found(message: String)
func get_transcoder_name() -> String               # "ffmpeg"
func is_available() -> bool                        # probe
func get_unavailable_reason() -> String
# Capability edges. Input: {"kind":"file","format":Format} or {"kind":"frames","frame_ext":"png"}.
func can_convert(input: Dictionary, target: GdTMOutputFormat.Format) -> bool
func convert_async(input: Dictionary, output_path: String, options: Dictionary) -> void
# options: {"fps":int, "measured_fps":float, "frame_ext":String, "clean":bool}
func wait_for_completion() -> void
```

`GdTMFFmpegConvert` becomes `TranscoderFFmpeg extends RecorderTranscoder`: `can_convert` returns true for file→{mp4,webm,avi,ogv} and frames→{mp4,webm,avi,ogv} (exactly its current builder arms — capability *derived from what the builders implement*, so the two can never drift). `convert_async` dispatches to the existing `convert_file/frames_async` by `input.kind`. Keep the old method names working (thin wrappers) until callers migrate.

### 4.2 `TranscoderRegistry` (new, owned by `RecorderController`)

```gdscript
signal transcoder_availability_changed(transcoder_name: String, available: bool)
func register_transcoder(t: RecorderTranscoder) -> void
func find_transcoder(input: Dictionary, target: Format) -> RecorderTranscoder  # first available, registry order
func is_target_reachable(input: Dictionary, target: Format) -> bool  # any (even unavailable) edge — for "disabled with reason" vs "unsupported"
```

Controller forwards availability as `backend_availability_changed`-style signal; `plugin.gd` registers the built-in ffmpeg transcoder at startup (next to backend registration). Doctor iterates `registry.list()` instead of its hardcoded ffmpeg block; each transcoder contributes its own `doctor_check()` line.

### 4.3 Backend contract v2 (narrow the backend, widen the derivation)

Backends keep `get_native_formats()` and **replace** hand-written `get_supported_formats()` with a derived default on the base:

```gdscript
# base: natives ∪ {every Format with any registry edge from my artifact}
func get_supported_formats() -> Array
func get_native_artifact() -> Dictionary  # {"kind":"file","format":MP4} OBS, {"kind":"file","format":AVI} Movie Maker, {"kind":"frames"} Screenshot
```

Backends that want to *restrict* (taste/policy) override `get_supported_formats()` — restriction becomes explicit and greppable, instead of today's silent omission. `format_needs_ffmpeg(fmt)` becomes `not natives.has(fmt)` (true by construction for derived entries).

This deletes: dock `_get_allowed_formats` fallbacks, base capture-mode lists, and the next hand-list bug. `is_tier2_format`/`frames_need_ffmpeg` stay as transcoder-edge predicates inside `TranscoderFFmpeg`, not UI logic.

### 4.4 Shared transcode request (delete the trios)

One base helper replaces ~40 lines × N backends:

```gdscript
# RecorderBackend
func request_transcode(input: Dictionary, output_path: String, options: Dictionary) -> bool:
    # finds transcoder via controller registry, one-shot-wires signals with
    # backend-name adapters (notice Converting… → converted/notice | not-found notice | error), returns false + emits actionable error when none available
```

Backends keep only: intermediate/final path building (artifact-specific), `_needs_ffmpeg_convert()` gate, `_get_auto_convert_setting()`. The `movie_writer.gd` arity class of bug becomes unrepresentable — adapters exist once. Unify `auto_convert` lookup order to `config → ES → PS → true` (BackendOBS convention) and thread `clean_frames` through job options for all file converts (today only Screenshot honors it).

### 4.5 Generalized install hints

`OBS_BACKEND_NAME` checks become `get_install_hint() -> Dictionary` (`{}` = none) on the base: OBS returns title/body/url/suppress-key, others `{}`. Dock shows the dialog for *any* backend returning a hint — a future HandBrake-dependent backend gets hints free.

### 4.6 Settings namespace (with migration)

```
transcoders/active := ["ffmpeg"]            # ordered preference
transcoders/ffmpeg/path | auto_convert | clean_frames   # migrated from ffmpeg/*
transcoders/<name>/...                      # future transcoders
```

`plugin.gd` sets `transcoders/*` defaults. Recorder backends read `auto_convert`/`clean` from the *active* transcoder's section via base `_transcoder_setting()`, not hardcoded paths.

## 5. Migration phases (each lands green)

- **Phase 0 — DONE:** `movie_writer.gd` → `convert_file_sync`.
- **Phase 1 — DONE:** `RecorderTranscoder` + `GdTMFFmpegConvert extends` it (with `can_convert` + `convert_async` dispatch), `TranscoderRegistry` on the controller, plugin registers ffmpeg at startup; dock asks the controller (registry, else one direct probe); doctor untouched (Phase 4).
- **Phase 2 — DONE:** base `get_supported_formats()` derives natives + registry edges (no registry/artifact → natives only); backends declare `get_native_artifact()` and their hand `get_supported_formats()` lists are deleted; dock calls the interface directly with no fallbacks; registry availability re-populates the dropdown live. Test doubles declare natives + artifacts and attach stub registries (mirroring production).
- **Phase 3 — DONE:** base `request_transcode()` + shared terminal handlers; per-backend trios (ensure/handlers) deleted, triggers reduced to input-dict builders; `ffmpeg_not_found` deleted everywhere; `auto_convert` lookup unified to config → ES → PS → true. Deviation kept deliberately: file converts still pass `clean: false` (deleting AVI/MP4 intermediates by default would destroy masters users may want — `clean_frames` stays a frames concern until a contributor argues otherwise).
- **Phase 4 — DONE:** `transcoders/active` + `transcoders/ffmpeg/*` settings; readers resolve `transcoders/<active>/` only (EditorSettings → ProjectSettings) via base `_transcoder_setting()` (shared with the converter's binary resolution, now EditorInterface-aware); `_get_auto_convert_setting` and `_get_clean_on_success_setting` moved to the base (four copies deleted); doctor iterates a local registry via `doctor_check()` with byte-identical output (verified live); install hints generalized to `get_install_hint()` cards (OBS provides one, dock shows any backend's, suppression key travels in the card).

## 6. Open decisions (settled unless noted)

1. One `convert_async(job)` — SETTLED: single job dict; transcoders return `can_convert == false` for kinds they don't do.
1. Registry ownership — SETTLED: controller (owns backends, forwards both signal families). Registry holds weakrefs only; node lifetime stays with whoever add_child'd (controller in production, tests in unit tests).
1. `ffmpeg_not_found` — SETTLED: deleted outright, no alias.
1. OBS stills (PNG/JPG via file→frames extraction) — OPEN, needs a new converter builder + edge.
1. Settings namespace — SETTLED: `transcoders/<name>/` sections with `transcoders/active` preference (registration order follows it). No fallback reads.
1. Install hints — SETTLED: `get_install_hint()` cards on the backend contract; dock renders any backend's card.
1. Per-request vs per-backend transcoder instances — SETTLED for now: per-backend owned instances via the `_create_ffmpeg_converter()` seam (default consults `spawn_preferred()`), preserving the exact old one-job-at-a-time concurrency. Per-request pooling is future work if a second transcoder makes it necessary.
