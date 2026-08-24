extends SceneTree

const MARKER := "GPU_MESHING_LIVE_SHADOW_SMOKE_PASS"
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
	_world.runtime_gpu_meshing_shadow_enabled = true
	_world.runtime_gpu_meshing_shadow_capacity = 3
	root.add_child(_world)
	_world.edit_committed.connect(_on_edit_committed)
	if not _world.start_backend_world() or not await _wait_for_state("running"):
		_fail("live shadow world did not start: %s" % _world.get_last_error())
		return
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 0, 0) \
			or not _world.update_collision_viewer(2, 1, Vector3(8, 8, 8), 0):
		_fail("live shadow viewers were rejected: %s" % _world.get_last_error())
		return
	if not await _wait_for_shadow_and_cpu(1, 0, 0):
		_fail("initial streamed terrain did not match GPU shadow authority")
		return
	var initial_status: Dictionary = _world.get_gpu_meshing_shadow_status()
	var initial_terrain_matches := int(initial_status.get("terrain_matched_results", 0))

	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CONSTRUCT, Vector3(8, 12, 8), 2.0, 3), 6401
	) or not await _wait_for_commit(1):
		_fail("construct edit did not commit: %s" % _world.get_last_error())
		return
	if not await _wait_for_shadow_and_cpu(initial_terrain_matches + 1, 0, 0):
		_fail("edited terrain did not remesh through the GPU shadow lane")
		return

	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.PLACE_STATIC_WATER, Vector3(4, 12, 4), 2.0, 9),
		6402
	) or not await _wait_for_commit(2):
		_fail("static-water edit did not commit: %s" % _world.get_last_error())
		return
	if not await _wait_for_shadow_and_cpu(initial_terrain_matches + 1, 1, 0):
		_fail(
			"static-water volume did not match GPU shadow authority: shadow=%s idle=%s" % [
				str(_world.get_gpu_meshing_shadow_status()),
				str(_world.get_cold_idle_summary()),
			]
		)
		return

	var shadow_status: Dictionary = _world.get_gpu_meshing_shadow_status()
	var native_metrics: Dictionary = shadow_status.get("native_metrics", {})
	if int(shadow_status.get("mismatched_results", -1)) != 0 \
			or int(shadow_status.get("identity_rejections", -1)) != 0 \
			or not bool(native_metrics.get("cpu_render_authority", false)) \
			or not bool(native_metrics.get("cpu_collision_authority", false)) \
			or bool(native_metrics.get("gpu_publication_enabled", true)):
		_fail("live shadow changed authority or produced a mismatch: %s" % str(shadow_status))
		return

	_world.end_gpu_meshing_shadow()
	var backend: Node = _world.get_backend_terrain()
	if backend == null or not bool(backend.call("begin_gpu_meshing_shadow", 1)):
		_fail("native stale-result fixture could not begin")
		return
	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CARVE, Vector3(8, 12, 8), 1.0, 0), 6403
	) or not await _wait_for_commit(3):
		_fail("stale-result fixture edit did not commit")
		return
	var stale_request := await _wait_for_native_request(backend)
	if stale_request.is_empty():
		_fail("native stale-result fixture did not capture a remesh")
		return
	if not _world.submit_edit_batch(
		_edit_batch(EditOperation.Mode.CONSTRUCT, Vector3(8, 12, 8), 0.75, 4), 6404
	) or not await _wait_for_commit(4):
		_fail("stale-result superseding edit did not commit")
		return
	var stale_completion := Dictionary(backend.call(
		"complete_gpu_meshing_shadow_request",
		int(stale_request.get("request_id", 0)),
		Dictionary(stale_request.get("identity", {})),
		true,
		""
	))
	backend.call("end_gpu_meshing_shadow")
	if str(stale_completion.get("status", "")) != "STALE" \
			or bool(stale_completion.get("published", true)):
		_fail("superseded live result was not rejected as stale: %s" % str(stale_completion))
		return

	if not _world.stop_backend_world() or not await _wait_for_state("stopped"):
		_fail("live shadow world did not stop cleanly")
		return
	print(
		"%s terrain=%d water=%d stale=1 cpu_render=1 cpu_collision=1 gpu_publish=0" % [
			MARKER,
			int(shadow_status.get("terrain_matched_results", 0)),
			int(shadow_status.get("static_water_matched_results", 0)),
		]
	)
	_world.queue_free()
	await process_frame
	quit(0)


func _terrain_profile() -> Resource:
	var profile := TerrainProfile.new()
	profile.profile_id = &"gpu_meshing_live_shadow_smoke"
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
	profile.profile_id = &"gpu_meshing_live_shadow_smoke"
	profile.procedural_preset_id = &"flat"
	profile.source_revision = 640001
	profile.world_chunk_count_x = 1
	profile.world_chunk_count_y = 1
	profile.world_chunk_count_z = 1
	return profile


func _storage_profile() -> Resource:
	var root_path := "user://gpu-meshing-live-shadow-%d" % Time.get_ticks_usec()
	var profile := StorageProfile.new()
	profile.profile_id = &"gpu_meshing_live_shadow_smoke"
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


func _wait_for_shadow_and_cpu(
	terrain_matches: int,
	water_matches: int,
	transition_matches: int
) -> bool:
	for _frame in range(1800):
		var status: Dictionary = _world.get_gpu_meshing_shadow_status()
		var idle: Dictionary = _world.get_cold_idle_summary()
		if int(status.get("terrain_matched_results", 0)) >= terrain_matches \
				and int(status.get("static_water_matched_results", 0)) >= water_matches \
				and int(status.get("transition_matched_results", 0)) >= transition_matches \
				and int(status.get("mismatched_results", 0)) == 0 \
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
	push_error("GPU_MESHING_LIVE_SHADOW_SMOKE_FAIL: " + message)
	quit(1)
