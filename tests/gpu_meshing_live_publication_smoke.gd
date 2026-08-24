extends SceneTree

const MARKER := "GPU_MESHING_LIVE_PUBLICATION_SMOKE_PASS"
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
const EditOperation := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_operation.gd"
)
const EditBatch := preload(
	"res://addons/world_transvoxel_terrain/edit/wt_terrain_edit_batch.gd"
)

var _world
var _committed_revisions: Array[int] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = TerrainWorld.new()
	_world.terrain_profile = _terrain_profile()
	_world.runtime_profile = _runtime_profile()
	_world.generation_profile = _generation_profile()
	_world.storage_profile = _storage_profile()
	_world.runtime_gpu_meshing_publication_candidate_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	root.add_child(_world)
	_world.edit_committed.connect(_on_edit_committed)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("publication world did not start: %s" % _world.get_last_error())
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 0, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0):
		_fail("publication viewers were rejected: %s" % _world.get_last_error())
		return
	if not await _wait_for_publication(1, 1, 0):
		_fail("initial matched GPU-cell render was not applied")
		return
	var initial_status: Dictionary = _world.get_gpu_meshing_shadow_status()
	var initial_publications := int(initial_status.get("publication_queued", 0))
	var initial_applied := int(_world.get_runtime_metrics().get(
		"application_applied_gpu_candidate_render", 0
	))

	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CONSTRUCT, Vector3(8, 12, 8), 2.0, 3), 6401
	) or not await _wait_for_commit(1):
		_fail("construct edit did not commit: %s" % _world.get_last_error())
		return
	if not await _wait_for_publication(
		initial_publications + 1, initial_applied + 1, 0
	):
		_fail("construct candidate was not applied")
		return

	var after_construct: Dictionary = _world.get_gpu_meshing_shadow_status()
	var construct_publications := int(after_construct.get("publication_queued", 0))
	var construct_applied := int(_world.get_runtime_metrics().get(
		"application_applied_gpu_candidate_render", 0
	))
	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.PLACE_STATIC_WATER, Vector3(4, 12, 4), 2.0, 9),
		6402
	) or not await _wait_for_commit(2):
		_fail("static-water edit did not commit: %s" % _world.get_last_error())
		return
	if not await _wait_for_publication(
		construct_publications + 1, construct_applied + 1, 1
	):
		_fail("static-water candidate was not applied")
		return

	var status: Dictionary = _world.get_gpu_meshing_shadow_status()
	var native_metrics: Dictionary = status.get("native_metrics", {})
	var runtime_metrics: Dictionary = _world.get_runtime_metrics()
	var submitted_candidates := int(runtime_metrics.get(
		"application_submitted_gpu_candidate_render", -1
	))
	var applied_candidates := int(runtime_metrics.get(
		"application_applied_gpu_candidate_render", -1
	))
	if not bool(status.get("publish_matched", false)) \
			or not bool(status.get("gpu_publication_enabled", false)) \
			or bool(status.get("gpu_resident_render_publication", true)) \
			or int(status.get("publication_rejections", -1)) != 0 \
			or int(status.get("mismatched_results", -1)) != 0 \
			or int(native_metrics.get("gpu_publication_finalization_rejections", -1)) != 0 \
			or int(native_metrics.get("gpu_publication_application_rejections", -1)) != 0 \
			or not bool(native_metrics.get("cpu_collision_authority", false)) \
			or bool(native_metrics.get("gpu_resident_render_publication", true)) \
			or submitted_candidates <= 0 \
			or submitted_candidates != applied_candidates \
			or submitted_candidates != int(status.get("publication_queued", -1)) \
			or int(runtime_metrics.get("application_stale_gpu_candidate_render", -1)) != 0:
		_fail("matched publication contract failed: status=%s runtime=%s" % [
			str(status), str(runtime_metrics)
		])
		return

	_world.end_gpu_meshing_shadow()
	var backend: Node = _world.get_backend_terrain()
	if backend == null or not bool(backend.call("begin_gpu_meshing_publication", 1)):
		_fail("native stale-publication fixture could not begin")
		return
	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CARVE, Vector3(8, 12, 8), 1.0, 0), 6403
	) or not await _wait_for_commit(3):
		_fail("stale-publication edit did not commit")
		return
	var stale_request := await _wait_for_native_request(backend)
	if stale_request.is_empty():
		_fail("stale-publication fixture did not capture a remesh")
		return
	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CONSTRUCT, Vector3(8, 12, 8), 0.75, 4), 6404
	) or not await _wait_for_commit(4):
		_fail("stale-publication superseding edit did not commit")
		return
	var stale_completion := Dictionary(backend.call(
		"complete_gpu_meshing_publication_request",
		int(stale_request.get("request_id", 0)),
		Dictionary(stale_request.get("identity", {})),
		[],
		true,
		""
	))
	backend.call("end_gpu_meshing_shadow")
	if str(stale_completion.get("status", "")) != "STALE" \
			or bool(stale_completion.get("publication_queued", true)):
		_fail("superseded GPU-cell render was not rejected: %s" % stale_completion)
		return
	await process_frame
	var final_metrics: Dictionary = _world.get_runtime_metrics()
	if int(final_metrics.get("application_applied_gpu_candidate_render", -1)) \
			!= applied_candidates:
		_fail("stale GPU-cell render reached application")
		return

	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("publication world did not stop cleanly")
		return
	print(
		"%s applied=%d terrain=%d water=%d stale=1 collision_authority=cpu gpu_resident=0" % [
			MARKER,
			applied_candidates,
			int(status.get("terrain_matched_results", 0)),
			int(status.get("static_water_matched_results", 0)),
		]
	)
	_world.queue_free()
	await process_frame
	quit(0)


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.profile_id = &"gpu_meshing_live_publication_smoke"
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
	profile.profile_id = &"gpu_meshing_live_publication_smoke"
	profile.procedural_preset_id = &"flat"
	profile.source_revision = 640101
	profile.world_chunk_count_x = 1
	profile.world_chunk_count_y = 1
	profile.world_chunk_count_z = 1
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://gpu-meshing-live-publication-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"gpu_meshing_live_publication_smoke"
	profile.object_root_path = root_path
	profile.world_manifest_path = root_path.path_join("world.wtworld")
	profile.edit_journal_path = root_path.path_join("world.wtedit")
	profile.snapshot_directory = root_path.path_join("snapshots")
	return profile


func _edit_batch(mode: EditOperation.Mode, center: Vector3, radius: float, material: int):
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
		if _committed_revisions.has(revision) and _world.get_world_revision() == revision:
			return true
		await process_frame
	return false


func _wait_for_publication(
	publication_count: int,
	applied_count: int,
	water_matches: int
) -> bool:
	for _frame in range(1800):
		var status: Dictionary = _world.get_gpu_meshing_shadow_status()
		var metrics: Dictionary = _world.get_runtime_metrics()
		var idle: Dictionary = _world.get_cold_idle_summary()
		if int(status.get("publication_queued", 0)) >= publication_count \
				and int(status.get("static_water_matched_results", 0)) >= water_matches \
				and int(status.get("publication_rejections", 0)) == 0 \
				and int(status.get("mismatched_results", 0)) == 0 \
				and int(metrics.get("application_applied_gpu_candidate_render", 0)) \
					>= applied_count \
				and bool(idle.get("cold_idle", false)) \
				and int(idle.get("render_resources", 0)) >= 1 \
				and int(idle.get("collision_resources", 0)) >= 1:
			return true
		await process_frame
	return false


func _wait_for_native_request(backend: Node) -> Dictionary:
	for _frame in range(1200):
		var request := Dictionary(backend.call("pop_gpu_meshing_shadow_request"))
		if str(request.get("status", "")) == "PASS":
			return request
		await process_frame
	return {}


func _on_edit_committed(revision: int) -> void:
	_committed_revisions.append(revision)


func _fail(message: String) -> void:
	if _world != null:
		_world.end_gpu_meshing_shadow()
	push_error("GPU_MESHING_LIVE_PUBLICATION_SMOKE_FAIL: " + message)
	quit(1)
