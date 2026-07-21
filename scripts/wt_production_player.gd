extends CharacterBody3D

const PLACE_MATERIAL_IDS := [1, 2, 3, 4, 5, 7, 8, 10]
const PLACE_MATERIAL_NAMES := [
	"deep_stone",
	"grass",
	"gravel",
	"sand",
	"snow",
	"mid_rock",
	"ore_patch",
	"asphalt",
]

@export var human_input_enabled: bool = true
@export var move_speed: float = 8.0
@export var edit_radius: float = 1.8
@export var mouse_sensitivity: float = 0.0025
@export var interaction_distance: float = 96.0
@export var fly_speed: float = 32.0
@export var fly_fast_multiplier: float = 4.0
@export var render_mesh_fallback_target_enabled: bool = true
@export var render_mesh_fallback_max_instances: int = 1024
@export var render_mesh_fallback_max_triangles: int = 250000

var game_world: Node
var human_command_target: Node
var edit_point := Vector3.ZERO
var pitch := 0.0
var human_command_armed := false
var fly_mode_enabled := false
var _walk_collision_layer := 0
var _walk_collision_mask := 0
var _walk_motion_mode := CharacterBody3D.MOTION_MODE_GROUNDED
var _walk_collision_state_saved := false
var _interaction_attempt_count := 0
var selected_place_material_index := 3
var _last_interaction_summary := {
	"attempt": 0,
	"mode": "",
	"ray_hit": false,
	"accepted": false,
	"reason": "not_attempted",
	"selected_material_id": 4,
	"selected_material_name": "sand",
}


func set_human_input_enabled(enabled: bool) -> void:
	human_input_enabled = enabled
	if enabled:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func autonomous_translate(delta: Vector3) -> bool:
	global_position += delta
	return true


func autonomous_move_with_streaming_collision(
	motion_velocity: Vector3,
	delta: float
) -> bool:
	velocity = motion_velocity
	return _move_with_streaming_collision(delta)


func set_fly_mode_enabled(enabled: bool) -> void:
	_set_fly_mode_enabled(enabled)


func is_fly_mode_enabled() -> bool:
	return fly_mode_enabled


func get_last_interaction_summary() -> Dictionary:
	return _last_interaction_summary.duplicate(true)


func get_selected_material_summary() -> Dictionary:
	return {
		"slot": selected_place_material_index + 1,
		"slot_count": PLACE_MATERIAL_IDS.size(),
		"material_id": _selected_place_material_id(),
		"material_name": _selected_place_material_name(),
	}


func set_selected_material_slot(slot: int) -> bool:
	if slot < 1 or slot > PLACE_MATERIAL_IDS.size():
		return false
	_set_selected_place_material_index(slot - 1)
	return true


func set_selected_material_id(material_id: int) -> bool:
	var index := PLACE_MATERIAL_IDS.find(material_id)
	if index < 0:
		return false
	_set_selected_place_material_index(index)
	return true


func get_interaction_target_summary() -> Dictionary:
	return _interaction_target()


func autonomous_look_at(target: Vector3) -> bool:
	var camera := get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return false
	camera.look_at(target, Vector3.UP)
	return true


func set_view_target(target: Vector3) -> bool:
	var camera := get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return false
	var direction := target - camera.global_position
	if direction.length_squared() <= 0.000001:
		return false
	direction = direction.normalized()
	rotation.y = atan2(-direction.x, -direction.z)
	pitch = clamp(asin(direction.y), -1.45, 1.45)
	camera.rotation = Vector3(pitch, 0.0, 0.0)
	return true


func autonomous_submit_interaction(mode_name: StringName) -> bool:
	return _submit_interaction(mode_name)


func submit_edit_input(mode_name: StringName, center: Vector3, ray_hit: bool = false) -> bool:
	if game_world == null or not game_world.has_method("submit_sphere_edit"):
		_record_interaction(mode_name, ray_hit, false, "game_world_unavailable", center)
		return false
	var material_id := -1 if mode_name == &"carve" else _selected_place_material_id()
	var accepted := bool(game_world.call("submit_sphere_edit", mode_name, center, edit_radius, material_id, 1.0))
	_record_interaction(mode_name, ray_hit, accepted, "raycast_hit" if ray_hit and accepted else ("direct_center" if accepted else "edit_rejected"), center)
	if game_world.has_method("get_last_edit_summary"):
		_last_interaction_summary["edit_summary"] = game_world.call("get_last_edit_summary")
	return accepted


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
	_move_with_streaming_collision(delta)
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
	velocity = direction * speed
	_move_with_streaming_collision(delta)
	if game_world != null and game_world.has_method("update_player_viewer"):
		game_world.call("update_player_viewer", false)


func _move_with_streaming_collision(delta: float) -> bool:
	if game_world != null and \
			game_world.has_method("is_player_collision_ready_at") and \
			not bool(game_world.call(
				"is_player_collision_ready_at",
				global_position + velocity * delta
			)):
		velocity = Vector3.ZERO
		return false
	move_and_slide()
	return true


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
		if human_command_armed and (event.keycode == KEY_L or event.physical_keycode == KEY_L):
			human_command_armed = false
			_forward_human_command(&"cycle_lighting")
			return
		if human_command_armed and (event.keycode == KEY_K or event.physical_keycode == KEY_K):
			human_command_armed = false
			_forward_human_command(&"toggle_local_lights")
			return
		if human_command_armed and (event.keycode == KEY_M or event.physical_keycode == KEY_M):
			human_command_armed = false
			_forward_human_command(&"mark_artifact")
			return
		if human_command_armed and (event.keycode == KEY_P or event.physical_keycode == KEY_P):
			human_command_armed = false
			_forward_human_command(&"mark_path_point")
			return
		if human_command_armed and (event.keycode == KEY_T or event.physical_keycode == KEY_T):
			human_command_armed = false
			_forward_human_command(&"cycle_material_mode")
			return
		var material_slot := _material_slot_from_key(event)
		if material_slot >= 0:
			human_command_armed = false
			_set_selected_place_material_index(material_slot)
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
			_submit_interaction(&"carve")
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_submit_interaction(&"construct")
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_submit_interaction(&"paint")


func _interaction_point() -> Vector3:
	var target := _interaction_target()
	if bool(target.get("ray_hit", false)):
		return target["position"]
	return edit_point


func _interaction_target() -> Dictionary:
	var camera := get_node_or_null("FirstPersonCamera") as Camera3D
	if camera == null:
		return {
			"ray_hit": false,
			"render_mesh_hit": false,
			"target_source": "none",
			"reason": "camera_missing",
			"position": edit_point,
			"collider": "",
		}
	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var end := origin + (direction * interaction_distance)
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var collider = hit.get("collider", null)
		var collider_name := ""
		if collider is Node:
			collider_name = str((collider as Node).name)
		return {
			"ray_hit": true,
			"render_mesh_hit": false,
			"target_source": "physics_collision",
			"reason": "raycast_hit",
			"position": hit["position"],
			"collider": collider_name,
		}
	var fallback := _render_mesh_interaction_target(origin, direction.normalized(), interaction_distance)
	if bool(fallback.get("render_mesh_hit", false)):
		return fallback
	return {
		"ray_hit": false,
		"render_mesh_hit": false,
		"target_source": "none",
		"reason": str(fallback.get("reason", "raycast_miss")),
		"position": end,
		"collider": "",
	}


func _submit_interaction(mode_name: StringName) -> bool:
	var target := _interaction_target()
	var has_target := bool(target.get("ray_hit", false)) or bool(target.get("render_mesh_hit", false))
	if not has_target:
		_record_interaction(
			mode_name,
			false,
			false,
			str(target.get("reason", "raycast_miss")),
			target.get("position", edit_point)
		)
		return false
	var position: Vector3 = target["position"]
	var accepted := submit_edit_input(mode_name, position, bool(target.get("ray_hit", false)))
	_last_interaction_summary["reason"] = str(target.get("reason", "target_hit")) if accepted else "edit_rejected_after_target"
	_last_interaction_summary["collider"] = str(target.get("collider", ""))
	_last_interaction_summary["target_source"] = str(target.get("target_source", "unknown"))
	_last_interaction_summary["render_mesh_hit"] = bool(target.get("render_mesh_hit", false))
	if target.has("fallback_instances_scanned"):
		_last_interaction_summary["fallback_instances_scanned"] = int(target["fallback_instances_scanned"])
	if target.has("fallback_triangles_scanned"):
		_last_interaction_summary["fallback_triangles_scanned"] = int(target["fallback_triangles_scanned"])
	return accepted


func _render_mesh_interaction_target(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	if not render_mesh_fallback_target_enabled:
		return {
			"ray_hit": false,
			"render_mesh_hit": false,
			"target_source": "none",
			"reason": "raycast_miss_render_mesh_fallback_disabled",
			"position": origin + direction * max_distance,
			"collider": "",
		}
	var backend := _terrain_backend_node()
	if backend == null:
		return {
			"ray_hit": false,
			"render_mesh_hit": false,
			"target_source": "none",
			"reason": "raycast_miss_backend_render_node_missing",
			"position": origin + direction * max_distance,
			"collider": "",
		}
	var report := {
		"hit": false,
		"distance": max_distance,
		"position": origin + direction * max_distance,
		"normal": Vector3.ZERO,
		"mesh_name": "",
		"instances_scanned": 0,
		"triangles_scanned": 0,
		"limited": false,
	}
	_collect_render_mesh_hit(backend, origin, direction, max_distance, report)
	if bool(report["hit"]):
		return {
			"ray_hit": false,
			"render_mesh_hit": true,
			"target_source": "render_mesh_fallback",
			"reason": "render_mesh_fallback_hit",
			"position": report["position"],
			"collider": str(report["mesh_name"]),
			"fallback_instances_scanned": int(report["instances_scanned"]),
			"fallback_triangles_scanned": int(report["triangles_scanned"]),
		}
	var reason := "raycast_miss_render_mesh_miss"
	if bool(report["limited"]):
		reason = "raycast_miss_render_mesh_scan_limited"
	return {
		"ray_hit": false,
		"render_mesh_hit": false,
		"target_source": "none",
		"reason": reason,
		"position": origin + direction * max_distance,
		"collider": "",
		"fallback_instances_scanned": int(report["instances_scanned"]),
		"fallback_triangles_scanned": int(report["triangles_scanned"]),
	}


func _terrain_backend_node() -> Node:
	if game_world == null:
		return null
	if game_world.has_method("get_terrain_world"):
		var terrain_world = game_world.call("get_terrain_world")
		if terrain_world != null and terrain_world.has_method("get_backend_terrain"):
			return terrain_world.call("get_backend_terrain")
	if game_world.has_method("get_reference_scene"):
		var reference_scene = game_world.call("get_reference_scene")
		if reference_scene != null and reference_scene.has_method("get_terrain_world"):
			var terrain_world = reference_scene.call("get_terrain_world")
			if terrain_world != null and terrain_world.has_method("get_backend_terrain"):
				return terrain_world.call("get_backend_terrain")
	return null


func _collect_render_mesh_hit(node: Node, origin: Vector3, direction: Vector3, max_distance: float, report: Dictionary) -> void:
	if bool(report.get("limited", false)):
		return
	if node is MeshInstance3D:
		if int(report["instances_scanned"]) >= render_mesh_fallback_max_instances:
			report["limited"] = true
			return
		report["instances_scanned"] = int(report["instances_scanned"]) + 1
		_accumulate_render_mesh_hit(node as MeshInstance3D, origin, direction, max_distance, report)
	for child in node.get_children():
		if bool(report.get("limited", false)):
			return
		if child is Node:
			_collect_render_mesh_hit(child, origin, direction, max_distance, report)


func _accumulate_render_mesh_hit(instance: MeshInstance3D, origin: Vector3, direction: Vector3, max_distance: float, report: Dictionary) -> void:
	var mesh := instance.mesh
	if mesh == null or not (mesh is ArrayMesh):
		return
	var array_mesh := mesh as ArrayMesh
	var world_aabb: AABB = instance.global_transform * array_mesh.get_aabb()
	if not _ray_intersects_aabb(origin, direction, world_aabb.grow(0.25), max_distance):
		return
	for surface_index in range(array_mesh.get_surface_count()):
		var arrays: Array = array_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		if arrays.size() > Mesh.ARRAY_INDEX and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var index := 0
			while index + 2 < indices.size():
				if int(report["triangles_scanned"]) >= render_mesh_fallback_max_triangles:
					report["limited"] = true
					return
				_accumulate_render_triangle(
					instance,
					vertices[int(indices[index])],
					vertices[int(indices[index + 1])],
					vertices[int(indices[index + 2])],
					origin,
					direction,
					report
				)
				report["triangles_scanned"] = int(report["triangles_scanned"]) + 1
				index += 3
		else:
			var index := 0
			while index + 2 < vertices.size():
				if int(report["triangles_scanned"]) >= render_mesh_fallback_max_triangles:
					report["limited"] = true
					return
				_accumulate_render_triangle(
					instance,
					vertices[index],
					vertices[index + 1],
					vertices[index + 2],
					origin,
					direction,
					report
				)
				report["triangles_scanned"] = int(report["triangles_scanned"]) + 1
				index += 3


func _accumulate_render_triangle(
	instance: MeshInstance3D,
	local_a: Vector3,
	local_b: Vector3,
	local_c: Vector3,
	origin: Vector3,
	direction: Vector3,
	report: Dictionary
) -> void:
	var a := instance.global_transform * local_a
	var b := instance.global_transform * local_b
	var c := instance.global_transform * local_c
	var hit := _ray_triangle_intersection(origin, direction, a, b, c, float(report["distance"]))
	if hit.is_empty():
		return
	report["hit"] = true
	report["distance"] = float(hit["distance"])
	report["position"] = hit["position"]
	report["normal"] = hit["normal"]
	report["mesh_name"] = str(instance.name)


func _ray_triangle_intersection(
	origin: Vector3,
	direction: Vector3,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	max_distance: float
) -> Dictionary:
	var edge1 := b - a
	var edge2 := c - a
	var h := direction.cross(edge2)
	var determinant := edge1.dot(h)
	if absf(determinant) < 0.000001:
		return {}
	var inverse_determinant := 1.0 / determinant
	var s := origin - a
	var u := inverse_determinant * s.dot(h)
	if u < 0.0 or u > 1.0:
		return {}
	var q := s.cross(edge1)
	var v := inverse_determinant * direction.dot(q)
	if v < 0.0 or u + v > 1.0:
		return {}
	var distance := inverse_determinant * edge2.dot(q)
	if distance <= 0.0001 or distance > max_distance:
		return {}
	var normal := edge1.cross(edge2)
	if normal.length_squared() > 0.000001:
		normal = normal.normalized()
	return {
		"distance": distance,
		"position": origin + direction * distance,
		"normal": normal,
	}


func _ray_intersects_aabb(origin: Vector3, direction: Vector3, aabb: AABB, max_distance: float) -> bool:
	var t_min := 0.0
	var t_max := max_distance
	for axis in range(3):
		var origin_component := origin[axis]
		var direction_component := direction[axis]
		var minimum := aabb.position[axis]
		var maximum := minimum + aabb.size[axis]
		if absf(direction_component) < 0.000001:
			if origin_component < minimum or origin_component > maximum:
				return false
			continue
		var inverse := 1.0 / direction_component
		var near := (minimum - origin_component) * inverse
		var far := (maximum - origin_component) * inverse
		if near > far:
			var swap := near
			near = far
			far = swap
		t_min = maxf(t_min, near)
		t_max = minf(t_max, far)
		if t_min > t_max:
			return false
	return true


func _record_interaction(
	mode_name: StringName,
	ray_hit: bool,
	accepted: bool,
	reason: String,
	position: Vector3
) -> void:
	_interaction_attempt_count += 1
	_last_interaction_summary = {
		"attempt": _interaction_attempt_count,
		"mode": str(mode_name),
		"ray_hit": ray_hit,
		"accepted": accepted,
		"reason": reason,
		"position": position,
		"selected_material_id": _selected_place_material_id(),
		"selected_material_name": _selected_place_material_name(),
	}


func _set_fly_mode_enabled(enabled: bool) -> void:
	if fly_mode_enabled == enabled:
		return
	fly_mode_enabled = enabled
	human_command_armed = false
	velocity = Vector3.ZERO
	if enabled:
		_walk_collision_layer = collision_layer
		_walk_collision_mask = collision_mask
		_walk_motion_mode = motion_mode
		_walk_collision_state_saved = true
		motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	else:
		if _walk_collision_state_saved:
			collision_layer = _walk_collision_layer
			collision_mask = _walk_collision_mask
			motion_mode = _walk_motion_mode
			_walk_collision_state_saved = false
		if game_world != null and game_world.has_method("update_player_viewer"):
			game_world.call("update_player_viewer", true)
	print("human_fly_mode=%s" % ("on" if fly_mode_enabled else "off"))


func _forward_human_command(command: StringName) -> bool:
	if human_command_target == null or not human_command_target.has_method("handle_human_command"):
		return false
	return bool(human_command_target.call("handle_human_command", command))


func _selected_place_material_id() -> int:
	return int(PLACE_MATERIAL_IDS[clampi(selected_place_material_index, 0, PLACE_MATERIAL_IDS.size() - 1)])


func _selected_place_material_name() -> String:
	return str(PLACE_MATERIAL_NAMES[clampi(selected_place_material_index, 0, PLACE_MATERIAL_NAMES.size() - 1)])


func _set_selected_place_material_index(slot_index: int) -> void:
	selected_place_material_index = clampi(slot_index, 0, PLACE_MATERIAL_IDS.size() - 1)
	print("human_place_material=%d:%s" % [_selected_place_material_id(), _selected_place_material_name()])


func _material_slot_from_key(event: InputEventKey) -> int:
	var code := event.keycode
	if code == KEY_NONE:
		code = event.physical_keycode
	match code:
		KEY_1, KEY_KP_1:
			return 0
		KEY_2, KEY_KP_2:
			return 1
		KEY_3, KEY_KP_3:
			return 2
		KEY_4, KEY_KP_4:
			return 3
		KEY_5, KEY_KP_5:
			return 4
		KEY_6, KEY_KP_6:
			return 5
		KEY_7, KEY_KP_7:
			return 6
		KEY_8, KEY_KP_8:
			return 7
		_:
			return -1


func _is_human_command_prefix(event: InputEventKey) -> bool:
	return event.unicode == 96 or event.unicode == 126 or \
			event.keycode == 96 or event.keycode == 126 or \
			event.physical_keycode == 96 or event.physical_keycode == 126
