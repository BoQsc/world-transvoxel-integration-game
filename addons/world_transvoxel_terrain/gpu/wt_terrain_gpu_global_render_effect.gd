@tool
extends CompositorEffect
class_name WtTerrainGpuGlobalRenderEffect

const MeshingCandidate := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_candidate.gd"
)
const COMPUTE_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing.glsl"
)
const RASTER_SHADER_FILE := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render.glsl"
)
const RESULT_SCHEMA := "world_transvoxel.terrain.gpu_global_render_publication.v1"
const REQUEST_CAPACITY := 3
const DEFAULT_RESIDENT_CAPACITY := 64
const LOCAL_SIZE := 64
const MAXIMUM_VERTICES_PER_CELL := 12
const MAXIMUM_INDICES_PER_CELL := 36
const DRAW_COMMAND_STRIDE := 20
const REQUIRED_IDENTITY_FIELDS := [
	"page_x", "page_y", "page_z", "lod", "generation", "source_revision",
	"world_revision", "transition_mask", "field_mode", "sample_count", "surface",
]

var _rendering_device: RenderingDevice
var _packer = MeshingCandidate.new()
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
	"resident_buffer_count_per_entry": 21,
	"gpu_written_indirect_commands": true,
	"device_local_index_copy_used": true,
	"fallback_used": false,
	"request_capacity": REQUEST_CAPACITY,
	"resident_capacity": DEFAULT_RESIDENT_CAPACITY,
	"resident_allocation_capacity": DEFAULT_RESIDENT_CAPACITY + REQUEST_CAPACITY,
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
	"last_error": "",
	"last_applied_identity": {},
}


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	enabled = true
	_rendering_device = RenderingServer.get_rendering_device()


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
	var packed: Dictionary = _packer.pack_explicit_samples_for_global_rendering(
		densities,
		gradients,
		materials,
		material_authored,
		cells,
		identity
	)
	if str(packed.get("status", "")) != "PASS" \
			or bool(packed.get("fallback_used", true)):
		_record_rejection(str(packed.get("error", "global request packing failed")))
		return 0
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
		"cell_count": int(packed.get("cell_count", 0)),
		"input_buffers": Array(packed.get("input_buffers", [])).duplicate(),
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
		_resident_capacity + REQUEST_CAPACITY
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
	_drain_pending_on_render_thread()
	_drain_lifecycle_commands_on_render_thread()
	_draw_entries_on_render_thread(render_data)


func _ensure_shaders() -> bool:
	if _compute_pipeline.is_valid() and _raster_shader.is_valid() \
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
	if compute_file == null or raster_file == null \
			or not compute_file.get_base_error().is_empty() \
			or not raster_file.get_base_error().is_empty():
		_record_render_error("global render shader import is invalid: %s %s" % [
			compute_file.get_base_error() if compute_file != null else "compute missing",
			raster_file.get_base_error() if raster_file != null else "raster missing",
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
	_mutex.lock()
	_status["initialized"] = _vertex_format >= 0
	_mutex.unlock()
	return _vertex_format >= 0


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
		if _entries.size() >= _resident_capacity + REQUEST_CAPACITY:
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
	_mutex.unlock()
	_push_event_on_render_thread("RETIRED", source)


func _create_entry_on_render_thread(request: Dictionary) -> Dictionary:
	var input_buffers: Array = request.get("input_buffers", [])
	var cell_count := int(request.get("cell_count", 0))
	if input_buffers.size() != 13 or cell_count <= 0:
		_record_render_error("global render request buffer inventory changed")
		return {}
	var output_sizes := _output_buffer_sizes(cell_count)
	var buffers: Array[RID] = []
	for binding in range(21):
		var data := PackedByteArray()
		var size := 0
		if binding < 13:
			data = input_buffers[binding]
			size = data.size()
		else:
			size = output_sizes[binding - 13]
		var buffer := _create_buffer(binding, size, data)
		if not buffer.is_valid():
			_free_rids_on_render_thread(buffers)
			_record_render_error("global render buffer creation failed at %d" % binding)
			return {}
		buffers.append(buffer)
	var uniforms: Array[RDUniform] = []
	for binding in range(buffers.size()):
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(buffers[binding])
		uniforms.append(uniform)
	var compute_set := _rendering_device.uniform_set_create(
		uniforms, _compute_shader, 0
	)
	if not compute_set.is_valid():
		_free_rids_on_render_thread(buffers)
		_record_render_error("global render compute uniform set creation failed")
		return {}
	var index_count := cell_count * MAXIMUM_INDICES_PER_CELL
	var raster_index_buffer := _rendering_device.index_buffer_create(
		index_count, RenderingDevice.INDEX_BUFFER_FORMAT_UINT32
	)
	if not raster_index_buffer.is_valid():
		_rendering_device.free_rid(compute_set)
		_free_rids_on_render_thread(buffers)
		_record_render_error("global render raster index buffer creation failed")
		return {}
	var vertex_buffers: Array[RID] = [buffers[13], buffers[14], buffers[15]]
	var vertex_array := _rendering_device.vertex_array_create(
		cell_count * MAXIMUM_VERTICES_PER_CELL,
		_vertex_format,
		vertex_buffers
	)
	var index_array := _rendering_device.index_array_create(
		raster_index_buffer, 0, index_count
	)
	if not vertex_array.is_valid() or not index_array.is_valid():
		_free_rids_on_render_thread([vertex_array, index_array, raster_index_buffer])
		_rendering_device.free_rid(compute_set)
		_free_rids_on_render_thread(buffers)
		_record_render_error("global render vertex/index views failed")
		return {}
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(
		compute_list, _compute_pipeline
	)
	_rendering_device.compute_list_bind_uniform_set(compute_list, compute_set, 0)
	_rendering_device.compute_list_dispatch(
		compute_list, int((cell_count + LOCAL_SIZE - 1) / LOCAL_SIZE), 1, 1
	)
	_rendering_device.compute_list_end()
	var copy_error := _rendering_device.buffer_copy(
		buffers[17], raster_index_buffer, 0, 0, index_count * 4
	)
	if copy_error != OK:
		_free_rids_on_render_thread([vertex_array, index_array, raster_index_buffer])
		_rendering_device.free_rid(compute_set)
		_free_rids_on_render_thread(buffers)
		_record_render_error(
			"global render index copy failed: %s" % error_string(copy_error)
		)
		return {}
	return {
		"buffers": buffers,
		"compute_set": compute_set,
		"raster_index_buffer": raster_index_buffer,
		"vertex_array": vertex_array,
		"index_array": index_array,
		"cell_count": cell_count,
		"publication_sequence": int(request.get("publication_sequence", 0)),
		"identity": Dictionary(request.get("identity", {})).duplicate(true),
	}


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
	for view in range(view_count):
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
		var draw_list := _rendering_device.draw_list_begin(framebuffer)
		_rendering_device.draw_list_bind_render_pipeline(draw_list, _raster_pipeline)
		_rendering_device.draw_list_bind_uniform_set(draw_list, scene_set, 0)
		var push_bytes := PackedInt32Array([view, view_count, 0, 0]).to_byte_array()
		for entry_value in _entries.values():
			var entry: Dictionary = entry_value
			if not bool(entry.get("active", false)):
				continue
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
				Array(entry.get("buffers", []))[20],
				0,
				int(entry.get("cell_count", 0)),
				DRAW_COMMAND_STRIDE
			)
			draw_calls += 1
		_rendering_device.draw_list_end()
	_mutex.lock()
	_status["draw_frames"] = int(_status["draw_frames"]) + 1
	_status["indirect_draw_calls"] = int(_status["indirect_draw_calls"]) + draw_calls
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


func _create_buffer(binding: int, size: int, data: PackedByteArray) -> RID:
	if size <= 0:
		return RID()
	if binding in [13, 14, 15]:
		return _rendering_device.vertex_buffer_create(
			size, data, RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
		)
	if binding == 20:
		return _rendering_device.storage_buffer_create(
			size, data, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
		)
	return _rendering_device.storage_buffer_create(size, data)


func _close_on_render_thread() -> void:
	for entry in _entries.values():
		_free_entry_on_render_thread(entry)
	_entries.clear()
	_active_sequence_by_key.clear()
	for framebuffer in _framebuffers.values():
		if framebuffer is RID and framebuffer.is_valid():
			_rendering_device.free_rid(framebuffer)
	_framebuffers.clear()
	_free_rids_on_render_thread([
		_raster_pipeline, _raster_shader, _compute_pipeline, _compute_shader,
	])
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
	_free_rids_on_render_thread([
		entry.get("vertex_array", RID()),
		entry.get("index_array", RID()),
		entry.get("raster_index_buffer", RID()),
		entry.get("compute_set", RID()),
	])
	_free_rids_on_render_thread(Array(entry.get("buffers", [])))


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


static func _output_buffer_sizes(cell_count: int) -> Array[int]:
	return [
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_INDICES_PER_CELL * 4,
		cell_count * 16,
		48,
		cell_count * DRAW_COMMAND_STRIDE,
	]


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
