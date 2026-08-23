# TEST_SUITE_AUDIT_2026-08-16

Audit of `test/unit/*.gd` (+ `test/manual/recording_smoke.gd`) for no-op tests, regression-pinned tests, third-party-reproducing tests, and redundancy — with a defense of the tests that earn their place and a proposal for more effective coverage. Read-only audit (no production or test code changed; findings only).

______________________________________________________________________

## TL;DR

- **282 audited test functions across 15 files: 231 KEEP (82%), 18 WEAK, 20 REDUNDANT, 10 PINBUG, 3 NOOP, 0 3P.**
- **Headline structural finding — the suite's "green" signal is untrustworthy.** During this audit a one-character invalid GDScript escape in `BackendOBS` silenced **4 test files (≈43 tests incl. 3 files that failed to compile) while both the CLI exit code and `make test-godot` remained 0.** Recommendation #1 is a harness fix (see §11), not a test fix.
- **Zero tests that merely re-prove third-party code.** Every fake is passive; asserted values flow through real SUT logic. The three OBS auth vectors were independently re-derived in Python during this audit and match byte-for-byte.
- **Three true no-ops** to delete, **20 redundant twins** to either delete or absorb, **10 verbatim user-facing-copy pins** to loosen (`contains()`/enum/URI asserts).
- Highest-value coverage gaps: request-refusal/status-500 handling, wrong-id reply rejection, the debugger `_capture` mirror↔source equivalence, malformed inbound frames.

______________________________________________________________________

## 1. Incident uncovered during the audit (suite masking)

This is the most important finding and it predates the audit itself. While running spot-checks, a live failure was discovered in the uncommitted OBS lifecycle-hardening WIP (`notes/DESIGN_obs_lifecycle_hardening.md`, `backend_obs.gd` + `test_backend_obs.gd`):

- `backend_obs.gd:824` contained `cmdline.split("\0")` — `"\0"` is not a valid GDScript escape. `BackendOBS` failed to parse, which then failed compilation of **every script referencing the global class**: `test_backend_obs.gd` (28→35 tests), `test_plugin_button_state.gd` (5→0), `test_plugin_shortcut.gd` (7→2), `test_plugin_toggle.gd` (3→0).
- **Every affected run still reported success:**
  - GUT's `-gexit` returned **0** even with "Failed to load script … Parse error" (observed directly: `gut_wip.log` run exited 0 with 4 broken files).
  - `make test-godot` pipes through `grep … || true`, so its exit code is **always 0** regardless of outcome.
- The escape was being fixed live during the audit (mtime 18:11:25; now `char(0)`, which is valid GDScript 4). With the fix in place: **289/289 tests pass, 0 script errors, exit 0.** The suite is green *at this instant* — the point is that nobody could have known when it wasn't.

**Why this matters for the user's question:** a test suite whose harness swallows script-load failure cannot defend anything. Before spending effort on test quality, the suite must fail loudly when a file doesn't run to completion (§11, items 1–2).

______________________________________________________________________

## 2. Method and scope

- All 282 test functions read in full by 7 parallel read-only reviewers, each tagged with exactly one verdict: `KEEP | NOOP | PINBUG | 3P | REDUNDANT | WEAK`.
- Cross-file redundancy searched (controller forwarding vs dock vs backends; the three auth-vector tests; base-class vs subclass tests; format labels across files).
- Independent verification performed during this audit: the three OBS auth vectors were re-computed with Python (`hashlib`/`base64`) and match byte-for-byte; all NOOP claims spot-checked at source; the `assert_true(true)`/tautology claims verified inline; the `recording_notice` chain checked link-by-link across the three suites.
- Scope exclusions: `addons/gut/` (vendored), UI scenes, manual playbook. Timing/flake risk was assessed per-file; current suite has exactly 5 real-time waits, all in `test_backend_movie_maker.gd` (§10).

## 3. Verdict tally by file

| File | Tests | Verdicts (K/W/R/P/N) | Grade | |---|---|---|---| | test_time_machine_dock.gd | 47 | 41/1/2/3/0 | B | | test_backend_screenshot_capture.gd | 42 | 37/3/1/1/0 | A− | | test_backend_movie_maker.gd | 32 | 26/0/4/1/1 | A | | test_debugger_plugin.gd | 30 | 26/3/1/0/0 | B | | test_backend_obs.gd | 28 (35 WIP) | 22/2/2/2/0 | A | | test_recorder_controller.gd | 24 | 20/1/3/0/0 | B | | test_obs_client.gd | 16 | 11/1/1/3/0 | A | | test_ffmpeg_convert.gd | 14 | 10/1/3/0/0 | B | | test_config_store.gd | 11 | 9/1/1/0/0 | A | | test_output_format.gd | 10 | 9/1/0/0/0 | A | | test_graceful_stop_autoload.gd | 7 | 7/0/0/0/0 | A | | test_plugin_shortcut.gd | 7 | 4/2/0/0/1 | B | | test_recorder_backend.gd | 6 | 2/2/1/0/1 | C | | test_plugin_button_state.gd | 5 | 4/0/1/0/0 | B+ | | test_plugin_toggle.gd | 3 | 3/0/0/0/0 | A | | **Total** | **282** | **231/18/20/10/3** | **A−** |

K = KEEP, W = WEAK, R = REDUNDANT, P = PINBUG, N = NOOP, 3P = 0 everywhere.

## 4. NOOP (3) — delete these

| Test | Why it cannot fail | Action | |---|---|---| | `test_recorder_backend.gd:26` `test_default_start_and_stop_do_not_crash` | `assert_true(true)` after base-class `start`/`stop` (literal `pass` stubs); no reachable error path. | **Delete.** | | `test_backend_movie_maker.gd:418` `test_set_movie_file_does_not_call_save_indirectly` | Own comment admits "Fake does not track save calls anymore" — its one assert re-checks start() plumbing already proven at :119. | **Delete.** | | `test_plugin_shortcut.gd:55` `test_should_use_meta_returns_bool` | `assert_true(… is bool)` is a tautology; the platform seam can't return anything else. | **Delete** (or assert a concrete per-OS branch, §8). |

**Defense of a token that *looks* like a no-op but isn't:** `test_debugger_plugin.gd:387` `test_send_to_session_null_is_noop` uses `assert_true(true)`. This is a legitimate **crash-guard test**: `_send_to_session(null)` goes through a real guarded path, and a regression dropping the null check errors the test run. GUT surfaces crashes as failures, so the "reaching here" assert has signal. Keep as-is; it is the honest maximum for a void function with no observable side effect. (The recorder_backend one at :26 does **not** qualify — its `start`/`stop` are `pass` stubs with no real path.)

## 5. PINBUG (10) — brittle pins of user-facing copy

These assert **verbatim project-authored strings**; any legitimate copy edit breaks CI while behavior stays correct. All are fixable by asserting structure, not letters.

| Where | Pinned string | Fix | |---|---|---| | test_obs_client.gd:313 | `"Connection failed — could not reach OBS at 127.0.0.1:4455 (close code 1006)"` | `contains("127.0.0.1")` + `contains("4455")` + `contains("1006")` | | test_obs_client.gd:333 | `"Authentication failed — OBS rejected the password (close code 4009)"` | `contains("Authentication failed")` + `contains("4009")`; also **de-duplicate** the string constant shared with `test_backend_obs.gd:92` | | test_obs_client.gd:349-352 | `"Connection timed out — no Hello from OBS within 5 s (is the WebSocket server enabled?)"` | `contains("timed out")` + `contains("WebSocket")` | | test_backend_obs.gd:574-577 | Three launch-progress notices ("OBS Studio isn't reachable…", "Launched OBS Studio (pid 4711)…", "OBS Studio is reachable.") | assert ordering + pid/number presence, `contains()` | | test_backend_obs.gd:767 | `"Scene did not start playing before the duration elapsed"` | prefix or `contains` | | test_backend_movie_maker.gd:468 | `"4 gb"` (via `to_lower()`) | `contains("4")` + `contains("gb", case-insensitive)` or a notice-constant | | test_time_machine_dock.gd:426,427,453,454,455,836 | Format labels `"PNG sequence (.png)"`, `"JPG sequence (.jpg)"`, `"AVI (.avi)"`, `"OGV (.ogv)"` | assert vs `GdTMOutputFormat.display_name(fmt)` / enum membership; labels are literals duplicated from output_format.gd — single source of truth exists | | test_time_machine_dock.gd:778,780 | `" — not available"` suffix and OBS tooltip sentence | `contains("not available")` + assert resolved target URI separately (already done at :802) | | test_debugger_plugin.gd:243 | Source snippet `capture == SCREENSHOT_CAPTURE_PREFIX and _screenshot_capture_active` | reformat-brittle source pin — keep behavioral twin :266, drop or `source.contains("_screenshot_capture_active")` |

**Good practice already in place (do not regress):** `test_output_format.gd` deliberately avoids pinning warning/user text; `test_plugin_button_state.gd` compares tooltips **constant-to-constant** (plugin's own constants), so the human strings are never frozen; dock shortcut test derives "Ctrl+Alt+R" from `get_as_text()` rather than hardcoding.

## 6. 3P — none found, and why (the defense of the mock architecture)

Every suite was checked for "proves third-party/engine behavior" or "proves the mock." **Zero tests in all 15 files.** The risk-concentrations were examined explicitly and cleared with evidence:

- **FakeOBSClient data in `test_backend_obs.gd`:** awaited signals (`recording_started`, `recording_stopped`) are **backend-emitted**, firing only after `_on_request_completed` correlates the reply with the pending id. Deleting `backend_obs.gd` wiring makes every one of these time out. The `REPLY_BUDGET`(2.0s) < 3.0s fallback timer design deliberately discriminates the reply path from the fallback path (`test_stop_never_kills_and_emits_once`). The OBS client state machine itself (handshake, identify, op-dispatch, correlation) is proven **only** in `test_obs_client.gd` with a passive fake peer — `test_backend_obs.gd`'s fake jumps straight to READY, so no double-coverage there.
- **Three auth vectors (`test_obs_client.gd:97,104,111`):** header claim independently re-verified during this audit (Python `hashlib.sha256`/`base64` — byte-for-byte match). The trio is three distinct input classes (baseline / special-chars+space / empty), each catching a different bug class (structure, encoding, degenerate). **Not** redundant of each other.
- **Controller forwarding tests** (`test_recorder_controller.gd:199,211,222,233`): the **only** place backend→controller signal forwarding is proven. The dock emits controller signals *directly* in its tests; the backends prove their own emission. The middle hop lives solely here — layering is genuine, not duplicated.
- **Config-store round-trips through real `ConfigFile`:** asserted values are written by the store's own mapping logic (keys, enum↔extension, section names), so the tests prove SUT serialization against engine mechanics — the boundary sits in the right place.
- **MovieMaker tier-2 test** avoids real ffmpeg via `auto_convert: false`; the ffmpeg suite fakes `probe`/`_os_execute_blocking`, so **no test requires the ffmpeg binary**.
- **`recording_smoke.gd`** is not a GUT test by design; it produces a live, visible AVI that cannot be asserted headlessly. Verdict: **KEEP-AS-MANUAL** — folding its visual checks into unit tests would be near-tautological.

## 7. REDUNDANT (20) — grouped and adjudicated

| Group | Twin(s) | Action | |---|---|---| | Base-class grab-bag | `test_recorder_backend.gd:8` (is-a-Node) + `:26` (noop) folded; `:34`/`:43` are **subclass** tooltip tests living in the base file | Keep only `:13` (abstract defaults) + `:21` (RESTART_SCENE base default); move `:34`→movie_maker, `:43`→screenshot; delete `:8`/`:26` | | ffmpeg token subsets | `test_ffmpeg_convert.gd:52-54,57-62` duplicate `test_output_format.gd:9-10,34-38` verbatim; `:177-189` re-tests `:112` under a misleading "async" name with an unasserted signal capture | Delete the three subsets; keep `:64` (`is_tier2_format`, unique truth table) | | MovieMaker emission twins | `test_backend_movie_maker.gd:101,231,296,401` duplicate `:34` (desc) / `:186` (stop sequence) / `:168`+`:217` (no-graceful, no-double) / `:366` (restore path, which doesn't branch on stop type) | Delete or merge into stronger twins | | OBS micro-helpers | `test_backend_obs.gd:75` (typed reader already covered by `:51`) and `:348` (installed-true already the `:361`+`:376` pair's setup) | Delete | | Dock double-checks | `test_time_machine_dock.gd:436` (`_update_backend_visibility` sets both rows unconditionally — cannot fail) and `:883` (OBS-costumed re-assert of `:584`'s generic "Error:" handler) | Delete | | Debugger toggle state machine | `test_debugger_plugin.gd:327` (`test_set_screenshot_capture_active_toggles_game_view_claim`) re-runs the same mirror toggle both directions that `:266` already covers | Delete | | Controller twin-pairs | `:153` (focus ordering claims an **unobservable** ordering — the mock records no shared sequence), `:246` (disconnect twin of `:274` which is the guarded half), `:326` (mode-routing twin of `:334` which covers both modes) | Delete `:153`; keep the `:274`/`:334` halves | | obs_client private-field pin | `:115` re-pins `_password` storage already proven end-to-end by `:213` | Delete | | Button-state mode-irrelevance | `test_plugin_button_state.gd:33` re-asserts `:21` with a different mode literal (branch ignores mode) | Delete | | Screenshot var-init | `test_backend_screenshot_capture.gd:316` (default-PNG already observable via `:308`) | Delete `:316`; fold `:190` (var initializer) into the no-op-`stop` test (WEAK, not R) | | Config read-back twin | `test_config_store.gd:118-134` (`test_project_local_store_default_profile`) re-exercises the same `_write_profile_to_section`/`_profile_from_section` mapping as `:63-88`; only the section constant differs | Delete or shrink to the section-specific asserts |

Remaining flag: two near-identical `MockBackend` inner classes drift independently (controller :6, dock :18). Not coverage waste — **fixture hygiene**; consider a shared test helper class.

## 8. WEAK (18) — highest-value strengthenings (top picks)

1. `test_config_store.gd:104` — the `[default]`-section exclusion branch in `get_all_scene_paths` (project_local_store.gd:99) never executes; save a default first.
1. `test_ffmpeg_convert.gd:102` — only 2 substring asserts on a ~12-arg argv; compare the whole `PackedStringArray` (and fix the `s.contains("14.5") or s.contains("14.5")` tautology at :88).
1. `test_debugger_plugin.gd:279/291` — assert the real guarded behavior (the mirror's `_capture` doesn't faithfully replicate the real one, so these prove almost nothing — see §9 item 1).
1. `test_backend_obs.gd:58` — assert the empty password actually reaches `connect_to_obs`.
1. `test_recorder_controller.gd:191` — `received.size()==1` passes with any wrong message; assert `== [["", "No backend selected"]]`.

## 9. Coverage gaps worth filling (highest value first)

1. **Debugger mirror↔source equivalence for `_capture`** (`test_debugger_plugin.gd`): the mirror accepts only exact `"get_screenshot"` and typed `int` fields, while the real `_capture` accepts the `game_view:` prefix, string-coerced ids, and `.jpg` paths — so real-plugin regressions in `_capture` pass silently today. Add an equivalence test table or drop the "faithful mirror" claim.
1. **StartRecord refusal / status-500** (`test_backend_obs.gd`): the `if result or code == OBSClient.STATUS_OUTPUT_RUNNING` branch in `_on_request_completed` — including "already recording counts as success" and the `"OBS could not start recording (code %d)"` error — is entirely untested (`respond_result` never mutated; cite by function — line numbers shift under the concurrent WIP edit).
1. **Wrong-request-id rejection** (`test_backend_obs.gd`): feed a bogus `request_completed` rid to prove `_on_request_completed` drops it (the `_in_flight_rq_id == -1` / mismatch guard).
1. **`_begin_recording` connect-failure branch** (`test_backend_obs.gd`): the fake is always READY unless `fail_message` routes to the probe path; the "Could not connect… check host/port/password" branch (backend :424) is dead in tests.
1. **Screenshot session-not-ready retry** (`test_backend_screenshot_capture.gd`): `_send_screenshot_request` returning `false` (backend :357-359) — the fake always returns `true`, so the retry-without-consuming-rq_id path (`_restart_no_reply_timer`; `_in_flight_rq_id` stays −1) is untested.
1. **Malformed inbound frames** (`test_obs_client.gd`): byte-packet and garbage-JSON skip branches (`was_string_packet` hardcoded true; `JSON.parse_string` failure).
1. **UTF-8 auth vector** (`test_obs_client.gd`): all three vectors are ASCII; a geodata+Python string-encoding divergence would evade all of them. Independent value (computed during this audit): `("pässwörd","sölt","chal-é")` → `vTWJ86bFMROIwIdYmOt8fQ8l8kSXmDCOjDPML8Egx3k=`.
1. **Focus-before-start ordering** (`test_recorder_controller.gd`): replace unobservable `:153` with a single shared log (FocusProbe + MockBackend cooperating).
1. **Restart cycle + MovieMaker restore/state reset** (`test_backend_movie_maker.gd`): start → record → natural-exit → start again (proves `_stopping`/`_pending_start` reset); `get_capture_mode()` override; stop-while-pending-start path.
1. **Dock record-time build_config with per-scene override** (dock :build_config path), and a test that **legitimizes or deletes** the dead "Converting" branch (`_on_recording_notice` — both arms identical at time_machine_dock.gd:1023-1028).
1. **Shortcut registration wiring** (`test_plugin_shortcut.gd`): nothing proves `EditorSettings.add_shortcut`/`palette.add_command` are actually called; wire-seam test.
1. **`_register`/`_exit_tree` of graceful_stop**: EngineDebugger registration is headless-impossible but the `source.contains` pattern already used in `test_debugger_plugin.gd:205` would pin it.

## 10. Flake and hygiene notes

- Only live-timer waits in the suite: `test_backend_movie_maker.gd:254,261,317,332,348` (`wait_seconds`, 0.2–0.25s). `:310` (duration auto-stop E2E) has the thinnest margin (~0.2s chained timers in a 0.25s wait). Acceptable but the least headless-robust test; if it ever flakes, drive the timers via seams like the rest of the suite does.
- `test_backend_obs.gd` file-move test uses real `user://` IO under a unique dir — safe single-process.
- Two orphans reported in the OBS pending-start tests — assert/purge them opportunistically.
- Reserved: every other suite is fully deterministic (seam-driven timers/clock, no real process, no real encode, no engine singletons — the debugger/plugin files never touch real `EditorInterface`/`EditorSettings`/`CommandPalette`).

## 11. Recommended actions, prioritized

1. **Fix the health signal (do this first, it's one sitting):**
   - `make test-godot`: remove `|| true` and make it fail when GUT reports failures, script errors, or a test-count shortfall. Harden: assert the expected file list ran (a parse-broken file is currently indistinguishable from an empty one).
   - Add a CI/terminal check for `SCRIPT ERROR`/`Failed to load` lines in GUT output, independent of exit code.
1. **Delete the 3 NOOPs and the 20 REDUNDANTs** (§4, §7) — pure waste removal, ~23 tests. Note: removing tests will drop the count below what PROGRESS notes claim; record the new count.
1. **De-pin the 10 PINBUG assertions** (§5) to `contains()`/enum/URI/constant-based forms; add the UTF-8 auth vector while touching `test_obs_client.gd`.
1. **Add the top-5 coverage gaps** (§9 items 1–5).
1. **Tighten the WEAK list** (§8) opportunistically.
1. Re-run after each step: `make test-godot` must list every file green and no SCRIPT ERROR lines; verify the real exit code directly (`godot --headless -s --path . addons/gut/gut_cmdln.gd -gexit; echo $?`).

## 12. Baseline state at audit close (for the PROGRESS ledger)

- HEAD suite (pre-WIP): 280 runnable tests / 800 asserts (prior validation runs).
- Working tree at audit close: **289/289 (incl. 7 new WIP OBS tests), 0 script errors, exit 0** — green but with the §1 masking caveat; the WIP is uncommitted and was being edited concurrently during this audit (the `"\0"`→`char(0)` fix landed mid-audit).
- Awaiting the author's decision: none of §4/§5/§7/§9 changes were made (read-only audit).
