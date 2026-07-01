@tool
extends MeshInstance3D
class_name WtTerrainFullMapVisual

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
	var width := max(16.0, float(chunk_count_x) * chunk_size)
	var depth := max(16.0, float(chunk_count_z) * chunk_size)
	var center_x: float = width * 0.5 - 0.5
	var center_z: float = depth * 0.5 - 0.5
	var nx: float = (x - center_x) / max(center_x, 1.0)
	var nz: float = (z - center_z) / max(center_z, 1.0)
	var phase := float(abs(seed) % 100000) * 0.0001
	var ridge := 3.2 * exp(-3.0 * (nx * nx + nz * nz))
	var long_wave := 0.80 * sin(x * 0.018 + phase) + 0.60 * cos(z * 0.016 - phase)
	var diagonal := 0.40 * sin((x + z) * 0.008 + phase * 0.5)
	var local := 0.28 * cos((x - z) * 0.021 - phase * 0.25)
	return 5.8 + ridge + long_wave + diagonal + local


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
	var indices := PackedInt32Array()
	for z_index in range(grid_segments_z + 1):
		var z := depth * float(z_index) / float(grid_segments_z)
		for x_index in range(grid_segments_x + 1):
			var x := width * float(x_index) / float(grid_segments_x)
			vertices.append(Vector3(x, sample_surface_height(x, z) + vertical_offset, z))
			normals.append(Vector3.UP)
			colors.append(_material_color(sample_material_id(x, z)))
	for z_cell in range(grid_segments_z):
		for x_cell in range(grid_segments_x):
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
		"native_detail_layer": "local_transvoxel_chunks",
		"active_window_is_detail_layer_only": true,
	}


func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	material.albedo_color = Color.WHITE
	return material


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


func _floor_div(value: int, divisor: int) -> int:
	if value >= 0:
		return int(value / divisor)
	return int((value - divisor + 1) / divisor)
