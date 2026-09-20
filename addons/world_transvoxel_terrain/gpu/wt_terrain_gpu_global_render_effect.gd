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
const COMMIT_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_commit.glsl"
)
const COMPLETION_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_completion.glsl"
)
const COMPACT_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_compact.glsl"
)
const RASTER_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render.glsl"
)
const PRODUCTION_RASTER_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_production.glsl"
)
const PRODUCTION_WATER_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_water.glsl"
)
const SCENE_COLOR_COPY_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_scene_color_copy.glsl"
)
const RESULT_SCHEMA := "world_transvoxel.terrain.gpu_global_render_publication.v1"
const REQUEST_CAPACITY := 16
const INTERACTION_REQUEST_CAPACITY := 8
const BACKGROUND_DISPATCH_CAPACITY := 4
const INTERACTION_DISPATCH_CAPACITY := 8
const DEFAULT_RESIDENT_CAPACITY := 64
const MAXIMUM_SURFACES_PER_CHUNK := 2
const SCRATCH_SLOT_CAPACITY := 64
const COMPACTION_SETTLE_CALLBACKS := 4
const DISPATCH_COMPLETION_CAPACITY_PER_CALLBACK := 16
const TELEMETRY_COMPLETION_CAPACITY_PER_CALLBACK := 8
const LIFECYCLE_COMMAND_CAPACITY_PER_CALLBACK := 16
const DRAW_COMMAND_STRIDE := 20
const DRAW_BIN_EXTENT := 128.0
const REQUIRED_IDENTITY_FIELDS := [
	"page_x", "page_y", "page_z", "lod", "generation", "source_revision",
	"world_revision", "transition_mask", "field_mode", "sample_count", "surface",
]

var _rendering_device: RenderingDevice
var _packer = MeshingCandidate.new()
var _arena
var _mutex := Mutex.new()
var _pending: Array[Dictionary] = []
var _pending_interaction: Array[Dictionary] = []
var _inflight_extractions: Dictionary = {}
var _dispatch_pending_tickets: Dictionary = {}
var _cancelled_inflight_tickets: Dictionary = {}
var _pending_compactions: Array[String] = []
var _compaction_eligible_callback_by_token: Dictionary = {}
var _compaction_idle_callbacks := 0
var _render_callback_sequence := 0
var _lifecycle_commands: Array[Dictionary] = []
var _interaction_lifecycle_commands: Array[Dictionary] = []
var _priority_events: Dictionary = {}
var _events: Dictionary = {}
var _priority_event_head := 0
var _priority_event_tail := 0
var _event_head := 0
var _event_tail := 0
var _debug_geometry_requests: Array[Dictionary] = []
var _debug_geometry_results: Dictionary = {}
var _latest_sequence_by_key: Dictionary = {}
var _protected_activation_tokens: Dictionary = {}
var _entries: Dictionary = {}
var _active_sequence_by_key: Dictionary = {}
var _framebuffers: Dictionary = {}
var _next_request_id := 1
var _next_debug_geometry_request_id := 1
var _resident_capacity := DEFAULT_RESIDENT_CAPACITY
var _compute_shader := RID()
var _compute_pipeline := RID()
var _commit_shader := RID()
var _commit_pipeline := RID()
var _completion_shader := RID()
var _completion_pipeline := RID()
var _compact_shader := RID()
var _compact_pipeline := RID()
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
var _production_water_shader := RID()
var _production_water_pipeline := RID()
var _production_water_pipeline_format := -1
var _production_water_buffer := RID()
var _production_water_set := RID()
var _pending_production_water := {}
var _production_water_resource
var _scene_color_copy_shader := RID()
var _scene_color_copy_pipeline := RID()
var _scene_color_sampler := RID()
var _vertex_format := -1
var _initialization_attempted := false
var _close_requested := false
var _close_completed := false
var _stage_timing_enabled := OS.get_cmdline_user_args().has("--gpu-stage-timing")
var _critical_path_timeline_enabled := OS.get_cmdline_user_args().has(
	"--gpu-lifecycle-history"
)
var _stage_timing_usec: Dictionary = {}
var _active_lod_inventory_dirty := false
var _draw_bins: Array[Dictionary] = []
var _status := {
	"schema": RESULT_SCHEMA,
	"initialized": false,
	"initialization_attempted": false,
	"global_rendering_device": true,
	"render_thread_owned": true,
	"same_global_device_compute_raster": true,
	"compositor_callback": "pre_transparent",
	"resource_architecture": "bounded_gpu_validated_exact_meshlet_residency",
	"resident_buffer_count_per_entry": 1,
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
	"arena_scratch_in_flight": 0,
	"arena_scratch_allocated_bytes": 0,
	"arena_resident_allocated_bytes": 0,
	"arena_counter_readback_bytes": 0,
	"packing_requests": 0,
	"packing_usec_total": 0,
	"packing_usec_max": 0,
	"packed_bytes_total": 0,
	"native_packed_requests": 0,
	"native_packed_bytes_total": 0,
	"gpu_written_indirect_commands": true,
	"compacted_surface_indirect_commands": true,
	"indirect_commands_per_surface": 44,
	"meshlet_cells_per_axis": 8,
	"asynchronous_summary_bytes": 20,
	"device_local_index_copy_used": true,
	"visibility_culling": "conservative_aabb_frustum",
	"visibility_bounds_position_space": "world",
	"visibility_culling_near_far": false,
	"per_view_visibility_context": true,
	"cached_mono_terrain_push_constants": true,
	"conservative_draw_bins": true,
	"draw_bin_extent": DRAW_BIN_EXTENT,
	"draw_bin_count": 0,
	"bin_visibility_test_count": 0,
	"bin_culled_surface_count": 0,
	"visibility_test_count": 0,
	"visibility_culled_count": 0,
	"last_visible_surface_count": 0,
	"last_culled_surface_count": 0,
	"cached_terrain_push_constant_uses": 0,
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
	"interaction_request_capacity": INTERACTION_REQUEST_CAPACITY,
	"background_dispatch_capacity": BACKGROUND_DISPATCH_CAPACITY,
	"interaction_dispatch_capacity": INTERACTION_DISPATCH_CAPACITY,
	"resident_capacity": DEFAULT_RESIDENT_CAPACITY,
	"resident_allocation_capacity": (
		DEFAULT_RESIDENT_CAPACITY * MAXIMUM_SURFACES_PER_CHUNK
		+ REQUEST_CAPACITY + INTERACTION_REQUEST_CAPACITY
	),
	"requested": 0,
	"applied": 0,
	"rejected": 0,
	"stale_skips": 0,
	"cancelled_queued_requests": 0,
	"cancelled_inflight_requests": 0,
	"discarded_cancelled_readbacks": 0,
	"superseded_entries": 0,
	"protected_activation_entries": 0,
	"protected_stale_activations": 0,
	"prepared_entries": 0,
	"activated_entries": 0,
	"transition_remask_commands": 0,
	"transition_remask_surfaces": 0,
	"retired_entries": 0,
	"resident_capacity_rejections": 0,
	"draw_frames": 0,
	"indirect_draw_calls": 0,
	"resident_entry_count": 0,
	"active_entry_count": 0,
	"active_terrain_lod_counts": {},
	"active_static_water_lod_counts": {},
	"active_empty_entry_count": 0,
	"active_partial_entry_count": 0,
	"active_empty_entry_examples": [],
	"active_partial_entry_examples": [],
	"event_count": 0,
	"priority_event_count": 0,
	"queued_request_count": 0,
	"queued_interaction_request_count": 0,
	"inflight_extraction_count": 0,
	"telemetry_pending_count": 0,
	"peak_telemetry_pending_count": 0,
	"inflight_upload_bytes_retained": 0,
	"released_upload_bytes_after_dispatch": 0,
	"dispatch_pending_count": 0,
	"background_dispatch_pending_count": 0,
	"interaction_dispatch_pending_count": 0,
	"peak_background_dispatch_pending_count": 0,
	"peak_interaction_dispatch_pending_count": 0,
	"background_dispatch_deferrals": 0,
	"interaction_dispatch_deferrals": 0,
	"pending_compaction_count": 0,
	"compactions_completed": 0,
	"compaction_interaction_deferrals": 0,
	"compaction_idle_callbacks": 0,
	"invalid_dispatch_completions": 0,
	"dispatch_completion_requests": 0,
	"dispatch_completion_completions": 0,
	"dispatch_completion_bytes": 0,
	"dispatch_completion_budget_deferrals": 0,
	"telemetry_completion_budget_deferrals": 0,
	"lifecycle_command_budget_deferrals": 0,
	"dispatch_completion_capacity_per_callback": DISPATCH_COMPLETION_CAPACITY_PER_CALLBACK,
	"telemetry_completion_capacity_per_callback": TELEMETRY_COMPLETION_CAPACITY_PER_CALLBACK,
	"lifecycle_command_capacity_per_callback": LIFECYCLE_COMMAND_CAPACITY_PER_CALLBACK,
	"pending_dispatch_completion_count": 0,
	"pending_telemetry_completion_count": 0,
	"counter_readback_bytes": 0,
	"geometry_readback_bytes": 0,
	"render_target_readback_bytes": 0,
	"cpu_meshing_used": false,
	"cpu_chunk_finalization_used": false,
	"array_mesh_upload_used": false,
	"cpu_collision_authority": true,
	"atomic_surface_set_activation": true,
	"gpu_cohort_validation": true,
	"cpu_readback_blocks_publication": false,
	"production_chunk_replacement": false,
	"production_material_parity": false,
	"production_terrain_material_payload_ready": false,
	"production_terrain_albedo_mapping_parity": false,
	"production_terrain_roughness_mapping_parity": false,
	"production_terrain_accepted_normal_response_parity": false,
	"production_terrain_bounded_pbr_response_parity": false,
	"production_terrain_directional_ambient_lighting_parity": false,
	"production_terrain_normal_mapping_parity": false,
	"production_terrain_pbr_lighting_parity": false,
	"production_terrain_material_parity": false,
	"production_static_water_material_parity": false,
	"production_static_water_material_payload_ready": false,
	"production_static_water_fresnel_tint_parity": false,
	"production_static_water_refraction_parity": false,
	"production_static_water_scene_copy_ready": false,
	"production_material_source": "",
	"production_material_parameter_bytes": 0,
	"production_material_texture_count": 0,
	"production_water_material_source": "",
	"production_water_parameter_bytes": 0,
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
			or PackedByteArray(parameter_bytes).size() != 26 * 16:
		_record_rejection("production material parameter block must be 416 bytes")
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


func configure_production_static_water_material(config: Dictionary) -> bool:
	var parameter_bytes = config.get("parameter_bytes", PackedByteArray())
	var resource = config.get("resource")
	if not parameter_bytes is PackedByteArray \
			or PackedByteArray(parameter_bytes).size() != 3 * 16:
		_record_rejection("production water parameter block must be 48 bytes")
		return false
	if not resource is ShaderMaterial:
		_record_rejection("production water material resource is invalid")
		return false
	_mutex.lock()
	_pending_production_water = config.duplicate(true)
	_production_water_resource = resource
	_status["production_water_material_source"] = str(config.get("source", ""))
	_status["production_water_parameter_bytes"] = PackedByteArray(
		parameter_bytes
	).size()
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
	bounds_max: Vector3 = Vector3.ZERO,
	proven_empty: bool = false
) -> int:
	var identity_error := _validate_identity(identity, publication_sequence)
	if not identity_error.is_empty():
		_record_rejection(identity_error)
		return 0
	if cell_count <= 0 or (not proven_empty and input_buffers.size() != 13) \
			or (proven_empty and not input_buffers.is_empty() \
				and input_buffers.size() != 13):
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
		bounds_max,
		proven_empty
	)


func _queue_packed_request(
	input_buffers: Array,
	cell_count: int,
	identity: Dictionary,
	publication_sequence: int,
	activate_immediately: bool,
	bounds_min: Vector3,
	bounds_max: Vector3,
	proven_empty: bool = false
) -> int:
	var key := _identity_key(identity)
	var interaction := bool(identity.get("incremental_edit", false)) \
			or bool(identity.get("interaction_priority", false))
	_mutex.lock()
	var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
	if _close_requested or publication_sequence <= latest_sequence \
			or (interaction and _pending_interaction.size() >= INTERACTION_REQUEST_CAPACITY) \
			or (not interaction and _pending.size() >= REQUEST_CAPACITY):
		_status["rejected"] = int(_status["rejected"]) + 1
		_status["last_error"] = "global render request is stale, closed, or saturated"
		_mutex.unlock()
		return 0
	# Supersession is a queue operation, not a completion operation. Release the
	# packed page arrays for older unpublished generations immediately so rapid
	# movement and editing cannot accumulate a cold upload tail behind the newest
	# request for the same chunk.
	var retained_interaction: Array[Dictionary] = []
	var retained_background: Array[Dictionary] = []
	var superseded_queued := 0
	for queued_value in _pending_interaction:
		var queued := Dictionary(queued_value)
		if str(queued.get("key", "")) == key:
			superseded_queued += 1
		else:
			retained_interaction.append(queued)
	for queued_value in _pending:
		var queued := Dictionary(queued_value)
		if str(queued.get("key", "")) == key:
			superseded_queued += 1
		else:
			retained_background.append(queued)
	if superseded_queued > 0:
		_pending_interaction = retained_interaction
		_pending = retained_background
		_status["cancelled_queued_requests"] = int(
			_status["cancelled_queued_requests"]
		) + superseded_queued
	var request_id := _next_request_id
	_next_request_id += 1
	_latest_sequence_by_key[key] = publication_sequence
	var input_byte_count := 0
	for buffer_value in input_buffers:
		if buffer_value is PackedByteArray:
			input_byte_count += PackedByteArray(buffer_value).size()
	var request := {
		"request_id": request_id,
		"key": key,
		"publication_sequence": publication_sequence,
		"identity": identity.duplicate(true),
		"activate_immediately": activate_immediately,
		"cell_count": cell_count,
		"bounds_min": bounds_min,
		"bounds_max": bounds_max,
		"proven_empty": proven_empty,
		"input_byte_count": input_byte_count,
		"input_buffers": input_buffers.duplicate(),
	}
	if interaction:
		_pending_interaction.append(request)
	else:
		_pending.append(request)
	_status["requested"] = int(_status["requested"]) + 1
	_status["queued_request_count"] = _pending.size() + _pending_interaction.size()
	_status["queued_interaction_request_count"] = _pending_interaction.size()
	_status["last_error"] = ""
	_mutex.unlock()
	return request_id


func configure_resident_capacity(capacity: int) -> bool:
	_mutex.lock()
	if _status.get("initialized", false) or not _pending.is_empty() \
			or not _pending_interaction.is_empty() \
			or not _entries.is_empty():
		_status["last_error"] = "resident capacity cannot change after use"
		_mutex.unlock()
		return false
	_resident_capacity = clampi(capacity, 1, 4096)
	_status["resident_capacity"] = _resident_capacity
	_status["resident_allocation_capacity"] = \
		_resident_allocation_capacity()
	_mutex.unlock()
	return true


func activate_entry(identity: Dictionary, publication_sequence: int) -> bool:
	return _queue_lifecycle_command("ACTIVATE", identity, publication_sequence)


func stage_activation_entries(entries: Array) -> bool:
	return _queue_activation_group_command("STAGE_ACTIVATION_GROUP", entries)


func activate_entries(entries: Array) -> bool:
	return _queue_activation_group_command("ACTIVATE_GROUP", entries)


func activate_pending_entries(entries: Array) -> bool:
	return _queue_activation_group_command("ACTIVATE_GROUP", entries, [], false)


func replace_entries(entries: Array, retirements: Array) -> bool:
	if retirements.is_empty():
		return activate_entries(entries)
	return _queue_activation_group_command(
		"REPLACE_GROUP", entries, retirements
	)


func remask_active_entries(entries: Array, controller_group_key: String) -> bool:
	if entries.is_empty() or controller_group_key.is_empty():
		_record_rejection("resident transition remask inventory is empty")
		return false
	var retained: Array[Dictionary] = []
	for entry_value in entries:
		var source := Dictionary(entry_value)
		var identity := Dictionary(source.get("identity", {}))
		var sequence := int(source.get("publication_sequence", 0))
		if _validate_identity(identity, sequence) != "":
			_record_rejection("resident transition remask identity is invalid")
			return false
		retained.append({
			"identity": identity.duplicate(true),
			"publication_sequence": sequence,
			"controller_group_key": controller_group_key,
		})
	_mutex.lock()
	_status["transition_remask_commands"] = int(
		_status["transition_remask_commands"]
	) + 1
	_lifecycle_commands.append({
		"action": "REMASK_GROUP",
		"entries": retained,
		"controller_group_key": controller_group_key,
	})
	_mutex.unlock()
	return true


func _queue_activation_group_command(
	action: String, entries: Array, retirements: Array = [],
	_dispatch_immediately: bool = true
) -> bool:
	if entries.is_empty() and (action != "REPLACE_GROUP" or retirements.is_empty()):
		_record_rejection("global render activation group is empty")
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
	var retained_retirements: Array[Dictionary] = []
	for entry_value in retirements:
		var entry := Dictionary(entry_value)
		var identity := Dictionary(entry.get("identity", {}))
		var publication_sequence := int(entry.get("publication_sequence", 0))
		var identity_error := _validate_identity(identity, publication_sequence)
		if not identity_error.is_empty():
			_record_rejection(identity_error)
			return false
		retained_retirements.append({
			"identity": identity.duplicate(true),
			"publication_sequence": publication_sequence,
			"deactivate": bool(entry.get("deactivate", false)),
		})
	_mutex.lock()
	if _close_requested:
		_status["last_error"] = "global render publication is closed"
		_mutex.unlock()
		return false
	var command := {
		"action": action,
		"entries": retained_entries,
		"retirements": retained_retirements,
	}
	if _lifecycle_command_is_interaction(command):
		_interaction_lifecycle_commands.append(command)
	else:
		_lifecycle_commands.append(command)
	for entry in retained_entries:
		var identity := Dictionary(entry.get("identity", {}))
		var token := _entry_token(
			_identity_key(identity), int(entry.get("publication_sequence", 0))
		)
		_protected_activation_tokens[token] = true
	_status["protected_activation_entries"] = _protected_activation_tokens.size()
	_mutex.unlock()
	return true


func retire_entry(identity: Dictionary, publication_sequence: int) -> bool:
	return _queue_lifecycle_command("RETIRE", identity, publication_sequence)


func deactivate_entry(identity: Dictionary, publication_sequence: int) -> bool:
	return _queue_lifecycle_command("DEACTIVATE", identity, publication_sequence)


func pop_event() -> Dictionary:
	_mutex.lock()
	if _priority_events.is_empty() and _events.is_empty():
		_mutex.unlock()
		return {}
	var event: Dictionary
	if not _priority_events.is_empty():
		event = Dictionary(_priority_events.get(_priority_event_head, {}))
		_priority_events.erase(_priority_event_head)
		_priority_event_head += 1
	else:
		event = Dictionary(_events.get(_event_head, {}))
		_events.erase(_event_head)
		_event_head += 1
	_status["event_count"] = _priority_events.size() + _events.size()
	_status["priority_event_count"] = _priority_events.size()
	_mutex.unlock()
	return event


func request_debug_ray_geometry(rays: Array) -> int:
	if rays.is_empty():
		return 0
	var retained: Array[Dictionary] = []
	for ray_value in rays:
		var ray := Dictionary(ray_value)
		var origin: Vector3 = ray.get("origin", Vector3.ZERO)
		var direction: Vector3 = ray.get("direction", Vector3.ZERO)
		var maximum_distance := float(ray.get("max_distance", 0.0))
		if not origin.is_finite() or not direction.is_finite() \
				or direction.is_zero_approx() or maximum_distance <= 0.0:
			return 0
		retained.append({
			"index": int(ray.get("index", retained.size())),
			"origin": origin,
			"direction": direction.normalized(),
			"max_distance": maximum_distance,
			"include_geometry": bool(ray.get("include_geometry", false)),
		})
	_mutex.lock()
	if _close_requested or _debug_geometry_requests.size() >= 4:
		_mutex.unlock()
		return 0
	var request_id := _next_debug_geometry_request_id
	_next_debug_geometry_request_id += 1
	_debug_geometry_requests.append({"request_id": request_id, "rays": retained})
	_mutex.unlock()
	return request_id


func pop_debug_ray_geometry(request_id: int) -> Dictionary:
	_mutex.lock()
	var result := Dictionary(_debug_geometry_results.get(request_id, {})).duplicate(true)
	if not result.is_empty():
		_debug_geometry_results.erase(request_id)
	_mutex.unlock()
	return result


func get_status() -> Dictionary:
	_mutex.lock()
	var result := _status.duplicate(true)
	result["close_requested"] = _close_requested
	result["close_completed"] = _close_completed
	result["pending_lifecycle_command_count"] = \
		_lifecycle_commands.size() + _interaction_lifecycle_commands.size()
	result["pending_interaction_lifecycle_command_count"] = \
		_interaction_lifecycle_commands.size()
	_mutex.unlock()
	return result


func set_critical_path_timeline_enabled(enabled_value: bool) -> void:
	_critical_path_timeline_enabled = enabled_value


func close() -> void:
	enabled = false
	_mutex.lock()
	_close_requested = true
	_pending.clear()
	_pending_interaction.clear()
	_lifecycle_commands.clear()
	_interaction_lifecycle_commands.clear()
	_status["queued_request_count"] = 0
	_status["queued_interaction_request_count"] = 0
	_mutex.unlock()
	RenderingServer.call_on_render_thread(Callable(self, "_close_on_render_thread"))

func set_debug_stage_timing_enabled(enabled: bool) -> void:
	_stage_timing_enabled = enabled or OS.get_cmdline_user_args().has("--gpu-stage-timing")


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT:
		return
	_render_callback_sequence += 1
	var phase_start := Time.get_ticks_usec() if _stage_timing_enabled else 0
	if _rendering_device == null:
		_rendering_device = RenderingServer.get_rendering_device()
	if _rendering_device == null or not _ensure_shaders():
		_mutex.lock()
		var have_specific_error := not str(_status.get("last_error", "")).is_empty()
		_mutex.unlock()
		if not have_specific_error:
			_record_render_error("global RenderingDevice shader initialization failed")
		return
	if _stage_timing_enabled:
		phase_start = _record_stage_time("initialize", phase_start)
	_apply_pending_production_material_on_render_thread()
	_apply_pending_production_water_on_render_thread()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("materials", phase_start)
	_drain_dispatch_completions_on_render_thread()
	_drain_arena_readbacks_on_render_thread()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("arena_readback", phase_start)
	_drain_pending_on_render_thread()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("dispatch", phase_start)
	_drain_one_compaction_on_render_thread()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("compaction", phase_start)
	# Failure probes are requested from the main thread after it reads the last
	# completed frame. Inspect the still-published entries before applying the
	# next lifecycle batch so the geometry result describes that captured frame.
	_drain_debug_geometry_requests_on_render_thread()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("debug_geometry", phase_start)
	_drain_lifecycle_commands_on_render_thread()
	if _stage_timing_enabled:
		phase_start = _record_stage_time("lifecycle", phase_start)
	_draw_entries_on_render_thread(render_data)
	if _stage_timing_enabled:
		_record_stage_time("draw", phase_start)
		_mutex.lock()
		_status["stage_timing_usec"] = _stage_timing_usec.duplicate(true)
		_mutex.unlock()


func _record_stage_time(stage: String, start_us: int) -> int:
	var now := Time.get_ticks_usec()
	var elapsed := now - start_us
	var value := Dictionary(_stage_timing_usec.get(stage, {"calls": 0, "total": 0, "max": 0}))
	value["calls"] = int(value["calls"]) + 1
	value["total"] = int(value["total"]) + elapsed
	value["max"] = maxi(int(value["max"]), elapsed)
	_stage_timing_usec[stage] = value
	return now


func _ensure_shaders() -> bool:
	if _compute_pipeline.is_valid() and _commit_pipeline.is_valid() \
			and _completion_pipeline.is_valid() and _compact_pipeline.is_valid() \
			and _raster_shader.is_valid() \
			and _production_raster_shader.is_valid() \
			and _production_water_shader.is_valid() \
			and _scene_color_copy_pipeline.is_valid() \
			and _vertex_format >= 0:
		return true
	if _initialization_attempted:
		return false
	_initialization_attempted = true
	_mutex.lock()
	_status["initialization_attempted"] = true
	_mutex.unlock()
	var compute_file := COMPUTE_SHADER_FILE as RDShaderFile
	var commit_file := COMMIT_SHADER_FILE as RDShaderFile
	var completion_file := COMPLETION_SHADER_FILE as RDShaderFile
	var compact_file := COMPACT_SHADER_FILE as RDShaderFile
	var raster_file := RASTER_SHADER_FILE as RDShaderFile
	var production_raster_file := PRODUCTION_RASTER_SHADER_FILE as RDShaderFile
	var production_water_file := PRODUCTION_WATER_SHADER_FILE as RDShaderFile
	var scene_color_copy_file := SCENE_COLOR_COPY_SHADER_FILE as RDShaderFile
	if compute_file == null or commit_file == null or completion_file == null \
			or compact_file == null \
			or raster_file == null \
			or production_raster_file == null \
			or production_water_file == null \
			or scene_color_copy_file == null \
			or not compute_file.get_base_error().is_empty() \
			or not commit_file.get_base_error().is_empty() \
			or not completion_file.get_base_error().is_empty() \
			or not compact_file.get_base_error().is_empty() \
			or not raster_file.get_base_error().is_empty() \
			or not production_raster_file.get_base_error().is_empty() \
			or not production_water_file.get_base_error().is_empty() \
			or not scene_color_copy_file.get_base_error().is_empty():
		_record_render_error("global render shader import is invalid: %s %s %s %s %s %s %s %s" % [
			compute_file.get_base_error() if compute_file != null else "compute missing",
			commit_file.get_base_error() if commit_file != null else "commit missing",
			completion_file.get_base_error() \
				if completion_file != null else "completion missing",
			compact_file.get_base_error() if compact_file != null else "compact missing",
			raster_file.get_base_error() if raster_file != null else "raster missing",
			production_raster_file.get_base_error() \
				if production_raster_file != null else "production raster missing",
			production_water_file.get_base_error() \
				if production_water_file != null else "production water missing",
			scene_color_copy_file.get_base_error() \
				if scene_color_copy_file != null else "scene color copy missing",
		])
		return false
	var shader_compile_error := _shader_file_compile_error(
		compute_file, RenderingDevice.SHADER_STAGE_COMPUTE
	)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			commit_file, RenderingDevice.SHADER_STAGE_COMPUTE
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			completion_file, RenderingDevice.SHADER_STAGE_COMPUTE
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			compact_file, RenderingDevice.SHADER_STAGE_COMPUTE
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			raster_file, RenderingDevice.SHADER_STAGE_VERTEX
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			raster_file, RenderingDevice.SHADER_STAGE_FRAGMENT
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			production_raster_file, RenderingDevice.SHADER_STAGE_VERTEX
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			production_raster_file, RenderingDevice.SHADER_STAGE_FRAGMENT
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			production_water_file, RenderingDevice.SHADER_STAGE_VERTEX
		)
	if shader_compile_error.is_empty():
		shader_compile_error = _shader_file_compile_error(
			production_water_file, RenderingDevice.SHADER_STAGE_FRAGMENT
		)
	if not shader_compile_error.is_empty():
		_record_render_error(shader_compile_error)
		return false
	_compute_shader = _rendering_device.shader_create_from_spirv(
		compute_file.get_spirv()
	)
	if not _compute_shader.is_valid():
		return false
	_compute_pipeline = _rendering_device.compute_pipeline_create(_compute_shader)
	if not _compute_pipeline.is_valid():
		return false
	_commit_shader = _rendering_device.shader_create_from_spirv(commit_file.get_spirv())
	if not _commit_shader.is_valid():
		return false
	_commit_pipeline = _rendering_device.compute_pipeline_create(_commit_shader)
	if not _commit_pipeline.is_valid():
		return false
	_completion_shader = _rendering_device.shader_create_from_spirv(
		completion_file.get_spirv()
	)
	if not _completion_shader.is_valid():
		return false
	_completion_pipeline = _rendering_device.compute_pipeline_create(_completion_shader)
	if not _completion_pipeline.is_valid():
		return false
	_compact_shader = _rendering_device.shader_create_from_spirv(compact_file.get_spirv())
	if not _compact_shader.is_valid():
		return false
	_compact_pipeline = _rendering_device.compute_pipeline_create(_compact_shader)
	if not _compact_pipeline.is_valid():
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
	_production_water_shader = _rendering_device.shader_create_from_spirv(
		production_water_file.get_spirv()
	)
	if not _production_water_shader.is_valid():
		return false
	_scene_color_copy_shader = _rendering_device.shader_create_from_spirv(
		scene_color_copy_file.get_spirv()
	)
	if not _scene_color_copy_shader.is_valid():
		return false
	_scene_color_copy_pipeline = _rendering_device.compute_pipeline_create(
		_scene_color_copy_shader
	)
	var scene_sampler_state := RDSamplerState.new()
	scene_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	scene_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	scene_sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	scene_sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	scene_sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_scene_color_sampler = _rendering_device.sampler_create(scene_sampler_state)
	if not _scene_color_copy_pipeline.is_valid() or not _scene_color_sampler.is_valid():
		return false
	var attributes: Array[RDVertexAttribute] = []
	attributes.append(_vertex_attribute(
		0, RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT, 12
	))
	attributes.append(_vertex_attribute(
		1, RenderingDevice.DATA_FORMAT_R16G16_SNORM, 4
	))
	attributes.append(_vertex_attribute(
		2, RenderingDevice.DATA_FORMAT_R16G16_UINT, 4
	))
	_vertex_format = _rendering_device.vertex_format_create(attributes)
	if _vertex_format >= 0:
		_arena = ResidentArena.new()
		if not _arena.initialize(
			_rendering_device,
			_compute_shader,
			_compute_pipeline,
			_commit_shader,
			_commit_pipeline,
			_completion_shader,
			_completion_pipeline,
			_compact_shader,
			_compact_pipeline,
			_vertex_format,
			_resident_allocation_capacity(),
			mini(SCRATCH_SLOT_CAPACITY, _resident_allocation_capacity())
		):
			_record_render_error(_arena.get_last_error())
			_arena = null
			return false
	_mutex.lock()
	_status["initialized"] = _vertex_format >= 0
	_mutex.unlock()
	return _vertex_format >= 0


static func _shader_file_compile_error(
	shader_file: RDShaderFile, stage: int
) -> String:
	if shader_file == null:
		return "GPU shader resource is unavailable"
	return str(shader_file.get_spirv().get_stage_compile_error(stage)).strip_edges()


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
	_status["production_terrain_roughness_mapping_parity"] = \
		_production_material_set.is_valid()
	# The accepted production shader declares a normal array but does not write
	# NORMAL_MAP. Preserving geometric normals is therefore the exact response.
	_status["production_terrain_accepted_normal_response_parity"] = \
		_production_material_set.is_valid()
	_status["production_terrain_normal_mapping_parity"] = \
		_production_material_set.is_valid()
	_status["production_terrain_bounded_pbr_response_parity"] = \
		_production_material_set.is_valid()
	_status["production_terrain_directional_ambient_lighting_parity"] = bool(
		_production_material_set.is_valid() \
		and config.get("scene_lighting_supported", false)
	)
	_status["production_terrain_pbr_lighting_parity"] = bool(
		_status["production_terrain_bounded_pbr_response_parity"]
	) and bool(_status["production_terrain_directional_ambient_lighting_parity"])
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


func _apply_pending_production_water_on_render_thread() -> void:
	var config := {}
	_mutex.lock()
	if not _pending_production_water.is_empty():
		config = _pending_production_water
		_pending_production_water = {}
	_mutex.unlock()
	if config.is_empty():
		return
	_free_rids_on_render_thread([
		_production_water_set,
		_production_water_buffer,
	])
	_production_water_set = RID()
	_production_water_buffer = RID()
	var parameter_bytes := PackedByteArray(config.get(
		"parameter_bytes", PackedByteArray()
	))
	_production_water_buffer = _rendering_device.uniform_buffer_create(
		parameter_bytes.size(), parameter_bytes
	)
	if not _production_water_buffer.is_valid():
		_record_render_error("production water material buffer creation failed")
		return
	var parameters := RDUniform.new()
	parameters.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	parameters.binding = 0
	parameters.add_id(_production_water_buffer)
	_production_water_set = _rendering_device.uniform_set_create(
		[parameters], _production_water_shader, 1
	)
	_mutex.lock()
	_status["production_static_water_material_payload_ready"] = \
		_production_water_set.is_valid()
	_status["production_static_water_fresnel_tint_parity"] = \
		_production_water_set.is_valid()
	_status["production_static_water_refraction_parity"] = bool(
		_production_water_set.is_valid() and _scene_color_copy_pipeline.is_valid()
	)
	_status["production_static_water_material_parity"] = bool(
		_status["production_static_water_fresnel_tint_parity"]
	) and bool(_status["production_static_water_refraction_parity"])
	_status["production_material_parity"] = bool(
		_status["production_terrain_material_parity"]
	) and bool(_status["production_static_water_material_parity"])
	if not _production_water_set.is_valid():
		_status["last_error"] = "production water material uniform set creation failed"
	_mutex.unlock()


func _drain_dispatch_completions_on_render_thread() -> void:
	if _arena == null:
		return
	for completion in _arena.pop_completed_dispatches(
		DISPATCH_COMPLETION_CAPACITY_PER_CALLBACK
	):
		var ticket := int(completion.get("ticket", 0))
		_dispatch_pending_tickets.erase(ticket)
		if bool(completion.get("valid", false)):
			continue
		if not _inflight_extractions.has(ticket):
			continue
		var request: Dictionary = _inflight_extractions[ticket]
		_inflight_extractions.erase(ticket)
		_arena.discard_readback(ticket)
		_rollback_gpu_candidate_on_render_thread(request)
		_reject_request_on_render_thread(
			request, str(completion.get("error", "GPU extraction completion failed"))
		)
		_mutex.lock()
		_status["invalid_dispatch_completions"] = int(
			_status["invalid_dispatch_completions"]
		) + 1
		_mutex.unlock()
	_sync_arena_status_on_render_thread()
	var arena_status: Dictionary = _arena.get_status()
	if int(arena_status.get("completed_dispatch_queue_count", 0)) > 0:
		_mutex.lock()
		_status["dispatch_completion_budget_deferrals"] = int(
			_status["dispatch_completion_budget_deferrals"]
		) + 1
		_mutex.unlock()
	_sync_dispatch_lane_status_on_render_thread()


func _drain_arena_readbacks_on_render_thread() -> void:
	if _arena == null:
		return
	for completion in _arena.pop_completed_readbacks(
		TELEMETRY_COMPLETION_CAPACITY_PER_CALLBACK
	):
		var ticket := int(completion.get("ticket", 0))
		var completion_data: PackedByteArray = completion.get("data", PackedByteArray())
		_dispatch_pending_tickets.erase(ticket)
		_arena.discard_dispatch_completion(ticket)
		if not _inflight_extractions.has(ticket):
			_arena.discard_readback(ticket, completion_data.size())
			continue
		var request: Dictionary = _inflight_extractions[ticket]
		_inflight_extractions.erase(ticket)
		if _critical_path_timeline_enabled:
			request["gpu_readback_ticks_usec"] = Time.get_ticks_usec()
		if _cancelled_inflight_tickets.has(ticket):
			_cancelled_inflight_tickets.erase(ticket)
			_arena.discard_readback(ticket, completion_data.size())
			_sync_arena_status_on_render_thread()
			_mutex.lock()
			_status["inflight_extraction_count"] = _inflight_extractions.size()
			_status["discarded_cancelled_readbacks"] = int(
				_status["discarded_cancelled_readbacks"]
			) + 1
			_mutex.unlock()
			continue
		var key := str(request.get("key", ""))
		var sequence := int(request.get("publication_sequence", 0))
		_mutex.lock()
		var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
		_status["inflight_extraction_count"] = _inflight_extractions.size()
		_mutex.unlock()
		if sequence != latest_sequence:
			_arena.discard_readback(ticket, completion_data.size())
			var stale_token := _entry_token(key, sequence)
			if _entries.has(stale_token):
				var stale_entry := Dictionary(_entries[stale_token])
				stale_entry["counts_pending"] = false
				_finalize_gpu_candidate_on_render_thread(stale_entry)
				_entries[stale_token] = stale_entry
				_queue_compaction_on_render_thread(stale_token, stale_entry)
			continue
		var telemetry: Dictionary = _arena.finalize_readback(
			ticket, completion_data
		)
		_sync_arena_status_on_render_thread()
		if telemetry.is_empty():
			_rollback_gpu_candidate_on_render_thread(request)
			_reject_request_on_render_thread(
				request, _arena.get_last_error()
			)
			continue
		var token := _entry_token(key, sequence)
		if _entries.has(token):
			var entry := Dictionary(_entries[token])
			entry["counts_pending"] = false
			entry["empty"] = bool(telemetry.get("empty", false))
			entry["vertex_count"] = int(telemetry.get("vertex_count", 0))
			entry["index_count"] = int(telemetry.get("index_count", 0))
			entry["failure_cell_count"] = int(telemetry.get("failure_cell_count", 0))
			_finalize_gpu_candidate_on_render_thread(entry)
			_entries[token] = entry
			_queue_compaction_on_render_thread(token, entry)
			_active_lod_inventory_dirty = true
			_mutex.lock()
			_status["resident_entry_count"] = _entries.size()
			_status["active_entry_count"] = _active_sequence_by_key.size()
			_mutex.unlock()
	_sync_arena_status_on_render_thread()
	var arena_status: Dictionary = _arena.get_status()
	if int(arena_status.get("completed_readback_queue_count", 0)) > 0:
		_mutex.lock()
		_status["telemetry_completion_budget_deferrals"] = int(
			_status["telemetry_completion_budget_deferrals"]
		) + 1
		_mutex.unlock()
	_mutex.lock()
	_status["resident_entry_count"] = _entries.size()
	_status["active_entry_count"] = _active_sequence_by_key.size()
	_status["inflight_extraction_count"] = _inflight_extractions.size()
	_mutex.unlock()
	_sync_dispatch_lane_status_on_render_thread()


func _queue_compaction_on_render_thread(token: String, entry: Dictionary) -> void:
	if str(entry.get("resident_kind", "")) != "provisional" \
			or bool(entry.get("counts_pending", true)):
		return
	if bool(entry.get("empty", false)):
		var compact: Dictionary = _arena.compact_resident_meshlets(entry)
		if str(compact.get("resident_kind", "")) != "provisional":
			compact["mono_push_bytes"] = _entry_push_bytes(
				compact, 0, 1, Vector2i.ZERO, false
			)
			_entries[token] = compact
			_active_lod_inventory_dirty = true
			_mutex.lock()
			_status["compactions_completed"] = int(
				_status.get("compactions_completed", 0)
			) + 1
			_mutex.unlock()
		return
	if not _pending_compactions.has(token):
		_pending_compactions.append(token)
		_compaction_eligible_callback_by_token[token] = (
			_render_callback_sequence + COMPACTION_SETTLE_CALLBACKS
		)


func _drain_one_compaction_on_render_thread() -> void:
	if _arena == null:
		return
	# Scratch reclamation is part of steady-state streaming. Waiting for global
	# idle made continuous movement permanently retain every provisional page.
	_compaction_idle_callbacks = 0
	while not _pending_compactions.is_empty():
		var token := _pending_compactions.front()
		if _render_callback_sequence < int(
			_compaction_eligible_callback_by_token.get(token, 0)
		):
			break
		_pending_compactions.pop_front()
		_compaction_eligible_callback_by_token.erase(token)
		if not _entries.has(token):
			continue
		var entry: Dictionary = _entries[token]
		var compact: Dictionary = _arena.compact_resident_meshlets(entry)
		if str(compact.get("resident_kind", "")) != str(
			entry.get("resident_kind", "")
		):
			compact["mono_push_bytes"] = _entry_push_bytes(
				compact, 0, 1, Vector2i.ZERO, false
			)
			_entries[token] = compact
			_active_lod_inventory_dirty = true
			_mutex.lock()
			_status["compactions_completed"] = int(
				_status.get("compactions_completed", 0)
			) + 1
			_mutex.unlock()
		_sync_arena_status_on_render_thread()
		break
	_mutex.lock()
	_status["pending_compaction_count"] = _pending_compactions.size()
	_status["compaction_idle_callbacks"] = 0
	_mutex.unlock()


func _drain_pending_on_render_thread() -> void:
	var requests: Array[Dictionary] = []
	_mutex.lock()
	requests.assign(_pending_interaction)
	requests.append_array(_pending)
	_pending_interaction.clear()
	_pending.clear()
	_status["queued_request_count"] = 0
	_status["queued_interaction_request_count"] = 0
	_mutex.unlock()
	var deferred: Array[Dictionary] = []
	var deferred_interaction: Array[Dictionary] = []
	for request in requests:
		var key := str(request.get("key", ""))
		var sequence := int(request.get("publication_sequence", 0))
		_mutex.lock()
		var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
		_mutex.unlock()
		if sequence != latest_sequence:
			_reject_request_on_render_thread(
				request, "request became stale before GPU extraction"
			)
			continue
		if _entries.size() >= _resident_allocation_capacity():
			_mutex.lock()
			_status["resident_capacity_rejections"] = \
				int(_status["resident_capacity_rejections"]) + 1
			_mutex.unlock()
			_reject_request_on_render_thread(
				request, "resident entry capacity reached"
			)
			continue
		if bool(request.get("proven_empty", false)):
			var empty_entry: Dictionary = _arena.create_proven_empty(
				int(request.get("cell_count", 0))
			)
			_sync_arena_status_on_render_thread()
			if empty_entry.is_empty():
				_reject_request_on_render_thread(request, _arena.get_last_error())
				continue
			_finish_entry_on_render_thread(request, empty_entry)
			continue
		var request_identity := Dictionary(request.get("identity", {}))
		var interaction := bool(request_identity.get("incremental_edit", false)) \
				or bool(request_identity.get("interaction_priority", false))
		var lane_pending := _dispatch_lane_count(interaction)
		var lane_capacity := INTERACTION_DISPATCH_CAPACITY \
				if interaction else BACKGROUND_DISPATCH_CAPACITY
		if lane_pending >= lane_capacity:
			if interaction:
				deferred_interaction.append(request)
			else:
				deferred.append(request)
			_mutex.lock()
			var deferral_key := "interaction_dispatch_deferrals" \
					if interaction else "background_dispatch_deferrals"
			_status[deferral_key] = int(_status[deferral_key]) + 1
			_mutex.unlock()
			continue
		var previous_entry := {}
		if _active_sequence_by_key.has(key):
			var previous_token := _entry_token(
				key, int(_active_sequence_by_key[key])
			)
			if _entries.has(previous_token):
				previous_entry = Dictionary(_entries[previous_token])
		var extraction: Dictionary = _arena.lease_and_dispatch(
			Array(request.get("input_buffers", [])),
			int(request.get("cell_count", 0)),
			request.get("bounds_min", Vector3.ZERO),
			request.get("bounds_max", Vector3.ZERO),
			previous_entry,
			int(Dictionary(request.get("identity", {})).get(
				"dirty_regular_brick_mask", 0xff
			)),
			int(Dictionary(request.get("identity", {})).get(
				"cached_transition_mask", 0
			)),
			int(Dictionary(request.get("identity", {})).get(
				"transition_mask", 0
			)),
			Dictionary(request.get("identity", {})).get(
				"dirty_bounds_min", Vector3i.ZERO
			),
			Dictionary(request.get("identity", {})).get(
				"dirty_bounds_max", Vector3i.ZERO
			),
			interaction
		)
		_sync_arena_status_on_render_thread()
		if extraction.is_empty():
			if _arena.get_last_error() == "resident arena scratch capacity is busy":
				if interaction:
					deferred_interaction.append(request)
				else:
					deferred.append(request)
				continue
			_reject_request_on_render_thread(request, _arena.get_last_error())
			continue
		var ticket := int(extraction.get("arena_ticket", 0))
		if ticket <= 0:
			_reject_request_on_render_thread(
				request, "resident arena did not return an extraction ticket"
			)
			continue
		if _critical_path_timeline_enabled:
			request["gpu_dispatch_ticks_usec"] = Time.get_ticks_usec()
		# RenderingDevice has synchronously copied these bytes into the arena before
		# lease_and_dispatch returns.  Keep only the small publication record while
		# completion and telemetry readbacks run; retaining all 13 upload arrays here
		# multiplied transient CPU memory by every published pending ticket.
		var inflight_request := request.duplicate()
		inflight_request.erase("input_buffers")
		_inflight_extractions[ticket] = inflight_request
		_dispatch_pending_tickets[ticket] = interaction
		_finish_entry_on_render_thread(request, extraction)
		_mutex.lock()
		_status["released_upload_bytes_after_dispatch"] = int(
			_status["released_upload_bytes_after_dispatch"]
		) + int(request.get("input_byte_count", 0))
		_mutex.unlock()
	if not deferred.is_empty() or not deferred_interaction.is_empty():
		_mutex.lock()
		_pending_interaction.append_array(deferred_interaction)
		_pending.append_array(deferred)
		_status["queued_request_count"] = _pending.size() + _pending_interaction.size()
		_status["queued_interaction_request_count"] = _pending_interaction.size()
		_mutex.unlock()
	_mutex.lock()
	_status["inflight_extraction_count"] = _inflight_extractions.size()
	_mutex.unlock()
	_sync_dispatch_lane_status_on_render_thread()


func _dispatch_lane_count(interaction: bool) -> int:
	var count := 0
	for lane_value in _dispatch_pending_tickets.values():
		if bool(lane_value) == interaction:
			count += 1
	return count


func _sync_dispatch_lane_status_on_render_thread() -> void:
	var interaction_count := _dispatch_lane_count(true)
	var background_count := _dispatch_lane_count(false)
	var telemetry_pending := maxi(
		0, _inflight_extractions.size() - interaction_count - background_count
	)
	_mutex.lock()
	_status["dispatch_pending_count"] = interaction_count + background_count
	_status["telemetry_pending_count"] = telemetry_pending
	_status["peak_telemetry_pending_count"] = maxi(
		int(_status["peak_telemetry_pending_count"]), telemetry_pending
	)
	_status["inflight_upload_bytes_retained"] = 0
	_status["interaction_dispatch_pending_count"] = interaction_count
	_status["background_dispatch_pending_count"] = background_count
	_status["peak_interaction_dispatch_pending_count"] = maxi(
		int(_status["peak_interaction_dispatch_pending_count"]), interaction_count
	)
	_status["peak_background_dispatch_pending_count"] = maxi(
		int(_status["peak_background_dispatch_pending_count"]), background_count
	)
	_mutex.unlock()


func _finish_entry_on_render_thread(
	request: Dictionary, entry: Dictionary
) -> void:
	var key := str(request.get("key", ""))
	var sequence := int(request.get("publication_sequence", 0))
	var token := _entry_token(key, sequence)
	_mutex.lock()
	var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
	_mutex.unlock()
	if sequence != latest_sequence:
		_free_entry_on_render_thread(entry)
		_reject_request_on_render_thread(
			request, "request became stale before compact residency"
		)
		return
	entry["publication_sequence"] = sequence
	entry["identity"] = Dictionary(request.get("identity", {})).duplicate(true)
	entry["bounds_min"] = request.get("bounds_min", Vector3.ZERO)
	entry["bounds_max"] = request.get("bounds_max", Vector3.ZERO)
	entry["mono_push_bytes"] = _entry_push_bytes(entry, 0, 1, Vector2i.ZERO, false)
	var activate_immediately := bool(request.get("activate_immediately", true))
	entry["active"] = false
	_entries[token] = entry
	# Validation and transient-storage reclamation belong to completed extraction,
	# not activation. Large atomic cohorts must be able to compact every prepared
	# member before all members are simultaneously ready to publish.
	if not _arena.request_summary_readback(entry):
		_free_entry_on_render_thread(_entries[token])
		_entries.erase(token)
		_reject_request_on_render_thread(request, _arena.get_last_error())
		return
	if activate_immediately:
		if not _commit_single_activation_on_render_thread(key, token, request):
			_free_entry_on_render_thread(_entries[token])
			_entries.erase(token)
			_reject_request_on_render_thread(request, _arena.get_last_error())
			return
	else:
		var prepared_source := request.duplicate(true)
		prepared_source["entry_empty"] = bool(entry.get("empty", false))
		prepared_source["entry_vertex_count"] = int(entry.get("vertex_count", 0))
		prepared_source["entry_index_count"] = int(entry.get("index_count", 0))
		prepared_source["entry_failure_cell_count"] = int(entry.get(
			"failure_cell_count", 0
		))
		prepared_source["entry_cell_count"] = int(entry.get(
			"regenerated_cell_count", entry.get("cell_count", 0)
		))
		prepared_source["source_cell_count"] = int(entry.get("cell_count", 0))
		prepared_source["gpu_uploaded_bytes"] = int(entry.get("uploaded_bytes", 0))
		prepared_source["gpu_dispatch_ticks_usec"] = int(request.get(
			"gpu_dispatch_ticks_usec", 0
		))
		prepared_source["gpu_readback_ticks_usec"] = int(request.get(
			"gpu_readback_ticks_usec", 0
		))
		_push_event_on_render_thread("PREPARED", prepared_source)
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
	var phase_start := Time.get_ticks_usec() if _stage_timing_enabled else 0
	var commands: Array[Dictionary] = []
	_mutex.lock()
	var interaction_count := mini(
		LIFECYCLE_COMMAND_CAPACITY_PER_CALLBACK,
		_interaction_lifecycle_commands.size()
	)
	if interaction_count > 0:
		commands.assign(_interaction_lifecycle_commands.slice(0, interaction_count))
		_interaction_lifecycle_commands = _interaction_lifecycle_commands.slice(
			interaction_count
		)
	var background_capacity := LIFECYCLE_COMMAND_CAPACITY_PER_CALLBACK - commands.size()
	var background_count := mini(background_capacity, _lifecycle_commands.size())
	if background_count > 0:
		commands.append_array(_lifecycle_commands.slice(0, background_count))
		_lifecycle_commands = _lifecycle_commands.slice(background_count)
	if not _interaction_lifecycle_commands.is_empty() or not _lifecycle_commands.is_empty():
		_status["lifecycle_command_budget_deferrals"] = int(
			_status["lifecycle_command_budget_deferrals"]
		) + 1
	_mutex.unlock()
	for command in commands:
		var action := str(command.get("action", ""))
		if action == "STAGE_ACTIVATION_GROUP":
			_stage_activation_group_on_render_thread(command)
			continue
		if action == "ACTIVATE_GROUP":
			_activate_group_on_render_thread(command)
			continue
		if action == "REPLACE_GROUP":
			_replace_group_on_render_thread(command)
			continue
		if action == "REMASK_GROUP":
			_remask_group_on_render_thread(command)
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
			if not _commit_single_activation_on_render_thread(key, token, command):
				_push_event_on_render_thread(
					"REJECTED", command, _arena.get_last_error()
				)
		elif action == "RETIRE":
			_retire_entry_on_render_thread(key, token, command)
		elif action == "DEACTIVATE":
			_deactivate_entry_on_render_thread(key, token, command)
	_sync_active_lod_inventory_on_render_thread()
	if _stage_timing_enabled:
		_record_stage_time("lifecycle_all_callbacks", phase_start)


func _remask_group_on_render_thread(command: Dictionary) -> void:
	var updates: Array = []
	for source_value in Array(command.get("entries", [])):
		var source := Dictionary(source_value)
		var identity := Dictionary(source.get("identity", {}))
		var key := _identity_key(identity)
		var sequence := int(source.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		if not _entries.has(token):
			_push_event_on_render_thread(
				"REJECTED", source, "resident transition remask became stale"
			)
			return
		var entry := Dictionary(_entries[token])
		if bool(entry.get("active", false)) \
				and int(_active_sequence_by_key.get(key, 0)) != sequence:
			_push_event_on_render_thread(
				"REJECTED", source, "active resident transition remask became stale"
			)
			return
		var previous := Dictionary(entry.get("identity", {}))
		for field in [
			"surface", "page_x", "page_y", "page_z", "lod", "generation",
			"source_revision", "world_revision",
		]:
			if previous.get(field) != identity.get(field):
				_push_event_on_render_thread(
					"REJECTED", source, "resident transition remask changed geometry identity"
				)
				return
		var cached_mask := int(entry.get(
			"resident_cached_transition_mask",
			previous.get("cached_transition_mask", 0)
		))
		if (int(identity.get("transition_mask", 0)) & ~cached_mask) != 0:
			_push_event_on_render_thread(
				"REJECTED", source, "resident transition remask exceeds cached faces"
			)
			return
		var regular_visibility_mask := int(identity.get(
			"regular_visibility_mask", entry.get("regular_visibility_mask", 0xff)
		))
		if regular_visibility_mask < 0 or regular_visibility_mask > 0xff:
			_push_event_on_render_thread(
				"REJECTED", source, "resident regular brick mask is invalid"
			)
			return
		var updated := entry.duplicate(true)
		updated["identity"] = identity.duplicate(true)
		updated["regular_visibility_mask"] = regular_visibility_mask
		updates.append({"token": token, "entry": updated, "source": source})
	var visibility_entries: Array = []
	for update in updates:
		var updated_entry := Dictionary(Dictionary(update).get("entry", {}))
		# Dormant entries retain their arena allocation with all draws disabled.
		# Updating their identity must not make transition draws visible before
		# the complete native/render activation cohort commits.
		if bool(updated_entry.get("active", false)):
			visibility_entries.append(updated_entry)
	if not visibility_entries.is_empty() \
			and not _arena.commit_visibility([], [], visibility_entries):
		for update in updates:
			_push_event_on_render_thread(
				"REJECTED", Dictionary(Dictionary(update).get("source", {})),
				_arena.get_last_error()
			)
		return
	if not visibility_entries.is_empty() \
			and not _arena.set_transition_visibility(visibility_entries):
		for update in updates:
			_push_event_on_render_thread(
				"REJECTED", Dictionary(Dictionary(update).get("source", {})),
				_arena.get_last_error()
			)
		return
	for update in updates:
		var item := Dictionary(update)
		var updated_entry := Dictionary(item.get("entry", {}))
		_entries[str(item.get("token", ""))] = updated_entry
		var source := Dictionary(item.get("source", {}))
		source["entry_empty"] = bool(updated_entry.get("empty", false))
		source["entry_vertex_count"] = int(updated_entry.get("vertex_count", 0))
		source["entry_index_count"] = int(updated_entry.get("index_count", 0))
		_push_event_on_render_thread("REMASKED", source)
	_mutex.lock()
	_status["transition_remask_surfaces"] = int(
		_status["transition_remask_surfaces"]
	) + updates.size()
	_mutex.unlock()
	_active_lod_inventory_dirty = true


func _lifecycle_command_is_interaction(command: Dictionary) -> bool:
	var sources: Array = Array(command.get("entries", []))
	if sources.is_empty() and command.has("identity"):
		sources = [{"identity": command.get("identity", {})}]
	for source_value in sources:
		var identity := Dictionary(Dictionary(source_value).get("identity", {}))
		if bool(identity.get("incremental_edit", false)) \
				or bool(identity.get("interaction_priority", false)):
			return true
	return false


func _activation_entry_available(key: String, sequence: int, token: String) -> bool:
	_mutex.lock()
	var latest_sequence := int(_latest_sequence_by_key.get(key, 0))
	var protected := _protected_activation_tokens.has(token)
	if protected and sequence != latest_sequence:
		_status["protected_stale_activations"] = int(
			_status.get("protected_stale_activations", 0)
		) + 1
	_mutex.unlock()
	return _entries.has(token) and (sequence == latest_sequence or protected)


func _release_activation_protection(entries: Array) -> void:
	_mutex.lock()
	for entry_value in entries:
		var entry := Dictionary(entry_value)
		var identity := Dictionary(entry.get("identity", {}))
		_protected_activation_tokens.erase(_entry_token(
			_identity_key(identity), int(entry.get("publication_sequence", 0))
		))
	_status["protected_activation_entries"] = _protected_activation_tokens.size()
	_mutex.unlock()


func _activation_token_is_protected(token: String) -> bool:
	_mutex.lock()
	var protected := _protected_activation_tokens.has(token)
	_mutex.unlock()
	return protected


func _stage_activation_group_on_render_thread(command: Dictionary) -> void:
	for source_value in Array(command.get("entries", [])):
		var source := Dictionary(source_value)
		var identity := Dictionary(source.get("identity", {}))
		var key := _identity_key(identity)
		var sequence := int(source.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		if not _activation_entry_available(key, sequence, token):
			_push_event_on_render_thread(
				"REJECTED", source,
				"prepared activation set became stale before staging"
			)
			_release_activation_protection(Array(command.get("entries", [])))
			return
		var entry: Dictionary = _entries[token]
		if Dictionary(entry.get("identity", {})) != identity:
			_push_event_on_render_thread(
				"REJECTED", source,
				"staged activation identity differs from prepared entry"
			)
			_release_activation_protection(Array(command.get("entries", [])))
			return
	for source_value in Array(command.get("entries", [])):
		_push_event_on_render_thread(
			"ACTIVATION_STAGED", Dictionary(source_value)
		)


func _activate_group_on_render_thread(command: Dictionary) -> void:
	var validated: Array[Dictionary] = []
	for source_value in Array(command.get("entries", [])):
		var source := Dictionary(source_value)
		var identity := Dictionary(source.get("identity", {}))
		var key := _identity_key(identity)
		var sequence := int(source.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		if not _activation_entry_available(key, sequence, token):
			_push_event_on_render_thread(
				"REJECTED", source,
				"prepared activation set became stale before activation"
			)
			_release_activation_protection(Array(command.get("entries", [])))
			return
		var entry: Dictionary = _entries[token]
		if Dictionary(entry.get("identity", {})) != identity:
			_push_event_on_render_thread(
				"REJECTED", source,
				"activation set identity differs from prepared entry"
			)
			_release_activation_protection(Array(command.get("entries", [])))
			return
		validated.append({
			"source": source,
			"key": key,
			"token": token,
		})
	var candidate_entries: Array = []
	var replaced_entries: Array = []
	for item in validated:
		candidate_entries.append(Dictionary(_entries[str(item.get("token", ""))]))
		var key := str(item.get("key", ""))
		if _active_sequence_by_key.has(key):
			var old_token := _entry_token(key, int(_active_sequence_by_key[key]))
			if _entries.has(old_token) and old_token != str(item.get("token", "")):
				replaced_entries.append(Dictionary(_entries[old_token]))
	if not _arena.commit_visibility(candidate_entries, replaced_entries):
		for item in validated:
			_push_event_on_render_thread(
				"REJECTED", Dictionary(item.get("source", {})), _arena.get_last_error()
			)
		_release_activation_protection(Array(command.get("entries", [])))
		return
	for item in validated:
		var token := str(item.get("token", ""))
		var entry: Dictionary = _entries[token]
		entry["active"] = true
		_entries[token] = entry
		_activate_entry_on_render_thread(
			str(item.get("key", "")), token, Dictionary(item.get("source", {}))
		)
	_release_activation_protection(Array(command.get("entries", [])))


func _replace_group_on_render_thread(command: Dictionary) -> void:
	var activation_sources := Array(command.get("entries", []))
	var activations: Array[Dictionary] = []
	if not activation_sources.is_empty():
		activations = _validated_activation_group_on_render_thread(command)
	if not activation_sources.is_empty() and activations.is_empty():
		return
	var retirements: Array[Dictionary] = []
	for source_value in Array(command.get("retirements", [])):
		var source := Dictionary(source_value)
		var identity := Dictionary(source.get("identity", {}))
		var key := _identity_key(identity)
		var sequence := int(source.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		if not _entries.has(token) \
				or int(_active_sequence_by_key.get(key, 0)) != sequence:
			_push_event_on_render_thread(
				"REJECTED", source,
				"retained entry became stale before atomic replacement"
			)
			_release_activation_protection(activation_sources)
			return
		var entry: Dictionary = _entries[token]
		if Dictionary(entry.get("identity", {})) != identity:
			_push_event_on_render_thread(
				"REJECTED", source,
				"retirement identity differs before atomic replacement"
			)
			_release_activation_protection(activation_sources)
			return
		retirements.append({"source": source, "key": key, "token": token})
	var candidate_entries: Array = []
	var retired_entries: Array = []
	for item in activations:
		candidate_entries.append(Dictionary(_entries[str(item.get("token", ""))]))
	for item in retirements:
		retired_entries.append(Dictionary(_entries[str(item.get("token", ""))]))
	if not _arena.commit_visibility(candidate_entries, retired_entries):
		for item in activations:
			_push_event_on_render_thread(
				"REJECTED", Dictionary(item.get("source", {})), _arena.get_last_error()
			)
		_release_activation_protection(activation_sources)
		return
	if activations.is_empty():
		for item in retirements:
			var source := Dictionary(item.get("source", {}))
			if bool(source.get("deactivate", false)):
				_deactivate_entry_on_render_thread(
					str(item.get("key", "")), str(item.get("token", "")), source, true
				)
			else:
				_retire_entry_on_render_thread(
					str(item.get("key", "")), str(item.get("token", "")), source
				)
		return
	var deferred_retirements: Array = []
	for item in retirements:
		var retirement_source := Dictionary(item.get("source", {}))
		if bool(retirement_source.get("deactivate", false)):
			_deactivate_entry_on_render_thread(
				str(item.get("key", "")), str(item.get("token", "")),
				retirement_source, true
			)
		else:
			deferred_retirements.append(item)
	for item in activations:
		var token := str(item.get("token", ""))
		var entry: Dictionary = _entries[token]
		entry["active"] = true
		entry["retained_retirements"] = deferred_retirements.duplicate(true)
		_entries[token] = entry
		_activate_entry_on_render_thread(
			str(item.get("key", "")), token, Dictionary(item.get("source", {}))
		)
	_release_activation_protection(activation_sources)
	# GPU validation owns retirement. The old entries remain submitted until the
	# asynchronous summary confirms that the entire cohort committed.


func _validated_activation_group_on_render_thread(
	command: Dictionary
) -> Array[Dictionary]:
	var validated: Array[Dictionary] = []
	for source_value in Array(command.get("entries", [])):
		var source := Dictionary(source_value)
		var identity := Dictionary(source.get("identity", {}))
		var key := _identity_key(identity)
		var sequence := int(source.get("publication_sequence", 0))
		var token := _entry_token(key, sequence)
		if not _activation_entry_available(key, sequence, token):
			_push_event_on_render_thread(
				"REJECTED", source,
				"prepared activation set became stale before activation"
			)
			_release_activation_protection(Array(command.get("entries", [])))
			return []
		var entry: Dictionary = _entries[token]
		if Dictionary(entry.get("identity", {})) != identity:
			_push_event_on_render_thread(
				"REJECTED", source,
				"activation set identity differs from prepared entry"
			)
			_release_activation_protection(Array(command.get("entries", [])))
			return []
		validated.append({"source": source, "key": key, "token": token})
	return validated


func _activate_entry_on_render_thread(
	key: String, token: String, source: Dictionary
) -> void:
	if _active_sequence_by_key.has(key):
		var old_sequence := int(_active_sequence_by_key[key])
		var old_token := _entry_token(key, old_sequence)
		if old_token != token and _entries.has(old_token):
			var old_entry: Dictionary = _entries[old_token]
			var candidate: Dictionary = _entries[token]
			candidate["retained_previous_token"] = old_token
			_entries[token] = candidate
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
	_active_lod_inventory_dirty = true
	_mutex.unlock()
	_push_event_on_render_thread("ACTIVE", source)


func _commit_single_activation_on_render_thread(
	key: String, token: String, source: Dictionary
) -> bool:
	if not _entries.has(token):
		return false
	var candidate: Dictionary = _entries[token]
	var replaced_entries: Array = []
	if _active_sequence_by_key.has(key):
		var old_token := _entry_token(key, int(_active_sequence_by_key[key]))
		if old_token != token and _entries.has(old_token):
			replaced_entries.append(Dictionary(_entries[old_token]))
	if not _arena.commit_visibility([candidate], replaced_entries):
		return false
	candidate["active"] = true
	_entries[token] = candidate
	_activate_entry_on_render_thread(key, token, source)
	return true


func _retire_entry_on_render_thread(
	key: String, token: String, source: Dictionary
) -> void:
	_cancel_unpublished_entry_on_render_thread(
		key, int(source.get("publication_sequence", 0))
	)
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
	_active_lod_inventory_dirty = true
	_mutex.unlock()
	_push_event_on_render_thread("RETIRED", source)


func _deactivate_entry_on_render_thread(
	key: String, token: String, source: Dictionary,
	visibility_already_committed: bool = false
) -> void:
	if not _entries.has(token):
		_push_event_on_render_thread(
			"REJECTED", source, "resident entry disappeared before deactivation"
		)
		return
	var entry: Dictionary = _entries[token]
	if Dictionary(entry.get("identity", {})) != Dictionary(source.get("identity", {})):
		_push_event_on_render_thread(
			"REJECTED", source, "deactivation identity differs from resident entry"
		)
		return
	if bool(entry.get("active", false)) and not visibility_already_committed:
		if not _arena.commit_visibility([], [entry]):
			_push_event_on_render_thread("REJECTED", source, _arena.get_last_error())
			return
	entry["active"] = false
	_entries[token] = entry
	if int(_active_sequence_by_key.get(key, 0)) \
			== int(source.get("publication_sequence", 0)):
		_active_sequence_by_key.erase(key)
	_mutex.lock()
	_status["active_entry_count"] = _active_sequence_by_key.size()
	_active_lod_inventory_dirty = true
	_mutex.unlock()
	_push_event_on_render_thread("DEACTIVATED", source)


func _finalize_gpu_candidate_on_render_thread(entry: Dictionary) -> void:
	var previous_token := str(entry.get("retained_previous_token", ""))
	var traversed := 0
	while not previous_token.is_empty() and _entries.has(previous_token) \
			and traversed < maxi(1, _resident_capacity * 6):
		var previous_entry: Dictionary = _entries[previous_token]
		var previous_identity := Dictionary(previous_entry.get("identity", {}))
		var previous_key := _identity_key(previous_identity)
		if int(_active_sequence_by_key.get(previous_key, 0)) == int(
			previous_entry.get("publication_sequence", 0)
		):
			break
		if _activation_token_is_protected(previous_token):
			break
		var next_previous_token := str(previous_entry.get(
			"retained_previous_token", ""
		))
		_free_entry_on_render_thread(previous_entry)
		_entries.erase(previous_token)
		previous_token = next_previous_token
		traversed += 1
	for retirement_value in Array(entry.get("retained_retirements", [])):
		var retirement := Dictionary(retirement_value)
		var retirement_token := str(retirement.get("token", ""))
		if _entries.has(retirement_token):
			var source := Dictionary(retirement.get("source", {}))
			if bool(source.get("deactivate", false)):
				_deactivate_entry_on_render_thread(
					str(retirement.get("key", "")), retirement_token, source, true
				)
			else:
				_retire_entry_on_render_thread(
					str(retirement.get("key", "")), retirement_token, source
				)
	entry.erase("retained_previous_token")
	entry.erase("retained_retirements")


func _rollback_gpu_candidate_on_render_thread(request: Dictionary) -> void:
	var key := str(request.get("key", ""))
	var sequence := int(request.get("publication_sequence", 0))
	var token := _entry_token(key, sequence)
	if not _entries.has(token):
		return
	var entry: Dictionary = _entries[token]
	var previous_token := str(entry.get("retained_previous_token", ""))
	if not previous_token.is_empty() and _entries.has(previous_token):
		var previous_entry: Dictionary = _entries[previous_token]
		_active_sequence_by_key[key] = int(previous_entry.get("publication_sequence", 0))
	elif int(_active_sequence_by_key.get(key, 0)) == sequence:
		_active_sequence_by_key.erase(key)
	_free_entry_on_render_thread(entry)
	_entries.erase(token)
	_active_lod_inventory_dirty = true


func _cancel_unpublished_entry_on_render_thread(
	key: String, publication_sequence: int
) -> void:
	var retained_pending: Array[Dictionary] = []
	var retained_interaction: Array[Dictionary] = []
	var cancelled_queued := 0
	_mutex.lock()
	for request_value in _pending_interaction:
		var request := Dictionary(request_value)
		if str(request.get("key", "")) == key \
				and int(request.get("publication_sequence", 0)) == publication_sequence:
			cancelled_queued += 1
		else:
			retained_interaction.append(request)
	for request_value in _pending:
		var request := Dictionary(request_value)
		if str(request.get("key", "")) == key \
				and int(request.get("publication_sequence", 0)) == publication_sequence:
			cancelled_queued += 1
		else:
			retained_pending.append(request)
	_pending_interaction = retained_interaction
	_pending = retained_pending
	_status["queued_request_count"] = _pending.size() + _pending_interaction.size()
	_status["queued_interaction_request_count"] = _pending_interaction.size()
	_status["cancelled_queued_requests"] = int(
		_status["cancelled_queued_requests"]
	) + cancelled_queued
	_mutex.unlock()

	var cancelled_inflight := 0
	for ticket_value in _inflight_extractions.keys():
		var ticket := int(ticket_value)
		var request := Dictionary(_inflight_extractions[ticket])
		if str(request.get("key", "")) != key \
				or int(request.get("publication_sequence", 0)) != publication_sequence \
				or _cancelled_inflight_tickets.has(ticket):
			continue
		# An unpublished candidate has no commit dependency. Render-thread command
		# ordering makes its slot reusable after the already-recorded extraction,
		# so reclaim it immediately instead of waiting for a readback that is only
		# requested after activation.
		_inflight_extractions.erase(ticket)
		_dispatch_pending_tickets.erase(ticket)
		_arena.discard_dispatch_completion(ticket)
		_arena.discard_readback(ticket)
		_rollback_gpu_candidate_on_render_thread(request)
		cancelled_inflight += 1
	if cancelled_inflight > 0:
		_sync_arena_status_on_render_thread()
		_mutex.lock()
		_status["cancelled_inflight_requests"] = int(
			_status["cancelled_inflight_requests"]
		) + cancelled_inflight
		_status["inflight_extraction_count"] = _inflight_extractions.size()
		_mutex.unlock()
	_sync_dispatch_lane_status_on_render_thread()


func _sync_active_lod_inventory_on_render_thread() -> void:
	if not _active_lod_inventory_dirty:
		return
	_active_lod_inventory_dirty = false
	var terrain_counts := {}
	var water_counts := {}
	var empty_count := 0
	var partial_count := 0
	var empty_examples: Array = []
	var partial_examples: Array = []
	var bins := {}
	for token_value in _entries.keys():
		var token := str(token_value)
		var entry: Dictionary = _entries[token]
		var identity := Dictionary(entry.get("identity", {}))
		var key := _identity_key(identity)
		var is_active := int(_active_sequence_by_key.get(key, 0)) \
			== int(entry.get("publication_sequence", 0))
		if bool(entry.get("empty", false)):
			if is_active:
				empty_count += 1
			if is_active and empty_examples.size() < 32:
				empty_examples.append(identity.duplicate(true))
		if int(entry.get("failure_cell_count", 0)) > 0:
			if is_active:
				partial_count += 1
			if is_active and partial_examples.size() < 32:
				var example := identity.duplicate(true)
				example["failure_cell_count"] = int(
					entry.get("failure_cell_count", 0)
				)
				partial_examples.append(example)
		if is_active:
			var lod := str(int(identity.get("lod", 0)))
			var counts := water_counts \
				if str(identity.get("surface", "")) == "static_water" else terrain_counts
			counts[lod] = int(counts.get(lod, 0)) + 1
		if is_active and not bool(entry.get("empty", false)):
			var minimum: Vector3 = entry.get("bounds_min", Vector3.ZERO)
			var maximum: Vector3 = entry.get("bounds_max", Vector3.ZERO)
			var center := (minimum + maximum) * 0.5
			var coordinate := Vector3i((center / DRAW_BIN_EXTENT).floor())
			var bin_key := "%d:%d:%d" % [coordinate.x, coordinate.y, coordinate.z]
			var bin: Dictionary = bins.get(bin_key, {
				"bounds_min": minimum,
				"bounds_max": maximum,
				"entries": [],
				"source_cell_count": 0,
			})
			bin["bounds_min"] = Vector3(bin["bounds_min"]).min(minimum)
			bin["bounds_max"] = Vector3(bin["bounds_max"]).max(maximum)
			var bin_entries: Array = bin["entries"]
			bin_entries.append(entry)
			bin["entries"] = bin_entries
			bin["source_cell_count"] = int(bin["source_cell_count"]) + int(
				entry.get("cell_count", 0)
			)
			bins[bin_key] = bin
	_draw_bins.assign(bins.values())
	_mutex.lock()
	_status["active_inventory_rebuilds"] = int(_status.get("active_inventory_rebuilds", 0)) + 1
	_status["active_terrain_lod_counts"] = terrain_counts
	_status["active_static_water_lod_counts"] = water_counts
	_status["active_empty_entry_count"] = empty_count
	_status["active_partial_entry_count"] = partial_count
	_status["active_empty_entry_examples"] = empty_examples
	_status["active_partial_entry_examples"] = partial_examples
	_status["draw_bin_count"] = _draw_bins.size()
	_mutex.unlock()


func _create_entry_on_render_thread(request: Dictionary) -> Dictionary:
	var input_buffers: Array = request.get("input_buffers", [])
	var cell_count := int(request.get("cell_count", 0))
	if input_buffers.size() != 13 or cell_count <= 0 or _arena == null:
		_record_render_error("global render request buffer inventory changed")
		return {}
	var entry: Dictionary = _arena.lease_and_dispatch(
		input_buffers,
		cell_count,
		request.get("bounds_min", Vector3.ZERO),
		request.get("bounds_max", Vector3.ZERO)
	)
	_sync_arena_status_on_render_thread()
	if entry.is_empty():
		_record_render_error(_arena.get_last_error())
		return {}
	entry["publication_sequence"] = int(request.get("publication_sequence", 0))
	entry["identity"] = Dictionary(request.get("identity", {})).duplicate(true)
	entry["bounds_min"] = request.get("bounds_min", Vector3.ZERO)
	entry["bounds_max"] = request.get("bounds_max", Vector3.ZERO)
	return entry


func _drain_debug_geometry_requests_on_render_thread() -> void:
	var requests: Array[Dictionary] = []
	_mutex.lock()
	requests.assign(_debug_geometry_requests)
	_debug_geometry_requests.clear()
	_mutex.unlock()
	for request in requests:
		var ray_results: Array[Dictionary] = []
		var total_readback_bytes := 0
		for ray_value in Array(request.get("rays", [])):
			var ray := Dictionary(ray_value)
			var origin: Vector3 = ray.get("origin", Vector3.ZERO)
			var direction: Vector3 = ray.get("direction", Vector3.ZERO)
			var maximum_distance := float(ray.get("max_distance", 0.0))
			var entry_results: Array[Dictionary] = []
			for entry_value in _entries.values():
				var entry := Dictionary(entry_value)
				var identity := Dictionary(entry.get("identity", {}))
				if not bool(entry.get("active", false)) \
						or str(identity.get("surface", "terrain")) != "terrain" \
						or bool(entry.get("empty", false)):
					continue
				var bounds_distance := _debug_ray_aabb_distance(
					origin,
					direction,
					entry.get("bounds_min", Vector3.ZERO),
					entry.get("bounds_max", Vector3.ZERO),
					maximum_distance
				)
				if bounds_distance < 0.0:
					continue
				var probe := Dictionary(_arena.debug_ray_intersection(
					entry, origin, direction, maximum_distance,
					bool(ray.get("include_geometry", false))
				))
				total_readback_bytes += int(probe.get("geometry_readback_bytes", 0))
				probe["bounds_distance"] = bounds_distance
				probe["identity"] = identity.duplicate(true)
				entry_results.append(probe)
			entry_results.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
				return float(left.get("bounds_distance", INF)) < \
					float(right.get("bounds_distance", INF))
			)
			ray_results.append({
				"index": int(ray.get("index", -1)),
				"entries": entry_results,
			})
		var result := {
			"request_id": int(request.get("request_id", 0)),
			"rays": ray_results,
			"geometry_readback_bytes": total_readback_bytes,
		}
		_mutex.lock()
		_status["geometry_readback_bytes"] = int(
			_status.get("geometry_readback_bytes", 0)
		) + total_readback_bytes
		_debug_geometry_results[int(request.get("request_id", 0))] = result
		_mutex.unlock()


static func _debug_ray_aabb_distance(
	origin: Vector3,
	direction: Vector3,
	minimum: Vector3,
	maximum: Vector3,
	maximum_distance: float
) -> float:
	var near_distance := 0.0
	var far_distance := maximum_distance
	for axis in range(3):
		if absf(direction[axis]) <= 0.000001:
			if origin[axis] < minimum[axis] or origin[axis] > maximum[axis]:
				return -1.0
			continue
		var first := (minimum[axis] - origin[axis]) / direction[axis]
		var second := (maximum[axis] - origin[axis]) / direction[axis]
		if first > second:
			var swap := first
			first = second
			second = swap
		near_distance = maxf(near_distance, first)
		far_distance = minf(far_distance, second)
		if near_distance > far_distance:
			return -1.0
	return near_distance if far_distance >= 0.0 else -1.0


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
	var bin_visibility_tests := 0
	var bin_culled_surfaces := 0
	var visible_surfaces := 0
	var compact_command_records := 0
	var source_records_avoided := 0
	var cached_push_uses := 0
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
		var water_scene_set := RID()
		var water_ready := _production_water_set.is_valid()
		if water_ready:
			if not _ensure_production_water_pipeline(
				_rendering_device.framebuffer_get_format(framebuffer)
			):
				_record_render_error("production water raster pipeline failed")
				return
			water_scene_set = UniformSetCacheRD.get_cache(
				_production_water_shader, 0, [scene_uniform]
			)
			if not water_scene_set.is_valid():
				_record_render_error("production water scene uniform set failed")
				return
		var production_entries: Array[Dictionary] = []
		var diagnostic_entries: Array[Dictionary] = []
		var water_entries: Array[Dictionary] = []
		var visibility_context := _visibility_context_for_view(scene_data, view)
		for bin_value in _draw_bins:
			var bin: Dictionary = bin_value
			var bin_entries: Array = bin.get("entries", [])
			bin_visibility_tests += 1
			if not _entry_visible_for_context(bin, visibility_context):
				culled_surfaces += bin_entries.size()
				bin_culled_surfaces += bin_entries.size()
				view_records_avoided += int(bin.get("source_cell_count", 0))
				continue
			for entry_value in bin_entries:
				var entry: Dictionary = entry_value
				visibility_tests += 1
				var source_cell_count := int(entry.get("cell_count", 0))
				last_tested_bounds_min = entry.get("bounds_min", Vector3.ZERO)
				last_tested_bounds_max = entry.get("bounds_max", Vector3.ZERO)
				if not _entry_visible_for_context(entry, visibility_context):
					culled_surfaces += 1
					view_records_avoided += source_cell_count
					continue
				visible_surfaces += 1
				var surface := str(Dictionary(
					entry.get("identity", {})
				).get("surface", ""))
				if surface == "terrain" and production_ready:
					production_entries.append(entry)
				elif surface == "static_water" and water_ready:
					water_entries.append(entry)
				else:
					diagnostic_entries.append(entry)
				view_command_records += 1
				view_records_avoided += maxi(0, source_cell_count - 1)
		var draw_list := _rendering_device.draw_list_begin(framebuffer)
		if not production_entries.is_empty():
			_rendering_device.draw_list_bind_render_pipeline(
				draw_list, _production_raster_pipeline
			)
			_rendering_device.draw_list_bind_uniform_set(
				draw_list, production_scene_set, 0
			)
			_rendering_device.draw_list_bind_uniform_set(
				draw_list, _production_material_set, 1
			)
			_rendering_device.draw_list_bind_uniform_set(
				draw_list, _activation_set_for(_production_raster_shader), 3
			)
			for entry in production_entries:
				var push_bytes: PackedByteArray = entry.get("mono_push_bytes", PackedByteArray()) \
					if view_count == 1 else _entry_push_bytes(entry, view, view_count, size, false)
				cached_push_uses += 1 if view_count == 1 else 0
				_draw_entry_on_render_thread(
					draw_list,
					entry,
					push_bytes
				)
		if not diagnostic_entries.is_empty():
			_rendering_device.draw_list_bind_render_pipeline(draw_list, _raster_pipeline)
			_rendering_device.draw_list_bind_uniform_set(draw_list, scene_set, 0)
			_rendering_device.draw_list_bind_uniform_set(
				draw_list, _activation_set_for(_raster_shader), 3
			)
			for entry in diagnostic_entries:
				var push_bytes: PackedByteArray = entry.get("mono_push_bytes", PackedByteArray()) \
					if view_count == 1 else _entry_push_bytes(entry, view, view_count, size, false)
				cached_push_uses += 1 if view_count == 1 else 0
				_draw_entry_on_render_thread(
					draw_list,
					entry,
					push_bytes
				)
		_rendering_device.draw_list_end()
		if not water_entries.is_empty():
			var opaque_scene := _copy_scene_color_on_render_thread(
				scene_buffers, view, color, size, view_count
			)
			if not opaque_scene.is_valid():
				_record_render_error("production water scene-color copy failed")
				return
			var water_texture := RDUniform.new()
			water_texture.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			water_texture.binding = 0
			water_texture.add_id(_scene_color_sampler)
			water_texture.add_id(opaque_scene)
			var water_scene_texture_set: RID = UniformSetCacheRD.get_cache(
				_production_water_shader, 2, [water_texture]
			)
			if not water_scene_texture_set.is_valid():
				_record_render_error("production water scene texture set failed")
				return
			var water_draw_list := _rendering_device.draw_list_begin(framebuffer)
			_rendering_device.draw_list_bind_render_pipeline(
				water_draw_list, _production_water_pipeline
			)
			_rendering_device.draw_list_bind_uniform_set(
				water_draw_list, water_scene_set, 0
			)
			_rendering_device.draw_list_bind_uniform_set(
				water_draw_list, _production_water_set, 1
			)
			_rendering_device.draw_list_bind_uniform_set(
				water_draw_list, water_scene_texture_set, 2
			)
			_rendering_device.draw_list_bind_uniform_set(
				water_draw_list, _activation_set_for(_production_water_shader), 3
			)
			for entry in water_entries:
				_draw_entry_on_render_thread(
					water_draw_list,
					entry,
					_entry_push_bytes(entry, view, view_count, size, true)
				)
			_rendering_device.draw_list_end()
			_mutex.lock()
			_status["production_static_water_scene_copy_ready"] = true
			_mutex.unlock()
		draw_calls += view_command_records
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
	_status["bin_visibility_test_count"] = int(
		_status["bin_visibility_test_count"]
	) + bin_visibility_tests
	_status["bin_culled_surface_count"] = int(
		_status["bin_culled_surface_count"]
	) + bin_culled_surfaces
	_status["last_visible_surface_count"] = visible_surfaces
	_status["last_culled_surface_count"] = culled_surfaces
	_status["cached_terrain_push_constant_uses"] = int(
		_status["cached_terrain_push_constant_uses"]
	) + cached_push_uses
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


func _draw_entry_on_render_thread(
	draw_list: int, entry: Dictionary, push_bytes: PackedByteArray
) -> void:
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
	if (_critical_path_timeline_enabled \
			or bool(Dictionary(entry.get("identity", {})).get("incremental_edit", false))) \
			and not bool(entry.get("first_draw_reported", false)):
		entry["first_draw_reported"] = true
		_push_event_on_render_thread("FIRST_DRAW", {
			"publication_sequence": int(entry.get("publication_sequence", 0)),
			"identity": Dictionary(entry.get("identity", {})).duplicate(true),
			"entry_empty": bool(entry.get("empty", false)),
			"entry_vertex_count": int(entry.get("vertex_count", 0)),
			"entry_index_count": int(entry.get("index_count", 0)),
			"entry_failure_cell_count": int(entry.get("failure_cell_count", 0)),
			"entry_cell_count": int(entry.get("cell_count", 0)),
		})


static func _entry_push_bytes(
	entry: Dictionary,
	view: int,
	view_count: int,
	viewport: Vector2i,
	include_viewport: bool
) -> PackedByteArray:
	var bounds_min: Vector3 = entry.get("bounds_min", Vector3.ZERO)
	var bounds_max: Vector3 = entry.get("bounds_max", Vector3.ONE)
	var extent := bounds_max - bounds_min
	var bounds_offset := 32 if include_viewport else 16
	var bytes := PackedByteArray()
	bytes.resize(bounds_offset + 32)
	bytes.encode_s32(0, view)
	bytes.encode_s32(4, view_count)
	bytes.encode_s32(8, int(entry.get("gpu_slot", -1)))
	if include_viewport:
		bytes.encode_s32(16, viewport.x)
		bytes.encode_s32(20, viewport.y)
	for component in range(3):
		bytes.encode_float(bounds_offset + component * 4, bounds_min[component])
		bytes.encode_float(
			bounds_offset + 16 + component * 4, extent[component]
		)
	return bytes


func _activation_set_for(shader: RID) -> RID:
	if _arena == null or not shader.is_valid():
		return RID()
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(_arena.activation_buffer())
	return UniformSetCacheRD.get_cache(shader, 3, [uniform])


func _copy_scene_color_on_render_thread(
	scene_buffers: RenderSceneBuffersRD,
	view: int,
	color: RID,
	size: Vector2i,
	view_count: int
) -> RID:
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var texture := scene_buffers.create_texture(
		"world_transvoxel",
		"opaque_after_terrain",
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		usage,
		RenderingDevice.TEXTURE_SAMPLES_1,
		size,
		view_count,
		1,
		false,
		false
	)
	if not texture.is_valid():
		return RID()
	var destination := scene_buffers.get_texture_slice(
		"world_transvoxel", "opaque_after_terrain", view, 0, 1, 1
	)
	if not destination.is_valid():
		return RID()
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	source_uniform.binding = 0
	source_uniform.add_id(_scene_color_sampler)
	source_uniform.add_id(color)
	var destination_uniform := RDUniform.new()
	destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	destination_uniform.binding = 1
	destination_uniform.add_id(destination)
	var copy_set: RID = UniformSetCacheRD.get_cache(
		_scene_color_copy_shader, 0, [source_uniform, destination_uniform]
	)
	if not copy_set.is_valid():
		return RID()
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(
		compute_list, _scene_color_copy_pipeline
	)
	_rendering_device.compute_list_bind_uniform_set(compute_list, copy_set, 0)
	var copy_push := PackedInt32Array([size.x, size.y, 0, 0]).to_byte_array()
	_rendering_device.compute_list_set_push_constant(
		compute_list, copy_push, copy_push.size()
	)
	_rendering_device.compute_list_dispatch(
		compute_list,
		ceili(float(size.x) / 8.0),
		ceili(float(size.y) / 8.0),
		1
	)
	_rendering_device.compute_list_end()
	return destination


func _ensure_raster_pipeline(framebuffer_format: int) -> bool:
	if _raster_pipeline.is_valid() and _raster_pipeline_format == framebuffer_format:
		return true
	if _raster_pipeline.is_valid():
		_rendering_device.free_rid(_raster_pipeline)
		_raster_pipeline = RID()
	var rasterization := RDPipelineRasterizationState.new()
	# CPU authority normalizes connected triangle components after deformation.
	# Keep every authoritative GPU triangle visible until that global pass has a
	# GPU equivalent; local per-triangle flips can break shared-edge winding.
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
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
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


func _ensure_production_water_pipeline(framebuffer_format: int) -> bool:
	if _production_water_pipeline.is_valid() \
			and _production_water_pipeline_format == framebuffer_format:
		return true
	if _production_water_pipeline.is_valid():
		_rendering_device.free_rid(_production_water_pipeline)
		_production_water_pipeline = RID()
	var rasterization := RDPipelineRasterizationState.new()
	# The CPU authority orients connected components to interpolated normals.
	# GPU publication performs that facing decision in the fragment shader so
	# inconsistent raw table winding cannot punch holes into the water surface.
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var depth_stencil := RDPipelineDepthStencilState.new()
	depth_stencil.enable_depth_test = true
	depth_stencil.enable_depth_write = true
	depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var color_attachment := RDPipelineColorBlendStateAttachment.new()
	color_attachment.enable_blend = false
	var color_blend := RDPipelineColorBlendState.new()
	color_blend.attachments = [color_attachment]
	_production_water_pipeline = _rendering_device.render_pipeline_create(
		_production_water_shader,
		framebuffer_format,
		_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterization,
		RDPipelineMultisampleState.new(),
		depth_stencil,
		color_blend
	)
	_production_water_pipeline_format = framebuffer_format
	return _production_water_pipeline.is_valid()


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
	_inflight_extractions.clear()
	_dispatch_pending_tickets.clear()
	_cancelled_inflight_tickets.clear()
	_pending_compactions.clear()
	_compaction_eligible_callback_by_token.clear()
	_compaction_idle_callbacks = 0
	_protected_activation_tokens.clear()
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
		_production_raster_shader, _production_water_set,
		_production_water_buffer, _production_water_pipeline,
		_production_water_shader, _scene_color_copy_pipeline,
		_scene_color_copy_shader, _scene_color_sampler,
		_raster_pipeline, _raster_shader,
		_completion_pipeline, _completion_shader,
		_compact_pipeline, _compact_shader,
		_commit_pipeline, _commit_shader, _compute_pipeline, _compute_shader,
	])
	_production_material_set = RID()
	_production_material_buffer = RID()
	_production_material_sampler = RID()
	_production_raster_pipeline = RID()
	_production_raster_shader = RID()
	_production_water_set = RID()
	_production_water_buffer = RID()
	_production_water_pipeline = RID()
	_production_water_shader = RID()
	_scene_color_copy_pipeline = RID()
	_scene_color_copy_shader = RID()
	_scene_color_sampler = RID()
	_raster_pipeline = RID()
	_raster_shader = RID()
	_commit_pipeline = RID()
	_commit_shader = RID()
	_completion_pipeline = RID()
	_completion_shader = RID()
	_compact_pipeline = RID()
	_compact_shader = RID()
	_compute_pipeline = RID()
	_compute_shader = RID()
	_mutex.lock()
	_status["resident_entry_count"] = 0
	_status["active_entry_count"] = 0
	_status["inflight_extraction_count"] = 0
	_status["dispatch_pending_count"] = 0
	_status["background_dispatch_pending_count"] = 0
	_status["interaction_dispatch_pending_count"] = 0
	_status["pending_compaction_count"] = 0
	_status["compaction_idle_callbacks"] = 0
	_status["protected_activation_entries"] = 0
	_close_completed = true
	_mutex.unlock()


func _free_entry_on_render_thread(entry: Dictionary) -> void:
	var identity := Dictionary(entry.get("identity", {}))
	var sequence := int(entry.get("publication_sequence", 0))
	if not identity.is_empty() and sequence > 0:
		_mutex.lock()
		_protected_activation_tokens.erase(_entry_token(
			_identity_key(identity), sequence
		))
		_status["protected_activation_entries"] = _protected_activation_tokens.size()
		_mutex.unlock()
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
	_status["arena_scratch_in_flight"] = int(
		arena_status.get("scratch_in_flight", 0)
	)
	_status["arena_scratch_allocated_bytes"] = int(
		arena_status.get("scratch_allocated_bytes", 0)
	)
	_status["arena_resident_allocated_bytes"] = int(
		arena_status.get("resident_allocated_bytes", 0)
	)
	_status["arena_counter_readback_bytes"] = int(
		arena_status.get("counter_readback_bytes", 0)
	)
	_status["counter_readback_bytes"] = int(
		arena_status.get("counter_readback_bytes", 0)
	)
	_status["dispatch_completion_requests"] = int(
		arena_status.get("dispatch_completion_requests", 0)
	)
	_status["dispatch_completion_completions"] = int(
		arena_status.get("dispatch_completion_completions", 0)
	)
	_status["dispatch_completion_bytes"] = int(
		arena_status.get("dispatch_completion_bytes", 0)
	)
	_status["pending_dispatch_completion_count"] = int(
		arena_status.get("completed_dispatch_queue_count", 0)
	)
	_status["pending_telemetry_completion_count"] = int(
		arena_status.get("completed_readback_queue_count", 0)
	)
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
	var command := {
		"action": action,
		"identity": identity.duplicate(true),
		"publication_sequence": publication_sequence,
	}
	if _lifecycle_command_is_interaction(command):
		_interaction_lifecycle_commands.append(command)
	else:
		_lifecycle_commands.append(command)
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
		"ticks_usec": Time.get_ticks_usec() if (
			_critical_path_timeline_enabled
			or event_status == "FIRST_DRAW"
		) else 0,
		"request_id": int(source.get("request_id", 0)),
		"publication_sequence": int(source.get("publication_sequence", 0)),
		"controller_group_key": str(source.get("controller_group_key", "")),
		"identity": Dictionary(source.get("identity", {})).duplicate(true),
		"entry_empty": bool(source.get("entry_empty", false)),
		"entry_vertex_count": int(source.get("entry_vertex_count", 0)),
		"entry_index_count": int(source.get("entry_index_count", 0)),
		"entry_failure_cell_count": int(source.get(
			"entry_failure_cell_count", 0
		)),
		"entry_cell_count": int(source.get("entry_cell_count", 0)),
		"source_cell_count": int(source.get("source_cell_count", 0)),
		"gpu_uploaded_bytes": int(source.get("gpu_uploaded_bytes", 0)),
		"gpu_dispatch_ticks_usec": int(source.get("gpu_dispatch_ticks_usec", 0)),
		"gpu_readback_ticks_usec": int(source.get("gpu_readback_ticks_usec", 0)),
		"error": error,
	}
	_mutex.lock()
	if bool(Dictionary(event.get("identity", {})).get("incremental_edit", false)):
		_priority_events[_priority_event_tail] = event
		_priority_event_tail += 1
	else:
		_events[_event_tail] = event
		_event_tail += 1
	_status["event_count"] = _priority_events.size() + _events.size()
	_status["priority_event_count"] = _priority_events.size()
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
	return _entry_visible_for_context(entry, _visibility_context_for_view(scene_data, view))


static func _visibility_context_for_view(
	scene_data: RenderSceneData, view: int
) -> Dictionary:
	var camera_transform := scene_data.get_cam_transform()
	var eye_offset := scene_data.get_view_eye_offset(view)
	var eye_transform := Transform3D(
		camera_transform.basis,
		camera_transform.origin + camera_transform.basis * eye_offset
	)
	return {
		"world_to_view": eye_transform.affine_inverse(),
		"projection": scene_data.get_view_projection(view),
	}


static func _entry_visible_for_context(entry: Dictionary, context: Dictionary) -> bool:
	var minimum: Vector3 = entry.get("bounds_min", Vector3.ZERO)
	var maximum: Vector3 = entry.get("bounds_max", Vector3.ZERO)
	if not _bounds_are_valid(minimum, maximum):
		return true
	var world_to_view: Transform3D = context.get("world_to_view", Transform3D.IDENTITY)
	var projection: Projection = context.get("projection", Projection())
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


static func _vertex_attribute(
	location: int, format: int, stride: int
) -> RDVertexAttribute:
	var attribute := RDVertexAttribute.new()
	attribute.location = location
	attribute.offset = 0
	attribute.format = format
	attribute.stride = stride
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
	# Active double-buffered surfaces and both bounded request lanes can coexist.
	# Omitting the interaction lane here made its reserved queue compete for arena
	# descriptor slots with background candidates at peak residency.
	return (_resident_capacity * MAXIMUM_SURFACES_PER_CHUNK
		+ REQUEST_CAPACITY + INTERACTION_REQUEST_CAPACITY)


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
