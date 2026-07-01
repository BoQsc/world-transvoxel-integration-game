@tool
extends Node
class_name WtTerrainMaterialApplicator

const TERRAIN_SHADER := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_palette.gdshader")
const CHECKER_TEXTURE_FORMAT := "RGBA8"
const CHECKER_TEXTURE_BYTES_PER_PIXEL := 4
const MAX_STANDARD_TEXTURE_BYTES := 4 * 1024
const QUALITY_IMPLEMENTATION := "terrain_material_texture_pipeline_v1"
const PRODUCTION_QUALITY_IMPLEMENTATION := "terrain_production_material_texture_pipeline_v1"
const VISIBLE_SHADER_MODE := "addon_uv2_production_atlas"

@export var auto_apply: bool = true
@export_range(1, 30, 1) var material_audit_interval_frames: int = 2
@export_range(2, 64, 1) var texture_resolution: int = 16
@export var reference_scene_path: NodePath = ^"../WtTerrainReferenceScene"

var _summary := {
	"applied": false,
	"materialized_instances": 0,
	"reapplied_instances": 0,
	"texture_resolution": 0,
	"texture_format": CHECKER_TEXTURE_FORMAT,
	"texture_bytes": 0,
	"texture_checksum": 0,
	"shader_mode": VISIBLE_SHADER_MODE,
	"profile_shader_mode": "",
	"profile_id": "",
	"material_ids": [],
	"auto_apply_count": 0,
	"deterministic_texture": true,
	"small_texture_budget_bytes": MAX_STANDARD_TEXTURE_BYTES,
	"quality_implementation": QUALITY_IMPLEMENTATION,
	"production_quality_implementation": PRODUCTION_QUALITY_IMPLEMENTATION,
	"implementation": "terrain_addon_material_applicator",
}
var _material: ShaderMaterial
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
	return _summary.duplicate()

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
	var result := _apply_to_meshes(backend, material)
	var profile := _material_profile_summary()
	var resolved_texture_resolution := _material_texture_resolution
	var production_resolution := _production_texture_resolution(profile)
	var production_active := bool(profile.get("production_texture_pipeline", false)) and production_resolution >= 64
	_summary = {
		"applied": int(result.get("checked", 0)) > 0,
		"materialized_instances": int(result.get("checked", 0)),
		"reapplied_instances": int(result.get("updated", 0)),
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
		"checker_fallback_enabled": true,
		"visible_texture_target": "production_atlas_with_checker_fallback",
		"mapping_policy": str(profile.get("mapping_policy", "")),
		"blending_policy": str(profile.get("blending_policy", "")),
		"texture_import_policy": str(profile.get("texture_import_policy", "")),
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
	if _material != null and _has_unmaterialized_meshes(_backend_terrain(), _material):
		_auto_apply_count += 1
		apply_materials_now()

func _material_instance() -> ShaderMaterial:
	var resolution := _resolved_texture_resolution()
	if _material == null or _material_texture_resolution != resolution:
		_material = _build_material(resolution)
		_material_texture_resolution = resolution
	return _material

func _build_material(resolution: int) -> ShaderMaterial:
	var shader_material := ShaderMaterial.new()
	shader_material.shader = TERRAIN_SHADER
	shader_material.set_shader_parameter("checker_texture", _checker_texture(resolution))
	var production_resolution := _production_texture_resolution(_material_profile_summary())
	shader_material.set_shader_parameter("terrain_albedo_atlas", _production_atlas(production_resolution, &"albedo"))
	shader_material.set_shader_parameter("terrain_normal_atlas", _production_atlas(production_resolution, &"normal"))
	shader_material.set_shader_parameter("terrain_roughness_atlas", _production_atlas(production_resolution, &"roughness_orm"))
	return shader_material

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
	if render_resources <= 0 or collision_resources <= 0 or \
			int(metrics.get("queued_render", 0)) != 0 or \
			int(metrics.get("queued_collision", 0)) != 0 or \
			int(metrics.get("pending_chunk_retirements", 0)) != 0 or \
			int(metrics.get("render_fading_resources", 0)) != 0 or \
			int(metrics.get("fully_ready_chunk_records", -1)) != active_records:
		return ""
	var revision := 0
	if terrain_world.has_method("get_world_revision"):
		revision = int(terrain_world.call("get_world_revision"))
	return "%d:%d:%d:%d:%d:%d" % [
		active_records,
		render_resources,
		collision_resources,
		int(metrics.get("viewer_updates", 0)),
		int(metrics.get("edit_replacements", 0)),
		revision,
	]

func _resolved_texture_resolution() -> int:
	var profile := _material_profile_summary()
	var profile_resolution := int(profile.get("texture_resolution", texture_resolution))
	return int(clamp(profile_resolution, 2, 64))

func _texture_bytes(resolution: int) -> int:
	return resolution * resolution * CHECKER_TEXTURE_BYTES_PER_PIXEL

func _production_texture_resolution(profile: Dictionary) -> int:
	return int(clamp(int(profile.get("standard_texture_resolution", 64)), 16, 512))

func _production_atlas(resolution: int, slot: StringName) -> Texture2D:
	var image := Image.create(resolution * 4, resolution, false, Image.FORMAT_RGBA8)
	var base := [
		Color(0.40, 0.62, 0.22, 1.0),
		Color(0.42, 0.43, 0.42, 1.0),
		Color(0.63, 0.53, 0.36, 1.0),
		Color(0.30, 0.30, 0.32, 1.0),
	]
	for y in range(resolution):
		for x in range(resolution * 4):
			var tile := int(x / resolution)
			var c: Color = base[tile]
			if slot == &"normal":
				c = Color(0.5, 0.5, 1.0, 1.0)
			elif slot == &"roughness_orm":
				c = Color(0.0, 0.76 + float(tile) * 0.04, 1.0, 1.0)
			else:
				var grain := 0.90 + 0.10 * float(((x * 13 + y * 7 + tile * 19) % 11)) / 10.0
				c = Color(c.r * grain, c.g * grain, c.b * grain, 1.0)
			image.set_pixel(x, y, c)
	return ImageTexture.create_from_image(image)

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
