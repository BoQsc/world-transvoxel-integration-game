extends CharacterBody3D

@export var human_input_enabled: bool = true
@export var move_speed: float = 8.0
@export var edit_radius: float = 1.8
@export var mouse_sensitivity: float = 0.0025
@export var interaction_distance: float = 96.0
@export var fly_speed: float = 32.0
@export var fly_fast_multiplier: float = 4.0

var game_world: Node
var edit_point := Vector3.ZERO
var pitch := 0.0
var human_command_armed := false
var fly_mode_enabled := false
var _walk_collision_layer := 0
var _walk_collision_mask := 0
var _walk_collision_state_saved := false


func set_human_input_enabled(enabled: bool) -> void:
	human_input_enabled = enabled
	if enabled:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func autonomous_translate(delta: Vector3) -> bool:
	global_position += delta
	return true


func set_fly_mode_enabled(enabled: bool) -> void:
	_set_fly_mode_enabled(enabled)


func is_fly_mode_enabled() -> bool:
	return fly_mode_enabled


func submit_edit_input(mode_name: StringName, center: Vector3) -> bool:
	if game_world == null or not game_world.has_method("submit_sphere_edit"):
		return false
	var material_id := -1 if mode_name == &"carve" else 4
	return bool(game_world.call("submit_sphere_edit", mode_name, center, edit_radius, material_id, 1.0))


func _physics_process(delta: float) -> void:
	if not human_input_enabled:
		return
	if fly_mode_enabled:
		_physics_process_fly(delta)
		return
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		direction.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		direction.z += 1.0
	if Input.is_key_pressed(KEY_A):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		direction.x += 1.0
	direction = direction.normalized()
	var world_direction := (global_transform.basis * direction)
	world_direction.y = 0.0
	world_direction = world_direction.normalized()
	velocity.x = world_direction.x * move_speed
	velocity.z = world_direction.z * move_speed
	if not is_on_floor():
		velocity.y -= 24.0 * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = 7.0
	move_and_slide()
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", false)


func _physics_process_fly(delta: float) -> void:
	var camera := get_node_or_null("FirstPersonCamera") as Camera3D
	var movement_basis := global_transform.basis
	if camera != null:
		movement_basis = camera.global_transform.basis
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		direction += -movement_basis.z
	if Input.is_key_pressed(KEY_S):
		direction += movement_basis.z
	if Input.is_key_pressed(KEY_A):
		direction += -movement_basis.x
	if Input.is_key_pressed(KEY_D):
		direction += movement_basis.x
	if Input.is_key_pressed(KEY_SPACE):
		direction += Vector3.UP
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_C):
		direction -= Vector3.UP
	if direction.length_squared() > 0.0:
		direction = direction.normalized()
	var speed := fly_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= fly_fast_multiplier
	global_position += direction * speed * delta
	velocity = Vector3.ZERO
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", false)


func _unhandled_input(event: InputEvent) -> void:
	if not human_input_enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			return
		if _is_human_command_prefix(event):
			human_command_armed = true
			return
		if human_command_armed and (event.keycode == KEY_F or event.physical_keycode == KEY_F):
			human_command_armed = false
			_set_fly_mode_enabled(not fly_mode_enabled)
			return
		human_command_armed = false
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		pitch = clamp(pitch - event.relative.y * mouse_sensitivity, -1.45, 1.45)
		var camera := get_node_or_null("FirstPersonCamera") as Camera3D
		if camera != null:
			camera.rotation.x = pitch
		return
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			submit_edit_input(&"carve", _interaction_point())
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			submit_edit_input(&"construct", _interaction_point())


func _interaction_point() -> Vector3:
	var camera := get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return edit_point
	var origin := camera.global_position
	var end := origin + (-camera.global_transform.basis.z * interaction_distance)
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return origin + (-camera.global_transform.basis.z * minf(interaction_distance, 8.0))
	return hit["position"]


func _set_fly_mode_enabled(enabled: bool) -> void:
	if fly_mode_enabled == enabled:
		return
	fly_mode_enabled = enabled
	human_command_armed = false
	velocity = Vector3.ZERO
	if enabled:
		_walk_collision_layer = collision_layer
		_walk_collision_mask = collision_mask
		_walk_collision_state_saved = true
		collision_mask = 0
	else:
		if _walk_collision_state_saved:
			collision_layer = _walk_collision_layer
			collision_mask = _walk_collision_mask
			_walk_collision_state_saved = false
	print("human_fly_mode=%s" % ("on" if fly_mode_enabled else "off"))


func _is_human_command_prefix(event: InputEventKey) -> bool:
	return event.unicode == 96 or event.unicode == 126 or \
			event.keycode == 96 or event.keycode == 126 or \
			event.physical_keycode == 96 or event.physical_keycode == 126
