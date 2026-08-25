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

var _rendering_device: RenderingDevice
var _compute_shader := RID()
var _compute_pipeline := RID()
var _vertex_format := -1
var _maximum_slots := 0
var _pages: Array[Dictionary] = []
var _allocated_slot_count := 0
var _active_slot_count := 0
var _peak_active_slot_count := 0
var _allocated_bytes := 0
var _page_allocations := 0
var _slot_leases := 0
var _slot_reuses := 0
var _slot_releases := 0
var _uploaded_bytes := 0
var _dispatch_count := 0
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
	_last_error = ""
	return true


func lease_and_dispatch(input_buffers: Array, cell_count: int) -> Dictionary:
	var validation_error := _validate_request(input_buffers, cell_count)
	if not validation_error.is_empty():
		_last_error = validation_error
		return {}
	var page_index := _find_page(input_buffers, cell_count)
	if page_index < 0:
		page_index = _create_page(input_buffers, cell_count)
	if page_index < 0:
		return {}
	var page: Dictionary = _pages[page_index]
	var free_slots: Array = page.get("free_slots", [])
	if free_slots.is_empty():
		_last_error = "resident arena page has no free slot"
		return {}
	var slot_index := int(free_slots.pop_front())
	page["free_slots"] = free_slots
	var lease_counts: Array = page.get("lease_counts", [])
	if int(lease_counts[slot_index]) > 0:
		_slot_reuses += 1
	lease_counts[slot_index] = int(lease_counts[slot_index]) + 1
	page["lease_counts"] = lease_counts
	var strides: Array = page.get("strides", [])
	var buffers: Array = page.get("buffers", [])
	for binding in range(TABLE_BINDING_BEGIN):
		var bytes: PackedByteArray = input_buffers[binding]
		var offset := slot_index * int(strides[binding])
		var update_error := _rendering_device.buffer_update(
			buffers[binding], offset, bytes.size(), bytes
		)
		if update_error != OK:
			free_slots.append(slot_index)
			page["free_slots"] = free_slots
			_pages[page_index] = page
			_last_error = "resident arena input upload failed at binding %d: %s" % [
				binding, error_string(update_error),
			]
			return {}
		_uploaded_bytes += bytes.size()
	var push_bytes := _push_constant_bytes(strides, slot_index)
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(
		compute_list, _compute_pipeline
	)
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
	var index_offset := slot_index * int(strides[17])
	var copy_error := _rendering_device.buffer_copy(
		buffers[17],
		page.get("raster_index_buffer", RID()),
		index_offset,
		index_offset,
		cell_count * MAXIMUM_INDICES_PER_CELL * 4
	)
	if copy_error != OK:
		_last_error = "resident arena index copy failed: %s" % error_string(copy_error)
		_pages[page_index] = page
		return {}
	var slots: Array = page.get("slots", [])
	var slot: Dictionary = slots[slot_index]
	slot["in_use"] = true
	slots[slot_index] = slot
	page["slots"] = slots
	_pages[page_index] = page
	_slot_leases += 1
	_active_slot_count += 1
	_peak_active_slot_count = maxi(_peak_active_slot_count, _active_slot_count)
	_last_error = ""
	return {
		"arena_page_index": page_index,
		"arena_slot_index": slot_index,
		"arena_generation": int(page.get("generation", 0)),
		"vertex_array": slot.get("vertex_array", RID()),
		"index_array": slot.get("index_array", RID()),
		"indirect_buffer": buffers[20],
		"indirect_offset": slot_index * int(strides[20]),
		"cell_count": cell_count,
	}


func release(entry: Dictionary) -> bool:
	var page_index := int(entry.get("arena_page_index", -1))
	var slot_index := int(entry.get("arena_slot_index", -1))
	if page_index < 0 or page_index >= _pages.size():
		return false
	var page: Dictionary = _pages[page_index]
	if int(entry.get("arena_generation", -1)) != int(page.get("generation", 0)):
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
	_active_slot_count = maxi(0, _active_slot_count - 1)
	_slot_releases += 1
	return true


func close() -> void:
	if _rendering_device != null:
		for page in _pages:
			_free_page(page)
	_pages.clear()
	_allocated_slot_count = 0
	_active_slot_count = 0


func get_status() -> Dictionary:
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_arena.v1",
		"architecture": "paged_shared_arena",
		"page_slot_capacity": PAGE_SLOT_COUNT,
		"maximum_slots": _maximum_slots,
		"allocated_slots": _allocated_slot_count,
		"active_slots": _active_slot_count,
		"peak_active_slots": _peak_active_slot_count,
		"page_count": _pages.size(),
		"page_allocations": _page_allocations,
		"slot_leases": _slot_leases,
		"slot_reuses": _slot_reuses,
		"slot_releases": _slot_releases,
		"binding_buffer_count_per_page": BINDING_COUNT,
		"resident_buffer_count_per_entry": 0,
		"allocated_bytes": _allocated_bytes,
		"uploaded_bytes": _uploaded_bytes,
		"dispatch_count": _dispatch_count,
		"last_error": _last_error,
	}


func get_last_error() -> String:
	return _last_error


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
	if remaining <= 0:
		_last_error = "resident arena slot capacity reached"
		return -1
	var slot_count := mini(PAGE_SLOT_COUNT, remaining)
	var cell_capacity := cell_count
	var output_sizes := _output_buffer_sizes(cell_capacity)
	var strides: Array[int] = []
	strides.resize(BINDING_COUNT)
	for binding in range(INPUT_BINDING_COUNT):
		var required := PackedByteArray(input_buffers[binding]).size()
		strides[binding] = required
	for binding in range(INPUT_BINDING_COUNT, BINDING_COUNT):
		strides[binding] = output_sizes[binding - INPUT_BINDING_COUNT]
	strides[20] = _round_up(strides[20], DRAW_COMMAND_STRIDE)
	var buffers: Array[RID] = []
	for binding in range(BINDING_COUNT):
		var shared_table := binding >= TABLE_BINDING_BEGIN \
				and binding < TABLE_BINDING_END
		var size := strides[binding] if shared_table else strides[binding] * slot_count
		var data := PackedByteArray(input_buffers[binding]) if shared_table \
			else PackedByteArray()
		var buffer := _create_buffer(binding, size, data)
		if not buffer.is_valid():
			_free_rids(buffers)
			_last_error = "resident arena buffer creation failed at binding %d" % binding
			return -1
		buffers.append(buffer)
		_allocated_bytes += size
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
		_last_error = "resident arena uniform set creation failed"
		return -1
	var raster_index_bytes := strides[17] * slot_count
	var raster_index_buffer := _rendering_device.index_buffer_create(
		int(raster_index_bytes / 4), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32
	)
	if not raster_index_buffer.is_valid():
		_rendering_device.free_rid(uniform_set)
		_free_rids(buffers)
		_last_error = "resident arena raster index buffer creation failed"
		return -1
	_allocated_bytes += raster_index_bytes
	var slots: Array[Dictionary] = []
	var free_slots: Array[int] = []
	var lease_counts: Array[int] = []
	for slot_index in range(slot_count):
		var vertex_buffers: Array[RID] = [buffers[13], buffers[14], buffers[15]]
		var vertex_offsets := PackedInt64Array([
			slot_index * strides[13],
			slot_index * strides[14],
			slot_index * strides[15],
		])
		var vertex_array := _rendering_device.vertex_array_create(
			cell_capacity * MAXIMUM_VERTICES_PER_CELL,
			_vertex_format,
			vertex_buffers,
			vertex_offsets
		)
		var index_array := _rendering_device.index_array_create(
			raster_index_buffer,
			int(slot_index * strides[17] / 4),
			cell_capacity * MAXIMUM_INDICES_PER_CELL
		)
		if not vertex_array.is_valid() or not index_array.is_valid():
			_free_rids([vertex_array, index_array])
			for existing_slot in slots:
				_free_rids([
					existing_slot.get("vertex_array", RID()),
					existing_slot.get("index_array", RID()),
				])
			_rendering_device.free_rid(raster_index_buffer)
			_rendering_device.free_rid(uniform_set)
			_free_rids(buffers)
			_last_error = "resident arena vertex or index view creation failed"
			return -1
		slots.append({
			"vertex_array": vertex_array,
			"index_array": index_array,
			"in_use": false,
		})
		free_slots.append(slot_index)
		lease_counts.append(0)
	var page := {
		"generation": _page_allocations + 1,
		"cell_capacity": cell_capacity,
		"slot_count": slot_count,
		"strides": strides,
		"buffers": buffers,
		"uniform_set": uniform_set,
		"raster_index_buffer": raster_index_buffer,
		"slots": slots,
		"free_slots": free_slots,
		"lease_counts": lease_counts,
	}
	_pages.append(page)
	_allocated_slot_count += slot_count
	_page_allocations += 1
	return _pages.size() - 1


func _free_page(page: Dictionary) -> void:
	for slot in Array(page.get("slots", [])):
		_free_rids([
			Dictionary(slot).get("vertex_array", RID()),
			Dictionary(slot).get("index_array", RID()),
		])
	var uniform_set: RID = page.get("uniform_set", RID())
	if uniform_set.is_valid():
		_rendering_device.free_rid(uniform_set)
	var raster_index_buffer: RID = page.get("raster_index_buffer", RID())
	if raster_index_buffer.is_valid():
		_rendering_device.free_rid(raster_index_buffer)
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


func _push_constant_bytes(strides: Array, slot_index: int) -> PackedByteArray:
	var values := PackedInt32Array([
		int(slot_index * int(strides[0]) / 16),
		int(slot_index * int(strides[1]) / 16),
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
		0,
		0,
		0,
	])
	return values.to_byte_array()


func _validate_request(input_buffers: Array, cell_count: int) -> String:
	if _rendering_device == null or not _compute_shader.is_valid() \
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
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_VERTICES_PER_CELL * 16,
		cell_count * MAXIMUM_INDICES_PER_CELL * 4,
		cell_count * 16,
		48,
		cell_count * DRAW_COMMAND_STRIDE,
	]


static func _round_up(value: int, alignment: int) -> int:
	return int((value + alignment - 1) / alignment) * alignment
