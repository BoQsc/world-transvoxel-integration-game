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
				and (int(status.get("stale_skips", 0)) \
					+ int(status.get("cancelled_queued_requests", 0))) >= 1 \
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
	if not await _wait_for_status(
		func(compacted_status: Dictionary) -> bool:
			return int(compacted_status.get("compactions_completed", 0)) >= 1 \
				and int(compacted_status.get("pending_compaction_count", -1)) == 0,
		10.0
	):
		_fail("exact resident compaction did not finish: %s" % _effect.get_status())
		return
	await RenderingServer.frame_post_draw
	var viewport_image := get_root().get_texture().get_image()
	if viewport_image == null or viewport_image.is_empty():
		_fail("live viewport capture is unavailable")
		return
	viewport_image.convert(Image.FORMAT_RGBA8)
	var foreground_pixels := _foreground_pixel_count(viewport_image)
	if foreground_pixels < 64:
		_fail("global resident mesh did not produce visible viewport pixels: %d status=%s" % [
			foreground_pixels, str(_effect.get_status()),
		])
		return
	var driver := RenderingServer.get_current_rendering_driver_name().to_lower()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_ROOT))
	var capture_path := "%s/%s.png" % [CAPTURE_ROOT, driver]
	if viewport_image.save_png(capture_path) != OK:
		_fail("live viewport proof image could not be retained")
		return
	var image_sha256 := _sha256(viewport_image.get_data())
	_camera.position = Vector3(8.0, 8.0, 40.0)
	_camera.look_at(Vector3(8.0, 8.0, 8.0), Vector3.UP)
	if not await _wait_for_status(
		func(outside_visible_status: Dictionary) -> bool:
			return int(outside_visible_status.get("last_visible_surface_count", 0)) >= 1,
		10.0
	):
		_fail("resident surface was not visible from outside its bounds")
		return
	_camera.look_at(Vector3(8.0, 8.0, 60.0), Vector3.UP)
	if not await _wait_for_status(
		func(culled_status: Dictionary) -> bool:
			return int(culled_status.get("last_visible_surface_count", -1)) == 0 \
				and int(culled_status.get("last_culled_surface_count", 0)) >= 1,
		10.0
	):
		_fail("resident surface was not culled behind the camera: %s" % _effect.get_status())
		return
	_camera.look_at(Vector3(8.0, 8.0, 8.0), Vector3.UP)
	if not await _wait_for_status(
		func(visible_status: Dictionary) -> bool:
			return int(visible_status.get("last_visible_surface_count", 0)) >= 1 \
				and int(visible_status.get("last_culled_surface_count", -1)) == 0,
		10.0
	):
		_fail("resident surface did not return after camera culling: %s" % _effect.get_status())
		return
	if not await _wait_for_status(
		func(cleanup_status: Dictionary) -> bool:
			return int(cleanup_status.get("counter_readback_bytes", 0)) == 40 \
				and int(cleanup_status.get("inflight_extraction_count", -1)) == 0 \
				and int(cleanup_status.get("resident_entry_count", -1)) == 1,
		10.0
	):
		_fail("asynchronous publication cleanup did not finish: %s" % _effect.get_status())
		return
	var status: Dictionary = _effect.get_status()
	if str(status.get("schema", "")) \
			!= "world_transvoxel.terrain.gpu_global_render_publication.v1" \
			or not bool(status.get("initialized", false)) \
			or not bool(status.get("global_rendering_device", false)) \
			or not bool(status.get("render_thread_owned", false)) \
			or not bool(status.get("same_global_device_compute_raster", false)) \
			or str(status.get("compositor_callback", "")) != "pre_transparent" \
			or str(status.get("resource_architecture", "")) \
				!= "bounded_gpu_validated_exact_meshlet_residency" \
			or int(status.get("resident_buffer_count_per_entry", -1)) != 1 \
			or int(status.get("arena_binding_buffer_count_per_page", 0)) != 21 \
			or int(status.get("arena_page_count", 0)) != 2 \
			or int(status.get("arena_allocated_slot_count", 0)) != 8 \
			or int(status.get("arena_active_slot_count", 0)) != 1 \
			or int(status.get("arena_peak_active_slot_count", 0)) != 2 \
			or int(status.get("arena_allocated_bytes", 0)) <= 0 \
			or int(status.get("arena_slot_leases", 0)) != 2 \
			or int(status.get("arena_slot_releases", 0)) < 1 \
			or int(status.get("counter_readback_bytes", 0)) != 40 \
			or not bool(status.get("gpu_written_indirect_commands", false)) \
			or not bool(status.get("compacted_surface_indirect_commands", false)) \
			or int(status.get("indirect_commands_per_surface", 0)) != 32 \
			or not bool(status.get("device_local_index_copy_used", false)) \
			or str(status.get("visibility_culling", "")) \
				!= "conservative_aabb_frustum" \
			or str(status.get("visibility_bounds_position_space", "")) != "world" \
			or bool(status.get("visibility_culling_near_far", true)) \
			or not bool(status.get("per_view_visibility_context", false)) \
			or not bool(status.get("cached_mono_terrain_push_constants", false)) \
			or not bool(status.get("conservative_draw_bins", false)) \
			or float(status.get("draw_bin_extent", 0.0)) != 128.0 \
			or int(status.get("draw_bin_count", 0)) != 1 \
			or int(status.get("bin_visibility_test_count", 0)) <= 0 \
			or int(status.get("bin_culled_surface_count", 0)) <= 0 \
			or int(status.get("visibility_test_count", 0)) <= 0 \
			or int(status.get("visibility_culled_count", 0)) <= 0 \
			or int(status.get("last_visible_surface_count", 0)) != 1 \
			or int(status.get("last_culled_surface_count", -1)) != 0 \
			or int(status.get("max_compact_command_records_per_view", 0)) > 2 \
			or int(status.get("max_source_cell_records_avoided_per_view", 0)) \
				< EXPECTED_CELL_COUNT - 1 \
			or bool(status.get("fallback_used", true)) \
			or int(status.get("requested", 0)) != 3 \
			or int(status.get("applied", 0)) != 2 \
			or int(status.get("rejected", 0)) != 1 \
			or (int(status.get("stale_skips", 0)) \
				+ int(status.get("cancelled_queued_requests", 0))) < 1 \
			or int(status.get("superseded_entries", 0)) != 1 \
			or int(status.get("resident_entry_count", 0)) != 1 \
			or int(status.get("queued_request_count", -1)) != 0 \
			or int(status.get("draw_frames", 0)) < 4 \
			or int(status.get("indirect_draw_calls", 0)) < 4 \
			or int(status.get("cached_terrain_push_constant_uses", 0)) < 4 \
			or int(status.get("compact_indirect_command_records", -1)) \
				!= int(status.get("indirect_draw_calls", 0)) \
			or int(status.get("source_cell_indirect_records_avoided", 0)) <= 0 \
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
	var avoided_records := int(status.get(
		"source_cell_indirect_records_avoided", 0
	))
	var replacement_identity := _identity(batch, 304, 0x500000032, 0x600000056)
	replacement_identity["page_x"] = 1
	var prepared_before := int(status.get("prepared_entries", 0))
	var replacement_request := _submit(batch, replacement_identity, 4, false)
	if replacement_request <= request_three or not await _wait_for_status(
		func(replacement_status: Dictionary) -> bool:
			return int(replacement_status.get("prepared_entries", 0)) \
				> prepared_before,
		10.0
	):
		_fail("atomic replacement entry was not prepared")
		return
	if not _effect.replace_entries(
		[{"identity": replacement_identity, "publication_sequence": 4}],
		[{"identity": identity, "publication_sequence": 3}]
	):
		_fail("atomic replacement command was rejected")
		return
	if not await _wait_for_status(
		func(replacement_status: Dictionary) -> bool:
			return int(replacement_status.get("active_entry_count", 0)) == 1 \
				and int(replacement_status.get("retired_entries", 0)) >= 1,
		10.0
	):
		_fail("atomic replacement did not complete: %s" % _effect.get_status())
		return
	var replacement_activated := 0
	var replaced_retired := 0
	while true:
		var replacement_event: Dictionary = _effect.pop_event()
		if replacement_event.is_empty():
			break
		var event_identity := Dictionary(replacement_event.get("identity", {}))
		if str(replacement_event.get("status", "")) == "ACTIVE" \
				and event_identity == replacement_identity:
			replacement_activated += 1
		elif str(replacement_event.get("status", "")) == "RETIRED" \
				and event_identity == identity:
			replaced_retired += 1
	if replacement_activated != 1 or replaced_retired != 1:
		_fail("atomic replacement did not publish a complete event pair")
		return
	var saturation_identities: Array[Dictionary] = []
	var prepared_before_saturation := int(
		Dictionary(_effect.get_status()).get("prepared_entries", 0)
	)
	# Queue both lanes before the next render callback. Interaction work must be
	# admitted first while background extraction remains bounded to four tokens.
	for index in range(12):
		var background_identity := _identity(
			batch, 500 + index, 0x500000100 + index, 0x600000100 + index
		)
		background_identity["page_x"] = 10 + index
		saturation_identities.append(background_identity)
		if _submit(batch, background_identity, 1, false) <= 0:
			_fail("background saturation request %d was rejected" % index)
			return
	for index in range(4):
		var interaction_identity := _identity(
			batch, 600 + index, 0x500000200 + index, 0x600000200 + index
		)
		interaction_identity["page_x"] = 100 + index
		interaction_identity["incremental_edit"] = true
		interaction_identity["dirty_regular_brick_mask"] = 1
		saturation_identities.append(interaction_identity)
		if _submit(batch, interaction_identity, 1, false) <= 0:
			_fail("interaction saturation request %d was rejected" % index)
			return
	if not await _wait_for_status(
		func(saturation_status: Dictionary) -> bool:
			return int(saturation_status.get("prepared_entries", 0)) \
					>= prepared_before_saturation + saturation_identities.size() \
				and int(saturation_status.get("dispatch_pending_count", -1)) == 0 \
				and int(saturation_status.get("dispatch_completion_requests", 0)) \
					== int(saturation_status.get("dispatch_completion_completions", -1)),
		30.0
	):
		_fail("dispatch lanes did not drain after saturation: %s" % _effect.get_status())
		return
	var saturation_status: Dictionary = _effect.get_status()
	if int(saturation_status.get("peak_background_dispatch_pending_count", 0)) != 4 \
			or int(saturation_status.get("peak_interaction_dispatch_pending_count", 0)) < 4 \
			or int(saturation_status.get("peak_interaction_dispatch_pending_count", 0)) > 8 \
			or int(saturation_status.get("background_dispatch_deferrals", 0)) < 8 \
			or int(saturation_status.get("interaction_dispatch_deferrals", -1)) != 0 \
			or int(saturation_status.get("invalid_dispatch_completions", -1)) != 0 \
			or int(saturation_status.get("dispatch_completion_bytes", 0)) \
				!= int(saturation_status.get("dispatch_completion_completions", 0)) * 16:
		_fail("independent dispatch-lane contract failed: %s" % saturation_status)
		return
	for saturation_identity in saturation_identities:
		if not _effect.retire_entry(saturation_identity, 1):
			_fail("saturation candidate retirement was rejected")
			return
	if not await _wait_for_status(
		func(retired_status: Dictionary) -> bool:
			return int(retired_status.get("resident_entry_count", -1)) == 1 \
				and int(retired_status.get("inflight_extraction_count", -1)) == 0,
		10.0
	):
		_fail("saturation candidates were not reclaimed: %s" % _effect.get_status())
		return
	var cancellation_count_before := int(
		Dictionary(_effect.get_status()).get("cancelled_queued_requests", 0)
	) + int(Dictionary(_effect.get_status()).get("cancelled_inflight_requests", 0))
	var cancelled_identity := _identity(batch, 401, 0x500000041, 0x600000061)
	cancelled_identity["page_x"] = 2
	var cancelled_request := _submit(batch, cancelled_identity, 1, false)
	if cancelled_request <= replacement_request \
			or not _effect.retire_entry(cancelled_identity, 1):
		_fail("pre-publication retirement request was rejected")
		return
	if not await _wait_for_status(
		func(cancelled_status: Dictionary) -> bool:
			return int(cancelled_status.get("queued_request_count", -1)) == 0 \
				and int(cancelled_status.get("inflight_extraction_count", -1)) == 0 \
				and int(cancelled_status.get("cancelled_queued_requests", 0)) \
					+ int(cancelled_status.get("cancelled_inflight_requests", 0)) \
					== cancellation_count_before + 1,
		10.0
	):
		_fail("pre-publication retirement did not cancel extraction: %s" \
			% str(_effect.get_status()))
		return
	var cancelled_prepared := 0
	var cancelled_retired := 0
	while true:
		var event: Dictionary = _effect.pop_event()
		if event.is_empty():
			break
		if Dictionary(event.get("identity", {})) != cancelled_identity:
			continue
		if str(event.get("status", "")) == "PREPARED":
			cancelled_prepared += 1
		elif str(event.get("status", "")) == "RETIRED":
			cancelled_retired += 1
	var cancelled_status: Dictionary = _effect.get_status()
	# Dispatch completion may expose PREPARED before the queued retirement is
	# applied. PREPARED is not visibility publication; retirement must still win
	# exactly once and leave no resident orphan.
	if cancelled_prepared > 1 or cancelled_retired != 1 \
			or int(cancelled_status.get("resident_entry_count", -1)) != 1:
		_fail("retired extraction published an orphan entry: prepared=%d retired=%d status=%s" % [
			cancelled_prepared, cancelled_retired, str(cancelled_status),
		])
		return
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
			"GPU_GLOBAL_RENDER_PUBLICATION_SMOKE_PASS cells=%d applied=2 supersession=1 " \
			+ "superseded=1 draw_frames=%d indirect_draw_calls=%d " \
			+ "meshlets=32 culling=1 atomic_replacement=1 dispatch_lanes=4+8 " \
			+ "avoided_records=%d " \
			+ "foreground_pixels=%d image_sha256=%s"
		) % [
			EXPECTED_CELL_COUNT,
			draw_frames,
			indirect_draw_calls,
			avoided_records,
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


func _submit(
	batch: Dictionary,
	identity: Dictionary,
	sequence: int,
	activate_immediately: bool = true
) -> int:
	return int(_effect.submit_explicit_samples(
		batch.get("densities", PackedFloat32Array()),
		batch.get("gradients", PackedVector3Array()),
		batch.get("materials", PackedInt32Array()),
		batch.get("material_authored", PackedByteArray()),
		batch.get("cells", []),
		identity,
		sequence,
		activate_immediately
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
