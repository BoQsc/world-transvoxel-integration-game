extends SceneTree

const MARKER := "GPU_RESIDENT_PRODUCTION_VISUAL_PARITY_SMOKE_PASS"
const BACKGROUND := Color(0.02, 0.025, 0.03, 1.0)
const CAPTURE_ROOT := (
	"res://.godot/world_transvoxel_captures/gpu_resident_production_visual_parity"
)
const PRODUCTION_SHADER := (
	"res://addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader"
)
const TerrainWorld := preload(
	"res://addons/world_transvoxel_terrain/runtime/wt_terrain_world.gd"
)
const TerrainProfile := preload(
	"res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd"
)
const RuntimeProfile := preload(
	"res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd"
)
const GenerationProfile := preload(
	"res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd"
)
const StorageProfile := preload(
	"res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd"
)
const MaterialProfile := preload(
	"res://addons/world_transvoxel_terrain/material/wt_terrain_material_profile.gd"
)
const ReferenceScene := preload(
	"res://addons/world_transvoxel_terrain/debug/wt_terrain_reference_scene.gd"
)
const GameMaterialApplicator := preload(
	"res://addons/world_transvoxel_gameworld/material/wt_game_terrain_material_applicator.gd"
)
const LodAudit := preload(
	"res://addons/world_transvoxel_terrain/debug/wt_terrain_lod_audit.gd"
)

var _world
var _reference_scene
var _material_applicator
var _camera: Camera3D
var _world_environment: WorldEnvironment


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_setup_viewport()
	_setup_world()
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("bounded visual-parity world did not start: %s" % _world.get_last_error())
		return
	var material_summary: Dictionary = _material_applicator.apply_materials_now()
	if not bool(material_summary.get("production_texture_active", false)) \
			or not bool(material_summary.get("native_render_material_override", false)):
		_fail("production material was not installed: %s" % str(material_summary))
		return
	var viewer := Vector3(24.0, 30.0, 24.0)
	if not _world.update_viewer(1, 1, viewer, 2, 3):
		_fail("bounded LOD3 viewer was rejected: %s" % _world.get_last_error())
		return
	if not await _wait_for_lod3_inventory():
		_fail("LOD3 resident inventory did not settle: status=%s runtime=%s" \
			% [str(_world.get_gpu_resident_render_status()), str(_world.get_runtime_metrics())])
		return
	var lod3_status: Dictionary = _world.get_gpu_resident_render_status()
	var lod3_effect: Dictionary = lod3_status.get("effect_status", {})
	var lod3_count := int(Dictionary(lod3_effect.get(
		"active_terrain_lod_counts", {}
	)).get("3", 0))
	if not _world.update_viewer(1, 2, viewer, 2, 2):
		_fail("bounded mixed-LOD viewer was rejected: %s" % _world.get_last_error())
		return
	if not await _wait_for_complete_lod_inventory():
		_fail("LOD0/1/2 resident inventory did not settle: status=%s runtime=%s" \
			% [str(_world.get_gpu_resident_render_status()), str(_world.get_runtime_metrics())])
		return

	_camera.position = Vector3(112.0, 82.0, 170.0)
	_camera.look_at(Vector3(88.0, 26.0, 32.0), Vector3.UP)
	var overview := await _capture("overview")
	_camera.position = Vector3(22.0, 45.0, 76.0)
	_camera.look_at(Vector3(24.0, 25.0, 24.0), Vector3.UP)
	var near := await _capture("near")
	var status: Dictionary = _world.get_gpu_resident_render_status()
	var effect: Dictionary = status.get("effect_status", {})
	var native: Dictionary = status.get("native_metrics", {})
	var runtime_metrics: Dictionary = _world.get_runtime_metrics()
	var terrain_lods: Dictionary = effect.get("active_terrain_lod_counts", {})
	var water_lods: Dictionary = effect.get("active_static_water_lod_counts", {})
	var lod_audit: Dictionary = LodAudit.collect(_world)
	var active_lod_entries := _sum_counts(terrain_lods)
	if not bool(status.get("running", false)) \
			or bool(status.get("production_terrain_material_parity", true)) \
			or not bool(status.get("production_terrain_material_payload_ready", false)) \
			or not bool(status.get("production_terrain_albedo_mapping_parity", false)) \
			or not bool(status.get("production_terrain_roughness_mapping_parity", false)) \
			or not bool(status.get(
				"production_terrain_accepted_normal_response_parity", false
			)) \
			or not bool(status.get(
				"production_terrain_bounded_pbr_response_parity", false
			)) \
			or bool(status.get("production_terrain_normal_mapping_parity", true)) \
			or bool(status.get("production_terrain_pbr_lighting_parity", true)) \
			or not bool(status.get("production_static_water_material_parity", false)) \
			or not bool(status.get(
				"production_static_water_material_payload_ready", false
			)) \
			or not bool(status.get(
				"production_static_water_fresnel_tint_parity", false
			)) \
			or not bool(status.get("production_static_water_refraction_parity", false)) \
			or str(status.get("production_material_source", "")) != PRODUCTION_SHADER \
			or int(status.get("production_material_parameter_bytes", 0)) != 368 \
			or int(status.get("production_material_texture_count", 0)) != 5 \
			or int(terrain_lods.get("0", 0)) < 1 \
			or int(terrain_lods.get("1", 0)) < 1 \
			or int(terrain_lods.get("2", 0)) < 1 \
			or not water_lods.is_empty() \
			or active_lod_entries != int(effect.get("active_entry_count", -1)) \
			or str(lod_audit.get("status", "")) != "PASS" \
			or int(lod_audit.get("coverage_overlap_count", -1)) != 0 \
			or int(status.get("rejected_chunks", -1)) != 0 \
			or int(status.get("superseded_chunks", -1)) \
				!= int(native.get("readiness_stale", -2)) \
			or int(native.get("validation_rejections", -1)) != 0 \
			or not str(status.get("last_error", "")).is_empty() \
			or int(status.get("recovery_count", -1)) != 0 \
			or int(effect.get("geometry_readback_bytes", -1)) != 0 \
			or bool(effect.get("cpu_chunk_finalization_used", true)) \
			or int(native.get("cpu_visual_mesh_omitted_captures", -1)) \
				!= int(native.get("pre_mesh_field_captures", -2)) \
			or int(runtime_metrics.get(
				"page_gpu_resident_visual_only_completions", 0
			)) < active_lod_entries \
			or int(runtime_metrics.get("resource_cache_mesh_entries", -1)) != 0 \
			or int(runtime_metrics.get("resource_cache_collision_entries", -1)) != 0 \
			or not _capture_is_valid(overview, 10) \
			or not _capture_is_valid(near, 16) \
			or str(overview.get("sha256", "")) == str(near.get("sha256", "")):
		_fail("production visual parity contract failed: status=%s runtime=%s audit=%s overview=%s near=%s" \
			% [str(status), str(runtime_metrics), str(lod_audit), str(overview), str(near)])
		return

	_world.end_gpu_resident_render_publication()
	await process_frame
	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("bounded visual-parity world did not stop cleanly")
		return
	print((
		"%s lod0=%d lod1=%d lod2=%d lod3_phase=%d active=%d overlap=0 " \
		+ "terrain_albedo_mapping_parity=1 terrain_material_parity=0 " \
		+ "roughness_mapping_parity=1 bounded_pbr_response_parity=1 " \
		+ "water_fresnel_tint_parity=1 water_refraction_parity=1 " \
		+ "water_material_parity=1 readback=0 " \
		+ "gpu_only_completions=%d superseded=%d overview_pixels=%d near_pixels=%d " \
		+ "overview_sha256=%s near_sha256=%s"
	) % [
		MARKER,
		int(terrain_lods.get("0", 0)),
		int(terrain_lods.get("1", 0)),
		int(terrain_lods.get("2", 0)),
		lod3_count,
		active_lod_entries,
		int(runtime_metrics.get(
			"page_gpu_resident_visual_only_completions", 0
		)),
		int(status.get("superseded_chunks", 0)),
		int(overview.get("foreground_pixels", 0)),
		int(near.get("foreground_pixels", 0)),
		str(overview.get("sha256", "")),
		str(near.get("sha256", "")),
	])
	_reference_scene.queue_free()
	_material_applicator.queue_free()
	await process_frame
	quit(0)


func _setup_viewport() -> void:
	root.size = Vector2i(800, 600)
	root.content_scale_size = Vector2i(800, 600)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND
	_world_environment = WorldEnvironment.new()
	_world_environment.environment = environment
	root.add_child(_world_environment)
	_camera = Camera3D.new()
	_camera.fov = 62.0
	_camera.position = Vector3(112.0, 82.0, 170.0)
	root.add_child(_camera)
	_camera.look_at(Vector3(88.0, 26.0, 32.0), Vector3.UP)
	_camera.current = true


func _setup_world() -> void:
	_world = TerrainWorld.new()
	_world.name = "TerrainWorld"
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.material_profile = MaterialProfile.new()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	_world.runtime_gpu_resident_request_capacity = 16
	_world.runtime_gpu_resident_chunk_capacity = 96
	_reference_scene = ReferenceScene.new()
	_reference_scene.name = "WtTerrainReferenceScene"
	_reference_scene.refresh_on_ready = false
	_reference_scene.add_child(_world)
	root.add_child(_reference_scene)
	_material_applicator = GameMaterialApplicator.new()
	_material_applicator.name = "WtGameTerrainMaterialApplicator"
	_material_applicator.auto_apply = false
	_material_applicator.reference_scene_path = NodePath("../WtTerrainReferenceScene")
	root.add_child(_material_applicator)


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.profile_id = &"gpu_resident_production_visual_parity"
	profile.horizontal_cells = 192
	profile.vertical_cells = 64
	profile.vertical_origin_cell = 0
	return profile


func _runtime_profile() -> Resource:
	var profile := RuntimeProfile.create_builtin(RuntimeProfile.Preset.REFERENCE)
	profile.profile_id = &"gpu_resident_production_visual_parity"
	profile.viewer_radius_chunks = 2
	profile.maximum_lod = 3
	profile.collision_radius_chunks = 0
	profile.active_chunk_capacity = 128
	profile.demand_capacity_per_viewer = 256
	profile.lod_refinement_radius_chunks = 1
	profile.procedural_generation_worker_count = 1
	profile.meshing_worker_count = 1
	profile.storage_request_capacity = 128
	profile.storage_completion_capacity = 128
	profile.encoded_page_entry_capacity = 128
	profile.decoded_page_entry_capacity = 128
	profile.mesh_entry_capacity = 128
	profile.render_entry_capacity = 128
	profile.collision_entry_capacity = 16
	profile.render_apply_budget = 8
	profile.collision_apply_budget = 2
	return profile


func _generation_profile() -> Resource:
	var profile := GenerationProfile.new()
	profile.source_mode = GenerationProfile.SourceMode.DETERMINISTIC_REFERENCE
	profile.profile_id = &"gpu_resident_production_visual_parity"
	profile.procedural_preset_id = &"rolling_hills_cave"
	profile.seed = 470047
	profile.source_revision = 640401
	profile.world_chunk_count_x = 12
	profile.world_chunk_count_y = 4
	profile.world_chunk_origin_y = 0
	profile.world_chunk_count_z = 4
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://gpu-resident-visual-parity-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"gpu_resident_production_visual_parity"
	profile.object_root_path = root_path
	profile.world_manifest_path = root_path.path_join("world.wtworld")
	profile.edit_journal_path = root_path.path_join("world.wtedit")
	profile.snapshot_directory = root_path.path_join("snapshots")
	return profile


func _wait_for_state(expected: String) -> bool:
	for _frame in range(900):
		if _world.get_world_state_name() == expected:
			await process_frame
			return true
		await process_frame
	return false


func _wait_for_complete_lod_inventory() -> bool:
	for _frame in range(3600):
		var status: Dictionary = _world.get_gpu_resident_render_status()
		var effect: Dictionary = status.get("effect_status", {})
		var counts: Dictionary = effect.get("active_terrain_lod_counts", {})
		var idle: Dictionary = _world.get_cold_idle_summary()
		if bool(idle.get("cold_idle", false)) \
				and int(counts.get("0", 0)) > 0 \
				and int(counts.get("1", 0)) > 0 \
				and int(counts.get("2", 0)) > 0 \
				and int(status.get("rejected_chunks", 0)) == 0 \
				and int(status.get("active_chunks", -1)) \
					== int(effect.get("active_entry_count", -2)) \
				and int(effect.get("draw_frames", 0)) >= 2:
			return true
		await process_frame
	return false


func _wait_for_lod3_inventory() -> bool:
	for _frame in range(1800):
		var status: Dictionary = _world.get_gpu_resident_render_status()
		var effect: Dictionary = status.get("effect_status", {})
		var counts: Dictionary = effect.get("active_terrain_lod_counts", {})
		var idle: Dictionary = _world.get_cold_idle_summary()
		if bool(idle.get("cold_idle", false)) \
				and int(counts.get("3", 0)) > 0 \
				and int(status.get("rejected_chunks", 0)) == 0 \
				and int(status.get("active_chunks", -1)) \
					== int(effect.get("active_entry_count", -2)) \
				and int(effect.get("draw_frames", 0)) >= 2:
			return true
		await process_frame
	return false


func _capture(name: String) -> Dictionary:
	for _frame in range(4):
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		return {}
	image.convert(Image.FORMAT_RGBA8)
	var driver := RenderingServer.get_current_rendering_driver_name().to_lower()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_ROOT))
	image.save_png("%s/%s_%s.png" % [CAPTURE_ROOT, driver, name])
	return {
		"foreground_pixels": _foreground_pixel_count(image),
		"quantized_color_count": _quantized_color_count(image),
		"sha256": _sha256(image.get_data()),
	}


func _capture_is_valid(capture: Dictionary, minimum_colors: int) -> bool:
	return int(capture.get("foreground_pixels", 0)) >= 2000 \
		and int(capture.get("quantized_color_count", 0)) >= minimum_colors \
		and not str(capture.get("sha256", "")).is_empty()


func _foreground_pixel_count(image: Image) -> int:
	var expected := BACKGROUND.to_rgba32()
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if _color_distance(image.get_pixel(x, y).to_rgba32(), expected) > 24:
				count += 1
	return count


func _quantized_color_count(image: Image) -> int:
	var colors := {}
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var color := image.get_pixel(x, y)
			var key := "%d:%d:%d" % [
				int(color.r * 15.0), int(color.g * 15.0), int(color.b * 15.0)
			]
			colors[key] = true
	return colors.size()


static func _sum_counts(counts: Dictionary) -> int:
	var total := 0
	for value in counts.values():
		total += int(value)
	return total


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


func _fail(message: String) -> void:
	if _world != null:
		_world.end_gpu_resident_render_publication()
	push_error("GPU_RESIDENT_PRODUCTION_VISUAL_PARITY_SMOKE_FAIL: " + message)
	quit(1)
