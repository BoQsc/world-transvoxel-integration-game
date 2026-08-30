extends SceneTree

const WaterfallRoute := preload("res://scripts/wt_terrain_waterfall_route.gd")
const Controller := preload("res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd")

class AdmissionBackend:
	extends Node
	var commits := 0

	func get_gpu_resident_render_activation_cohort(_identity: Dictionary) -> Dictionary:
		return {"status": "READY", "ready": true, "regional": true, "chunks": [
			{"page_x": 0, "generation": 1}, {"page_x": 1, "generation": 2},
			{"page_x": 2, "generation": 3},
		]}

	func activate_gpu_resident_render_cohort(pool: Array, _seed: Dictionary) -> Dictionary:
		if pool.size() != 3:
			return {"status": "WAITING_COHORT"}
		commits += 1
		var chunks: Array = []
		for inventory in pool:
			var member := Dictionary(inventory[0]).duplicate()
			member["activation_required"] = int(member["generation"]) == 1
			chunks.append(member)
		return {"status": "ACTIVE", "active": true, "chunks": chunks}

class AdmissionEffect:
	extends RefCounted
	var submitted_entries := 0

	func activate_entries(entries: Array) -> bool:
		submitted_entries += entries.size()
		return true


class RetiringAdmissionBackend:
	extends Node
	var pending: Array[Dictionary] = []
	var rejections: Array[Dictionary] = []

	func pop_gpu_resident_render_request() -> Dictionary:
		if pending.is_empty():
			return {"status": "EMPTY"}
		return pending.pop_front()

	func reject_gpu_resident_render_request(
		request_id: int, identity: Dictionary, error: String
	) -> Dictionary:
		rejections.append({
			"request_id": request_id,
			"identity": identity.duplicate(true),
			"error": error,
		})
		return {"status": "REJECTED"}


class RetiringAdmissionEffect:
	extends RefCounted
	var submissions := 0

	func submit_native_packed_input(
		_input_buffers: Array,
		_cell_count: int,
		_identity: Dictionary,
		_publication_sequence: int,
		_activate_immediately: bool,
		_bounds_min: Vector3,
		_bounds_max: Vector3,
		_proven_empty: bool
	) -> int:
		submissions += 1
		return submissions

	func get_status() -> Dictionary:
		return {}

class RetryProbe:
	extends "res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd"

	var visited: Array[String] = []

	func add_waiting(key: String) -> void:
		_groups[key] = {"native_prepared": true}
		_queue_activation_cohort_retry(key)
		_queue_activation_cohort_retry(key)

	func _try_queue_activation_cohort(group_key: String) -> void:
		visited.append(group_key)
		_queue_activation_cohort_retry(group_key)


func _initialize() -> void:
	var probe := RetryProbe.new()
	var capacity: int = probe.ACTIVATION_COHORT_RETRY_CAPACITY
	var count := capacity * 3 + 1
	for index in range(count):
		probe.add_waiting(str(index))
	for _frame in range(4):
		probe._drain_activation_cohort_retries()
	for index in range(count):
		if index >= probe.visited.size() or probe.visited[index] != str(index):
			_fail(probe, "blocked retries starved later groups: %s" % str(probe.visited))
			return
	if probe._activation_retry_queue.size() != count \
			or probe._activation_retry_membership.size() != count \
			or probe.visited.size() != capacity * 4:
		_fail(probe, "retry queue lost deduplication or per-frame budget")
		return
	probe._activation_retry_membership.erase(probe._activation_retry_queue[0])
	probe._drain_activation_cohort_retries()
	if probe._activation_retry_queue.size() != count - 1:
		_fail(probe, "cancelled retry was retained")
		return
	probe.free()
	if not _test_spatial_retirement_routes() or not _test_batched_inventory():
		quit(1)
		return
	if not _test_generation_activation_ack() or not _test_optional_lifecycle_history():
		quit(1)
		return
	if not _test_retiring_status():
		quit(1)
		return
	if not _test_retiring_admission_rejected():
		quit(1)
		return
	if not _test_activation_inventory():
		quit(1)
		return
	if not _test_regional_commit_barrier():
		quit(1)
		return
	if not _test_drain_gate():
		quit(1)
		return
	print("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_PASS fair=1 bounded=1 deduplicated=1 cancelled=1 inflight_excluded=1 strict_drain=1 spatial_retirement=1 batched_inventory=1 activation_ack=1 optional_history=1 retiring_diagnostics=1 retiring_admission_rejected=1")
	quit(0)


func _test_optional_lifecycle_history() -> bool:
	var controller := Controller.new()
	controller._groups["test"] = {"requests": {"terrain": {"identity": {"generation": 1}}}}
	controller._record_lifecycle_event("ACTIVE", "test")
	var ok := controller._recent_lifecycle_events.is_empty()
	controller.set_debug_lifecycle_history_enabled(true)
	for index in range(controller.LIFECYCLE_HISTORY_CAPACITY + 1):
		controller._record_lifecycle_event("ACTIVE", "test", {"test_index": index})
	var status := controller.get_status()
	var events: Array = status["recent_lifecycle_events"]
	ok = ok and events.size() == controller.LIFECYCLE_HISTORY_CAPACITY \
		and int(events[0]["test_index"]) == 1
	events[0]["identity"]["generation"] = 99
	ok = ok and int(controller._recent_lifecycle_events[0]["identity"]["generation"]) == 1
	controller.set_debug_lifecycle_history_enabled(false)
	controller._record_lifecycle_event("RETIRE", "test")
	ok = ok and controller._recent_lifecycle_events.is_empty()
	controller.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: optional bounded lifecycle history")
	return ok


func _test_retiring_status() -> bool:
	var controller := Controller.new()
	controller._process_frame = 25
	controller._groups["retiring"] = {
		"active": false,
		"native_active": false,
		"validated": false,
		"retiring": true,
		"created_frame": 5,
		"requests": {"terrain": {
			"request_id": 17,
			"identity": {"surface": "terrain", "generation": 3},
		}},
		"native_validated": {},
		"retired": {},
	}
	var status := controller.get_status()
	var examples: Array = status.get("retiring_chunk_examples", [])
	var ok := int(status.get("retiring_chunks", 0)) == 1 \
		and examples.size() == 1 \
		and int(Dictionary(examples[0].get("request_ids", {})).get(
			"terrain", 0
		)) == 17 \
		and int(examples[0].get("age_frames", 0)) == 20
	controller.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: retiring diagnostics")
	return ok


func _test_retiring_admission_rejected() -> bool:
	var controller := Controller.new()
	var backend := RetiringAdmissionBackend.new()
	var effect := RetiringAdmissionEffect.new()
	var identity := {
		"page_x": 10,
		"page_y": 0,
		"page_z": 6,
		"lod": 3,
		"generation": 2035,
		"source_revision": 190327,
		"world_revision": 0,
		"transition_mask": 32,
		"surface": "static_water",
		"input_stage": "pre_mesh_field",
		"static_water_surface_expected": true,
	}
	var request := {
		"schema": "world_transvoxel.gpu_resident_render_request.v6",
		"status": "PASS",
		"position_space": "world",
		"input_stage": "pre_mesh_field",
		"cpu_topology_input_dependency": false,
		"cpu_field_sampling": false,
		"gpu_density_field_generation": true,
		"gpu_material_field_generation": true,
		"gpu_page_lattice_input": true,
		"gpu_transvoxel_extraction": true,
		"cpu_visual_mesh_omitted": true,
		"gpu_resident_render_publication": true,
		"cpu_render_visible_until_activation": false,
		"cpu_collision_publication_unchanged": true,
		"native_input_packing": true,
		"cell_batch_exported": false,
		"fallback_used": false,
		"gpu_input_buffers": _nonempty_input_buffers(),
		"packed_byte_count": 13,
		"cell_count": 1,
		"page_count": 1,
		"request_id": 2149,
		"identity": identity,
		"bounds_min": Vector3.ZERO,
		"bounds_max": Vector3.ONE,
	}
	backend.pending.append(request)
	controller._backend_terrain = backend
	controller._effect = effect
	controller._resident_capacity = 8
	var group_key := controller._group_key(identity)
	controller._groups[group_key] = controller._new_group(identity)
	controller._groups[group_key]["retiring"] = true
	controller._submit_native_captures()
	var group := Dictionary(controller._groups[group_key])
	var ok := effect.submissions == 0 \
		and backend.rejections.size() == 1 \
		and int(backend.rejections[0].get("request_id", 0)) == 2149 \
		and str(backend.rejections[0].get("error", "")) \
			== "resident chunk group is retiring" \
		and Dictionary(group.get("requests", {})).is_empty()
	controller.free()
	backend.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: retiring admission")
	return ok


func _nonempty_input_buffers() -> Array:
	var buffers: Array = []
	for _index in range(13):
		buffers.append(PackedByteArray([1]))
	return buffers


func _test_generation_activation_ack() -> bool:
	var controller := Controller.new()
	var identity := {
		"page_x": 35, "page_y": 2, "page_z": 35, "lod": 0, "generation": 17,
	}
	var group := {
		"requests": {"terrain": {"identity": identity}},
		"native_prepared": true, "activation_queued": true, "active": false,
	}
	controller._groups["target"] = group
	controller._running = true
	var target := Vector3i(35, 2, 35)
	var ok := not controller.is_chunk_generation_active(target, 0, 17)
	group["active"] = true
	ok = ok and controller.is_chunk_generation_active(target, 0, 17)
	ok = ok and not controller.is_chunk_generation_active(target, 0, 16)
	ok = ok and not controller.is_chunk_generation_active(target, 1, 17)
	ok = ok and not controller.is_chunk_generation_active(target + Vector3i.RIGHT, 0, 17)
	group["retiring"] = true
	ok = ok and not controller.is_chunk_generation_active(target, 0, 17)
	group["retiring"] = false
	controller._running = false
	ok = ok and not controller.is_chunk_generation_active(target, 0, 17)
	controller.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: generation activation acknowledgment")
	return ok


func _test_spatial_retirement_routes() -> bool:
	var controller := Controller.new()
	var retirement := {"page_x": 9, "page_y": 0, "page_z": 8, "lod": 3}
	var identity := retirement.duplicate()
	identity.merge({"generation": 17, "transition_mask": 16})
	controller._groups["current"] = {
		"active": true, "requests": {"terrain": {"identity": identity}},
	}
	var location := controller._chunk_location_key(retirement)
	var routes := controller._active_group_routes_by_chunk()
	var ok := str(routes.get(location, "")) == "current"
	var duplicate := Dictionary(controller._groups["current"]).duplicate(true)
	controller._groups["duplicate"] = duplicate
	routes = controller._active_group_routes_by_chunk()
	ok = ok and routes.has(location) and str(routes[location]).is_empty()
	duplicate["retiring"] = true
	routes = controller._active_group_routes_by_chunk()
	ok = ok and str(routes.get(location, "")) == "current"
	controller._groups["current"]["active"] = false
	ok = ok and not controller._active_group_routes_by_chunk().has(location)
	controller.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: spatial retirement contract")
	return ok


func _test_batched_inventory() -> bool:
	var effect := Controller.GlobalRenderEffect.new()
	var entries: Array = []
	for index in range(64):
		var identity := {"surface": "terrain", "page_x": index, "lod": index % 4}
		var key := effect._identity_key(identity)
		var token := effect._entry_token(key, 1)
		effect._latest_sequence_by_key[key] = 1
		effect._entries[token] = {"identity": identity, "empty": true, "active": false}
		entries.append({"identity": identity, "publication_sequence": 1})
	effect._lifecycle_commands.append({"action": "ACTIVATE_GROUP", "entries": entries})
	effect._drain_lifecycle_commands_on_render_thread()
	var status := effect.get_status()
	var ok := int(status.get("active_inventory_rebuilds", 0)) == 1 \
		and int(status.get("active_empty_entry_count", 0)) == 64 \
		and int(status.get("active_entry_count", 0)) == 64
	for lod in range(4):
		ok = ok and int(Dictionary(status.get("active_terrain_lod_counts", {})).get(str(lod), 0)) == 16
	for entry in entries:
		var command := Dictionary(entry).duplicate()
		command["action"] = "RETIRE"
		effect._lifecycle_commands.append(command)
	effect._drain_lifecycle_commands_on_render_thread()
	status = effect.get_status()
	ok = ok and int(status.get("active_inventory_rebuilds", 0)) == 2 \
		and int(status.get("active_entry_count", -1)) == 0 \
		and int(status.get("active_empty_entry_count", -1)) == 0
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: batched inventory accounting")
	return ok


func _test_activation_inventory() -> bool:
	var probe := RetryProbe.new()
	var members: Array = []
	for index in range(3):
		var identity := {"generation": index + 1}
		members.append(identity)
		probe._prepared_group_routes[probe._activation_chunk_key(identity)] = str(index)
		probe._groups[str(index)] = {
			"native_prepared": true,
			"native_active": index > 0,
			"active": index == 2,
			"activation_queued": index == 1,
			"water_expected": false,
			"prepared": {"terrain": true},
			"requests": {"terrain": {"identity": identity}},
		}
	var inventory: Array = probe._prepared_inventory_pool([members[0], members[2]])
	var blocked: Array = probe._prepared_inventory_pool(members)
	var missing: Array = probe._prepared_inventory_pool([{"generation": 99}])
	probe.free()
	if inventory.size() != 2 \
			or not blocked.is_empty() or not missing.is_empty() \
			or int(inventory[0][0].get("generation", 0)) != 1 \
			or int(inventory[1][0].get("generation", 0)) != 3:
		push_error("native commit admitted an in-flight render activation: %s" % str(inventory))
		return false
	return true


func _test_regional_commit_barrier() -> bool:
	var controller := Controller.new()
	var backend := AdmissionBackend.new()
	var effect := AdmissionEffect.new()
	controller._backend_terrain = backend
	controller._effect = effect
	for index in range(3):
		var identity := {"page_x": index, "generation": index + 1}
		var key := str(index)
		controller._groups[key] = {
			"native_prepared": true, "native_active": index > 0,
			"active": index == 2, "activation_queued": index == 1,
			"prepared": {"terrain": true},
			"requests": {"terrain": {"identity": identity}},
			"sequences": {"terrain": index + 1},
		}
		controller._prepared_group_routes[controller._activation_chunk_key(identity)] = key
	controller._try_queue_activation_cohort("0")
	var waited := backend.commits == 0 and effect.submitted_entries == 0
	controller._groups["1"]["active"] = true
	controller._groups["1"]["activation_queued"] = false
	controller._try_queue_activation_cohort("0")
	var committed := backend.commits == 1 and effect.submitted_entries == 1 \
		and bool(controller._groups["0"].get("activation_queued", false)) \
		and bool(controller._groups["0"].get("native_active", false))
	controller.free()
	backend.free()
	if not waited or not committed:
		push_error("regional commit did not wait for retained render activation")
		return false
	return true


func _test_drain_gate() -> bool:
	if not WaterfallRoute.gpu_publication_drained({"gpu_resident_render_publication": false}):
		push_error("CPU route was changed by the GPU drain gate")
		return false
	var status := {"gpu_resident_render_publication": true, "running": true}
	var controller_keys := [
		"incomplete_chunks", "prepared_inactive_chunks", "activation_queued_chunks",
		"pending_activation_cohorts", "pending_activation_retry_groups",
		"rejected_chunks", "recovery_count", "unrouted_effect_events",
		"application_wait_expirations",
	]
	for key in controller_keys:
		status[key] = 0
	status["native_metrics"] = {
		"queued_requests": 0, "in_flight_requests": 0, "reserved_capture_slots": 0,
	}
	status["effect_status"] = {
		"queued_request_count": 0, "inflight_extraction_count": 0,
		"event_count": 0, "pending_lifecycle_command_count": 0,
	}
	if not WaterfallRoute.gpu_publication_drained(status):
		push_error("drained GPU route was rejected")
		return false
	for section in [status, status["native_metrics"], status["effect_status"]]:
		for key in section.keys():
			if section[key] is not int:
				continue
			section[key] = 1
			var accepted := WaterfallRoute.gpu_publication_drained(status)
			section[key] = 0
			if accepted:
				push_error("GPU drain gate ignored %s" % key)
				return false
	return true


func _fail(probe: Node, error: String) -> void:
	probe.free()
	push_error(error)
	quit(1)
