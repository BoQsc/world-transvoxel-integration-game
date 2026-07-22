@tool
extends Node
class_name WtTerrainMaterialApplicator

const TERRAIN_SHADER := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_palette.gdshader")
const WATER_SHADER := preload("res://addons/world_transvoxel_terrain/material/wt_static_water.gdshader")
const CHECKER_TEXTURE_FORMAT := "RGBA8"
const CHECKER_TEXTURE_BYTES_PER_PIXEL := 4
const MAX_STANDARD_TEXTURE_BYTES := 4 * 1024
const QUALITY_IMPLEMENTATION := "terrain_material_texture_pipeline_v1"
const PRODUCTION_QUALITY_IMPLEMENTATION := "terrain_production_material_texture_array_explicit_weight_layers_pipeline_v9"
const DEFAULT_PRODUCTION_TEXTURE_RESOLUTION := 512
const VISIBLE_SHADER_MODE := "native_override_world_triplanar_primary_material_texture_array"
const AUTHORED_TEXTURE_ROOT := "res://assets/terrain_textures/material_layers"
const REFERENCE_ROAD_SEGMENTS := [
	Vector4(720.0, 820.0, 900.0, 820.0),
	Vector4(900.0, 820.0, 1080.0, 820.0),
	Vector4(900.0, 680.0, 900.0, 820.0),
	Vector4(900.0, 820.0, 900.0, 960.0),
	Vector4(720.0, 820.0, 760.0, 900.0),
	Vector4(900.0, 960.0, 1040.0, 940.0),
]
const EXPANSIVE_ROAD_SEGMENTS := [
	Vector4(360.0, 360.0, 820.0, 420.0),
	Vector4(820.0, 420.0, 1020.0, 360.0),
	Vector4(1020.0, 360.0, 1640.0, 380.0),
	Vector4(1640.0, 380.0, 1700.0, 900.0),
	Vector4(1700.0, 900.0, 1600.0, 1600.0),
	Vector4(1600.0, 1600.0, 1020.0, 1700.0),
	Vector4(1020.0, 1700.0, 400.0, 1600.0),
	Vector4(400.0, 1600.0, 300.0, 1100.0),
	Vector4(300.0, 1100.0, 400.0, 850.0),
	Vector4(400.0, 850.0, 360.0, 360.0),
	Vector4(400.0, 850.0, 760.0, 1040.0),
	Vector4(760.0, 1040.0, 1024.0, 1024.0),
	Vector4(1024.0, 1024.0, 1280.0, 1000.0),
	Vector4(1280.0, 1000.0, 1700.0, 900.0),
	Vector4(1024.0, 1024.0, 1020.0, 1700.0),
	Vector4(1024.0, 1024.0, 1020.0, 360.0),
	Vector4(760.0, 1040.0, 1020.0, 1700.0),
	Vector4(1280.0, 1000.0, 1600.0, 1600.0),
]

@export var auto_apply: bool = true
@export_range(1, 30, 1) var material_audit_interval_frames: int = 1
@export_range(2, 64, 1) var texture_resolution: int = 16
@export var reference_scene_path: NodePath = ^"../WtTerrainReferenceScene"
@export var visual_mode: StringName = &"production"
@export var clean_albedo_color: Color = Color(0.72, 0.65, 0.50, 1.0)
@export var clean_albedo_texture_path: String = ""
@export_range(0.001, 1.0, 0.001) var clean_texture_world_scale: float = 0.125
@export var clean_triplanar_enabled: bool = true
@export_range(1.0, 16.0, 0.1) var clean_triplanar_blend_sharpness: float = 4.0
@export var clean_material_variation_enabled: bool = false
@export_range(0.0, 1.0, 0.01) var clean_material_variation_strength: float = 0.08
@export_range(0.0, 1.0, 0.01) var clean_roughness: float = 1.0
@export_range(0.0, 1.0, 0.01) var clean_specular: float = 0.0

var _summary := {
	"applied": false,
	"materialized_instances": 0,
	"reapplied_instances": 0,
	"native_render_material_override": false,
	"native_water_material_override": false,
	"texture_resolution": 0,
	"texture_format": CHECKER_TEXTURE_FORMAT,
	"texture_bytes": 0,
	"texture_checksum": 0,
	"shader_mode": VISIBLE_SHADER_MODE,
	"profile_shader_mode": "",
	"profile_id": "",
	"material_ids": [],
	"visual_mode": "production",
	"clean_texture_enabled": false,
	"clean_triplanar_enabled": true,
	"auto_apply_count": 0,
	"deterministic_texture": true,
	"small_texture_budget_bytes": MAX_STANDARD_TEXTURE_BYTES,
	"primary_material_texture_active": false,
	"surface_material_blend_channel": "custom_rgba8_generated_and_authored_material_weights",
	"surface_material_blend_weights_active": false,
	"material_weight_payload_model": "eight_material_generated_authored_rgba8_unorm_v1",
	"material_weight_payload_flat_varyings": false,
	"surface_biome_worldspace_blend_active": false,
	"surface_depth_worldspace_blend_active": false,
	"underground_ore_worldspace_blend_active": false,
	"surface_road_worldspace_blend_active": false,
	"authored_albedo_layers": [],
	"quality_implementation": QUALITY_IMPLEMENTATION,
	"production_quality_implementation": PRODUCTION_QUALITY_IMPLEMENTATION,
	"implementation": "terrain_addon_material_applicator",
}
var _material: ShaderMaterial
var _water_material: ShaderMaterial
var _material_texture_resolution := 0
var _texture_checksum := 0
var _auto_apply_signature := ""
var _auto_apply_count := 0
var _audit_frame_count := 0

func _ready() -> void:
	set_process(auto_apply)

func _process(_delta: float) -> void:
	if _runtime_signature().is_empty():
		_auto_apply_signature = ""
		return
	if not _apply_if_signature_changed():
		_repair_missing_materials_if_needed()

func get_material_summary() -> Dictionary:
	var summary := _summary.duplicate()
	if bool(summary.get("native_render_material_override", false)):
		var backend := _backend_terrain()
		if backend != null and backend.has_method("get_render_resource_count"):
			# Native overrides cover every owned render resource, including newly
			# streamed chunks and temporary replacement records. Read the O(1)
			# native resource count only when telemetry is requested.
			summary["materialized_instances"] = int(
				backend.call("get_render_resource_count")
			)
	return summary

func get_material_quality_summary() -> Dictionary:
	var summary := get_material_summary()
	summary["quality_implementation"] = QUALITY_IMPLEMENTATION
	summary["small_texture_budget_bytes"] = MAX_STANDARD_TEXTURE_BYTES
	summary["deterministic_texture"] = true
	return summary

func apply_materials_now() -> Dictionary:
	var backend := _backend_terrain()
	if backend == null:
		_summary["applied"] = false
		return get_material_summary()
	var material := _material_instance()
	_apply_procedural_material_parameters(material)
	_apply_visual_mode(material)
	var native_override_set := _set_native_material_override(backend, material)
	var water_override_set := _set_native_water_material_override(
		backend,
		_water_material_instance()
	)
	# The native render sink retains both overrides and applies them whenever a
	# chunk is created or replaced. Once that persistent path is installed,
	# polling streaming counters and rescanning the terrain every frame is both
	# redundant and harmful to input/frame pacing. Explicit calls still update
	# runtime visual-mode changes immediately.
	if auto_apply and native_override_set and water_override_set:
		_auto_apply_signature = "persistent_native_overrides"
		set_process(false)
	var result := {"checked": 0, "updated": 0}
	if not native_override_set:
		result = _apply_to_meshes(backend, material)
	else:
		result["checked"] = _count_meshes(backend)
	var profile := _material_profile_summary()
	var resolved_texture_resolution := _material_texture_resolution
	var production_resolution := _production_texture_resolution(profile)
	var production_active := bool(profile.get("production_texture_pipeline", false)) and production_resolution >= 64
	var authored_layers := _authored_albedo_layers()
	var generation := _generation_profile_summary()
	var four_biome_world := str(generation.get("procedural_preset_id", "")) == "four_biomes_lakes_caves_roads"
	var exterior_surface_active := production_active and _procedural_rolling_exterior_surface_enabled(generation)
	var procedural_ore_active := production_active and _procedural_ore_blend_enabled(generation)
	var procedural_road_active := production_active and _procedural_road_blend_enabled(generation)
	_summary = {
		"applied": native_override_set or int(result.get("checked", 0)) > 0,
		"materialized_instances": int(result.get("checked", 0)),
		"reapplied_instances": int(result.get("updated", 0)),
		"native_render_material_override": native_override_set,
		"native_water_material_override": water_override_set,
		"water_material_id": 9,
		"water_surface_pipeline": "material_id_volume_secondary_transvoxel_surface",
		"texture_resolution": resolved_texture_resolution,
		"texture_format": CHECKER_TEXTURE_FORMAT,
		"texture_bytes": _texture_bytes(resolved_texture_resolution),
		"texture_checksum": _texture_checksum,
		"shader_mode": VISIBLE_SHADER_MODE,
		"profile_shader_mode": str(profile.get("shader_mode", "")),
		"profile_id": str(profile.get("profile_id", "unknown")),
		"material_ids": Array(profile.get("material_ids", [])),
		"material_profile_configured": bool(profile.get("configured", false)),
		"auto_apply_count": _auto_apply_count,
		"auto_apply_signature": _auto_apply_signature,
		"deterministic_texture": true,
		"small_texture_budget_bytes": MAX_STANDARD_TEXTURE_BYTES,
		"primary_material_texture_active": production_active,
		"surface_material_blend_channel": "custom_rgba8_generated_and_authored_material_weights",
		"surface_material_blend_weights_active": production_active,
		"material_weight_payload_model": "eight_material_generated_authored_rgba8_unorm_v1",
		"material_weight_payload_flat_varyings": false,
		"surface_biome_worldspace_blend_active": exterior_surface_active,
		"surface_biome_worldspace_blend_model": ("categorical_four_region_exterior_surface_weights_v1" if four_biome_world else "rolling_hills_exterior_surface_biome_weights_v2") if exterior_surface_active else "vertex_material_weights",
		"surface_depth_worldspace_blend_active": exterior_surface_active,
		"surface_depth_worldspace_blend_model": ("four_biome_exterior_surface_distance_orientation_v1" if four_biome_world else "rolling_hills_exterior_surface_distance_orientation_v2") if exterior_surface_active else "none",
		"underground_ore_worldspace_blend_active": procedural_ore_active,
		"underground_ore_worldspace_blend_model": "deterministic_deep_ore_patches_v1_generated_weight_guarded",
		"surface_road_worldspace_blend_active": procedural_road_active,
		"surface_road_worldspace_blend_model": "deterministic_long_connected_asphalt_network_v1_exterior_generated_weight_guarded" if four_biome_world else "deterministic_shallow_asphalt_corridors_v1_exterior_generated_weight_guarded",
		"surface_biome_seed": int(generation.get("seed", 1)),
		"authored_albedo_layers": authored_layers,
		"authored_albedo_layer_count": authored_layers.size(),
		"material_instance_id": material.get_instance_id(),
		"quality_implementation": QUALITY_IMPLEMENTATION,
		"production_quality_implementation": PRODUCTION_QUALITY_IMPLEMENTATION,
		"production_texture_pipeline": bool(profile.get("production_texture_pipeline", false)),
		"production_texture_active": production_active,
		"production_texture_slots": Array(profile.get("production_texture_slots", [])),
		"production_texture_slot_count": int(profile.get("production_texture_slot_count", 0)),
		"sample_material_names": Array(profile.get("sample_material_names", [])),
		"sample_material_count": int(profile.get("sample_material_count", 0)),
		"standard_texture_resolution": production_resolution,
		"production_texture_resolution": production_resolution,
		"production_texture_budget_bytes": int(profile.get("production_texture_budget_bytes", 0)),
		"checker_fallback_enabled": false,
		"visible_texture_target": "production_texture_array_authored_albedo_or_procedural_fallback",
		"mapping_policy": str(profile.get("mapping_policy", "")),
		"blending_policy": str(profile.get("blending_policy", "")),
		"texture_import_policy": str(profile.get("texture_import_policy", "")),
		"visual_mode": str(visual_mode),
		"clean_texture_enabled": not clean_albedo_texture_path.is_empty(),
		"clean_albedo_texture_path": clean_albedo_texture_path,
		"clean_triplanar_enabled": clean_triplanar_enabled,
		"clean_material_variation_enabled": clean_material_variation_enabled,
		"clean_material_variation_strength": clean_material_variation_strength,
		"clean_roughness": clean_roughness,
		"clean_specular": clean_specular,
		"implementation": "terrain_addon_material_applicator",
	}
	return get_material_summary()

func _apply_if_signature_changed() -> bool:
	var signature := _runtime_signature()
	if signature.is_empty() or signature == _auto_apply_signature:
		return false
	_auto_apply_signature = signature
	_auto_apply_count += 1
	apply_materials_now()
	return true

func _repair_missing_materials_if_needed() -> void:
	_audit_frame_count += 1
	if _audit_frame_count < material_audit_interval_frames:
		return
	_audit_frame_count = 0
	if _runtime_signature().is_empty():
		return
	var backend := _backend_terrain()
	if backend != null and backend.has_method("set_render_material_override"):
		return
	if _material != null and _has_unmaterialized_meshes(_backend_terrain(), _material):
		_auto_apply_count += 1
		apply_materials_now()

func _material_instance() -> ShaderMaterial:
	var resolution := _resolved_texture_resolution()
	if _material == null or _material_texture_resolution != resolution:
		_material = _build_material(resolution)
		_material_texture_resolution = resolution
	return _material

func _water_material_instance() -> ShaderMaterial:
	if _water_material == null:
		_water_material = ShaderMaterial.new()
		_water_material.shader = WATER_SHADER
		_water_material.render_priority = 1
	return _water_material

func _build_material(resolution: int) -> ShaderMaterial:
	var shader_material := ShaderMaterial.new()
	shader_material.shader = TERRAIN_SHADER
	shader_material.set_shader_parameter("checker_texture", _checker_texture(resolution))
	var production_resolution := _production_texture_resolution(_material_profile_summary())
	shader_material.set_shader_parameter("terrain_albedo_array", _production_texture_array(production_resolution, &"albedo"))
	shader_material.set_shader_parameter("terrain_normal_array", _production_texture_array(production_resolution, &"normal"))
	shader_material.set_shader_parameter("terrain_roughness_array", _production_texture_array(production_resolution, &"roughness_orm"))
	_apply_procedural_material_parameters(shader_material)
	_apply_visual_mode(shader_material)
	return shader_material

func _apply_procedural_material_parameters(shader_material: ShaderMaterial) -> void:
	var generation := _generation_profile_summary()
	var enabled := _procedural_ore_blend_enabled(generation)
	var seed := int(generation.get("seed", 1))
	var four_biome_world := str(generation.get("procedural_preset_id", "")) == "four_biomes_lakes_caves_roads"
	shader_material.set_shader_parameter("procedural_ore_worldspace_blend_enabled", enabled)
	shader_material.set_shader_parameter("procedural_seed_phase", float(seed % 100000) * 0.0001)
	shader_material.set_shader_parameter("procedural_ore_blend_width", 0.12)
	shader_material.set_shader_parameter("procedural_four_biome_world_enabled", four_biome_world)
	shader_material.set_shader_parameter("procedural_road_half_width", 8.0 if four_biome_world else 6.0)
	shader_material.set_shader_parameter("procedural_road_shoulder_width", 8.0 if four_biome_world else 5.0)
	shader_material.set_shader_parameter(
		"procedural_rolling_exterior_surface_enabled",
		_procedural_rolling_exterior_surface_enabled(generation)
	)
	shader_material.set_shader_parameter("procedural_surface_cover_full_depth", 1.25)
	shader_material.set_shader_parameter("procedural_surface_cover_fade_depth", 2.75)
	shader_material.set_shader_parameter("procedural_surface_cover_normal_start", -0.10)
	shader_material.set_shader_parameter("procedural_surface_cover_normal_end", 0.30)
	shader_material.set_shader_parameter("procedural_surface_biome_height_blend_width", 2.0)
	shader_material.set_shader_parameter("procedural_surface_biome_noise_blend_width", 0.14)
	shader_material.set_shader_parameter(
		"procedural_world_size_xz",
		Vector2(
			maxf(16.0, float(int(generation.get("world_chunk_count_x", 128)) * 16)),
			maxf(16.0, float(int(generation.get("world_chunk_count_z", 128)) * 16))
		)
	)
	shader_material.set_shader_parameter(
		"procedural_road_worldspace_blend_enabled",
		_procedural_road_blend_enabled(generation)
	)
	var road_segments: Array = EXPANSIVE_ROAD_SEGMENTS if four_biome_world else REFERENCE_ROAD_SEGMENTS
	for index in range(road_segments.size()):
		var segment: Vector4 = road_segments[index]
		shader_material.set_shader_parameter(
			"procedural_road_grade_%d" % index,
			Vector2(
				_procedural_source_height(Vector2(segment.x, segment.y), generation),
				_procedural_source_height(Vector2(segment.z, segment.w), generation)
			)
		)

func _procedural_ore_blend_enabled(generation: Dictionary) -> bool:
	return str(generation.get("source_mode", "")) == "DETERMINISTIC_REFERENCE" and \
		str(generation.get("underground_patch_model", "")) == "deterministic_deep_ore_patches_v1"

func _procedural_road_blend_enabled(generation: Dictionary) -> bool:
	if str(generation.get("source_mode", "")) != "DETERMINISTIC_REFERENCE":
		return false
	var preset := str(generation.get("procedural_preset_id", ""))
	var model := str(generation.get("road_network_model", ""))
	return (preset == "rolling_hills_cave_roads" and model == "deterministic_shallow_asphalt_corridors_v1") or \
		(preset == "four_biomes_lakes_caves_roads" and model == "deterministic_long_connected_asphalt_network_v1")


func _procedural_rolling_exterior_surface_enabled(generation: Dictionary) -> bool:
	if str(generation.get("source_mode", "")) != "DETERMINISTIC_REFERENCE":
		return false
	if str(generation.get("surface_biome_model", "")) not in [
		"deterministic_macro_surface_biomes_v1",
		"deterministic_four_region_surface_biomes_v1",
	]:
		return false
	return str(generation.get("procedural_preset_id", "")) in [
		"rolling_hills_cave",
		"rolling_hills_cave_roads",
		"four_biomes_lakes_caves_roads",
	]


func _procedural_source_height(point: Vector2, generation: Dictionary) -> float:
	if str(generation.get("procedural_preset_id", "")) == "four_biomes_lakes_caves_roads":
		return _procedural_four_biome_height(point, generation)
	return _procedural_rolling_hills_height(point, generation)


func _procedural_rolling_hills_height(point: Vector2, generation: Dictionary) -> float:
	var width := maxf(16.0, float(int(generation.get("world_chunk_count_x", 128)) * 16))
	var depth := maxf(16.0, float(int(generation.get("world_chunk_count_z", 128)) * 16))
	var center := Vector2(width * 0.5 - 0.5, depth * 0.5 - 0.5)
	var normalized := Vector2(
		(point.x - center.x) / maxf(center.x, 1.0),
		(point.y - center.y) / maxf(center.y, 1.0)
	)
	var phase := float(int(generation.get("seed", 1)) % 100000) * 0.0001
	var broad := \
		7.5 * sin(point.x * 0.0052 + phase * 1.7) + \
		5.0 * cos(point.y * 0.0047 - phase * 1.2) + \
		3.0 * sin((point.x + point.y) * 0.0034 + phase)
	var rolling := \
		4.0 * sin((point.x - point.y) * 0.008 + phase) * \
			cos((point.x + point.y) * 0.006 - phase * 0.6)
	var central_mound := 8.0 * exp(-2.7 * (
		pow(normalized.x - 0.03, 2.0) + pow(normalized.y + 0.06, 2.0)
	))
	var shallow_valley := -5.5 * exp(-5.0 * (
		pow(normalized.x + 0.34, 2.0) + pow(normalized.y - 0.22, 2.0)
	))
	var local := \
		1.2 * sin(point.x * 0.018 - phase * 0.5) + \
		0.9 * cos(point.y * 0.016 + phase * 0.9)
	return 26.0 + broad + rolling + central_mound + shallow_valley + local


func _procedural_gaussian_feature(
	point: Vector2,
	center: Vector2,
	radius: Vector2,
	amplitude: float
) -> float:
	var delta := (point - center) / radius
	var distance_squared := delta.length_squared()
	if distance_squared >= 16.0:
		return 0.0
	return amplitude * exp(-distance_squared)


func _procedural_lake_depression_feature(
	point: Vector2,
	center: Vector2,
	radius: Vector2,
	depth: float
) -> float:
	var q := ((point - center) / radius).length()
	if q >= 1.0:
		return 0.0
	var t: float = clampf((q - 0.15) / 0.85, 0.0, 1.0)
	var smooth := t * t * (3.0 - 2.0 * t)
	return depth * (1.0 - smooth)


func _procedural_four_biome_height(point: Vector2, generation: Dictionary) -> float:
	var phase := float(int(generation.get("seed", 1)) % 100000) * 0.0001
	var broad := \
		8.0 * sin(point.x * 0.0031 + phase * 1.4) + \
		6.5 * cos(point.y * 0.0027 - phase * 0.9) + \
		4.5 * sin((point.x + point.y) * 0.0017 + phase * 0.6)
	var rolling := \
		5.0 * sin((point.x - point.y) * 0.0073 + phase) * \
			cos((point.x + point.y) * 0.0058 - phase * 0.4)
	var detail := \
		2.2 * sin(point.x * 0.021 + phase * 0.7) * \
			cos(point.y * 0.019 - phase) + \
		1.4 * sin((point.x + 2.0 * point.y) * 0.034 + phase * 0.2) + \
		0.8 * cos((2.0 * point.x - point.y) * 0.047)
	var features := \
		_procedural_gaussian_feature(point, Vector2(1540.0, 1500.0), Vector2(230.0, 210.0), 38.0) + \
		_procedural_gaussian_feature(point, Vector2(1760.0, 1320.0), Vector2(170.0, 200.0), 28.0) + \
		_procedural_gaussian_feature(point, Vector2(1280.0, 1730.0), Vector2(190.0, 150.0), 26.0) + \
		_procedural_gaussian_feature(point, Vector2(470.0, 1510.0), Vector2(250.0, 230.0), 22.0) + \
		_procedural_gaussian_feature(point, Vector2(700.0, 1700.0), Vector2(210.0, 180.0), 12.0) + \
		_procedural_gaussian_feature(point, Vector2(350.0, 360.0), Vector2(280.0, 230.0), 8.0) + \
		_procedural_gaussian_feature(point, Vector2(800.0, 300.0), Vector2(240.0, 200.0), 5.0)
	var lake_depression := maxf(
		_procedural_lake_depression_feature(point, Vector2(650.0, 700.0), Vector2(230.0, 170.0), 34.0),
		maxf(
			_procedural_lake_depression_feature(point, Vector2(1400.0, 700.0), Vector2(240.0, 170.0), 36.0),
			_procedural_lake_depression_feature(point, Vector2(650.0, 1370.0), Vector2(220.0, 160.0), 38.0)
		)
	)
	return 34.0 + broad + rolling + detail + features - lake_depression

func _apply_visual_mode(shader_material: ShaderMaterial) -> void:
	shader_material.set_shader_parameter("clean_visual_enabled", visual_mode == &"clean")
	shader_material.set_shader_parameter("clean_albedo_color", clean_albedo_color)
	shader_material.set_shader_parameter("clean_texture_world_scale", clean_texture_world_scale)
	shader_material.set_shader_parameter("clean_triplanar_enabled", clean_triplanar_enabled)
	shader_material.set_shader_parameter("clean_triplanar_blend_sharpness", clean_triplanar_blend_sharpness)
	shader_material.set_shader_parameter("clean_material_variation_enabled", clean_material_variation_enabled)
	shader_material.set_shader_parameter("clean_material_variation_strength", clean_material_variation_strength)
	shader_material.set_shader_parameter("clean_roughness", clean_roughness)
	shader_material.set_shader_parameter("clean_specular", clean_specular)
	var texture := _load_clean_albedo_texture()
	shader_material.set_shader_parameter("clean_texture_enabled", texture != null)
	if texture != null:
		shader_material.set_shader_parameter("clean_albedo_texture", texture)

func _load_clean_albedo_texture() -> Texture2D:
	if clean_albedo_texture_path.is_empty():
		return null
	var resource := ResourceLoader.load(clean_albedo_texture_path)
	return resource as Texture2D

func _checker_texture(resolution: int) -> Texture2D:
	var image := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
	var checksum := 0
	for y in range(resolution):
		for x in range(resolution):
			var bright := ((x / 4) + (y / 4)) % 2 == 0
			var byte_value := 255 if bright else 158
			var value := float(byte_value) / 255.0
			checksum = int((checksum + ((x + 1) * 31 + (y + 1) * 17) * byte_value) % 2147483647)
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	_texture_checksum = checksum
	return ImageTexture.create_from_image(image)

func _apply_to_meshes(node: Node, material: Material) -> Dictionary:
	var result := {"checked": 0, "updated": 0}
	_apply_to_meshes_recursive(node, material, result)
	return result

func _count_meshes(node: Node) -> int:
	if node == null:
		return 0
	var count := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		count += 1
	for child in node.get_children():
		if child is Node:
			count += _count_meshes(child)
	return count

func _set_native_material_override(node: Node, material: Material) -> bool:
	if node == null or not node.has_method("set_render_material_override"):
		return false
	node.call("set_render_material_override", material)
	return true

func _set_native_water_material_override(node: Node, material: Material) -> bool:
	if node == null or not node.has_method("set_water_material_override"):
		return false
	node.call("set_water_material_override", material)
	return true

func _apply_to_meshes_recursive(node: Node, material: Material, result: Dictionary) -> void:
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh != null:
			result["checked"] = int(result.get("checked", 0)) + 1
			if instance.material_override != material:
				instance.material_override = material
				result["updated"] = int(result.get("updated", 0)) + 1
	for child in node.get_children():
		if child is Node:
			_apply_to_meshes_recursive(child, material, result)

func _has_unmaterialized_meshes(node: Node, material: Material) -> bool:
	if node == null:
		return false
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh != null and instance.material_override != material:
			return true
	for child in node.get_children():
		if child is Node and _has_unmaterialized_meshes(child, material):
			return true
	return false

func _backend_terrain() -> Node:
	var terrain_world := _terrain_world()
	if terrain_world == null or not terrain_world.has_method("get_backend_terrain"):
		return null
	return terrain_world.call("get_backend_terrain")

func _runtime_signature() -> String:
	var terrain_world := _terrain_world()
	if terrain_world == null or not terrain_world.has_method("get_runtime_metrics"):
		return ""
	var metrics: Dictionary = terrain_world.call("get_runtime_metrics")
	var active_records := int(metrics.get("active_chunk_records", 0))
	var render_resources := int(metrics.get("render_resources", 0))
	var collision_resources := int(metrics.get("collision_resources", 0))
	if active_records <= 0 or render_resources <= 0 or collision_resources <= 0:
		return ""
	var revision := 0
	if terrain_world.has_method("get_world_revision"):
		revision = int(terrain_world.call("get_world_revision"))
	return "%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [
		active_records,
		render_resources,
		collision_resources,
		int(metrics.get("viewer_updates", 0)),
		int(metrics.get("edit_replacements", 0)),
		int(metrics.get("queued_render", 0)),
		int(metrics.get("queued_collision", 0)),
		int(metrics.get("pending_chunk_retirements", 0)),
		int(metrics.get("fully_ready_chunk_records", 0)),
		revision,
	]

func _resolved_texture_resolution() -> int:
	var profile := _material_profile_summary()
	var profile_resolution := int(profile.get("texture_resolution", texture_resolution))
	return int(clamp(profile_resolution, 2, 64))

func _texture_bytes(resolution: int) -> int:
	return resolution * resolution * CHECKER_TEXTURE_BYTES_PER_PIXEL

func _production_texture_resolution(profile: Dictionary) -> int:
	return int(clamp(int(profile.get("standard_texture_resolution", DEFAULT_PRODUCTION_TEXTURE_RESOLUTION)), 16, 1024))

func _production_texture_array(resolution: int, slot: StringName) -> Texture2DArray:
	const TILE_COUNT := 8
	var base := [
		Color(0.24, 0.25, 0.24, 1.0), # 1 deep stone
		Color(0.28, 0.39, 0.20, 1.0), # 2 grass
		Color(0.36, 0.35, 0.33, 1.0), # 3 gravel
		Color(0.56, 0.49, 0.35, 1.0), # 4 sand / player fill
		Color(0.68, 0.70, 0.66, 1.0), # 5 snow
		Color(0.31, 0.32, 0.31, 1.0), # 7 mid rock
		Color(0.48, 0.29, 0.13, 1.0), # 8 ore patch
		Color(0.09, 0.10, 0.11, 1.0), # 10 asphalt
	]
	var images: Array[Image] = []
	for tile in range(TILE_COUNT):
		var image: Image = null
		if slot == &"albedo":
			image = _authored_albedo_image(tile, resolution)
		if image == null:
			image = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
			for y in range(resolution):
				for x in range(resolution):
					var c: Color = base[tile]
					if slot == &"normal":
						c = _production_normal_texel(tile, x, y)
					elif slot == &"roughness_orm":
						c = _production_roughness_texel(tile)
					else:
						c = _production_albedo_texel(c, tile, x, y)
					image.set_pixel(x, y, c)
		image.generate_mipmaps(slot == &"normal")
		images.append(image)
	var texture_array := Texture2DArray.new()
	var error := texture_array.create_from_images(images)
	if error != OK:
		push_error("failed to create production texture array: %s" % str(error))
	return texture_array

func _authored_albedo_layers() -> Array:
	var layers := []
	for tile in range(8):
		var path := _first_existing_authored_albedo_path(tile)
		if not path.is_empty():
			layers.append(_material_layer_name(tile))
	return layers

func _authored_albedo_image(tile: int, resolution: int) -> Image:
	var path := _first_existing_authored_albedo_path(tile)
	if path.is_empty():
		return null
	var texture := ResourceLoader.load(path) as Texture2D
	if texture == null:
		push_warning("authored terrain texture failed to load: %s" % path)
		return null
	var image := texture.get_image()
	if image == null:
		push_warning("authored terrain texture has no image: %s" % path)
		return null
	image = image.duplicate()
	image.convert(Image.FORMAT_RGBA8)
	if image.get_width() != resolution or image.get_height() != resolution:
		image.resize(resolution, resolution, Image.INTERPOLATE_LANCZOS)
	return image

func _first_existing_authored_albedo_path(tile: int) -> String:
	for path in _authored_albedo_candidates(tile):
		if ResourceLoader.exists(path) or FileAccess.file_exists(path):
			return path
	return ""

func _authored_albedo_candidates(tile: int) -> Array[String]:
	var names: Array[String] = []
	match tile:
		0:
			names = ["deep_stone_albedo", "stone_albedo", "stone_diff", "rock_albedo"]
		1:
			names = ["grass_albedo", "grass_diff"]
		2:
			names = ["gravel_albedo", "gravel_diff"]
		3:
			names = ["sand_albedo", "sand_diff", "coast_sand_01_diff_1k"]
		4:
			names = ["snow_albedo", "snow_diff"]
		5:
			names = ["mid_rock_albedo", "rock_albedo", "rock_diff"]
		6:
			names = ["ore_patch_albedo", "ore_albedo", "ore_diff"]
		_:
			names = ["asphalt_albedo", "road_asphalt_albedo", "asphalt_diff"]
	var candidates: Array[String] = []
	for name in names:
		for extension in [".png", ".jpg", ".jpeg", ".webp"]:
			candidates.append("%s/%s%s" % [AUTHORED_TEXTURE_ROOT, name, extension])
			candidates.append("res://assets/terrain_textures/%s%s" % [name, extension])
	return candidates

func _material_layer_name(tile: int) -> String:
	match tile:
		0:
			return "deep_stone"
		1:
			return "grass"
		2:
			return "gravel"
		3:
			return "sand"
		4:
			return "snow"
		5:
			return "mid_rock"
		6:
			return "ore_patch"
		_:
			return "asphalt"

func _production_albedo_texel(base: Color, tile: int, x: int, y: int) -> Color:
	var coarse := _production_noise(tile, int(x / 4), int(y / 4), 1)
	var fine := _production_noise(tile, x, y, 2)
	var accent := _production_noise(tile, int(x / 2), int(y / 2), 3)
	var scale := 0.90 + 0.16 * coarse + 0.06 * fine
	if tile == 1:
		scale *= 0.92 + 0.18 * accent
	elif tile == 2:
		scale *= 0.88 + 0.20 * coarse
	elif tile == 4:
		scale *= 0.96 + 0.05 * fine
	elif tile == 6:
		scale *= 0.78 + 0.22 * fine
		if accent > 0.74:
			base = Color(0.84, 0.56, 0.22, 1.0)
	elif tile == 7:
		scale *= 0.86 + 0.10 * fine
		if accent > 0.82:
			base = Color(0.18, 0.19, 0.20, 1.0)
	return Color(
		clamp(base.r * scale, 0.0, 1.0),
		clamp(base.g * scale, 0.0, 1.0),
		clamp(base.b * scale, 0.0, 1.0),
		1.0
	)

func _production_normal_texel(tile: int, x: int, y: int) -> Color:
	var strength := 0.018
	if tile == 2 or tile == 5:
		strength = 0.026
	elif tile == 6:
		strength = 0.032
	elif tile == 7:
		strength = 0.012
	var bump := (_production_noise(tile, x, y, 4) - 0.5) * strength
	return Color(0.5 + bump, 0.5 - bump, 1.0, 1.0)


func _production_noise(tile: int, x: int, y: int, salt: int) -> float:
	var n := posmod(x * 157 + y * 311 + tile * 911 + salt * 619, 10007)
	n = posmod(n * n * 73 + n * 19 + 97, 10009)
	return float(n) / 10008.0

func _production_roughness_texel(tile: int) -> Color:
	var roughness := 0.82
	if tile == 1:
		roughness = 0.95
	elif tile == 4:
		roughness = 0.74
	elif tile == 6:
		roughness = 0.58
	elif tile == 7:
		roughness = 0.88
	return Color(0.0, roughness, 1.0, 1.0)

func _terrain_world() -> Node:
	var reference := get_node_or_null(reference_scene_path)
	if reference == null or not reference.has_method("get_terrain_world"):
		return null
	return reference.call("get_terrain_world")

func _material_profile_summary() -> Dictionary:
	var terrain_world := _terrain_world()
	if terrain_world == null:
		return {}
	var profile = terrain_world.get("material_profile")
	if profile != null and profile.has_method("get_contract_summary"):
		var summary := Dictionary(profile.call("get_contract_summary"))
		summary["configured"] = true
		return summary
	return {}

func _generation_profile_summary() -> Dictionary:
	var terrain_world := _terrain_world()
	if terrain_world == null:
		return {}
	var profile = terrain_world.get("generation_profile")
	if profile != null and profile.has_method("get_contract_summary"):
		return Dictionary(profile.call("get_contract_summary"))
	return {}
