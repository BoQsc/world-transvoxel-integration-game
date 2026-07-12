@tool
extends MeshInstance3D
class_name WtTerrainFullMapVisual

const TerrainPaletteShader := preload("res://addons/world_transvoxel_terrain/material/wt_terrain_palette.gdshader")

@export var enabled: bool = true
@export var auto_detect_parent_profile: bool = true
@export var enabled_profile_id: StringName = &"g19_compact_2k_on_demand"
@export_range(1, 4096, 1) var chunk_count_x: int = 128
@export_range(1, 4096, 1) var chunk_count_z: int = 128
@export_range(1.0, 128.0, 1.0) var chunk_size: float = 16.0
@export var seed: int = 19019
@export_range(1, 512, 1) var grid_segments_x: int = 128
@export_range(1, 512, 1) var grid_segments_z: int = 128
@export var vertical_offset: float = -0.08
@export var local_detail_exclusion_enabled: bool = false
@export var local_detail_exclusion_center: Vector2 = Vector2(1024.0, 1024.0)
@export var local_detail_exclusion_half_extent: Vector2 = Vector2(96.0, 96.0)
@export var visual_mode: StringName = &"material_id"
@export var clean_albedo_color: Color = Color(0.72, 0.65, 0.50, 1.0)
@export var clean_albedo_texture_path: String = ""
@export_range(0.001, 1.0, 0.001) var clean_texture_world_scale: float = 0.125

var _built_profile_id: StringName = &""
var _summary: Dictionary = {"enabled": false}


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not Engine.is_editor_hint():
		set_process(true)


func _process(_delta: float) -> void:
	var profile_id := _detected_profile_id()
	if not _should_build(profile_id):
		_clear_visual(profile_id)
		return
	if profile_id != _built_profile_id or mesh == null:
		_build_visual(profile_id)


func get_full_terrain_visual_summary() -> Dictionary:
	return _summary.duplicate(true)


func sample_surface_height(x: float, z: float) -> float:
	# Keep this expression in lockstep with
	# addons/world_transvoxel/src/storage/wt_procedural_world_source.cpp. The
	# compact human/visual profile uses this mesh as the far 2K terrain LOD below
	# the native moving Transvoxel detail window, so a simplified height function
	# can expose false sky holes while the viewer moves.
	var width := max(16.0, float(chunk_count_x) * chunk_size)
	var depth := max(16.0, float(chunk_count_z) * chunk_size)
	var center_x: float = width * 0.5 - 0.5
	var center_z: float = depth * 0.5 - 0.5
	var nx: float = (x - center_x) / max(center_x, 1.0)
	var nz: float = (z - center_z) / max(center_z, 1.0)
	var phase := float(abs(seed) % 100000) * 0.0001
	var radial_distance := nx * nx + nz * nz
	var central_highland := 18.0 * exp(-2.1 * radial_distance)
	var ridge_axis := nz + nx * 0.34 - 0.06
	var ridge_along := nx - 0.05
	var mountain_range := 18.0 * exp(-48.0 * ridge_axis * ridge_axis) * exp(-1.2 * ridge_along * ridge_along)
	var spire_a := 50.0 * exp(-165.0 * ((nx - 0.16) * (nx - 0.16) + (nz + 0.02) * (nz + 0.02)))
	var spire_b := 38.0 * exp(-170.0 * ((nx + 0.16) * (nx + 0.16) + (nz - 0.19) * (nz - 0.19)))
	var spire_c := 34.0 * exp(-190.0 * ((nx - 0.36) * (nx - 0.36) + (nz + 0.30) * (nz + 0.30)))
	var knife_axis := nz + 0.22 * nx + 0.13
	var knife_ridge := 20.0 * exp(-95.0 * knife_axis * knife_axis) * exp(-3.0 * (nx - 0.25) * (nx - 0.25))
	var cliff := 10.0 / (1.0 + exp(-35.0 * (0.20 - nz + 0.18 * nx))) * exp(-1.8 * (nx - 0.18) * (nx - 0.18))
	var basin := -12.0 * exp(-5.0 * ((nx + 0.44) * (nx + 0.44) + (nz - 0.27) * (nz - 0.27)))
	var macro := 4.0 * sin(x * 0.0032 + phase * 1.7) + 3.2 * cos(z * 0.0038 - phase * 1.3) + 2.3 * sin((x + z) * 0.0024 + phase)
	var hills := 2.6 * sin(x * 0.010 + phase) * cos(z * 0.0085 - phase * 0.5) + 1.6 * cos((x - z) * 0.0075 - phase * 0.25)
	var crag := sin(x * 0.045 + phase) * cos(z * 0.041 - phase * 0.5)
	var crag_positive: float = maxf(0.0, crag)
	var crags := 6.0 * crag_positive * crag_positive * exp(-2.1 * radial_distance)
	var long_wave := 1.0 * sin(x * 0.016 + phase) + 0.8 * cos(z * 0.014 - phase)
	var local := 0.45 * cos((x - z) * 0.021 - phase * 0.25)
	return 12.0 + central_highland + mountain_range + spire_a + spire_b + spire_c + knife_ridge + cliff + basin + macro + hills + crags + long_wave + local


func sample_material_id(x: float, z: float) -> int:
	var surface := sample_surface_height(x, z)
	if surface < 7.6:
		return 2
	if surface > 11.0:
		return 5
	var band := _floor_div(int(floor(x)), 96) + _floor_div(int(floor(z)), 96)
	return 4 if band % 3 == 0 else 3


func _detected_profile_id() -> StringName:
	if not auto_detect_parent_profile or get_parent() == null:
		return enabled_profile_id
	var value = get_parent().get("playtest_profile_id")
	return StringName(str(value))


func _should_build(profile_id: StringName) -> bool:
	if not enabled:
		return false
	if String(enabled_profile_id).is_empty():
		return true
	return profile_id == enabled_profile_id


func _clear_visual(profile_id: StringName) -> void:
	if mesh != null:
		mesh = null
	visible = false
	_built_profile_id = profile_id
	_summary = {
		"enabled": false,
		"profile_id": str(profile_id),
		"expected_profile_id": str(enabled_profile_id),
	}


func _build_visual(profile_id: StringName) -> void:
	var width := float(chunk_count_x) * chunk_size
	var depth := float(chunk_count_z) * chunk_size
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for z_index in range(grid_segments_z + 1):
		var z := depth * float(z_index) / float(grid_segments_z)
		for x_index in range(grid_segments_x + 1):
			var x := width * float(x_index) / float(grid_segments_x)
			vertices.append(Vector3(x, sample_surface_height(x, z) + vertical_offset, z))
			normals.append(Vector3.UP)
			colors.append(_visual_color(sample_material_id(x, z)))
			uvs.append(Vector2(x * _clean_texture_uv_scale(), z * _clean_texture_uv_scale()))
	var excluded_cells := 0
	for z_cell in range(grid_segments_z):
		for x_cell in range(grid_segments_x):
			var cell_center_x := width * (float(x_cell) + 0.5) / float(grid_segments_x)
			var cell_center_z := depth * (float(z_cell) + 0.5) / float(grid_segments_z)
			if _is_inside_local_detail_exclusion(cell_center_x, cell_center_z):
				excluded_cells += 1
				continue
			var a := z_cell * (grid_segments_x + 1) + x_cell
			var b := a + 1
			var c := a + grid_segments_x + 1
			var d := c + 1
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	array_mesh.surface_set_material(0, _make_material())
	mesh = array_mesh
	visible = true
	_built_profile_id = profile_id
	_summary = {
		"enabled": true,
		"profile_id": str(profile_id),
		"coverage_blocks_x": int(round(width)),
		"coverage_blocks_z": int(round(depth)),
		"chunk_count_x": chunk_count_x,
		"chunk_count_z": chunk_count_z,
		"grid_segments_x": grid_segments_x,
		"grid_segments_z": grid_segments_z,
		"vertices": vertices.size(),
		"triangles": int(indices.size() / 3),
		"visual_layer_kind": "full_map_deterministic_procedural_lod",
		"visual_mode": str(visual_mode),
		"native_detail_layer": "local_transvoxel_chunks",
		"active_window_is_detail_layer_only": true,
		"local_detail_exclusion_enabled": local_detail_exclusion_enabled,
		"local_detail_exclusion_center_x": local_detail_exclusion_center.x,
		"local_detail_exclusion_center_z": local_detail_exclusion_center.y,
		"local_detail_exclusion_half_extent_x": local_detail_exclusion_half_extent.x,
		"local_detail_exclusion_half_extent_z": local_detail_exclusion_half_extent.y,
		"local_detail_exclusion_cells": excluded_cells,
	}


func _make_material() -> Material:
	if visual_mode == &"clean":
		return _make_clean_shader_material()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	material.albedo_color = Color.WHITE
	return material


func _make_clean_shader_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	# The full-map LOD is a far heightfield backdrop, not the native Transvoxel
	# mesh. Disable culling only here so grazing/underside views of the backdrop
	# do not look like terrain holes. Native chunks keep their normal material and
	# remain single-sided for manifold/debug validation.
	shader.code = TerrainPaletteShader.code.replace("cull_back", "cull_disabled")
	material.shader = shader
	material.set_shader_parameter("clean_visual_enabled", true)
	material.set_shader_parameter("clean_albedo_color", clean_albedo_color)
	material.set_shader_parameter("clean_texture_world_scale", clean_texture_world_scale)
	material.set_shader_parameter("clean_triplanar_enabled", true)
	material.set_shader_parameter("clean_triplanar_blend_sharpness", 4.0)
	var clean_texture := _load_clean_albedo_texture()
	material.set_shader_parameter("clean_texture_enabled", clean_texture != null)
	if clean_texture != null:
		material.set_shader_parameter("clean_albedo_texture", clean_texture)
	return material


func _load_clean_albedo_texture() -> Texture2D:
	if visual_mode != &"clean" or clean_albedo_texture_path.is_empty():
		return null
	var resource := ResourceLoader.load(clean_albedo_texture_path)
	return resource as Texture2D


func _clean_texture_uv_scale() -> float:
	if visual_mode == &"clean":
		return clean_texture_world_scale
	return 1.0 / 32.0


func _clean_material_albedo_color() -> Color:
	return Color(
		minf(clean_albedo_color.r * 1.15, 1.0),
		minf(clean_albedo_color.g * 1.15, 1.0),
		minf(clean_albedo_color.b * 1.15, 1.0),
		clean_albedo_color.a
	)


func _material_color(material_id: int) -> Color:
	match material_id:
		2:
			return Color(0.68, 0.61, 0.39)
		3:
			return Color(0.34, 0.57, 0.28)
		4:
			return Color(0.46, 0.64, 0.31)
		5:
			return Color(0.45, 0.45, 0.42)
		_:
			return Color(0.5, 0.5, 0.5)


func _visual_color(material_id: int) -> Color:
	if visual_mode == &"clean":
		return clean_albedo_color
	return _material_color(material_id)


func _is_inside_local_detail_exclusion(x: float, z: float) -> bool:
	if not local_detail_exclusion_enabled:
		return false
	return abs(x - local_detail_exclusion_center.x) <= local_detail_exclusion_half_extent.x and \
			abs(z - local_detail_exclusion_center.y) <= local_detail_exclusion_half_extent.y


func _floor_div(value: int, divisor: int) -> int:
	if value >= 0:
		return int(value / divisor)
	return int((value - divisor + 1) / divisor)
