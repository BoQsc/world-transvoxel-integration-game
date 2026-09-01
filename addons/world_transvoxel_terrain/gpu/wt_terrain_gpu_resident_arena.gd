@tool
extends RefCounted
class_name WtTerrainGpuResidentArena

const BINDING_COUNT := 21
const INPUT_BINDING_COUNT := 13
const TABLE_BINDING_BEGIN := 7
const TABLE_BINDING_END := 13
const PAGE_SLOT_COUNT := 4
const LOCAL_SIZE := 64
const MAXIMUM_VERTICES_PER_CELL := 12
const MAXIMUM_INDICES_PER_CELL := 36
const DRAW_COMMAND_STRIDE := 20
const PACKED_POSITION_STRIDE := 12
const PACKED_NORMAL_STRIDE := 4
const PACKED_META_STRIDE := 4

var _rendering_device: RenderingDevice
var _compute_shader := RID()
var _compute_pipeline := RID()
var _vertex_format := -1
var _maximum_slots := 0
var _pages: Array[Dictionary] = []
var _pending_readbacks: Dictionary = {}
var _completed_readbacks: Array[Dictionary] = []
var _readback_mutex := Mutex.new()
var _next_ticket := 1
var _closed := false
var _allocated_slot_count := 0
var _scratch_in_flight_count := 0
var _peak_scratch_in_flight_count := 0
var _active_slot_count := 0
var _peak_active_slot_count := 0
var _scratch_allocated_bytes := 0
var _resident_allocated_bytes := 0
var _peak_resident_allocated_bytes := 0
var _page_allocations := 0
var _page_replacements := 0
var _slot_leases := 0
var _slot_reuses := 0
var _slot_releases := 0
var _uploaded_bytes := 0
var _dispatch_count := 0
var _counter_readback_requests := 0
var _counter_readback_completions := 0
var _counter_readback_bytes := 0
var _compacted_resident_entries := 0
var _empty_resident_entries := 0
var _proven_empty_resident_entries := 0
var _failed_extractions := 0
var _failed_cell_count_total := 0
var _last_failure_cell_count := 0
var _last_error := ""


func initialize(
	rendering_device: RenderingDevice,
	compute_shader: RID,
	compute_pipeline: RID,
	vertex_format: int,
	maximum_slots: int
) -> bool:
	if rendering_device == null or not compute_shader.is_valid() \
			or not compute_pipeline.is_valid() or vertex_format < 0 \
			or maximum_slots <= 0:
		_last_error = "resident arena initialization parameters are invalid"
		return false
	_rendering_device = rendering_device
	_compute_shader = compute_shader
	_compute_pipeline = compute_pipeline
	_vertex_format = vertex_format
	_maximum_slots = maximum_slots
	_closed = false
	_last_error = ""
	return true


func lease_and_dispatch(
	input_buffers: Array,
	cell_count: int,
	bounds_min: Vector3,
	bounds_max: Vector3
) -> Dictionary:
	var validation_error := _validate_request(input_buffers, cell_count)
	if not validation_error.is_empty():
		_last_error = validation_error
		return {}
	if not bounds_min.is_finite() or not bounds_max.is_finite() \
			or bounds_min.x >= bounds_max.x or bounds_min.y >= bounds_max.y \
			or bounds_min.z >= bounds_max.z:
		_last_error = "resident arena bounds are invalid"
		return {}
	var page_index := _find_page(input_buffers, cell_count)
	if page_index < 0:
		page_index = _create_page(input_buffers, cell_count)
	if page_index < 0:
		return {}
	var page: Dictionary = _pages[page_index]
	var free_slots: Array = page.get("free_slots", [])
	if free_slots.is_empty():
		_last_error = "resident arena scratch capacity is busy"
		return {}
	var slot_index := int(free_slots.pop_front())
	page["free_slots"] = free_slots
	var lease_counts: Array = page.get("lease_counts", [])
	if int(lease_counts[slot_index]) > 0:
		_slot_reuses += 1
	lease_counts[slot_index] = int(lease_counts[slot_index]) + 1
	page["lease_counts"] = lease_counts
	var slots: Array = page.get("slots", [])
	var slot: Dictionary = slots[slot_index]
	slot["in_use"] = true
	slots[slot_index] = slot
	page["slots"] = slots
	_pages[page_index] = page
	var strides: Array = page.get("strides", [])
	var buffers: Array = page.get("buffers", [])
	for binding in range(TABLE_BINDING_BEGIN):
		var bytes: PackedByteArray = input_buffers[binding]
		var offset := slot_index * int(strides[binding])
		var update_error := _rendering_device.buffer_update(
			buffers[binding], offset, bytes.size(), bytes
		)
		if update_error != OK:
			_release_scratch_slot(page_index, slot_index, int(page.get("generation", 0)))
			_last_error = "resident arena input upload failed at binding %d: %s" % [
				binding, error_string(update_error),
			]
			return {}
		_uploaded_bytes += bytes.size()
	var indirect_offset := slot_index * int(strides[20])
	var initial_command := PackedInt32Array([0, 1, 0, 0, 0]).to_byte_array()
	var command_error := _rendering_device.buffer_update(
		buffers[20], indirect_offset, initial_command.size(), initial_command
	)
	if command_error != OK:
		_release_scratch_slot(page_index, slot_index, int(page.get("generation", 0)))
		_last_error = "resident arena counter initialization failed: %s" % [
			error_string(command_error),
		]
		return {}
	var push_bytes := _push_constant_bytes(
		strides, slot_index, bounds_min, bounds_max
	)
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(compute_list, _compute_pipeline)
	_rendering_device.compute_list_bind_uniform_set(
		compute_list, page.get("uniform_set", RID()), 0
	)
	_rendering_device.compute_list_set_push_constant(
		compute_list, push_bytes, push_bytes.size()
	)
	_rendering_device.compute_list_dispatch(
		compute_list, int((cell_count + LOCAL_SIZE - 1) / LOCAL_SIZE), 1, 1
	)
	_rendering_device.compute_list_end()
	_dispatch_count += 1
	var ticket := _next_ticket
	_next_ticket += 1
	_pending_readbacks[ticket] = {
		"ticket": ticket,
		"arena_page_index": page_index,
		"arena_slot_index": slot_index,
		"arena_generation": int(page.get("generation", 0)),
		"cell_count": cell_count,
	}
	var readback_error := _rendering_device.buffer_get_data_async(
		buffers[20],
		Callable(self, "_on_counter_readback").bind(ticket),
		indirect_offset,
		DRAW_COMMAND_STRIDE
	)
	if readback_error != OK:
		_pending_readbacks.erase(ticket)
		_release_scratch_slot(page_index, slot_index, int(page.get("generation", 0)))
		_last_error = "resident arena asynchronous counter readback failed: %s" % [
			error_string(readback_error),
		]
		return {}
	_slot_leases += 1
	_scratch_in_flight_count += 1
	_peak_scratch_in_flight_count = maxi(
		_peak_scratch_in_flight_count, _scratch_in_flight_count
	)
	_counter_readback_requests += 1
	_last_error = ""
	return {
		"status": "PENDING_COUNTER_READBACK",
		"arena_ticket": ticket,
		"cell_count": cell_count,
	}


func pop_completed_readbacks() -> Array[Dictionary]:
	_readback_mutex.lock()
	var completed: Array[Dictionary] = []
	completed.assign(_completed_readbacks)
	_completed_readbacks.clear()
	_readback_mutex.unlock()
	return completed


func create_proven_empty(cell_count: int) -> Dictionary:
	if _closed or cell_count <= 0:
		_last_error = "proven-empty resident entry is invalid"
		return {}
	_active_slot_count += 1
	_peak_active_slot_count = maxi(_peak_active_slot_count, _active_slot_count)
	_empty_resident_entries += 1
	_proven_empty_resident_entries += 1
	_last_error = ""
	return {
		"resident_kind": "empty",
		"empty": true,
		"failure_cell_count": 0,
		"vertex_count": 0,
		"index_count": 0,
		"cell_count": cell_count,
		"proven_empty": true,
	}


func finalize_readback(ticket: int, data: PackedByteArray) -> Dictionary:
	if not _pending_readbacks.has(ticket):
		_last_error = "resident arena counter readback ticket is unknown"
		return {}
	var scratch: Dictionary = _pending_readbacks[ticket]
	_pending_readbacks.erase(ticket)
	_counter_readback_completions += 1
	_counter_readback_bytes += data.size()
	if data.size() != DRAW_COMMAND_STRIDE:
		_release_scratch(scratch)
		_last_error = "resident arena counter readback size is invalid"
		return {}
	var index_count := int(data.decode_u32(0))
	var failure_cell_count := int(data.decode_u32(8))
	var vertex_count := int(data.decode_u32(16))
	_last_failure_cell_count = failure_cell_count
	if failure_cell_count > 0:
		_failed_extractions += 1
		_failed_cell_count_total += failure_cell_count
		_release_scratch(scratch)
		_last_error = (
			"resident arena GPU extraction reported %d failed cells"
			% failure_cell_count
		)
		return {}
	var page_index := int(scratch.get("arena_page_index", -1))
	if page_index < 0 or page_index >= _pages.size():
		_release_scratch(scratch)
		_last_error = "resident arena scratch page disappeared"
		return {}
	var page: Dictionary = _pages[page_index]
	var strides: Array = page.get("strides", [])
	var maximum_vertex_count := int(strides[13]) / PACKED_POSITION_STRIDE
	var maximum_index_count := int(strides[17]) / 4
	if index_count > maximum_index_count or vertex_count > maximum_vertex_count \
			or (index_count == 0) != (vertex_count == 0):
		_release_scratch(scratch)
		_last_error = "resident arena GPU counters exceed their bounded output"
		return {}
	if index_count == 0:
		_release_scratch(scratch)
		_active_slot_count += 1
		_peak_active_slot_count = maxi(_peak_active_slot_count, _active_slot_count)
		_empty_resident_entries += 1
		_last_error = ""
		return {
			"resident_kind": "empty",
			"empty": true,
			"failure_cell_count": failure_cell_count,
			"vertex_count": 0,
			"index_count": 0,
			"cell_count": int(scratch.get("cell_count", 0)),
		}
	var entry := _create_compact_resident(
		page, int(scratch.get("arena_slot_index", -1)), vertex_count, index_count
	)
	_release_scratch(scratch)
	if entry.is_empty():
		return {}
	entry["cell_count"] = int(scratch.get("cell_count", 0))
	entry["vertex_count"] = vertex_count
	entry["index_count"] = index_count
	entry["empty"] = false
	entry["failure_cell_count"] = failure_cell_count
	_active_slot_count += 1
	_peak_active_slot_count = maxi(_peak_active_slot_count, _active_slot_count)
	_compacted_resident_entries += 1
	_last_error = ""
	return entry


func discard_readback(ticket: int) -> bool:
	if not _pending_readbacks.has(ticket):
		return false
	var scratch: Dictionary = _pending_readbacks[ticket]
	_pending_readbacks.erase(ticket)
	_release_scratch(scratch)
	return true


func release(entry: Dictionary) -> bool:
	var resident_kind := str(entry.get("resident_kind", ""))
	if resident_kind == "empty":
		_active_slot_count = maxi(0, _active_slot_count - 1)
		return true
	if resident_kind != "compact":
		return false
	_free_rids(Array(entry.get("resident_rids", [])))
	_resident_allocated_bytes = maxi(
		0,
		_resident_allocated_bytes - int(entry.get("resident_allocated_bytes", 0))
	)
	_active_slot_count = maxi(0, _active_slot_count - 1)
	return true


func close() -> void:
	_closed = true
	_pending_readbacks.clear()
	_readback_mutex.lock()
	_completed_readbacks.clear()
	_readback_mutex.unlock()
	if _rendering_device != null:
		for page in _pages:
			_free_page(page)
	_pages.clear()
	_allocated_slot_count = 0
	_scratch_in_flight_count = 0
	_active_slot_count = 0
	_scratch_allocated_bytes = 0
	_resident_allocated_bytes = 0


func get_status() -> Dictionary:
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_arena.v3",
		"architecture": "bounded_scratch_compact_residency",
		"position_encoding": "float32_world_space",
		"page_slot_capacity": PAGE_SLOT_COUNT,
		"maximum_slots": _maximum_slots,
		"allocated_slots": _allocated_slot_count,
		"scratch_in_flight": _scratch_in_flight_count,
		"peak_scratch_in_flight": _peak_scratch_in_flight_count,
		"active_slots": _active_slot_count,
		"peak_active_slots": _peak_active_slot_count,
		"page_count": _pages.size(),
		"page_allocations": _page_allocations,
		"page_replacements": _page_replacements,
		"slot_leases": _slot_leases,
		"slot_reuses": _slot_reuses,
		"slot_releases": _slot_releases,
		"binding_buffer_count_per_page": BINDING_COUNT,
		"resident_buffer_count_per_entry": 5,
		"compacted_surface_vertices": true,
		"compacted_surface_indices": true,
		"compacted_surface_indirect_commands": true,
		"indirect_commands_per_surface": 1,
		"allocated_bytes": _scratch_allocated_bytes + _resident_allocated_bytes,
		"scratch_allocated_bytes": _scratch_allocated_bytes,
		"resident_allocated_bytes": _resident_allocated_bytes,
		"peak_resident_allocated_bytes": _peak_resident_allocated_bytes,
		"uploaded_bytes": _uploaded_bytes,
		"dispatch_count": _dispatch_count,
		"counter_readback_requests": _counter_readback_requests,
		"counter_readback_completions": _counter_readback_completions,
		"counter_readback_bytes": _counter_readback_bytes,
		"geometry_readback_bytes": 0,
		"compacted_resident_entries": _compacted_resident_entries,
		"empty_resident_entries": _empty_resident_entries,
		"proven_empty_resident_entries": _proven_empty_resident_entries,
		"failed_extractions": _failed_extractions,
		"failed_cell_count_total": _failed_cell_count_total,
		"last_failure_cell_count": _last_failure_cell_count,
		"last_error": _last_error,
	}


func get_last_error() -> String:
	return _last_error


func _on_counter_readback(data: PackedByteArray, ticket: int) -> void:
	if _closed:
		return
	_readback_mutex.lock()
	_completed_readbacks.append({"ticket": ticket, "data": data})
	_readback_mutex.unlock()


func _create_compact_resident(
	page: Dictionary, slot_index: int, vertex_count: int, index_count: int
) -> Dictionary:
	var buffers: Array = page.get("buffers", [])
	var strides: Array = page.get("strides", [])
	if slot_index < 0 or buffers.size() != BINDING_COUNT \
			or strides.size() != BINDING_COUNT:
		_last_error = "resident arena compact source is invalid"
		return {}
	var position_bytes := vertex_count * PACKED_POSITION_STRIDE
	var normal_bytes := vertex_count * PACKED_NORMAL_STRIDE
	var meta_bytes := vertex_count * PACKED_META_STRIDE
	var index_bytes := index_count * 4
	var position_buffer := _rendering_device.vertex_buffer_create(
		position_bytes, PackedByteArray(), RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	)
	var normal_buffer := _rendering_device.vertex_buffer_create(
		normal_bytes, PackedByteArray(), RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	)
	var meta_buffer := _rendering_device.vertex_buffer_create(
		meta_bytes, PackedByteArray(), RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	)
	var index_buffer := _rendering_device.index_buffer_create(
		index_count, RenderingDevice.INDEX_BUFFER_FORMAT_UINT32
	)
	var draw_command := PackedInt32Array([index_count, 1, 0, 0, 0]).to_byte_array()
	var indirect_buffer := _rendering_device.storage_buffer_create(
		DRAW_COMMAND_STRIDE,
		draw_command,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
	)
	var resource_rids: Array = [
		position_buffer, normal_buffer, meta_buffer, index_buffer, indirect_buffer,
	]
	for rid in resource_rids:
		if not rid is RID or not rid.is_valid():
			_free_rids(resource_rids)
			_last_error = "resident arena exact buffer allocation failed"
			return {}
	var copies := [
		[13, position_buffer, position_bytes],
		[14, normal_buffer, normal_bytes],
		[15, meta_buffer, meta_bytes],
		[17, index_buffer, index_bytes],
	]
	for copy in copies:
		var binding := int(copy[0])
		var copy_error := _rendering_device.buffer_copy(
			buffers[binding], copy[1],
			slot_index * int(strides[binding]), 0, int(copy[2])
		)
		if copy_error != OK:
			_free_rids(resource_rids)
			_last_error = "resident arena exact buffer copy failed: %s" % [
				error_string(copy_error),
			]
			return {}
	var vertex_array := _rendering_device.vertex_array_create(
		vertex_count, _vertex_format, [position_buffer, normal_buffer, meta_buffer]
	)
	var index_array := _rendering_device.index_array_create(
		index_buffer, 0, index_count
	)
	if not vertex_array.is_valid() or not index_array.is_valid():
		_free_rids([vertex_array, index_array])
		_free_rids(resource_rids)
		_last_error = "resident arena exact vertex or index view creation failed"
		return {}
	var allocated_bytes := position_bytes + normal_bytes + meta_bytes \
		+ index_bytes + DRAW_COMMAND_STRIDE
	_resident_allocated_bytes += allocated_bytes
	_peak_resident_allocated_bytes = maxi(
		_peak_resident_allocated_bytes, _resident_allocated_bytes
	)
	return {
		"resident_kind": "compact",
		"vertex_array": vertex_array,
		"index_array": index_array,
		"position_buffer": position_buffer,
		"index_buffer": index_buffer,
		"indirect_buffer": indirect_buffer,
		"indirect_offset": 0,
		"indirect_draw_count": 1,
		"resident_rids": [
			vertex_array, index_array,
			position_buffer, normal_buffer, meta_buffer,
			index_buffer, indirect_buffer,
		],
		"resident_allocated_bytes": allocated_bytes,
	}


func debug_ray_intersection(
	entry: Dictionary,
	origin: Vector3,
	direction: Vector3,
	maximum_distance: float,
	include_geometry: bool = false
) -> Dictionary:
	var vertex_count := int(entry.get("vertex_count", 0))
	var index_count := int(entry.get("index_count", 0))
	var position_buffer: RID = entry.get("position_buffer", RID())
	var index_buffer: RID = entry.get("index_buffer", RID())
	var indirect_buffer: RID = entry.get("indirect_buffer", RID())
	var indirect_offset := int(entry.get("indirect_offset", 0))
	if _rendering_device == null or vertex_count <= 0 or index_count <= 0 \
			or not position_buffer.is_valid() or not index_buffer.is_valid() \
			or not indirect_buffer.is_valid():
		return {"valid": false, "error": "resident geometry is unavailable"}
	var unit_direction := direction.normalized()
	if not origin.is_finite() or not unit_direction.is_finite() \
			or unit_direction.is_zero_approx() or maximum_distance <= 0.0:
		return {"valid": false, "error": "debug ray is invalid"}
	var position_bytes := _rendering_device.buffer_get_data(position_buffer)
	var index_bytes := _rendering_device.buffer_get_data(index_buffer)
	var indirect_bytes := _rendering_device.buffer_get_data(
		indirect_buffer, indirect_offset, DRAW_COMMAND_STRIDE
	)
	if position_bytes.size() != vertex_count * PACKED_POSITION_STRIDE \
			or index_bytes.size() != index_count * 4 \
			or indirect_bytes.size() != DRAW_COMMAND_STRIDE:
		return {
			"valid": false,
			"error": "resident geometry readback size is invalid",
			"position_bytes": position_bytes.size(),
			"index_bytes": index_bytes.size(),
			"indirect_bytes": indirect_bytes.size(),
		}
	var draw_index_count := int(indirect_bytes.decode_u32(0))
	var draw_instance_count := int(indirect_bytes.decode_u32(4))
	var draw_first_index := int(indirect_bytes.decode_u32(8))
	var draw_vertex_offset := int(indirect_bytes.decode_s32(12))
	var draw_first_instance := int(indirect_bytes.decode_u32(16))
	var nearest_distance := INF
	var nearest_triangle := -1
	var nearest_indices: Array[int] = []
	var nearest_vertices: Array[Vector3] = []
	var nearest_normal := Vector3.ZERO
	var invalid_indices := 0
	var degenerate_triangles := 0
	for triangle in range(0, index_count, 3):
		var index_a := int(index_bytes.decode_u32(triangle * 4))
		var index_b := int(index_bytes.decode_u32((triangle + 1) * 4))
		var index_c := int(index_bytes.decode_u32((triangle + 2) * 4))
		if index_a >= vertex_count or index_b >= vertex_count or index_c >= vertex_count:
			invalid_indices += 1
			continue
		var a := _decode_position(position_bytes, index_a)
		var b := _decode_position(position_bytes, index_b)
		var c := _decode_position(position_bytes, index_c)
		var distance := _ray_triangle_distance(origin, unit_direction, a, b, c)
		if distance == -2.0:
			degenerate_triangles += 1
		elif distance >= 0.0 and distance <= maximum_distance and distance < nearest_distance:
			nearest_distance = distance
			nearest_triangle = int(triangle / 3)
			nearest_indices = [index_a, index_b, index_c]
			nearest_vertices = [a, b, c]
			nearest_normal = (b - a).cross(c - a).normalized()
	var result := {
		"valid": true,
		"hit": nearest_triangle >= 0,
		"distance": nearest_distance if nearest_triangle >= 0 else -1.0,
		"triangle": nearest_triangle,
		"triangle_indices": nearest_indices,
		"triangle_vertices": nearest_vertices,
		"triangle_normal": nearest_normal,
		"triangle_normal_dot_ray": nearest_normal.dot(unit_direction) \
			if nearest_triangle >= 0 else 0.0,
		"indirect_command": {
			"index_count": draw_index_count,
			"instance_count": draw_instance_count,
			"first_index": draw_first_index,
			"vertex_offset": draw_vertex_offset,
			"first_instance": draw_first_instance,
		},
		"indirect_matches_entry": draw_index_count == index_count,
		"indirect_covers_hit_triangle": nearest_triangle < 0 or (
			draw_first_index <= nearest_triangle * 3 \
			and draw_first_index + draw_index_count >= (nearest_triangle + 1) * 3
		),
		"tested_triangles": int(index_count / 3),
		"invalid_indices": invalid_indices,
		"degenerate_triangles": degenerate_triangles,
		"geometry_readback_bytes": (
			position_bytes.size() + index_bytes.size() + indirect_bytes.size()
		),
	}
	if include_geometry:
		var positions := []
		for index in range(vertex_count):
			var position := _decode_position(position_bytes, index)
			positions.append([position.x, position.y, position.z])
		result["vertex_positions"] = positions
		result["indices"] = Array(index_bytes.to_int32_array())
	return result


static func _decode_position(bytes: PackedByteArray, index: int) -> Vector3:
	var offset := index * PACKED_POSITION_STRIDE
	return Vector3(
		bytes.decode_float(offset),
		bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8)
	)


static func _ray_triangle_distance(
	origin: Vector3, direction: Vector3, a: Vector3, b: Vector3, c: Vector3
) -> float:
	var edge_ab := b - a
	var edge_ac := c - a
	var normal := edge_ab.cross(edge_ac)
	if normal.length_squared() <= 1.0e-12:
		return -2.0
	var p := direction.cross(edge_ac)
	var determinant := edge_ab.dot(p)
	if absf(determinant) <= 1.0e-8:
		return -1.0
	var inverse := 1.0 / determinant
	var translated := origin - a
	var u := translated.dot(p) * inverse
	if u < 0.0 or u > 1.0:
		return -1.0
	var q := translated.cross(edge_ab)
	var v := direction.dot(q) * inverse
	if v < 0.0 or u + v > 1.0:
		return -1.0
	var distance := edge_ac.dot(q) * inverse
	return distance if distance >= 0.0 else -1.0


func _release_scratch(scratch: Dictionary) -> void:
	_release_scratch_slot(
		int(scratch.get("arena_page_index", -1)),
		int(scratch.get("arena_slot_index", -1)),
		int(scratch.get("arena_generation", -1))
	)


func _release_scratch_slot(
	page_index: int, slot_index: int, generation: int
) -> bool:
	if page_index < 0 or page_index >= _pages.size():
		return false
	var page: Dictionary = _pages[page_index]
	if generation != int(page.get("generation", 0)):
		return false
	var slots: Array = page.get("slots", [])
	if slot_index < 0 or slot_index >= slots.size():
		return false
	var slot: Dictionary = slots[slot_index]
	if not bool(slot.get("in_use", false)):
		return false
	slot["in_use"] = false
	slots[slot_index] = slot
	var free_slots: Array = page.get("free_slots", [])
	free_slots.append(slot_index)
	page["slots"] = slots
	page["free_slots"] = free_slots
	_pages[page_index] = page
	_scratch_in_flight_count = maxi(0, _scratch_in_flight_count - 1)
	_slot_releases += 1
	return true


func _find_page(input_buffers: Array, cell_count: int) -> int:
	for page_index in range(_pages.size()):
		var page: Dictionary = _pages[page_index]
		if not Array(page.get("free_slots", [])).is_empty() \
				and _request_fits(page, input_buffers, cell_count):
			return page_index
	return -1


func _request_fits(
	page: Dictionary, input_buffers: Array, cell_count: int
) -> bool:
	if cell_count > int(page.get("cell_capacity", 0)):
		return false
	var strides: Array = page.get("strides", [])
	for binding in range(INPUT_BINDING_COUNT):
		var size := PackedByteArray(input_buffers[binding]).size()
		if binding >= TABLE_BINDING_BEGIN:
			if size != int(strides[binding]):
				return false
		elif size > int(strides[binding]):
			return false
	return true


func _create_page(input_buffers: Array, cell_count: int) -> int:
	var remaining := _maximum_slots - _allocated_slot_count
	var replacement_index := -1
	var slot_count := mini(PAGE_SLOT_COUNT, remaining)
	if remaining <= 0:
		replacement_index = _free_page_replacement_candidate()
		if replacement_index < 0:
			_last_error = "resident arena scratch capacity is busy"
			return -1
		slot_count = int(_pages[replacement_index].get("slot_count", 0))
		if slot_count <= 0:
			_last_error = "resident arena replacement page is invalid"
			return -1
	var output_sizes := _output_buffer_sizes(cell_count)
	var strides: Array[int] = []
	strides.resize(BINDING_COUNT)
	for binding in range(INPUT_BINDING_COUNT):
		strides[binding] = PackedByteArray(input_buffers[binding]).size()
	for binding in range(INPUT_BINDING_COUNT, BINDING_COUNT):
		strides[binding] = output_sizes[binding - INPUT_BINDING_COUNT]
	strides[20] = _round_up(strides[20], DRAW_COMMAND_STRIDE)
	var buffers: Array[RID] = []
	var page_bytes := 0
	for binding in range(BINDING_COUNT):
		var shared_buffer := binding >= TABLE_BINDING_BEGIN \
				and binding < TABLE_BINDING_END
		var size := strides[binding] if shared_buffer \
			else strides[binding] * slot_count
		var data := PackedByteArray(input_buffers[binding]) if shared_buffer \
			else PackedByteArray()
		var buffer := _create_buffer(binding, size, data)
		if not buffer.is_valid():
			_free_rids(buffers)
			_last_error = "resident arena scratch buffer creation failed at binding %d" % binding
			return -1
		buffers.append(buffer)
		page_bytes += size
	var uniforms: Array[RDUniform] = []
	for binding in range(BINDING_COUNT):
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(buffers[binding])
		uniforms.append(uniform)
	var uniform_set := _rendering_device.uniform_set_create(
		uniforms, _compute_shader, 0
	)
	if not uniform_set.is_valid():
		_free_rids(buffers)
		_last_error = "resident arena scratch uniform set creation failed"
		return -1
	var slots: Array[Dictionary] = []
	var free_slots: Array[int] = []
	var lease_counts: Array[int] = []
	for slot_index in range(slot_count):
		slots.append({"in_use": false})
		free_slots.append(slot_index)
		lease_counts.append(0)
	var page := {
		"generation": _page_allocations + 1,
		"cell_capacity": cell_count,
		"slot_count": slot_count,
		"strides": strides,
		"buffers": buffers,
		"uniform_set": uniform_set,
		"slots": slots,
		"free_slots": free_slots,
		"lease_counts": lease_counts,
		"allocated_bytes": page_bytes,
	}
	if replacement_index >= 0:
		var replaced_page: Dictionary = _pages[replacement_index]
		_free_page(replaced_page)
		_scratch_allocated_bytes = maxi(
			0,
			_scratch_allocated_bytes - int(replaced_page.get("allocated_bytes", 0))
		)
		_pages[replacement_index] = page
		_page_replacements += 1
	else:
		_pages.append(page)
		_allocated_slot_count += slot_count
	_scratch_allocated_bytes += page_bytes
	_page_allocations += 1
	return replacement_index if replacement_index >= 0 else _pages.size() - 1


func _free_page_replacement_candidate() -> int:
	var selected := -1
	var selected_bytes := 0
	for page_index in range(_pages.size()):
		var page: Dictionary = _pages[page_index]
		var free_slots: Array = page.get("free_slots", [])
		if free_slots.size() != int(page.get("slot_count", 0)):
			continue
		var allocated_bytes := int(page.get("allocated_bytes", 0))
		if selected < 0 or allocated_bytes < selected_bytes:
			selected = page_index
			selected_bytes = allocated_bytes
	return selected


func _free_page(page: Dictionary) -> void:
	var uniform_set: RID = page.get("uniform_set", RID())
	if uniform_set.is_valid():
		_rendering_device.free_rid(uniform_set)
	_free_rids(Array(page.get("buffers", [])))


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


func _push_constant_bytes(
	strides: Array,
	slot_index: int,
	bounds_min: Vector3,
	bounds_max: Vector3
) -> PackedByteArray:
	var values := PackedInt32Array([
		int(slot_index * int(strides[0]) / 4),
		int(slot_index * int(strides[1]) / 4),
		int(slot_index * int(strides[2]) / 16),
		int(slot_index * int(strides[3]) / 16),
		int(slot_index * int(strides[4]) / 16),
		int(slot_index * int(strides[5]) / 4),
		int(slot_index * int(strides[6]) / 16),
		0,
		int(slot_index * int(strides[13]) / 16),
		int(slot_index * int(strides[17]) / 4),
		int(slot_index * int(strides[18]) / 16),
		int(slot_index * int(strides[19]) / 16),
		int(slot_index * int(strides[20]) / DRAW_COMMAND_STRIDE),
		1,
		0,
		0,
		int(slot_index * int(strides[13]) / 4),
		int(slot_index * int(strides[14]) / 4),
		int(slot_index * int(strides[15]) / 4),
		int(slot_index * int(strides[17]) / 4),
	])
	var bytes := values.to_byte_array()
	bytes.resize(112)
	var extent := bounds_max - bounds_min
	for component in range(3):
		bytes.encode_float(80 + component * 4, bounds_min[component])
		bytes.encode_float(96 + component * 4, extent[component])
	return bytes


func _validate_request(input_buffers: Array, cell_count: int) -> String:
	if _closed or _rendering_device == null or not _compute_shader.is_valid() \
			or not _compute_pipeline.is_valid() or _vertex_format < 0:
		return "resident arena is not initialized"
	if input_buffers.size() != INPUT_BINDING_COUNT or cell_count <= 0:
		return "resident arena request inventory is invalid"
	for binding in range(INPUT_BINDING_COUNT):
		if not input_buffers[binding] is PackedByteArray \
				or PackedByteArray(input_buffers[binding]).is_empty():
			return "resident arena input buffer %d is empty" % binding
	return ""


func _free_rids(rids: Array) -> void:
	if _rendering_device == null:
		return
	for rid in rids:
		if rid is RID and rid.is_valid():
			_rendering_device.free_rid(rid)


static func _output_buffer_sizes(cell_count: int) -> Array[int]:
	return [
		cell_count * MAXIMUM_VERTICES_PER_CELL * PACKED_POSITION_STRIDE,
		cell_count * MAXIMUM_VERTICES_PER_CELL * PACKED_NORMAL_STRIDE,
		cell_count * MAXIMUM_VERTICES_PER_CELL * PACKED_META_STRIDE,
		16,
		cell_count * MAXIMUM_INDICES_PER_CELL * 4,
		16,
		48,
		DRAW_COMMAND_STRIDE,
	]


static func _round_up(value: int, alignment: int) -> int:
	return int((value + alignment - 1) / alignment) * alignment
