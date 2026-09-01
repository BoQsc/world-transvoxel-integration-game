extends SceneTree

const TerrainWorld := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world.gd")
const TerrainProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd")
const RuntimeProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")

var _world
var _backend: Node


func _initialize() -> void:
	Engine.max_fps = 120
	call_deferred("_run")


func _run() -> void:
	_world = TerrainWorld.new()
	var terrain := TerrainProfile.new()
	terrain.horizontal_cells = 16
	terrain.vertical_cells = 16
	_world.terrain_profile = terrain
	var runtime := RuntimeProfile.create_builtin(RuntimeProfile.Preset.LOW_POWER)
	runtime.procedural_generation_worker_count = 1
	runtime.meshing_worker_count = 0
	_world.runtime_profile = runtime
	var generation := GenerationProfile.new()
	generation.source_mode = GenerationProfile.SourceMode.FLAT
	generation.procedural_preset_id = &"flat"
	generation.source_revision = 640301
	generation.world_chunk_count_x = 1
	generation.world_chunk_count_y = 1
	generation.world_chunk_count_z = 1
	_world.generation_profile = generation
	var storage := StorageProfile.new()
	storage.object_root_path = "user://gpu-application-readiness-%d" % Time.get_ticks_usec()
	storage.world_manifest_path = storage.object_root_path.path_join("world.wtworld")
	storage.edit_journal_path = storage.object_root_path.path_join("world.wtedit")
	storage.snapshot_directory = storage.object_root_path.path_join("snapshots")
	_world.storage_profile = storage
	root.add_child(_world)
	if not _world.start_backend_world() or not await _wait_state("running"):
		_fail("world did not start")
		return
	_backend = _world.get_backend_terrain()
	if not _backend.call("begin_gpu_resident_render_publication", 4):
		_fail("native resident admission did not start")
		return
	# No compute or renderer is needed to test native publication identities.
	_backend.set_process(false)
	if not _world.update_viewer(1, 1, Vector3(8, 8, 8), 0, 0):
		_fail("first viewer rejected")
		return
	var first := await _request()
	if first.is_empty() or not _expect(first, "WAITING_APPLICATION", "initial pending"):
		_fail("live native generation was not distinguished from missing frontend state")
		return
	_backend.set_process(true)
	if not await _wait_records(1):
		_fail("first expectation did not reach frontend")
		return
	if not _world.remove_viewer(1, 2) or not await _wait_records(0):
		_fail("removed chunk did not leave frontend")
		return
	if not _expect(first, "STALE_APPLICATION", "removed"):
		_fail("removed GPU generation waits forever for a nonexistent application record")
		return
	_backend.set_process(false)
	if not _world.update_viewer(1, 3, Vector3(8, 8, 8), 0, 0):
		_fail("readded viewer rejected")
		return
	var second := await _request()
	if second.is_empty() or second.get("generation") == first.get("generation") \
			or not _expect(second, "WAITING_APPLICATION", "readded pending") \
			or not _expect(first, "STALE_APPLICATION", "old generation after readd"):
		_fail("pending new generation and retired generation were conflated")
		return
	_backend.set_process(true)
	_backend.call("end_gpu_resident_render_publication")
	if not _world.stop_backend_world() or not await _wait_state("stopped"):
		_fail("world did not stop")
		return
	_world.queue_free()
	await process_frame
	print("GPU_RESIDENT_APPLICATION_READINESS_PASS pending=2 stale=2 readback=0")
	quit(0)


func _request() -> Dictionary:
	for _frame in range(600):
		var request: Dictionary = _backend.call("pop_gpu_resident_render_request")
		if request.get("status") == "PASS":
			var identity: Dictionary = request["identity"]
			_backend.call("validate_gpu_resident_render_request", request["request_id"], identity)
			return identity
		await process_frame
	return {}


func _expect(identity: Dictionary, status: String, context: String) -> bool:
	var result: Dictionary = _backend.call("get_gpu_resident_render_chunk_readiness", identity)
	print("GPU_APPLICATION_READINESS ", context, " ", JSON.stringify(result))
	return result.get("status") == status and not result.get("ready", true)


func _wait_records(count: int) -> bool:
	for _frame in range(600):
		var metrics: Dictionary = _world.get_runtime_metrics()
		if int(metrics.get("active_chunk_records", -1)) == count \
				and int(metrics.get("scheduler_queued_jobs", -1)) == 0:
			return true
		await process_frame
	return false


func _wait_state(state: String) -> bool:
	for _frame in range(600):
		if _world.get_world_state_name() == state:
			return true
		await process_frame
	return false


func _fail(message: String) -> void:
	if _backend != null:
		_backend.set_process(true)
		_backend.call("end_gpu_resident_render_publication")
	if _world != null:
		_world.stop_backend_world()
		await _wait_state("stopped")
	push_error("GPU_RESIDENT_APPLICATION_READINESS_FAIL: " + message)
	quit(1)
