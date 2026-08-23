extends SceneTree

## GdTimeMachine CLI — self-contained GDScript entry
##
## Location: addons/GdTimeMachine/cli/main.gd (only path that ships via Asset Library)
## Entry: consumers run `gdtime <command>` (wrapper at cli/gdtime) → godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args>
## Fallback: godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args> directly

const VERSION := "0.1.0"
const SCHEMA_PATH := "res://addons/GdTimeMachine/cli/schema/batch_manifest.schema.json"

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


func _has_git() -> bool:
	var out: Array = []
	var code := OS.execute("git", PackedStringArray(["--version"]), out, true)
	return code == 0


func _get_git_version() -> String:
	var out: Array = []
	var code := OS.execute("git", PackedStringArray(["--version"]), out, true)
	if code != 0 or out.is_empty():
		return "unknown"
	var raw := str(out[0]).strip_edges()
	if raw.contains("\n"):
		raw = raw.split("\n")[0].strip_edges()
	return raw


func _git_worktree_supported() -> bool:
	if not _has_git():
		return false
	var out: Array = []
	var code := OS.execute("git", PackedStringArray(["--version"]), out, true)
	if code != 0 or out.is_empty():
		return false
	var ver_str := str(out[0])
	if ver_str.contains("\n"):
		ver_str = ver_str.split("\n")[0]
	var regex := RegEx.new()
	regex.compile("(\\d+)\\.(\\d+)")
	var m := regex.search(ver_str)
	if m == null:
		return false
	var major := int(m.get_string(1))
	var minor := int(m.get_string(2))
	if major > 2:
		return true
	if major == 2 and minor >= 13:
		return true
	return false


func _add_worktree(
	label: String, commit: String, project_root: String, force: bool = false
) -> String:
	var wt_rel := ".worktrees/%s" % label
	var wt_abs := project_root.path_join(".worktrees").path_join(label)
	# Refuse collision unless --force
	if DirAccess.dir_exists_absolute(wt_abs) or FileAccess.file_exists(wt_abs):
		if not force:
			printerr("worktree collision: %s already exists (use --force to overwrite)" % wt_rel)
			return ""
		else:
			print("worktree collision: %s exists — --force removing existing" % wt_rel)
			_remove_worktree(label, project_root)
	# Verify commit resolves (git cat-file -e <commit>)
	# HEAD is always resolvable if git repo has commits; skip cat-file for HEAD? Still check.
	if commit != "HEAD":
		var out_cat: Array = []
		var cat_code := OS.execute(
			"git", PackedStringArray(["-C", project_root, "cat-file", "-e", commit]), out_cat, true
		)
		if cat_code != 0:
			printerr("commit does not resolve: %s (git cat-file -e failed)" % commit)
			if not out_cat.is_empty():
				printerr(str(out_cat[0]))
			return ""
	else:
		# For HEAD, verify repo has HEAD
		var out_head: Array = []
		var head_code := OS.execute(
			"git",
			PackedStringArray(["-C", project_root, "rev-parse", "--verify", "HEAD"]),
			out_head,
			true
		)
		if head_code != 0:
			printerr("commit HEAD does not resolve (no HEAD in %s)" % project_root)
			return ""
	# Ensure .worktrees parent exists (git will create but ensure dir)
	var wt_parent := project_root.path_join(".worktrees")
	if not DirAccess.dir_exists_absolute(wt_parent):
		var mk_err := DirAccess.make_dir_absolute(wt_parent)
		if mk_err != OK:
			# Not fatal — git will create, but warn
			pass
	var out: Array = []
	var args := PackedStringArray(
		["-C", project_root, "worktree", "add", "--detach", wt_rel, commit]
	)
	var code := OS.execute("git", args, out, true)
	if code != 0:
		var msg := (
			"\n".join(out) if not out.is_empty() else "git worktree add failed (exit %d)" % code
		)
		printerr("failed to create worktree %s for %s: %s" % [wt_rel, commit, msg])
		return ""
	print("created worktree %s for %s at %s" % [wt_rel, commit, wt_abs])
	return wt_abs


func _remove_worktree(label: String, project_root: String) -> bool:
	var wt_rel := ".worktrees/%s" % label
	var out: Array = []
	var code := OS.execute(
		"git",
		PackedStringArray(["-C", project_root, "worktree", "remove", "--force", wt_rel]),
		out,
		true
	)
	if code != 0:
		# May already be gone or not registered; warn but continue to prune
		var msg := "\n".join(out) if not out.is_empty() else "exit %d" % code
		# Only warn if directory still exists
		var wt_abs_check := project_root.path_join(".worktrees").path_join(label)
		if DirAccess.dir_exists_absolute(wt_abs_check):
			printerr("warning: git worktree remove failed for %s: %s" % [wt_rel, msg])
	# Always prune
	var out2: Array = []
	OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "prune"]), out2, true)
	var wt_abs := project_root.path_join(".worktrees").path_join(label)
	if DirAccess.dir_exists_absolute(wt_abs):
		# Fallback: try recursive delete (orphan)
		var da := DirAccess.open(wt_abs)
		if da == null:
			# Try OS-level removal via shell
			var out_rm: Array = []
			OS.execute("rm", PackedStringArray(["-rf", wt_abs]), out_rm, true)
		else:
			# Attempt to remove via DirAccess recursion
			_delete_dir_recursive(wt_abs)
		if DirAccess.dir_exists_absolute(wt_abs):
			printerr("warning: worktree directory still exists: %s" % wt_abs)
			return false
	print("removed worktree %s" % wt_rel)
	return true


func _delete_dir_recursive(dir_path: String) -> void:
	var abs_dir := dir_path
	# Use DirAccess to delete recursively
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	var da := DirAccess.open(abs_dir)
	if da == null:
		return
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var child := abs_dir.path_join(fname)
			if DirAccess.dir_exists_absolute(child):
				_delete_dir_recursive(child)
			else:
				DirAccess.remove_absolute(child)
		fname = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(abs_dir)


func _list_worktrees(project_root: String) -> Array:
	var out: Array = []
	var code := OS.execute(
		"git", PackedStringArray(["-C", project_root, "worktree", "list", "--porcelain"]), out, true
	)
	if code != 0:
		return []
	var result: Array = []
	for line in out:
		var s := str(line)
		if s.contains("\n"):
			for sub in s.split("\n"):
				var t := sub.strip_edges()
				if t.begins_with("worktree "):
					result.append(t.substr(9).strip_edges())
		else:
			var t := s.strip_edges()
			if t.begins_with("worktree "):
				result.append(t.substr(9).strip_edges())
	if result.is_empty() and not out.is_empty():
		# Fallback: try non-porcelain
		var out2: Array = []
		OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "list"]), out2, true)
		for line in out2:
			var ss := str(line)
			if ss.contains("\n"):
				for sub in ss.split("\n"):
					var tt := sub.strip_edges()
					if not tt.is_empty():
						result.append(tt)
			else:
				var tt := ss.strip_edges()
				if not tt.is_empty():
					result.append(tt)
	return result


func _cleanup_worktrees(project_root: String, keep_failed: bool, failed_labels: Array) -> void:
	var wt_dir := project_root.path_join(".worktrees")
	if not DirAccess.dir_exists_absolute(wt_dir):
		# Also prune git metadata
		var out: Array = []
		OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "prune"]), out, true)
		return
	var da := DirAccess.open(wt_dir)
	if da == null:
		var out: Array = []
		OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "prune"]), out, true)
		return
	var labels_to_clean: Array = []
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var is_keep := keep_failed and failed_labels.has(fname)
			if is_keep:
				print("keeping failed worktree .worktrees/%s per --keep-failed" % fname)
			else:
				labels_to_clean.append(fname)
		fname = da.get_next()
	da.list_dir_end()
	for lbl in labels_to_clean:
		print("cleaning worktree .worktrees/%s" % str(lbl))
		_remove_worktree(str(lbl), project_root)
	# Final prune ensures git metadata has no orphans
	var out_final: Array = []
	OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "prune"]), out_final, true)


func _resolve_godot_binary(worktree_path: String, godot_path: String, hint: String) -> String:
	var bin := ""
	# Try godotenv in worktree
	var out_env: Array = []
	var env_code := OS.execute(
		"godotenv", PackedStringArray(["godot", "env", "get"]), out_env, true
	)
	# godotenv expects to run in project dir; try with -C worktree via shell
	if env_code != 0 or out_env.is_empty():
		var out_sh: Array = []
		OS.execute(
			"sh",
			PackedStringArray(
				["-c", "cd '%s' && godotenv godot env get 2>/dev/null" % worktree_path]
			),
			out_sh,
			true
		)
		if not out_sh.is_empty():
			var cand := str(out_sh[0]).strip_edges()
			if not cand.is_empty() and FileAccess.file_exists(cand):
				bin = cand
	if bin.is_empty() and not out_env.is_empty():
		var cand2 := str(out_env[0]).strip_edges()
		if not cand2.is_empty():
			bin = cand2
	if not bin.is_empty() and FileAccess.file_exists(bin):
		return bin
	# Fallback to manifest godot_path
	if not godot_path.is_empty() and godot_path != "godot":
		if FileAccess.file_exists(godot_path):
			return godot_path
		var out_which: Array = []
		OS.execute("which", PackedStringArray([godot_path]), out_which, true)
		if not out_which.is_empty() and FileAccess.file_exists(str(out_which[0]).strip_edges()):
			return str(out_which[0]).strip_edges()
		return godot_path
	# Final fallback: godot on PATH or GODOT_BIN env
	var godot_bin_env := OS.get_environment("GODOT_BIN")
	if not godot_bin_env.is_empty():
		return godot_bin_env
	var out_which2: Array = []
	OS.execute("which", PackedStringArray(["godot"]), out_which2, true)
	if not out_which2.is_empty():
		return str(out_which2[0]).strip_edges()
	return "godot"


func _regenerate_godot_cache(worktree_path: String, godot_bin: String) -> bool:
	var cache_dir := worktree_path.path_join(".godot")
	# Remove existing cache
	if DirAccess.dir_exists_absolute(cache_dir):
		_delete_dir_recursive(cache_dir)
	var out: Array = []
	var args := PackedStringArray(["--editor", "--headless", "--quit"])
	# Use -C worktree via shell to ensure correct project path
	var cmd := "%s --path '%s' --editor --headless --quit 2>&1" % [godot_bin, worktree_path]
	var code := OS.execute("sh", PackedStringArray(["-c", cmd]), out, true)
	if code != 0:
		var msg := "\n".join(out) if not out.is_empty() else "exit %d" % code
		printerr("warning: Godot cache regeneration failed in %s: %s" % [worktree_path, msg])
		return false
	return true


func _run_build_command(
	worktree_path: String, build_command: String, label: String, commit: String
) -> bool:
	if build_command.strip_edges().is_empty():
		return true
	print("running build for %s: %s" % [label, build_command])
	OS.set_environment("GDTM_LABEL", label)
	OS.set_environment("GDTM_COMMIT", commit)
	OS.set_environment("GDTM_SCENE", "")
	var log_path := "/tmp/gdtm_build_%s.log" % label
	var script_path := "/tmp/gdtm_build_%s.sh" % label
	var script_content := (
		"#!/usr/bin/env sh\nexec > '%s' 2>&1\ncd '%s'\n%s\n"
		% [log_path, worktree_path, build_command]
	)
	var fa := FileAccess.open(script_path, FileAccess.WRITE)
	if fa == null:
		printerr("failed to create build script for %s" % label)
		return false
	fa.store_string(script_content)
	fa.close()
	var code: int = 0
	if OS.get_name() == "Windows":
		code = OS.execute("cmd", PackedStringArray(["/c", 'call "%s"' % script_path]), [], false)
	else:
		code = OS.execute("sh", PackedStringArray([script_path]), [], false)
	if FileAccess.file_exists(log_path):
		var content := FileAccess.get_file_as_string(log_path)
		for line in content.split("\n"):
			if not str(line).strip_edges().is_empty():
				print(line)
		DirAccess.remove_absolute(log_path)
	DirAccess.remove_absolute(script_path)
	if code != 0:
		printerr("build failed for %s (exit %d): %s" % [label, code, build_command])
		return false
	print("build ok for %s" % label)
	return true
	DirAccess.remove_absolute(script_path)
	if code != 0:
		printerr("build failed for %s (exit %d): %s" % [label, code, build_command])
		return false
	print("build ok for %s" % label)
	return true


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
	var has_git := _has_git()
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
	if not _git_worktree_supported():
		var ver := _get_git_version()
		printerr("git worktrees not supported — requires git >= 2.13 (found %s)" % ver)
		printerr("install newer git or use --no-git for HEAD-only")
		quit(1)
		return

	if dry_run:
		print("dry-run preview for %s (project_root=%s):" % [manifest_path, project_root])
		var top_godot_path := str(dict.get("godot_path", "godot"))
		var top_build := str(dict.get("build_command", ""))
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
		var wt_path := _add_worktree(lbl, cm, project_root, force)
		if wt_path.is_empty():
			printerr("✘ failed to create worktree .worktrees/%s for %s" % [lbl, cm])
			failed_labels.append(lbl)
			continue
		var godot_bin := _resolve_godot_binary(wt_path, top_godot_path_r, hint_r)
		print("  godot: %s" % godot_bin)
		if not _regenerate_godot_cache(wt_path, godot_bin):
			printerr("✘ cache regeneration failed for %s" % lbl)
			failed_labels.append(lbl)
			continue
		if not _run_build_command(wt_path, bcmd_r, lbl, cm):
			printerr("✘ build failed for %s" % lbl)
			failed_labels.append(lbl)
			continue
		created.append(lbl)
		print("✔ worktree .worktrees/%s ready (godot + build ok)" % lbl)

	# --- cleanup: atexit/SIGINT trap equivalent — ensure no orphans ---
	if keep_worktrees:
		print("keeping all worktrees per --keep-worktrees (%d created)" % created.size())
		for lbl in created:
			print("  kept .worktrees/%s" % str(lbl))
		if not failed_labels.is_empty() and keep_failed:
			for lbl in failed_labels:
				print("  kept failed .worktrees/%s per --keep-failed" % str(lbl))
	else:
		_cleanup_worktrees(project_root, keep_failed, failed_labels)

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
