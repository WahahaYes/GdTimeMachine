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
		cregex.compile("^[0-9a-fA-F]{4,40}$")
		if cregex.search(commit) == null:
			return "captures[%d].commit '%s' must be hex 4-40 chars" % [i, commit]
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
	# Minimal healthcheck stub for Phase 0 — full probes in Phase 4
	print("gdtime doctor — healthcheck (stub, Phase 0)")
	print("  ○ git: probe not yet implemented (will check git --version + worktree)")
	print("  ○ godot: probe not yet implemented (will check godotenv + godot --version)")
	print("  ○ ffmpeg: probe not yet implemented (will check ffmpeg -version)")
	print("  ○ OBS: probe not yet implemented (will check binary + WebSocket)")
	print("  ○ build hook: probe not yet implemented (will check <bin> --version, warn-only)")
	print("  ○ output_dir: probe not yet implemented")
	if verbose:
		print("  --verbose: per-check version/path/hints in Phase 4")
	print("  (Phase 0 stub — exits 0)")
	quit(0)


func _cmd_run(args: PackedStringArray) -> void:
	if args.size() < 2 or String(args[1]).begins_with("-"):
		# Find manifest arg (last non-flag)
		var found := false
		for a in args:
			if not String(a).begins_with("-") and String(a) != "run":
				found = true
		if not found:
			printerr("run: missing <manifest.json>")
			_print_help()
			quit(1)
			return
	print("gdtime run — batch record not yet implemented (Phase 3)")
	print("  Use: gdtime validate <manifest.json> and gdtime doctor in Phase 0")
	quit(1)


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
