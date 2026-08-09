@tool
extends Node3D
class_name WtTerrainWorld

const DependencyStatus := preload("res://addons/world_transvoxel_terrain/api/wt_terrain_dependency_status.gd")
const BackendBridge := preload("res://addons/world_transvoxel_terrain/runtime/wt_world_transvoxel_bridge.gd")
const BackendOps := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world_backend_ops.gd")
const Contracts := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world_contracts.gd")
const RuntimeAudit := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_runtime_audit.gd")
const RuntimeState := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_runtime_state.gd")
const RuntimeEvents := preload("res://addons/world_transvoxel_terrain/runtime/wt_terrain_world_runtime_events.gd")
const DebugSnapshot := preload("res://addons/world_transvoxel_terrain/debug/wt_terrain_debug_snapshot.gd")
const VALIDATION_MARKERS := [
	"a4_phase1_resource_semantics_only",
	"GenerationBackend.start_backend_world",
	"terrain_world_lifecycle",
	"reference_profile_runtime_cold_idle",
	"terrain_addon_api_contract_v1",
	"tqp52_generation_aware_readiness_v1",
]

signal world_snapshot_ready(request_id: int, manifest_path: String, source_revision: int, world_revision: int, page_count: int)
signal world_snapshot_failed(request_id: int, error: String)
signal authoritative_sample_ready(request_id: int, sample: RefCounted)
signal authoritative_sample_failed(request_id: int, error: String)
signal authoritative_samples_ready(request_id: int, samples: Array)
signal authoritative_samples_failed(request_id: int, error: String)
signal edit_committed(world_revision: int)
signal edit_failed(error: String)
signal runtime_generation_changed(api_generation: int, running: bool, reason: String)
signal terrain_request_completed(request_id: int, kind: String, api_generation: int, world_revision: int)
signal terrain_request_failed(request_id: int, kind: String, api_generation: int, error: String)
signal terrain_request_cancelled(request_id: int, kind: String, api_generation: int, reason: String)
signal readiness_changed(snapshot: Dictionary)

@export var terrain_profile: Resource
@export var runtime_profile: Resource
@export var generation_profile: Resource
@export var storage_profile: Resource
@export var recovery_policy: Resource
@export var material_profile: Resource
@export var auto_report_dependency_status: bool = false
@export_range(0, 65536, 1) var runtime_active_chunk_capacity: int = 0
@export_range(0, 65536, 1) var runtime_demand_capacity_per_viewer: int = 0
@export_range(0, 65536, 1) var runtime_render_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_collision_entry_capacity: int = 0
@export_range(0, 65536, 1) var runtime_lod_refinement_radius_chunks: int = 0
@export_range(0, 1024, 1) var runtime_viewer_capacity: int = 0
@export_range(0, 8, 1) var runtime_procedural_generation_worker_count: int = 0
@export_range(0, 128, 1) var runtime_render_apply_budget: int = 0
@export_range(0, 128, 1) var runtime_collision_apply_budget: int = 0
@export_range(0, 33333, 1) var runtime_collision_apply_deadline_us: int = 0
@export_range(0, 240, 1) var runtime_render_transition_frames: int = 0
@export var runtime_shader_fade_parameter_enabled: bool = false
@export var runtime_global_coarse_lod_coverage: bool = false
@export_range(0.0, 1000000.0, 0.01) var runtime_collision_activation_distance: float = 0.0
@export_range(0.0, 1000000.0, 0.01) var runtime_collision_deactivation_distance: float = 0.0

var _backend_terrain: Node
var _backend_config: Resource
var _last_error: String = "ok"
var _last_edit_submission_summary: Dictionary = {}
var _runtime_state = RuntimeState.new()

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
	var profile_error := _runtime_state.configure(runtime_profile)
	if not profile_error.is_empty():
		_last_error = profile_error
		return false
	var accepted := BackendOps.start_backend_world(self)
	if accepted:
		_transition_runtime(true, "world_started")
	return accepted

func stop_world() -> bool:
	return stop_backend_world()

func stop_backend_world() -> bool:
	var accepted := BackendOps.stop_backend_world(self)
	if accepted:
		_transition_runtime(false, "world_stopped")
	return accepted

func submit_edit_batch(batch: Resource, author_id: int = 0) -> bool:
	var accepted := BackendOps.submit_edit_batch(self, batch, author_id)
	if accepted:
		_runtime_state.mark_edit_submitted()
		_emit_readiness()
	return accepted

func get_last_edit_submission_summary() -> Dictionary:
	return _last_edit_submission_summary

func request_world_compaction(output_directory: String, new_source_revision: int) -> int:
	return _track_request(&"world_snapshot", BackendOps.request_world_compaction.bind(self, output_directory, new_source_revision))

func request_world_migration(output_directory: String) -> int:
	return _track_request(&"world_snapshot", BackendOps.request_world_migration.bind(self, output_directory))

func request_authoritative_sample(point: Vector3i, lod: int = 0) -> int:
	return _track_request(&"sample", BackendOps.request_authoritative_sample.bind(self, point, lod))

func request_authoritative_samples(points: Array, lod: int = 0) -> int:
	return _track_request(&"samples", BackendOps.request_authoritative_samples.bind(self, points, lod))

func update_viewer(viewer_id: int, revision: int, position: Vector3, radius_chunks: int, maximum_lod: int = 0) -> bool:
	var validation_error := _runtime_state.validate_viewer_update(viewer_id, revision, false)
	if not validation_error.is_empty():
		_last_error = validation_error
		return false
	var accepted := BackendOps.update_viewer(self, viewer_id, revision, position, radius_chunks, maximum_lod)
	if accepted:
		_runtime_state.record_viewer_update(viewer_id, revision, false)
		_emit_readiness()
	return accepted

func remove_viewer(viewer_id: int, revision: int) -> bool:
	var validation_error := _runtime_state.validate_viewer_removal(viewer_id, revision, false)
	if not validation_error.is_empty():
		_last_error = validation_error
		return false
	var accepted := BackendOps.remove_viewer(self, viewer_id, revision)
	if accepted:
		_runtime_state.record_viewer_removal(viewer_id, false)
		_emit_readiness()
	return accepted

func update_collision_viewer(viewer_id: int, revision: int, position: Vector3, radius_chunks: int) -> bool:
	var validation_error := _runtime_state.validate_viewer_update(viewer_id, revision, true)
	if not validation_error.is_empty():
		_last_error = validation_error
		return false
	var accepted := BackendOps.update_collision_viewer(self, viewer_id, revision, position, radius_chunks)
	if accepted:
		_runtime_state.record_viewer_update(viewer_id, revision, true)
		_emit_readiness()
	return accepted

func remove_collision_viewer(viewer_id: int, revision: int) -> bool:
	var validation_error := _runtime_state.validate_viewer_removal(viewer_id, revision, true)
	if not validation_error.is_empty():
		_last_error = validation_error
		return false
	var accepted := BackendOps.remove_collision_viewer(self, viewer_id, revision)
	if accepted:
		_runtime_state.record_viewer_removal(viewer_id, true)
		_emit_readiness()
	return accepted

func query_chunk_state(chunk_coordinate: Vector3i, lod: int) -> RefCounted:
	return BackendOps.query_chunk_state(self, chunk_coordinate, lod)

func get_chunk_readiness(chunk_coordinate: Vector3i, lod: int = 0) -> Dictionary:
	return _runtime_state.chunk_readiness(self, chunk_coordinate, lod)

func get_readiness_snapshot() -> Dictionary:
	return _runtime_state.readiness_snapshot(self)

func get_api_generation() -> int:
	return _runtime_state.get_api_generation()

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

func get_a4_phase1_summary() -> Dictionary:
	return Contracts.a4_phase1_summary(self)

func get_a4_phase3_summary() -> Dictionary:
	return Contracts.a4_phase3_summary(self)

func get_a4_phase4_summary() -> Dictionary:
	return Contracts.a4_phase4_summary(self)

func _on_backend_world_snapshot_ready(request_id: int, manifest_path: String, source_revision: int, world_revision: int, page_count: int) -> void:
	RuntimeEvents.forward_ready(self, _runtime_state, request_id, &"world_snapshot", [manifest_path, source_revision, world_revision, page_count])

func _on_backend_world_snapshot_failed(request_id: int, error: String) -> void:
	RuntimeEvents.forward_failed(self, _runtime_state, request_id, &"world_snapshot", error)

func _on_backend_authoritative_sample_ready(request_id: int, sample: RefCounted) -> void:
	RuntimeEvents.forward_ready(self, _runtime_state, request_id, &"sample", [sample])

func _on_backend_authoritative_sample_failed(request_id: int, error: String) -> void:
	RuntimeEvents.forward_failed(self, _runtime_state, request_id, &"sample", error)

func _on_backend_authoritative_samples_ready(request_id: int, samples: Array) -> void:
	RuntimeEvents.forward_ready(self, _runtime_state, request_id, &"samples", [samples])

func _on_backend_authoritative_samples_failed(request_id: int, error: String) -> void:
	RuntimeEvents.forward_failed(self, _runtime_state, request_id, &"samples", error)

func _on_backend_edit_committed(world_revision: int) -> void:
	RuntimeEvents.forward_edit(self, _runtime_state, true, world_revision)

func _on_backend_edit_failed(error: String) -> void:
	RuntimeEvents.forward_edit(self, _runtime_state, false, error)

func _track_request(kind: StringName, submit: Callable) -> int:
	return RuntimeEvents.track_request(self, _runtime_state, kind, submit)

func _finish_request(request_id: int, kind: StringName, error: String) -> bool:
	return RuntimeEvents.finish_request(self, _runtime_state, request_id, kind, error)

func _transition_runtime(running: bool, reason: String) -> void:
	RuntimeEvents.transition_runtime(self, _runtime_state, running, reason)

func _emit_readiness() -> void:
	RuntimeEvents.emit_readiness(self, _runtime_state)
