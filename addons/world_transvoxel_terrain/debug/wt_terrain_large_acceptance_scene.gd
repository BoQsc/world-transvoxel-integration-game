@tool
extends "res://addons/world_transvoxel_terrain/debug/wt_terrain_large_acceptance_presentation.gd"
class_name WtTerrainLargeAcceptanceScene

var _metrics_accumulator := 0.0
var _bounds_accumulator := 0.0


func _ready() -> void:
	_session_root = "user://world_transvoxel_terrain/tqp57_large_acceptance/%s_%d" % [
		"editor" if Engine.is_editor_hint() else "runtime",
		OS.get_process_id(),
	]
	_configure_profiles()
	_configure_interface()
	_build_world_bounds()
	_focus_camera(_viewer_position)
	set_process(true)
	call_deferred("_start_preview")


func _exit_tree() -> void:
	_session_generation += 1
	if terrain_world != null and terrain_world.has_method("is_world_running") and terrain_world.call("is_world_running"):
		terrain_world.call("stop_world")
	_world_started = false


func _process(delta: float) -> void:
	_metrics_accumulator += delta
	_bounds_accumulator += delta
	if not Engine.is_editor_hint(): _update_runtime_camera(delta)
	if _metrics_accumulator >= 0.2:
		_metrics_accumulator = 0.0
		_refresh_metrics()
	if _bounds_accumulator >= 0.5:
		_bounds_accumulator = 0.0
		_refresh_resident_bounds()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint(): return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _looking:
		_camera_yaw -= event.relative.x * 0.0035
		_camera_pitch = clampf(_camera_pitch - event.relative.y * 0.0035, -1.48, 1.48)
		camera.rotation = Vector3(_camera_pitch, _camera_yaw, 0.0)
		get_viewport().set_input_as_handled()
