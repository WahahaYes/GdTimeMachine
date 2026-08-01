# Agent Guidelines

Guidelines for AI agents working in this codebase.

## Documentation

Plans scoped to the duration of one or few sessions should be written into `notes/` and continually updated.

## Build Tasks

Prefer `make` targets over executing arbitrary shell commands to preserve context. Check the [Makefile](Makefile) for available targets before proposing custom commands.

For example, `make launch-editor` instead of running godot directly.
