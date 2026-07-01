extends RefCounted
class_name WtTerrainWorldBackendOps

const BackendBridge := preload("res://addons/world_transvoxel_terrain/runtime/wt_world_transvoxel_bridge.gd")
const EditBridge := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_edit_bridge.gd")
const GenerationBackend := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_generation_backend.gd")
const BACKEND_TERRAIN_NODE_NAME := "WT_BackendTerrain"

static func start_backend_world(world) -> bool:
	world._last_error = "ok"
	if world.is_backend_world_running():
		world._last_error = "backend world is already running"
		return false
	if not _validate_storage_profile(world) or not ensure_backend_terrain(world):
		return false
	var manifest_path := str(world.storage_profile.get("world_manifest_path"))
	var object_root := str(world.storage_profile.get("object_root_path"))
	var result := GenerationBackend.start_backend_world(
		world._backend_terrain, world.generation_profile, manifest_path, object_root
	)
	if not bool(result.get("started", false)):
		world._last_error = str(result.get("error", ""))
		if world._last_error.is_empty():
			world._last_error = world.get_backend_world_error()
		return false
	world._last_error = "ok"
	return true

static func stop_backend_world(world) -> bool:
	if world._backend_terrain == null:
		world._last_error = "backend terrain is not instantiated"
		return false
	if not world._backend_terrain.has_method("stop_world"):
		world._last_error = "backend terrain cannot stop worlds"
		return false
	if not bool(world._backend_terrain.call("stop_world")):
		world._last_error = world.get_backend_world_error()
		return false
	world._last_error = "ok"
	return true

static func submit_edit_batch(world, batch: Resource, author_id: int) -> bool:
	if not world.is_backend_world_running():
		world._last_error = "backend world must be running before edit submission"
		return false
	var edit_bridge := EditBridge.new()
	if not edit_bridge.commit_batch(world._backend_terrain, batch, author_id):
		world._last_error = edit_bridge.get_last_error()
		world._last_edit_submission_summary = edit_bridge.get_last_submission_summary()
		return false
	world._last_edit_submission_summary = edit_bridge.get_last_submission_summary()
	world._last_error = "ok"
	return true

static func request_world_compaction(world, output_directory: String, new_source_revision: int) -> int:
	if not world.is_backend_world_running():
		world._last_error = "backend world must be running before world compaction"
		return 0
	if world._backend_terrain == null or not world._backend_terrain.has_method("request_world_compaction"):
		world._last_error = "backend terrain cannot compact world snapshots"
		return 0
	var request_id := int(world._backend_terrain.call(
		"request_world_compaction", output_directory, new_source_revision
	))
	return _finish_request(world, request_id)

static func request_world_migration(world, output_directory: String) -> int:
	if not world.is_backend_world_running():
		world._last_error = "backend world must be running before world migration"
		return 0
	if world._backend_terrain == null or not world._backend_terrain.has_method("request_world_migration"):
		world._last_error = "backend terrain cannot migrate world snapshots"
		return 0
	return _finish_request(world, int(world._backend_terrain.call("request_world_migration", output_directory)))

static func request_authoritative_sample(world, point: Vector3i, lod: int) -> int:
	if not world.is_world_running():
		world._last_error = "world must be running before authoritative sample queries"
		return 0
	if world._backend_terrain == null or not world._backend_terrain.has_method("request_authoritative_sample"):
		world._last_error = "terrain backend cannot query authoritative samples"
		return 0
	return _finish_request(world, int(world._backend_terrain.call("request_authoritative_sample", point, lod)))

static func request_authoritative_samples(world, points: Array, lod: int) -> int:
	if not world.is_world_running():
		world._last_error = "world must be running before authoritative sample queries"
		return 0
	if world._backend_terrain == null or not world._backend_terrain.has_method("request_authoritative_samples"):
		world._last_error = "terrain backend cannot query authoritative sample batches"
		return 0
	return _finish_request(world, int(world._backend_terrain.call("request_authoritative_samples", points, lod)))

static func update_viewer(world, viewer_id: int, revision: int, position: Vector3, radius_chunks: int, maximum_lod: int) -> bool:
	if not world.is_backend_world_running():
		world._last_error = "backend world must be running before viewer updates"
		return false
	if not world._backend_terrain.has_method("update_viewer"):
		world._last_error = "backend terrain cannot update viewers"
		return false
	if not bool(world._backend_terrain.call("update_viewer", viewer_id, revision, position, radius_chunks, maximum_lod)):
		world._last_error = world.get_backend_world_error()
		return false
	world._last_error = "ok"
	return true

static func remove_viewer(world, viewer_id: int, revision: int) -> bool:
	if not world.is_backend_world_running():
		world._last_error = "backend world must be running before viewer removal"
		return false
	if not world._backend_terrain.has_method("remove_viewer"):
		world._last_error = "backend terrain cannot remove viewers"
		return false
	if not bool(world._backend_terrain.call("remove_viewer", viewer_id, revision)):
		world._last_error = world.get_backend_world_error()
		return false
	world._last_error = "ok"
	return true

static func query_chunk_state(world, chunk_coordinate: Vector3i, lod: int) -> RefCounted:
	if world._backend_terrain == null or not world._backend_terrain.has_method("query_chunk_state"):
		world._last_error = "backend terrain cannot query chunk state"
		return null
	return world._backend_terrain.call("query_chunk_state", chunk_coordinate, lod)

static func ensure_backend_terrain(world) -> bool:
	if world._backend_terrain != null and is_instance_valid(world._backend_terrain):
		connect_backend_runtime_signals(world)
		return true
	var bridge := BackendBridge.new()
	var status := bridge.get_bridge_status()
	if not bool(status.get("bridge_ready", false)):
		world._last_error = "world-transvoxel bridge is not ready: %s" % str(status)
		return false
	var terrain = bridge.instantiate_backend_terrain()
	var config = bridge.instantiate_backend_config()
	if terrain == null or config == null:
		world._last_error = "failed to instantiate world-transvoxel backend terrain/config"
		if terrain is Node:
			terrain.free()
		return false
	if not (terrain is Node):
		world._last_error = "world-transvoxel backend terrain is not a Node"
		return false
	world._backend_terrain = terrain
	world._backend_config = config
	world._backend_terrain.name = BACKEND_TERRAIN_NODE_NAME
	world._backend_terrain.set("configuration", world._backend_config)
	world.add_child(world._backend_terrain)
	connect_backend_runtime_signals(world)
	return true

static func connect_backend_runtime_signals(world) -> void:
	if world._backend_terrain == null:
		return
	for pair in [
		["world_snapshot_ready", "_on_backend_world_snapshot_ready"],
		["world_snapshot_failed", "_on_backend_world_snapshot_failed"],
		["authoritative_sample_ready", "_on_backend_authoritative_sample_ready"],
		["authoritative_sample_failed", "_on_backend_authoritative_sample_failed"],
		["authoritative_samples_ready", "_on_backend_authoritative_samples_ready"],
		["authoritative_samples_failed", "_on_backend_authoritative_samples_failed"],
	]:
		var callable := Callable(world, pair[1])
		if world._backend_terrain.has_signal(pair[0]) and not world._backend_terrain.is_connected(pair[0], callable):
			world._backend_terrain.connect(pair[0], callable)

static func _validate_storage_profile(world) -> bool:
	if world.storage_profile == null:
		world._last_error = "storage_profile is required"
		return false
	if not world.storage_profile.has_method("get_validation_error"):
		world._last_error = "storage_profile must expose validation"
		return false
	var validation_error := str(world.storage_profile.call("get_validation_error"))
	if not validation_error.is_empty():
		world._last_error = validation_error
		return false
	if not _resource_has_property(world.storage_profile, "object_root_path"):
		world._last_error = "storage_profile must expose object_root_path"
		return false
	return true

static func _finish_request(world, request_id: int) -> int:
	if request_id <= 0:
		world._last_error = world.get_backend_world_error()
		return 0
	world._last_error = "ok"
	return request_id

static func _resource_has_property(resource: Resource, property_name: String) -> bool:
	for property in resource.get_property_list():
		if str(property.get("name", "")) == property_name:
			return true
	return false
