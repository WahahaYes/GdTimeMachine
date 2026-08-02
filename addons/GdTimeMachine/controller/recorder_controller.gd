@tool
extends Node
class_name RecorderController

## Registry of recording backends and router for their signals.
##
## UI and other consumers talk only to this node: it owns the active
## backend's lifecycle, forwards start/stop, and re-emits every backend
## signal so backends can be swapped without touching consumers.

## Registered backends, keyed by backend name.
var backends: Dictionary = {}
## Currently selected backend; null when none is registered yet.
var active_backend: RecorderBackend = null

## Emitted when the active backend changes (explicit selection, or the
## previously active backend being unregistered).
signal backend_changed(backend_name: String)
## Emitted when the active backend starts recording (forwarded from the backend).
signal recording_started(backend_name: String, output_path: String)
## Emitted when the active backend stops recording (forwarded from the backend).
signal recording_stopped(backend_name: String, output_path: String)
## Emitted periodically with the active backend's elapsed recording time (forwarded from the backend).
signal recording_progress(backend_name: String, elapsed_sec: float)
## Emitted when recording fails (forwarded from the backend, or emitted
## directly when start_recording is called with no backend selected).
signal recording_error(backend_name: String, error_message: String)
## Emitted with an info-level message from the active backend, shown in the
## dock status line (forwarded from the backend, e.g. capture statistics or a
## zero/low-frame hint).
signal recording_notice(backend_name: String, message: String)


## Registers a backend under its own name, connects its signals, reparents it
## under this node, and auto-selects it if no backend is active yet. Replaces
## (and frees) any backend already registered under the same name.
func register_backend(backend: RecorderBackend) -> void:
	if backend == null:
		push_warning("Cannot register a null backend")
		return
	var backend_name := backend.get_backend_name()
	if backend_name.is_empty():
		push_warning("Cannot register a backend with an empty name")
		return
	if backends.has(backend_name):
		push_warning("Backend '%s' already registered; replacing it" % backend_name)
		unregister_backend(backend_name)
	_connect_backend_signals(backend)
	backends[backend_name] = backend
	if not backend.is_inside_tree():
		add_child(backend)
	if active_backend == null:
		active_backend = backend


## Unregisters a backend by name: disconnects its signals, removes and frees
## it, and reselects another backend if the active one was removed.
func unregister_backend(backend_name: String) -> void:
	if not backends.has(backend_name):
		push_warning("Cannot unregister unknown backend '%s'" % backend_name)
		return
	var backend: RecorderBackend = backends[backend_name]
	_disconnect_backend_signals(backend)
	backends.erase(backend_name)
	if backend.is_inside_tree():
		remove_child(backend)
	backend.queue_free()
	if active_backend == backend:
		active_backend = _first_backend()
		backend_changed.emit(active_backend.get_backend_name() if active_backend else "")


## Switches the active backend to the one registered under backend_name.
## Emits backend_changed; no-op when the requested backend is already active.
func select_backend(backend_name: String) -> void:
	if not backends.has(backend_name):
		push_warning("Unknown backend '%s'; keeping current selection" % backend_name)
		return
	var backend: RecorderBackend = backends[backend_name]
	if backend == active_backend:
		return
	active_backend = backend
	backend_changed.emit(backend.get_backend_name())


## Names of all registered backends, in registration order.
func get_backend_names() -> Array:
	return backends.keys()


## Whether the active backend is currently recording.
func is_recording() -> bool:
	return active_backend != null and active_backend.is_recording()


## Capture mode of the active backend, so UI never reaches into backends
## directly. Defaults to RESTART_SCENE (the conservative answer) when no
## backend is selected.
func get_capture_mode() -> RecorderBackend.CaptureMode:
	if active_backend == null:
		return RecorderBackend.CaptureMode.RESTART_SCENE
	return active_backend.get_capture_mode()


## Starts recording on the active backend with the given config. Warns and
## emits recording_error when no backend is selected; warns and skips when
## the backend is already recording.
func start_recording(config: Dictionary) -> void:
	if active_backend == null:
		push_warning("No backend selected; cannot start recording")
		recording_error.emit("", "No backend selected")
		return
	if active_backend.is_recording():
		push_warning("Backend '%s' is already recording" % active_backend.get_backend_name())
		return
	active_backend.start(config)


## Stops the active backend if it is recording. Returns whether a stop was
## issued; false when there is no backend or it is not recording.
func stop_recording() -> bool:
	if active_backend == null or not active_backend.is_recording():
		return false
	active_backend.stop()
	return true


## Convenience alias for stop_recording(), discarding its result.
func stop_recording_if_active() -> void:
	stop_recording()


## First registered backend, or null when none are registered.
func _first_backend() -> RecorderBackend:
	if backends.is_empty():
		return null
	return backends.values()[0]


## Connects a backend's signals to this controller's re-emit handlers.
func _connect_backend_signals(backend: RecorderBackend) -> void:
	backend.recording_started.connect(_on_backend_recording_started)
	backend.recording_stopped.connect(_on_backend_recording_stopped)
	backend.recording_progress.connect(_on_backend_recording_progress)
	backend.recording_error.connect(_on_backend_recording_error)
	backend.recording_notice.connect(_on_backend_recording_notice)


## Disconnects a backend's signals from this controller's re-emit handlers.
func _disconnect_backend_signals(backend: RecorderBackend) -> void:
	backend.recording_started.disconnect(_on_backend_recording_started)
	backend.recording_stopped.disconnect(_on_backend_recording_stopped)
	backend.recording_progress.disconnect(_on_backend_recording_progress)
	backend.recording_error.disconnect(_on_backend_recording_error)
	backend.recording_notice.disconnect(_on_backend_recording_notice)


## Forwards a backend's recording_started as the controller's own signal.
func _on_backend_recording_started(backend_name: String, output_path: String) -> void:
	recording_started.emit(backend_name, output_path)


## Forwards a backend's recording_stopped as the controller's own signal.
func _on_backend_recording_stopped(backend_name: String, output_path: String) -> void:
	recording_stopped.emit(backend_name, output_path)


## Forwards a backend's recording_progress as the controller's own signal.
func _on_backend_recording_progress(backend_name: String, elapsed_sec: float) -> void:
	recording_progress.emit(backend_name, elapsed_sec)


## Forwards a backend's recording_error as the controller's own signal.
func _on_backend_recording_error(backend_name: String, error_message: String) -> void:
	recording_error.emit(backend_name, error_message)


## Forwards a backend's recording_notice as the controller's own signal.
func _on_backend_recording_notice(backend_name: String, message: String) -> void:
	recording_notice.emit(backend_name, message)
