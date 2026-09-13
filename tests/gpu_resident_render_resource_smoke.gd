extends SceneTree

const GpuMeshingService := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing_service.gd"
)

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
	var identity := {
		"page_x": 0,
		"page_y": 0,
		"page_z": 0,
		"lod": 1,
		"generation": 201,
		"source_revision": 0x300000029,
		"world_revision": 0x40000004d,
		"transition_mask": 1 << 5,
		"field_mode": 0,
		"sample_count": int(batch.get("sample_value_count", 0)),
	}
	_service = GpuMeshingService.new()
	if not _service.start():
		_fail("GPU meshing service did not start: %s" % _service.get_last_error())
		return
	var request_id := int(_service.submit_resident_resource_samples(
		batch.get("densities", PackedFloat32Array()),
		batch.get("gradients", PackedVector3Array()),
		batch.get("materials", PackedInt32Array()),
		batch.get("material_authored", PackedByteArray()),
		batch.get("cells", []),
		identity,
		Vector3(8.0, 8.0, 8.0),
		6.5,
		Vector2i(256, 256)
	))
	if request_id <= 0:
		_fail("GPU resident request was rejected: %s" % _service.get_last_error())
		return
	var completion := await _wait_for_completion(request_id, 30.0)
	if completion.is_empty():
		_fail("GPU resident request timed out")
		return
	if str(completion.get("status", "")) != "PASS":
		_fail("GPU resident request failed: %s" % completion.get("failures", []))
		return
	if str(completion.get("schema", "")) \
			!= "world_transvoxel.terrain.gpu_resident_render_resource.v1":
		_fail("GPU resident result schema changed")
		return
	if Dictionary(completion.get("identity", {})) != identity:
		_fail("GPU resident request identity changed")
		return
	if bool(completion.get("fallback_used", true)) \
			or bool(completion.get("cpu_meshing_used", true)) \
			or bool(completion.get("cpu_chunk_finalization_used", true)) \
			or bool(completion.get("array_mesh_upload_used", true)) \
			or int(completion.get("geometry_readback_bytes", -1)) != 0 \
			or not bool(completion.get("same_device_compute_raster", false)) \
			or not bool(completion.get("gpu_written_indirect_commands", false)) \
			or not bool(completion.get("gpu_resident_vertex_index_consumed", false)) \
			or not bool(completion.get("device_local_index_copy_used", false)) \
			or int(completion.get("geometry_device_local_copy_bytes", 0)) \
					!= 4352 * 36 * 4 \
			or bool(completion.get("local_device_screen_shareable", true)) \
			or bool(completion.get("production_scene_publication", true)) \
			or bool(completion.get("frame_thread_compute_sync", true)):
		_fail("GPU resident execution contract failed: %s" % str(completion))
		return
	var raster: Dictionary = completion.get("raster", {})
	if str(raster.get("status", "")) != "PASS" \
			or int(raster.get("indirect_draw_count", 0)) != 4352 \
			or int(raster.get("indirect_draw_stride_bytes", 0)) != 20 \
			or int(raster.get("render_target_readback_bytes", 0)) != 256 * 256 * 4 \
			or int(raster.get("geometry_device_local_copy_bytes", 0)) \
					!= 4352 * 36 * 4 \
			or not bool(raster.get("device_local_index_copy_used", false)) \
			or bool(raster.get("direct_index_storage_alias_supported", true)) \
			or int(raster.get("foreground_pixel_count", 0)) < 16 \
			or float(raster.get("foreground_coverage", 0.0)) <= 0.0 \
			or str(raster.get("image_sha256", "")).length() != 64:
		_fail("GPU resident raster proof failed: %s" % str(raster))
		return
	var service_status: Dictionary = _service.get_status()
	var resources: Dictionary = service_status.get("persistent_resources", {})
	if str(service_status.get("execution_thread", "")) != "dedicated_gpu_worker" \
			or bool(service_status.get("frame_thread_compute_sync", true)) \
			or int(service_status.get("resident_submission_count", 0)) != 1 \
			or int(service_status.get("resident_completion_count", 0)) != 1 \
			or int(resources.get("buffer_count", 0)) != 22 \
			or int(resources.get("render_consumable_vertex_buffers", 0)) != 3 \
			or int(resources.get("render_consumable_index_buffers", 0)) != 1 \
			or not bool(resources.get("gpu_written_indirect_buffer", false)) \
			or not bool(resources.get("device_local_index_copy_required", false)) \
			or bool(resources.get("direct_index_storage_alias_supported", true)) \
			or int(resources.get("readback_bytes", -1)) != 0 \
			or int(resources.get("render_target_readback_bytes", 0)) != 256 * 256 * 4 \
			or bool(resources.get("gpu_resident_render_publication", true)):
		_fail("GPU resident resource inventory failed: %s" % str(service_status))
		return
	_service.close()
	print(
		"GPU_RESIDENT_RENDER_RESOURCE_SMOKE_PASS cells=%d indirect_draws=%d foreground_pixels=%d coverage=%.6f image_sha256=%s" % [
			int(completion.get("cell_count", 0)),
			int(raster.get("indirect_draw_count", 0)),
			int(raster.get("foreground_pixel_count", 0)),
			float(raster.get("foreground_coverage", 0.0)),
			str(raster.get("image_sha256", "")),
		]
	)
	quit(0)


func _wait_for_completion(request_id: int, timeout_seconds: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var completion: Dictionary = _service.take_completion(request_id)
		if not completion.is_empty():
			return completion
		await process_frame
	return {}


func _chunk_sample(point: Vector3i) -> Dictionary:
	var p := Vector3(point) - Vector3(8.0, 8.0, 8.0)
	var density := p.length() - 5.0
	return {
		"density": density,
		"material": 3 if density < 0.0 else 0,
		"material_authored": true,
	}


func _fail(message: String) -> void:
	if _service != null:
		_service.close()
	push_error("GPU_RESIDENT_RENDER_RESOURCE_SMOKE_FAIL: " + message)
	quit(1)
