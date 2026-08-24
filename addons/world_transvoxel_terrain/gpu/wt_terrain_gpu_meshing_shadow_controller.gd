@tool
extends Node
class_name WtTerrainGpuMeshingShadowController

const GpuMeshingService := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_service.gd"
)
const REQUIRED_BACKEND_METHODS := [
	"begin_gpu_meshing_shadow",
	"end_gpu_meshing_shadow",
	"pop_gpu_meshing_shadow_request",
	"complete_gpu_meshing_shadow_request",
	"get_gpu_meshing_shadow_metrics",
]
const PUBLICATION_BACKEND_METHODS := [
	"begin_gpu_meshing_publication",
	"complete_gpu_meshing_publication_request",
]

var _backend_terrain: Node
var _service
var _pending: Dictionary = {}
var _capacity := 3
var _service_capacity := 2
var _running := false
var _publish_matched := false
var _last_error := ""
var _submitted_results := 0
var _matched_results := 0
var _terrain_matched_results := 0
var _static_water_matched_results := 0
var _transition_matched_results := 0
var _mismatched_results := 0
var _stale_results := 0
var _identity_rejections := 0
var _publication_queued := 0
var _publication_rejections := 0
var _publication_stale_skips := 0


func _ready() -> void:
	set_process(false)


func start(
	backend_terrain: Node, capacity: int = 3, publish_matched: bool = false
) -> bool:
	if _running:
		return true
	if backend_terrain == null:
		_last_error = "native terrain backend is unavailable"
		return false
	for method_name in REQUIRED_BACKEND_METHODS:
		if not backend_terrain.has_method(method_name):
			_last_error = "native terrain backend lacks %s" % method_name
			return false
	if publish_matched:
		for method_name in PUBLICATION_BACKEND_METHODS:
			if not backend_terrain.has_method(method_name):
				_last_error = "native terrain backend lacks %s" % method_name
				return false
	_capacity = clampi(capacity, 1, GpuMeshingService.REQUEST_CAPACITY)
	_service_capacity = maxi(1, _capacity - 1)
	_service = GpuMeshingService.new()
	if not _service.start():
		_last_error = _service.get_last_error()
		_service = null
		return false
	var begin_method := "begin_gpu_meshing_publication" \
		if publish_matched else "begin_gpu_meshing_shadow"
	if not bool(backend_terrain.call(begin_method, _capacity)):
		_last_error = "native terrain backend rejected GPU meshing capture"
		_service.close()
		_service = null
		return false
	_backend_terrain = backend_terrain
	_publish_matched = publish_matched
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
	_publish_matched = false


func is_running() -> bool:
	return _running


func get_status() -> Dictionary:
	var native_metrics := {}
	var service_status := {}
	if _backend_terrain != null and is_instance_valid(_backend_terrain) \
			and _backend_terrain.has_method("get_gpu_meshing_shadow_metrics"):
		native_metrics = Dictionary(_backend_terrain.call("get_gpu_meshing_shadow_metrics"))
	if _service != null:
		service_status = _service.get_status()
	return {
		"schema": "world_transvoxel.terrain.gpu_meshing_shadow_controller.v1",
		"running": _running,
		"publish_matched": _publish_matched,
		"capacity": _capacity,
		"service_capacity": _service_capacity,
		"native_freshness_slot_reserved": _capacity > 1,
		"pending_results": _pending.size(),
		"submitted_results": _submitted_results,
		"matched_results": _matched_results,
		"terrain_matched_results": _terrain_matched_results,
		"static_water_matched_results": _static_water_matched_results,
		"transition_matched_results": _transition_matched_results,
		"mismatched_results": _mismatched_results,
		"stale_results": _stale_results,
		"identity_rejections": _identity_rejections,
		"publication_queued": _publication_queued,
		"publication_rejections": _publication_rejections,
		"publication_stale_skips": _publication_stale_skips,
		"last_error": _last_error,
		"native_metrics": native_metrics,
		"service_status": service_status,
		"cpu_render_authority": true,
		"cpu_collision_authority": true,
		"gpu_publication_enabled": _publish_matched,
		"gpu_resident_render_publication": false,
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
		var native_completion: Dictionary
		if _publish_matched:
			native_completion = Dictionary(_backend_terrain.call(
				"complete_gpu_meshing_publication_request",
				int(native_request.get("request_id", 0)),
				Dictionary(native_request.get("identity", {})),
				Array(completion.get("cells", [])),
				matched,
				comparison_error
			))
		else:
			native_completion = Dictionary(_backend_terrain.call(
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
		if _publish_matched and bool(native_completion.get("publication_queued", false)):
			_publication_queued += 1
		elif _publish_matched \
				and str(native_completion.get("publication_status", "")) \
				== "STALE_APPLICATION":
			_publication_stale_skips += 1
		elif _publish_matched and status == "MATCHED":
			_publication_rejections += 1
		if not matched or status not in ["MATCHED", "STALE"]:
			_last_error = comparison_error if not comparison_error.is_empty() \
				else str(native_completion.get("error", "GPU shadow completion failed"))


func _submit_captures() -> void:
	while _pending.size() < _service_capacity:
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
		var service_request_id := int(_service.submit_shadow_samples(
			batch.get("densities", PackedFloat32Array()),
			batch.get("gradients", PackedVector3Array()),
			batch.get("materials", PackedInt32Array()),
			batch.get("material_authored", PackedByteArray()),
			batch.get("cells", []),
			batch.get("authority_cells", []),
			identity,
			_publish_matched
		))
		if service_request_id <= 0:
			_complete_rejected_native_request(native_request, _service.get_last_error())
			return
		_pending[service_request_id] = native_request
		_submitted_results += 1


func _complete_rejected_native_request(request: Dictionary, error: String) -> void:
	_last_error = error
	_mismatched_results += 1
	if _publish_matched:
		_publication_rejections += 1
		_backend_terrain.call(
			"complete_gpu_meshing_publication_request",
			int(request.get("request_id", 0)),
			Dictionary(request.get("identity", {})),
			[],
			false,
			error
		)
	else:
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
			or bool(request.get("gpu_publication_enabled", false)) != _publish_matched:
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
	var comparison: Dictionary = completion.get("shadow_comparison", {})
	if str(comparison.get("schema", "")) \
			!= "world_transvoxel.terrain.gpu_meshing_differential.v1" \
			or str(comparison.get("status", "")) != "PASS" \
			or not bool(comparison.get("matched", false)):
		return "GPU worker differential failed: %s" % JSON.stringify(comparison)
	return ""
