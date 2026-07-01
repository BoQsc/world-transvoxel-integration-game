extends CharacterBody3D

@export var human_input_enabled: bool = true
@export var move_speed: float = 8.0
@export var edit_radius: float = 1.8

var game_world: Node
var edit_point := Vector3.ZERO


func set_human_input_enabled(enabled: bool) -> void:
	human_input_enabled = enabled
	if enabled:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func autonomous_translate(delta: Vector3) -> bool:
	global_position += delta
	return true


func submit_edit_input(mode_name: StringName, center: Vector3) -> bool:
	if game_world == null or not game_world.has_method("submit_sphere_edit"):
		return false
	var material_id := -1 if mode_name == &"carve" else 4
	return bool(game_world.call("submit_sphere_edit", mode_name, center, edit_radius, material_id, 1.0))


func _physics_process(delta: float) -> void:
	if not human_input_enabled:
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
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if not is_on_floor():
		velocity.y -= 24.0 * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = 7.0
	move_and_slide()


func _unhandled_input(event: InputEvent) -> void:
	if not human_input_enabled:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			submit_edit_input(&"carve", edit_point)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			submit_edit_input(&"construct", edit_point)
