# Design — OBS lifecycle hardening (auto-close leaks)

Date: 2026-08-16. Session: post-"we no longer see logs" forensics.

## Problem (observed, twice in one day)

`BackendOBS` owns the OBS it launches (`_we_launched`/`_launched_pid`) and kills it in `_exit_tree` when `auto_close` is on. Empirically this leaks:

1. An OBS launched at 10:22:29 (`--minimize-to-tray`, our own spawn — timestamp matches a `recording_smoke_…10-22-29.mp4`) was still alive at 17:09, ~7 h after its godot parent died. Its parent was long gone, PPID reparented to `systemd --user`; nothing ever killed it.
1. A second OBS (PID 77353, spawned 17:14:58 via a shell wrapper) ignored SIGTERM (`OS.kill` never killed it); a manual `kill -9` was required.

### Root causes

- **C1 — single cleanup path**: the only kill site is `_exit_tree`. A hard godot exit (crash, SIGKILL, editor replaced mid-session) never runs it. There is no recovery on the *next* startup.
- **C2 — no escalation**: `_kill_process` = `OS.kill(pid)` (SIGTERM), one shot, no wait, no SIGKILL fallback. Some OBS builds ignore TERM.
- **C3 — no ownership record across sessions**: `_we_launched` is in-memory only, so nothing external can tell "this OBS belongs to a dead GdTimeMachine session".

## Decisions

### D1 — recovery ledger (`user://`)

Persist launch ownership to disk so a later session can reap orphans:

- File: `user://gdtime_obs_launched.cfg` (ConfigFile), key `obs/pid` and `obs/binary` (the resolved binary path passed to `create_process`).
- Written in `ensure_obs_running()` immediately after a successful launch (pid > 0), via seams `_persist_launched_pid(pid, binary)` / `_load_launched_ledger() -> Dictionary` / `_clear_launched_ledger()`.
- Cleared when we kill what we launched AND confirm it died (timeout path). NOT cleared in `_exit_tree`: the sweep decides from evidence.

### D2 — startup orphan sweep

`_reap_orphaned_launches()` (async), called from `_ready()` **before** the `Engine.is_editor_hint()` gate (so the drive tool benefits too; GUT test fakes override `_ready` with `pass`, so tests never run the real sweep):

1. Gate on `_get_auto_close_setting()`; if off, no-op (even orphans stay — the user opted out of management).
1. Load ledger. No entry → done.
1. If `_is_process_alive(pid)` is false → clear ledger (dead, nothing to reap).
1. If alive but `_process_is_ours(pid, binary)` is false (pid recycled to some other process, or cmdline no longer matches) → log a warning, clear ledger, do NOT kill. Never kill a process that does not provably match our launch.
1. Else: `_kill_process_and_wait(pid)` (TERM → grace → SIGKILL), log a `[GdTM]` line (direct `print`, same rationale as `_exit_tree`: the plugin's feedback handlers may not be attached yet), clear ledger.

Note: `_exit_tree` deliberately leaves the ledger entry behind. Graceful close TERMs the OBS; the next startup's sweep sees a dead pid and clears the entry silently. If TERM silently failed (C2), the sweep escalates — the leak is contained to at most one startup.

### D3 — kill escalation

- `_is_process_alive(pid) -> bool` seam = `OS.is_process_running(pid)` (exists in 4.7; verified). Stubbable in GUT.
- `_process_is_ours(pid, binary) -> bool` seam: Linux reads `/proc/<pid>/cmdline` and requires our exact binary path + `--minimize-to-tray`; non-Linux = best-effort true (documented limitation).
- `_force_kill_process(pid)` seam: Linux `OS.execute("kill", ["-9", pid])`; Windows `taskkill /F /PID`; other → yes another `OS.kill`.
- `_kill_process_and_wait(pid) -> bool` (async): `OS.kill(pid)` (TERM), then up to ~2 s grace polling `_is_process_alive` via the existing `_sleep` seam, then `_force_kill_process`, return gone-or-not.
- Timeout path in `ensure_obs_running()` switches from bare `_kill_process` to `_kill_process_and_wait` + `_clear_launched_ledger()`.
- `_exit_tree` stays best-effort `_kill_process` (TERM; or escalate immediately since recording was already stopped — keep TERM-only, sweep is the safety net).

### D4 — reuse notice (approved earlier this session)

The fast path (`is_obs_running()` true → reuse, no launch) was silent by design; a leftover OBS made it impossible to tell the tool was reusing instead of launching. Now `ensure_obs_running()` emits `"OBS Studio is already running — reusing it."` via `recording_notice` on the fast path before returning true. The existing "reachable" notice in the launch loop already covers the launched case.

## Semantics guaranteed after this work

- Graceful editor close: TERM at `_exit_tree`; next startup confirms dead, clears ledger.
- Hard godot death: next startup sweeps → TERM → SIGKILL if needed → cleared.
- We never kill an OBS we did not launch, and never kill a pid whose cmdline proves it is no longer our spawn. On Linux the /proc cmdline check makes the no-recycle-kill guarantee strict; on other platforms verification is best-effort (no reliable /proc) and killing relies on the ledger alone.
- `auto_close` off = we manage nothing, including orphans (consistent with D1).

## Out of scope

- Killing an OBS the *user* started manually with `--minimize-to-tray` (the 17:14 shell spawn was external, not ours; we must not touch it).
- A standalone watchdog that reaps without a godot session (no new processes).
- Cross-platform /proc verification beyond Linux (documented best-effort).
