@tool
extends Resource
class_name WtTerrainRuntimeProfile

enum Preset { LOW_POWER, BALANCED, QUALITY, REFERENCE }

const IMPLEMENTATION := "tqp52_runtime_profile_v1"
const MIB := 1024 * 1024

@export var profile_id: StringName = &"balanced"
@export var preset: Preset = Preset.BALANCED
@export_range(1, 32, 1) var viewer_radius_chunks: int = 6
@export_range(0, 8, 1) var maximum_lod: int = 2
@export_range(0, 16, 1) var collision_radius_chunks: int = 2
@export_range(1, 4096, 1) var maximum_async_requests: int = 64
@export_range(1, 65536, 1) var active_chunk_capacity: int = 256
@export_range(1, 1024, 1) var viewer_capacity: int = 8
@export_range(1, 65536, 1) var demand_capacity_per_viewer: int = 4096
@export_range(0, 16, 1) var lod_refinement_radius_chunks: int = 0
@export_range(1, 8, 1) var procedural_generation_worker_count: int = 2
@export_range(1, 65536, 1) var storage_request_capacity: int = 256
@export_range(1, 65536, 1) var storage_completion_capacity: int = 256
@export_range(1, 65536, 1) var encoded_page_entry_capacity: int = 256
@export_range(1, 1024, 1, "suffix:MiB") var encoded_page_mebibytes: int = 64
@export_range(1, 65536, 1) var decoded_page_entry_capacity: int = 128
@export_range(1, 1024, 1, "suffix:MiB") var decoded_page_mebibytes: int = 64
@export_range(1, 65536, 1) var mesh_entry_capacity: int = 128
@export_range(1, 2048, 1, "suffix:MiB") var mesh_mebibytes: int = 128
@export_range(1, 65536, 1) var render_entry_capacity: int = 128
@export_range(1, 2048, 1, "suffix:MiB") var render_mebibytes: int = 128
@export_range(1, 65536, 1) var collision_entry_capacity: int = 64
@export_range(1, 1024, 1, "suffix:MiB") var collision_mebibytes: int = 64
@export_range(1, 1048576, 1) var trace_event_capacity: int = 65536
@export_range(1, 128, 1) var render_apply_budget: int = 4
@export_range(1, 128, 1) var collision_apply_budget: int = 2
@export_range(1, 33333, 1, "suffix:us") var collision_apply_deadline_us: int = 4000
@export_range(0.0, 1000000.0, 0.01, "suffix:m") var collision_activation_distance: float = 96.0
@export_range(0.0, 1000000.0, 0.01, "suffix:m") var collision_deactivation_distance: float = 128.0
@export_range(0, 240, 1) var render_transition_frames: int = 0
@export var shader_fade_parameter_enabled: bool = false
@export var global_coarse_lod_coverage: bool = false
@export var power_intent: StringName = &"balanced_cpu_reference"


static func create_builtin(kind: Preset) -> WtTerrainRuntimeProfile:
	var profile := WtTerrainRuntimeProfile.new()
	profile.apply_builtin(kind)
	return profile


func apply_builtin(kind: Preset) -> void:
	preset = kind
	_match_common_defaults()
	match kind:
		Preset.LOW_POWER:
			_apply_scale(&"low_power", 3, 2, 96, 4, 1024, 1, 64, 32, 32, 16, 2, 1, 2500)
			power_intent = &"minimum_cpu_gpu_board_work"
		Preset.QUALITY:
			_apply_scale(&"quality", 10, 3, 512, 8, 8192, 4, 512, 256, 256, 128, 8, 4, 5000)
			power_intent = &"maximum_supported_cpu_quality"
		Preset.REFERENCE:
			_apply_scale(&"authoritative_reference", 6, 2, 256, 8, 4096, 2, 256, 128, 128, 64, 4, 2, 4000)
			power_intent = &"repeatable_tqp_reference"
		_:
			_apply_scale(&"balanced", 6, 2, 256, 8, 4096, 2, 256, 128, 128, 64, 4, 2, 4000)
			power_intent = &"balanced_cpu_reference"
	emit_changed()


func get_validation_error() -> String:
	if profile_id.is_empty():
		return "runtime profile_id is required"
	if collision_deactivation_distance < collision_activation_distance:
		return "collision deactivation distance must be at least activation distance"
	if render_entry_capacity > active_chunk_capacity or collision_entry_capacity > active_chunk_capacity:
		return "render and collision entries cannot exceed active chunk capacity"
	if maximum_async_requests > storage_request_capacity:
		return "maximum async requests cannot exceed storage request capacity"
	return ""


func is_valid() -> bool:
	return get_validation_error().is_empty()


func get_backend_config_overrides() -> Dictionary:
	return {
		"active_chunk_capacity": active_chunk_capacity,
		"viewer_capacity": viewer_capacity,
		"demand_capacity_per_viewer": demand_capacity_per_viewer,
		"lod_refinement_radius_chunks": lod_refinement_radius_chunks,
		"procedural_generation_worker_count": procedural_generation_worker_count,
		"storage_request_capacity": storage_request_capacity,
		"storage_completion_capacity": storage_completion_capacity,
		"encoded_page_entry_capacity": encoded_page_entry_capacity,
		"encoded_page_byte_capacity": encoded_page_mebibytes * MIB,
		"decoded_page_entry_capacity": decoded_page_entry_capacity,
		"decoded_page_byte_capacity": decoded_page_mebibytes * MIB,
		"mesh_entry_capacity": mesh_entry_capacity,
		"mesh_byte_capacity": mesh_mebibytes * MIB,
		"render_entry_capacity": render_entry_capacity,
		"render_byte_capacity": render_mebibytes * MIB,
		"collision_entry_capacity": collision_entry_capacity,
		"collision_byte_capacity": collision_mebibytes * MIB,
		"trace_event_capacity": trace_event_capacity,
		"render_apply_budget": render_apply_budget,
		"collision_apply_budget": collision_apply_budget,
		"collision_apply_deadline_us": collision_apply_deadline_us,
		"collision_activation_distance": collision_activation_distance,
		"collision_deactivation_distance": collision_deactivation_distance,
		"render_transition_frames": render_transition_frames,
		"shader_fade_parameter_enabled": shader_fade_parameter_enabled,
		"global_coarse_lod_coverage": global_coarse_lod_coverage,
	}


func get_contract_summary() -> Dictionary:
	return {
		"profile_id": str(profile_id),
		"preset": Preset.keys()[preset],
		"valid": is_valid(),
		"validation_error": get_validation_error(),
		"resolution": {"base_cell_size_m": 1.0, "maximum_lod": maximum_lod},
		"distance": {"viewer_radius_chunks": viewer_radius_chunks, "collision_radius_chunks": collision_radius_chunks},
		"queues": {"maximum_async_requests": maximum_async_requests, "storage_requests": storage_request_capacity, "storage_completions": storage_completion_capacity},
		"memory": {"encoded_page_mib": encoded_page_mebibytes, "decoded_page_mib": decoded_page_mebibytes, "mesh_mib": mesh_mebibytes, "render_mib": render_mebibytes, "collision_mib": collision_mebibytes},
		"collision": {"activation_distance_m": collision_activation_distance, "deactivation_distance_m": collision_deactivation_distance, "apply_budget": collision_apply_budget, "deadline_us": collision_apply_deadline_us},
		"power": {"intent": str(power_intent), "measured_target_status": "unqualified_profile_intent_only"},
		"backend_config": get_backend_config_overrides(),
		"implementation": IMPLEMENTATION,
	}


func _match_common_defaults() -> void:
	maximum_async_requests = 64
	collision_radius_chunks = 2
	lod_refinement_radius_chunks = 0
	storage_completion_capacity = 256
	encoded_page_mebibytes = 64
	decoded_page_mebibytes = 64
	mesh_mebibytes = 128
	render_mebibytes = 128
	collision_mebibytes = 64
	trace_event_capacity = 65536
	render_transition_frames = 0
	shader_fade_parameter_enabled = false
	global_coarse_lod_coverage = false
	collision_activation_distance = 96.0
	collision_deactivation_distance = 128.0


func _apply_scale(id: StringName, radius: int, lod: int, chunks: int, viewers: int, demand: int, workers: int, storage: int, decoded: int, mesh: int, collision: int, render_budget: int, collision_budget: int, deadline: int) -> void:
	profile_id = id
	viewer_radius_chunks = radius
	maximum_lod = lod
	active_chunk_capacity = chunks
	viewer_capacity = viewers
	demand_capacity_per_viewer = demand
	procedural_generation_worker_count = workers
	storage_request_capacity = storage
	storage_completion_capacity = storage
	encoded_page_entry_capacity = storage
	decoded_page_entry_capacity = decoded
	mesh_entry_capacity = mesh
	render_entry_capacity = mesh
	collision_entry_capacity = collision
	render_apply_budget = render_budget
	collision_apply_budget = collision_budget
	collision_apply_deadline_us = deadline
