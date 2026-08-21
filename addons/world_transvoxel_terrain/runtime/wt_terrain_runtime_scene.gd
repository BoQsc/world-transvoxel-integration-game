@tool
extends Node3D
class_name WtTerrainRuntimeScene

const TerrainProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd")
const RuntimeProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const MaterialProfile := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_material_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const RecoveryPolicy := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_recovery_policy.gd")

@export var terrain_world_path: NodePath = ^"TerrainWorld"


func get_terrain_world() -> Node:
	return get_node_or_null(terrain_world_path)


func ensure_runtime_defaults() -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	if terrain_world.get("terrain_profile") == null:
		terrain_world.set("terrain_profile", TerrainProfile.new())
	if terrain_world.get("runtime_profile") == null:
		terrain_world.set(
			"runtime_profile",
			RuntimeProfile.create_builtin(RuntimeProfile.Preset.REFERENCE)
		)
	if terrain_world.get("generation_profile") == null:
		terrain_world.set("generation_profile", GenerationProfile.new())
	if terrain_world.get("storage_profile") == null:
		terrain_world.set("storage_profile", StorageProfile.new())
	if terrain_world.get("recovery_policy") == null:
		terrain_world.set("recovery_policy", RecoveryPolicy.new())
	if terrain_world.get("material_profile") == null:
		terrain_world.set("material_profile", MaterialProfile.new())
	return true


func start_runtime_world() -> bool:
	var terrain_world := get_terrain_world()
	return ensure_runtime_defaults() and bool(terrain_world.call("start_world"))


func stop_runtime_world() -> bool:
	var terrain_world := get_terrain_world()
	return terrain_world != null and bool(terrain_world.call("stop_world"))


func update_runtime_viewer(
	viewer_id: int,
	revision: int,
	position: Vector3,
	radius_chunks: int,
	maximum_lod: int = 0
) -> bool:
	var terrain_world := get_terrain_world()
	return terrain_world != null and bool(terrain_world.call(
		"update_viewer",
		viewer_id,
		revision,
		position,
		radius_chunks,
		maximum_lod
	))


func update_runtime_collision_viewer(
	viewer_id: int,
	revision: int,
	position: Vector3,
	radius_chunks: int
) -> bool:
	var terrain_world := get_terrain_world()
	return terrain_world != null and bool(terrain_world.call(
		"update_collision_viewer", viewer_id, revision, position, radius_chunks
	))
