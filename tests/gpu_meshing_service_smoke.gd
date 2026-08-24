extends SceneTree

const GpuMeshingService := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_service.gd"
)
const MAXIMUM_VECTOR_DIFFERENCE := 0.00001

var _service


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("WorldTransvoxelCellProbe"):
		_fail("WorldTransvoxelCellProbe is unavailable")
		return
	var probe := ClassDB.instantiate("WorldTransvoxelCellProbe") as RefCounted
	if probe == null:
		_fail("WorldTransvoxelCellProbe could not be instantiated")
		return
	var capture: Dictionary = probe.call(
		"capture_chunk_cells_with_callable",
		Callable(self, "_chunk_sample"),
		Vector3i.ZERO,
		1,
		1 << 5,
		1 << 5,
		0.0,
		0.25
	)
	if not bool(capture.get("ok", false)):
		_fail("native chunk cell capture failed: %s" % capture.get("error", ""))
		return
	var batch: Dictionary = capture.get("cell_batch", {})
	if int(batch.get("cell_count", 0)) != 4352:
		_fail("captured production chunk cell inventory changed")
		return
	_service = GpuMeshingService.new()
	if not _service.start():
		_fail("GPU meshing service did not start: %s" % _service.get_last_error())
		return
	var identity := {
		"page_x": 0,
		"page_y": 0,
		"page_z": 0,
		"lod": 1,
		"generation": 101,
		"source_revision": 0x100000029,
		"world_revision": 0x20000004d,
		"transition_mask": 1 << 5,
		"field_mode": 0,
		"sample_count": int(batch.get("sample_value_count", 0)),
	}
	var request_id: int = int(_service.submit_explicit_samples(
		batch.get("densities", PackedFloat32Array()),
		batch.get("gradients", PackedVector3Array()),
		batch.get("materials", PackedInt32Array()),
		batch.get("material_authored", PackedByteArray()),
		batch.get("cells", []),
		identity
	))
	if request_id <= 0:
		_fail("GPU meshing request was rejected: %s" % _service.get_last_error())
		return
	var service_status: Dictionary = _service.get_status()
	if bool(service_status.get("frame_thread_compute_sync", true)) \
			or bool(service_status.get("cpu_meshing_fallback", true)):
		_fail("GPU service violated its execution or fallback contract")
		return
	var completion := await _wait_for_completion(request_id, 30.0)
	if completion.is_empty():
		_fail("GPU meshing request timed out")
		return
	if str(completion.get("status", "")) != "PASS" \
			or bool(completion.get("fallback_used", true)) \
			or bool(completion.get("cpu_meshing_used", true)) \
			or bool(completion.get("frame_thread_compute_sync", true)):
		_fail("GPU meshing request failed: %s" % completion.get("failures", []))
		return
	if Dictionary(completion.get("identity", {})) != identity:
		_fail("GPU meshing request identity changed")
		return
	var gpu_cells: Array = completion.get("cells", [])
	var authority_cells: Array = batch.get("authority_cells", [])
	if gpu_cells.size() != authority_cells.size():
		_fail("GPU and authority cell counts differ")
		return
	for index in range(gpu_cells.size()):
		var comparison := _compare_cell(authority_cells[index], gpu_cells[index])
		if not comparison.is_empty():
			_fail("cell %d differs: %s" % [index, comparison])
			return
	var replayed: Dictionary = probe.call(
		"finalize_chunk_with_gpu_cells_callable",
		Callable(self, "_chunk_sample"),
		Vector3i.ZERO,
		1,
		1 << 5,
		1 << 5,
		0.0,
		0.25,
		gpu_cells
	)
	if not bool(replayed.get("ok", false)) \
			or not bool(replayed.get("replay_complete", false)) \
			or bool(replayed.get("cpu_cell_geometry_fallback_used", true)):
		_fail("native GPU-cell finalization failed: %s" % replayed.get("replay_failure", ""))
		return
	if not _chunk_mesh_equal(capture.get("cpu_chunk", {}), replayed):
		_fail("GPU-cell native finalization changed chunk geometry")
		return
	var capacity_error := await _exercise_bounded_capacity(batch, identity)
	if not capacity_error.is_empty():
		_fail(capacity_error)
		return
	var timing: Dictionary = completion.get("timing_usec", {})
	_service.close()
	print(
		"GPU_MESHING_SERVICE_SMOKE_PASS cells=%d vertices=%d triangles=%d gpu_total_us=%d" % [
			gpu_cells.size(),
			int(completion.get("vertex_count", 0)),
			int(completion.get("triangle_count", 0)),
			int(timing.get("total", 0)),
		]
	)
	quit(0)


func _exercise_bounded_capacity(batch: Dictionary, identity: Dictionary) -> String:
	var densities: PackedFloat32Array = batch.get("densities", PackedFloat32Array())
	var gradients: PackedVector3Array = batch.get("gradients", PackedVector3Array())
	var materials: PackedInt32Array = batch.get("materials", PackedInt32Array())
	var authored: PackedByteArray = batch.get("material_authored", PackedByteArray())
	var cells: Array = batch.get("cells", [])
	var request_ids: Array[int] = []
	for _index in range(3):
		var request_id := int(_service.submit_explicit_samples(
			densities.slice(0, 8),
			gradients.slice(0, 8),
			materials.slice(0, 8),
			authored.slice(0, 8),
			[cells[0]],
			identity
		))
		if request_id <= 0:
			return "bounded GPU request %d was unexpectedly rejected" % _index
		request_ids.append(request_id)
	var overflow_id := int(_service.submit_explicit_samples(
		densities.slice(0, 8), gradients.slice(0, 8), materials.slice(0, 8),
		authored.slice(0, 8), [cells[0]], identity
	))
	if overflow_id != 0 or "capacity" not in _service.get_last_error().to_lower():
		return "GPU request capacity did not fail closed"
	var signature := ""
	for request_id in request_ids:
		var completion := await _wait_for_completion(request_id, 10.0)
		if str(completion.get("status", "")) != "PASS":
			return "bounded GPU request did not complete"
		if signature.is_empty():
			signature = str(completion.get("raw_signature", ""))
		elif str(completion.get("raw_signature", "")) != signature:
			return "bounded GPU request repeats were not deterministic"
	return ""


func _wait_for_completion(request_id: int, timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var completion: Dictionary = _service.take_completion(request_id)
		if not completion.is_empty():
			return completion
		await process_frame
	return {}


func _compare_cell(authority: Dictionary, candidate: Dictionary) -> String:
	for key in ["status", "case_code", "vertex_count", "index_count", "triangle_count"]:
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


func _maximum_vector_difference(
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


func _chunk_mesh_equal(left: Dictionary, right: Dictionary) -> bool:
	if left.get("regular", {}) != right.get("regular", {}):
		return false
	return Array(left.get("transitions", [])) == Array(right.get("transitions", []))


func _chunk_sample(point: Vector3i) -> Dictionary:
	var p := Vector3(point) - Vector3(8.0, 8.0, 8.0)
	var density := p.length() - 5.0
	return {
		"density": density,
		"material": 1 if density < 0.0 else 0,
		"material_authored": true,
	}


func _fail(message: String) -> void:
	if _service != null:
		_service.close()
	push_error("GPU_MESHING_SERVICE_SMOKE_FAIL: " + message)
	quit(1)
