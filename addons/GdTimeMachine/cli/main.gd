extends SceneTree

## GdTimeMachine CLI — self-contained GDScript entry
##
## Location: addons/GdTimeMachine/cli/main.gd (only path that ships via Asset Library)
## Entry: consumers run `gdtime <command>` (wrapper at cli/gdtime) → godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args>
## Fallback: godot --headless -s addons/GdTimeMachine/cli/main.gd -- <args> directly

const PLUGIN_CFG_PATH := "res://addons/GdTimeMachine/plugin.cfg"
const SCHEMA_PATH := "res://addons/GdTimeMachine/cli/schema/batch_manifest.schema.json"


func _get_version() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PLUGIN_CFG_PATH) == OK:
		return str(cfg.get_value("plugin", "version", "")).strip_edges()
	return ""


## GdTMWorktree — worktree helper for git worktree lifecycle.
const GdTMWorktree := preload("res://addons/GdTimeMachine/core/worktree.gd")
## GdTMGodotResolve — resolver for Godot binary via godotenv and PATH.
const GdTMGodotResolve := preload("res://addons/GdTimeMachine/core/godot_resolve.gd")
## GdTMBuildRunner — runner for per-capture build_command.
const GdTMBuildRunner := preload("res://addons/GdTimeMachine/core/build_runner.gd")
## GdTMMovieWriter — writer that records captures via godot --write-movie.
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
			print("gdtime %s" % _get_version())
			quit(0)
		_:
			printerr("Unknown command: %s" % cmd)
			_print_help()
			quit(1)


func _print_help() -> void:
	print(
		"""gdtime — batch capture for GdTimeMachine (Movie Maker headless)

Usage:
  gdtime validate <manifest.json> [--strict]          Validate manifest
  gdtime run [options] <manifest.json>                Run batch (worktree → godot → build → record)
  gdtime doctor [--verbose] [--fix]                   Check deps (git/godot/ffmpeg/OBS/build hook)
  gdtime list-commits <manifest.json>                 List captures (commit label)

Options for run:
  --dry-run        Preview without creating worktrees
  --resume LABEL   Skip entries before LABEL
  --keep-failed    Keep worktrees for failed entries
  --keep-worktrees Keep all worktrees
  --no-git         HEAD-only, no worktrees (requires git otherwise)
  --force          Overwrite existing worktree

Examples:
  gdtime validate test/cli/manifest_history.json
  gdtime run --dry-run test/cli/manifest_history.json
  gdtime run test/cli/manifest_history.json
  gdtime doctor --verbose"""
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
		print("[OK] manifest valid: %s" % path)
		quit(0)
	else:
		printerr("[FAIL] manifest invalid: %s" % path)
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
	var fix := "--fix" in args
	print("gdtime doctor — healthcheck")
	var degraded := false
	var failed := false
	# git
	var git_ver := GdTMWorktree.get_git_version()
	if GdTMWorktree.has_git():
		var wt_ok := GdTMWorktree.is_worktree_supported()
		if wt_ok:
			print("  [OK] git %s — worktrees: yes" % git_ver)
			if verbose:
				var out: Array = []
				OS.execute("git", PackedStringArray(["worktree", "list", "--porcelain"]), out, true)
				print("    worktrees: %d registered" % out.size())
		else:
			print("  [WARN] git %s — worktrees: no (requires ≥2.13)" % git_ver)
			degraded = true
	else:
		print("  [FAIL] git not found — history requires git, use --no-git for HEAD-only")
		print("    hint: sudo apt install git / brew install git")
		failed = true
	# godot + godotenv
	var godot_bin := GdTMGodotResolve.resolve_godot_binary(
		ProjectSettings.globalize_path("res://"), "godot", ""
	)
	var out_godot: Array = []
	var godot_code := OS.execute(godot_bin, PackedStringArray(["--version"]), out_godot, true)
	if godot_code == 0 and not out_godot.is_empty():
		var ver := str(out_godot[0]).strip_edges()
		print("  [OK] godot %s — %s" % [ver, godot_bin])
		if verbose:
			var out_env: Array = []
			OS.execute(
				"sh", PackedStringArray(["-c", "godotenv godot env get 2>&1"]), out_env, true
			)
			if not out_env.is_empty():
				print("    godotenv: %s" % str(out_env[0]).strip_edges())
	else:
		print("  [FAIL] godot not found — %s" % godot_bin)
		print("    hint: install Godot 4.7+ or set GODOT_BIN / godotenv")
		failed = true
	var out_godotenv: Array = []
	var has_godotenv := (
		OS.execute(
			"sh",
			PackedStringArray(["-c", "command -v godotenv >/dev/null 2>&1 && echo yes"]),
			out_godotenv,
			true
		)
		== 0
	)
	if has_godotenv:
		if verbose:
			print("  [OK] godotenv available")
	else:
		print("  [WARN] godotenv not found — will use godot on PATH")
		if verbose:
			print("    hint: https://github.com/chickensoft-games/GodotEnv")
	# ffmpeg
	var ffmpeg_path := (
		str(ProjectSettings.get_setting("gd_time_machine/ffmpeg/path"))
		if ProjectSettings.has_setting("gd_time_machine/ffmpeg/path")
		else ""
	)
	if ffmpeg_path.is_empty():
		ffmpeg_path = "ffmpeg"
	var out_ff: Array = []
	var ff_code := OS.execute(ffmpeg_path, PackedStringArray(["-version"]), out_ff, true)
	if ff_code == 0 and not out_ff.is_empty():
		var ff_ver := (
			str(out_ff[0]).split("\n")[0].strip_edges()
			if str(out_ff[0]).contains("\n")
			else str(out_ff[0]).strip_edges()
		)
		print("  [OK] ffmpeg — %s (%s)" % [ff_ver, ffmpeg_path])
	else:
		print("  [WARN] ffmpeg not found — tier-2 mp4/webm will be unavailable")
		print(
			"    hint: sudo apt install ffmpeg / brew install ffmpeg, or set gd_time_machine/ffmpeg/path"
		)
		degraded = true
	# OBS
	var obs_binary := ""
	if ProjectSettings.has_setting("gd_time_machine/obs/binary_path"):
		obs_binary = str(ProjectSettings.get_setting("gd_time_machine/obs/binary_path"))
	if obs_binary.is_empty():
		var out_which: Array = []
		OS.execute("which", PackedStringArray(["obs"]), out_which, true)
		if not out_which.is_empty():
			obs_binary = str(out_which[0]).strip_edges()
	if not obs_binary.is_empty() and FileAccess.file_exists(obs_binary):
		print("  [OK] OBS Studio — %s" % obs_binary)
		if verbose:
			print("    WebSocket probe: skipped (use dock for live probe)")
	else:
		print("  [WARN] OBS Studio not found — Movie Maker will be used for history")
		if verbose:
			print("    hint: obsproject.com, then enable Tools → WebSocket Server Settings")
		degraded = true
	# build hook
	var manifest_path_doctor := ""
	for a in args:
		if (
			not String(a).begins_with("-")
			and String(a) != "doctor"
			and FileAccess.file_exists(String(a))
		):
			manifest_path_doctor = String(a)
			break
	if not manifest_path_doctor.is_empty() and FileAccess.file_exists(manifest_path_doctor):
		var content := FileAccess.get_file_as_string(manifest_path_doctor)
		var json := JSON.new()
		if json.parse(content) == OK and typeof(json.data) == TYPE_DICTIONARY:
			var dict: Dictionary = json.data
			var bcmd := str(dict.get("build_command", ""))
			if bcmd.strip_edges().is_empty():
				print("  [INFO] build hook: none (GDScript-only)")
			else:
				var bin_name := bcmd.split(" ")[0].strip_edges()
				var out_b: Array = []
				var bcode := OS.execute(bin_name, PackedStringArray(["--version"]), out_b, true)
				if bcode != 0:
					bcode = OS.execute(
						"sh", PackedStringArray(["-c", "%s --version 2>&1" % bin_name]), out_b, true
					)
				if bcode == 0 and not out_b.is_empty():
					print(
						(
							"  [OK] build hook: %s — %s"
							% [bin_name, str(out_b[0]).strip_edges().split("\n")[0]]
						)
					)
				else:
					print(
						'  [WARN] build hook: %s not found (build_command="%s")' % [bin_name, bcmd]
					)
					degraded = true
		else:
			print("  [INFO] build hook: no manifest provided, skipping probe")
	else:
		print(
			"  [INFO] build hook: no manifest provided, skipping probe (pass manifest.json to check)"
		)
	# output_dir
	var out_dir := "res://media/captures/history"
	if not manifest_path_doctor.is_empty() and FileAccess.file_exists(manifest_path_doctor):
		var c2 := FileAccess.get_file_as_string(manifest_path_doctor)
		var j2 := JSON.new()
		if j2.parse(c2) == OK and typeof(j2.data) == TYPE_DICTIONARY:
			var d2: Dictionary = j2.data
			out_dir = str(d2.get("output_dir", out_dir))
	var abs_out := (
		ProjectSettings.globalize_path(out_dir) if out_dir.begins_with("res://") else out_dir
	)
	if DirAccess.dir_exists_absolute(abs_out):
		print("  [OK] output_dir %s — writable" % out_dir)
	else:
		print("  [WARN] output_dir %s — not found" % out_dir)
		if fix:
			var mk := DirAccess.make_dir_recursive_absolute(abs_out)
			if mk == OK:
				print("    --fix: created %s" % abs_out)
			else:
				print("    --fix: failed to create %s" % abs_out)
		else:
			print("    hint: mkdir -p %s  or use --fix" % abs_out)
		degraded = true
	# worktree orphans — only .worktrees/*, not the main worktree
	var wt_dir_check := ProjectSettings.globalize_path("res://").path_join(".worktrees")
	var wt_orphans: Array = []
	if DirAccess.dir_exists_absolute(wt_dir_check):
		var da_wt := DirAccess.open(wt_dir_check)
		if da_wt != null:
			da_wt.list_dir_begin()
			var fn := da_wt.get_next()
			while fn != "":
				if fn != "." and fn != "..":
					wt_orphans.append(wt_dir_check.path_join(fn))
				fn = da_wt.get_next()
			da_wt.list_dir_end()
	if wt_orphans.is_empty():
		print("  [OK] worktrees: none orphaned")
	else:
		print("  [WARN] worktrees: %d in .worktrees/" % wt_orphans.size())
		degraded = true
		if verbose:
			for w in wt_orphans:
				print("    %s" % str(w))
		if fix:
			var outp: Array = []
			OS.execute("git", PackedStringArray(["worktree", "prune"]), outp, true)
			print("    --fix: pruned")
	if failed:
		print("doctor: [FAIL] failed — core deps missing")
		quit(1)
	elif degraded:
		print(
			"doctor: [WARN] degraded — optional deps missing, history via Movie Maker still works"
		)
		quit(2)
	else:
		print("doctor: [OK] healthy")
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
	# Last non-flag argument wins (manifest path).
	if manifest_path.is_empty():
		# Try last non-flag scan (original behavior)
		for a in args:
			var s := String(a)
			if not s.begins_with("-") and s != "run":
				manifest_path = s
	return manifest_path


func _get_arg_value(args: PackedStringArray, name: String, default: String) -> String:
	for i in range(args.size()):
		if String(args[i]) == name and i + 1 < args.size():
			return String(args[i + 1])
		if String(args[i]).begins_with(name + "="):
			return String(args[i]).substr(name.length() + 1)
	return default


func _cmd_run(args: PackedStringArray) -> void:
	var keep_worktrees := "--keep-worktrees" in args
	var keep_failed := "--keep-failed" in args
	var force := "--force" in args
	var dry_run := "--dry-run" in args
	var no_git := "--no-git" in args
	var resume_label := _get_arg_value(args, "--resume", "")
	var build_timeout_s := _get_arg_value(args, "--build-timeout", "600")
	var build_timeout := int(build_timeout_s) if build_timeout_s.is_valid_int() else 600
	var fail_fast := "--fail-fast" in args

	var manifest_path := _extract_manifest_path(args)
	if manifest_path.is_empty():
		printerr("run: missing <manifest.json>")
		_print_help()
		quit(1)
		return

	var strict := "--strict" in args
	var validation_err := _validate_manifest(manifest_path, strict)
	if not validation_err.is_empty():
		printerr("[FAIL] manifest invalid: %s" % manifest_path)
		printerr(validation_err)
		quit(1)
		return

	var content := FileAccess.get_file_as_string(manifest_path)
	var json := JSON.new()
	if json.parse(content) != OK:
		printerr("[FAIL] manifest invalid: %s" % manifest_path)
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
	if not resume_label.is_empty():
		var idx := -1
		for i in range(arr.size()):
			var e = arr[i]
			if typeof(e) == TYPE_DICTIONARY and str(e.get("label", "")) == resume_label:
				idx = i
				break
		if idx == -1:
			printerr("[FAIL] --resume label '%s' not found in manifest" % resume_label)
			quit(1)
			return
		print("resuming from %s (skipping %d entries before it)" % [resume_label, idx])
		arr = arr.slice(idx)

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
					print("[OK] %s (HEAD) — no worktree (--no-git)" % lbl)
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
				print("[OK] %s (HEAD) — no worktree (--no-git)" % lbl2)
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
			printerr("[FAIL] failed to create worktree .worktrees/%s for %s" % [lbl, cm])
			failed_labels.append(lbl)
			if fail_fast:
				break
			continue
		var godot_bin := GdTMGodotResolve.resolve_godot_binary(wt_path, top_godot_path_r, hint_r)
		print("  godot: %s" % godot_bin)
		if not GdTMGodotResolve.regenerate_cache(wt_path, godot_bin):
			printerr("[FAIL] cache regeneration failed for %s" % lbl)
			failed_labels.append(lbl)
			if fail_fast:
				break
			continue
		if not GdTMBuildRunner.run_build(wt_path, bcmd_r, lbl, cm, build_timeout):
			printerr("[FAIL] build failed for %s" % lbl)
			failed_labels.append(lbl)
			if fail_fast:
				break
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
			printerr("[FAIL] record failed for %s" % lbl)
			failed_labels.append(lbl)
			if fail_fast:
				break
			continue
		created.append(lbl)
		print("[OK] %s done (worktree + build + record)" % lbl)

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
