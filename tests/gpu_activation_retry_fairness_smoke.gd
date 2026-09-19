extends SceneTree

const WaterfallRoute := preload("res://scripts/wt_terrain_waterfall_route.gd")
const Controller := preload("res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd")

class AdmissionBackend:
	extends Node
	var commits := 0
	var queries := 0

	func get_gpu_resident_render_activation_cohort(_identity: Dictionary) -> Dictionary:
		queries += 1
		return {"status": "READY", "ready": true, "regional": true, "chunks": [
			{"page_x": 0, "generation": 1, "activation_required": true},
			{"page_x": 1, "generation": 2, "activation_required": false},
			{"page_x": 2, "generation": 3, "activation_required": false},
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

	func set_gpu_resident_render_chunk_active(_identities: Array, _active: bool) -> Dictionary:
		return {"status": "OK"}

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

	func pop_gpu_resident_render_request(_interaction_only: bool = false) -> Dictionary:
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
	var empty_submissions := 0

	func submit_native_packed_input(
		_input_buffers: Array,
		_cell_count: int,
		_identity: Dictionary,
		_publication_sequence: int,
		_activate_immediately: bool,
		_bounds_min: Vector3,
		_bounds_max: Vector3,
		proven_empty: bool
	) -> int:
		submissions += 1
		empty_submissions += int(proven_empty)
		return submissions

	func get_status() -> Dictionary:
		return {}

class RetryProbe:
	extends "res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd"

	var visited: Array[String] = []
	var simulated_usec := 0
	var query_cost_usec := 0

	func _activation_retry_clock_usec() -> int:
		return simulated_usec

	func add_waiting(key: String) -> void:
		_groups[key] = {"native_prepared": true}
		_queue_activation_cohort_retry(key)
		_queue_activation_cohort_retry(key)

	func _try_queue_activation_cohort(group_key: String) -> bool:
		visited.append(group_key)
		simulated_usec += query_cost_usec
		_queue_activation_cohort_retry(group_key)
		return true


class EventEffect:
	extends RefCounted
	var pending: Array[Dictionary] = []
	var probe
	var pop_cost_usec := 0

	func pop_event() -> Dictionary:
		if pending.is_empty():
			return {}
		probe.simulated_usec += pop_cost_usec
		return pending.pop_front()


class EventDrainProbe:
	extends "res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd"
	var simulated_usec := 0

	func _effect_event_clock_usec() -> int:
		return simulated_usec


class VisibilityArenaStub:
	extends RefCounted

	func commit_visibility(_candidates: Array, _replaced: Array) -> bool:
		return true

	func get_last_error() -> String:
		return ""

	func release(_entry: Dictionary) -> void:
		pass

	func get_status() -> Dictionary:
		return {}


class PreparationBackend:
	extends Node
	var preparations := 0

	func get_gpu_resident_render_chunk_readiness(_identity: Dictionary) -> Dictionary:
		return {"status": "READY", "ready": true}

	func prepare_gpu_resident_render_chunk(_identities: Array) -> Dictionary:
		preparations += 1
		return {"status": "PREPARED", "prepared": true}


class StaleSeedBackend:
	extends Node
	var queries: Array[int] = []

	func get_gpu_resident_render_activation_cohort(identity: Dictionary) -> Dictionary:
		var generation := int(identity.generation)
		queries.append(generation)
		return {"status": "WAITING_COHORT" if generation == 100 else "STALE_APPLICATION"}


class SharedWaitBackend:
	extends Node
	var queries := 0

	func get_gpu_resident_render_activation_cohort(_identity: Dictionary) -> Dictionary:
		queries += 1
		return {
			"status": "WAITING_COHORT",
			"error": "shared boundary dependency",
			"boundary_mask_wait_count": 1,
			"waiting_member": {
				"page_x": 7, "page_y": 0, "page_z": 3,
				"lod": 1, "generation": 91, "transition_mask": 4,
			},
		}


class RetireEffect:
	extends RefCounted
	var retired: Array[int] = []

	func retire_entry(identity: Dictionary, _sequence: int) -> bool:
		retired.append(int(identity.generation))
		return true


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
	if not _test_effect_event_drain_budget():
		quit(1)
		return
	if not _test_effect_event_priority():
		quit(1)
		return
	if not _test_effect_queue_supersession():
		quit(1)
		return
	if not _test_retry_time_budget():
		quit(1)
		return
	if not _test_collision_activation_lane():
		quit(1)
		return
	if not _test_initial_activation_budget():
		quit(1)
		return
	if not _test_stale_seed_budget():
		quit(1)
		return
	if not _test_shared_wait_coalescing():
		quit(1)
		return
	if not _test_empty_admission_budget():
		quit(1)
		return
	if not _test_candidate_generation_headroom():
		quit(1)
		return
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
	if not _test_committed_cohort_supersession():
		quit(1)
		return
	if not _test_drain_gate():
		quit(1)
		return
	print("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_PASS fair=1 bounded=1 effect_event_budget=1 collision_lane=1 normal_lane_not_starved=1 initial_budget=1 stale_seed_budget=1 shared_wait_coalesced=1 empty_admission_budget=1 candidate_headroom=1 deduplicated=1 cancelled=1 inflight_excluded=1 strict_drain=1 spatial_retirement=1 batched_inventory=1 activation_ack=1 optional_history=1 retiring_diagnostics=1 retiring_admission_rejected=1 committed_cohort_supersession=1")
	quit(0)


func _test_effect_event_drain_budget() -> bool:
	var count_probe := EventDrainProbe.new()
	var count_effect := EventEffect.new()
	count_effect.probe = count_probe
	count_probe._effect = count_effect
	var total := count_probe.EFFECT_EVENT_CAPACITY_PER_FRAME * 2 + 3
	for index in range(total):
		count_effect.pending.append({"status": "FIRST_DRAW", "request_id": index + 1})
	count_probe._drain_effect_events()
	if count_effect.pending.size() != total - count_probe.EFFECT_EVENT_CAPACITY_PER_FRAME:
		push_error("effect-event count budget did not defer backlog")
		count_probe.free()
		return false
	count_probe._drain_effect_events()
	count_probe._drain_effect_events()
	if not count_effect.pending.is_empty() \
			or count_probe._effect_events_processed != total \
			or count_probe._effect_event_max_processed_per_frame \
				!= count_probe.EFFECT_EVENT_CAPACITY_PER_FRAME:
		push_error("effect-event count budget lost or duplicated events")
		count_probe.free()
		return false
	count_probe.free()

	var time_probe := EventDrainProbe.new()
	var time_effect := EventEffect.new()
	time_effect.probe = time_probe
	time_effect.pop_cost_usec = time_probe.EFFECT_EVENT_BUDGET_USEC + 1
	time_probe._effect = time_effect
	for index in range(3):
		time_effect.pending.append({"status": "FIRST_DRAW", "request_id": index + 1})
	time_probe._drain_effect_events()
	var ok := time_effect.pending.size() == 2 \
		and time_probe._effect_events_processed == 1 \
		and time_probe._effect_event_budget_stops == 1
	time_probe.free()
	return ok


func _test_effect_event_priority() -> bool:
	var effect := Controller.GlobalRenderEffect.new()
	effect._push_event_on_render_thread("PREPARED", {
		"request_id": 1,
		"identity": {"surface": "terrain", "generation": 1},
	})
	effect._push_event_on_render_thread("PREPARED", {
		"request_id": 2,
		"identity": {
			"surface": "terrain", "generation": 2, "incremental_edit": true,
		},
	})
	var first := effect.pop_event()
	var second := effect.pop_event()
	var status := effect.get_status()
	var ok := int(first.get("request_id", 0)) == 2 \
		and int(second.get("request_id", 0)) == 1 \
		and int(status.get("event_count", -1)) == 0 \
		and int(status.get("priority_event_count", -1)) == 0
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: interactive event priority")
	return ok


func _test_effect_queue_supersession() -> bool:
	var effect := Controller.GlobalRenderEffect.new()
	var background := {
		"page_x": 4, "page_y": 2, "page_z": 8, "lod": 0,
		"generation": 1, "surface": "terrain",
	}
	var interaction := background.duplicate()
	interaction["generation"] = 2
	interaction["interaction_priority"] = true
	var first := effect._queue_packed_request(
		[], 1, background, 10, false, Vector3.ZERO, Vector3.ONE
	)
	var second := effect._queue_packed_request(
		[], 1, interaction, 11, false, Vector3.ZERO, Vector3.ONE
	)
	var status := effect.get_status()
	var ok := first > 0 and second > first \
		and effect._pending.is_empty() \
		and effect._pending_interaction.size() == 1 \
		and int(status.get("cancelled_queued_requests", 0)) == 1 \
		and int(status.get("queued_request_count", 0)) == 1 \
		and int(status.get("queued_interaction_request_count", 0)) == 1
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: queued supersession retained stale upload data")
	return ok


func _test_collision_activation_lane() -> bool:
	var probe := RetryProbe.new()
	for index in range(4):
		var key := "normal_%d" % index
		probe._groups[key] = {"native_prepared": true}
		probe._queue_activation_cohort_retry(key)
	for index in range(3):
		var key := "collision_%d" % index
		probe._groups[key] = {
			"native_prepared": true,
			"collision_activation_priority": true,
		}
		probe._queue_activation_cohort_retry(key)
	for _frame in range(5):
		probe._drain_activation_cohort_retries()
	var expected := [
		"collision_0", "collision_1", "collision_2", "normal_0", "collision_0",
	]
	var ok := probe.visited.slice(0, 5) == expected \
		and probe.visited.size() == 5 * probe.ACTIVATION_COHORT_RETRY_CAPACITY \
		and probe.visited.has("normal_3") \
		and probe._activation_collision_retry_queue.size() == 3 \
		and probe._activation_retry_queue.size() == 4 \
		and probe._activation_retry_membership.size() == 7
	probe.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: collision activation lane was not weighted-fair")
	return ok


func _test_retry_time_budget() -> bool:
	var probe := RetryProbe.new()
	for index in range(8):
		probe.add_waiting(str(index))
	probe.query_cost_usec = probe.ACTIVATION_COHORT_RETRY_BUDGET_USEC + 1
	probe._drain_activation_cohort_retries()
	var ok := probe.visited == ["0"]
	probe.query_cost_usec = probe.ACTIVATION_COHORT_RETRY_BUDGET_USEC / 2
	probe._drain_activation_cohort_retries()
	ok = ok and probe.visited == ["0", "1", "2"]
	probe.query_cost_usec = 0
	probe._drain_activation_cohort_retries()
	ok = ok and probe.visited == ["0", "1", "2", "3", "4", "5", "6"]
	probe.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: retry deadline or cheap-cohort progress failed")
	return ok


func _test_stale_seed_budget() -> bool:
	var controller := Controller.new()
	var backend := StaleSeedBackend.new()
	var effect := RetireEffect.new()
	controller._backend_terrain = backend
	controller._effect = effect
	var stale_count := controller.RENDER_SUBMISSION_CAPACITY + 4
	var live_generation := 100
	for generation in range(stale_count):
		_add_prepared_seed(controller, generation)
	_add_prepared_seed(controller, live_generation)
	controller._drain_activation_cohort_retries()
	var ok := backend.queries.size() == controller.RENDER_SUBMISSION_CAPACITY \
		and effect.retired.size() == controller.RENDER_SUBMISSION_CAPACITY
	controller._drain_activation_cohort_retries()
	ok = ok and backend.queries.size() == stale_count + 1 \
		and backend.queries[-1] == live_generation \
		and effect.retired.size() == stale_count \
		and controller._activation_stale_seed_skips == stale_count \
		and controller._activation_retry_membership.size() == 1 \
		and controller._activation_retry_membership.has(str(live_generation))
	controller._process_frame += 2
	controller._drain_activation_cohort_retries()
	ok = ok and backend.queries.size() == stale_count + 2 \
		and effect.retired.size() == stale_count
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: stale seed cleanup consumed live selection budget or exceeded bound queries=%s retired=%s skips=%d membership=%s normal_queue=%s interaction_queue=%s" % [str(backend.queries), str(effect.retired), controller._activation_stale_seed_skips, str(controller._activation_retry_membership), str(controller._activation_retry_queue), str(controller._activation_collision_retry_queue)])
	controller.free()
	backend.free()
	return ok


func _test_shared_wait_coalescing() -> bool:
	var controller := Controller.new()
	var backend := SharedWaitBackend.new()
	controller._backend_terrain = backend
	for generation in range(8):
		_add_prepared_seed(controller, generation + 1)
	controller._drain_activation_cohort_retries()
	controller._process_frame += controller.ACTIVATION_WAIT_BACKGROUND_PROBE_FRAMES
	controller._drain_activation_cohort_retries()
	var learned_queries := backend.queries
	controller._process_frame += controller.ACTIVATION_WAIT_BACKGROUND_PROBE_FRAMES
	controller._drain_activation_cohort_retries()
	var ok := learned_queries == 8 and backend.queries == learned_queries + 1 \
		and controller._activation_cohort_retry_coalesced >= 7 \
		and controller._activation_retry_membership.size() == 8
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: shared regional blocker was polled once per seed queries=%d learned=%d coalesced=%d membership=%d" % [backend.queries, learned_queries, controller._activation_cohort_retry_coalesced, controller._activation_retry_membership.size()])
	controller.free()
	backend.free()
	return ok


func _add_prepared_seed(controller: Node, generation: int) -> void:
	var key := str(generation)
	controller._groups[key] = {
		"native_prepared": true, "validated": true,
		"native_validated": {"terrain": true},
		"requests": {"terrain": {"identity": {"generation": generation}}},
	}
	controller._queue_activation_cohort_retry(key)


func _test_initial_activation_budget() -> bool:
	var probe := RetryProbe.new()
	var capacity: int = probe.ACTIVATION_COHORT_RETRY_CAPACITY
	var backend := PreparationBackend.new()
	probe._backend_terrain = backend
	probe.add_waiting("older")
	for index in range(8):
		var key := str(index)
		var identity := {"page_x": index, "generation": index + 1, "surface": "terrain"}
		probe._groups[key] = {
			"requests": {"terrain": {"identity": identity}},
			"prepared": {"terrain": true},
			"native_validated": {"terrain": true},
		}
		probe._try_validate_group(key)
		probe._try_validate_group(key)
	var unbudgeted_calls := probe.visited.size()
	var ok := unbudgeted_calls == 0 and backend.preparations == 8 \
		and probe._activation_retry_membership.size() == 9 \
		and probe._prepared_group_routes.size() == 8
	probe._retry_prepared_groups()
	probe._drain_activation_cohort_retries()
	var expected_first: Array[String] = ["older"]
	for index in range(capacity - 1):
		expected_first.append(str(index))
	ok = ok and probe.visited == expected_first
	var retiring_key := str(capacity - 1)
	probe._groups[retiring_key]["retiring"] = true
	probe._drain_activation_cohort_retries()
	var expected_second := expected_first.duplicate()
	for index in range(capacity, capacity * 2):
		expected_second.append(str(index))
	ok = ok and probe.visited == expected_second \
		and not probe._activation_retry_membership.has(retiring_key)
	probe.free()
	backend.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: initial activation budget; unbudgeted_calls=%d" % unbudgeted_calls)
	return ok


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
	var request := _resident_request(identity)
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


func _resident_request(identity: Dictionary) -> Dictionary:
	return {
		"schema": "world_transvoxel.gpu_resident_render_request.v7",
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


func _test_empty_admission_budget() -> bool:
	var ok := true
	for empty_count in [0, 8, 20]:
		var controller := Controller.new()
		var backend := RetiringAdmissionBackend.new()
		var effect := RetiringAdmissionEffect.new()
		controller._backend_terrain = backend
		controller._effect = effect
		controller._resident_capacity = 64
		for index in range(empty_count + controller.NATIVE_SUBMISSIONS_PER_FRAME):
			var request := _resident_request({
				"generation": index + 1, "page_x": index,
				"surface": "terrain", "input_stage": "pre_mesh_field",
			})
			request["request_id"] = index + 1
			request["proven_empty"] = index < empty_count
			if bool(request["proven_empty"]):
				request["gpu_input_buffers"] = []
				request["packed_byte_count"] = 0
			backend.pending.append(request)
		controller._submit_native_captures()
		var expected := controller.NATIVE_SUBMISSIONS_PER_FRAME
		ok = ok and effect.submissions == expected and backend.rejections.is_empty() \
			and controller._render_request_routes.size() == expected \
			and effect.submissions - effect.empty_submissions <= controller.NATIVE_SUBMISSIONS_PER_FRAME
		controller.free()
		backend.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: empty admission or extraction budget")
	return ok


func _test_candidate_generation_headroom() -> bool:
	var controller := Controller.new()
	var backend := RetiringAdmissionBackend.new()
	var effect := RetiringAdmissionEffect.new()
	controller._backend_terrain = backend
	controller._effect = effect
	controller._resident_capacity = 4
	for index in range(4):
		controller._groups["active:%d" % index] = {
			"active": true,
			"retiring": false,
		}
		var request := _resident_request({
			"generation": index + 1,
			"page_x": index + 100,
			"surface": "terrain",
			"input_stage": "pre_mesh_field",
		})
		request["request_id"] = index + 1
		backend.pending.append(request)
	controller._submit_native_captures()
	var ok := controller._tracked_group_capacity() == 8 \
			and controller._groups.size() == 8 \
			and effect.submissions == 4 \
			and backend.rejections.is_empty()
	controller.free()
	backend.free()
	if not ok:
		push_error("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_FAIL: candidate generation headroom")
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
	effect._arena = VisibilityArenaStub.new()
	var entries: Array = []
	for index in range(64):
		var identity := {"surface": "terrain", "page_x": index, "lod": index % 4}
		var key := effect._identity_key(identity)
		var token := effect._entry_token(key, 1)
		effect._latest_sequence_by_key[key] = 1
		effect._entries[token] = {
			"identity": identity,
			"publication_sequence": 1,
			"empty": true,
			"active": false,
		}
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
	var retired_per_callback: Array[int] = []
	for drain_index in range(4):
		var active_before := int(effect.get_status().get("active_entry_count", -1))
		effect._drain_lifecycle_commands_on_render_thread()
		var active_after := int(effect.get_status().get("active_entry_count", -1))
		retired_per_callback.append(active_before - active_after)
	status = effect.get_status()
	ok = ok and retired_per_callback == [16, 16, 16, 16] \
		and int(status.get("active_inventory_rebuilds", 0)) == 5 \
		and int(status.get("active_entry_count", -1)) == 0 \
		and int(status.get("active_empty_entry_count", -1)) == 0 \
		and int(status.get("pending_lifecycle_command_count", -1)) == 0 \
		and int(status.get("lifecycle_command_budget_deferrals", 0)) == 3
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
	if not waited or not committed:
		push_error(
			"regional commit barrier mismatch: waited=%s committed=%s queries=%d commits=%d submitted=%d group=%s"
			% [waited, committed, backend.queries, backend.commits, effect.submitted_entries, str(controller._groups.get("0", {}))]
		)
		controller.free()
		backend.free()
		return false
	controller.free()
	backend.free()
	return true


func _test_committed_cohort_supersession() -> bool:
	var controller := Controller.new()
	var effect := RetireEffect.new()
	var backend := AdmissionBackend.new()
	controller._effect = effect
	controller._backend_terrain = backend
	controller._activation_cohorts[7] = {
		"native_committed": true,
		"group_keys": ["left", "right"],
	}
	for index in range(2):
		var key := "left" if index == 0 else "right"
		controller._groups[key] = {
			"active": false,
			"native_active": true,
			"activation_queued": true,
			"activation_cohort_id": 7,
			"requests": {"terrain": {"identity": {"generation": index + 1}}},
			"sequences": {"terrain": index + 1},
			"activated": {"terrain": true},
		}
	controller._groups["left"]["retiring"] = true
	controller._groups["left"]["retired"] = {"terrain": true}
	controller._try_finish_retirement("left")
	var retained := controller._activation_cohorts.has(7) \
		and controller._groups.has("left") and controller._groups.has("right") \
		and bool(controller._groups["left"].get("retire_after_activation", false)) \
		and not bool(controller._groups["left"].get("retiring", false))
	controller._try_finish_activation_cohort("right")
	var retired_after_callback := not controller._activation_cohorts.has(7) \
		and bool(controller._groups["left"].get("retiring", false)) \
		and bool(controller._groups["right"].get("active", false)) \
		and effect.retired == [1]
	if not retained or not retired_after_callback:
		push_error(
			"committed cohort supersession mismatch: retained=%s retired=%s groups=%s cohorts=%s"
			% [retained, retired_after_callback, str(controller._groups), str(controller._activation_cohorts)]
		)
		controller.free()
		backend.free()
		return false
	controller.free()
	backend.free()
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
