@tool
extends RefCounted
class_name WtTerrainGpuMeshingService

const Candidate := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_candidate.gd"
)
const Differential := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_differential.gd"
)
const REQUEST_CAPACITY := 3

var _thread := Thread.new()
var _semaphore := Semaphore.new()
var _mutex := Mutex.new()
var _requests: Array[Dictionary] = []
var _completions: Array[Dictionary] = []
var _next_request_id := 1
var _active_request_id := 0
var _stopping := false
var _last_error := ""
var _resource_status: Dictionary = {}
var _submitted_request_count := 0
var _completed_request_count := 0
var _shadow_submission_count := 0
var _shadow_comparison_count := 0
var _shadow_comparison_failure_count := 0
var _last_shadow_comparison: Dictionary = {}


func start() -> bool:
	if _thread.is_started():
		return true
	_stopping = false
	_last_error = ""
	var error := _thread.start(Callable(self, "_worker_main"))
	if error != OK:
		_last_error = "could not start the dedicated GPU meshing worker: %s" % error_string(error)
		return false
	return true


func close() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stopping = true
	_requests.clear()
	_mutex.unlock()
	_semaphore.post()
	_thread.wait_to_finish()
	_mutex.lock()
	_active_request_id = 0
	_completions.clear()
	_mutex.unlock()


func submit_explicit_samples(
	densities: PackedFloat32Array,
	gradients: PackedVector3Array,
	materials: PackedInt32Array,
	material_authored: PackedByteArray,
	cells: Array,
	identity: Dictionary = {}
) -> int:
	return _submit_request(
		densities, gradients, materials, material_authored, cells, identity,
		[], true, false
	)


func submit_shadow_samples(
	densities: PackedFloat32Array,
	gradients: PackedVector3Array,
	materials: PackedInt32Array,
	material_authored: PackedByteArray,
	cells: Array,
	authority_cells: Array,
	identity: Dictionary = {}
) -> int:
	if authority_cells.size() != cells.size():
		_mutex.lock()
		_last_error = "GPU shadow authority inventory differs from cell inventory"
		_mutex.unlock()
		return 0
	return _submit_request(
		densities, gradients, materials, material_authored, cells, identity,
		authority_cells, false, true
	)


func _submit_request(
	densities: PackedFloat32Array,
	gradients: PackedVector3Array,
	materials: PackedInt32Array,
	material_authored: PackedByteArray,
	cells: Array,
	identity: Dictionary,
	authority_cells: Array,
	retain_candidate_cells: bool,
	immutable_handoff: bool
) -> int:
	if not _thread.is_started() and not start():
		return 0
	if densities.is_empty() or gradients.size() != densities.size() \
			or materials.size() != densities.size() \
			or material_authored.size() != densities.size() or cells.is_empty():
		_mutex.lock()
		_last_error = "GPU meshing request arrays are invalid"
		_mutex.unlock()
		return 0
	_mutex.lock()
	var outstanding := _requests.size() + _completions.size()
	if _active_request_id != 0:
		outstanding += 1
	if _stopping or outstanding >= REQUEST_CAPACITY:
		_last_error = "GPU meshing request capacity is exhausted"
		_mutex.unlock()
		return 0
	var request_id := _next_request_id
	_next_request_id += 1
	var request := {
		"request_id": request_id,
		"densities": densities if immutable_handoff else densities.duplicate(),
		"gradients": gradients if immutable_handoff else gradients.duplicate(),
		"materials": materials if immutable_handoff else materials.duplicate(),
		"material_authored": material_authored \
			if immutable_handoff else material_authored.duplicate(),
		"cells": cells if immutable_handoff else cells.duplicate(true),
		"authority_cells": authority_cells,
		"retain_candidate_cells": retain_candidate_cells,
		"immutable_handoff": immutable_handoff,
		"identity": identity.duplicate(true),
	}
	_requests.append(request)
	_submitted_request_count += 1
	if immutable_handoff:
		_shadow_submission_count += 1
	_last_error = ""
	_mutex.unlock()
	_semaphore.post()
	return request_id


func take_completion(request_id: int) -> Dictionary:
	_mutex.lock()
	for index in range(_completions.size()):
		if int(_completions[index].get("request_id", 0)) == request_id:
			var completion := _completions[index]
			_completions.remove_at(index)
			_mutex.unlock()
			return completion
	_mutex.unlock()
	return {}


func pop_completion() -> Dictionary:
	_mutex.lock()
	if _completions.is_empty():
		_mutex.unlock()
		return {}
	var completion := _completions.pop_front()
	_mutex.unlock()
	return completion


func get_status() -> Dictionary:
	_mutex.lock()
	var result := {
		"schema": "world_transvoxel.terrain.gpu_meshing_service_status.v1",
		"started": _thread.is_started(),
		"stopping": _stopping,
		"request_capacity": REQUEST_CAPACITY,
		"queued_requests": _requests.size(),
		"queued_completions": _completions.size(),
		"active_request_id": _active_request_id,
		"execution_thread": "dedicated_gpu_worker",
		"frame_thread_compute_sync": false,
		"cpu_meshing_fallback": false,
		"persistent_resources": _resource_status.duplicate(true),
		"submitted_request_count": _submitted_request_count,
		"completed_request_count": _completed_request_count,
		"shadow_submission_count": _shadow_submission_count,
		"shadow_comparison_count": _shadow_comparison_count,
		"shadow_comparison_failure_count": _shadow_comparison_failure_count,
		"last_shadow_comparison": _last_shadow_comparison.duplicate(true),
		"immutable_shadow_handoff": true,
		"worker_side_shadow_differential": true,
		"last_error": _last_error,
	}
	_mutex.unlock()
	return result


func get_last_error() -> String:
	_mutex.lock()
	var result := _last_error
	_mutex.unlock()
	return result


func _worker_main() -> void:
	var candidate = Candidate.new()
	while true:
		_semaphore.wait()
		_mutex.lock()
		if _stopping:
			_mutex.unlock()
			break
		if _requests.is_empty():
			_mutex.unlock()
			continue
		var request := _requests.pop_front()
		_active_request_id = int(request.get("request_id", 0))
		_mutex.unlock()
		var result: Dictionary = candidate.mesh_explicit_samples(
			request.get("densities", PackedFloat32Array()),
			request.get("gradients", PackedVector3Array()),
			request.get("materials", PackedInt32Array()),
			request.get("material_authored", PackedByteArray()),
			request.get("cells", []),
			request.get("identity", {})
		)
		result["request_id"] = _active_request_id
		result["service_identity"] = Dictionary(request.get("identity", {})).duplicate(true)
		result["service_schema"] = "world_transvoxel.terrain.gpu_meshing_service.v1"
		result["execution_thread"] = "dedicated_gpu_worker"
		result["frame_thread_compute_sync"] = false
		var authority_cells: Array = request.get("authority_cells", [])
		if not authority_cells.is_empty():
			var comparison := Differential.compare_cells(
				authority_cells, result.get("cells", [])
			)
			result["shadow_comparison"] = comparison
			if not bool(request.get("retain_candidate_cells", true)):
				result.erase("cells")
		_mutex.lock()
		_resource_status = candidate.get_resource_status().duplicate(true)
		_completed_request_count += 1
		if not authority_cells.is_empty():
			_shadow_comparison_count += 1
			_last_shadow_comparison = Dictionary(
				result.get("shadow_comparison", {})
			).duplicate(true)
			if str(result.get("shadow_comparison", {}).get("status", "")) != "PASS":
				_shadow_comparison_failure_count += 1
		_completions.append(result)
		_active_request_id = 0
		if str(result.get("status", "")) != "PASS":
			_last_error = str(result.get("failures", ["GPU meshing request failed"]))
		elif str(result.get("shadow_comparison", {"status": "PASS"}).get(
			"status", ""
		)) != "PASS":
			_last_error = JSON.stringify(result.get("shadow_comparison", {}))
		_mutex.unlock()
	candidate.close()
