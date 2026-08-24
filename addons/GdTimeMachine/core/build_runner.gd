class_name GdTMBuildRunner
extends RefCounted


static func run_build(
	worktree_path: String, build_command: String, label: String, commit: String, timeout: int = 600
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
		# Use timeout if available, otherwise plain sh
		var has_timeout := (
			OS.execute(
				"sh",
				PackedStringArray(["-c", "command -v timeout >/dev/null 2>&1 && echo yes"]),
				[],
				true
			)
			== 0
		)
		# Actually check via which
		var out_which: Array = []
		OS.execute("which", PackedStringArray(["timeout"]), out_which, true)
		var use_timeout := (
			not out_which.is_empty() and FileAccess.file_exists(str(out_which[0]).strip_edges())
		)
		if use_timeout:
			code = OS.execute(
				"sh",
				PackedStringArray(["-c", "timeout %d sh '%s'" % [timeout, script_path]]),
				[],
				false
			)
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
