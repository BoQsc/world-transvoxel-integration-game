@tool
extends Node3D

const TerrainProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_profile.gd")
const RuntimeProfile := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_runtime_profile.gd")
const GenerationProfile := preload("res://addons/world_transvoxel_terrain/generation/wt_terrain_generation_profile.gd")
const MaterialProfile := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_material_profile.gd")
const StorageProfile := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_storage_profile.gd")
const RecoveryPolicy := preload("res://addons/world_transvoxel_terrain/storage/wt_terrain_recovery_policy.gd")
const Support := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_large_acceptance_support.gd")

const WORLD_CELLS := Vector3i(2048, 256, 2048)
const WORLD_CHUNKS := Vector3i(128, 16, 128)
const VERTICAL_ORIGIN_CHUNKS := -8
const SOURCE_REVISION := 957001
const VIEWER_ID := 5701
const COLLISION_VIEWER_ID := 5702
const EDIT_CENTER := Vector3(1792.0, 26.0, 1792.0)
const CONSTRUCTION_CENTER := Vector3(1800.0, 42.0, 1792.0)
const TELEPORTS := [
	Vector3(256.0, 40.0, 256.0), Vector3(1024.0, 44.0, 1024.0),
	Vector3(1792.0, 40.0, 1792.0), Vector3(192.0, 40.0, 1792.0),
	Vector3(1792.0, 40.0, 192.0),
]

@export_group("Editor Preview")
@export var editor_preview_enabled := true:
	set(value):
		editor_preview_enabled = value
		if is_inside_tree(): call_deferred("_apply_preview_enabled")
@export_enum("Near", "Center", "Edit Site", "Far Z", "Far X") var editor_teleport_preset := 1
@export var editor_teleport_now := false:
	set(value):
		editor_teleport_now = false
		if value and is_inside_tree(): call_deferred("_apply_editor_teleport")
@export var editor_overview_now := false:
	set(value):
		editor_overview_now = false
		if value and is_inside_tree(): call_deferred("focus_world_overview")
@export var editor_carve_now := false:
	set(value):
		editor_carve_now = false
		if value and is_inside_tree(): call_deferred("submit_edit_and_wait", &"carve", EDIT_CENTER)
@export var editor_construct_now := false:
	set(value):
		editor_construct_now = false
		if value and is_inside_tree(): call_deferred("submit_edit_and_wait", &"construct", CONSTRUCTION_CENTER)
@export var editor_restart_now := false:
	set(value):
		editor_restart_now = false
		if value and is_inside_tree(): call_deferred("_restart_preview")

@export_group("Diagnostics")
@export var show_world_bounds := true:
	set(value):
		show_world_bounds = value
		if is_instance_valid(world_bounds): world_bounds.visible = value
@export var show_resident_bounds := false:
	set(value):
		show_resident_bounds = value
		if is_instance_valid(resident_bounds): resident_bounds.visible = value
@export_group("")

@onready var terrain_world: Node = %TerrainWorld
@onready var material_applicator: Node = %MaterialApplicator
@onready var camera: Camera3D = %Camera3D
@onready var world_bounds: MeshInstance3D = %WorldBounds
@onready var resident_bounds: MeshInstance3D = %ResidentBounds
@onready var viewer_marker: MeshInstance3D = %ViewerMarker
@onready var status_label: Label = %StatusLabel
@onready var profile_label: Label = %ProfileLabel
@onready var viewer_label: Label = %ViewerLabel
@onready var residency_label: Label = %ResidencyLabel
@onready var lod_label: Label = %LodLabel
@onready var pipeline_label: Label = %PipelineLabel
@onready var bounds_toggle: CheckButton = %BoundsToggle
@onready var resident_toggle: CheckButton = %ResidentToggle
@onready var track_toggle: CheckButton = %TrackToggle

var _session_root := ""
var _world_started := false
var _starting := false
var _session_generation := 0
var _viewer_revision := 0
var _collision_revision := 0
var _viewer_position := TELEPORTS[1]
var _published_viewer_position := Vector3(INF, INF, INF)
var _last_metrics := {}
var _last_audit := {}
var _last_render_signature := ""
var _runtime_follow_camera := true
var _looking := false
var _camera_pitch := -0.35
var _camera_yaw := -0.75


func _configure_profiles() -> void:
	var terrain = TerrainProfile.new()
	terrain.profile_id = &"tqp57_large_2048x256"
	terrain.horizontal_cells = WORLD_CELLS.x
	terrain.vertical_cells = WORLD_CELLS.y
	terrain.vertical_origin_cell = VERTICAL_ORIGIN_CHUNKS * 16
	terrain_world.set("terrain_profile", terrain)
	var runtime = RuntimeProfile.new()
	runtime.profile_id = &"tqp57_large_acceptance"
	runtime.viewer_radius_chunks = 2
	runtime.maximum_lod = 2
	runtime.collision_radius_chunks = 1
	runtime.maximum_async_requests = 64
	runtime.active_chunk_capacity = 2048
	runtime.viewer_capacity = 4
	runtime.demand_capacity_per_viewer = 8192
	runtime.lod_refinement_radius_chunks = 1
	runtime.procedural_generation_worker_count = 2
	runtime.storage_request_capacity = 8192
	runtime.storage_completion_capacity = 8192
	runtime.encoded_page_entry_capacity = 2048
	runtime.decoded_page_entry_capacity = 2048
	runtime.mesh_entry_capacity = 2048
	runtime.render_entry_capacity = 2048
	runtime.collision_entry_capacity = 256
	runtime.render_apply_budget = 8
	runtime.collision_apply_budget = 3
	runtime.collision_apply_deadline_us = 12000
	runtime.collision_activation_distance = 64.0
	runtime.collision_deactivation_distance = 96.0
	runtime.power_intent = &"cpu_large_terrain_acceptance"
	terrain_world.set("runtime_profile", runtime)
	var generation = GenerationProfile.new()
	generation.profile_id = &"tqp57_rolling_hills_cave_2k_256"
	generation.seed = 470047
	generation.procedural_preset_id = &"rolling_hills_cave"
	generation.source_revision = SOURCE_REVISION
	generation.world_chunk_count_x = WORLD_CHUNKS.x
	generation.world_chunk_count_y = WORLD_CHUNKS.y
	generation.world_chunk_origin_y = VERTICAL_ORIGIN_CHUNKS
	generation.world_chunk_count_z = WORLD_CHUNKS.z
	generation.source_mode = GenerationProfile.SourceMode.DETERMINISTIC_REFERENCE
	terrain_world.set("generation_profile", generation)
	var storage = StorageProfile.new()
	storage.profile_id = &"tqp57_large_acceptance_session"
	storage.world_manifest_path = _session_root.path_join("world.wtworld")
	storage.object_root_path = _session_root
	storage.edit_journal_path = _session_root.path_join("world.wtedit")
	storage.snapshot_directory = _session_root.path_join("snapshots")
	terrain_world.set("storage_profile", storage)
	terrain_world.set("recovery_policy", RecoveryPolicy.new())
	terrain_world.set("material_profile", MaterialProfile.new())


func _start_preview() -> void:
	if _starting or _world_started or not editor_preview_enabled: return
	_starting = true
	_session_generation += 1
	var generation := _session_generation
	status_label.text = "STARTING"
	Support.remove_tree(_session_root)
	if not bool(terrain_world.call("start_world")):
		_fail_preview("world start rejected: %s" % terrain_world.call("get_last_error")); return
	for _frame in range(1800):
		if generation != _session_generation: return
		if str(terrain_world.call("get_world_state_name")) == "running":
			_world_started = true; break
		await get_tree().process_frame
	if not _world_started:
		_fail_preview("large world did not enter running state"); return
	if not _request_viewer(_viewer_position, true):
		_fail_preview("initial viewer request rejected"); return
	_starting = false
	material_applicator.call("apply_materials_now")
	_refresh_metrics()
	call("_refresh_resident_bounds", true)


func _stop_preview(cleanup: bool) -> Dictionary:
	_session_generation += 1
	_starting = false
	var stopped := true
	if terrain_world != null and bool(terrain_world.call("is_world_running")):
		_viewer_revision += 1; _collision_revision += 1
		terrain_world.call("remove_viewer", VIEWER_ID, _viewer_revision)
		terrain_world.call("remove_collision_viewer", COLLISION_VIEWER_ID, _collision_revision)
		stopped = bool(terrain_world.call("stop_world"))
		for _frame in range(600):
			if str(terrain_world.call("get_world_state_name")) == "stopped": break
			await get_tree().process_frame
	_world_started = false
	_published_viewer_position = Vector3(INF, INF, INF)
	_last_metrics = {}; _last_audit = {}
	call("_clear_resident_bounds")
	if cleanup: Support.remove_tree(_session_root)
	status_label.text = "STOPPED" if stopped else "FAIL: shutdown"
	return {"status": "PASS" if stopped else "FAIL", "world_state": terrain_world.call("get_world_state_name")}


func _request_viewer(position: Vector3, force: bool) -> bool:
	_viewer_position = position
	viewer_marker.position = position
	if not _world_started: return false
	if not force and position.distance_to(_published_viewer_position) < 2.0: return true
	_viewer_revision += 1; _collision_revision += 1
	var accepted := bool(terrain_world.call("update_viewer", VIEWER_ID, _viewer_revision, position, 2, 2))
	accepted = accepted and bool(terrain_world.call("update_collision_viewer", COLLISION_VIEWER_ID, _collision_revision, position, 1))
	if accepted: _published_viewer_position = position
	else: status_label.text = "FAIL: viewer update"
	return accepted


func _refresh_metrics() -> void:
	if not _world_started: return
	_last_metrics = terrain_world.call("get_runtime_metrics")
	_last_audit = call("_collect_live_lod_counts")


func _readiness_status() -> String:
	if not _world_started: return "STARTING" if _starting else "STOPPED"
	var active := int(_last_metrics.get("non_retiring_chunk_records", 0))
	var ready := int(_last_metrics.get("non_retiring_fully_ready_chunk_records", 0))
	return "READY" if active > 0 and ready == active and _queues_are_empty() else "STREAMING"


func _queues_are_empty() -> bool:
	return _work_queues_are_empty() and int(_last_metrics.get("pending_chunk_replacements", 1)) == 0 and int(_last_metrics.get("pending_chunk_retirements", 1)) == 0


func _work_queues_are_empty() -> bool:
	return int(_last_metrics.get("scheduler_queued_jobs", 1)) == 0 and int(_last_metrics.get("storage_queued_requests", 1)) == 0 and int(_last_metrics.get("queued_render", 1)) == 0 and int(_last_metrics.get("total_collision_backlog", 1)) == 0


func _fail_preview(message: String) -> void:
	_starting = false; _world_started = false
	status_label.text = "FAIL: " + message


func _clamp_viewer_position(position: Vector3) -> Vector3:
	return Vector3(clampf(position.x, 16.0, WORLD_CELLS.x - 16.0), clampf(position.y, VERTICAL_ORIGIN_CHUNKS * 16.0 + 8.0, VERTICAL_ORIGIN_CHUNKS * 16.0 + WORLD_CELLS.y - 8.0), clampf(position.z, 16.0, WORLD_CELLS.z - 16.0))


func _focus_camera(target: Vector3) -> void:
	camera.position = target + Vector3(-72.0, 54.0, -96.0)
	camera.look_at(target + Vector3(0.0, -8.0, 0.0), Vector3.UP)
	_camera_pitch = camera.rotation.x
	_camera_yaw = camera.rotation.y
