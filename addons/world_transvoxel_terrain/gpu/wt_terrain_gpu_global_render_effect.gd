@tool
extends CompositorEffect
class_name WtTerrainGpuGlobalRenderEffect

const MeshingCandidate := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_candidate.gd"
)
const ResidentArena := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_arena.gd"
)
const COMPUTE_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing.glsl"
)
const RASTER_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render.glsl"
)
const PRODUCTION_RASTER_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_production.glsl"
)
const RESULT_SCHEMA := "world_transvoxel.terrain.gpu_global_render_publication.v1"
const REQUEST_CAPACITY := 3
const DEFAULT_RESIDENT_CAPACITY := 64
const MAXIMUM_SURFACES_PER_CHUNK := 2
const DRAW_COMMAND_STRIDE := 20
const REQUIRED_IDENTITY_FIELDS := [
	"page_x", "page_y", "page_z", "lod", "generation", "source_revision",
	"world_revision", "transition_mask", "field_mode", "sample_count", "surface",
]

var _rendering_device: RenderingDevice
var _packer = MeshingCandidate.new()
var _arena
var _mutex := Mutex.new()
var _pending: Array[Dictionary] = []
var _lifecycle_commands: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _latest_sequence_by_key: Dictionary = {}
var _entries: Dictionary = {}
var _active_sequence_by_key: Dictionary = {}
var _framebuffers: Dictionary = {}
var _next_request_id := 1
var _resident_capacity := DEFAULT_RESIDENT_CAPACITY
var _compute_shader := RID()
var _compute_pipeline := RID()
var _raster_shader := RID()
var _raster_pipeline := RID()
var _raster_pipeline_format := -1
var _production_raster_shader := RID()
var _production_raster_pipeline := RID()
var _production_raster_pipeline_format := -1
var _production_material_sampler := RID()
var _production_material_buffer := RID()
var _production_material_set := RID()
var _pending_production_material := {}
var _production_material_resources: Array = []
var _vertex_format := -1
var _initialization_attempted := false
var _close_requested := false
var _close_completed := false
var _status := {
	"schema": RESULT_SCHEMA,
	"initialized": false,
	"initialization_attempted": false,
	"global_rendering_device": true,
	"render_thread_owned": true,
	"same_global_device_compute_raster": true,
	"compositor_callback": "pre_transparent",
	"resource_architecture": "paged_shared_arena",
	"resident_buffer_count_per_entry": 0,
	"arena_binding_buffer_count_per_page": 21,
	"arena_page_slot_capacity": 4,
	"arena_page_count": 0,
	"arena_allocated_slot_count": 0,
	"arena_active_slot_count": 0,
	"arena_peak_active_slot_count": 0,
	"arena_allocated_bytes": 0,
	"arena_slot_leases": 0,
	"arena_slot_reuses": 0,
	"arena_slot_releases": 0,
	"packing_requests": 0,
	"packing_usec_total": 0,
	"packing_usec_max": 0,
	"packed_bytes_total": 0,
	"native_packed_requests": 0,
	"native_packed_bytes_total": 0,
	"gpu_written_indirect_commands": true,
	"compacted_surface_indirect_commands": true,
	"indirect_commands_per_surface": 1,
	"device_local_index_copy_used": true,
	"visibility_culling": "conservative_aabb_frustum",
	"visibility_bounds_position_space": "world",
	"visibility_culling_near_far": false,
	"visibility_test_count": 0,
	"visibility_culled_count": 0,
	"last_visible_surface_count": 0,
	"last_culled_surface_count": 0,
	"compact_indirect_command_records": 0,
	"source_cell_indirect_records_avoided": 0,
	"max_compact_command_records_per_view": 0,
	"max_source_cell_records_avoided_per_view": 0,
	"last_camera_origin": Vector3.ZERO,
	"last_camera_basis_z": Vector3.ZERO,
	"last_tested_bounds_min": Vector3.ZERO,
	"last_tested_bounds_max": Vector3.ZERO,
	"fallback_used": false,
	"request_capacity": REQUEST_CAPACITY,
	"resident_capacity": DEFAULT_RESIDENT_CAPACITY,
	"resident_allocation_capacity": (
		DEFAULT_RESIDENT_CAPACITY * MAXIMUM_SURFACES_PER_CHUNK + REQUEST_CAPACITY
	),
	"requested": 0,
	"applied": 0,
	"rejected": 0,
	"stale_skips": 0,
	"superseded_entries": 0,
	"prepared_entries": 0,
	"activated_entries": 0,
	"retired_entries": 0,
	"resident_capacity_rejections": 0,
	"draw_frames": 0,
	"indirect_draw_calls": 0,
	"resident_entry_count": 0,
	"active_entry_count": 0,
	"active_terrain_lod_counts": {},
	"active_static_water_lod_counts": {},
	"event_count": 0,
	"queued_request_count": 0,
	"geometry_readback_bytes": 0,
	"render_target_readback_bytes": 0,
	"cpu_meshing_used": false,
	"cpu_chunk_finalization_used": false,
	"array_mesh_upload_used": false,
	"cpu_collision_authority": true,
	"atomic_surface_set_activation": true,
	"production_chunk_replacement": false,
	"production_material_parity": false,
	"production_terrain_material_payload_ready": false,
	"production_terrain_albedo_mapping_parity": false,
	"production_terrain_normal_mapping_parity": false,
	"production_terrain_pbr_lighting_parity": false,
	"production_terrain_material_parity": false,
	"production_static_water_material_parity": false,
	"production_material_source": "",
	"production_material_parameter_bytes": 0,
	"production_material_texture_count": 0,
	"last_error": "",
	"last_applied_identity": {},
}


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	enabled = true
	_rendering_device = RenderingServer.get_rendering_device()


func configure_production_terrain_material(config: Dictionary) -> bool:
	var parameter_bytes = config.get("parameter_bytes", PackedByteArray())
	var texture_rids: Array = config.get("texture_rids", [])
	var resources: Array = config.get("resources", [])
	if not parameter_bytes is PackedByteArray \
			or PackedByteArray(parameter_bytes).size() != 23 * 16:
		_record_rejection("production material parameter block must be 368 bytes")
		return false
	if texture_rids.size() != 5 or resources.size() != 5:
		_record_rejection("production material texture inventory must contain five entries")
		return false
	for texture_rid in texture_rids:
		if not texture_rid is RID or not texture_rid.is_valid():
			_record_rejection("production material contains an invalid RD texture")
			return false
	_mutex.lock()
	_pending_production_material = config.duplicate(true)
	_production_material_resources.assign(resources)
	_status["production_material_source"] = str(config.get("source", ""))
	_status["production_material_parameter_bytes"] = PackedByteArray(
		parameter_bytes
	).size()
	_status["production_material_texture_count"] = texture_rids.size()
	_mutex.unlock()
	return true


func submit_explicit_samples(
	densities: PackedFloat32Array,
	gradients: PackedVector3Array,
	materials: PackedInt32Array,
	material_authored: PackedByteArray,
	cells: Array,
	identity: Dictionary,
	publication_sequence: int,
	activate_immediately: bool = true
) -> int:
	var identity_error := _validate_identity(identity, publication_sequence)
	if not identity_error.is_empty():
		_record_rejection(identity_error)
		return 0
	var packing_started_usec := Time.get_ticks_usec()
	var packed: Dictionary = _packer.pack_explicit_samples_for_global_rendering(
		densities,
		gradients,
		materials,
		material_authored,
		cells,
		identity
	)
	var packing_usec := Time.get_ticks_usec() - packing_started_usec
	var packed_bytes := 0
	for packed_buffer in Array(packed.get("input_buffers", [])):
		if packed_buffer is PackedByteArray:
			packed_bytes += PackedByteArray(packed_buffer).size()
	_mutex.lock()
	_status["packing_requests"] = int(_status["packing_requests"]) + 1
	_status["packing_usec_total"] = int(_status["packing_usec_total"]) + packing_usec
	_status["packing_usec_max"] = maxi(
		int(_status["packing_usec_max"]), packing_usec
	)
	_status["packed_bytes_total"] = int(_status["packed_bytes_total"]) + packed_bytes
	_mutex.unlock()
	if str(packed.get("status", "")) != "PASS" \
			or bool(packed.get("fallback_used", true)):
		_record_rejection(str(packed.get("error", "global request packing failed")))
		return 0
	var bounds := _bounds_for_cells(cells)
	if not bool(bounds.get("valid", false)):
		_record_rejection("explicit GPU input bounds are invalid")
		return 0
	return _queue_packed_request(
		Array(packed.get("input_buffers", [])),
		int(packed.get("cell_count", 0)),
		identity,
		publication_sequence,
		activate_immediately,
		bounds.get("minimum", Vector3.ZERO),
		bounds.get("maximum", Vector3.ZERO)
	)


func submit_native_packed_input(
	input_buffers: Array,
	cell_count: int,
	identity: Dictionary,
	publication_sequence: int,
	activate_immediately: bool = true,
	bounds_min: Vector3 = Vector3.ZERO,
	bounds_max: Vector3 = Vector3.ZERO
) -> int:
	var identity_error := _validate_identity(identity, publication_sequence)
	if not identity_error.is_empty():
		_record_rejection(identity_error)
		return 0
	if input_buffers.size() != 13 or cell_count <= 0:
		_record_rejection("native GPU input buffer inventory is invalid")
		return 0
	if not _bounds_are_valid(bounds_min, bounds_max):
		_record_rejection("native GPU input bounds are invalid")
		return 0
	var packed_bytes := 0
	for buffer_value in input_buffers:
		if not buffer_value is PackedByteArray \
				or PackedByteArray(buffer_value).is_empty():
			_record_rejection("native GPU input buffer is empty or untyped")
			return 0
		packed_bytes += PackedByteArray(buffer_value).size()
	_mutex.lock()
	_status["native_packed_requests"] = int(
		_status["native_packed_requests"]
	) + 1
	_status["native_packed_bytes_total"] = int(
		_status["native_packed_bytes_total"]
	) + packed_bytes
	_mutex.unlock()
	return _queue_packed_request(
		input_buffers,
		cell_count,
		identity,
		publication_sequence,
		activate_immediately,
		bounds_min,
		bounds_max
	)


func _queue_packed_request(
	input_buffers: Array,
	cell_count: int,
	identity: Dictionary,
	publication_sequence: int,
	activate_immediately: bool,
	bounds_min: Vector3,
	bounds_max: Vector3
) -> int:
	var key := _identity_key(identity)
	_mutex.lock()
	var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
	if _close_requested or publication_sequence <= latest_sequence \
			or _pending.size() >= REQUEST_CAPACITY:
		_status["rejected"] = int(_status["rejected"]) + 1
		_status["last_error"] = "global render request is stale, closed, or saturated"
		_mutex.unlock()
		return 0
	var request_id := _next_request_id
	_next_request_id += 1
	_latest_sequence_by_key[key] = publication_sequence
	_pending.append({
		"request_id": request_id,
		"key": key,
		"publication_sequence": publication_sequence,
		"identity": identity.duplicate(true),
		"activate_immediately": activate_immediately,
		"cell_count": cell_count,
		"bounds_min": bounds_min,
		"bounds_max": bounds_max,
		"input_buffers": input_buffers.duplicate(),
	})
	_status["requested"] = int(_status["requested"]) + 1
	_status["queued_request_count"] = _pending.size()
	_status["last_error"] = ""
	_mutex.unlock()
	return request_id


func configure_resident_capacity(capacity: int) -> bool:
	_mutex.lock()
	if _status.get("initialized", false) or not _pending.is_empty() \
			or not _entries.is_empty():
		_status["last_error"] = "resident capacity cannot change after use"
		_mutex.unlock()
		return false
	_resident_capacity = clampi(capacity, 1, 256)
	_status["resident_capacity"] = _resident_capacity
	_status["resident_allocation_capacity"] = \
		_resident_allocation_capacity()
	_mutex.unlock()
	return true


func activate_entry(identity: Dictionary, publication_sequence: int) -> bool:
	return _queue_lifecycle_command("ACTIVATE", identity, publication_sequence)


func activate_entries(entries: Array) -> bool:
	if entries.is_empty():
		_record_rejection("global render activation set is empty")
		return false
	var retained_entries: Array[Dictionary] = []
	for entry_value in entries:
		var entry := Dictionary(entry_value)
		var identity := Dictionary(entry.get("identity", {}))
		var publication_sequence := int(entry.get("publication_sequence", 0))
		var identity_error := _validate_identity(identity, publication_sequence)
		if not identity_error.is_empty():
			_record_rejection(identity_error)
			return false
		retained_entries.append({
			"identity": identity.duplicate(true),
			"publication_sequence": publication_sequence,
		})
	_mutex.lock()
	if _close_requested:
		_status["last_error"] = "global render publication is closed"
		_mutex.unlock()
		return false
	_lifecycle_commands.append({
		"action": "ACTIVATE_GROUP",
		"entries": retained_entries,
	})
	_mutex.unlock()
	return true


func retire_entry(identity: Dictionary, publication_sequence: int) -> bool:
	return _queue_lifecycle_command("RETIRE", identity, publication_sequence)


func pop_event() -> Dictionary:
	_mutex.lock()
	if _events.is_empty():
		_mutex.unlock()
		return {}
	var event: Dictionary = _events.pop_front()
	_status["event_count"] = _events.size()
	_mutex.unlock()
	return event


func get_status() -> Dictionary:
	_mutex.lock()
	var result := _status.duplicate(true)
	result["close_requested"] = _close_requested
	result["close_completed"] = _close_completed
	_mutex.unlock()
	return result


func close() -> void:
	enabled = false
	_mutex.lock()
	_close_requested = true
	_pending.clear()
	_lifecycle_commands.clear()
	_status["queued_request_count"] = 0
	_mutex.unlock()
	RenderingServer.call_on_render_thread(Callable(self, "_close_on_render_thread"))


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
		return
	if _rendering_device == null:
		_rendering_device = RenderingServer.get_rendering_device()
	if _rendering_device == null or not _ensure_shaders():
		_record_render_error("global RenderingDevice shader initialization failed")
		return
	_apply_pending_production_material_on_render_thread()
	_drain_pending_on_render_thread()
	_drain_lifecycle_commands_on_render_thread()
	_draw_entries_on_render_thread(render_data)


func _ensure_shaders() -> bool:
	if _compute_pipeline.is_valid() and _raster_shader.is_valid() \
			and _production_raster_shader.is_valid() \
			and _vertex_format >= 0:
		return true
	if _initialization_attempted:
		return false
	_initialization_attempted = true
	_mutex.lock()
	_status["initialization_attempted"] = true
	_mutex.unlock()
	var compute_file := COMPUTE_SHADER_FILE as RDShaderFile
	var raster_file := RASTER_SHADER_FILE as RDShaderFile
	var production_raster_file := PRODUCTION_RASTER_SHADER_FILE as RDShaderFile
	if compute_file == null or raster_file == null or production_raster_file == null \
			or not compute_file.get_base_error().is_empty() \
			or not raster_file.get_base_error().is_empty() \
			or not production_raster_file.get_base_error().is_empty():
		_record_render_error("global render shader import is invalid: %s %s %s" % [
			compute_file.get_base_error() if compute_file != null else "compute missing",
			raster_file.get_base_error() if raster_file != null else "raster missing",
			production_raster_file.get_base_error() \
				if production_raster_file != null else "production raster missing",
		])
		return false
	_compute_shader = _rendering_device.shader_create_from_spirv(
		compute_file.get_spirv()
	)
	if not _compute_shader.is_valid():
		return false
	_compute_pipeline = _rendering_device.compute_pipeline_create(_compute_shader)
	if not _compute_pipeline.is_valid():
		return false
	_raster_shader = _rendering_device.shader_create_from_spirv(
		raster_file.get_spirv()
	)
	if not _raster_shader.is_valid():
		return false
	_production_raster_shader = _rendering_device.shader_create_from_spirv(
		production_raster_file.get_spirv()
	)
	if not _production_raster_shader.is_valid():
		return false
	var attributes: Array[RDVertexAttribute] = []
	attributes.append(_vertex_attribute(
		0, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	))
	attributes.append(_vertex_attribute(
		1, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	))
	attributes.append(_vertex_attribute(
		2, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT
	))
	_vertex_format = _rendering_device.vertex_format_create(attributes)
	if _vertex_format >= 0:
		_arena = ResidentArena.new()
		if not _arena.initialize(
			_rendering_device,
			_compute_shader,
			_compute_pipeline,
			_vertex_format,
			_resident_allocation_capacity()
		):
			_record_render_error(_arena.get_last_error())
			_arena = null
			return false
	_mutex.lock()
	_status["initialized"] = _vertex_format >= 0
	_mutex.unlock()
	return _vertex_format >= 0


func _apply_pending_production_material_on_render_thread() -> void:
	var config := {}
	_mutex.lock()
	if not _pending_production_material.is_empty():
		config = _pending_production_material
		_pending_production_material = {}
	_mutex.unlock()
	if config.is_empty():
		return
	_free_rids_on_render_thread([
		_production_material_set,
		_production_material_buffer,
		_production_material_sampler,
	])
	_production_material_set = RID()
	_production_material_buffer = RID()
	_production_material_sampler = RID()
	var parameter_bytes := PackedByteArray(config.get(
		"parameter_bytes", PackedByteArray()
	))
	_production_material_buffer = _rendering_device.uniform_buffer_create(
		parameter_bytes.size(), parameter_bytes
	)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_production_material_sampler = _rendering_device.sampler_create(sampler_state)
	if not _production_material_buffer.is_valid() \
			or not _production_material_sampler.is_valid():
		_record_render_error("production material buffer or sampler creation failed")
		return
	var uniforms: Array[RDUniform] = []
	var parameters := RDUniform.new()
	parameters.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	parameters.binding = 0
	parameters.add_id(_production_material_buffer)
	uniforms.append(parameters)
	var texture_rids: Array = config.get("texture_rids", [])
	for index in range(texture_rids.size()):
		var texture := RDUniform.new()
		texture.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		texture.binding = index + 1
		texture.add_id(_production_material_sampler)
		texture.add_id(texture_rids[index])
		uniforms.append(texture)
	_production_material_set = _rendering_device.uniform_set_create(
		uniforms, _production_raster_shader, 1
	)
	_mutex.lock()
	_status["production_terrain_material_payload_ready"] = \
		_production_material_set.is_valid()
	_status["production_terrain_albedo_mapping_parity"] = \
		_production_material_set.is_valid()
	_status["production_terrain_material_parity"] = bool(
		_status["production_terrain_albedo_mapping_parity"]
	) and bool(_status["production_terrain_normal_mapping_parity"]) \
		and bool(_status["production_terrain_pbr_lighting_parity"])
	_status["production_material_parity"] = bool(
		_status["production_terrain_material_parity"]
	) and bool(_status["production_static_water_material_parity"])
	if not _production_material_set.is_valid():
		_status["last_error"] = "production material uniform set creation failed"
	_mutex.unlock()


func _drain_pending_on_render_thread() -> void:
	var requests: Array[Dictionary] = []
	_mutex.lock()
	requests.assign(_pending)
	_pending.clear()
	_status["queued_request_count"] = 0
	_mutex.unlock()
	for request in requests:
		var key := str(request.get("key", ""))
		var sequence := int(request.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		_mutex.lock()
		var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
		_mutex.unlock()
		if sequence != latest_sequence:
			_reject_request_on_render_thread(request, "request became stale before allocation")
			continue
		if _entries.size() >= _resident_allocation_capacity():
			_mutex.lock()
			_status["resident_capacity_rejections"] = \
				int(_status["resident_capacity_rejections"]) + 1
			_mutex.unlock()
			_reject_request_on_render_thread(request, "resident allocation capacity reached")
			continue
		var entry := _create_entry_on_render_thread(request)
		if entry.is_empty():
			_reject_request_on_render_thread(request, str(_status.get(
				"last_error", "resident entry creation failed"
			)))
			continue
		_mutex.lock()
		latest_sequence = int(_latest_sequence_by_key.get(key, 0))
		_mutex.unlock()
		if sequence != latest_sequence:
			_free_entry_on_render_thread(entry)
			_reject_request_on_render_thread(request, "request became stale before residency")
			continue
		var activate_immediately := bool(request.get("activate_immediately", true))
		entry["active"] = activate_immediately
		_entries[token] = entry
		if activate_immediately:
			_activate_entry_on_render_thread(key, token, request)
		else:
			_push_event_on_render_thread("PREPARED", request)
		_mutex.lock()
		_status["applied"] = int(_status["applied"]) + 1
		_status["prepared_entries"] = int(_status["prepared_entries"]) + 1
		_status["resident_entry_count"] = _entries.size()
		_status["active_entry_count"] = _active_sequence_by_key.size()
		_status["last_applied_identity"] = Dictionary(
			request.get("identity", {})
		).duplicate(true)
		_status["last_error"] = ""
		_mutex.unlock()


func _drain_lifecycle_commands_on_render_thread() -> void:
	var commands: Array[Dictionary] = []
	_mutex.lock()
	commands.assign(_lifecycle_commands)
	_lifecycle_commands.clear()
	_mutex.unlock()
	for command in commands:
		var action := str(command.get("action", ""))
		if action == "ACTIVATE_GROUP":
			_activate_group_on_render_thread(command)
			continue
		var identity: Dictionary = command.get("identity", {})
		var key := _identity_key(identity)
		var sequence := int(command.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		if action == "ACTIVATE":
			_mutex.lock()
			var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
			_mutex.unlock()
			if not _entries.has(token) or sequence != latest_sequence:
				_push_event_on_render_thread("REJECTED", command, \
					"prepared entry became stale before activation")
				continue
			var entry: Dictionary = _entries[token]
			if Dictionary(entry.get("identity", {})) != identity:
				_push_event_on_render_thread("REJECTED", command, \
					"activation identity differs from prepared entry")
				continue
			entry["active"] = true
			_entries[token] = entry
			_activate_entry_on_render_thread(key, token, command)
		elif action == "RETIRE":
			_retire_entry_on_render_thread(key, token, command)


func _activate_group_on_render_thread(command: Dictionary) -> void:
	var validated: Array[Dictionary] = []
	for source_value in Array(command.get("entries", [])):
		var source := Dictionary(source_value)
		var identity := Dictionary(source.get("identity", {}))
		var key := _identity_key(identity)
		var sequence := int(source.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		_mutex.lock()
		var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
		_mutex.unlock()
		if not _entries.has(token) or sequence != latest_sequence:
			_push_event_on_render_thread(
				"REJECTED", source,
				"prepared activation set became stale before activation"
			)
			return
		var entry: Dictionary = _entries[token]
		if Dictionary(entry.get("identity", {})) != identity:
			_push_event_on_render_thread(
				"REJECTED", source,
				"activation set identity differs from prepared entry"
			)
			return
		validated.append({
			"source": source,
			"key": key,
			"token": token,
		})
	for item in validated:
		var token := str(item.get("token", ""))
		var entry: Dictionary = _entries[token]
		entry["active"] = true
		_entries[token] = entry
		_activate_entry_on_render_thread(
			str(item.get("key", "")), token, Dictionary(item.get("source", {}))
		)


func _activate_entry_on_render_thread(
	key: String, token: String, source: Dictionary
) -> void:
	if _active_sequence_by_key.has(key):
		var old_sequence := int(_active_sequence_by_key[key])
		var old_token := _entry_token(key, old_sequence)
		if old_token != token and _entries.has(old_token):
			var old_entry: Dictionary = _entries[old_token]
			_free_entry_on_render_thread(old_entry)
			_entries.erase(old_token)
			_mutex.lock()
			_status["superseded_entries"] = \
				int(_status["superseded_entries"]) + 1
			_mutex.unlock()
			_push_event_on_render_thread("SUPERSEDED", {
				"identity": Dictionary(old_entry.get("identity", {})),
				"publication_sequence": old_sequence,
			})
	_active_sequence_by_key[key] = int(source.get("publication_sequence", 0))
	_mutex.lock()
	_status["activated_entries"] = int(_status["activated_entries"]) + 1
	_status["resident_entry_count"] = _entries.size()
	_status["active_entry_count"] = _active_sequence_by_key.size()
	_sync_active_lod_inventory_locked()
	_mutex.unlock()
	_push_event_on_render_thread("ACTIVE", source)


func _retire_entry_on_render_thread(
	key: String, token: String, source: Dictionary
) -> void:
	if _entries.has(token):
		_free_entry_on_render_thread(_entries[token])
		_entries.erase(token)
	if int(_active_sequence_by_key.get(key, 0)) \
			== int(source.get("publication_sequence", 0)):
		_active_sequence_by_key.erase(key)
	_mutex.lock()
	_status["retired_entries"] = int(_status["retired_entries"]) + 1
	_status["resident_entry_count"] = _entries.size()
	_status["active_entry_count"] = _active_sequence_by_key.size()
	_sync_active_lod_inventory_locked()
	_mutex.unlock()
	_push_event_on_render_thread("RETIRED", source)


func _sync_active_lod_inventory_locked() -> void:
	var terrain_counts := {}
	var water_counts := {}
	for key_value in _active_sequence_by_key.keys():
		var key := str(key_value)
		var token := _entry_token(key, int(_active_sequence_by_key[key]))
		if not _entries.has(token):
			continue
		var identity := Dictionary(Dictionary(_entries[token]).get("identity", {}))
		var lod := str(int(identity.get("lod", 0)))
		var counts := water_counts \
			if str(identity.get("surface", "")) == "static_water" else terrain_counts
		counts[lod] = int(counts.get(lod, 0)) + 1
	_status["active_terrain_lod_counts"] = terrain_counts
	_status["active_static_water_lod_counts"] = water_counts


func _create_entry_on_render_thread(request: Dictionary) -> Dictionary:
	var input_buffers: Array = request.get("input_buffers", [])
	var cell_count := int(request.get("cell_count", 0))
	if input_buffers.size() != 13 or cell_count <= 0 or _arena == null:
		_record_render_error("global render request buffer inventory changed")
		return {}
	var entry: Dictionary = _arena.lease_and_dispatch(input_buffers, cell_count)
	_sync_arena_status_on_render_thread()
	if entry.is_empty():
		_record_render_error(_arena.get_last_error())
		return {}
	entry["publication_sequence"] = int(request.get("publication_sequence", 0))
	entry["identity"] = Dictionary(request.get("identity", {})).duplicate(true)
	entry["bounds_min"] = request.get("bounds_min", Vector3.ZERO)
	entry["bounds_max"] = request.get("bounds_max", Vector3.ZERO)
	return entry


func _draw_entries_on_render_thread(render_data: RenderData) -> void:
	if _entries.is_empty():
		return
	var scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if scene_buffers == null or scene_data == null:
		_record_render_error("global render scene buffers are unavailable")
		return
	var size := scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var view_count := scene_buffers.get_view_count()
	var draw_calls := 0
	var visibility_tests := 0
	var culled_surfaces := 0
	var visible_surfaces := 0
	var compact_command_records := 0
	var source_records_avoided := 0
	var maximum_commands_per_view := 0
	var maximum_records_avoided_per_view := 0
	var last_tested_bounds_min := Vector3.ZERO
	var last_tested_bounds_max := Vector3.ZERO
	for view in range(view_count):
		var view_command_records := 0
		var view_records_avoided := 0
		var color := scene_buffers.get_color_layer(view)
		var depth := scene_buffers.get_depth_layer(view)
		var framebuffer := _framebuffer_for(color, depth)
		if not framebuffer.is_valid() or not _ensure_raster_pipeline(
			_rendering_device.framebuffer_get_format(framebuffer)
		):
			_record_render_error("global render framebuffer or pipeline failed")
			return
		var scene_uniform := RDUniform.new()
		scene_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		scene_uniform.binding = 0
		scene_uniform.add_id(scene_data.get_uniform_buffer())
		var scene_set: RID = UniformSetCacheRD.get_cache(
			_raster_shader, 0, [scene_uniform]
		)
		if not scene_set.is_valid():
			_record_render_error("global render scene uniform set failed")
			return
		var production_scene_set := RID()
		var production_ready := _production_material_set.is_valid()
		if production_ready:
			if not _ensure_production_raster_pipeline(
				_rendering_device.framebuffer_get_format(framebuffer)
			):
				_record_render_error("production terrain raster pipeline failed")
				return
			production_scene_set = UniformSetCacheRD.get_cache(
				_production_raster_shader, 0, [scene_uniform]
			)
			if not production_scene_set.is_valid():
				_record_render_error("production render scene uniform set failed")
				return
		var draw_list := _rendering_device.draw_list_begin(framebuffer)
		var production_pipeline_bound := false
		_rendering_device.draw_list_bind_render_pipeline(draw_list, _raster_pipeline)
		_rendering_device.draw_list_bind_uniform_set(draw_list, scene_set, 0)
		var push_bytes := PackedInt32Array([view, view_count, 0, 0]).to_byte_array()
		for entry_value in _entries.values():
			var entry: Dictionary = entry_value
			if not bool(entry.get("active", false)):
				continue
			visibility_tests += 1
			var source_cell_count := int(entry.get("cell_count", 0))
			last_tested_bounds_min = entry.get("bounds_min", Vector3.ZERO)
			last_tested_bounds_max = entry.get("bounds_max", Vector3.ZERO)
			if not _entry_visible_for_view(entry, scene_data, view):
				culled_surfaces += 1
				view_records_avoided += source_cell_count
				continue
			visible_surfaces += 1
			var use_production := production_ready and str(Dictionary(
				entry.get("identity", {})
			).get("surface", "")) == "terrain"
			if use_production != production_pipeline_bound:
				if use_production:
					_rendering_device.draw_list_bind_render_pipeline(
						draw_list, _production_raster_pipeline
					)
					_rendering_device.draw_list_bind_uniform_set(
						draw_list, production_scene_set, 0
					)
					_rendering_device.draw_list_bind_uniform_set(
						draw_list, _production_material_set, 1
					)
				else:
					_rendering_device.draw_list_bind_render_pipeline(
						draw_list, _raster_pipeline
					)
					_rendering_device.draw_list_bind_uniform_set(
						draw_list, scene_set, 0
					)
				production_pipeline_bound = use_production
			_rendering_device.draw_list_bind_vertex_array(
				draw_list, entry.get("vertex_array", RID())
			)
			_rendering_device.draw_list_bind_index_array(
				draw_list, entry.get("index_array", RID())
			)
			_rendering_device.draw_list_set_push_constant(
				draw_list, push_bytes, push_bytes.size()
			)
			_rendering_device.draw_list_draw_indirect(
				draw_list,
				true,
				entry.get("indirect_buffer", RID()),
				int(entry.get("indirect_offset", 0)),
				int(entry.get("indirect_draw_count", 1)),
				DRAW_COMMAND_STRIDE
			)
			draw_calls += 1
			view_command_records += 1
			view_records_avoided += maxi(0, source_cell_count - 1)
		_rendering_device.draw_list_end()
		compact_command_records += view_command_records
		source_records_avoided += view_records_avoided
		maximum_commands_per_view = maxi(
			maximum_commands_per_view, view_command_records
		)
		maximum_records_avoided_per_view = maxi(
			maximum_records_avoided_per_view, view_records_avoided
		)
	_mutex.lock()
	_status["draw_frames"] = int(_status["draw_frames"]) + 1
	_status["indirect_draw_calls"] = int(_status["indirect_draw_calls"]) + draw_calls
	_status["visibility_test_count"] = int(
		_status["visibility_test_count"]
	) + visibility_tests
	_status["visibility_culled_count"] = int(
		_status["visibility_culled_count"]
	) + culled_surfaces
	_status["last_visible_surface_count"] = visible_surfaces
	_status["last_culled_surface_count"] = culled_surfaces
	var camera_transform := scene_data.get_cam_transform()
	_status["last_camera_origin"] = camera_transform.origin
	_status["last_camera_basis_z"] = camera_transform.basis.z
	_status["last_tested_bounds_min"] = last_tested_bounds_min
	_status["last_tested_bounds_max"] = last_tested_bounds_max
	_status["compact_indirect_command_records"] = int(
		_status["compact_indirect_command_records"]
	) + compact_command_records
	_status["source_cell_indirect_records_avoided"] = int(
		_status["source_cell_indirect_records_avoided"]
	) + source_records_avoided
	_status["max_compact_command_records_per_view"] = maxi(
		int(_status["max_compact_command_records_per_view"]),
		maximum_commands_per_view
	)
	_status["max_source_cell_records_avoided_per_view"] = maxi(
		int(_status["max_source_cell_records_avoided_per_view"]),
		maximum_records_avoided_per_view
	)
	_mutex.unlock()


func _ensure_raster_pipeline(framebuffer_format: int) -> bool:
	if _raster_pipeline.is_valid() and _raster_pipeline_format == framebuffer_format:
		return true
	if _raster_pipeline.is_valid():
		_rendering_device.free_rid(_raster_pipeline)
		_raster_pipeline = RID()
	var rasterization := RDPipelineRasterizationState.new()
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var depth_stencil := RDPipelineDepthStencilState.new()
	depth_stencil.enable_depth_test = true
	depth_stencil.enable_depth_write = true
	depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var color_attachment := RDPipelineColorBlendStateAttachment.new()
	color_attachment.enable_blend = false
	var color_blend := RDPipelineColorBlendState.new()
	color_blend.attachments = [color_attachment]
	_raster_pipeline = _rendering_device.render_pipeline_create(
		_raster_shader,
		framebuffer_format,
		_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterization,
		RDPipelineMultisampleState.new(),
		depth_stencil,
		color_blend
	)
	_raster_pipeline_format = framebuffer_format
	return _raster_pipeline.is_valid()


func _ensure_production_raster_pipeline(framebuffer_format: int) -> bool:
	if _production_raster_pipeline.is_valid() \
			and _production_raster_pipeline_format == framebuffer_format:
		return true
	if _production_raster_pipeline.is_valid():
		_rendering_device.free_rid(_production_raster_pipeline)
		_production_raster_pipeline = RID()
	var rasterization := RDPipelineRasterizationState.new()
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_BACK
	rasterization.front_face = RenderingDevice.POLYGON_FRONT_FACE_COUNTER_CLOCKWISE
	var depth_stencil := RDPipelineDepthStencilState.new()
	depth_stencil.enable_depth_test = true
	depth_stencil.enable_depth_write = true
	depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var color_attachment := RDPipelineColorBlendStateAttachment.new()
	color_attachment.enable_blend = false
	var color_blend := RDPipelineColorBlendState.new()
	color_blend.attachments = [color_attachment]
	_production_raster_pipeline = _rendering_device.render_pipeline_create(
		_production_raster_shader,
		framebuffer_format,
		_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterization,
		RDPipelineMultisampleState.new(),
		depth_stencil,
		color_blend
	)
	_production_raster_pipeline_format = framebuffer_format
	return _production_raster_pipeline.is_valid()


func _framebuffer_for(color: RID, depth: RID) -> RID:
	if not color.is_valid() or not depth.is_valid():
		return RID()
	var key := "%d:%d" % [color.get_id(), depth.get_id()]
	if _framebuffers.has(key):
		var existing: RID = _framebuffers[key]
		if existing.is_valid() and _rendering_device.framebuffer_is_valid(existing):
			return existing
	var framebuffer := _rendering_device.framebuffer_create([color, depth])
	if framebuffer.is_valid():
		_framebuffers[key] = framebuffer
	return framebuffer


func _close_on_render_thread() -> void:
	for entry in _entries.values():
		_free_entry_on_render_thread(entry)
	_entries.clear()
	_active_sequence_by_key.clear()
	if _arena != null:
		_arena.close()
		_sync_arena_status_on_render_thread()
		_arena = null
	for framebuffer in _framebuffers.values():
		if framebuffer is RID and framebuffer.is_valid():
			_rendering_device.free_rid(framebuffer)
	_framebuffers.clear()
	_free_rids_on_render_thread([
		_production_material_set, _production_material_buffer,
		_production_material_sampler, _production_raster_pipeline,
		_production_raster_shader, _raster_pipeline, _raster_shader,
		_compute_pipeline, _compute_shader,
	])
	_production_material_set = RID()
	_production_material_buffer = RID()
	_production_material_sampler = RID()
	_production_raster_pipeline = RID()
	_production_raster_shader = RID()
	_raster_pipeline = RID()
	_raster_shader = RID()
	_compute_pipeline = RID()
	_compute_shader = RID()
	_mutex.lock()
	_status["resident_entry_count"] = 0
	_status["active_entry_count"] = 0
	_close_completed = true
	_mutex.unlock()


func _free_entry_on_render_thread(entry: Dictionary) -> void:
	if _arena != null:
		_arena.release(entry)
		_sync_arena_status_on_render_thread()


func _sync_arena_status_on_render_thread() -> void:
	if _arena == null:
		return
	var arena_status: Dictionary = _arena.get_status()
	_mutex.lock()
	_status["arena_status"] = arena_status
	_status["arena_page_count"] = int(arena_status.get("page_count", 0))
	_status["arena_allocated_slot_count"] = int(
		arena_status.get("allocated_slots", 0)
	)
	_status["arena_active_slot_count"] = int(arena_status.get("active_slots", 0))
	_status["arena_peak_active_slot_count"] = int(
		arena_status.get("peak_active_slots", 0)
	)
	_status["arena_allocated_bytes"] = int(arena_status.get("allocated_bytes", 0))
	_status["arena_slot_leases"] = int(arena_status.get("slot_leases", 0))
	_status["arena_slot_reuses"] = int(arena_status.get("slot_reuses", 0))
	_status["arena_slot_releases"] = int(arena_status.get("slot_releases", 0))
	_mutex.unlock()


func _free_rids_on_render_thread(rids: Array) -> void:
	for value in rids:
		if value is RID and value.is_valid():
			_rendering_device.free_rid(value)


func _record_rejection(error: String) -> void:
	_mutex.lock()
	_status["rejected"] = int(_status["rejected"]) + 1
	_status["last_error"] = error
	_mutex.unlock()


func _record_render_error(error: String) -> void:
	_mutex.lock()
	_status["last_error"] = error
	_mutex.unlock()


func _queue_lifecycle_command(
	action: String, identity: Dictionary, publication_sequence: int
) -> bool:
	var identity_error := _validate_identity(identity, publication_sequence)
	if not identity_error.is_empty():
		_record_rejection(identity_error)
		return false
	_mutex.lock()
	if _close_requested:
		_status["last_error"] = "global render publication is closed"
		_mutex.unlock()
		return false
	_lifecycle_commands.append({
		"action": action,
		"identity": identity.duplicate(true),
		"publication_sequence": publication_sequence,
	})
	_mutex.unlock()
	return true


func _reject_request_on_render_thread(request: Dictionary, error: String) -> void:
	_mutex.lock()
	if error.contains("stale"):
		_status["stale_skips"] = int(_status["stale_skips"]) + 1
	else:
		_status["rejected"] = int(_status["rejected"]) + 1
	_status["last_error"] = error
	_mutex.unlock()
	_push_event_on_render_thread("REJECTED", request, error)


func _push_event_on_render_thread(
	event_status: String, source: Dictionary, error: String = ""
) -> void:
	var event := {
		"schema": "world_transvoxel.terrain.gpu_global_render_event.v1",
		"status": event_status,
		"request_id": int(source.get("request_id", 0)),
		"publication_sequence": int(source.get("publication_sequence", 0)),
		"identity": Dictionary(source.get("identity", {})).duplicate(true),
		"error": error,
	}
	_mutex.lock()
	_events.append(event)
	_status["event_count"] = _events.size()
	_mutex.unlock()


static func _bounds_for_cells(cells: Array) -> Dictionary:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for cell_value in cells:
		if not cell_value is Dictionary:
			return {"valid": false}
		var cell := Dictionary(cell_value)
		var origin: Vector3 = cell.get("origin", Vector3.ZERO)
		var spacing := float(cell.get(
			"cell_size", cell.get("sample_spacing", 0.0)
		))
		var points: Array[Vector3] = []
		if str(cell.get("type", "")) == "regular":
			points.assign([
				origin,
				origin + Vector3(spacing, spacing, spacing),
			])
		else:
			var axes := _transition_basis_vectors(int(cell.get("orientation", 0)))
			var width := float(cell.get("transition_width", 0.0))
			for u in [0.0, 2.0 * spacing]:
				for v in [0.0, 2.0 * spacing]:
					for w in [0.0, width]:
						points.append(
							origin + axes[0] * u + axes[1] * v + axes[2] * w
						)
		for point in points:
			minimum = Vector3(
				minf(minimum.x, point.x),
				minf(minimum.y, point.y),
				minf(minimum.z, point.z)
			)
			maximum = Vector3(
				maxf(maximum.x, point.x),
				maxf(maximum.y, point.y),
				maxf(maximum.z, point.z)
			)
	return {
		"valid": _bounds_are_valid(minimum, maximum),
		"minimum": minimum,
		"maximum": maximum,
	}


static func _transition_basis_vectors(orientation: int) -> Array[Vector3]:
	match orientation:
		0:
			return [Vector3.UP, Vector3.FORWARD * -1.0, Vector3.RIGHT]
		1:
			return [Vector3.UP, Vector3.FORWARD, Vector3.LEFT]
		2:
			return [Vector3.BACK, Vector3.RIGHT, Vector3.UP]
		3:
			return [Vector3.BACK, Vector3.LEFT, Vector3.DOWN]
		4:
			return [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
		_:
			return [Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD]


static func _bounds_are_valid(minimum: Vector3, maximum: Vector3) -> bool:
	return minimum.is_finite() and maximum.is_finite() \
		and minimum.x <= maximum.x and minimum.y <= maximum.y \
		and minimum.z <= maximum.z


static func _entry_visible_for_view(
	entry: Dictionary, scene_data: RenderSceneData, view: int
) -> bool:
	var minimum: Vector3 = entry.get("bounds_min", Vector3.ZERO)
	var maximum: Vector3 = entry.get("bounds_max", Vector3.ZERO)
	if not _bounds_are_valid(minimum, maximum):
		return true
	var camera_transform := scene_data.get_cam_transform()
	var eye_offset := scene_data.get_view_eye_offset(view)
	var eye_transform := Transform3D(
		camera_transform.basis,
		camera_transform.origin + camera_transform.basis * eye_offset
	)
	var world_to_view := eye_transform.affine_inverse()
	var projection := scene_data.get_view_projection(view)
	var behind := 0
	var left := 0
	var right := 0
	var below := 0
	var above := 0
	for mask in range(8):
		var corner := Vector3(
			maximum.x if (mask & 1) != 0 else minimum.x,
			maximum.y if (mask & 2) != 0 else minimum.y,
			maximum.z if (mask & 4) != 0 else minimum.z
		)
		var view_point := world_to_view * corner
		var clip: Vector4 = projection * Vector4(
			view_point.x, view_point.y, view_point.z, 1.0
		)
		behind += 1 if view_point.z >= 0.0 else 0
		left += 1 if clip.x < -clip.w else 0
		right += 1 if clip.x > clip.w else 0
		below += 1 if clip.y < -clip.w else 0
		above += 1 if clip.y > clip.w else 0
	return behind < 8 and left < 8 and right < 8 and below < 8 and above < 8


static func _vertex_attribute(location: int, format: int) -> RDVertexAttribute:
	var attribute := RDVertexAttribute.new()
	attribute.location = location
	attribute.offset = 0
	attribute.format = format
	attribute.stride = 16
	attribute.frequency = RenderingDevice.VERTEX_FREQUENCY_VERTEX
	return attribute


static func _identity_key(identity: Dictionary) -> String:
	return "%s:%d:%d:%d:%d" % [
		str(identity.get("surface", "")),
		int(identity.get("page_x", 0)),
		int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)),
		int(identity.get("lod", 0)),
	]


static func _entry_token(key: String, publication_sequence: int) -> String:
	return "%s@%d" % [key, publication_sequence]


func _resident_allocation_capacity() -> int:
	return _resident_capacity * MAXIMUM_SURFACES_PER_CHUNK + REQUEST_CAPACITY


static func _validate_identity(identity: Dictionary, publication_sequence: int) -> String:
	if publication_sequence <= 0:
		return "global render publication sequence must be positive"
	for field in REQUIRED_IDENTITY_FIELDS:
		if not identity.has(field):
			return "global render identity lacks %s" % field
	if str(identity.get("surface", "")) not in ["terrain", "static_water"] \
			or int(identity.get("sample_count", 0)) <= 0:
		return "global render identity surface or sample count is invalid"
	return ""
