@tool
extends Node3D
class_name WtTerrainWorld

const DependencyStatus := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_dependency_status.gd")
const BackendBridge := preload("res://addons/world_transvoxel_terrain/runtime/wt_world_transvoxel_bridge.gd")
const BackendOps := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world_backend_ops.gd")
const Contracts := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world_contracts.gd")
const RuntimeAudit := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_runtime_audit.gd")
const DebugSnapshot := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_debug_snapshot.gd")
const VALIDATION_MARKERS := [
	"a4_phase1_resource_semantics_only",
	"GenerationBackend.start_backend_world",
	"terrain_world_lifecycle",
	"reference_profile_runtime_cold_idle",
	"terrain_addon_api_contract_v1",
]

signal world_snapshot_ready(request_id: int, manifest_path: String, source_revision: int, world_revision: int, page_count: int)
signal world_snapshot_failed(request_id: int, error: String)
signal authoritative_sample_ready(request_id: int, sample: RefCounted)
signal authoritative_sample_failed(request_id: int, error: String)
signal authoritative_samples_ready(request_id: int, samples: Array)
signal authoritative_samples_failed(request_id: int, error: String)
signal edit_committed(world_revision: int)
signal edit_failed(error: String)

@export var terrain_profile: Resource
@export var generation_profile: Resource
@export var storage_profile: Resource
@export var recovery_policy: Resource
@export var material_profile: Resource
@export var auto_report_dependency_status: bool = false
@export_range(0, 65536, 1) var runtime_active_chunk_capacity: int = 0
@export_range(0, 1024, 1) var runtime_viewer_capacity: int = 0
@export_range(0, 65536, 1) var runtime_demand_capacity_per_viewer: int = 0
@export_range(0, 65536, 1) var runtime_render_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_collision_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_lod_refinement_radius_chunks: int = 0
@export_range(0, 128, 1) var runtime_render_apply_budget: int = 0
@export_range(0, 128, 1) var runtime_collision_apply_budget: int = 0
@export_range(0, 240, 1) var runtime_render_transition_frames: int = 0
@export var runtime_shader_fade_parameter_enabled: bool = false
@export var runtime_global_coarse_lod_coverage: bool = false
@export_range(0.0, 1000000.0, 0.01) var runtime_collision_activation_distance: float = 0.0
@export_range(0.0, 1000000.0, 0.01) var runtime_collision_deactivation_distance: float = 0.0

var _backend_terrain: Node
var _backend_config: Resource
var _last_error: String = "ok"
var _last_edit_submission_summary: Dictionary = {}

func _ready() -> void:
	if Engine.is_editor_hint() and auto_report_dependency_status:
		print(get_dependency_status().get("message", ""))

func get_dependency_status() -> Dictionary:
	return DependencyStatus.new().get_status()

func get_bridge_status() -> Dictionary:
	return BackendBridge.new().get_bridge_status()

func get_backend_identity() -> Dictionary:
	return BackendBridge.new().get_backend_identity()

func get_last_error() -> String:
	return _last_error

func get_backend_terrain() -> Node:
	return _backend_terrain

func get_world_state_name() -> String:
	return get_backend_world_state_name()

func get_backend_world_state_name() -> String:
	if _backend_terrain == null or not _backend_terrain.has_method("get_world_state_name"):
		return "stopped"
	return str(_backend_terrain.call("get_world_state_name"))

func get_world_revision() -> int:
	return get_backend_world_revision()

func get_backend_world_revision() -> int:
	if _backend_terrain == null or not _backend_terrain.has_method("get_world_revision"):
		return 0
	return int(_backend_terrain.call("get_world_revision"))

func get_world_source_revision() -> int:
	return get_backend_world_source_revision()

func get_backend_world_source_revision() -> int:
	if _backend_terrain == null or not _backend_terrain.has_method("get_world_source_revision"):
		return 0
	return int(_backend_terrain.call("get_world_source_revision"))

func get_world_page_count() -> int:
	if _backend_terrain == null or not _backend_terrain.has_method("get_world_page_count"):
		return 0
	return int(_backend_terrain.call("get_world_page_count"))

func get_world_error() -> String:
	return get_backend_world_error()

func get_backend_world_error() -> String:
	if _backend_terrain == null or not _backend_terrain.has_method("get_world_error"):
		return _last_error
	return str(_backend_terrain.call("get_world_error"))

func is_world_running() -> bool:
	return is_backend_world_running()

func is_backend_world_running() -> bool:
	if _backend_terrain == null or not _backend_terrain.has_method("is_world_running"):
		return false
	return bool(_backend_terrain.call("is_world_running"))

func start_world() -> bool:
	return start_backend_world()

func start_backend_world() -> bool:
	return BackendOps.start_backend_world(self)

func stop_world() -> bool:
	return stop_backend_world()

func stop_backend_world() -> bool:
	return BackendOps.stop_backend_world(self)

func submit_edit_batch(batch: Resource, author_id: int = 0) -> bool:
	return BackendOps.submit_edit_batch(self, batch, author_id)

func get_last_edit_submission_summary() -> Dictionary:
	return _last_edit_submission_summary

func request_world_compaction(output_directory: String, new_source_revision: int) -> int:
	return BackendOps.request_world_compaction(self, output_directory, new_source_revision)

func request_world_migration(output_directory: String) -> int:
	return BackendOps.request_world_migration(self, output_directory)

func request_authoritative_sample(point: Vector3i, lod: int = 0) -> int:
	return BackendOps.request_authoritative_sample(self, point, lod)

func request_authoritative_samples(points: Array, lod: int = 0) -> int:
	return BackendOps.request_authoritative_samples(self, points, lod)

func update_viewer(viewer_id: int, revision: int, position: Vector3, radius_chunks: int, maximum_lod: int = 0) -> bool:
	return BackendOps.update_viewer(self, viewer_id, revision, position, radius_chunks, maximum_lod)

func remove_viewer(viewer_id: int, revision: int) -> bool:
	return BackendOps.remove_viewer(self, viewer_id, revision)

func query_chunk_state(chunk_coordinate: Vector3i, lod: int) -> RefCounted:
	return BackendOps.query_chunk_state(self, chunk_coordinate, lod)

func get_runtime_metrics() -> Dictionary:
	return RuntimeAudit.get_runtime_metrics(_backend_terrain)

func is_cold_idle() -> bool:
	return RuntimeAudit.is_cold_idle(get_runtime_metrics())

func get_cold_idle_summary() -> Dictionary:
	return RuntimeAudit.get_cold_idle_summary(get_runtime_metrics())

func get_profile_summaries() -> Dictionary:
	return Contracts.profile_summaries(self)

func get_debug_snapshot() -> Dictionary:
	return DebugSnapshot.capture(self)

func get_hot_path_boundary_summary() -> Dictionary:
	return Contracts.hot_path_boundary_summary(self)

func get_terrain_api_contract_summary() -> Dictionary:
	return Contracts.terrain_api_contract_summary(self)

func get_contract_summary() -> Dictionary:
	return Contracts.contract_summary(self)


func _on_backend_edit_committed(world_revision: int) -> void:
	edit_committed.emit(world_revision)


func _on_backend_edit_failed(error: String) -> void:
	edit_failed.emit(error)

func get_a4_phase1_summary() -> Dictionary:
	return Contracts.a4_phase1_summary(self)

func get_a4_phase3_summary() -> Dictionary:
	return Contracts.a4_phase3_summary(self)

func get_a4_phase4_summary() -> Dictionary:
	return Contracts.a4_phase4_summary(self)

func _on_backend_world_snapshot_ready(request_id: int, manifest_path: String, source_revision: int, world_revision: int, page_count: int) -> void:
	world_snapshot_ready.emit(request_id, manifest_path, source_revision, world_revision, page_count)

func _on_backend_world_snapshot_failed(request_id: int, error: String) -> void:
	world_snapshot_failed.emit(request_id, error)

func _on_backend_authoritative_sample_ready(request_id: int, sample: RefCounted) -> void:
	authoritative_sample_ready.emit(request_id, sample)

func _on_backend_authoritative_sample_failed(request_id: int, error: String) -> void:
	authoritative_sample_failed.emit(request_id, error)

func _on_backend_authoritative_samples_ready(request_id: int, samples: Array) -> void:
	authoritative_samples_ready.emit(request_id, samples)

func _on_backend_authoritative_samples_failed(request_id: int, error: String) -> void:
	authoritative_samples_failed.emit(request_id, error)
