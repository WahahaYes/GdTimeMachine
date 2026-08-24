extends SceneTree

## GdTimeMachine CLI — self-contained GDScript entry
##
## Location: addons/GdTimeMachine/cli/main.gd (only path that ships via Asset Library)
## Entry: consumers run `gdtime <command>` (wrapper at cli/gdtime) → godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args>
## Fallback: godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args> directly

const VERSION := "0.1.0"
const SCHEMA_PATH := "res://addons/GdTimeMachine/cli/schema/batch_manifest.schema.json"

const GdTMWorktree := preload("res://addons/GdTimeMachine/core/worktree.gd")
const GdTMGodotResolve := preload("res://addons/GdTimeMachine/core/godot_resolve.gd")
const GdTMBuildRunner := preload("res://addons/GdTimeMachine/core/build_runner.gd")
const GdTMMovieWriter := preload("res://addons/GdTimeMachine/core/movie_writer.gd")

var _exit_code := 0
var _args: PackedStringArray


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		var all := OS.get_cmdline_args()
		var sep := all.find("--")
		if sep != -1:
			args = all.slice(sep + 1)
	_args = args
	# Defer command handling to _initialize to ensure exit codes propagate
	if args.is_empty():
		_print_help()
		_exit_code = 1


func _initialize() -> void:
	if _exit_code != 0:
		quit(_exit_code)
		return
	if _args.is_empty():
		quit(_exit_code)
		return
	var cmd := String(_args[0])
	match cmd:
		"validate":
			_cmd_validate(_args)
		"doctor":
			_cmd_doctor(_args)
		"run":
			_cmd_run(_args)
		"list-commits":
			_cmd_list_commits(_args)
		"--help", "-h", "help":
			_print_help()
			quit(0)
		"--version", "-v", "version":
			print("gdtime %s" % VERSION)
			quit(0)
		_:
			printerr("Unknown command: %s" % cmd)
			_print_help()
			quit(1)


func _print_help() -> void:
	print(
		"""gdtime — GdTimeMachine CLI (self-contained at addons/GdTimeMachine/cli/main.gd)
Usage:
  gdtime validate <manifest.json> [--strict]
  gdtime doctor [--verbose] [--fix]
  gdtime run [--dry-run] [--resume LABEL] [--keep-failed] [--fail-fast] [--no-git] [--build-timeout SECS] <manifest.json>
  gdtime list-commits <manifest.json>
  gdtime --help | --version
Wrapper: addons/GdTimeMachine/cli/gdtime → godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args>
Fallback: godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args>"""
	)


func _cmd_validate(args: PackedStringArray) -> void:
	if args.size() < 2:
		printerr("validate: missing <manifest.json>")
		_print_help()
		quit(1)
		return
	var path := String(args[1])
	var strict := "--strict" in args
	var err := _validate_manifest(path, strict)
	if err.is_empty():
		print("✔ manifest valid: %s" % path)
		quit(0)
	else:
		printerr("✘ manifest invalid: %s" % path)
		printerr(err)
		quit(1)


func _validate_manifest(path: String, strict: bool) -> String:
	if not FileAccess.file_exists(path):
		return "File not found: %s" % path
	var content := FileAccess.get_file_as_string(path)
	if content.is_empty():
		return "Empty or unreadable file: %s" % path
	var json := JSON.new()
	var parse_err := json.parse(content)
	if parse_err != OK:
		return "Invalid JSON: %s" % json.get_error_message()
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return "Top-level must be an object"
	var dict: Dictionary = data
	if not dict.has("project_root"):
		return "Missing required field: project_root"
	if not dict.has("captures"):
		return "Missing required field: captures"
	var captures = dict["captures"]
	if typeof(captures) != TYPE_ARRAY:
		return "captures must be an array"
	var arr: Array = captures
	if arr.is_empty():
		return "captures must be non-empty"
	var labels := {}
	for i in range(arr.size()):
		var entry = arr[i]
		if typeof(entry) != TYPE_DICTIONARY:
			return "captures[%d] must be an object" % i
		var e: Dictionary = entry
		for field in ["commit", "scene", "label"]:
			if not e.has(field):
				return "captures[%d] missing required field: %s" % [i, field]
			if not (e[field] is String) or String(e[field]).is_empty():
				return "captures[%d].%s must be a non-empty string" % [i, field]
		var label := String(e["label"])
		if not label.is_valid_filename() and label != label.replace(" ", "_"):
			# Fallback regex check: filesystem-safe
			var regex := RegEx.new()
			regex.compile("^[a-zA-Z0-9_-]+$")
			if regex.search(label) == null:
				return "captures[%d].label '%s' must match ^[a-zA-Z0-9_-]+$" % [i, label]
		if labels.has(label):
			return "Duplicate label: '%s' (captures[%d])" % [label, i]
		labels[label] = true
		var scene := String(e["scene"])
		if not scene.begins_with("res://"):
			return "captures[%d].scene must start with res://, got '%s'" % [i, scene]
		var commit := String(e["commit"])
		var cregex := RegEx.new()
		cregex.compile("^[0-9a-fA-F]{4,40}$|^HEAD$")
		if cregex.search(commit) == null:
			return "captures[%d].commit '%s' must be hex 4-40 chars or HEAD" % [i, commit]
		if strict:
			for k in e.keys():
				if (
					k
					not in [
						"commit",
						"scene",
						"label",
						"duration",
						"fps",
						"fullscreen",
						"godot_version_hint",
						"output_path",
						"build_command"
					]
				):
					return "captures[%d] unknown key '%s' (strict mode)" % [i, k]
	if strict:
		for k in dict.keys():
			if (
				k
				not in [
					"project_root", "godot_path", "build_command", "output_dir", "obs", "captures"
				]
			):
				return "Unknown top-level key '%s' (strict mode)" % k
	return ""


func _cmd_doctor(args: PackedStringArray) -> void:
	var verbose := "--verbose" in args
	print("gdtime doctor — healthcheck (stub)")
	print("  ○ git: probe not yet implemented")
	print("  ○ godot: probe not yet implemented")
	print("  ○ ffmpeg: probe not yet implemented")
	print("  ○ OBS: probe not yet implemented")
	print("  ○ build hook: probe not yet implemented")
	print("  ○ output_dir: probe not yet implemented")
	if verbose:
		print("  --verbose: per-check details")
	print("  (stub — exits 0)")
	quit(0)


func _extract_manifest_path(args: PackedStringArray) -> String:
	var manifest_path := ""
	for i in range(1, args.size()):
		var a := String(args[i])
		if a.begins_with("-"):
			continue
		if a == "run":
			continue
		manifest_path = a
	# If multiple non-flags, last one wins (consistent with original stub)
	if manifest_path.is_empty():
		# Try last non-flag scan (original behavior)
		for a in args:
			var s := String(a)
			if not s.begins_with("-") and s != "run":
				manifest_path = s
	return manifest_path


func _cmd_run(args: PackedStringArray) -> void:
	var keep_worktrees := "--keep-worktrees" in args
	var keep_failed := "--keep-failed" in args
	var force := "--force" in args
	var dry_run := "--dry-run" in args
	var no_git := "--no-git" in args

	var manifest_path := _extract_manifest_path(args)
	if manifest_path.is_empty():
		printerr("run: missing <manifest.json>")
		_print_help()
		quit(1)
		return

	var strict := "--strict" in args
	var validation_err := _validate_manifest(manifest_path, strict)
	if not validation_err.is_empty():
		printerr("✘ manifest invalid: %s" % manifest_path)
		printerr(validation_err)
		quit(1)
		return

	var content := FileAccess.get_file_as_string(manifest_path)
	var json := JSON.new()
	if json.parse(content) != OK:
		printerr("✘ manifest invalid: %s" % manifest_path)
		printerr("Invalid JSON: %s" % json.get_error_message())
		quit(1)
		return
	var dict: Dictionary = json.data if typeof(json.data) == TYPE_DICTIONARY else {}
	var project_root := str(dict.get("project_root", ""))
	if project_root.is_empty():
		project_root = ProjectSettings.globalize_path("res://")
	# Normalize project_root: expand res:// if ever passed (unlikely per schema)
	if project_root.begins_with("res://"):
		project_root = ProjectSettings.globalize_path(project_root)
	var captures_var = dict.get("captures", [])
	var arr: Array = captures_var if typeof(captures_var) == TYPE_ARRAY else []

	# --- --no-git / git-absent fallback handling ---
	var has_git := GdTMWorktree.has_git()
	if not has_git:
		if no_git:
			print("git not found — --no-git mode: operating on current checkout (no worktree)")
			print("history mode requires git + worktrees; only single-commit HEAD mode available")
			var all_head := true
			for entry in arr:
				if typeof(entry) == TYPE_DICTIONARY:
					if str(entry.get("commit", "")) != "HEAD":
						all_head = false
						break
				else:
					all_head = false
					break
			if not all_head:
				printerr(
					"git not found — --no-git allows only commit == HEAD; manifest contains other commits"
				)
				printerr("install git or use history mode")
				quit(1)
				return
			for entry in arr:
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var lbl := str(entry.get("label", ""))
				var cm := str(entry.get("commit", ""))
				if dry_run:
					print(
						(
							"[dry-run] would capture %s for %s on current checkout (no worktree, --no-git)"
							% [lbl, cm]
						)
					)
				else:
					print(
						(
							"capturing %s for %s on current checkout (no worktree, --no-git)"
							% [lbl, cm]
						)
					)
					print("✔ %s (HEAD) — no worktree (--no-git)" % lbl)
			quit(0)
			return
		else:
			printerr(
				"git not found — install git or use --no-git for current-commit only; history capture requires git + worktrees"
			)
			quit(1)
			return

	if no_git:
		# git is present but user forced --no-git
		print("--no-git: operating on current checkout (no worktree) even though git is available")
		print(
			"history mode requires git + worktrees; only single-commit HEAD mode available with --no-git"
		)
		var all_head2 := true
		for entry in arr:
			if typeof(entry) == TYPE_DICTIONARY:
				if str(entry.get("commit", "")) != "HEAD":
					all_head2 = false
					break
			else:
				all_head2 = false
				break
		if not all_head2:
			printerr("--no-git allows only commit == HEAD; manifest contains other commits")
			quit(1)
			return
		for entry in arr:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var lbl2 := str(entry.get("label", ""))
			var cm2 := str(entry.get("commit", ""))
			if dry_run:
				print(
					(
						"[dry-run] would capture %s for %s on current checkout (no worktree, --no-git)"
						% [lbl2, cm2]
					)
				)
			else:
				print(
					"capturing %s for %s on current checkout (no worktree, --no-git)" % [lbl2, cm2]
				)
				print("✔ %s (HEAD) — no worktree (--no-git)" % lbl2)
		quit(0)
		return

	# git present and not --no-git: check worktree support
	if not GdTMWorktree.is_worktree_supported():
		var ver := GdTMWorktree.get_git_version()
		printerr("git worktrees not supported — requires git >= 2.13 (found %s)" % ver)
		printerr("install newer git or use --no-git for HEAD-only")
		quit(1)
		return

	if dry_run:
		print("dry-run preview for %s (project_root=%s):" % [manifest_path, project_root])
		var top_godot_path := str(dict.get("godot_path", "godot"))
		var top_build := str(dict.get("build_command", ""))
		var top_output_dir := str(dict.get("output_dir", "res://media/captures/history"))
		for entry in arr:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var lbl := str(entry.get("label", ""))
			var cm := str(entry.get("commit", ""))
			var sc := str(entry.get("scene", ""))
			var hint := str(entry.get("godot_version_hint", ""))
			var bcmd: String = (
				str(entry.get("build_command", top_build))
				if entry.has("build_command")
				else top_build
			)
			var dur := float(entry.get("duration", 30))
			var fps_v := int(entry.get("fps", 60))
			var outp := str(entry.get("output_path", ""))
			if outp.is_empty():
				outp = top_output_dir.path_join(lbl)
			var backend_dry := str(entry.get("backend", "OBS Studio"))
			print("[dry-run] would create worktree .worktrees/%s for %s" % [lbl, cm])
			if not sc.is_empty():
				print("  scene: %s" % sc)
			var gpath := top_godot_path
			if not hint.is_empty():
				print("  godot hint: %s (would resolve via godotenv, fallback %s)" % [hint, gpath])
			else:
				print("  godot: %s" % gpath)
			if bcmd.strip_edges().is_empty():
				print("  build: none (GDScript-only)")
			else:
				print("  build: %s" % bcmd)
			print(
				(
					"  record: %s -> %s (duration %s, fps %d, backend %s)"
					% [sc, outp, str(dur), fps_v, backend_dry]
				)
			)
		print("dry-run complete — no worktrees created")
		quit(0)
		return

	var top_godot_path_r := str(dict.get("godot_path", "godot"))
	var top_build_r := str(dict.get("build_command", ""))
	var created: Array = []
	var failed_labels: Array = []
	for entry in arr:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var lbl := str(entry.get("label", ""))
		var cm := str(entry.get("commit", ""))
		var hint_r := str(entry.get("godot_version_hint", ""))
		var bcmd_r: String = (
			str(entry.get("build_command", top_build_r))
			if entry.has("build_command")
			else top_build_r
		)
		print("creating worktree for %s (%s)..." % [lbl, cm])
		var wt_path := GdTMWorktree.add_worktree(lbl, cm, project_root, force)
		if wt_path.is_empty():
			printerr("✘ failed to create worktree .worktrees/%s for %s" % [lbl, cm])
			failed_labels.append(lbl)
			continue
		var godot_bin := GdTMGodotResolve.resolve_godot_binary(wt_path, top_godot_path_r, hint_r)
		print("  godot: %s" % godot_bin)
		if not GdTMGodotResolve.regenerate_cache(wt_path, godot_bin):
			printerr("✘ cache regeneration failed for %s" % lbl)
			failed_labels.append(lbl)
			continue
		if not GdTMBuildRunner.run_build(wt_path, bcmd_r, lbl, cm):
			printerr("✘ build failed for %s" % lbl)
			failed_labels.append(lbl)
			continue
		var top_output_dir_r := str(dict.get("output_dir", "res://media/captures/history"))
		var scene_r := str(entry.get("scene", ""))
		var fps_r := int(entry.get("fps", 60))
		var dur_r := float(entry.get("duration", 30))
		var out_r := str(entry.get("output_path", ""))
		if out_r.is_empty():
			out_r = top_output_dir_r.path_join(lbl)
		# Globalize output so headless movie writes to main repo, not worktree's res://
		if out_r.begins_with("res://"):
			out_r = ProjectSettings.globalize_path(out_r)
		elif not out_r.begins_with("/"):
			out_r = project_root.path_join(out_r)
		var backend_r := str(entry.get("backend", "OBS Studio"))
		if GdTMMovieWriter.record(wt_path, scene_r, out_r, fps_r, dur_r, godot_bin) != 0:
			printerr("✘ record failed for %s" % lbl)
			failed_labels.append(lbl)
			continue
		created.append(lbl)
		print("✔ %s done (worktree + build + record)" % lbl)

	# --- cleanup: atexit/SIGINT trap equivalent — ensure no orphans ---
	if keep_worktrees:
		print("keeping all worktrees per --keep-worktrees (%d created)" % created.size())
		for lbl in created:
			print("  kept .worktrees/%s" % str(lbl))
		if not failed_labels.is_empty() and keep_failed:
			for lbl in failed_labels:
				print("  kept failed .worktrees/%s per --keep-failed" % str(lbl))
	else:
		GdTMWorktree.cleanup_worktrees(project_root, keep_failed, failed_labels)

	# --- exit codes: 0 all ok, 1 fatal, 2 partial ---
	if failed_labels.is_empty():
		print("run complete — %d worktree(s) processed" % created.size())
		quit(0)
		return
	else:
		if keep_failed:
			printerr(
				(
					"run partial — %d failed, %d succeeded (kept failed per --keep-failed)"
					% [failed_labels.size(), created.size()]
				)
			)
			quit(2)
			return
		else:
			printerr(
				"run failed — %d failed, %d succeeded" % [failed_labels.size(), created.size()]
			)
			quit(1)
			return


func _cmd_list_commits(args: PackedStringArray) -> void:
	if args.size() < 2:
		printerr("list-commits: missing <manifest.json>")
		_print_help()
		quit(1)
		return
	var path := String(args[1])
	var content := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var json := JSON.new()
	if json.parse(content) != OK:
		printerr("Invalid manifest: %s" % path)
		quit(1)
		return
	var dict: Dictionary = json.data if typeof(json.data) == TYPE_DICTIONARY else {}
	var captures = dict.get("captures", [])
	if typeof(captures) != TYPE_ARRAY:
		printerr("No captures in manifest")
		quit(1)
		return
	for entry in captures:
		if typeof(entry) == TYPE_DICTIONARY:
			print("%s %s" % [entry.get("commit", "?"), entry.get("label", "?")])
	quit(0)
