extends SceneTree

const WaterfallRoute := preload("res://scripts/wt_terrain_waterfall_route.gd")
const Controller := preload("res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_render_controller.gd")

class AdmissionBackend:
	extends Node
	var commits := 0

	func get_gpu_resident_render_activation_cohort(_identity: Dictionary) -> Dictionary:
		return {"status": "READY", "ready": true, "regional": true}

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
	if not _test_activation_inventory():
		quit(1)
		return
	if not _test_regional_commit_barrier():
		quit(1)
		return
	if not _test_drain_gate():
		quit(1)
		return
	print("GPU_ACTIVATION_RETRY_FAIRNESS_SMOKE_PASS fair=1 bounded=1 deduplicated=1 cancelled=1 inflight_excluded=1 strict_drain=1")
	quit(0)


func _test_activation_inventory() -> bool:
	var probe := RetryProbe.new()
	for index in range(3):
		probe._groups[str(index)] = {
			"native_prepared": true,
			"native_active": index > 0,
			"active": index == 2,
			"activation_queued": index == 1,
			"water_expected": false,
			"prepared": {"terrain": true},
			"requests": {"terrain": {"identity": {"generation": index + 1}}},
		}
	var inventory: Array = probe._prepared_inventory_pool()
	probe.free()
	if inventory.size() != 2 \
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
