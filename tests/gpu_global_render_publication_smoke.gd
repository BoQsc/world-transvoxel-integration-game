extends SceneTree

const GlobalRenderEffect := preload(
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_global_render_effect.gd"
)
const CAPTURE_ROOT := (
	"res://.godot/world_transvoxel_captures/gpu_global_render_publication"
)
const BACKGROUND := Color(0.01, 0.015, 0.02, 1.0)
const EXPECTED_CELL_COUNT := 4352

var _effect
var _world_environment: WorldEnvironment
var _camera: Camera3D


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
	if int(batch.get("cell_count", 0)) != EXPECTED_CELL_COUNT:
		_fail("captured production chunk cell inventory changed")
		return
	_setup_viewport()
	_effect = GlobalRenderEffect.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [_effect]
	_world_environment.compositor = compositor
	var identity := _identity(batch, 301, 0x50000002f, 0x600000055)
	var request_one := _submit(batch, identity, 1)
	if request_one <= 0:
		_fail("initial global publication request was rejected")
		return
	identity["generation"] = 302
	identity["source_revision"] = 0x500000030
	var request_two := _submit(batch, identity, 2)
	if request_two <= request_one:
		_fail("newer queued global publication request was rejected")
		return
	if not await _wait_for_status(
		func(status: Dictionary) -> bool:
			return int(status.get("applied", 0)) >= 1 \
				and int(status.get("stale_skips", 0)) >= 1 \
				and int(status.get("draw_frames", 0)) >= 2,
		30.0
	):
		_fail("queued publication did not reach the viewport: %s" % _effect.get_status())
		return
	identity["generation"] = 303
	identity["source_revision"] = 0x500000031
	var request_three := _submit(batch, identity, 3)
	if request_three <= request_two:
		_fail("superseding global publication request was rejected")
		return
	if not await _wait_for_status(
		func(status: Dictionary) -> bool:
			return int(status.get("applied", 0)) >= 2 \
				and int(status.get("superseded_entries", 0)) >= 1 \
				and int(status.get("draw_frames", 0)) >= 4,
		30.0
	):
		_fail("superseding publication did not reach the viewport: %s" % _effect.get_status())
		return
	if _submit(batch, identity, 2) != 0:
		_fail("stale publication sequence was accepted")
		return
	await RenderingServer.frame_post_draw
	var viewport_image := get_root().get_texture().get_image()
	if viewport_image == null or viewport_image.is_empty():
		_fail("live viewport capture is unavailable")
		return
	viewport_image.convert(Image.FORMAT_RGBA8)
	var foreground_pixels := _foreground_pixel_count(viewport_image)
	if foreground_pixels < 64:
		_fail("global resident mesh did not produce visible viewport pixels: %d" % foreground_pixels)
		return
	var driver := RenderingServer.get_current_rendering_driver_name().to_lower()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_ROOT))
	var capture_path := "%s/%s.png" % [CAPTURE_ROOT, driver]
	if viewport_image.save_png(capture_path) != OK:
		_fail("live viewport proof image could not be retained")
		return
	var image_sha256 := _sha256(viewport_image.get_data())
	var status: Dictionary = _effect.get_status()
	if str(status.get("schema", "")) \
			!= "world_transvoxel.terrain.gpu_global_render_publication.v1" \
			or not bool(status.get("initialized", false)) \
			or not bool(status.get("global_rendering_device", false)) \
			or not bool(status.get("render_thread_owned", false)) \
			or not bool(status.get("same_global_device_compute_raster", false)) \
			or str(status.get("compositor_callback", "")) != "pre_transparent" \
			or int(status.get("resident_buffer_count_per_entry", 0)) != 21 \
			or not bool(status.get("gpu_written_indirect_commands", false)) \
			or not bool(status.get("device_local_index_copy_used", false)) \
			or bool(status.get("fallback_used", true)) \
			or int(status.get("requested", 0)) != 3 \
			or int(status.get("applied", 0)) != 2 \
			or int(status.get("rejected", 0)) != 1 \
			or int(status.get("stale_skips", 0)) != 1 \
			or int(status.get("superseded_entries", 0)) != 1 \
			or int(status.get("resident_entry_count", 0)) != 1 \
			or int(status.get("queued_request_count", -1)) != 0 \
			or int(status.get("draw_frames", 0)) < 4 \
			or int(status.get("indirect_draw_calls", 0)) < 4 \
			or int(status.get("geometry_readback_bytes", -1)) != 0 \
			or int(status.get("render_target_readback_bytes", -1)) != 0 \
			or bool(status.get("cpu_meshing_used", true)) \
			or bool(status.get("cpu_chunk_finalization_used", true)) \
			or bool(status.get("array_mesh_upload_used", true)) \
			or not bool(status.get("cpu_collision_authority", false)) \
			or bool(status.get("production_chunk_replacement", true)) \
			or bool(status.get("production_material_parity", true)) \
			or not str(status.get("last_error", "")).contains("stale") \
			or Dictionary(status.get("last_applied_identity", {})) != identity:
		_fail("global publication contract failed: %s" % str(status))
		return
	var draw_frames := int(status.get("draw_frames", 0))
	var indirect_draw_calls := int(status.get("indirect_draw_calls", 0))
	_effect.close()
	_world_environment.compositor = null
	if not await _wait_for_status(
		func(closed_status: Dictionary) -> bool:
			return bool(closed_status.get("close_completed", false)) \
				and int(closed_status.get("resident_entry_count", -1)) == 0,
		10.0
	):
		_fail("global publication resources did not close")
		return
	print(
		(
			"GPU_GLOBAL_RENDER_PUBLICATION_SMOKE_PASS cells=%d applied=2 stale=1 " \
			+ "superseded=1 draw_frames=%d indirect_draw_calls=%d " \
			+ "foreground_pixels=%d image_sha256=%s"
		) % [
			EXPECTED_CELL_COUNT,
			draw_frames,
			indirect_draw_calls,
			foreground_pixels,
			image_sha256,
		]
	)
	quit(0)


func _setup_viewport() -> void:
	get_root().size = Vector2i(640, 480)
	get_root().content_scale_size = Vector2i(640, 480)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_world_environment = WorldEnvironment.new()
	_world_environment.environment = environment
	get_root().add_child(_world_environment)
	_camera = Camera3D.new()
	_camera.position = Vector3(8.0, 8.0, 25.0)
	get_root().add_child(_camera)
	_camera.look_at(Vector3(8.0, 8.0, 8.0), Vector3.UP)
	_camera.current = true


func _identity(
	batch: Dictionary,
	generation: int,
	source_revision: int,
	world_revision: int
) -> Dictionary:
	return {
		"page_x": 0,
		"page_y": 0,
		"page_z": 0,
		"lod": 1,
		"generation": generation,
		"source_revision": source_revision,
		"world_revision": world_revision,
		"transition_mask": 1 << 5,
		"field_mode": 0,
		"sample_count": int(batch.get("sample_value_count", 0)),
		"surface": "terrain",
	}


func _submit(batch: Dictionary, identity: Dictionary, sequence: int) -> int:
	return int(_effect.submit_explicit_samples(
		batch.get("densities", PackedFloat32Array()),
		batch.get("gradients", PackedVector3Array()),
		batch.get("materials", PackedInt32Array()),
		batch.get("material_authored", PackedByteArray()),
		batch.get("cells", []),
		identity,
		sequence
	))


func _wait_for_status(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call(_effect.get_status()):
			return true
		await process_frame
	return false


func _foreground_pixel_count(image: Image) -> int:
	var expected := BACKGROUND.to_rgba32()
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y).to_rgba32()
			if _color_distance(pixel, expected) > 24:
				count += 1
	return count


static func _color_distance(left: int, right: int) -> int:
	return abs(int((left >> 24) & 0xff) - int((right >> 24) & 0xff)) \
		+ abs(int((left >> 16) & 0xff) - int((right >> 16) & 0xff)) \
		+ abs(int((left >> 8) & 0xff) - int((right >> 8) & 0xff))


static func _sha256(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(data) != OK:
		return ""
	return context.finish().hex_encode()


func _chunk_sample(point: Vector3i) -> Dictionary:
	var p := Vector3(point) - Vector3(8.0, 8.0, 8.0)
	var density := p.length() - 5.0
	return {
		"density": density,
		"material": 3 if density < 0.0 else 0,
		"material_authored": true,
	}


func _fail(message: String) -> void:
	if _effect != null:
		_effect.close()
	push_error("GPU_GLOBAL_RENDER_PUBLICATION_SMOKE_FAIL: " + message)
	quit(1)
