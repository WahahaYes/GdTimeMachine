# Contributing

Quick checks before a PR:

1. `make test-godot` — must be green (GUT-SUITE-OK, 284+ tests).
1. `make check-docs` — README sync (`README.md` ↔ `addons/GdTimeMachine/README.md`).
1. `pre-commit run --all-files` — mdformat, gitleaks, gdformat.

Notes live in `notes/archive/`; active work uses `notes/ENHANCEMENT_CLI_COMPANION.md` as roadmap. Keep `tools/` empty (dev drivers were removed for release).
