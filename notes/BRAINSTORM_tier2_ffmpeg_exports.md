# Brainstorm — Tier-2 FFmpeg exports: MP4 (and beyond) for every backend

Status: research verified + design (2026-08-01); nothing implemented. This is the output-format counterpart of `BRAINSTORM_in_place_recording.md`, and it connects to `ENHANCEMENTS_engine_native_recording.md` (#4a ffmpeg hook, #5 format dropdown) and `IMPLEMENTATION_PLAN.md` (Phase 5 transcode). Engine facts are cross-checked against the official Godot 4.7 docs and 4.7-stable source on 2026-08-01.

## The ask

Can we onboard **MP4** as an output type — specifically, can `BackendMovieMaker` write it? Short answer: **not natively.** Godot 4.7's Movie Maker ships exactly three writers (AVI / OGV / PNG) and has no MP4 writer; the engine will refuse a `.mp4` `movie_file`. MP4 has to come from **ffmpeg**, run after the engine's writers finish. This note turns that limitation into the output architecture:

> **Tier 1** = the formats a backend writes natively (zero extra software). **Tier 2** = a backend-agnostic ffmpeg conversion hook that turns any tier-1 artifact into any ffmpeg-compatible target (MP4/H.264, WebM/VP9, GIF, …) — for **any** backend.

## Verified research (2026-08-01)

1. **Format = file extension.** Godot's Movie Maker picks its writer by extension: `MovieWriter::find_writer_for_file()` iterates registered writers and calls `_handles_file(path)` — MJPEG→`.avi`, Theora→`.ogv`, PNGWAV→`.png` (`servers/movie_writer/movie_writer.cpp:47-59`, `modules/jpg/movie_writer_mjpeg.cpp:43-45`). The engine drives whatever writer was picked at startup (`main.cpp:3800`) from the `--write-movie <path>` flag (also the basis of constraint 5 in `BRAINSTORM_in_place_recording.md`).

1. **No MP4 writer in the engine, and not coming.** The 4.7 docs: "Godot has 3 built-in MovieWriter, and more can be implemented by extensions." H.264/H.265 are excluded from core: "H.264 and H.265 cannot be supported in core Godot, as they are both encumbered by software patents" (Playing videos docs). All MP4-related proposals are still open, none merged: [#7062 FFmpeg conversion wrapper](https://github.com/godotengine/godot-proposals/issues/7062), [#11813 hardware encode in Movie Maker](https://github.com/godotengine/godot-proposals/issues/11813), [#14915 OpenH264 discussion](https://github.com/godotengine/godot-proposals/discussions/14915).

1. **godot-mp4 is dead.** `Jikky1985/godot-mp4` — the one project that added a native MP4 writer to Movie Maker — is **deleted** (HTTP 404 on the repo *and* the user account; no Wayback snapshots, no forks or mirrors findable on GitHub or Sourcegraph). It was also GPL-tainted: statically linking an H.264-capable FFmpeg makes the whole project GPL (libx264 is GPL), which the author's own r/godot post confirmed ("that project became GPL"). A permissive addon cannot bundle that.

1. **The maintained path is ffmpeg post-conversion.** Upstream's own answer is the docs' "Converting OGV/AVI video to MP4" section (`ffmpeg -i input.avi -crf 15 output.mp4`). The community plugin **Movie Maker Plus** (nooitaf, MIT, asset #4997) does exactly this — `OS.create_process(ffmpeg, …)` after Movie Maker finishes — and is tested through 4.6.2+.

→ A custom MP4 `MovieWriter` GDExtension *could* register a native writer (`add_writer()` at engine init; writer selection is purely extension-based, so `movie_file=…mp4` would then "just work"). But nothing maintained exists to stand on, and building one drags in H.264 licensing. **Not worth it for an addon.** ffmpeg-as-a-subprocess stays arms-length: the addon never links FFmpeg, so the addon's license is untouched.

## The model

**Tier 1 — native formats per backend** (what the backend writes with no extra deps):

| Backend | Tier 1 (native) | |---|---| | `BackendMovieMaker` | AVI, OGV, PNG — Godot's 3 writers, chosen by `movie_file` extension | | `BackendScreenshotCapture` (planned, ENHANCEMENTS #4) | PNG frames + manifest | | `BackendOBS` (planned) | whatever OBS is configured to write (MKV/FLV/…) |

**Tier 2 — the ffmpeg conversion hook** (backend-agnostic): after `recording_stopped`, when the selected output format is **not** in the backend's tier-1 set, convert the tier-1 artifact with ffmpeg (probe → convert on a `Thread` → emit `recording_converted`). This is the whole ffmpeg format space: MP4/H.264, WebM/VP9, GIF, ProRes, … — no per-backend codec mapping needed, one format→codec table in the shared hook.

Rule: a backend never needs to know about formats it can't write. It declares its tier-1 set; the hook covers everything else.

## Where this slots into existing plans

1. **`ENHANCEMENTS_engine_native_recording.md` #4a** — the designed (not built) ffmpeg auto-convert hook is the tier-2 mechanism, currently scoped to the screenshot backend. Generalize: a shared `backend/ffmpeg_convert.gd` sitting at the "any backend" layer (post-`recording_stopped`), keeping the Thread/`OS.execute`/`recording_converted` design and the graceful "ffmpeg not found → keep tier-1 artifact" fallback. #4a's "Future: MP4/H.264, WebM/VP9 as dropdown additions" becomes the tier-2 target list.
1. **#5 format dropdown** — already designed to be "backend-agnostic"; the tier-2 model makes it concrete: a backend's format options = **tier 1 ∪ tier 2 targets**. Add a per-backend declaration (e.g. `get_native_formats() -> Array[GdTMOutputFormat.Format]`) so the dropdown can mark native vs converted entries.
1. **`IMPLEMENTATION_PLAN.md` Phase 5 `_transcode_to_mp4`** — absorbed. It is exactly the Movie Maker + tier-2 case (record AVI/OGV → convert to MP4, `-c:v libx264 -crf 18`). The shared hook supersedes the standalone sketch.
1. **`ARCHITECTURE.md` open question "user wants mp4? Transcode after?"** — answered: yes, transcode after, via the tier-2 hook.

## Design sketch (generalized from #4a)

- `backend/ffmpeg_convert.gd`: probe (`ffmpeg -version`; optional `ffmpeg_path` setting overrides PATH) + command builder (format→codec/container table, quality from `editor/movie_writer/video_quality`) + async runner (`Thread` with blocking `OS.execute`, `call_deferred` back to main thread). Exit 0 → `recording_converted` + optional cleanup of the tier-1 artifact; nonzero → keep tier-1 artifact + `recording_error` with stderr tail; ffmpeg missing → graceful fallback, keep tier-1 artifact, surface "ffmpeg not found".
- New signal `recording_converted(backend_name, clip_path)` on `RecorderBackend` + `RecorderController` forwarder (already specced in #4a).
- Config: convert-to-selected-format toggle + optional `ffmpeg_path`; dock shows "Converting…" between `recording_stopped` and `recording_converted`.
- Source artifacts: Movie Maker → the recorded AVI/OGV (or PNG-seq dir); Screenshot → frames dir + manifest (measured fps drives `-framerate`, from #4a).
- Thread lifecycle: `wait_to_finish()` before free / `_exit_tree` (from #4a).

## Open questions / risks

- **Audio mapping**: AVI (PCM), OGV (Vorbis), PNG-seq+WAV all carry audio; the ffmpeg command must map each backend's stream. The screenshot backend has no audio yet.
- **Tier-1 artifact retention**: delete-after-convert default vs keep-on-failure-always.
- **4 GB AVI cap** (BRAINSTORM constraint 8) is a tier-2 *driver* — MP4 has no such cap. The dock should nudge long/high-res recordings toward a converted target.
- **Wording**: "tier 1 / tier 2" is internal; user-facing = "Native" / "Converted (ffmpeg)".

## Cut line / decision

Adopt the tier-1/tier-2 model as the output architecture. MP4 ships as a tier-2 target once the #4a hook lands (or, for Movie Maker only, standalone per Phase 5). Do **not** pursue a custom MP4 MovieWriter GDExtension — dead upstream, licensing trouble, nothing maintained.
