@tool
extends RefCounted
class_name WtTerrainGpuMeshingService

const Candidate := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_candidate.gd"
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
	_requests.append({
		"request_id": request_id,
		"densities": densities.duplicate(),
		"gradients": gradients.duplicate(),
		"materials": materials.duplicate(),
		"material_authored": material_authored.duplicate(),
		"cells": cells.duplicate(true),
		"identity": identity.duplicate(true),
	})
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
		result["service_schema"] = "world_transvoxel.terrain.gpu_meshing_service.v1"
		result["execution_thread"] = "dedicated_gpu_worker"
		result["frame_thread_compute_sync"] = false
		_mutex.lock()
		_completions.append(result)
		_active_request_id = 0
		if str(result.get("status", "")) != "PASS":
			_last_error = str(result.get("failures", ["GPU meshing request failed"]))
		_mutex.unlock()
	candidate.close()
