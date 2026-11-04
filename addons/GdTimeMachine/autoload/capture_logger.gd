## Logger behind the capture log (see capture_log.gd): stamps each line the
## game prints with the Movie Maker frame it was printed on.
##
## Line format: "[frame N | T s] text", where N = Engine.get_frames_drawn() at
## print time and T = N × the fixed frame step. Movie Maker runs fixed-step
## (every frame advances exactly 1/fps of game time, however long it takes to
## render), so N is the 0-based index of the first video frame that can show
## the line's effect, and T is that frame's timestamp in the video. Wall-clock
## time would drift from the footage, so it is not used. Lines from printerr
## carry "(stderr) "; engine errors and warnings read "ERROR: …"/"WARNING: …".
##
## Called from any thread, so writes are serialized; each write is flushed so
## a killed game still leaves its log behind. Standalone (no class_name): gdtime
## copies it into capture worktrees beside capture_log.gd.
extends Logger

## Labels for _log_error's error_type (Logger.ErrorType order).
const ERROR_LABELS := ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"]

## Log file, opened for appending by capture_log.gd.
var _file: FileAccess

## Serializes writes from the main thread and worker threads.
var _mutex := Mutex.new()


func _init(file: FileAccess) -> void:
	_file = file


## One stamped log line.
static func format_line(frame: int, seconds: float, text: String) -> String:
	return "[frame %d | %.3fs] %s" % [frame, seconds, text]


## print/printerr output; may hold several lines.
func _log_message(message: String, error: bool) -> void:
	_write(message, "(stderr) " if error else "")


## push_error/push_warning and engine errors.
func _log_error(
	function: String,
	file: String,
	line: int,
	code: String,
	rationale: String,
	_editor_notify: bool,
	error_type: int,
	_script_backtraces: Array[ScriptBacktrace]
) -> void:
	var label: String = (
		ERROR_LABELS[error_type]
		if error_type >= 0 and error_type < ERROR_LABELS.size()
		else "ERROR"
	)
	var text := rationale if not rationale.is_empty() else code
	var where := (
		"%s:%d" % [file, line] if function.is_empty() else "%s:%d @ %s()" % [file, line, function]
	)
	_write("%s: %s (%s)" % [label, text, where], "")


## Closes the file; later messages are dropped.
func close() -> void:
	_mutex.lock()
	if _file != null:
		_file.close()
		_file = null
	_mutex.unlock()


## Stamps and appends each line of message.
func _write(message: String, prefix: String) -> void:
	var frame := Engine.get_frames_drawn()
	var seconds := frame * _frame_step()
	var lines := message.split("\n")
	if lines.size() > 1 and lines[lines.size() - 1].is_empty():
		lines.resize(lines.size() - 1)
	_mutex.lock()
	if _file != null:
		for text in lines:
			_file.store_line(format_line(frame, seconds, prefix + text))
		_file.flush()
	_mutex.unlock()


## Seconds per frame: the root's process delta, which Movie Maker fixes at
## 1/fps. 0 before the first frame (frame 0, so the stamp is 0 either way).
func _frame_step() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return 0.0
	return tree.root.get_process_delta_time()
