@tool
extends Node
class_name WtTerrainGpuMeshingShadowController

const GpuMeshingService := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_service.gd"
)
const MAXIMUM_VECTOR_DIFFERENCE := 0.00001
const REQUIRED_BACKEND_METHODS := [
	"begin_gpu_meshing_shadow",
	"end_gpu_meshing_shadow",
	"pop_gpu_meshing_shadow_request",
	"complete_gpu_meshing_shadow_request",
	"get_gpu_meshing_shadow_metrics",
]

var _backend_terrain: Node
var _service
var _pending: Dictionary = {}
var _capacity := 3
var _running := false
var _last_error := ""
var _submitted_results := 0
var _matched_results := 0
var _terrain_matched_results := 0
var _static_water_matched_results := 0
var _transition_matched_results := 0
var _mismatched_results := 0
var _stale_results := 0
var _identity_rejections := 0


func _ready() -> void:
	set_process(false)


func start(backend_terrain: Node, capacity: int = 3) -> bool:
	if _running:
		return true
	if backend_terrain == null:
		_last_error = "native terrain backend is unavailable"
		return false
	for method_name in REQUIRED_BACKEND_METHODS:
		if not backend_terrain.has_method(method_name):
			_last_error = "native terrain backend lacks %s" % method_name
			return false
	_capacity = clampi(capacity, 1, GpuMeshingService.REQUEST_CAPACITY)
	_service = GpuMeshingService.new()
	if not _service.start():
		_last_error = _service.get_last_error()
		_service = null
		return false
	if not bool(backend_terrain.call("begin_gpu_meshing_shadow", _capacity)):
		_last_error = "native terrain backend rejected GPU shadow capture"
		_service.close()
		_service = null
		return false
	_backend_terrain = backend_terrain
	_pending.clear()
	_running = true
	_last_error = ""
	set_process(true)
	return true


func stop() -> void:
	set_process(false)
	_running = false
	if _backend_terrain != null and is_instance_valid(_backend_terrain) \
			and _backend_terrain.has_method("end_gpu_meshing_shadow"):
		_backend_terrain.call("end_gpu_meshing_shadow")
	if _service != null:
		_service.close()
	_pending.clear()
	_service = null
	_backend_terrain = null


func is_running() -> bool:
	return _running


func get_status() -> Dictionary:
	var native_metrics := {}
	if _backend_terrain != null and is_instance_valid(_backend_terrain) \
			and _backend_terrain.has_method("get_gpu_meshing_shadow_metrics"):
		native_metrics = Dictionary(_backend_terrain.call("get_gpu_meshing_shadow_metrics"))
	return {
		"schema": "world_transvoxel.terrain.gpu_meshing_shadow_controller.v1",
		"running": _running,
		"capacity": _capacity,
		"pending_results": _pending.size(),
		"submitted_results": _submitted_results,
		"matched_results": _matched_results,
		"terrain_matched_results": _terrain_matched_results,
		"static_water_matched_results": _static_water_matched_results,
		"transition_matched_results": _transition_matched_results,
		"mismatched_results": _mismatched_results,
		"stale_results": _stale_results,
		"identity_rejections": _identity_rejections,
		"last_error": _last_error,
		"native_metrics": native_metrics,
		"cpu_render_authority": true,
		"cpu_collision_authority": true,
		"gpu_publication_enabled": false,
	}


func _process(_delta: float) -> void:
	if not _running or _service == null or _backend_terrain == null \
			or not is_instance_valid(_backend_terrain):
		return
	_drain_completions()
	_submit_captures()


func _drain_completions() -> void:
	while true:
		var completion: Dictionary = _service.pop_completion()
		if completion.is_empty():
			return
		var service_request_id := int(completion.get("request_id", 0))
		if not _pending.has(service_request_id):
			_last_error = "GPU service returned an unknown request"
			continue
		var native_request: Dictionary = _pending[service_request_id]
		_pending.erase(service_request_id)
		var comparison_error := _validate_completion(native_request, completion)
		var matched := comparison_error.is_empty()
		var native_completion := Dictionary(_backend_terrain.call(
			"complete_gpu_meshing_shadow_request",
			int(native_request.get("request_id", 0)),
			Dictionary(native_request.get("identity", {})),
			matched,
			comparison_error
		))
		var status := str(native_completion.get("status", ""))
		match status:
			"MATCHED":
				_matched_results += 1
				var identity: Dictionary = native_request.get("identity", {})
				if str(identity.get("surface", "")) == "static_water":
					_static_water_matched_results += 1
				else:
					_terrain_matched_results += 1
				if int(identity.get("transition_mask", 0)) != 0:
					_transition_matched_results += 1
			"MISMATCHED":
				_mismatched_results += 1
			"STALE":
				_stale_results += 1
			"IDENTITY_MISMATCH":
				_identity_rejections += 1
		if not matched or status not in ["MATCHED", "STALE"]:
			_last_error = comparison_error if not comparison_error.is_empty() \
				else str(native_completion.get("error", "GPU shadow completion failed"))


func _submit_captures() -> void:
	while _pending.size() < _capacity:
		var native_request := Dictionary(
			_backend_terrain.call("pop_gpu_meshing_shadow_request")
		)
		if str(native_request.get("status", "")) == "EMPTY":
			return
		var request_error := _validate_native_request(native_request)
		if not request_error.is_empty():
			_complete_rejected_native_request(native_request, request_error)
			continue
		var batch: Dictionary = native_request.get("cell_batch", {})
		var identity: Dictionary = native_request.get("identity", {})
		var service_request_id := int(_service.submit_explicit_samples(
			batch.get("densities", PackedFloat32Array()),
			batch.get("gradients", PackedVector3Array()),
			batch.get("materials", PackedInt32Array()),
			batch.get("material_authored", PackedByteArray()),
			batch.get("cells", []),
			identity
		))
		if service_request_id <= 0:
			_complete_rejected_native_request(native_request, _service.get_last_error())
			return
		_pending[service_request_id] = native_request
		_submitted_results += 1


func _complete_rejected_native_request(request: Dictionary, error: String) -> void:
	_last_error = error
	_mismatched_results += 1
	_backend_terrain.call(
		"complete_gpu_meshing_shadow_request",
		int(request.get("request_id", 0)),
		Dictionary(request.get("identity", {})),
		false,
		error
	)


func _validate_native_request(request: Dictionary) -> String:
	if str(request.get("schema", "")) != "world_transvoxel.gpu_meshing_shadow_request.v1" \
			or str(request.get("status", "")) != "PASS":
		return "native GPU shadow request contract failed"
	if not bool(request.get("cpu_render_publication_unchanged", false)) \
			or not bool(request.get("cpu_collision_publication_unchanged", false)) \
			or bool(request.get("gpu_publication_enabled", true)):
		return "native GPU shadow request violated CPU publication authority"
	var batch: Dictionary = request.get("cell_batch", {})
	if str(batch.get("status", "")) != "PASS" or bool(batch.get("fallback_used", true)) \
			or not bool(batch.get("cpu_cell_authority_used", false)):
		return "native GPU shadow cell batch is invalid"
	if Array(batch.get("cells", [])).size() != Array(batch.get("authority_cells", [])).size():
		return "native GPU shadow cell and authority inventories differ"
	return ""


func _validate_completion(request: Dictionary, completion: Dictionary) -> String:
	if str(completion.get("status", "")) != "PASS" \
			or bool(completion.get("fallback_used", true)) \
			or bool(completion.get("cpu_meshing_used", true)) \
			or bool(completion.get("frame_thread_compute_sync", true)):
		return "GPU shadow meshing failed: %s" % str(completion.get("failures", []))
	var expected_identity: Dictionary = request.get("identity", {})
	if Dictionary(completion.get("service_identity", {})) != expected_identity:
		return "GPU service changed the native shadow identity"
	var gpu_identity: Dictionary = completion.get("identity", {})
	for key in [
		"page_x", "page_y", "page_z", "lod", "generation", "source_revision",
		"world_revision", "transition_mask", "field_mode", "sample_count",
	]:
		if gpu_identity.get(key) != expected_identity.get(key):
			return "GPU result identity differs at %s" % key
	var batch: Dictionary = request.get("cell_batch", {})
	var gpu_cells: Array = completion.get("cells", [])
	var authority_cells: Array = batch.get("authority_cells", [])
	if gpu_cells.size() != authority_cells.size():
		return "GPU and CPU authority cell counts differ"
	for index in range(gpu_cells.size()):
		var difference := _compare_cell(authority_cells[index], gpu_cells[index])
		if not difference.is_empty():
			return "cell %d %s" % [index, difference]
	return ""


static func _compare_cell(authority: Dictionary, candidate: Dictionary) -> String:
	for key in [
		"id", "type", "orientation", "status", "case_code", "vertex_count",
		"index_count", "triangle_count",
	]:
		if authority.get(key) != candidate.get(key):
			return "%s differs" % key
	for key in [
		"backend_indices", "indices", "materials", "material_authored",
		"endpoint_a", "endpoint_b", "reuse_data",
	]:
		if PackedInt32Array(authority.get(key, PackedInt32Array())) \
				!= PackedInt32Array(candidate.get(key, PackedInt32Array())):
			return "%s differs" % key
	if _maximum_vector_difference(
		authority.get("vertices", PackedVector3Array()),
		candidate.get("vertices", PackedVector3Array())
	) > MAXIMUM_VECTOR_DIFFERENCE:
		return "vertices differ"
	if _maximum_vector_difference(
		authority.get("normals", PackedVector3Array()),
		candidate.get("normals", PackedVector3Array())
	) > MAXIMUM_VECTOR_DIFFERENCE:
		return "normals differ"
	return ""


static func _maximum_vector_difference(
	left: PackedVector3Array,
	right: PackedVector3Array
) -> float:
	if left.size() != right.size():
		return INF
	var maximum := 0.0
	for index in range(left.size()):
		var difference := (left[index] - right[index]).abs()
		maximum = maxf(maximum, maxf(difference.x, maxf(difference.y, difference.z)))
	return maximum
