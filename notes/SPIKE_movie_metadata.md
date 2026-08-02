# Spike — per-scene `movie_file` root metadata — 2026-08-01

Question: can we avoid `ProjectSettings.save()` pollution by setting `movie_file` metadata on the scene root, instead of writing the global `editor/movie_writer/movie_file` setting?

## Engine source (Godot 4.7-stable)

Only reader of `movie_file` metadata in entire engine:

`editor/run/editor_run_bar.cpp:280-364` in `_run_scene()`:

```cpp
String write_movie_file;
if (is_movie_maker_enabled()) {
    if (current_mode == RUN_CURRENT) {                          // line 282
        Node *scene_root = nullptr;
        if (p_scene_path.is_empty())
            scene_root = get_tree()->get_edited_scene_root();   // in-memory edited scene
        else {
            int idx = EditorNode::get_editor_data().get_edited_scene_from_path(p_scene_path);
            if (idx >= 0) scene_root = EditorNode::get_editor_data().get_edited_scene_root(idx);
        }
        if (scene_root && scene_root->has_meta("movie_file"))   // line 293
            write_movie_file = scene_root->get_meta("movie_file");
    }
    if (write_movie_file.is_empty())
        write_movie_file = GLOBAL_GET("editor/movie_writer/movie_file"); // fallback
}
// then editor_run.run(run_filename, write_movie_file, args) adds --write-movie <path>
```

Flow: editor resolves path → `EditorRun::run()` appends `--write-movie <path>` → child `main.cpp` → `Engine.set_write_movie_path()` → MovieWriter uses it.

Game process never reads metadata.

## Answers

- Metadata key is literally `"movie_file"` (not `movie_writer/movie_file`, not `movie_path`). Global setting is `editor/movie_writer/movie_file` — distinct. Wrong key = silent ignore (issue godot#66148 was `movie_path` typo).

- Metadata wins over global — but **only in RUN_CURRENT** (`play_current_scene`, F6, currently open edited scene root in memory).

- `play_custom_scene(path)` sets `RUN_CUSTOM`, which skips the metadata block entirely. Always uses global. Our `BackendMovieMaker` uses `play_custom_scene()`.

- "Survives instancing"? N/A — editor resolves before launch, passes CLI arg.

## Go/No-Go for Op4 #6

GO for metadata **only if** launch via `play_current_scene()` and target is the currently open edited scene. That restricts recording to the open scene and mutates in-memory scene.

**NO-GO for GdTimeMachine's arbitrary-scene flow.** The dock can record any `scene_path`, not just the open one. `play_custom_scene()` path cannot use metadata.

## Decision for Op 4

Use **restore-on-stop** instead:

- On `start()`: capture previous `editor/movie_writer/movie_file` and `editor/movie_writer/fps`.
- Write new values (no `ProjectSettings.save()` needed — engine reads via GLOBAL_GET, but current code does save; new code should avoid save and just set).
- On `_finalize_stopped()` and on error paths: restore captured values.

This covers `movie_file` and `fps` (metadata would only cover `movie_file` anyway). Removes `project.godot` pollution.

Docs confirming:

- `doc/classes/MovieWriter.xml:13`
- `tutorials/animation/creating_movies.rst:90-95` — "only when main scene is set to the scene in question, or when running the scene directly by pressing F6"
- PR godot#62122
- `editor_run_bar.cpp:294` comment: "Quick workaround if you want to have multiple scenes that write to multiple movies."

## Open item left

Verify that not calling `ProjectSettings.save()` is sufficient — i.e. child process sees the new value via GLOBAL_GET already set in editor, without persisting to disk. Expected yes (setting is in-memory until save), but manual windowed check recommended same as Op 2 graceful-stop spike.
