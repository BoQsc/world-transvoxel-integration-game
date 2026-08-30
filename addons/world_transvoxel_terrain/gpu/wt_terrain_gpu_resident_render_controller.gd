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
	"prepare_gpu_resident_render_chunk",
	"get_gpu_resident_render_activation_cohort",
	"activate_gpu_resident_render_cohort",
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
const RENDER_SUBMISSION_CAPACITY := 16
const NATIVE_SUBMISSIONS_PER_FRAME := 4
const ACTIVATION_COHORT_RETRY_CAPACITY := 8
const LIFECYCLE_HISTORY_CAPACITY := 512

var _backend_terrain: Node
var _world_environment: WorldEnvironment
var _directional_light: DirectionalLight3D
var _previous_compositor: Compositor
var _compositor: Compositor
var _effect
var _groups: Dictionary = {}
var _render_request_routes: Dictionary = {}
var _entry_routes: Dictionary = {}
var _prepared_group_routes: Dictionary = {}
var _activation_cohorts: Dictionary = {}
var _activation_retry_queue: Array[String] = []
var _activation_retry_membership: Dictionary = {}
var _running := false
var _native_request_capacity := 16
var _resident_capacity := 64
var _next_publication_sequence := 1
var _next_activation_cohort_id := 1
var _last_error := ""
var _submitted_surfaces := 0
var _validated_surfaces := 0
var _activated_chunks := 0
var _retired_chunks := 0
var _rejected_chunks := 0
var _rejection_reasons: Dictionary = {}
var _rejection_examples: Array = []
var _superseded_chunks := 0
var _recovery_count := 0
var _application_wait_expirations := 0
var _coverage_retained_reconciliation_deferrals := 0
var _retirement_confirmation_deferrals := 0
var _retirement_candidate_cancellations := 0
var _stale_incomplete_groups_superseded := 0
var _activation_cohorts_queued := 0
var _activation_cohorts_committed := 0
var _cpu_only_regional_retirements := 0
var _recent_lifecycle_events: Array[Dictionary] = []
var _lifecycle_history_enabled := OS.get_cmdline_user_args().has("--gpu-lifecycle-history")
var _activation_cohort_retry_attempts := 0
var _last_activation_cohort_wait: Dictionary = {}
var _stale_activation_cohorts_retained := 0
var _stale_activation_examples: Array = []
var _unrouted_effect_events := 0
var _unrouted_effect_event_examples: Array = []
var _process_frame := 0
var _production_material_signature := ""
var _production_water_signature := ""
var _stage_timing_enabled := OS.get_cmdline_user_args().has("--gpu-stage-timing")
var _stage_timing_usec: Dictionary = {}


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
	_resident_capacity = clampi(resident_capacity, 1, 4096)
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
	_directional_light = _resolve_directional_light()
	_groups.clear()
	_render_request_routes.clear()
	_entry_routes.clear()
	_prepared_group_routes.clear()
	_activation_cohorts.clear()
	_activation_retry_queue.clear()
	_activation_retry_membership.clear()
	_unrouted_effect_events = 0
	_unrouted_effect_event_examples.clear()
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
	_prepared_group_routes.clear()
	_activation_cohorts.clear()
	_activation_retry_queue.clear()
	_activation_retry_membership.clear()
	_backend_terrain = null
	_world_environment = null
	_directional_light = null
	_previous_compositor = null
	_compositor = null
	_effect = null


func is_running() -> bool:
	return _running


func is_chunk_generation_active(position: Vector3i, lod: int, generation: int) -> bool:
	if not _running or generation <= 0:
		return false
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if not bool(group.get("active", false)) or bool(group.get("retiring", false)):
			continue
		var request := Dictionary(Dictionary(group.get("requests", {})).get("terrain", {}))
		var identity := Dictionary(request.get("identity", {}))
		if int(identity.get("generation", -1)) == generation \
				and int(identity.get("lod", -1)) == lod \
				and int(identity.get("page_x", 0)) == position.x \
				and int(identity.get("page_y", 0)) == position.y \
				and int(identity.get("page_z", 0)) == position.z:
			return true
	return false


func set_debug_lifecycle_history_enabled(enabled: bool) -> void:
	_lifecycle_history_enabled = enabled
	if not enabled:
		_recent_lifecycle_events.clear()


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
	var incomplete_groups := 0
	var prepared_inactive_groups := 0
	var activation_queued_groups := 0
	var oldest_inactive_age_frames := 0
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if bool(group.get("active", false)):
			active_groups += 1
		elif not bool(group.get("retiring", false)):
			oldest_inactive_age_frames = maxi(
				oldest_inactive_age_frames,
				_process_frame - int(group.get("created_frame", _process_frame))
			)
			if bool(group.get("activation_queued", false)):
				activation_queued_groups += 1
			if _surface_set_complete(group, "prepared"):
				prepared_inactive_groups += 1
			else:
				incomplete_groups += 1
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_render_controller.v1",
		"running": _running,
		"stage_timing_enabled": _stage_timing_enabled,
		"stage_timing_usec": _stage_timing_usec.duplicate(true),
		"native_request_capacity": _native_request_capacity,
		"render_submission_capacity": RENDER_SUBMISSION_CAPACITY,
		"native_submissions_per_frame": NATIVE_SUBMISSIONS_PER_FRAME,
		"resident_capacity": _resident_capacity,
		"tracked_chunks": _groups.size(),
		"active_chunks": active_groups,
		"incomplete_chunks": incomplete_groups,
		"prepared_inactive_chunks": prepared_inactive_groups,
		"activation_queued_chunks": activation_queued_groups,
		"oldest_inactive_age_frames": oldest_inactive_age_frames,
		"inactive_chunk_examples": _inactive_group_examples(8),
		"submitted_surfaces": _submitted_surfaces,
		"validated_surfaces": _validated_surfaces,
		"activated_chunks": _activated_chunks,
		"retired_chunks": _retired_chunks,
		"rejected_chunks": _rejected_chunks,
		"rejection_reasons": _rejection_reasons.duplicate(true),
		"rejection_examples": _rejection_examples.duplicate(true),
		"superseded_chunks": _superseded_chunks,
		"recovery_count": _recovery_count,
		"application_wait_expirations": _application_wait_expirations,
		"coverage_retained_reconciliation_deferrals": (
			_coverage_retained_reconciliation_deferrals
		),
		"retirement_confirmation_deferrals": _retirement_confirmation_deferrals,
		"retirement_candidate_cancellations": _retirement_candidate_cancellations,
		"stale_incomplete_groups_superseded": (
			_stale_incomplete_groups_superseded
		),
		"activation_cohorts_queued": _activation_cohorts_queued,
		"activation_cohorts_committed": _activation_cohorts_committed,
		"cpu_only_regional_retirements": _cpu_only_regional_retirements,
		"lifecycle_history_enabled": _lifecycle_history_enabled,
		"recent_lifecycle_events": _recent_lifecycle_events.duplicate(true),
		"activation_cohort_retry_attempts": _activation_cohort_retry_attempts,
		"pending_activation_retry_groups": _activation_retry_membership.size(),
		"last_activation_cohort_wait": _last_activation_cohort_wait.duplicate(true),
		"stale_activation_cohorts_retained": _stale_activation_cohorts_retained,
		"stale_activation_examples": _stale_activation_examples.duplicate(true),
		"unrouted_effect_events": _unrouted_effect_events,
		"unrouted_effect_event_examples": (
			_unrouted_effect_event_examples.duplicate(true)
		),
		"pending_activation_cohorts": _activation_cohorts.size(),
		"last_error": _last_error,
		"native_metrics": native_metrics,
		"effect_status": effect_status,
		"default_backend_unchanged": true,
		"gpu_resident_render_publication": true,
		"production_chunk_replacement": true,
		"native_request_handoff_decoupled": true,
		"native_position_space": "world",
		"cpu_collision_authority": true,
		"gpu_page_lattice_input": bool(native_metrics.get(
			"gpu_page_lattice_input", false
		)),
		"atomic_surface_set_activation": true,
		"production_material_parity": bool(effect_status.get(
			"production_material_parity", false
		)),
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
		"production_terrain_directional_ambient_lighting_parity": bool(
			effect_status.get(
				"production_terrain_directional_ambient_lighting_parity", false
			)
		),
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
		"production_static_water_scene_copy_ready": bool(effect_status.get(
			"production_static_water_scene_copy_ready", false
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
	var phase_start := Time.get_ticks_usec() if _stage_timing_enabled else 0
	_sync_production_materials()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("materials", phase_start)
	if not _running:
		return
	_drain_effect_events()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("effect_events", phase_start)
	if not _running:
		return
	_supersede_stale_incomplete_groups()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("supersede", phase_start)
	if not _running:
		return
	_retry_prepared_groups()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("prepared_retry", phase_start)
	if not _running:
		return
	_drain_activation_cohort_retries()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("activation_retry", phase_start)
	if not _running:
		return
	_submit_native_captures()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("submit", phase_start)
	if not _running:
		return
	_reconcile_active_chunks()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("reconcile", phase_start)
	if not _running:
		return
	var effect_status: Dictionary = _effect.get_status()
	if _stage_timing_enabled:
		_record_stage_time("status", phase_start)
	if bool(effect_status.get("initialization_attempted", false)) \
			and not bool(effect_status.get("initialized", false)) \
			and not str(effect_status.get("last_error", "")).is_empty():
		_fail_closed(str(effect_status.get("last_error", "GPU renderer failed")))


func _record_stage_time(stage: String, start_us: int) -> int:
	var now := Time.get_ticks_usec()
	var elapsed := now - start_us
	var value := Dictionary(_stage_timing_usec.get(stage, {"calls": 0, "total": 0, "max": 0}))
	value["calls"] = int(value["calls"]) + 1
	value["total"] = int(value["total"]) + elapsed
	value["max"] = maxi(int(value["max"]), elapsed)
	_stage_timing_usec[stage] = value
	return now


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
	var deep_linear: Color = deep_color.srgb_to_linear()
	var edge_linear: Color = edge_color.srgb_to_linear()
	var deep_tint = material.get_shader_parameter("deep_tint")
	var edge_tint = material.get_shader_parameter("edge_tint")
	var refraction_strength = material.get_shader_parameter("refraction_strength")
	var values := PackedFloat32Array()
	_append_vec4(values, Vector4(
		deep_linear.r, deep_linear.g, deep_linear.b, 1.0
	))
	_append_vec4(values, Vector4(
		edge_linear.r, edge_linear.g, edge_linear.b, 1.0
	))
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
	var lighting := _production_scene_lighting()
	var ambient_color: Color = lighting.get("ambient_color", Color.BLACK)
	var directional_color: Color = lighting.get("directional_color", Color.BLACK)
	var directional_direction: Vector3 = lighting.get(
		"directional_direction", Vector3.UP
	)
	_append_vec4(values, Vector4(
		ambient_color.r,
		ambient_color.g,
		ambient_color.b,
		float(lighting.get("ambient_energy", 0.0))
	))
	_append_vec4(values, Vector4(
		directional_color.r,
		directional_color.g,
		directional_color.b,
		float(lighting.get("directional_energy", 0.0))
	))
	_append_vec4(values, Vector4(
		directional_direction.x,
		directional_direction.y,
		directional_direction.z,
		1.0 if bool(lighting.get("supported", false)) else 0.0
	))
	var parameter_bytes := values.to_byte_array()
	var signature_parts := [str(material.get_instance_id()), parameter_bytes.hex_encode()]
	for texture in resources:
		signature_parts.append(str(texture.get_instance_id()))
	return {
		"source": PRODUCTION_TERRAIN_SHADER,
		"parameter_bytes": parameter_bytes,
		"texture_rids": texture_rids,
		"resources": resources,
		"scene_lighting_supported": bool(lighting.get("supported", false)),
		"signature": ":".join(signature_parts),
	}


func _production_scene_lighting() -> Dictionary:
	var result := {
		"ambient_color": Color.BLACK,
		"ambient_energy": 0.0,
		"directional_color": Color.BLACK,
		"directional_energy": 0.0,
		"directional_direction": Vector3.UP,
		"supported": false,
	}
	if _world_environment == null or not is_instance_valid(_world_environment):
		return result
	var environment := _world_environment.environment
	if environment == null \
			or environment.ambient_light_source != Environment.AMBIENT_SOURCE_COLOR \
			or environment.fog_enabled:
		return result
	var ambient_linear := environment.ambient_light_color.srgb_to_linear()
	result["ambient_color"] = ambient_linear
	result["ambient_energy"] = environment.ambient_light_energy
	var active_directional_lights: Array[DirectionalLight3D] = []
	for candidate in get_tree().root.find_children(
		"*", "DirectionalLight3D", true, false
	):
		var light := candidate as DirectionalLight3D
		if light == null or light.get_viewport() != get_viewport() \
				or not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		if light.light_negative or light.shadow_enabled:
			return result
		active_directional_lights.append(light)
	if active_directional_lights.size() > 1:
		return result
	for light_type in ["OmniLight3D", "SpotLight3D"]:
		for candidate in get_tree().root.find_children("*", light_type, true, false):
			var local_light := candidate as Light3D
			if local_light != null and local_light.get_viewport() == get_viewport() \
					and local_light.is_visible_in_tree() \
					and local_light.light_energy > 0.0:
				return result
	result["supported"] = true
	if active_directional_lights.is_empty():
		return result
	_directional_light = active_directional_lights[0]
	var directional_linear := _directional_light.light_color.srgb_to_linear()
	result["directional_color"] = directional_linear
	result["directional_energy"] = _directional_light.light_energy
	result["directional_direction"] = \
		_directional_light.global_transform.basis.z.normalized()
	return result


func _resolve_directional_light() -> DirectionalLight3D:
	if get_tree() == null:
		return null
	var selected: DirectionalLight3D
	for candidate in get_tree().root.find_children(
		"*", "DirectionalLight3D", true, false
	):
		var light := candidate as DirectionalLight3D
		if light == null or light.get_viewport() != get_viewport() \
				or not light.is_visible_in_tree() or light.light_negative:
			continue
		if selected == null or light.light_energy > selected.light_energy:
			selected = light
	return selected


static func _append_vec4(values: PackedFloat32Array, value: Vector4) -> void:
	values.append(value.x)
	values.append(value.y)
	values.append(value.z)
	values.append(value.w)


func _submit_native_captures() -> void:
	var submitted_this_frame := 0
	while _render_request_routes.size() < RENDER_SUBMISSION_CAPACITY \
			and submitted_this_frame < NATIVE_SUBMISSIONS_PER_FRAME:
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
			request.get("bounds_max", Vector3.ZERO),
			bool(request.get("proven_empty", false))
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
			"bounds_min": request.get("bounds_min", Vector3.ZERO),
			"bounds_max": request.get("bounds_max", Vector3.ZERO),
		}
		sequences[surface] = sequence
		group["requests"] = requests
		group["sequences"] = sequences
		_groups[group_key] = group
		var route := {"group_key": group_key, "surface": surface}
		_render_request_routes[render_request_id] = route
		_entry_routes[_entry_token(identity, sequence)] = route
		_submitted_surfaces += 1
		submitted_this_frame += 1


func _drain_effect_events() -> void:
	while true:
		var event: Dictionary = _effect.pop_event()
		if event.is_empty():
			return
		var route := _route_for_event(event)
		if route.is_empty():
			_unrouted_effect_events += 1
			if _unrouted_effect_event_examples.size() < 8:
				_unrouted_effect_event_examples.append(event.duplicate(true))
			continue
		var group_key := str(route.get("group_key", ""))
		if not _groups.has(group_key):
			continue
		match str(event.get("status", "")):
			"PREPARED":
				_record_surface_details(
					group_key, str(route.get("surface", "")), event
				)
				_mark_surface(group_key, "prepared", str(route.get("surface", "")))
				if not bool(Dictionary(_groups.get(group_key, {})).get(
					"retiring", false
				)):
					_try_validate_group(group_key)
			"ACTIVE":
				_mark_surface(group_key, "activated", str(route.get("surface", "")))
				if not bool(Dictionary(_groups.get(group_key, {})).get(
					"retiring", false
				)):
					_try_finish_activation_cohort(group_key)
			"ACTIVATION_STAGED":
				_mark_surface(
					group_key, "activation_staged", str(route.get("surface", ""))
				)
				if not bool(Dictionary(_groups.get(group_key, {})).get(
					"retiring", false
				)):
					_try_commit_activation_cohort(group_key)
			"REJECTED":
				var rejection_error := str(event.get(
					"error", "GPU entry rejected"
				))
				if bool(Dictionary(_groups.get(group_key, {})).get(
					"activation_queued", false
				)):
					var rejected_group := Dictionary(_groups[group_key])
					var rejected_cohort_id := int(rejected_group.get(
						"activation_cohort_id", 0
					))
					if rejected_cohort_id > 0 and _activation_cohorts.has(
						rejected_cohort_id
					) and bool(Dictionary(_activation_cohorts[
						rejected_cohort_id
					]).get("native_committed", false)):
						_fail_closed(
							"committed GPU activation failed: %s" % rejection_error
						)
						return
					_reject_activation_cohort(group_key, rejection_error)
					continue
				if _is_stale_render_event(rejection_error):
					_supersede_group(group_key)
				else:
					_reject_group(group_key, rejection_error)
			"RETIRED", "SUPERSEDED":
				_mark_surface(group_key, "retired", str(route.get("surface", "")))
				_try_finish_retirement(group_key)


func _try_validate_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)) \
			or bool(group.get("validated", false)) \
			or not _surface_set_complete(
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
	var preparation := Dictionary(_backend_terrain.call(
		"prepare_gpu_resident_render_chunk", _group_identities(group)
	))
	var preparation_status := str(preparation.get("status", ""))
	if preparation_status.begins_with("STALE"):
		_groups[group_key] = group
		_supersede_group(group_key)
		return
	if preparation_status != "PREPARED" \
			or not bool(preparation.get("prepared", false)):
		_groups[group_key] = group
		_reject_group(group_key, str(preparation.get(
			"error", "native resident preparation rejected the chunk"
		)))
		return
	group["native_prepared"] = true
	_groups[group_key] = group
	_prepared_group_routes[_activation_chunk_key(Dictionary(
		terrain_request.get("identity", {})
	))] = group_key
	_try_queue_activation_cohort(group_key)


func _retry_prepared_groups() -> void:
	var group_keys := _groups.keys()
	var queued_cohort_retries := 0
	for group_key_value in group_keys:
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		if bool(group.get("retiring", false)):
			continue
		if not bool(group.get("validated", false)):
			_try_validate_group(group_key)
		if not _groups.has(group_key):
			continue
		group = Dictionary(_groups[group_key])
		if queued_cohort_retries >= ACTIVATION_COHORT_RETRY_CAPACITY \
				or bool(group.get("retiring", false)) \
				or bool(group.get("active", false)) \
				or bool(group.get("activation_queued", false)) \
				or not bool(group.get("native_prepared", false)) \
				or _activation_retry_membership.has(group_key):
			continue
		_queue_activation_cohort_retry(group_key)
		queued_cohort_retries += 1


func _supersede_stale_incomplete_groups() -> void:
	var group_keys := _groups.keys()
	for group_key_value in group_keys:
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		if bool(group.get("active", false)) \
				or bool(group.get("retiring", false)) \
				or _surface_set_complete(group, "prepared") \
				or _process_frame < int(group.get(
					"next_incomplete_probe_frame", 0
				)):
			continue
		var requests: Dictionary = group.get("requests", {})
		if requests.is_empty():
			continue
		var request: Dictionary = requests.get("terrain", {})
		if request.is_empty():
			request = Dictionary(requests.values()[0])
		var readiness := Dictionary(_backend_terrain.call(
			"get_gpu_resident_render_chunk_readiness",
			Dictionary(request.get("identity", {}))
		))
		var readiness_status := str(readiness.get("status", ""))
		group["last_incomplete_status"] = readiness_status
		group["next_incomplete_probe_frame"] = (
			_process_frame + APPLICATION_WAIT_RETRY_FRAMES
		)
		_groups[group_key] = group
		if readiness_status.begins_with("STALE"):
			_stale_incomplete_groups_superseded += 1
			_supersede_group(group_key)


func _try_queue_activation_cohort(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)) \
			or bool(group.get("active", false)) \
			or bool(group.get("activation_queued", false)) \
			or not bool(group.get("native_prepared", false)):
		return
	var terrain_identity := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {})).get("identity", {})
	var phase_start := Time.get_ticks_usec() if _stage_timing_enabled else 0
	var cohort := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_activation_cohort", terrain_identity
	))
	if _stage_timing_enabled:
		phase_start = _record_stage_time("activation_native_query", phase_start)
	var cohort_status := str(cohort.get("status", ""))
	if cohort_status == "WAITING_COHORT":
		_record_activation_cohort_wait(cohort)
		_queue_activation_cohort_retry(group_key)
		return
	if cohort_status.begins_with("STALE"):
		_supersede_group(group_key)
		return
	if cohort_status != "READY" or not bool(cohort.get("ready", false)):
		_reject_group(group_key, str(cohort.get(
			"error", "native activation cohort rejected prepared GPU geometry"
		)))
		return
	var native_precommitted := false
	if bool(cohort.get("regional", false)):
		var pool := _prepared_inventory_pool(Array(cohort.get("chunks", [])))
		if _stage_timing_enabled:
			phase_start = _record_stage_time("activation_inventory", phase_start)
		if pool.is_empty():
			_queue_activation_cohort_retry(group_key)
			return
		var regional_activation := Dictionary(_backend_terrain.call(
			"activate_gpu_resident_render_cohort",
			pool,
			terrain_identity
		))
		if _stage_timing_enabled:
			phase_start = _record_stage_time("activation_native_commit", phase_start)
		var regional_status := str(regional_activation.get("status", ""))
		if regional_status == "WAITING_COHORT":
			_record_activation_cohort_wait(regional_activation)
			_queue_activation_cohort_retry(group_key)
			return
		if regional_status.begins_with("STALE"):
			_supersede_group(group_key)
			return
		if regional_status != "ACTIVE" \
				or not bool(regional_activation.get("active", false)):
			_fail_closed(str(regional_activation.get(
				"error", "native regional activation transaction failed"
			)))
			return
		cohort["chunks"] = Array(regional_activation.get(
			"chunks", []
		)).duplicate(true)
		cohort["retirements"] = Array(regional_activation.get(
			"retirements", []
		)).duplicate(true)
		native_precommitted = true
	var group_keys: Array[String] = []
	var cohort_member_group_keys: Array[String] = []
	var activation_entries: Array[Dictionary] = []
	var retirement_group_keys: Array[String] = []
	var retirement_entries: Array[Dictionary] = []
	var inventories: Array = []
	for member_value in Array(cohort.get("chunks", [])):
		var member := Dictionary(member_value)
		var member_group_key := str(_prepared_group_routes.get(
			_activation_chunk_key(member), ""
		))
		if member_group_key.is_empty() or not _groups.has(member_group_key):
			_queue_activation_cohort_retry(group_key)
			return
		var member_group := Dictionary(_groups[member_group_key])
		cohort_member_group_keys.append(member_group_key)
		var activation_required := bool(member.get("activation_required", true))
		if bool(member_group.get("retiring", false)):
			_queue_activation_cohort_retry(group_key)
			return
		if activation_required:
			if bool(member_group.get("active", false)) \
					or bool(member_group.get("activation_queued", false)) \
					or not bool(member_group.get("native_prepared", false)):
				_queue_activation_cohort_retry(group_key)
				return
			group_keys.append(member_group_key)
		elif not bool(member_group.get("active", false)) \
				or not bool(member_group.get("native_active", false)):
			_queue_activation_cohort_retry(group_key)
			return
		var requests: Dictionary = member_group.get("requests", {})
		var sequences: Dictionary = member_group.get("sequences", {})
		var member_identities := _group_identities(member_group)
		var routed_terrain_identity := Dictionary(requests.get(
			"terrain", {}
		)).get("identity", {})
		if _activation_chunk_key(routed_terrain_identity) != \
				_activation_chunk_key(member):
			_fail_closed("GPU activation cohort route changed chunk identity")
			return
		inventories.append(member_identities)
		if activation_required:
			for surface in _required_surfaces(member_group):
				var request := Dictionary(requests.get(surface, {}))
				activation_entries.append({
					"identity": Dictionary(request.get("identity", {})),
					"publication_sequence": int(sequences.get(surface, 0)),
				})
	if _stage_timing_enabled:
		phase_start = _record_stage_time("activation_member_routes", phase_start)
	var retirements := Array(cohort.get("retirements", []))
	var active_routes := _active_group_routes_by_chunk() if not retirements.is_empty() else {}
	for retirement_value in retirements:
		var retirement := Dictionary(retirement_value)
		var retirement_key := _chunk_location_key(retirement)
		var retirement_group_key := str(active_routes.get(retirement_key, ""))
		if retirement_group_key.is_empty():
			if active_routes.has(retirement_key):
				_fail_closed("authoritative GPU retirement has ambiguous active generations")
				return
			_cpu_only_regional_retirements += 1
			continue
		var retirement_group := Dictionary(_groups[retirement_group_key])
		if bool(retirement_group.get("retiring", false)) \
				or bool(retirement_group.get("activation_queued", false)):
			_fail_closed("authoritative GPU retirement is not stable")
			return
		if retirement_group_keys.has(retirement_group_key):
			_fail_closed("authoritative GPU retirement repeats a chunk")
			return
		retirement_group_keys.append(retirement_group_key)
		var retirement_requests := Dictionary(retirement_group.get("requests", {}))
		var retirement_sequences := Dictionary(retirement_group.get("sequences", {}))
		for surface in _required_surfaces(retirement_group):
			var retirement_request := Dictionary(retirement_requests.get(surface, {}))
			retirement_entries.append({
				"identity": Dictionary(retirement_request.get("identity", {})),
				"publication_sequence": int(retirement_sequences.get(surface, 0)),
			})
	if _stage_timing_enabled:
		_record_stage_time("activation_retirement_routes", phase_start)
	if inventories.is_empty():
		_queue_activation_cohort_retry(group_key)
		return
	if group_keys.is_empty():
		if not native_precommitted:
			var retained_activation := Dictionary(_backend_terrain.call(
				"activate_gpu_resident_render_cohort", inventories
			))
			if str(retained_activation.get("status", "")) != "ACTIVE" \
					or not bool(retained_activation.get("active", false)):
				_fail_closed(str(retained_activation.get(
					"error", "retained GPU activation cohort commit failed"
				)))
				return
		for member_group_key in cohort_member_group_keys:
			_activation_retry_membership.erase(member_group_key)
		_activation_cohorts_committed += 1
		return
	var cohort_id := _next_activation_cohort_id
	_next_activation_cohort_id += 1
	_activation_cohorts[cohort_id] = {
		"group_keys": group_keys.duplicate(),
		"inventories": inventories.duplicate(true),
		"activation_entries": activation_entries.duplicate(true),
		"retirement_group_keys": retirement_group_keys.duplicate(),
		"retirement_entries": retirement_entries.duplicate(true),
		"selected_chunks": Array(cohort.get("chunks", [])).duplicate(true),
		"native_committed": native_precommitted,
		"regional": bool(cohort.get("regional", false)),
	}
	for member_group_key in cohort_member_group_keys:
		_activation_retry_membership.erase(member_group_key)
	for member_group_key in group_keys:
		var member_group := Dictionary(_groups[member_group_key])
		member_group["activation_queued"] = true
		member_group["activation_cohort_id"] = cohort_id
		if native_precommitted:
			member_group["native_active"] = true
		_groups[member_group_key] = member_group
	_activation_cohorts_queued += 1
	if native_precommitted:
		_mark_groups_retiring(retirement_group_keys)
		var render_swap_queued: bool = _effect.replace_entries(
			activation_entries, retirement_entries
		) if not retirement_entries.is_empty() else _effect.activate_entries(
			activation_entries
		)
		if not render_swap_queued:
			_fail_closed("global renderer rejected committed regional activation cohort")
		return
	# Every entry emitted PREPARED only after its compact resident buffers were
	# created and validated on the render thread. Revalidating them through a
	# second render-thread round trip allowed the native publication region to
	# change between cohort selection and commit, starving moving LOD regions.
	# Commit the freshly selected authority cohort synchronously, then ask the
	# render thread to expose exactly those already-prepared entries.
	_try_commit_activation_cohort(group_key)


func _prepared_inventory_pool(members: Array) -> Array:
	var inventories: Array = []
	# Supply only the authority-selected cohort. Native commit still recomputes
	# and validates membership; never admit an in-flight render activation.
	for member_value in members:
		var route_key := _activation_chunk_key(Dictionary(member_value))
		var group_key := str(_prepared_group_routes.get(route_key, ""))
		if group_key.is_empty() or not _groups.has(group_key):
			return []
		var group := Dictionary(_groups[group_key])
		if bool(group.get("retiring", false)) \
				or bool(group.get("activation_queued", false)) \
				or (not bool(group.get("native_prepared", false)) \
				and not bool(group.get("native_active", false))):
			return []
		var requests := Dictionary(group.get("requests", {}))
		if not _surface_set_complete(group, "prepared") \
				or requests.size() != _required_surfaces(group).size():
			return []
		var terrain_identity := Dictionary(Dictionary(requests.get("terrain", {})).get("identity", {}))
		if _activation_chunk_key(terrain_identity) != route_key:
			return []
		inventories.append(_group_identities(group))
	return inventories


func _active_group_routes_by_chunk() -> Dictionary:
	# Native retirement keys identify locations, not generations. Resolve each
	# to its unique active GPU identity once for the whole replacement batch.
	var routes := {}
	for group_key_value in _groups.keys():
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		if not bool(group.get("active", false)) \
				or bool(group.get("retiring", false)):
			continue
		var terrain_request := Dictionary(Dictionary(group.get(
			"requests", {}
		)).get("terrain", {}))
		var location_key := _chunk_location_key(Dictionary(terrain_request.get(
			"identity", {}
		)))
		routes[location_key] = "" if routes.has(location_key) else group_key
	return routes


func _mark_groups_retiring(group_keys: Array[String]) -> void:
	for group_key in group_keys:
		if not _groups.has(group_key):
			continue
		var group := Dictionary(_groups[group_key])
		group["retiring"] = true
		group["retirement_candidate_frame"] = -1
		_groups[group_key] = group
		_record_lifecycle_event("ATOMIC_RETIRE", group_key)


func _record_activation_cohort_wait(wait: Dictionary) -> void:
	_last_activation_cohort_wait = wait.duplicate(true)
	var member := Dictionary(wait.get("waiting_member", {}))
	if member.is_empty():
		return
	var route_key := _activation_chunk_key(member)
	var group_key := str(_prepared_group_routes.get(route_key, ""))
	_last_activation_cohort_wait["waiting_member_route_key"] = route_key
	_last_activation_cohort_wait["waiting_member_group_key"] = group_key
	_last_activation_cohort_wait["waiting_member_group_present"] = (
		not group_key.is_empty() and _groups.has(group_key)
	)
	if group_key.is_empty() or not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	_last_activation_cohort_wait["waiting_member_group"] = {
		"active": bool(group.get("active", false)),
		"retiring": bool(group.get("retiring", false)),
		"validated": bool(group.get("validated", false)),
		"native_prepared": bool(group.get("native_prepared", false)),
		"native_active": bool(group.get("native_active", false)),
		"activation_queued": bool(group.get("activation_queued", false)),
		"activation_retry_queued": _activation_retry_membership.has(group_key),
		"prepared_surfaces": Dictionary(group.get("prepared", {})).keys(),
		"native_validated_surfaces": Dictionary(
			group.get("native_validated", {})
		).keys(),
		"identities": _group_identities(group),
	}


func _queue_activation_cohort_retry(group_key: String) -> void:
	if group_key.is_empty() or _activation_retry_membership.has(group_key):
		return
	_activation_retry_membership[group_key] = true
	_activation_retry_queue.append(group_key)


func _drain_activation_cohort_retries() -> void:
	var attempts := 0
	var inspected := 0
	var inspection_limit := _activation_retry_queue.size()
	# Retried groups join the tail behind every group that has not had a turn.
	while attempts < ACTIVATION_COHORT_RETRY_CAPACITY and inspected < inspection_limit \
			and not _activation_retry_queue.is_empty():
		var group_key := _activation_retry_queue.pop_front()
		inspected += 1
		if not _activation_retry_membership.has(group_key):
			continue
		_activation_retry_membership.erase(group_key)
		if not _groups.has(group_key):
			continue
		var group := Dictionary(_groups[group_key])
		if bool(group.get("retiring", false)) \
				or bool(group.get("active", false)) \
				or bool(group.get("activation_queued", false)) \
				or not bool(group.get("native_prepared", false)):
			continue
		attempts += 1
		_activation_cohort_retry_attempts += 1
		_try_queue_activation_cohort(group_key)


func _try_commit_activation_cohort(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var cohort_id := int(group.get("activation_cohort_id", 0))
	if cohort_id <= 0 or not _activation_cohorts.has(cohort_id):
		return
	var cohort := Dictionary(_activation_cohorts[cohort_id])
	if bool(cohort.get("native_committed", false)):
		return
	var group_keys: Array = cohort.get("group_keys", [])
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			_fail_closed("GPU activation cohort lost a prepared chunk")
			return
	var inventories: Array = cohort.get("inventories", [])
	var activation := Dictionary(_backend_terrain.call(
		"activate_gpu_resident_render_cohort", inventories
	))
	var activation_status := str(activation.get("status", ""))
	if activation_status != "ACTIVE" or not bool(activation.get("active", false)):
		if activation_status.begins_with("STALE"):
			_stale_activation_cohorts_retained += 1
			if _stale_activation_examples.size() < 8:
				_stale_activation_examples.append({
					"status": activation_status,
					"error": str(activation.get("error", "")),
					"activation": activation.duplicate(true),
					"selected_chunks": Array(cohort.get(
						"selected_chunks", []
					)).duplicate(true),
					"inventories": inventories.duplicate(true),
				})
			# Prepared entries remain invisible. Keep them resident and retry
			# against the newly authoritative regional cohort.
			_activation_cohorts.erase(cohort_id)
			for member_group_key_value in group_keys:
				var member_group_key := str(member_group_key_value)
				if not _groups.has(member_group_key):
					continue
				var member_group := Dictionary(_groups[member_group_key])
				member_group["activation_queued"] = false
				member_group["activation_cohort_id"] = 0
				member_group["activation_staged"] = {}
				_groups[member_group_key] = member_group
				_queue_activation_cohort_retry(member_group_key)
			return
		_fail_closed(str(activation.get(
			"error", "native activation cohort commit failed"
		)))
		return
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		var member_group := Dictionary(_groups[member_group_key])
		member_group["native_active"] = true
		_groups[member_group_key] = member_group
	cohort["native_committed"] = true
	_activation_cohorts[cohort_id] = cohort
	if not _effect.activate_entries(Array(cohort.get("activation_entries", []))):
		_fail_closed("global renderer rejected committed activation cohort")


func _try_finish_activation_cohort(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var cohort_id := int(group.get("activation_cohort_id", 0))
	if cohort_id <= 0 or not _activation_cohorts.has(cohort_id):
		return
	var cohort := Dictionary(_activation_cohorts[cohort_id])
	if not bool(cohort.get("native_committed", false)):
		_fail_closed("GPU entries activated before native cohort commit")
		return
	var group_keys: Array = cohort.get("group_keys", [])
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			_fail_closed("GPU activation cohort lost a committed chunk")
			return
		if not _surface_set_complete(
				Dictionary(_groups[member_group_key]), "activated"
		):
			return
	for member_group_key_value in group_keys:
		var member_group_key := str(member_group_key_value)
		var member_group := Dictionary(_groups[member_group_key])
		member_group["active"] = true
		member_group["activation_queued"] = false
		member_group["activation_cohort_id"] = 0
		_groups[member_group_key] = member_group
		_record_lifecycle_event("ACTIVE", member_group_key)
		_activated_chunks += 1
	_activation_cohorts.erase(cohort_id)
	_activation_cohorts_committed += 1


func _reconcile_active_chunks() -> void:
	if not _resident_replacement_batch_ready():
		_coverage_retained_reconciliation_deferrals += 1
		_clear_retirement_candidates()
		return
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
	var retire_group_keys := {}
	for identity_value in Array(reconciliation.get("retire", [])):
		var identity := Dictionary(identity_value)
		var group_key := str(group_by_identity.get(_group_key(identity), ""))
		if not group_key.is_empty():
			retire_group_keys[group_key] = true
	for group_key_value in group_by_identity.values():
		var group_key := str(group_key_value)
		if not _groups.has(group_key):
			continue
		var group: Dictionary = _groups[group_key]
		var candidate_frame := int(group.get("retirement_candidate_frame", -1))
		if not retire_group_keys.has(group_key):
			if candidate_frame >= 0:
				group["retirement_candidate_frame"] = -1
				_groups[group_key] = group
				_retirement_candidate_cancellations += 1
			continue
		if candidate_frame >= 0 and candidate_frame < _process_frame:
			_begin_group_retirement(group_key, "native_reconciliation")
			continue
		group["retirement_candidate_frame"] = _process_frame
		_groups[group_key] = group
		_retirement_confirmation_deferrals += 1


func _clear_retirement_candidates() -> void:
	for group_key_value in _groups.keys():
		var group_key := str(group_key_value)
		var group: Dictionary = _groups[group_key]
		if int(group.get("retirement_candidate_frame", -1)) < 0:
			continue
		group["retirement_candidate_frame"] = -1
		_groups[group_key] = group
		_retirement_candidate_cancellations += 1


func _resident_replacement_batch_ready() -> bool:
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if not bool(group.get("active", false)) \
				and not bool(group.get("retiring", false)):
			return false
	var effect_status := Dictionary(_effect.get_status())
	if int(effect_status.get("queued_request_count", 0)) != 0 \
			or int(effect_status.get("inflight_extraction_count", 0)) != 0 \
			or int(effect_status.get("event_count", 0)) != 0:
		return false
	var native_metrics := Dictionary(_backend_terrain.call(
		"get_gpu_resident_render_metrics"
	))
	return not bool(native_metrics.get("coverage_staging_blocked", false)) \
		and int(native_metrics.get("queued_requests", 0)) == 0 \
		and int(native_metrics.get("in_flight_requests", 0)) == 0


func debug_ray_coverage(
	origin: Vector3, direction: Vector3, maximum_distance: float
) -> Array:
	var hits: Array = []
	var unit_direction := direction.normalized()
	if not origin.is_finite() or not unit_direction.is_finite() \
			or unit_direction.is_zero_approx() or maximum_distance <= 0.0:
		return hits
	for group_key_value in _groups.keys():
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		var terrain_request := Dictionary(
			Dictionary(group.get("requests", {})).get("terrain", {})
		)
		if terrain_request.is_empty():
			continue
		var distance := _ray_aabb_distance(
			origin,
			unit_direction,
			terrain_request.get("bounds_min", Vector3.ZERO),
			terrain_request.get("bounds_max", Vector3.ZERO),
			maximum_distance
		)
		if distance < 0.0:
			continue
		var details := Dictionary(
			Dictionary(group.get("surface_details", {})).get("terrain", {})
		)
		hits.append({
			"distance": distance,
			"identity": Dictionary(terrain_request.get("identity", {})).duplicate(true),
			"bounds_min": terrain_request.get("bounds_min", Vector3.ZERO),
			"bounds_max": terrain_request.get("bounds_max", Vector3.ZERO),
			"active": bool(group.get("active", false)),
			"retiring": bool(group.get("retiring", false)),
			"empty": bool(details.get("empty", false)),
			"vertex_count": int(details.get("vertex_count", 0)),
			"index_count": int(details.get("index_count", 0)),
			"failure_cell_count": int(details.get("failure_cell_count", 0)),
		})
	hits.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("distance", INF)) < float(right.get("distance", INF))
	)
	return hits.slice(0, mini(16, hits.size()))


func request_debug_ray_geometry(rays: Array) -> int:
	if _effect == null or not _effect.has_method("request_debug_ray_geometry"):
		return 0
	return int(_effect.request_debug_ray_geometry(rays))


func pop_debug_ray_geometry(request_id: int) -> Dictionary:
	if _effect == null or not _effect.has_method("pop_debug_ray_geometry"):
		return {}
	return Dictionary(_effect.pop_debug_ray_geometry(request_id))


func _record_surface_details(
	group_key: String, surface: String, event: Dictionary
) -> void:
	if not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var details := Dictionary(group.get("surface_details", {}))
	details[surface] = {
		"empty": bool(event.get("entry_empty", false)),
		"vertex_count": int(event.get("entry_vertex_count", 0)),
		"index_count": int(event.get("entry_index_count", 0)),
		"failure_cell_count": int(event.get("entry_failure_cell_count", 0)),
	}
	group["surface_details"] = details
	_groups[group_key] = group


static func _ray_aabb_distance(
	origin: Vector3,
	direction: Vector3,
	minimum: Vector3,
	maximum: Vector3,
	maximum_distance: float
) -> float:
	var near_distance := 0.0
	var far_distance := maximum_distance
	for axis in range(3):
		var axis_origin := origin[axis]
		var axis_direction := direction[axis]
		if absf(axis_direction) <= 0.000001:
			if axis_origin < minimum[axis] or axis_origin > maximum[axis]:
				return -1.0
			continue
		var first := (minimum[axis] - axis_origin) / axis_direction
		var second := (maximum[axis] - axis_origin) / axis_direction
		if first > second:
			var swap := first
			first = second
			second = swap
		near_distance = maxf(near_distance, first)
		far_distance = minf(far_distance, second)
		if near_distance > far_distance:
			return -1.0
	return near_distance if far_distance >= 0.0 else -1.0


func _reject_group(group_key: String, error: String) -> void:
	if not _groups.has(group_key):
		return
	_last_error = error
	_rejected_chunks += 1
	var group: Dictionary = _groups[group_key]
	_rejection_reasons[error] = int(_rejection_reasons.get(error, 0)) + 1
	if _rejection_examples.size() < 16:
		var requests: Dictionary = group.get("requests", {})
		var request: Dictionary = requests.get("terrain", {})
		if request.is_empty() and not requests.is_empty():
			request = Dictionary(requests.values()[0])
		_rejection_examples.append({
			"error": error,
			"identity": Dictionary(request.get("identity", {})).duplicate(true),
			"prepared_surfaces": Dictionary(group.get("prepared", {})).duplicate(true),
			"validated_surfaces": Dictionary(group.get("native_validated", {})).duplicate(true),
			"activated_surfaces": Dictionary(group.get("activated", {})).duplicate(true),
		})
	if not bool(group.get("validated", false)):
		var native_validated: Dictionary = group.get("native_validated", {})
		for surface in Dictionary(group.get("requests", {})):
			if bool(native_validated.get(surface, false)):
				continue
			var request_value = Dictionary(group.get("requests", {}))[surface]
			var request := Dictionary(request_value)
			_reject_native_request(request, error)
	_begin_group_retirement(group_key, "rejected")


static func _is_stale_render_event(error: String) -> bool:
	return error.contains("became stale")


func _supersede_group(group_key: String) -> void:
	if not _groups.has(group_key):
		return
	if bool(Dictionary(_groups[group_key]).get("activation_queued", false)):
		_supersede_activation_cohort(group_key)
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
	_begin_group_retirement(group_key, "superseded")


func _reject_activation_cohort(group_key: String, error: String) -> void:
	var group := Dictionary(_groups.get(group_key, {}))
	var cohort_id := int(group.get("activation_cohort_id", 0))
	var cohort := Dictionary(_activation_cohorts.get(cohort_id, {}))
	_activation_cohorts.erase(cohort_id)
	for member_group_key_value in Array(cohort.get("group_keys", [group_key])):
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			continue
		var member_group := Dictionary(_groups[member_group_key])
		member_group["activation_queued"] = false
		member_group["activation_cohort_id"] = 0
		_groups[member_group_key] = member_group
		_reject_group(member_group_key, error)


func _supersede_activation_cohort(group_key: String) -> void:
	var group := Dictionary(_groups.get(group_key, {}))
	var cohort_id := int(group.get("activation_cohort_id", 0))
	var cohort := Dictionary(_activation_cohorts.get(cohort_id, {}))
	_activation_cohorts.erase(cohort_id)
	for member_group_key_value in Array(cohort.get("group_keys", [group_key])):
		var member_group_key := str(member_group_key_value)
		if not _groups.has(member_group_key):
			continue
		var member_group := Dictionary(_groups[member_group_key])
		member_group["activation_queued"] = false
		member_group["activation_cohort_id"] = 0
		_groups[member_group_key] = member_group
		_supersede_group(member_group_key)


func _begin_group_retirement(
	group_key: String, reason: String = "unspecified"
) -> void:
	if not _groups.has(group_key):
		return
	var group: Dictionary = _groups[group_key]
	if bool(group.get("retiring", false)):
		return
	group["retiring"] = true
	_groups[group_key] = group
	_record_lifecycle_event("RETIRE", group_key, {"reason": reason})
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
	if bool(group.get("native_active", false)):
		_backend_terrain.call(
			"set_gpu_resident_render_chunk_active", _group_identities(group), false
		)
		group["native_active"] = false
		_retired_chunks += 1
	_cleanup_group(group_key)


func _record_lifecycle_event(
	action: String, group_key: String, details: Dictionary = {}
) -> void:
	if not _lifecycle_history_enabled or not _groups.has(group_key):
		return
	var group := Dictionary(_groups[group_key])
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	var event := {
		"frame": _process_frame,
		"action": action,
		"identity": Dictionary(terrain_request.get("identity", {})).duplicate(true),
		"active": bool(group.get("active", false)),
		"native_active": bool(group.get("native_active", false)),
		"activation_queued": bool(group.get("activation_queued", false)),
	}
	event.merge(details, true)
	_recent_lifecycle_events.append(event)
	if _recent_lifecycle_events.size() > LIFECYCLE_HISTORY_CAPACITY:
		_recent_lifecycle_events.pop_front()


func _restore_cpu_and_release_native_requests() -> void:
	if _backend_terrain == null or not is_instance_valid(_backend_terrain):
		return
	for group_value in _groups.values():
		var group := Dictionary(group_value)
		if bool(group.get("native_active", false)):
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
	push_error("WT_GPU_RESIDENT_FAIL_CLOSED: %s" % error)
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
	_activation_retry_membership.erase(group_key)
	var group: Dictionary = _groups[group_key]
	var terrain_request := Dictionary(Dictionary(group.get(
		"requests", {}
	)).get("terrain", {}))
	if not terrain_request.is_empty():
		var terrain_identity := Dictionary(terrain_request.get("identity", {}))
		var activation_key := _activation_chunk_key(terrain_identity)
		if str(_prepared_group_routes.get(activation_key, "")) == group_key:
			_prepared_group_routes.erase(activation_key)
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


func _inactive_group_examples(limit: int) -> Array:
	var examples: Array = []
	for group_key_value in _groups.keys():
		if examples.size() >= limit:
			break
		var group_key := str(group_key_value)
		var group := Dictionary(_groups[group_key])
		if bool(group.get("active", false)) or bool(group.get("retiring", false)):
			continue
		var requests: Dictionary = group.get("requests", {})
		var identities := {}
		for surface_value in requests.keys():
			var surface := str(surface_value)
			identities[surface] = Dictionary(requests[surface]).get("identity", {})
		examples.append({
			"group_key": group_key,
			"age_frames": _process_frame - int(group.get("created_frame", _process_frame)),
			"water_expected": bool(group.get("water_expected", false)),
			"request_surfaces": requests.keys(),
			"prepared_surfaces": Dictionary(group.get("prepared", {})).keys(),
			"native_validated_surfaces": Dictionary(
				group.get("native_validated", {})
			).keys(),
			"validated": bool(group.get("validated", false)),
			"native_prepared": bool(group.get("native_prepared", false)),
			"native_active": bool(group.get("native_active", false)),
			"activation_queued": bool(group.get("activation_queued", false)),
			"activation_cohort_id": int(group.get("activation_cohort_id", 0)),
			"activation_retry_queued": _activation_retry_membership.has(group_key),
			"activation_staged_surfaces": Dictionary(
				group.get("activation_staged", {})
			).keys(),
			"activated_surfaces": Dictionary(group.get("activated", {})).keys(),
			"last_incomplete_status": str(group.get(
				"last_incomplete_status", ""
			)),
			"identities": identities,
		})
	return examples


func _new_group(identity: Dictionary) -> Dictionary:
	return {
		"water_expected": bool(identity.get("static_water_surface_expected", false)),
		"requests": {},
		"sequences": {},
		"prepared": {},
		"activation_staged": {},
		"activated": {},
		"retired": {},
		"native_validated": {},
		"surface_details": {},
		"validated": false,
		"native_prepared": false,
		"native_active": false,
		"active": false,
		"activation_queued": false,
		"activation_cohort_id": 0,
		"retiring": false,
		"retirement_candidate_frame": -1,
		"application_wait_started_frame": -1,
		"next_validation_frame": 0,
		"created_frame": _process_frame,
		"next_incomplete_probe_frame": 0,
		"last_incomplete_status": "",
	}


static func _required_surfaces(group: Dictionary) -> Array[String]:
	return ["terrain", "static_water"] if bool(group.get(
		"water_expected", false
	)) else ["terrain"]


static func _validate_native_request(request: Dictionary) -> String:
	if str(request.get("schema", "")) \
			!= "world_transvoxel.gpu_resident_render_request.v6" \
			or str(request.get("status", "")) != "PASS":
		return "native GPU resident request contract failed"
	if str(request.get("position_space", "")) != "world":
		return "native GPU resident request is not in world position space"
	if str(request.get("input_stage", "")) != "pre_mesh_field" \
			or bool(request.get("cpu_topology_input_dependency", true)) \
			or bool(request.get("cpu_field_sampling", true)) \
			or not bool(request.get("gpu_density_field_generation", false)) \
			or not bool(request.get("gpu_material_field_generation", false)) \
			or not bool(request.get("gpu_page_lattice_input", false)) \
			or not bool(request.get("gpu_transvoxel_extraction", false)):
		return "native GPU resident request is not a GPU page-field input"
	var cpu_visual_mesh_omitted := bool(request.get(
		"cpu_visual_mesh_omitted", false
	))
	if not bool(request.get("gpu_resident_render_publication", false)) \
			or bool(request.get("cpu_render_visible_until_activation", false)) \
				== cpu_visual_mesh_omitted \
			or not bool(request.get("cpu_collision_publication_unchanged", false)) \
			or not bool(request.get("native_input_packing", false)) \
			or bool(request.get("cell_batch_exported", true)) \
			or bool(request.get("fallback_used", true)):
		return "native GPU resident request changed publication authority"
	var input_buffers := Array(request.get("gpu_input_buffers", []))
	if input_buffers.size() != 13 or int(request.get("cell_count", 0)) <= 0 \
			or int(request.get("page_count", 0)) <= 0:
		return "native GPU resident input inventory is invalid"
	var actual_bytes := 0
	for buffer_value in input_buffers:
		if not buffer_value is PackedByteArray \
				or PackedByteArray(buffer_value).is_empty():
			return "native GPU resident input buffer is invalid"
		actual_bytes += PackedByteArray(buffer_value).size()
	if actual_bytes != int(request.get("packed_byte_count", -1)):
		return "native GPU resident packed byte count is invalid"
	var identity := Dictionary(request.get("identity", {}))
	if str(identity.get("input_stage", "")) != "pre_mesh_field":
		return "native GPU resident identity lost its input stage"
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


static func _chunk_location_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d" % [
		int(identity.get("page_x", 0)), int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)), int(identity.get("lod", 0)),
	]


static func _activation_chunk_key(identity: Dictionary) -> String:
	return "%d:%d:%d:%d:g%d:t%d" % [
		int(identity.get("page_x", 0)),
		int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)),
		int(identity.get("lod", 0)),
		int(identity.get("generation", 0)),
		int(identity.get("transition_mask", 0)),
	]


static func _entry_token(identity: Dictionary, sequence: int) -> String:
	return "%s:%s@%d" % [
		str(identity.get("surface", "")), _group_key(identity), sequence
	]
