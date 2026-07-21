@tool
extends Node3D
class_name WtTerrainReferenceScene

const TerrainProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const MaterialProfile := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_material_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const RecoveryPolicy := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_recovery_policy.gd")
const DebugSnapshot := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_debug_snapshot.gd")
const DebugOverlayFormatter := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_debug_overlay_formatter.gd")

const IMPLEMENTATION := "local_reference_scene_scaffold"
const RUNTIME_IMPLEMENTATION := "backend_reference_scene_runtime_smoke"
const OVERLAY_IMPLEMENTATION := "debug_overlay_category_rendering"

@export var terrain_world_path: NodePath = ^"TerrainWorld"
@export var status_label_path: NodePath = ^"DebugOverlay/Panel/StatusLabel"
@export var refresh_on_ready: bool = true
@export var debug_overlay_enabled: bool = true

var _last_debug_snapshot: Dictionary = {}


func _ready() -> void:
	_sync_debug_overlay_visibility()
	if refresh_on_ready:
		refresh_debug_snapshot()


func get_terrain_world() -> Node:
	return get_node_or_null(terrain_world_path)


func ensure_reference_defaults() -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null:
		return false
	if terrain_world.get("terrain_profile") == null:
		terrain_world.set("terrain_profile", TerrainProfile.new())
	if terrain_world.get("generation_profile") == null:
		terrain_world.set("generation_profile", GenerationProfile.new())
	if terrain_world.get("storage_profile") == null:
		terrain_world.set("storage_profile", StorageProfile.new())
	if terrain_world.get("recovery_policy") == null:
		terrain_world.set("recovery_policy", RecoveryPolicy.new())
	if terrain_world.get("material_profile") == null:
		terrain_world.set("material_profile", MaterialProfile.new())
	return true


func refresh_debug_snapshot() -> Dictionary:
	if not ensure_reference_defaults():
		_last_debug_snapshot = {
			"implementation": IMPLEMENTATION,
			"error": "terrain world missing",
		}
		return _last_debug_snapshot
	_last_debug_snapshot = DebugSnapshot.capture(get_terrain_world())
	_last_debug_snapshot["reference_scene"] = get_reference_scene_summary(false)
	_last_debug_snapshot["reference_runtime"] = get_reference_runtime_summary()
	_update_status_label()
	return _last_debug_snapshot


func get_last_debug_snapshot() -> Dictionary:
	return _last_debug_snapshot


func get_reference_scene_summary(include_snapshot: bool = true) -> Dictionary:
	var summary := {
		"scene": "WtTerrainReferenceScene",
		"has_terrain_world": get_terrain_world() != null,
		"has_debug_overlay": get_node_or_null(status_label_path) != null,
		"debug_overlay_enabled": debug_overlay_enabled,
		"implementation": IMPLEMENTATION,
	}
	if include_snapshot:
		summary["debug_snapshot"] = _last_debug_snapshot
	return summary


func start_reference_backend_world() -> bool:
	if not ensure_reference_defaults():
		return false
	var terrain_world := get_terrain_world()
	if not terrain_world.has_method("start_backend_world"):
		return false
	var accepted := bool(terrain_world.call("start_backend_world"))
	refresh_debug_snapshot()
	return accepted


func stop_reference_backend_world() -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("stop_backend_world"):
		return false
	var accepted := bool(terrain_world.call("stop_backend_world"))
	refresh_debug_snapshot()
	return accepted


func update_reference_viewer(
	viewer_id: int,
	revision: int,
	position: Vector3,
	radius_chunks: int,
	maximum_lod: int = 0
) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("update_viewer"):
		return false
	var accepted := bool(terrain_world.call(
		"update_viewer", viewer_id, revision, position, radius_chunks, maximum_lod
	))
	refresh_debug_snapshot()
	return accepted


func remove_reference_viewer(viewer_id: int, revision: int) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("remove_viewer"):
		return false
	var accepted := bool(terrain_world.call("remove_viewer", viewer_id, revision))
	refresh_debug_snapshot()
	return accepted

func update_reference_collision_viewer(
	viewer_id: int,
	revision: int,
	position: Vector3,
	radius_chunks: int
) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("update_collision_viewer"):
		return false
	var accepted := bool(terrain_world.call(
		"update_collision_viewer", viewer_id, revision, position, radius_chunks
	))
	refresh_debug_snapshot()
	return accepted

func remove_reference_collision_viewer(viewer_id: int, revision: int) -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("remove_collision_viewer"):
		return false
	var accepted := bool(terrain_world.call(
		"remove_collision_viewer", viewer_id, revision
	))
	refresh_debug_snapshot()
	return accepted


func is_reference_cold_idle() -> bool:
	var terrain_world := get_terrain_world()
	if terrain_world == null or not terrain_world.has_method("is_cold_idle"):
		return false
	return bool(terrain_world.call("is_cold_idle"))


func get_reference_runtime_summary() -> Dictionary:
	var snapshot := _last_debug_snapshot
	var world := Dictionary(snapshot.get("world", {}))
	var budget := Dictionary(snapshot.get("budget", {}))
	var streaming := Dictionary(snapshot.get("streaming", {}))
	return {
		"backend_state": str(world.get("backend_state", "stopped")),
		"backend_running": bool(world.get("backend_running", false)),
		"cold_idle": bool(budget.get("cold_idle", false)),
		"render_resources": int(budget.get("render_resources", 0)),
		"collision_resources": int(budget.get("collision_resources", 0)),
		"viewer_updates": int(streaming.get("viewer_updates", 0)),
		"viewer_removals": int(streaming.get("viewer_removals", 0)),
		"implementation": RUNTIME_IMPLEMENTATION,
	}


func get_debug_status_text() -> String:
	return "%s\nimplementation=%s" % [
		DebugOverlayFormatter.format_snapshot(_last_debug_snapshot),
		IMPLEMENTATION,
	]


func get_debug_overlay_categories() -> Array[String]:
	return DebugOverlayFormatter.get_rendered_categories(_last_debug_snapshot)


func set_debug_overlay_enabled(enabled: bool) -> void:
	debug_overlay_enabled = enabled
	_sync_debug_overlay_visibility()


func _sync_debug_overlay_visibility() -> void:
	var label := get_node_or_null(status_label_path)
	if label != null:
		var overlay := label.get_parent()
		if overlay != null:
			overlay = overlay.get_parent()
		if overlay is CanvasLayer:
			overlay.visible = debug_overlay_enabled


func _update_status_label() -> void:
	if not debug_overlay_enabled:
		return
	var label := get_node_or_null(status_label_path)
	if label != null:
		label.set("text", get_debug_status_text())
