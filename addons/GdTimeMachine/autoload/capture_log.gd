## Game-side capture log: writes everything the game prints (print, printerr,
## push_warning/push_error, engine errors) into "<movie>.log" beside the Movie
## Maker output, each line stamped with the movie frame it was printed on.
##
## Opt-in by handshake: the recorder (gdtime run or the editor's Movie Maker
## backend) creates the log file before launching the game; this node appends
## to it only when the game is writing a movie AND that file exists, so plain
## Movie Maker runs and exported games are untouched.
##
## Standalone on purpose (no class_name, engine API only): gdtime copies it
## into a capture's worktree and registers it as an autoload through
## override.cfg, so commits without (this version of) the addon get a log too.
## The Logger subclass lives in capture_logger.gd, loaded only when the engine
## has Logger (4.5+), so this file still parses on older engines.
extends Node

## Engine meta flag set once a capture log is installed, so the addon's own
## autoload and the one gdtime injects never both write.
const ACTIVE_META := &"gd_time_machine_capture_log"

## Installed logger (a capture_logger.gd instance), or null.
var _logger: Object = null


## Installs the logger as early as possible, before the main scene's _ready.
func _enter_tree() -> void:
	_install(_movie_path())


## Removes the logger and closes the file.
func _exit_tree() -> void:
	if _logger == null:
		return
	OS.remove_logger(_logger)
	_logger.call("close")
	_logger = null
	Engine.remove_meta(ACTIVE_META)


## "<movie path without extension>.log", or "" when no movie is written.
static func log_path_for_movie(movie_path: String) -> String:
	if movie_path.is_empty():
		return ""
	return movie_path.get_basename() + ".log"


## The movie path this run writes ("" when Movie Maker is off or the engine
## predates Engine.get_write_movie_path()). Seam for tests.
func _movie_path() -> String:
	if not Engine.has_method("get_write_movie_path"):
		return ""
	return str(Engine.call("get_write_movie_path"))


## Opens the recorder-created log for appending and registers the logger.
## Returns true when a logger was installed.
func _install(movie_path: String) -> bool:
	var path := log_path_for_movie(movie_path)
	if path.is_empty() or Engine.has_meta(ACTIVE_META):
		return false
	path = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		return false
	file.seek_end()
	Engine.set_meta(ACTIVE_META, true)
	if not ClassDB.class_exists("Logger"):
		file.store_line("# game output not captured: needs Godot 4.5+ (Logger)")
		file.close()
		return false
	var logger_script: Script = load(_logger_script_path())
	_logger = logger_script.new(file)
	OS.add_logger(_logger)
	return true


## capture_logger.gd beside this script, wherever it was copied to (found via
## the script chain, so subclasses resolve to this file's folder).
func _logger_script_path() -> String:
	var script := get_script() as Script
	while script != null and script.resource_path.get_file() != "capture_log.gd":
		script = script.get_base_script()
	var dir := script.resource_path.get_base_dir() if script != null else "res://"
	return dir.path_join("capture_logger.gd")
