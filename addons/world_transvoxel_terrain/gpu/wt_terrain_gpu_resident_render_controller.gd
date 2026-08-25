@tool
extends Node
class_name WtTerrainGpuResidentRenderController

const GlobalRenderEffect := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_effect.gd"
)
const REQUIRED_BACKEND_METHODS := [
	"begin_gpu_resident_render_publication",
	"end_gpu_resident_render_publication",
	"pop_gpu_resident_render_request",
	"validate_gpu_resident_render_request",
	"get_gpu_resident_render_chunk_readiness",
	"reject_gpu_resident_render_request",
	"set_gpu_resident_render_chunk_active",
	"reconcile_gpu_resident_render_chunks",
	"get_gpu_resident_render_metrics",
	"get_render_material_override",
	"get_water_material_override",
]
const PRODUCTION_TERRAIN_SHADER := (
	"res://addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader"
)
const PRODUCTION_WATER_SHADER := (
	"res://addons/world_transvoxel_gameworld/material/wt_game_static_water.gdshader"
)
const PRODUCTION_DEFAULT_ROAD_GRADES := [
	Vector2(34.0, 39.0),
	Vector2(39.0, 40.0),
	Vector2(46.0, 39.0),
	Vector2(39.0, 34.0),
	Vector2(34.0, 33.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
	Vector2(34.0, 34.0),
]
const APPLICATION_WAIT_FRAME_LIMIT := 180
const APPLICATION_WAIT_RETRY_FRAMES := 3
const RENDER_SUBMISSION_CAPACITY := 3

var _backend_terrain: Node
var _world_environment: WorldEnvironment
var _previous_compositor: Compositor
var _compositor: Compositor
var _effect
var _groups: Dictionary = {}
var _render_request_routes: Dictionary = {}
var _entry_routes: Dictionary = {}
var _running := false
var _native_request_capacity := 16
var _resident_capacity := 64
var _next_publication_sequence := 1
var _last_error := ""
var _submitted_surfaces := 0
var _validated_surfaces := 0
var _activated_chunks := 0
var _retired_chunks := 0
var _rejected_chunks := 0
var _superseded_chunks := 0
var _recovery_count := 0
var _application_wait_expirations := 0
var _process_frame := 0
var _production_material_signature := ""
var _production_water_signature := ""


func _ready() -> void:
	set_process(false)


func start(
	backend_terrain: Node,
	world_environment: WorldEnvironment,
	native_request_capacity: int = 16,
	resident_capacity: int = 64
) -> bool:
	if _running:
		return true
	if backend_terrain == null or world_environment == null:
		_last_error = "native terrain backend and WorldEnvironment are required"
		return false
	for method_name in REQUIRED_BACKEND_METHODS:
		if not backend_terrain.has_method(method_name):
			_last_error = "native terrain backend lacks %s" % method_name
			return false
	_native_request_capacity = clampi(native_request_capacity, 1, 16)
	_resident_capacity = clampi(resident_capacity, 1, 256)
	_effect = GlobalRenderEffect.new()
	if not _effect.configure_resident_capacity(_resident_capacity):
		_last_error = str(_effect.get_status().get(
			"last_error", "global render effect rejected resident capacity"
		))
		_effect = null
		return false
	_previous_compositor = world_environment.compositor
	_compositor = Compositor.new()
	var effects: Array[CompositorEffect] = []
	if _previous_compositor != null:
		for existing in _previous_compositor.compositor_effects:
			if existing != null:
				effects.append(existing)
	effects.append(_effect)
	_compositor.compositor_effects = effects
	world_environment.compositor = _compositor
	if not bool(backend_terrain.call(
		"begin_gpu_resident_render_publication", _native_request_capacity
	)):
		world_environment.compositor = _previous_compositor
		_effect.close()
		_effect = null
		_compositor = null
		_previous_compositor = null
		_last_error = "native terrain backend rejected resident publication"
		return false
	_backend_terrain = backend_terrain
	_world_environment = world_environment
	_groups.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_running = true
	_last_error = ""
	set_process(true)
	return true


func stop() -> void:
	set_process(false)
	if not _running and _effect == null:
		return
	_running = false
	_restore_cpu_and_release_native_requests()
	if _backend_terrain != null and is_instance_valid(_backend_terrain):
		_backend_terrain.call("end_gpu_resident_render_publication")
	if _world_environment != null and is_instance_valid(_world_environment) \
			and _world_environment.compositor == _compositor:
		_world_environment.compositor = _previous_compositor
	if _effect != null:
		_effect.close()
	_groups.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_backend_terrain = null
	_world_environment = null
	_previous_compositor = null
	_compositor = null
	_effect = null


func is_running() -> bool:
	return _running


func get_status() -> Dictionary:
	var native_metrics := {}
	var effect_status := {}
	if _backend_terrain != null and is_instance_valid(_backend_terrain):
		native_metrics = Dictionary(_backend_terrain.call(
			"get_gpu_resident_render_metrics"
		))
	if _effect != null:
		effect_status = _effect.get_status()
	var active_groups := 0
	for group_value in _groups.values():
		if bool(Dictionary(group_value).get("active", false)):
			active_groups += 1
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_render_controller.v1",
		"running": _running,
		"native_request_capacity": _native_request_capacity,
		"render_submission_capacity": RENDER_SUBMISSION_CAPACITY,
		"resident_capacity": _resident_capacity,
		"tracked_chunks": _groups.size(),
		"active_chunks": active_groups,
		"submitted_surfaces": _submitted_surfaces,
		"validated_surfaces": _validated_surfaces,
		"activated_chunks": _activated_chunks,
		"retired_chunks": _retired_chunks,
		"rejected_chunks": _rejected_chunks,
		"superseded_chunks": _superseded_chunks,
		"recovery_count": _recovery_count,
		"application_wait_expirations": _application_wait_expirations,
		"last_error": _last_error,
		"native_metrics": native_metrics,
		"effect_status": effect_status,
		"default_backend_unchanged": true,
		"gpu_resident_render_publication": true,
		"production_chunk_replacement": true,
		"native_request_handoff_decoupled": true,
		"native_position_space": "world",
		"cpu_collision_authority": true,
		"atomic_surface_set_activation": true,
		"production_material_parity": false,
		"production_terrain_material_payload_ready": bool(effect_status.get(
			"production_terrain_material_payload_ready", false
		)),
		"production_terrain_albedo_mapping_parity": bool(effect_status.get(
			"production_terrain_albedo_mapping_parity", false
		)),
		"production_terrain_roughness_mapping_parity": bool(effect_status.get(
			"production_terrain_roughness_mapping_parity", false
		)),
		"production_terrain_accepted_normal_response_parity": bool(effect_status.get(
			"production_terrain_accepted_normal_response_parity", false
		)),
		"production_terrain_bounded_pbr_response_parity": bool(effect_status.get(
			"production_terrain_bounded_pbr_response_parity", false
		)),
		"production_terrain_normal_mapping_parity": bool(effect_status.get(
			"production_terrain_normal_mapping_parity", false
		)),
		"production_terrain_pbr_lighting_parity": bool(effect_status.get(
			"production_terrain_pbr_lighting_parity", false
		)),
		"production_terrain_material_parity": bool(effect_status.get(
			"production_terrain_material_parity", false
		)),
		"production_static_water_material_parity": bool(effect_status.get(
			"production_static_water_material_parity", false
		)),
		"production_static_water_material_payload_ready": bool(effect_status.get(
			"production_static_water_material_payload_ready", false
		)),
		"production_static_water_fresnel_tint_parity": bool(effect_status.get(
			"production_static_water_fresnel_tint_parity", false
		)),
		"production_static_water_refraction_parity": bool(effect_status.get(
			"production_static_water_refraction_parity", false
		)),
		"production_material_source": str(effect_status.get(
			"production_material_source", ""
		)),
		"production_material_parameter_bytes": int(effect_status.get(
			"production_material_parameter_bytes", 0
		)),
		"production_material_texture_count": int(effect_status.get(
			"production_material_texture_count", 0
		)),
		"production_water_material_source": str(effect_status.get(
			"production_water_material_source", ""
		)),
		"production_water_parameter_bytes": int(effect_status.get(
			"production_water_parameter_bytes", 0
		)),
	}


func _process(_delta: float) -> void:
	if not _running or _backend_terrain == null or _effect == null:
		return
	_process_frame += 1
	_sync_production_materials()
	_drain_effect_events()
	_retry_prepared_groups()
	_reconcile_active_chunks()
	_submit_native_captures()
	var effect_status: Dictionary = _effect.get_status()
	if bool(effect_status.get("initialization_attempted", false)) \
			and not bool(effect_status.get("initialized", false)) \
			and not str(effect_status.get("last_error", "")).is_empty():
		_fail_closed(str(effect_status.get("last_error", "GPU renderer failed")))


func _sync_production_materials() -> void:
	_sync_production_terrain_material()
	_sync_production_water_material()


func _sync_production_terrain_material() -> void:
	if _effect == null or _backend_terrain == null:
		return
	var material_value = _backend_terrain.call("get_render_material_override")
	if not material_value is ShaderMaterial:
		return
	var material := material_value as ShaderMaterial
	if material.shader == null \
			or material.shader.resource_path != PRODUCTION_TERRAIN_SHADER:
		return
	var config := _production_material_config(material)
	var signature := str(config.get("signature", ""))
	if signature.is_empty() or signature == _production_material_signature:
		return
	if _effect.configure_production_terrain_material(config):
		_production_material_signature = signature


func _sync_production_water_material() -> void:
	if _effect == null or _backend_terrain == null:
		return
	var material_value = _backend_terrain.call("get_water_material_override")
	if not material_value is ShaderMaterial:
		return
	var material := material_value as ShaderMaterial
	if material.shader == null or material.shader.resource_path != PRODUCTION_WATER_SHADER:
		return
	var deep_color = material.get_shader_parameter("deep_color")
	var edge_color = material.get_shader_parameter("edge_color")
	if not deep_color is Color:
		deep_color = Color(0.015, 0.14, 0.20, 1.0)
	if not edge_color is Color:
		edge_color = Color(0.08, 0.38, 0.46, 1.0)
	var deep_tint = material.get_shader_parameter("deep_tint")
	var edge_tint = material.get_shader_parameter("edge_tint")
	var refraction_strength = material.get_shader_parameter("refraction_strength")
	var values := PackedFloat32Array()
	_append_vec4(values, Vector4(deep_color.r, deep_color.g, deep_color.b, 1.0))
	_append_vec4(values, Vector4(edge_color.r, edge_color.g, edge_color.b, 1.0))
	_append_vec4(values, Vector4(
		float(deep_tint) if deep_tint is float else 0.34,
		float(edge_tint) if edge_tint is float else 0.52,
		float(refraction_strength) if refraction_strength is float else 0.008,
		0.0
	))
	var parameter_bytes := values.to_byte_array()
	var signature := "%s:%s" % [
		str(material.get_instance_id()), parameter_bytes.hex_encode()
	]
	if signature == _production_water_signature:
		return
	if _effect.configure_production_static_water_material({
		"source": PRODUCTION_WATER_SHADER,
		"parameter_bytes": parameter_bytes,
		"resource": material,
	}):
		_production_water_signature = signature


func _production_material_config(material: ShaderMaterial) -> Dictionary:
	var texture_names := [
		"checker_texture",
		"terrain_albedo_array",
		"terrain_normal_array",
		"terrain_roughness_array",
		"clean_albedo_texture",
	]
	var resources: Array = []
	var texture_rids: Array[RID] = []
	for index in range(texture_names.size()):
		var texture = material.get_shader_parameter(texture_names[index])
		if texture == null and texture_names[index] == "clean_albedo_texture":
			texture = material.get_shader_parameter("checker_texture")
		if not texture is Texture:
			return {}
		var rd_texture := RenderingServer.texture_get_rd_texture(
			texture.get_rid(), index in [0, 1, 4]
		)
		if not rd_texture.is_valid():
			return {}
		resources.append(texture)
		texture_rids.append(rd_texture)
	var values := PackedFloat32Array()
	_append_vec4(values, Vector4(
		1.0 if bool(material.get_shader_parameter(
			"procedural_ore_worldspace_blend_enabled"
		)) else 0.0,
		1.0 if bool(material.get_shader_parameter(
			"procedural_rolling_exterior_surface_enabled"
		)) else 0.0,
		1.0 if bool(material.get_shader_parameter(
			"procedural_road_worldspace_blend_enabled"
		)) else 0.0,
		1.0 if bool(material.get_shader_parameter(
			"procedural_four_biome_world_enabled"
		)) else 0.0
	))
	_append_vec4(values, Vector4(
		float(material.get_shader_parameter("procedural_seed_phase")),
		float(material.get_shader_parameter("procedural_ore_blend_width")),
		float(material.get_shader_parameter("procedural_road_half_width")),
		float(material.get_shader_parameter("procedural_road_shoulder_width"))
	))
	_append_vec4(values, Vector4(
		float(material.get_shader_parameter("procedural_surface_cover_full_depth")),
		float(material.get_shader_parameter("procedural_surface_cover_fade_depth")),
		float(material.get_shader_parameter("procedural_surface_cover_normal_start")),
		float(material.get_shader_parameter("procedural_surface_cover_normal_end"))
	))
	_append_vec4(values, Vector4(
		float(material.get_shader_parameter(
			"procedural_surface_biome_height_blend_width"
		)),
		float(material.get_shader_parameter(
			"procedural_surface_biome_noise_blend_width"
		)),
		0.0,
		0.0
	))
	var world_size: Vector2 = material.get_shader_parameter(
		"procedural_world_size_xz"
	)
	_append_vec4(values, Vector4(world_size.x, world_size.y, 0.0, 0.0))
	for index in range(18):
		var grade_value = material.get_shader_parameter(
			"procedural_road_grade_%d" % index
		)
		var grade: Vector2 = grade_value \
			if grade_value is Vector2 else PRODUCTION_DEFAULT_ROAD_GRADES[index]
		_append_vec4(values, Vector4(grade.x, grade.y, 0.0, 0.0))
	var parameter_bytes := values.to_byte_array()
	var signature_parts := [str(material.get_instance_id()), parameter_bytes.hex_encode()]
	for texture in resources:
		signature_parts.append(str(texture.get_instance_id()))
	return {
		"source": PRODUCTION_TERRAIN_SHADER,
		"parameter_bytes": parameter_bytes,
		"texture_rids": texture_rids,
		"resources": resources,
		"signature": ":".join(signature_parts),
	}


static func _append_vec4(values: PackedFloat32Array, value: Vector4) -> void:
	values.append(value.x)
	values.append(value.y)
	values.append(value.z)
	values.append(value.w)


func _submit_native_captures() -> void:
	while _render_request_routes.size() < RENDER_SUBMISSION_CAPACITY:
		var request := Dictionary(_backend_terrain.call(
			"pop_gpu_resident_render_request"
		))
		var request_status := str(request.get("status", ""))
		if request_status in ["EMPTY", "DISABLED"]:
			return
		var request_error := _validate_native_request(request)
		if not request_error.is_empty():
			_reject_native_request(request, request_error)
			continue
		var identity: Dictionary = request.get("identity", {})
		var group_key := _group_key(identity)
		if not _groups.has(group_key) and _groups.size() >= _resident_capacity:
			_reject_native_request(request, "resident chunk capacity reached")
			continue
		var surface := str(identity.get("surface", ""))
		var group: Dictionary = _groups.get(group_key, _new_group(identity))
		if Dictionary(group.get("requests", {})).has(surface):
			_reject_native_request(request, "duplicate resident chunk surface")
			continue
		var sequence := _next_publication_sequence
		_next_publication_sequence += 1
		var render_request_id := int(_effect.submit_native_packed_input(
			Array(request.get("gpu_input_buffers", [])),
			int(request.get("cell_count", 0)),
			identity,
			sequence,
			false,
			request.get("bounds_min", Vector3.ZERO),
			request.get("bounds_max", Vector3.ZERO)
		))
		if render_request_id <= 0:
			_reject_native_request(request, str(_effect.get_status().get(
				"last_error", "global renderer rejected resident surface"
			)))
			continue
		var requests: Dictionary = group.get("requests", {})
		var sequences: Dictionary = group.get("sequences", {})
		requests[surface] = {
			"request_id": int(request.get("request_id", 0)),
			"identity": identity.duplicate(true),
		}
		sequences[surface] = sequence
		group["requests"] = requests
		group["sequences"] = sequences
		_groups[group_key] = group
		var route := {"group_key": group_key, "surface": surface}
		_render_request_routes[render_request_id] = route
		_entry_routes[_entry_token(identity, sequence)] = route
		_submitted_surfaces += 1


func _drain_effect_events() -> void:
	while true:
		var event: Dictionary = _effect.pop_event()
		if event.is_empty():
			return
		var route := _route_for_event(event)
		if route.is_empty():
			continue
		var group_key := str(route.get("group_key", ""))
		if not _groups.has(group_key):
			continue
		match str(event.get("status", "")):
			"PREPARED":
				_mark_surface(group_key, "prepared", str(route.get("surface", "")))
				_try_validate_group(group_key)
			"ACTIVE":
				_mark_surface(group_key, "activated", str(route.get("surface", "")))
				_try_activate_chunk(group_key)
			"REJECTED":
				_reject_group(group_key, str(event.get("error", "GPU entry rejected")))
			"RETIRED", "SUPERSEDED":
				_mark_surface(group_key, "retired", str(route.get("surface", "")))
				_try_finish_retirement(group_key)


func _try_validate_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("validated", false)) or not _surface_set_complete(
		group, "prepared"
	):
		return
	if _process_frame < int(group.get("next_validation_frame", 0)):
		return
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		if bool(Dictionary(group.get("native_validated", {})).get(surface, false)):
			continue
		var request: Dictionary = requests.get(surface, {})
		var validation := Dictionary(_backend_terrain.call(
			"validate_gpu_resident_render_request",
			int(request.get("request_id", 0)),
			Dictionary(request.get("identity", {}))
		))
		var validation_status := str(validation.get("status", ""))
		if validation_status.begins_with("STALE"):
			var stale_validated: Dictionary = group.get("native_validated", {})
			stale_validated[surface] = true
			group["native_validated"] = stale_validated
			_groups[group_key] = group
			_supersede_group(group_key)
			return
		if bool(validation.get("request_accepted", false)):
			var native_validated: Dictionary = group.get("native_validated", {})
			native_validated[surface] = true
			group["native_validated"] = native_validated
			_groups[group_key] = group
			_validated_surfaces += 1
		if validation_status not in ["READY", "WAITING_APPLICATION"]:
			_reject_group(group_key, str(validation.get(
				"error", "native resident admission rejected the chunk"
			)))
			return
	if not _surface_set_complete(group, "native_validated"):
		return
	var terrain_request: Dictionary = requests.get("terrain", {})
	var readiness := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_chunk_readiness",
		Dictionary(terrain_request.get("identity", {}))
	))
	if str(readiness.get("status", "")) == "WAITING_APPLICATION":
		var wait_started := int(group.get(
			"application_wait_started_frame", -1
		))
		if wait_started < 0:
			wait_started = _process_frame
		group["application_wait_started_frame"] = wait_started
		group["next_validation_frame"] = (
			_process_frame + APPLICATION_WAIT_RETRY_FRAMES
		)
		_groups[group_key] = group
		if _process_frame - wait_started >= APPLICATION_WAIT_FRAME_LIMIT:
			_application_wait_expirations += 1
			_reject_group(
				group_key,
				"GPU resident CPU-application wait expired"
			)
		return
	if str(readiness.get("status", "")) != "READY" \
			or not bool(readiness.get("ready", false)):
		if str(readiness.get("status", "")).begins_with("STALE"):
			_supersede_group(group_key)
			return
		_reject_group(group_key, str(readiness.get(
			"error", "native resident chunk readiness rejected the chunk"
		)))
		return
	group["validated"] = true
	_groups[group_key] = group
	var sequences: Dictionary = group.get("sequences", {})
	var activation_entries: Array[Dictionary] = []
	for surface in _required_surfaces(group):
		var request: Dictionary = requests.get(surface, {})
		activation_entries.append({
			"identity": Dictionary(request.get("identity", {})),
			"publication_sequence": int(sequences.get(surface, 0)),
		})
	if not _effect.activate_entries(activation_entries):
		_reject_group(group_key, "global renderer rejected chunk activation set")


func _retry_prepared_groups() -> void:
	var group_keys := _groups.keys()
	for group_key_value in group_keys:
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		if not bool(group.get("validated", false)) \
				and not bool(group.get("retiring", false)):
			_try_validate_group(group_key)


func _try_activate_chunk(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("active", false)) or not _surface_set_complete(
		group, "activated"
	):
		return
	var activation := Dictionary(_backend_terrain.call(
		"set_gpu_resident_render_chunk_active", _group_identities(group), true
	))
	if str(activation.get("status", "")) != "ACTIVE" \
			or not bool(activation.get("active", false)):
		if str(activation.get("status", "")).begins_with("STALE"):
			_supersede_group(group_key)
			return
		_reject_group(group_key, str(activation.get(
			"error", "native chunk activation became stale"
		)))
		return
	group["active"] = true
	_groups[group_key] = group
	_activated_chunks += 1


func _reconcile_active_chunks() -> void:
	var terrain_identities: Array = []
	var group_by_identity: Dictionary = {}
	for group_key in _groups:
		var group: Dictionary = _groups[group_key]
		if not bool(group.get("active", false)):
			continue
		var terrain_identity: Dictionary = Dictionary(
			Dictionary(group.get("requests", {})).get("terrain", {})
		).get("identity", {})
		terrain_identities.append(terrain_identity)
		group_by_identity[_group_key(terrain_identity)] = group_key
	if terrain_identities.is_empty():
		return
	var reconciliation := Dictionary(_backend_terrain.call(
		"reconcile_gpu_resident_render_chunks", terrain_identities
	))
	if str(reconciliation.get("status", "")) != "PASS":
		_fail_closed("native resident reconciliation failed")
		return
	for identity_value in Array(reconciliation.get("retire", [])):
		var identity := Dictionary(identity_value)
		var group_key := str(group_by_identity.get(_group_key(identity), ""))
		if not group_key.is_empty():
			_begin_group_retirement(group_key)


func _reject_group(group_key: String, error: String) -> void:
	if not _groups.has(group_key):
		return
	_last_error = error
	_rejected_chunks += 1
	var group: Dictionary = _groups[group_key]
	if not bool(group.get("validated", false)):
		var native_validated: Dictionary = group.get("native_validated", {})
		for surface in Dictionary(group.get("requests", {})):
			if bool(native_validated.get(surface, false)):
				continue
			var request_value = Dictionary(group.get("requests", {}))[surface]
			var request := Dictionary(request_value)
			_reject_native_request(request, error)
	_begin_group_retirement(group_key)


func _supersede_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	_superseded_chunks += 1
	var group: Dictionary = _groups[group_key]
	var native_validated: Dictionary = group.get("native_validated", {})
	for surface in Dictionary(group.get("requests", {})):
		if bool(native_validated.get(surface, false)):
			continue
		var request := Dictionary(Dictionary(group.get("requests", {}))[surface])
		_backend_terrain.call(
			"validate_gpu_resident_render_request",
			int(request.get("request_id", 0)),
			Dictionary(request.get("identity", {}))
		)
	_begin_group_retirement(group_key)


func _begin_group_retirement(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)):
		return
	group["retiring"] = true
	_groups[group_key] = group
	var requests: Dictionary = group.get("requests", {})
	var sequences: Dictionary = group.get("sequences", {})
	for surface in requests:
		var identity: Dictionary = Dictionary(requests[surface]).get("identity", {})
		_effect.retire_entry(identity, int(sequences.get(surface, 0)))
	if requests.is_empty():
		_try_finish_retirement(group_key)


func _try_finish_retirement(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if not _surface_set_complete(group, "retired", false):
		return
	if bool(group.get("active", false)):
		_backend_terrain.call(
			"set_gpu_resident_render_chunk_active", _group_identities(group), false
		)
		_retired_chunks += 1
	_cleanup_group(group_key)


func _restore_cpu_and_release_native_requests() -> void:
	if _backend_terrain == null or not is_instance_valid(_backend_terrain):
		return
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if bool(group.get("active", false)):
			_backend_terrain.call(
				"set_gpu_resident_render_chunk_active", _group_identities(group), false
			)
		elif not bool(group.get("validated", false)):
			var native_validated: Dictionary = group.get("native_validated", {})
			for surface in Dictionary(group.get("requests", {})):
				if bool(native_validated.get(surface, false)):
					continue
				var request_value = Dictionary(group.get("requests", {}))[surface]
				_reject_native_request(Dictionary(request_value), "resident renderer stopped")


func _fail_closed(error: String) -> void:
	_last_error = error
	_recovery_count += 1
	stop()


func _reject_native_request(request: Dictionary, error: String) -> void:
	if request.is_empty() or _backend_terrain == null:
		return
	_backend_terrain.call(
		"reject_gpu_resident_render_request",
		int(request.get("request_id", 0)),
		Dictionary(request.get("identity", {})),
		error
	)


func _cleanup_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	for request_value in Dictionary(group.get("requests", {})).values():
		var request := Dictionary(request_value)
		var identity: Dictionary = request.get("identity", {})
		var surface := str(identity.get("surface", ""))
		var sequence := int(Dictionary(group.get("sequences", {})).get(surface, 0))
		_entry_routes.erase(_entry_token(identity, sequence))
	var render_request_ids := _render_request_routes.keys()
	for render_request_id in render_request_ids:
		if str(Dictionary(_render_request_routes[render_request_id]).get(
			"group_key", ""
		)) == group_key:
			_render_request_routes.erase(render_request_id)
	_groups.erase(group_key)


func _route_for_event(event: Dictionary) -> Dictionary:
	var request_id := int(event.get("request_id", 0))
	if request_id > 0 and _render_request_routes.has(request_id):
		var route: Dictionary = _render_request_routes[request_id]
		_render_request_routes.erase(request_id)
		return route
	return Dictionary(_entry_routes.get(_entry_token(
		Dictionary(event.get("identity", {})),
		int(event.get("publication_sequence", 0))
	), {}))


func _mark_surface(group_key: String, field: String, surface: String) -> void:
	var group: Dictionary = _groups[group_key]
	var values: Dictionary = group.get(field, {})
	values[surface] = true
	group[field] = values
	_groups[group_key] = group


func _surface_set_complete(
	group: Dictionary, field: String, require_expected: bool = true
) -> bool:
	var values: Dictionary = group.get(field, {})
	var surfaces: Array = _required_surfaces(group) if require_expected \
		else Dictionary(group.get("requests", {})).keys()
	for surface in surfaces:
		if not bool(values.get(surface, false)):
			return false
	return true


func _group_identities(group: Dictionary) -> Array:
	var identities: Array = []
	var requests: Dictionary = group.get("requests", {})
	for surface in _required_surfaces(group):
		identities.append(Dictionary(requests.get(surface, {})).get("identity", {}))
	return identities


static func _new_group(identity: Dictionary) -> Dictionary:
	return {
		"water_expected": bool(identity.get("static_water_surface_expected", false)),
		"requests": {},
		"sequences": {},
		"prepared": {},
		"activated": {},
		"retired": {},
		"native_validated": {},
		"validated": false,
		"active": false,
		"retiring": false,
		"application_wait_started_frame": -1,
		"next_validation_frame": 0,
	}


static func _required_surfaces(group: Dictionary) -> Array[String]:
	return ["terrain", "static_water"] if bool(group.get(
		"water_expected", false
	)) else ["terrain"]


static func _validate_native_request(request: Dictionary) -> String:
	if str(request.get("schema", "")) \
			!= "world_transvoxel.gpu_resident_render_request.v3" \
			or str(request.get("status", "")) != "PASS":
		return "native GPU resident request contract failed"
	if str(request.get("position_space", "")) != "world":
		return "native GPU resident request is not in world position space"
	if not bool(request.get("gpu_resident_render_publication", false)) \
			or not bool(request.get("cpu_render_visible_until_activation", false)) \
			or not bool(request.get("cpu_collision_publication_unchanged", false)) \
			or not bool(request.get("native_input_packing", false)) \
			or bool(request.get("cell_batch_exported", true)) \
			or bool(request.get("fallback_used", true)):
		return "native GPU resident request changed publication authority"
	var input_buffers := Array(request.get("gpu_input_buffers", []))
	if input_buffers.size() != 13 or int(request.get("cell_count", 0)) <= 0:
		return "native GPU resident input inventory is invalid"
	var actual_bytes := 0
	for buffer_value in input_buffers:
		if not buffer_value is PackedByteArray \
				or PackedByteArray(buffer_value).is_empty():
			return "native GPU resident input buffer is invalid"
		actual_bytes += PackedByteArray(buffer_value).size()
	if actual_bytes != int(request.get("packed_byte_count", -1)):
		return "native GPU resident packed byte count is invalid"
	var bounds_min_value = request.get("bounds_min", null)
	var bounds_max_value = request.get("bounds_max", null)
	if not bounds_min_value is Vector3 or not bounds_max_value is Vector3:
		return "native GPU resident bounds are missing"
	var bounds_min: Vector3 = bounds_min_value
	var bounds_max: Vector3 = bounds_max_value
	if not bounds_min.is_finite() or not bounds_max.is_finite() \
			or bounds_min.x > bounds_max.x or bounds_min.y > bounds_max.y \
			or bounds_min.z > bounds_max.z:
		return "native GPU resident bounds are invalid"
	return ""


static func _group_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d:g%d:s%d:w%d:t%d" % [
		int(identity.get("page_x", 0)),
		int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)),
		int(identity.get("lod", 0)),
		int(identity.get("generation", 0)),
		int(identity.get("source_revision", 0)),
		int(identity.get("world_revision", 0)),
		int(identity.get("transition_mask", 0)),
	]


static func _entry_token(identity: Dictionary, sequence: int) -> String:
	return "%s:%s@%d" % [
		str(identity.get("surface", "")), _group_key(identity), sequence
	]
