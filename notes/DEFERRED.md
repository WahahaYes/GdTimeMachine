# Deferred Work

Captures items intentionally not shipped as of `v0.1.1` (CLI batch `gdtime` + editor addon at `284/284` GUT, Asset Library ready). GDScript-native CLI was chosen over the earlier Python-bundled-venv / Rust-single-binary options — revisit only on demand.

## Editor / Capture

- **Recent-captures list** — dock ItemList of previous recordings (deferred from Phase 5).
- **Replay buffer ("Record That")** — OBS replay-buffer workflow; needs pre-configured buffer, separate from normal record.
- **`BackendMovieMakerCLI`** — headless Movie Maker variant; delegated to `core/movie_writer.gd` (`godot --path <wt> --write-movie`).
- **Wayland portal dialog** — `needs_setup()` + token persistence (`obs_token_persistence.gd` / `platform_capture` portal flow) never created. Only mattered as a Linux/Wayland-first idea; not needed for current backends.
- **`SetRecordDirectory` handling** — move-after-stop (`StopRecord.outputPath` → dock `output_path`) only; no OBS `SetRecordDirectory` branch.

## CLI companion (`gdtime`)

- **Dock batch UI** — add/remove/reorder entries, git-log picker, “Export Manifest” button. CLI owns execution; GUI follows (manifest is `addons/GdTimeMachine/cli/schema/batch_manifest.schema.json`).
- **CI integration** — manifest enables it; no runner work.
- **Rust single-binary rewrite** — closed: GDScript shim `addons/GdTimeMachine/cli/gdtime` (`godot --headless -s cli/main.gd`) is preferred; revisit only if a binary outside Godot is needed.

## Process

- `CONTRIBUTING.md` / tag `v0.1.1` + `CHANGELOG` / `media/` gif — intentionally held until polish seed landed (covered in archived `SEED_cli_v0_1_1_polish.md` acceptance).
