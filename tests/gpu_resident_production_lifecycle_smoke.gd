extends SceneTree

const MARKER := "GPU_RESIDENT_PRODUCTION_LIFECYCLE_SMOKE_PASS"
const CAPTURE_ROOT := (
	"res://.godot/world_transvoxel_captures/gpu_resident_production_lifecycle"
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
const EditOperation := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd"
)
const EditBatch := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd"
)

var _world
var _world_environment: WorldEnvironment
var _sun: DirectionalLight3D
var _reference_scene
var _material_applicator
var _committed_revisions: Array[int] = []
var _cpu_reference := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_cpu_reference = OS.get_cmdline_user_args().has("--cpu-reference")
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.material_profile = MaterialProfile.new()
	_world.runtime_gpu_resident_render_candidate_enabled = not _cpu_reference
	_world.runtime_gpu_meshing_shadow_capacity = 3
	_world.runtime_gpu_resident_chunk_capacity = 4
	_world.name = "TerrainWorld"
	_reference_scene = ReferenceScene.new()
	_reference_scene.name = "WtTerrainReferenceScene"
	_reference_scene.refresh_on_ready = false
	_reference_scene.add_child(_world)
	root.add_child(_reference_scene)
	_material_applicator = GameMaterialApplicator.new()
	_material_applicator.name = "WtGameTerrainMaterialApplicator"
	_material_applicator.auto_apply = false
	_material_applicator.reference_scene_path = NodePath(
		"../WtTerrainReferenceScene"
	)
	root.add_child(_material_applicator)
	_world.edit_committed.connect(_on_edit_committed)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("resident production world did not start: %s" % _world.get_last_error())
		return
	var material_summary: Dictionary = _material_applicator.apply_materials_now()
	if not bool(material_summary.get("native_render_material_override", false)) \
			or not bool(material_summary.get("native_water_material_override", false)) \
			or not bool(material_summary.get("production_texture_active", false)):
		_fail("accepted game material was not installed: %s" % str(material_summary))
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 0, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0):
		_fail("resident production viewers were rejected")
		return
	if _cpu_reference:
		if not await _wait_for_cpu_chunk():
			_fail("initial CPU reference chunk did not settle")
			return
	elif not await _wait_for_active_chunk(1, 1):
		_fail("initial CPU visual was not replaced by a resident GPU chunk")
		return
	var initial_status: Dictionary = _world.get_gpu_resident_render_status()
	var initial_activated := int(initial_status.get("activated_chunks", 0))
	if not _cpu_reference:
		var backend: Node = _world.get_backend_terrain()
		var before: Dictionary = backend.call("get_gpu_resident_render_metrics")
		var inspection: Dictionary = backend.call("inspect_gpu_resident_publication", Vector3i.ZERO, 0)
		var repeated: Dictionary = backend.call("inspect_gpu_resident_publication", Vector3i.ZERO, 0)
		var after: Dictionary = backend.call("get_gpu_resident_render_metrics")
		if not inspection.get("built", false) or not inspection.get("read_only", false) \
				or inspection != repeated or before != after \
				or inspection.get("selected", []).size() != 1:
			_fail("publication inspection changed native state or could not inspect the live chunk")
			return
		var boundary: Dictionary = inspection["boundaries"][0]
		var identity := {
			"page_x": 0, "page_y": 0, "page_z": 0, "lod": 0,
			"generation": boundary["generation"],
			"transition_mask": boundary["transition_mask"],
			"source_revision": backend.call("get_world_source_revision"),
			"world_revision": _world.get_world_revision(), "surface": "terrain",
		}
		var cohort: Dictionary = backend.call("get_gpu_resident_render_activation_cohort", identity)
		var expected_member := {
			"page_x": 0, "page_y": 0, "page_z": 0, "lod": 0,
			"generation": boundary["generation"],
			"transition_mask": boundary["transition_mask"], "activation_required": false,
		}
		if not cohort.get("ready", false) or cohort.get("chunks", []) != [expected_member] \
				or cohort.get("activation_required_count", -1) != 0 \
				or cohort.get("retained_active_count", -1) != 1 \
				or not cohort.get("retirements", []).is_empty():
			_fail("live cohort serialization changed identity or activation ownership")
			return
		var measured: Dictionary = backend.call("get_gpu_resident_render_activation_cohort", identity, true)
		var timing: Dictionary = measured.get("query_timing_usec", {})
		for stage in ["seed_validation", "selection", "coverage", "member_readiness", "response"]:
			if int(timing.get(stage, -1)) < 0:
				_fail("native query timing omitted a completed phase")
				return
		measured.erase("query_timing_usec")
		if cohort.has("query_timing_usec") or measured != cohort:
			_fail("optional query timing changed publication results or ran by default")
			return
		identity["generation"] = int(identity["generation"]) + 1
		var stale: Dictionary = backend.call("get_gpu_resident_render_activation_cohort", identity)
		if stale.get("ready", true) or stale.get("status", "") != "STALE_APPLICATION" \
				or not stale.get("chunks", []).is_empty():
			_fail("stale cohort exposed an activation inventory")
			return

	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CONSTRUCT, Vector3(8, 12, 8), 2.0, 3),
		6401
	) or not await _wait_for_commit(1):
		_fail("resident construct edit did not commit")
		return
	if _cpu_reference:
		if not await _wait_for_cpu_chunk():
			_fail("constructed CPU reference chunk did not settle")
			return
	elif not await _wait_for_active_chunk(initial_activated + 1, 1):
		_fail("edited resident generation did not replace the prior generation: %s" \
			% str(_world.get_gpu_resident_render_status()))
		return

	var after_construct: Dictionary = _world.get_gpu_resident_render_status()
	var construct_activated := int(after_construct.get("activated_chunks", 0))
	var terrain_only_image := await _capture_image(
		"cpu_terrain_only" if _cpu_reference else "terrain_only"
	)
	if not _world.submit_edit_batch(
		_edit_batch(
			EditOperation.Mode.PLACE_STATIC_WATER, Vector3(4, 12, 4), 4.0, 9
		),
		6402
	) or not await _wait_for_commit(2):
		_fail("resident static-water edit did not commit")
		return
	if _cpu_reference:
		if not await _wait_for_cpu_chunk():
			_fail("terrain and water CPU reference chunk did not settle")
			return
	elif not await _wait_for_active_chunk(construct_activated + 1, 2):
		_fail("terrain and water were not admitted as one complete resident chunk: %s" \
			% str(_world.get_gpu_resident_render_status()))
		return

	var image := await _capture_image(
		"cpu_static_water" if _cpu_reference else "static_water"
	)
	if image == null or image.is_empty():
		_fail("resident production viewport could not be inspected")
		return
	if terrain_only_image == null or terrain_only_image.is_empty() \
			or _image_sha256(terrain_only_image) == _image_sha256(image):
		_fail("bounded static-water response did not alter the inspected viewport")
		return
	if _cpu_reference:
		if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
			_fail("CPU reference world did not stop cleanly")
			return
		print("GPU_RESIDENT_PRODUCTION_LIFECYCLE_CPU_REFERENCE_PASS")
		_world.queue_free()
		await process_frame
		quit(0)
		return
	var status: Dictionary = _world.get_gpu_resident_render_status()
	var native_metrics: Dictionary = status.get("native_metrics", {})
	var effect_status: Dictionary = status.get("effect_status", {})
	var runtime_metrics: Dictionary = _world.get_runtime_metrics()
	if not bool(status.get("running", false)) \
			or not bool(status.get("production_chunk_replacement", false)) \
			or str(status.get("native_position_space", "")) != "world" \
			or not bool(status.get("cpu_collision_authority", false)) \
			or not bool(status.get("production_material_parity", false)) \
			or not bool(status.get("production_terrain_material_parity", false)) \
			or not bool(status.get("production_terrain_material_payload_ready", false)) \
			or not bool(status.get("production_terrain_albedo_mapping_parity", false)) \
			or not bool(status.get("production_terrain_roughness_mapping_parity", false)) \
			or not bool(status.get(
				"production_terrain_accepted_normal_response_parity", false
			)) \
			or not bool(status.get(
				"production_terrain_bounded_pbr_response_parity", false
			)) \
			or not bool(status.get(
				"production_terrain_directional_ambient_lighting_parity", false
			)) \
			or not bool(status.get("production_terrain_normal_mapping_parity", false)) \
			or not bool(status.get("production_terrain_pbr_lighting_parity", false)) \
			or not bool(status.get("production_static_water_material_parity", false)) \
			or not bool(status.get(
				"production_static_water_material_payload_ready", false
			)) \
			or not bool(status.get(
				"production_static_water_fresnel_tint_parity", false
			)) \
			or not bool(status.get("production_static_water_refraction_parity", false)) \
			or not bool(effect_status.get(
				"production_static_water_scene_copy_ready", false
			)) \
			or str(status.get("production_material_source", "")) \
				!= "res://addons/world_transvoxel_gameworld/material/wt_game_terrain_palette.gdshader" \
			or int(status.get("production_material_parameter_bytes", 0)) != 416 \
			or int(status.get("production_material_texture_count", 0)) != 5 \
			or str(status.get("production_water_material_source", "")) \
				!= "res://addons/world_transvoxel_gameworld/material/wt_game_static_water.gdshader" \
			or int(status.get("production_water_parameter_bytes", 0)) != 48 \
			or int(status.get("rejected_chunks", -1)) != 0 \
			or int(effect_status.get("active_partial_entry_count", -1)) != 0 \
			or str(effect_status.get("resource_architecture", "")) \
				!= "bounded_scratch_compact_residency" \
			or int(effect_status.get("resident_buffer_count_per_entry", -1)) != 5 \
			or int(effect_status.get("arena_page_count", 0)) < 1 \
			or int(effect_status.get("arena_active_slot_count", -1)) != 2 \
			or int(effect_status.get("arena_slot_leases", 0)) < 4 \
			or int(effect_status.get("arena_slot_releases", 0)) < 2 \
			or int(effect_status.get("packing_requests", -1)) != 0 \
			or int(effect_status.get("native_packed_requests", 0)) < 4 \
			or int(effect_status.get("native_packed_bytes_total", 0)) <= 0 \
			or not bool(effect_status.get(
				"compacted_surface_indirect_commands", false
			)) \
			or int(effect_status.get("indirect_commands_per_surface", 0)) != 1 \
			or str(effect_status.get("visibility_bounds_position_space", "")) \
				!= "world" \
			or int(effect_status.get("visibility_test_count", 0)) <= 0 \
			or int(effect_status.get("source_cell_indirect_records_avoided", 0)) <= 0 \
			or int(effect_status.get("max_compact_command_records_per_view", 0)) > 2 \
			or int(native_metrics.get("capture_reservation_attempts", 0)) < 3 \
			or int(native_metrics.get("reserved_captures", 0)) < 4 \
			or int(native_metrics.get("released_capture_slots", 0)) < 2 \
			or int(native_metrics.get("pre_mesh_field_captures", 0)) < 4 \
			or bool(native_metrics.get("cpu_topology_input_dependency", true)) \
			or bool(native_metrics.get("cpu_field_sampling", true)) \
			or not bool(native_metrics.get("gpu_density_field_generation", false)) \
			or not bool(native_metrics.get("gpu_material_field_generation", false)) \
			or not bool(native_metrics.get("gpu_page_lattice_input", false)) \
			or not bool(native_metrics.get("gpu_transvoxel_extraction", false)) \
			or int(native_metrics.get("reserved_capture_slots", -1)) != 0 \
			or int(native_metrics.get("activated_chunks", 0)) < 3 \
			or int(native_metrics.get("validation_rejections", -1)) != 0 \
			or int(effect_status.get("active_entry_count", 0)) != 2 \
			or int(effect_status.get("resident_entry_count", 0)) > 5 \
			or int(effect_status.get("geometry_readback_bytes", -1)) != 0 \
			or int(effect_status.get("counter_readback_bytes", 0)) <= 0 \
			or bool(effect_status.get("cpu_chunk_finalization_used", true)) \
			or bool(effect_status.get("array_mesh_upload_used", true)) \
			or not bool(effect_status.get("atomic_surface_set_activation", false)) \
			or int(runtime_metrics.get("collision_resources", 0)) < 1:
		_fail("resident production contract failed: %s" % str(status))
		return
	_sun.shadow_enabled = true
	if not await _wait_for_material_parity(false):
		_fail("shadowed directional light did not downgrade GPU material parity")
		return
	_sun.shadow_enabled = false
	if not await _wait_for_material_parity(true):
		_fail("supported lighting did not restore GPU material parity")
		return

	_world.end_gpu_resident_render_publication()
	await process_frame
	var backend: Node = _world.get_backend_terrain()
	var recovery_metrics := Dictionary(backend.call(
		"get_gpu_resident_render_metrics"
	))
	if bool(recovery_metrics.get("enabled", true)) \
			or int(recovery_metrics.get("restored_cpu_chunks", 0)) < 1:
		_fail("resident shutdown did not restore the CPU visual")
		return
	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("resident production world did not stop cleanly")
		return
	print(
		(
			"%s activated=%d water_surfaces=2 restored=%d collision_authority=cpu " \
			+ "readback=0 terrain_albedo_mapping_parity=1 roughness_mapping_parity=1 " \
			+ "accepted_normal_response_parity=1 bounded_pbr_response_parity=1 " \
			+ "terrain_material_parity=1 water_material_parity=1 " \
			+ "water_fresnel_tint_parity=1 water_refraction_parity=1 " \
			+ "material_params=416 material_textures=5 water_params=48 " \
			+ "arena=paged_shared native_packed=1 " \
			+ "pre_mesh_admission=1 pre_mesh_field=1 cpu_topology_input=0 " \
			+ "cpu_field_sampling=0 gpu_density_generation=1 gpu_material_generation=1 " \
			+ "reservations=%d captures=%d released=%d"
		) % [
			MARKER,
			int(native_metrics.get("activated_chunks", 0)),
			int(recovery_metrics.get("restored_cpu_chunks", 0)),
			int(native_metrics.get("capture_reservation_attempts", 0)),
			int(native_metrics.get("reserved_captures", 0)),
			int(native_metrics.get("released_capture_slots", 0)),
		]
	)
	_world.queue_free()
	await process_frame
	quit(0)


func _capture_image(name: String) -> Image:
	for _frame in range(4):
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image != null and not image.is_empty():
		var driver := RenderingServer.get_current_rendering_driver_name().to_lower()
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
			CAPTURE_ROOT
		))
		image.save_png("%s/%s_%s.png" % [CAPTURE_ROOT, driver, name])
	return image


static func _image_sha256(image: Image) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(image.get_data()) != OK:
		return ""
	return context.finish().hex_encode()


func _setup_viewport() -> void:
	root.size = Vector2i(640, 480)
	root.content_scale_size = Vector2i(640, 480)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.025, 0.03, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.76, 0.80)
	environment.ambient_light_energy = 0.55
	_world_environment = WorldEnvironment.new()
	_world_environment.environment = environment
	root.add_child(_world_environment)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	_sun.light_color = Color(1.0, 0.96, 0.88)
	_sun.light_energy = 1.25
	_sun.shadow_enabled = false
	root.add_child(_sun)
	var camera := Camera3D.new()
	camera.position = Vector3(8, 12, 28)
	root.add_child(camera)
	camera.look_at(Vector3(8, 8, 8), Vector3.UP)
	camera.current = true


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.profile_id = &"gpu_resident_production_lifecycle_smoke"
	profile.horizontal_cells = 16
	profile.vertical_cells = 16
	return profile


func _runtime_profile() -> Resource:
	var profile := RuntimeProfile.create_builtin(RuntimeProfile.Preset.LOW_POWER)
	profile.procedural_generation_worker_count = 1
	profile.meshing_worker_count = 1
	return profile


func _generation_profile() -> Resource:
	var profile := GenerationProfile.new()
	profile.source_mode = GenerationProfile.SourceMode.FLAT
	profile.profile_id = &"gpu_resident_production_lifecycle_smoke"
	profile.procedural_preset_id = &"flat"
	profile.source_revision = 640201
	profile.world_chunk_count_x = 1
	profile.world_chunk_count_y = 1
	profile.world_chunk_count_z = 1
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://gpu-resident-production-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"gpu_resident_production_lifecycle_smoke"
	profile.object_root_path = root_path
	profile.world_manifest_path = root_path.path_join("world.wtworld")
	profile.edit_journal_path = root_path.path_join("world.wtedit")
	profile.snapshot_directory = root_path.path_join("snapshots")
	return profile


func _edit_batch(
	mode: EditOperation.Mode, center: Vector3, radius: float, material: int
) -> Resource:
	var operation := EditOperation.new()
	operation.mode = mode
	operation.brush_shape = EditOperation.BrushShape.SPHERE
	operation.center = center
	operation.radius = radius
	operation.material_id = material
	operation.density_value = 1.0
	var batch := EditBatch.new()
	batch.add_operation(operation)
	return batch


func _wait_for_state(expected: String) -> bool:
	for _frame in range(900):
		if _world.get_world_state_name() == expected:
			await process_frame
			return true
		await process_frame
	return false


func _wait_for_commit(revision: int) -> bool:
	for _frame in range(1200):
		if _committed_revisions.has(revision) \
				and _world.get_world_revision() == revision:
			return true
		await process_frame
	return false


func _wait_for_active_chunk(activated_chunks: int, active_surfaces: int) -> bool:
	for _frame in range(1800):
		var status: Dictionary = _world.get_gpu_resident_render_status()
		var effect_status: Dictionary = status.get("effect_status", {})
		var idle: Dictionary = _world.get_cold_idle_summary()
		if int(status.get("activated_chunks", 0)) >= activated_chunks \
				and int(status.get("active_chunks", 0)) == 1 \
				and int(status.get("rejected_chunks", 0)) == 0 \
				and int(effect_status.get("active_entry_count", 0)) == active_surfaces \
				and int(effect_status.get("active_partial_entry_count", 0)) == 0 \
				and int(effect_status.get("draw_frames", 0)) >= 2 \
				and bool(idle.get("cold_idle", false)) \
				and int(idle.get("render_resources", 0)) >= 1 \
				and int(idle.get("collision_resources", 0)) >= 1:
			return true
		await process_frame
	return false


func _wait_for_cpu_chunk() -> bool:
	for _frame in range(1800):
		var idle: Dictionary = _world.get_cold_idle_summary()
		if bool(idle.get("cold_idle", false)) \
				and int(idle.get("render_resources", 0)) >= 1 \
				and int(idle.get("collision_resources", 0)) >= 1:
			return true
		await process_frame
	return false


func _wait_for_material_parity(expected: bool) -> bool:
	for _frame in range(180):
		var status: Dictionary = _world.get_gpu_resident_render_status()
		if bool(status.get("production_material_parity", false)) == expected \
				and bool(status.get(
					"production_terrain_material_parity", false
				)) == expected:
			return true
		await process_frame
	return false


func _on_edit_committed(revision: int) -> void:
	_committed_revisions.append(revision)


func _fail(message: String) -> void:
	if _world != null:
		_world.end_gpu_resident_render_publication()
	push_error("GPU_RESIDENT_PRODUCTION_LIFECYCLE_SMOKE_FAIL: " + message)
	quit(1)
