class_name GdTMWorktree
extends RefCounted


## Returns true if git is available on PATH.
static func has_git() -> bool:
	var out: Array = []
	var code := OS.execute("git", PackedStringArray(["--version"]), out, true)
	return code == 0


## Returns `git --version` string or "unknown" if git missing.
static func get_git_version() -> String:
	var out: Array = []
	var code := OS.execute("git", PackedStringArray(["--version"]), out, true)
	if code != 0 or out.is_empty():
		return "unknown"
	var raw := str(out[0]).strip_edges()
	if raw.contains("\n"):
		raw = raw.split("\n")[0].strip_edges()
	return raw


## Returns true if git worktrees are supported (git >= 2.13).
static func is_worktree_supported() -> bool:
	if not has_git():
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


## Creates detached worktree .worktrees/<label> at commit. If force, removes existing collision. Returns absolute path or "" on failure.
static func add_worktree(
	label: String, commit: String, project_root: String, force: bool = false
) -> String:
	var wt_rel := ".worktrees/%s" % label
	var wt_abs := project_root.path_join(".worktrees").path_join(label)
	if DirAccess.dir_exists_absolute(wt_abs) or FileAccess.file_exists(wt_abs):
		if not force:
			printerr("worktree collision: %s already exists (use --force to overwrite)" % wt_rel)
			return ""
		else:
			print("worktree collision: %s exists — --force removing existing" % wt_rel)
			remove_worktree(label, project_root)
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
	var wt_parent := project_root.path_join(".worktrees")
	if not DirAccess.dir_exists_absolute(wt_parent):
		DirAccess.make_dir_absolute(wt_parent)
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


## Removes worktree .worktrees/<label> and prunes. Returns true if directory gone.
static func remove_worktree(label: String, project_root: String) -> bool:
	var wt_rel := ".worktrees/%s" % label
	var out: Array = []
	var code := OS.execute(
		"git",
		PackedStringArray(["-C", project_root, "worktree", "remove", "--force", wt_rel]),
		out,
		true
	)
	if code != 0:
		var msg := "\n".join(out) if not out.is_empty() else "exit %d" % code
		var wt_abs_check := project_root.path_join(".worktrees").path_join(label)
		if DirAccess.dir_exists_absolute(wt_abs_check):
			printerr("warning: git worktree remove failed for %s: %s" % [wt_rel, msg])
	var out2: Array = []
	OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "prune"]), out2, true)
	var wt_abs := project_root.path_join(".worktrees").path_join(label)
	if DirAccess.dir_exists_absolute(wt_abs):
		var da := DirAccess.open(wt_abs)
		if da == null:
			var out_rm: Array = []
			OS.execute("rm", PackedStringArray(["-rf", wt_abs]), out_rm, true)
		else:
			_delete_dir_recursive(wt_abs)
		if DirAccess.dir_exists_absolute(wt_abs):
			printerr("warning: worktree directory still exists: %s" % wt_abs)
			return false
	print("removed worktree %s" % wt_rel)
	return true


static func _delete_dir_recursive(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var da := DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var child := dir_path.path_join(fname)
			if DirAccess.dir_exists_absolute(child):
				_delete_dir_recursive(child)
			else:
				DirAccess.remove_absolute(child)
		fname = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(dir_path)


## Lists worktree paths via `git worktree list --porcelain`. Returns array of paths.
static func list_worktrees(project_root: String) -> Array:
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
	return result


## Cleans all .worktrees/* except those in failed_labels when keep_failed. Prunes at end.
static func cleanup_worktrees(
	project_root: String, keep_failed: bool, failed_labels: Array
) -> void:
	var wt_dir := project_root.path_join(".worktrees")
	if not DirAccess.dir_exists_absolute(wt_dir):
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
		remove_worktree(str(lbl), project_root)
	var out_final: Array = []
	OS.execute("git", PackedStringArray(["-C", project_root, "worktree", "prune"]), out_final, true)
