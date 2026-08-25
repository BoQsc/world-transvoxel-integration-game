extends SceneTree

const MARKER := "GPU_RESIDENT_MULTICHUNK_RELOCATION_SMOKE_PASS"
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

var _world
var _world_environment: WorldEnvironment


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_setup_viewport()
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_resident_render_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	_world.runtime_gpu_resident_chunk_capacity = 12
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("resident multi-chunk world did not start: %s" % _world.get_last_error())
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 1, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0):
		_fail("initial viewers were rejected")
		return
	if not await _wait_for_resident_state(2, 0):
		_fail("initial multi-chunk resident set did not become active: %s" \
			% str(_world.get_gpu_resident_render_status()))
		return
	var initial_status: Dictionary = _world.get_gpu_resident_render_status()
	var initial_activated := int(initial_status.get("activated_chunks", 0))
	var initial_active := int(initial_status.get("active_chunks", 0))

	if not _world.update_viewer(1, 2, Vector3(56, 8, 56), 1, 0) \
			or not _world.update_collision_viewer(2, 2, Vector3(56, 8, 56), 0):
		_fail("relocated viewers were rejected")
		return
	if not await _wait_for_resident_state(initial_activated + 2, 1):
		_fail("relocated resident set did not replace retired chunks: %s" \
			% str(_world.get_gpu_resident_render_status()))
		return
	var outward_status: Dictionary = _world.get_gpu_resident_render_status()
	if not _world.update_viewer(1, 3, Vector3(8, 8, 8), 1, 0) \
			or not _world.update_collision_viewer(2, 3, Vector3(8, 8, 8), 0):
		_fail("returning viewers were rejected")
		return
	if not await _wait_for_resident_state(
		int(outward_status.get("activated_chunks", 0)) + 2,
		int(outward_status.get("retired_chunks", 0)) + 1
	):
		_fail("return relocation did not reuse retired arena slots: %s" \
			% str(_world.get_gpu_resident_render_status()))
		return

	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var status: Dictionary = _world.get_gpu_resident_render_status()
	var effect_status: Dictionary = status.get("effect_status", {})
	var native_metrics: Dictionary = status.get("native_metrics", {})
	var active_chunks := int(status.get("active_chunks", 0))
	if image == null or image.is_empty() \
			or not bool(status.get("running", false)) \
			or int(status.get("retired_chunks", 0)) < 1 \
			or int(status.get("rejected_chunks", -1)) != 0 \
			or int(status.get("recovery_count", -1)) != 0 \
			or active_chunks < 2 or active_chunks > 9 \
			or int(effect_status.get("active_entry_count", -1)) != active_chunks \
			or str(effect_status.get("resource_architecture", "")) \
				!= "paged_shared_arena" \
			or int(effect_status.get("resident_buffer_count_per_entry", -1)) != 0 \
			or int(effect_status.get("arena_active_slot_count", -1)) != active_chunks \
			or int(effect_status.get("arena_page_count", 0)) > 3 \
			or int(effect_status.get("arena_slot_reuses", 0)) < 2 \
			or int(effect_status.get("arena_slot_releases", 0)) < 4 \
			or int(effect_status.get("packing_requests", -1)) != 0 \
			or int(effect_status.get("native_packed_requests", 0)) < 8 \
			or int(effect_status.get("native_packed_bytes_total", 0)) <= 0 \
			or int(native_metrics.get("capture_reservation_attempts", 0)) < 8 \
			or int(native_metrics.get("reserved_captures", 0)) < 8 \
			or int(native_metrics.get("released_capture_slots", 0)) < 8 \
			or int(native_metrics.get("reserved_capture_slots", -1)) != 0 \
			or int(effect_status.get("resident_entry_count", 0)) > 15 \
			or int(effect_status.get("geometry_readback_bytes", -1)) != 0 \
			or int(native_metrics.get("validation_rejections", -1)) != 0 \
			or int(_world.get_runtime_metrics().get("collision_resources", 0)) < 1:
		_fail("resident relocation contract failed: %s" % str(status))
		return

	_world.end_gpu_resident_render_publication()
	await process_frame
	var recovery := Dictionary(_world.get_backend_terrain().call(
		"get_gpu_resident_render_metrics"
	))
	if bool(recovery.get("enabled", true)) \
			or int(recovery.get("restored_cpu_chunks", 0)) < active_chunks:
		_fail("shutdown did not restore every active CPU visual: %s" % str(recovery))
		return
	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("resident multi-chunk world did not stop cleanly")
		return
	print((
		"%s initial_active=%d activated=%d retired=%d active=%d restored=%d " \
		+ "collision_authority=cpu readback=0 arena_reuses=%d pages=%d " \
		+ "native_packed=1 pre_mesh_admission=1 reservations=%d captures=%d released=%d"
	) % [
		MARKER,
		initial_active,
		int(status.get("activated_chunks", 0)),
		int(status.get("retired_chunks", 0)),
		active_chunks,
		int(recovery.get("restored_cpu_chunks", 0)),
		int(effect_status.get("arena_slot_reuses", 0)),
		int(effect_status.get("arena_page_count", 0)),
		int(native_metrics.get("capture_reservation_attempts", 0)),
		int(native_metrics.get("reserved_captures", 0)),
		int(native_metrics.get("released_capture_slots", 0)),
	])
	_world.queue_free()
	await process_frame
	quit(0)


func _setup_viewport() -> void:
	root.size = Vector2i(640, 480)
	root.content_scale_size = Vector2i(640, 480)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.025, 0.03, 1.0)
	_world_environment = WorldEnvironment.new()
	_world_environment.environment = environment
	root.add_child(_world_environment)
	var camera := Camera3D.new()
	camera.position = Vector3(32, 42, 82)
	root.add_child(camera)
	camera.look_at(Vector3(32, 8, 32), Vector3.UP)
	camera.current = true


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.profile_id = &"gpu_resident_multichunk_relocation_smoke"
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
	profile.profile_id = &"gpu_resident_multichunk_relocation_smoke"
	profile.procedural_preset_id = &"flat"
	profile.source_revision = 640301
	profile.world_chunk_count_x = 4
	profile.world_chunk_count_y = 1
	profile.world_chunk_count_z = 4
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://gpu-resident-relocation-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"gpu_resident_multichunk_relocation_smoke"
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


func _wait_for_resident_state(minimum_activated: int, minimum_retired: int) -> bool:
	for _frame in range(2400):
		var status: Dictionary = _world.get_gpu_resident_render_status()
		var effect_status: Dictionary = status.get("effect_status", {})
		var active_chunks := int(status.get("active_chunks", 0))
		var idle: Dictionary = _world.get_cold_idle_summary()
		if int(status.get("activated_chunks", 0)) >= minimum_activated \
				and int(status.get("retired_chunks", 0)) >= minimum_retired \
				and active_chunks >= 2 \
				and int(effect_status.get("active_entry_count", -1)) == active_chunks \
				and int(status.get("rejected_chunks", 0)) == 0 \
				and bool(idle.get("cold_idle", false)):
			return true
		await process_frame
	return false


func _fail(message: String) -> void:
	if _world != null:
		_world.end_gpu_resident_render_publication()
	push_error("GPU_RESIDENT_MULTICHUNK_RELOCATION_SMOKE_FAIL: " + message)
	quit(1)
