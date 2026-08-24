class_name GdTMGodotResolve
extends RefCounted


static func resolve_godot_binary(worktree_path: String, godot_path: String, hint: String) -> String:
	var bin := ""
	var out_env: Array = []
	var env_code := OS.execute(
		"godotenv", PackedStringArray(["godot", "env", "get"]), out_env, true
	)
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
	if not godot_path.is_empty() and godot_path != "godot":
		if FileAccess.file_exists(godot_path):
			return godot_path
		var out_which: Array = []
		OS.execute("which", PackedStringArray([godot_path]), out_which, true)
		if not out_which.is_empty() and FileAccess.file_exists(str(out_which[0]).strip_edges()):
			return str(out_which[0]).strip_edges()
		return godot_path
	var godot_bin_env := OS.get_environment("GODOT_BIN")
	if not godot_bin_env.is_empty():
		return godot_bin_env
	var out_which2: Array = []
	OS.execute("which", PackedStringArray(["godot"]), out_which2, true)
	if not out_which2.is_empty():
		return str(out_which2[0]).strip_edges()
	return "godot"


static func regenerate_cache(worktree_path: String, godot_bin: String) -> bool:
	var cache_dir := worktree_path.path_join(".godot")
	if DirAccess.dir_exists_absolute(cache_dir):
		var da := DirAccess.open(cache_dir)
		if da != null:
			# Use worktree helper via direct delete
			var out_rm: Array = []
			OS.execute("rm", PackedStringArray(["-rf", cache_dir]), out_rm, true)
		else:
			var out_rm2: Array = []
			OS.execute("rm", PackedStringArray(["-rf", cache_dir]), out_rm2, true)
	var out: Array = []
	var cmd := "%s --path '%s' --editor --headless --quit 2>&1" % [godot_bin, worktree_path]
	var code := OS.execute("sh", PackedStringArray(["-c", cmd]), out, true)
	if code != 0:
		var msg := "\n".join(out) if not out.is_empty() else "exit %d" % code
		printerr("warning: Godot cache regeneration failed in %s: %s" % [worktree_path, msg])
		return false
	return true
