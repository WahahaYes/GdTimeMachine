# Seed Prompt — Next Session's Orchestrator

Use this as the opening prompt for the next session. It orients the orchestrator (Sisyphus) to the mission, repo state, hard-won findings, and execution protocol. Read `notes/PLAN_obs_backend_v2.md` and `notes/BUGS_obs_backend_regressions.md` (on `obs-backend-wip`) for depth.

______________________________________________________________________

## Mission

Continue the **OBS backend v2 ground-up rebuild** for the GdTimeMachine Godot 4.7 editor addon. The work happens on branch **`obs-backend-v2`** (already checked out from clean `main`), per `notes/PLAN_obs_backend_v2.md`. The user's last instruction was to realign and implement cleanly from the ground up — **minimal core first**, with auth verified by **reference cross-check + real OBS**. Do NOT start coding until the user says "execute PLAN_obs_backend_v2" (the plan itself requires this gate; it was awaiting approval at session end).

## Repo state (verified at handoff)

```
main            1741af5  (clean; pre-OBS baseline)
obs-backend-wip 263b5f8  (v1 experiment archive: impl f74a953, tests 713e147,
                          notes f5e2a96, bug-7 polish 263b5f8; 221 GUT tests green)
obs-backend-v2  dd94633  ← CURRENT BRANCH. Plan committed; no code yet.
```

Working tree clean. Branches never pushed; all local.

## The single most important finding (drives everything)

**The auth algorithm is NOT the bug.** `vendor/obs_client.gd:_generate_auth` = `base64(sha256(base64(sha256(password + salt)) + challenge))` — matches the obs-websocket 5.x spec and reference C++/JS implementations exactly. The user's live test proved the symmetry: OBS with auth *disabled* connects; OBS with auth *enabled* and an intended-matching password gets close code 4009. Therefore the bug is **plumbing**: the password set by the user never reaches `_password` on the client. Supporting evidence: the dock has ZERO OBS settings UI (no `obs/` or `password` matches in `time_machine_dock.gd`), and `_get_obs_settings()` (backend_obs.gd:776) reads EditorSettings-first-then-ProjectSettings via `_get_setting_string` — so a password written to one store while another shadows it yields an empty password → 4009. The v1 "known vectors" in `test_obs_client.gd` were computed by our own function and proved nothing about OBS acceptance.

## The v2 plan in one screen

- **Phase 0 (BLOCKING, do first):** prove plumbing vs algorithm empirically — (1) independent reference cross-check of the auth vector (Python `hashlib`/`base64` or obs-websocket-js, NOT our own function) pinned as a fixed GUT constant; (2) GUT test that the password read from settings lands in `_password`; (3) manual real-OBS matrix (correct/wrong/none password on 4455). Exit criteria: vector test green, plumbing test green, real-OBS behaves as documented.
- **Phase 1:** `vendor/obs_client.gd` — port the v1 client (it held up), minus compute-auth-for-empty-password. Empty password → send NO `authentication` field.
- **Phase 2:** `backend/backend_obs.gd` — `is_available()` = WebSocket reachability ONLY; `is_obs_installed()` = binary with a **resolved-flag** (never empty-String sentinel — that was Bugs 1/3/4). Error surfacing keeps `_last_connect_error` + `_describe_start_error()` from the v1 Bug-7 fix. Move-after-stop only; no `SetRecordDirectory`. Never restart/kill the game (`IN_PLACE` invariant).
- **Phase 3:** `plugin.gd` + `time_machine_dock.gd` — register `obs/*` EditorSettings defaults + `BackendOBS`; dock gates OBS by `is_available()`, native-format filter (mp4), one-time install dialog guarded by `dont_show_obs_hint`.
- **Deferred (do NOT create):** `platform_capture.gd`, `obs_token_persistence.gd`, `needs_setup()`/Wayland dialog, tier-2 ffmpeg wiring, `SetRecordDirectory`, auto-close idle teardown.

## Two open user decisions from the plan (re-ask before executing)

1. **Dock has no OBS settings UI** — v1 keeps password config in Project > Editor Settings and proves the read path with a test. If the real-OBS run shows that's where the password got lost, a dock password field becomes a follow-up.
1. **Real-OBS Phase 0 needs a machine with OBS on 4455** — ask whether to gate execution on that being available, or run the code-side gate (reference vector + plumbing test) first and leave the manual matrix to the user.

## Execution protocol (non-negotiable)

1. **Read first:** `notes/PLAN_obs_backend_v2.md` (v2 plan, on this branch), `notes/BUGS_obs_backend_regressions.md` + `notes/PLAN_obs_backend.md` (archive, on `obs-backend-wip` — `git show obs-backend-wip:notes/...` if needed).
1. **Gate:** do not write feature code until the user explicitly approves execution. Phase 0 is blocking — everything hangs off a verified auth path.
1. **Delegate:** each phase = one `task(category=…, load_skills=[…])` lane; workers read the plan file as their prompt. No worker implements without it.
1. **Verify:** `make test-godot` (headless GUT) after every phase — must stay green (currently 221 passing on the archive branch). Manual items are in plan §9.
1. **Git hygiene:** prefix git commands `GIT_MASTER=1`. Pre-commit hooks (trailing-whitespace, end-of-file-fixer, gdformat, mdformat) MODIFY files and abort the commit on first run — always `git add` again and re-commit when a hook reports "Failed / files were modified". Never commit unless the user asks.
1. **Docs:** update `notes/` continually (AGENTS.md rule). `make sync-docs` if README/LICENSE drift is flagged by hooks.
1. **Bug-fix rule:** fix minimally, never refactor while fixing. Never suppress type errors. Match existing style (tabs, snake_case, doc comments on new members).

## Anti-goals (do not drift into)

- Do NOT resurrect the v1 incremental-fix approach — the rebuild exists because patching produced 7 interacting regressions.
- Do NOT add the deferred features (§1 of the plan) even if "easy" — scope is locked.
- Do NOT touch `backend_movie_maker.gd`, `backend_screenshot_capture.gd`, `recorder_backend.gd`, `ffmpeg_convert.gd`, `config/*`, `controller/*` (except the plugin.gd registration seam).
