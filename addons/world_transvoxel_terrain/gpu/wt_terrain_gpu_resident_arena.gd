@tool
extends RefCounted
class_name WtTerrainGpuResidentArena

const BINDING_COUNT := 21
const INPUT_BINDING_COUNT := 13
const TABLE_BINDING_BEGIN := 7
const TABLE_BINDING_END := 13
const PAGE_SLOT_COUNT := 4
const INTERACTION_SCRATCH_RESERVE_PER_PAGE := 1
const LOCAL_SIZE := 64
const MAXIMUM_VERTICES_PER_CELL := 12
const MAXIMUM_INDICES_PER_CELL := 36
const DRAW_COMMAND_STRIDE := 20
const STATUS_STRIDE := 16
const MAXIMUM_MESHLETS_PER_SLOT := 32
const STATUS_SLOT_STRIDE := STATUS_STRIDE * MAXIMUM_MESHLETS_PER_SLOT
const SUMMARY_STRIDE := 20
const COMPLETION_STRIDE := 16
const COMPLETION_MARKER := 0x57544350
const PACKED_POSITION_STRIDE := 12
const PACKED_NORMAL_STRIDE := 4
const PACKED_META_STRIDE := 4

var _rendering_device: RenderingDevice
var _compute_shader := RID()
var _compute_pipeline := RID()
var _commit_shader := RID()
var _commit_pipeline := RID()
var _completion_shader := RID()
var _completion_pipeline := RID()
var _compact_shader := RID()
var _compact_pipeline := RID()
var _status_buffer := RID()
var _summary_buffer := RID()
var _activation_buffer := RID()
var _commit_descriptor_buffer := RID()
var _commit_uniform_set := RID()
var _completion_buffer := RID()
var _completion_uniform_set := RID()
var _vertex_format := -1
var _maximum_slots := 0
var _maximum_scratch_slots := 0
var _next_compact_slot := 0
var _free_compact_slots: Array[int] = []
var _compact_slot_count := 0
var _pages: Array[Dictionary] = []
var _pending_readbacks: Dictionary = {}
var _completed_readbacks: Array[Dictionary] = []
var _pending_dispatch_completions: Dictionary = {}
var _completed_dispatch_completions: Array[Dictionary] = []
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
var _incremental_dispatch_count := 0
var _incremental_copy_fallback_count := 0
var _incremental_meshlet_copy_bytes := 0
var _last_incremental_meshlet_copy_bytes := 0
var _regenerated_cell_count := 0
var _last_regenerated_cell_count := 0
var _last_dispatch_uploaded_bytes := 0
var _counter_readback_requests := 0
var _counter_readback_completions := 0
var _counter_readback_bytes := 0
var _dispatch_completion_requests := 0
var _dispatch_completion_completions := 0
var _dispatch_completion_bytes := 0
var _compacted_resident_entries := 0
var _empty_resident_entries := 0
var _proven_empty_resident_entries := 0
var _failed_extractions := 0
var _background_scratch_reservation_deferrals := 0
var _failed_cell_count_total := 0
var _last_failure_cell_count := 0
var _last_error := ""


func initialize(
	rendering_device: RenderingDevice,
	compute_shader: RID,
	compute_pipeline: RID,
	commit_shader: RID,
	commit_pipeline: RID,
	completion_shader: RID,
	completion_pipeline: RID,
	compact_shader: RID,
	compact_pipeline: RID,
	vertex_format: int,
	maximum_slots: int,
	maximum_scratch_slots: int
) -> bool:
	if rendering_device == null or not compute_shader.is_valid() \
			or not compute_pipeline.is_valid() or not commit_shader.is_valid() \
			or not commit_pipeline.is_valid() or not completion_shader.is_valid() \
			or not completion_pipeline.is_valid() or not compact_shader.is_valid() \
			or not compact_pipeline.is_valid() or vertex_format < 0 \
			or maximum_slots <= 0 or maximum_scratch_slots <= 0 \
			or maximum_scratch_slots > maximum_slots:
		_last_error = "resident arena initialization parameters are invalid"
		return false
	_rendering_device = rendering_device
	_compute_shader = compute_shader
	_compute_pipeline = compute_pipeline
	_commit_shader = commit_shader
	_commit_pipeline = commit_pipeline
	_completion_shader = completion_shader
	_completion_pipeline = completion_pipeline
	_compact_shader = compact_shader
	_compact_pipeline = compact_pipeline
	_vertex_format = vertex_format
	_maximum_slots = maximum_slots
	_maximum_scratch_slots = maximum_scratch_slots
	_status_buffer = _rendering_device.storage_buffer_create(
		maximum_slots * 2 * STATUS_SLOT_STRIDE, PackedByteArray()
	)
	_summary_buffer = _rendering_device.storage_buffer_create(
		maximum_slots * 2 * SUMMARY_STRIDE, PackedByteArray()
	)
	_activation_buffer = _rendering_device.storage_buffer_create(
		maximum_slots * 2 * 4, PackedByteArray()
	)
	_completion_buffer = _rendering_device.storage_buffer_create(
		maximum_slots * COMPLETION_STRIDE, PackedByteArray()
	)
	# Header plus one candidate and one retirement slot per resident allocation.
	_commit_descriptor_buffer = _rendering_device.storage_buffer_create(
		(4 + maximum_slots * 2) * 4, PackedByteArray()
	)
	if not _status_buffer.is_valid() or not _summary_buffer.is_valid() \
			or not _activation_buffer.is_valid() or not _completion_buffer.is_valid() \
			or not _commit_descriptor_buffer.is_valid():
		_last_error = "resident arena GPU publication buffers could not be allocated"
		return false
	var commit_uniforms: Array[RDUniform] = []
	for item in [
		[0, _status_buffer], [1, _activation_buffer],
		[2, _commit_descriptor_buffer], [3, _summary_buffer],
	]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = int(item[0])
		uniform.add_id(item[1])
		commit_uniforms.append(uniform)
	_commit_uniform_set = _rendering_device.uniform_set_create(
		commit_uniforms, _commit_shader, 0
	)
	var completion_uniform := RDUniform.new()
	completion_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	completion_uniform.binding = 0
	completion_uniform.add_id(_completion_buffer)
	_completion_uniform_set = _rendering_device.uniform_set_create(
		[completion_uniform], _completion_shader, 0
	)
	if not _commit_uniform_set.is_valid() or not _completion_uniform_set.is_valid():
		_last_error = "resident arena GPU publication uniform set is invalid"
		return false
	_closed = false
	_next_compact_slot = 0
	_free_compact_slots.clear()
	_compact_slot_count = 0
	_last_error = ""
	return true


func lease_and_dispatch(
	input_buffers: Array,
	cell_count: int,
	bounds_min: Vector3,
	bounds_max: Vector3,
	previous_entry: Dictionary = {},
	dirty_regular_brick_mask: int = 0xff,
	cached_transition_mask: int = 0,
	dirty_bounds_min: Vector3i = Vector3i.ZERO,
	dirty_bounds_max: Vector3i = Vector3i.ZERO,
	interaction: bool = false
) -> Dictionary:
	var uploaded_before := _uploaded_bytes
	var validation_error := _validate_request(input_buffers, cell_count)
	if not validation_error.is_empty():
		_last_error = validation_error
		return {}
	if not bounds_min.is_finite() or not bounds_max.is_finite() \
			or bounds_min.x >= bounds_max.x or bounds_min.y >= bounds_max.y \
			or bounds_min.z >= bounds_max.z:
		_last_error = "resident arena bounds are invalid"
		return {}
	var previous_page_index := int(previous_entry.get("arena_page_index", -1))
	var page_index := _find_page(
		input_buffers, cell_count, previous_page_index, interaction
	)
	if page_index < 0:
		page_index = _create_page(input_buffers, cell_count)
	if page_index < 0:
		return {}
	var page: Dictionary = _pages[page_index]
	var free_slots: Array = page.get("free_slots", [])
	if free_slots.is_empty() or (not interaction and
			free_slots.size() <= INTERACTION_SCRATCH_RESERVE_PER_PAGE):
		if not interaction and not free_slots.is_empty():
			_background_scratch_reservation_deferrals += 1
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
	var global_slot := page_index * PAGE_SLOT_COUNT + slot_index
	var page_field_mode := PackedByteArray(input_buffers[6]).decode_s32(12) == 1
	var incremental := not previous_entry.is_empty() \
		and int(previous_entry.get("cell_count", -1)) == cell_count \
		and int(Dictionary(previous_entry.get("identity", {})).get(
			"cached_transition_mask", -1
		)) == cached_transition_mask \
		and dirty_regular_brick_mask != 0xff and page_field_mode \
		and dirty_bounds_min != dirty_bounds_max
	if incremental:
		incremental = _copy_previous_inputs(previous_entry, page, slot_index, input_buffers)
	if incremental:
		incremental = _patch_dirty_page_fields(
			page, slot_index, input_buffers, dirty_bounds_min, dirty_bounds_max
		)
	if not incremental:
		dirty_regular_brick_mask = 0xff
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
	if incremental and not _copy_previous_meshlets(
			previous_entry, page, slot_index, cell_count
	):
		_incremental_copy_fallback_count += 1
		_last_incremental_meshlet_copy_bytes = 0
		incremental = false
		dirty_regular_brick_mask = 0xff
	var initial_commands := PackedInt32Array()
	initial_commands.resize(MAXIMUM_MESHLETS_PER_SLOT * 5)
	for meshlet in range(MAXIMUM_MESHLETS_PER_SLOT):
		initial_commands[meshlet * 5 + 1] = 1
		initial_commands[meshlet * 5 + 2] = _meshlet_index_base(meshlet)
	var initial_command := initial_commands.to_byte_array()
	var command_error := _rendering_device.buffer_update(
		buffers[20], indirect_offset, initial_command.size(), initial_command
	)
	if incremental:
		# Restore clean commands after the full initialization; dirty commands are
		# cleared below together with their status records.
		_rendering_device.buffer_copy(
			previous_entry.get("indirect_buffer", RID()), buffers[20],
			int(previous_entry.get("indirect_offset", 0)), indirect_offset,
			int(strides[20])
		)
	if command_error != OK:
		_release_scratch_slot(page_index, slot_index, int(page.get("generation", 0)))
		_last_error = "resident arena counter initialization failed: %s" % [
			error_string(command_error),
		]
		return {}
	var status_zero := PackedByteArray()
	status_zero.resize(STATUS_SLOT_STRIDE)
	var status_error := OK
	if incremental:
		status_error = _initialize_incremental_status(
			global_slot, dirty_regular_brick_mask, cell_count > 4096
		)
	else:
		status_error = _rendering_device.buffer_update(
			_status_buffer, global_slot * STATUS_SLOT_STRIDE,
			STATUS_SLOT_STRIDE, status_zero
		)
	if status_error == OK and incremental:
		status_error = _clear_dirty_meshlet_state(
			buffers[20], indirect_offset, global_slot, dirty_regular_brick_mask,
			cell_count > 4096
		)
	var inactive := PackedInt32Array([0]).to_byte_array()
	var activation_error := _rendering_device.buffer_update(
		_activation_buffer, global_slot * 4, 4, inactive
	)
	if status_error != OK or activation_error != OK:
		_release_scratch_slot(page_index, slot_index, int(page.get("generation", 0)))
		_last_error = "resident arena GPU publication state initialization failed"
		return {}
	var push_bytes := _push_constant_bytes(
		strides, slot_index, global_slot, dirty_regular_brick_mask,
		bounds_min, bounds_max
	)
	var ticket := _next_ticket
	_next_ticket += 1
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
	_rendering_device.compute_list_add_barrier(compute_list)
	_rendering_device.compute_list_bind_compute_pipeline(
		compute_list, _completion_pipeline
	)
	_rendering_device.compute_list_bind_uniform_set(
		compute_list, _completion_uniform_set, 0
	)
	var completion_parameters := PackedInt32Array([
		global_slot, ticket, int(page.get("generation", 0)), COMPLETION_MARKER,
	]).to_byte_array()
	_rendering_device.compute_list_set_push_constant(
		compute_list, completion_parameters, completion_parameters.size()
	)
	_rendering_device.compute_list_dispatch(compute_list, 1, 1, 1)
	_rendering_device.compute_list_end()
	_dispatch_count += 1
	var regenerated_cells := cell_count
	if incremental:
		regenerated_cells = _set_bit_count(dirty_regular_brick_mask) * 512 \
			+ maxi(0, cell_count - 4096)
		_incremental_dispatch_count += 1
	_regenerated_cell_count += regenerated_cells
	_last_regenerated_cell_count = regenerated_cells
	_last_dispatch_uploaded_bytes = _uploaded_bytes - uploaded_before
	_pending_readbacks[ticket] = {
		"ticket": ticket,
		"arena_page_index": page_index,
		"arena_slot_index": slot_index,
		"arena_generation": int(page.get("generation", 0)),
		"cell_count": cell_count,
		"global_slot": global_slot,
		"readback_requested": false,
	}
	_slot_leases += 1
	_scratch_in_flight_count += 1
	_peak_scratch_in_flight_count = maxi(
		_peak_scratch_in_flight_count, _scratch_in_flight_count
	)
	_last_error = ""
	var entry := _create_provisional_resident(
		page, page_index, slot_index, global_slot, page_field_mode
	)
	if entry.is_empty():
		_pending_readbacks.erase(ticket)
		_release_scratch_slot(page_index, slot_index, int(page.get("generation", 0)))
		return {}
	entry["status"] = "GPU_PROVISIONAL_READY"
	var input_sizes: Array[int] = []
	for binding in range(TABLE_BINDING_BEGIN):
		input_sizes.append(PackedByteArray(input_buffers[binding]).size())
	entry["input_sizes"] = input_sizes
	entry["arena_ticket"] = ticket
	entry["cell_count"] = cell_count
	entry["vertex_count"] = 0
	entry["index_count"] = 0
	entry["failure_cell_count"] = 0
	entry["counts_pending"] = true
	entry["incremental_edit"] = incremental
	entry["dirty_regular_brick_mask"] = dirty_regular_brick_mask
	entry["regenerated_cell_count"] = regenerated_cells
	entry["uploaded_bytes"] = _last_dispatch_uploaded_bytes
	_active_slot_count += 1
	_peak_active_slot_count = maxi(_peak_active_slot_count, _active_slot_count)
	_pending_dispatch_completions[ticket] = {
		"ticket": ticket,
		"global_slot": global_slot,
		"arena_generation": int(page.get("generation", 0)),
	}
	var completion_error := _rendering_device.buffer_get_data_async(
		_completion_buffer,
		Callable(self, "_on_dispatch_completion").bind(ticket),
		global_slot * COMPLETION_STRIDE,
		COMPLETION_STRIDE
	)
	if completion_error != OK:
		_pending_dispatch_completions.erase(ticket)
		_pending_readbacks.erase(ticket)
		release(entry)
		_last_error = "resident arena dispatch completion readback failed: %s" % [
			error_string(completion_error),
		]
		return {}
	_dispatch_completion_requests += 1
	return entry


func pop_completed_readbacks(maximum_count: int = 0) -> Array[Dictionary]:
	_readback_mutex.lock()
	var completed: Array[Dictionary] = []
	var count := _completed_readbacks.size() if maximum_count <= 0 else mini(
		maximum_count, _completed_readbacks.size()
	)
	completed.assign(_completed_readbacks.slice(0, count))
	_completed_readbacks = _completed_readbacks.slice(count)
	_readback_mutex.unlock()
	return completed


func pop_completed_dispatches(maximum_count: int = 0) -> Array[Dictionary]:
	_readback_mutex.lock()
	var completed: Array[Dictionary] = []
	var count := _completed_dispatch_completions.size() if maximum_count <= 0 else mini(
		maximum_count, _completed_dispatch_completions.size()
	)
	completed.assign(_completed_dispatch_completions.slice(0, count))
	_completed_dispatch_completions = _completed_dispatch_completions.slice(count)
	_readback_mutex.unlock()
	var results: Array[Dictionary] = []
	for completion in completed:
		var ticket := int(completion.get("ticket", 0))
		if not _pending_dispatch_completions.has(ticket):
			continue
		var expected: Dictionary = _pending_dispatch_completions[ticket]
		_pending_dispatch_completions.erase(ticket)
		var data: PackedByteArray = completion.get("data", PackedByteArray())
		_dispatch_completion_completions += 1
		_dispatch_completion_bytes += data.size()
		var valid := data.size() == COMPLETION_STRIDE \
			and int(data.decode_u32(0)) == int(expected.get("global_slot", -1)) \
			and int(data.decode_u32(4)) == ticket \
			and int(data.decode_u32(8)) == int(expected.get("arena_generation", -1)) \
			and int(data.decode_u32(12)) == COMPLETION_MARKER
		results.append({
			"ticket": ticket,
			"valid": valid,
			"error": "" if valid else "GPU extraction completion token is stale",
		})
	return results


func discard_dispatch_completion(ticket: int) -> void:
	_pending_dispatch_completions.erase(ticket)


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


func activation_buffer() -> RID:
	return _activation_buffer


func commit_visibility(activations: Array, retirements: Array) -> bool:
	if _closed or not _commit_pipeline.is_valid() or not _commit_uniform_set.is_valid():
		_last_error = "resident arena GPU publication pipeline is unavailable"
		return false
	var candidate_slots: Array[int] = []
	var retirement_slots: Array[int] = []
	for entry_value in activations:
		var slot := int(Dictionary(entry_value).get("gpu_slot", -1))
		if slot >= 0:
			candidate_slots.append(slot)
	for entry_value in retirements:
		var slot := int(Dictionary(entry_value).get("gpu_slot", -1))
		if slot >= 0:
			retirement_slots.append(slot)
	if candidate_slots.size() > _maximum_slots or retirement_slots.size() > _maximum_slots:
		_last_error = "resident arena GPU publication cohort exceeds bounded capacity"
		return false
	var descriptor := PackedInt32Array()
	descriptor.resize(4 + candidate_slots.size() + retirement_slots.size())
	descriptor[0] = candidate_slots.size()
	descriptor[1] = retirement_slots.size()
	descriptor[2] = 1
	for index in range(candidate_slots.size()):
		descriptor[4 + index] = candidate_slots[index]
	for index in range(retirement_slots.size()):
		descriptor[4 + candidate_slots.size() + index] = retirement_slots[index]
	var bytes := descriptor.to_byte_array()
	var update_error := _rendering_device.buffer_update(
		_commit_descriptor_buffer, 0, bytes.size(), bytes
	)
	if update_error != OK:
		_last_error = "resident arena GPU publication descriptor upload failed"
		return false
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(compute_list, _commit_pipeline)
	_rendering_device.compute_list_bind_uniform_set(compute_list, _commit_uniform_set, 0)
	_rendering_device.compute_list_dispatch(compute_list, 1, 1, 1)
	_rendering_device.compute_list_end()
	# Publication is already queued. The small summary readback follows it and is
	# used only for telemetry, validation cleanup, and slot reclamation.
	for entry_value in activations:
		if not request_summary_readback(Dictionary(entry_value)):
			return false
	_last_error = ""
	return true


func request_summary_readback(entry: Dictionary) -> bool:
	var ticket := int(entry.get("arena_ticket", 0))
	if ticket <= 0 or not _pending_readbacks.has(ticket):
		return true
	var pending: Dictionary = _pending_readbacks[ticket]
	if bool(pending.get("readback_requested", false)):
		return true
	var slot := int(entry.get("gpu_slot", -1))
	if slot < 0:
		_last_error = "resident arena summary request has no GPU slot"
		return false
	# Run the same cohort validator without changing visibility. This produces the
	# immutable 20-byte summary needed to reclaim a prepared member before its
	# complete regional activation cohort is ready.
	var descriptor := PackedInt32Array([1, 0, 0, 0, slot]).to_byte_array()
	var update_error := _rendering_device.buffer_update(
		_commit_descriptor_buffer, 0, descriptor.size(), descriptor
	)
	if update_error != OK:
		_last_error = "resident arena validation descriptor upload failed"
		return false
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(compute_list, _commit_pipeline)
	_rendering_device.compute_list_bind_uniform_set(compute_list, _commit_uniform_set, 0)
	_rendering_device.compute_list_dispatch(compute_list, 1, 1, 1)
	_rendering_device.compute_list_end()
	var readback_error := _rendering_device.buffer_get_data_async(
		_summary_buffer,
		Callable(self, "_on_counter_readback").bind(ticket),
		slot * SUMMARY_STRIDE,
		SUMMARY_STRIDE
	)
	if readback_error != OK:
		_last_error = "resident arena asynchronous summary readback failed: %s" % [
			error_string(readback_error),
		]
		return false
	pending["readback_requested"] = true
	_pending_readbacks[ticket] = pending
	_counter_readback_requests += 1
	_last_error = ""
	return true


func finalize_readback(ticket: int, data: PackedByteArray) -> Dictionary:
	if not _pending_readbacks.has(ticket):
		_last_error = "resident arena counter readback ticket is unknown"
		return {}
	var scratch: Dictionary = _pending_readbacks[ticket]
	_pending_readbacks.erase(ticket)
	_counter_readback_completions += 1
	_counter_readback_bytes += data.size()
	if data.size() != SUMMARY_STRIDE:
		_last_error = "resident arena status readback size is invalid"
		return {}
	var index_count := int(data.decode_u32(0))
	var vertex_count := int(data.decode_u32(4))
	var failure_cell_count := int(data.decode_u32(8))
	var cohort_valid := int(data.decode_u32(12)) != 0
	var summary_slot := int(data.decode_u32(16))
	if summary_slot != int(scratch.get("global_slot", -1)):
		_last_error = "resident arena status summary slot is stale"
		return {}
	_last_failure_cell_count = failure_cell_count
	if failure_cell_count > 0 or not cohort_valid:
		_failed_extractions += 1
		_failed_cell_count_total += failure_cell_count
		_last_error = (
			"resident arena GPU cohort validation failed with %d failed cells"
			% failure_cell_count
		)
		return {}
	var page_index := int(scratch.get("arena_page_index", -1))
	if page_index < 0 or page_index >= _pages.size():
		_last_error = "resident arena scratch page disappeared"
		return {}
	var page: Dictionary = _pages[page_index]
	var strides: Array = page.get("strides", [])
	var maximum_vertex_count := int(strides[13]) / PACKED_POSITION_STRIDE
	var maximum_index_count := int(strides[17]) / 4
	if index_count > maximum_index_count or vertex_count > maximum_vertex_count \
			or (index_count == 0) != (vertex_count == 0):
		_last_error = "resident arena GPU counters exceed their bounded output"
		return {}
	if index_count == 0:
		_empty_resident_entries += 1
	_last_error = ""
	return {
		"valid": true,
		"empty": index_count == 0,
		"failure_cell_count": 0,
		"vertex_count": vertex_count,
		"index_count": index_count,
		"cell_count": int(scratch.get("cell_count", 0)),
		"global_slot": int(scratch.get("global_slot", -1)),
	}


func discard_readback(ticket: int, byte_count: int = 0) -> bool:
	if not _pending_readbacks.has(ticket):
		return false
	_pending_readbacks.erase(ticket)
	_counter_readback_completions += 1
	_counter_readback_bytes += byte_count
	return true


func release(entry: Dictionary) -> bool:
	var resident_kind := str(entry.get("resident_kind", ""))
	if resident_kind == "empty":
		_active_slot_count = maxi(0, _active_slot_count - 1)
		return true
	if resident_kind == "compact_meshlets":
		_free_rids(Array(entry.get("resident_rids", [])))
		_resident_allocated_bytes = maxi(
			0, _resident_allocated_bytes - int(entry.get("resident_allocated_bytes", 0))
		)
		_release_compact_slot(int(entry.get("gpu_slot", -1)))
		_compacted_resident_entries = maxi(0, _compacted_resident_entries - 1)
		_active_slot_count = maxi(0, _active_slot_count - 1)
		return true
	if resident_kind != "provisional":
		return false
	_free_rids(Array(entry.get("resident_view_rids", [])))
	_resident_allocated_bytes = maxi(
		0, _resident_allocated_bytes - int(entry.get("resident_allocated_bytes", 0))
	)
	_release_scratch_slot(
		int(entry.get("arena_page_index", -1)),
		int(entry.get("arena_slot_index", -1)),
		int(entry.get("arena_generation", -1))
	)
	_active_slot_count = maxi(0, _active_slot_count - 1)
	return true


func close() -> void:
	_closed = true
	_pending_readbacks.clear()
	_pending_dispatch_completions.clear()
	_readback_mutex.lock()
	_completed_readbacks.clear()
	_completed_dispatch_completions.clear()
	_readback_mutex.unlock()
	if _rendering_device != null:
		for page in _pages:
			_free_page(page)
		_free_rids([
			_commit_uniform_set, _commit_descriptor_buffer,
			_activation_buffer, _summary_buffer, _status_buffer,
			_completion_uniform_set, _completion_buffer,
		])
	_pages.clear()
	_allocated_slot_count = 0
	_scratch_in_flight_count = 0
	_active_slot_count = 0
	_scratch_allocated_bytes = 0
	_resident_allocated_bytes = 0
	_next_compact_slot = 0
	_free_compact_slots.clear()
	_compact_slot_count = 0
	_commit_uniform_set = RID()
	_commit_descriptor_buffer = RID()
	_activation_buffer = RID()
	_summary_buffer = RID()
	_status_buffer = RID()
	_completion_uniform_set = RID()
	_completion_buffer = RID()


func get_status() -> Dictionary:
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_arena.v5",
		"architecture": "bounded_gpu_validated_exact_meshlet_residency",
		"position_encoding": "float32_world_space",
		"page_slot_capacity": PAGE_SLOT_COUNT,
		"interaction_scratch_reserve_per_page": INTERACTION_SCRATCH_RESERVE_PER_PAGE,
		"background_scratch_reservation_deferrals": _background_scratch_reservation_deferrals,
		"maximum_slots": _maximum_slots,
		"maximum_scratch_slots": _maximum_scratch_slots,
		"compact_visibility_slots": _compact_slot_count,
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
		"resident_buffer_count_per_entry": 1,
		"compacted_surface_vertices": true,
		"compacted_surface_indices": true,
		"compacted_surface_indirect_commands": true,
		"gpu_cohort_validation": true,
		"cpu_readback_blocks_publication": false,
		"indirect_commands_per_surface": MAXIMUM_MESHLETS_PER_SLOT,
		"meshlet_cells_per_axis": 8,
		"asynchronous_summary_bytes": SUMMARY_STRIDE,
		"dispatch_completion_bytes_per_request": COMPLETION_STRIDE,
		"dispatch_completion_requests": _dispatch_completion_requests,
		"dispatch_completion_completions": _dispatch_completion_completions,
		"dispatch_completion_bytes": _dispatch_completion_bytes,
		"completed_dispatch_queue_count": _completed_dispatch_completions.size(),
		"completed_readback_queue_count": _completed_readbacks.size(),
		"allocated_bytes": _scratch_allocated_bytes + _resident_allocated_bytes,
		"scratch_allocated_bytes": _scratch_allocated_bytes,
		"resident_allocated_bytes": _resident_allocated_bytes,
		"peak_resident_allocated_bytes": _peak_resident_allocated_bytes,
		"uploaded_bytes": _uploaded_bytes,
		"dispatch_count": _dispatch_count,
		"incremental_dispatch_count": _incremental_dispatch_count,
		"incremental_copy_fallback_count": _incremental_copy_fallback_count,
		"incremental_meshlet_copy_bytes": _incremental_meshlet_copy_bytes,
		"last_incremental_meshlet_copy_bytes": _last_incremental_meshlet_copy_bytes,
		"regenerated_cell_count": _regenerated_cell_count,
		"last_regenerated_cell_count": _last_regenerated_cell_count,
		"last_dispatch_uploaded_bytes": _last_dispatch_uploaded_bytes,
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


func _on_dispatch_completion(data: PackedByteArray, ticket: int) -> void:
	if _closed:
		return
	_readback_mutex.lock()
	_completed_dispatch_completions.append({"ticket": ticket, "data": data})
	_readback_mutex.unlock()


func compact_resident_meshlets(entry: Dictionary) -> Dictionary:
	if _closed or str(entry.get("resident_kind", "")) != "provisional" \
			or bool(entry.get("counts_pending", true)):
		return entry
	if bool(entry.get("empty", false)):
		if bool(entry.get("active", false)) and not commit_visibility([], [entry]):
			return entry
		_free_rids(Array(entry.get("resident_view_rids", [])))
		_resident_allocated_bytes = maxi(
			0, _resident_allocated_bytes - int(entry.get("resident_allocated_bytes", 0))
		)
		_release_scratch_slot(
			int(entry.get("arena_page_index", -1)),
			int(entry.get("arena_slot_index", -1)),
			int(entry.get("arena_generation", -1))
		)
		var empty_entry := entry.duplicate()
		empty_entry["resident_kind"] = "empty"
		for field in [
			"vertex_array", "index_array", "position_buffer", "normal_buffer",
			"meta_buffer", "index_buffer", "indirect_buffer", "indirect_offset",
			"indirect_draw_count", "gpu_slot", "arena_page_index",
			"arena_slot_index", "arena_generation", "resident_view_rids",
			"resident_allocated_bytes", "meshlet_buffer_sizes", "input_buffers",
			"input_offsets", "input_sizes", "meshlet_index_source_buffer",
			"meshlet_index_source_offset", "arena_ticket",
		]:
			empty_entry.erase(field)
		_last_error = ""
		return empty_entry

	var vertex_count := int(entry.get("vertex_count", 0))
	var index_count := int(entry.get("index_count", 0))
	var draw_count := int(entry.get("indirect_draw_count", 0))
	if vertex_count <= 0 or index_count <= 0 or draw_count <= 0:
		return entry
	var compact_slot := _allocate_compact_slot()
	if compact_slot < 0:
		return entry
	var position_bytes := vertex_count * PACKED_POSITION_STRIDE
	var normal_bytes := vertex_count * PACKED_NORMAL_STRIDE
	var meta_bytes := vertex_count * PACKED_META_STRIDE
	var index_bytes := index_count * 4
	var indirect_bytes := draw_count * DRAW_COMMAND_STRIDE
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
	var compact_index_storage := _rendering_device.storage_buffer_create(
		index_bytes, PackedByteArray()
	)
	var indirect_buffer := _rendering_device.storage_buffer_create(
		indirect_bytes, PackedByteArray(),
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
	)
	var buffers: Array = [
		position_buffer, normal_buffer, meta_buffer, index_buffer,
		compact_index_storage, indirect_buffer,
	]
	for rid in buffers:
		if not rid is RID or not rid.is_valid():
			_free_rids(buffers)
			_release_compact_slot(compact_slot)
			_last_error = "resident arena exact meshlet allocation failed"
			return entry
	var source_buffers := [
		entry.get("position_buffer", RID()), entry.get("normal_buffer", RID()),
		entry.get("meta_buffer", RID()),
		entry.get("meshlet_index_source_buffer", RID()),
		entry.get("indirect_buffer", RID()), _status_buffer,
	]
	for source in source_buffers:
		if not source is RID or not source.is_valid():
			_free_rids(buffers)
			_release_compact_slot(compact_slot)
			_last_error = "resident arena exact meshlet source is invalid"
			return entry
	var uniforms: Array[RDUniform] = []
	var destination_buffers := [
		position_buffer, normal_buffer, meta_buffer,
		compact_index_storage, indirect_buffer,
	]
	var uniform_buffers := source_buffers + destination_buffers
	for binding in range(uniform_buffers.size()):
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(uniform_buffers[binding])
		uniforms.append(uniform)
	var uniform_set := _rendering_device.uniform_set_create(
		uniforms, _compact_shader, 0
	)
	if not uniform_set.is_valid():
		_free_rids(buffers)
		_release_compact_slot(compact_slot)
		_last_error = "resident arena exact meshlet uniform set creation failed"
		return entry
	var vertex_array := _rendering_device.vertex_array_create(
		vertex_count, _vertex_format, [position_buffer, normal_buffer, meta_buffer]
	)
	var index_array := _rendering_device.index_array_create(index_buffer, 0, index_count)
	if not vertex_array.is_valid() or not index_array.is_valid():
		_free_rids([uniform_set, vertex_array, index_array])
		_free_rids(buffers)
		_release_compact_slot(compact_slot)
		_last_error = "resident arena exact meshlet view creation failed"
		return entry
	var old_slot := int(entry.get("gpu_slot", -1))
	var push_values := PackedInt32Array([
		int(entry.get("position_offset", 0)) / 4,
		int(entry.get("normal_offset", 0)) / 4,
		int(entry.get("meta_offset", 0)) / 4,
		int(entry.get("meshlet_index_source_offset", 0)) / 4,
		int(entry.get("indirect_offset", 0)) / DRAW_COMMAND_STRIDE,
		old_slot * int(STATUS_SLOT_STRIDE / 4),
		draw_count,
		0,
		compact_slot * int(STATUS_SLOT_STRIDE / 4),
		0, 0, 0,
	]).to_byte_array()
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(compute_list, _compact_pipeline)
	_rendering_device.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rendering_device.compute_list_set_push_constant(
		compute_list, push_values, push_values.size()
	)
	_rendering_device.compute_list_dispatch(compute_list, 1, 1, 1)
	_rendering_device.compute_list_end()
	var index_copy_error := _rendering_device.buffer_copy(
		compact_index_storage, index_buffer, 0, 0, index_bytes
	)
	if index_copy_error != OK:
		_free_rids([uniform_set, vertex_array, index_array])
		_free_rids(buffers)
		_release_compact_slot(compact_slot)
		_last_error = "resident arena exact index publication copy failed"
		return entry
	var compact := entry.duplicate()
	compact["resident_kind"] = "compact_meshlets"
	compact["vertex_array"] = vertex_array
	compact["index_array"] = index_array
	compact["position_buffer"] = position_buffer
	compact["normal_buffer"] = normal_buffer
	compact["meta_buffer"] = meta_buffer
	compact["position_offset"] = 0
	compact["normal_offset"] = 0
	compact["meta_offset"] = 0
	compact["index_buffer"] = index_buffer
	compact["indirect_buffer"] = indirect_buffer
	compact["indirect_offset"] = 0
	compact["gpu_slot"] = compact_slot
	compact["resident_rids"] = [
		uniform_set, vertex_array, index_array,
		position_buffer, normal_buffer, meta_buffer, index_buffer,
		compact_index_storage, indirect_buffer,
	]
	var allocated_bytes := position_bytes + normal_bytes + meta_bytes \
			+ index_bytes * 2 + indirect_bytes
	compact["resident_allocated_bytes"] = allocated_bytes
	for field in [
		"arena_page_index", "arena_slot_index", "arena_generation",
		"resident_view_rids", "meshlet_buffer_sizes", "input_buffers",
		"input_offsets", "input_sizes", "meshlet_index_source_buffer",
		"meshlet_index_source_offset", "arena_ticket",
	]:
		compact.erase(field)
	if bool(entry.get("active", false)):
		if not commit_visibility([compact], [entry]):
			_free_rids(Array(compact.get("resident_rids", [])))
			_release_compact_slot(compact_slot)
			return entry
	else:
		# Prepared cohort members must remain invisible until their atomic lifecycle
		# command arrives. The compact shader has copied their exact geometry and
		# status, but publication still belongs to that later cohort commit.
		_rendering_device.buffer_update(
			_activation_buffer, compact_slot * 4, 4,
			PackedInt32Array([0]).to_byte_array()
		)
	_free_rids(Array(entry.get("resident_view_rids", [])))
	_resident_allocated_bytes = maxi(
		0, _resident_allocated_bytes - int(entry.get("resident_allocated_bytes", 0))
	)
	_release_scratch_slot(
		int(entry.get("arena_page_index", -1)),
		int(entry.get("arena_slot_index", -1)),
		int(entry.get("arena_generation", -1))
	)
	_resident_allocated_bytes += allocated_bytes
	_peak_resident_allocated_bytes = maxi(
		_peak_resident_allocated_bytes, _resident_allocated_bytes
	)
	_compacted_resident_entries += 1
	_last_error = ""
	return compact

func _create_provisional_resident(
	page: Dictionary,
	page_index: int,
	slot_index: int,
	global_slot: int,
	page_field_mode: bool
) -> Dictionary:
	var buffers: Array = page.get("buffers", [])
	var strides: Array = page.get("strides", [])
	if slot_index < 0 or buffers.size() != BINDING_COUNT \
			or strides.size() != BINDING_COUNT:
		_last_error = "resident arena provisional source is invalid"
		return {}
	var maximum_vertex_count := int(strides[13]) / PACKED_POSITION_STRIDE
	var maximum_index_count := int(strides[17]) / 4
	var index_buffer := _rendering_device.index_buffer_create(
		maximum_index_count, RenderingDevice.INDEX_BUFFER_FORMAT_UINT32
	)
	if not index_buffer.is_valid():
		_last_error = "resident arena provisional index allocation failed"
		return {}
	var copy_error := _rendering_device.buffer_copy(
		buffers[17], index_buffer,
		slot_index * int(strides[17]), 0, int(strides[17])
	)
	if copy_error != OK:
		_free_rids([index_buffer])
		_last_error = "resident arena provisional index copy failed: %s" % error_string(copy_error)
		return {}
	var vertex_array := _rendering_device.vertex_array_create(
		maximum_vertex_count,
		_vertex_format,
		[buffers[13], buffers[14], buffers[15]],
		[
			slot_index * int(strides[13]),
			slot_index * int(strides[14]),
			slot_index * int(strides[15]),
		]
	)
	var index_array := _rendering_device.index_array_create(
		index_buffer, 0, maximum_index_count
	)
	if not vertex_array.is_valid() or not index_array.is_valid():
		_free_rids([vertex_array, index_array, index_buffer])
		_last_error = "resident arena provisional vertex or index view creation failed"
		return {}
	_resident_allocated_bytes += int(strides[17])
	_peak_resident_allocated_bytes = maxi(
		_peak_resident_allocated_bytes, _resident_allocated_bytes
	)
	return {
		"resident_kind": "provisional",
		"vertex_array": vertex_array,
		"index_array": index_array,
		"position_buffer": buffers[13],
		"normal_buffer": buffers[14],
		"meta_buffer": buffers[15],
		"position_offset": slot_index * int(strides[13]),
		"normal_offset": slot_index * int(strides[14]),
		"meta_offset": slot_index * int(strides[15]),
		"index_buffer": index_buffer,
		"meshlet_index_source_buffer": buffers[17],
		"meshlet_index_source_offset": slot_index * int(strides[17]),
		"indirect_buffer": buffers[20],
		"indirect_offset": slot_index * int(strides[20]),
		"indirect_draw_count": 8 + int(maxi(
			0, int(page.get("cell_capacity", 4096)) - 4096
		) / 64) if page_field_mode else 1,
		"gpu_slot": global_slot,
		"arena_page_index": page_index,
		"arena_slot_index": slot_index,
		"arena_generation": int(page.get("generation", 0)),
		"resident_view_rids": [vertex_array, index_array, index_buffer],
		"resident_allocated_bytes": int(strides[17]),
		"meshlet_buffer_sizes": [
			int(strides[13]), int(strides[14]),
			int(strides[15]), int(strides[17]),
		],
		"input_buffers": buffers.slice(0, TABLE_BINDING_BEGIN),
		"input_offsets": _slot_input_offsets(strides, slot_index),
		"input_sizes": _input_sizes(strides),
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
	var indirect_draw_count := int(entry.get("indirect_draw_count", 1))
	if _rendering_device == null or vertex_count <= 0 or index_count <= 0 \
			or not position_buffer.is_valid() or not index_buffer.is_valid() \
			or not indirect_buffer.is_valid() or indirect_draw_count <= 0:
		return {"valid": false, "error": "resident geometry is unavailable"}
	var unit_direction := direction.normalized()
	if not origin.is_finite() or not unit_direction.is_finite() \
			or unit_direction.is_zero_approx() or maximum_distance <= 0.0:
		return {"valid": false, "error": "debug ray is invalid"}
	var position_bytes := _rendering_device.buffer_get_data(position_buffer)
	var index_bytes := _rendering_device.buffer_get_data(index_buffer)
	var indirect_bytes := _rendering_device.buffer_get_data(
		indirect_buffer, indirect_offset, indirect_draw_count * DRAW_COMMAND_STRIDE
	)
	if position_bytes.size() != vertex_count * PACKED_POSITION_STRIDE \
			or index_bytes.size() != index_count * 4 \
			or indirect_bytes.size() != indirect_draw_count * DRAW_COMMAND_STRIDE:
		return {
			"valid": false,
			"error": "resident geometry readback size is invalid",
			"position_bytes": position_bytes.size(),
			"index_bytes": index_bytes.size(),
			"indirect_bytes": indirect_bytes.size(),
		}
	var draw_index_count := 0
	var draw_instance_count := 0
	var command_ranges: Array[Vector2i] = []
	for command in range(indirect_draw_count):
		var command_offset := command * DRAW_COMMAND_STRIDE
		var command_indices := int(indirect_bytes.decode_u32(command_offset))
		var command_first := int(indirect_bytes.decode_u32(command_offset + 8))
		draw_index_count += command_indices
		draw_instance_count += int(indirect_bytes.decode_u32(command_offset + 4))
		command_ranges.append(Vector2i(command_first, command_indices))
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
	var indirect_covers_hit := nearest_triangle < 0
	if nearest_triangle >= 0:
		var hit_index := nearest_triangle * 3
		for command_range in command_ranges:
			if hit_index >= command_range.x \
					and hit_index + 3 <= command_range.x + command_range.y:
				indirect_covers_hit = true
				break
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
			"draw_count": indirect_draw_count,
		},
		"indirect_matches_entry": draw_index_count == index_count,
		"indirect_covers_hit_triangle": indirect_covers_hit,
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


func _allocate_compact_slot() -> int:
	var local_slot := -1
	if not _free_compact_slots.is_empty():
		local_slot = _free_compact_slots.pop_back()
	elif _next_compact_slot < _maximum_slots:
		local_slot = _next_compact_slot
		_next_compact_slot += 1
	if local_slot < 0:
		_last_error = "resident arena compact visibility capacity is full"
		return -1
	_compact_slot_count += 1
	return _maximum_slots + local_slot


func _release_compact_slot(global_slot: int) -> bool:
	var local_slot := global_slot - _maximum_slots
	if local_slot < 0 or local_slot >= _next_compact_slot \
			or _free_compact_slots.has(local_slot):
		return false
	var inactive := PackedInt32Array([0]).to_byte_array()
	_rendering_device.buffer_update(_activation_buffer, global_slot * 4, 4, inactive)
	_free_compact_slots.append(local_slot)
	_compact_slot_count = maxi(0, _compact_slot_count - 1)
	return true


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


func _find_page(
	input_buffers: Array,
	cell_count: int,
	excluded_page_index: int = -1,
	interaction: bool = false
) -> int:
	for page_index in range(_pages.size()):
		if page_index == excluded_page_index:
			continue
		var page: Dictionary = _pages[page_index]
		var free_slot_count := Array(page.get("free_slots", [])).size()
		if free_slot_count > (0 if interaction else INTERACTION_SCRATCH_RESERVE_PER_PAGE) \
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
	var remaining := _maximum_scratch_slots - _allocated_slot_count
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
	var status_uniform := RDUniform.new()
	status_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	status_uniform.binding = 21
	status_uniform.add_id(_status_buffer)
	uniforms.append(status_uniform)
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
	global_slot: int,
	dirty_regular_brick_mask: int,
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
		global_slot * MAXIMUM_MESHLETS_PER_SLOT * 4,
		dirty_regular_brick_mask,
		0,
		MAXIMUM_MESHLETS_PER_SLOT,
	])
	var bytes := values.to_byte_array()
	bytes.resize(128)
	var extent := bounds_max - bounds_min
	for component in range(3):
		bytes.encode_float(96 + component * 4, bounds_min[component])
		bytes.encode_float(112 + component * 4, extent[component])
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
		DRAW_COMMAND_STRIDE * MAXIMUM_MESHLETS_PER_SLOT,
	]


func _copy_previous_meshlets(
	previous: Dictionary, page: Dictionary, slot_index: int, cell_count: int
) -> bool:
	if str(previous.get("resident_kind", "")) != "provisional" \
			or int(previous.get("cell_count", -1)) != cell_count:
		return false
	var buffers: Array = page.get("buffers", [])
	var strides: Array = page.get("strides", [])
	if buffers.size() != BINDING_COUNT or strides.size() != BINDING_COUNT:
		return false
	var sources := [
		previous.get("position_buffer", RID()),
		previous.get("normal_buffer", RID()),
		previous.get("meta_buffer", RID()),
		previous.get("index_buffer", RID()),
	]
	var source_offsets := [
		int(previous.get("position_offset", 0)),
		int(previous.get("normal_offset", 0)),
		int(previous.get("meta_offset", 0)),
		0,
	]
	var source_sizes: Array = previous.get("meshlet_buffer_sizes", [])
	if source_sizes.size() != 4:
		return false
	var output_sizes := _output_buffer_sizes(cell_count)
	var copy_sizes := [
		int(output_sizes[0]), int(output_sizes[1]),
		int(output_sizes[2]), int(output_sizes[4]),
	]
	# Pages are capacity classes. A replacement can land in a larger page even
	# when its logical cell count is unchanged, so copying the destination stride
	# can read past the previous slot. Copy only the logical meshlet payload.
	for index in range(4):
		var source: RID = sources[index]
		if not source.is_valid() or source_offsets[index] < 0 \
				or copy_sizes[index] > int(source_sizes[index]):
			return false
	for index in range(4):
		var binding: int = [13, 14, 15, 17][index]
		var source: RID = sources[index]
		var error := _rendering_device.buffer_copy(
			source, buffers[binding], source_offsets[index],
			slot_index * int(strides[binding]), copy_sizes[index]
		)
		if error != OK:
			return false
	_last_incremental_meshlet_copy_bytes = 0
	for size in copy_sizes:
		_last_incremental_meshlet_copy_bytes += int(size)
	_incremental_meshlet_copy_bytes += _last_incremental_meshlet_copy_bytes
	return true


func _copy_previous_inputs(
	previous: Dictionary, page: Dictionary, slot_index: int, input_buffers: Array
) -> bool:
	var sources: Array = previous.get("input_buffers", [])
	var source_offsets: Array = previous.get("input_offsets", [])
	var source_sizes: Array = previous.get("input_sizes", [])
	var buffers: Array = page.get("buffers", [])
	var strides: Array = page.get("strides", [])
	if sources.size() != TABLE_BINDING_BEGIN \
			or source_offsets.size() != TABLE_BINDING_BEGIN \
			or source_sizes.size() != TABLE_BINDING_BEGIN:
		return false
	for binding in range(TABLE_BINDING_BEGIN):
		var size := PackedByteArray(input_buffers[binding]).size()
		if int(source_sizes[binding]) != size:
			return false
		var source: RID = sources[binding]
		if not source.is_valid():
			return false
		if binding == 6:
			var config_error := _rendering_device.buffer_update(
				buffers[binding], slot_index * int(strides[binding]), size,
				PackedByteArray(input_buffers[binding])
			)
			if config_error != OK:
				return false
			_uploaded_bytes += size
			continue
		if _rendering_device.buffer_copy(
			source, buffers[binding], int(source_offsets[binding]),
			slot_index * int(strides[binding]), size
		) != OK:
			return false
	return true


func _patch_dirty_page_fields(
	page: Dictionary,
	slot_index: int,
	input_buffers: Array,
	dirty_minimum: Vector3i,
	dirty_maximum: Vector3i
) -> bool:
	var values: PackedByteArray = input_buffers[0]
	var meta: PackedByteArray = input_buffers[1]
	var origins: PackedByteArray = input_buffers[3]
	var options: PackedByteArray = input_buffers[4]
	var config: PackedByteArray = input_buffers[6]
	var page_count := config.decode_s32(8)
	var buffers: Array = page.get("buffers", [])
	var strides: Array = page.get("strides", [])
	for page_index in range(page_count):
		var header := page_index * 16
		var origin := Vector3i(
			roundi(origins.decode_float(header)),
			roundi(origins.decode_float(header + 4)),
			roundi(origins.decode_float(header + 8))
		)
		var spacing := maxi(1, roundi(origins.decode_float(header + 12)))
		var sample_minimum := roundi(options.decode_float(header + 8))
		var sample_maximum := roundi(options.decode_float(header + 12))
		var low := Vector3i(
			floori(float(dirty_minimum.x - 1 - origin.x) / spacing),
			floori(float(dirty_minimum.y - 1 - origin.y) / spacing),
			floori(float(dirty_minimum.z - 1 - origin.z) / spacing)
		)
		var high := Vector3i(
			ceili(float(dirty_maximum.x + 1 - origin.x) / spacing),
			ceili(float(dirty_maximum.y + 1 - origin.y) / spacing),
			ceili(float(dirty_maximum.z + 1 - origin.z) / spacing)
		)
		low = low.max(Vector3i.ONE * sample_minimum)
		high = high.min(Vector3i.ONE * sample_maximum)
		if low.x > high.x or low.y > high.y or low.z > high.z:
			continue
		var local_low := low - Vector3i.ONE * sample_minimum
		var local_high := high - Vector3i.ONE * sample_minimum
		for z in range(local_low.z, local_high.z + 1):
			for y in range(local_low.y, local_high.y + 1):
				var sample_index := page_index * 6859 + (z * 19 + y) * 19 + local_low.x
				var byte_offset := sample_index * 8
				var byte_count := (local_high.x - local_low.x + 1) * 8
				for binding in range(2):
					var source := values if binding == 0 else meta
					var patch := source.slice(byte_offset, byte_offset + byte_count)
					if _rendering_device.buffer_update(
						buffers[binding], slot_index * int(strides[binding]) + byte_offset,
						byte_count, patch
					) != OK:
						return false
					_uploaded_bytes += byte_count
	return true


static func _slot_input_offsets(strides: Array, slot_index: int) -> Array[int]:
	var offsets: Array[int] = []
	for binding in range(TABLE_BINDING_BEGIN):
		offsets.append(slot_index * int(strides[binding]))
	return offsets


static func _input_sizes(strides: Array) -> Array[int]:
	var sizes: Array[int] = []
	for binding in range(TABLE_BINDING_BEGIN):
		sizes.append(int(strides[binding]))
	return sizes


func _clear_dirty_meshlet_state(
	indirect_buffer: RID,
	indirect_offset: int,
	global_slot: int,
	dirty_regular_brick_mask: int,
	has_transitions: bool
) -> int:
	var zero_status := PackedByteArray()
	zero_status.resize(STATUS_STRIDE)
	for meshlet in range(MAXIMUM_MESHLETS_PER_SLOT):
		var dirty := meshlet < 8 and (dirty_regular_brick_mask & (1 << meshlet)) != 0
		dirty = dirty or (meshlet >= 8 and has_transitions)
		if not dirty:
			continue
		var command := PackedInt32Array([
			0, 1, _meshlet_index_base(meshlet), 0, 0,
		]).to_byte_array()
		var command_error := _rendering_device.buffer_update(
			indirect_buffer, indirect_offset + meshlet * DRAW_COMMAND_STRIDE,
			DRAW_COMMAND_STRIDE, command
		)
		if command_error != OK:
			return command_error
		var status_error := _rendering_device.buffer_update(
			_status_buffer,
			global_slot * STATUS_SLOT_STRIDE + meshlet * STATUS_STRIDE,
			STATUS_STRIDE, zero_status
		)
		if status_error != OK:
			return status_error
	return OK


func _initialize_incremental_status(
	global_slot: int, dirty_regular_brick_mask: int, has_transitions: bool
) -> int:
	var values := PackedInt32Array()
	values.resize(MAXIMUM_MESHLETS_PER_SLOT * 4)
	for meshlet in range(MAXIMUM_MESHLETS_PER_SLOT):
		var dirty := meshlet < 8 and (dirty_regular_brick_mask & (1 << meshlet)) != 0
		dirty = dirty or (meshlet >= 8 and has_transitions)
		if not dirty:
			# Clean geometry was already validated in the previous slot. A paired
			# sentinel preserves non-empty telemetry without rereading its counters.
			values[meshlet * 4] = 1
			values[meshlet * 4 + 1] = 1
	return _rendering_device.buffer_update(
		_status_buffer, global_slot * STATUS_SLOT_STRIDE,
		STATUS_SLOT_STRIDE, values.to_byte_array()
	)


static func _meshlet_index_base(meshlet: int) -> int:
	if meshlet < 8:
		return meshlet * 512 * MAXIMUM_INDICES_PER_CELL
	return 8 * 512 * MAXIMUM_INDICES_PER_CELL \
		+ (meshlet - 8) * 64 * MAXIMUM_INDICES_PER_CELL


static func _set_bit_count(value: int) -> int:
	var count := 0
	var remaining := value & 0xff
	while remaining != 0:
		remaining &= remaining - 1
		count += 1
	return count


static func _round_up(value: int, alignment: int) -> int:
	return int((value + alignment - 1) / alignment) * alignment
