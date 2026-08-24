@tool
extends RefCounted
class_name WtTerrainGpuMeshingCandidate

const SHADER_PATH := (
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_meshing.glsl"
)
const FIELD_SCHEMA := "world_transvoxel.terrain.gpu_field_batch.v1"
const RESULT_SCHEMA := "world_transvoxel.terrain.gpu_meshing_batch.v1"
const TABLE_SCHEMA := "world_transvoxel.cell_probe.gpu_meshing_tables.v1"
const LOCAL_SIZE := 64
const MAXIMUM_CELL_COUNT := 8192
const MAXIMUM_SAMPLE_COUNT := 1048576
const MAXIMUM_VERTICES_PER_CELL := 12
const MAXIMUM_INDICES_PER_CELL := 36
const STATUS_NAMES := ["Empty", "Ok", "TopologyFailure"]

var _rendering_device: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _tables: Dictionary = {}
var _error := ""


func initialize() -> bool:
	if _rendering_device != null and _shader.is_valid() and _pipeline.is_valid() \
			and not _tables.is_empty():
		return true
	close()
	if not ClassDB.class_exists("WorldTransvoxelCellProbe"):
		_error = "WorldTransvoxelCellProbe is unavailable; fallback tables are forbidden"
		return false
	var probe := ClassDB.instantiate("WorldTransvoxelCellProbe") as RefCounted
	if probe == null or not probe.has_method("get_gpu_meshing_tables"):
		_error = "native GPU meshing table export is unavailable; fallback tables are forbidden"
		return false
	_tables = probe.call("get_gpu_meshing_tables")
	if not _validate_tables(_tables):
		_tables = {}
		return false
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		_error = "GPU meshing shader is unavailable"
		return false
	_rendering_device = RenderingServer.create_local_rendering_device()
	if _rendering_device == null:
		_error = "local RenderingDevice is unavailable; CPU fallback is forbidden"
		return false
	_shader = _rendering_device.shader_create_from_spirv(shader_file.get_spirv())
	if not _shader.is_valid():
		_error = "GPU meshing shader creation failed"
		close()
		return false
	_pipeline = _rendering_device.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_error = "GPU meshing pipeline creation failed"
		close()
		return false
	_error = ""
	return true


func close() -> void:
	if _rendering_device != null:
		if _pipeline.is_valid():
			_rendering_device.free_rid(_pipeline)
		if _shader.is_valid():
			_rendering_device.free_rid(_shader)
		_rendering_device.free()
	_rendering_device = null
	_shader = RID()
	_pipeline = RID()
	_tables = {}


func get_error() -> String:
	return _error


func get_table_identity() -> Dictionary:
	if not initialize():
		return {}
	return {
		"schema": _tables.get("schema", ""),
		"authority": _tables.get("authority", ""),
		"backend_id": _tables.get("backend_id", ""),
		"backend_upstream_revision": _tables.get("backend_upstream_revision", ""),
	}


func mesh_field_batch(field_batch: Dictionary, cells: Array) -> Dictionary:
	if str(field_batch.get("schema", "")) != FIELD_SCHEMA:
		return _failure("TQP-59 GPU field batch schema is required")
	return _mesh_batch(field_batch, cells, "tqp59_gpu_field")


func mesh_explicit_samples(
	densities: PackedFloat32Array,
	gradients: PackedVector3Array,
	materials: PackedInt32Array,
	material_authored: PackedByteArray,
	cells: Array,
	identity: Dictionary = {}
) -> Dictionary:
	if densities.is_empty() or gradients.size() != densities.size() \
			or materials.size() != densities.size() \
			or material_authored.size() != densities.size():
		return _failure("explicit sample arrays must have equal nonzero lengths")
	return _mesh_batch({
		"schema": "world_transvoxel.terrain.explicit_cell_samples.v1",
		"status": "PASS",
		"fallback_used": false,
		"densities": densities,
		"gradients": gradients,
		"materials": materials,
		"material_authored": material_authored,
		"identity": identity,
	}, cells, "explicit_cell_samples")


func _mesh_batch(batch: Dictionary, cells: Array, input_lane: String) -> Dictionary:
	if str(batch.get("status", "")) != "PASS" or bool(batch.get("fallback_used", true)):
		return _failure("GPU meshing input failed or used a fallback")
	var densities: PackedFloat32Array = batch.get("densities", PackedFloat32Array())
	var gradients: PackedVector3Array = batch.get("gradients", PackedVector3Array())
	var materials: PackedInt32Array = batch.get("materials", PackedInt32Array())
	var authored: PackedByteArray = batch.get("material_authored", PackedByteArray())
	if densities.is_empty() or densities.size() > MAXIMUM_SAMPLE_COUNT \
			or gradients.size() != densities.size() or materials.size() != densities.size() \
			or authored.size() != densities.size():
		return _failure("GPU meshing input sample arrays are invalid")
	if cells.is_empty() or cells.size() > MAXIMUM_CELL_COUNT:
		return _failure("GPU meshing cell count is outside the candidate limit")
	if not initialize():
		return _failure(_error)
	var packed := _pack_request(batch, cells, densities, gradients, materials, authored, input_lane)
	if str(packed.get("status", "")) != "PASS":
		return packed
	var started_usec := Time.get_ticks_usec()
	var buffers: Array[RID] = []
	for bytes in packed.get("input_buffers", []):
		_storage_buffer(bytes, buffers)
	var cell_count := cells.size()
	_empty_storage_buffer(cell_count * MAXIMUM_VERTICES_PER_CELL * 16, buffers)
	_empty_storage_buffer(cell_count * MAXIMUM_VERTICES_PER_CELL * 16, buffers)
	_empty_storage_buffer(cell_count * MAXIMUM_VERTICES_PER_CELL * 16, buffers)
	_empty_storage_buffer(cell_count * MAXIMUM_VERTICES_PER_CELL * 16, buffers)
	_empty_storage_buffer(cell_count * MAXIMUM_INDICES_PER_CELL * 4, buffers)
	_empty_storage_buffer(cell_count * 16, buffers)
	_empty_storage_buffer(48, buffers)
	for buffer in buffers:
		if not buffer.is_valid():
			_free_rids(buffers)
			return _failure("GPU meshing storage buffer creation failed")
	var uniforms: Array[RDUniform] = []
	for binding in range(buffers.size()):
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(buffers[binding])
		uniforms.append(uniform)
	var uniform_set := _rendering_device.uniform_set_create(uniforms, _shader, 0)
	if not uniform_set.is_valid():
		_free_rids(buffers)
		return _failure("GPU meshing uniform set creation failed")
	var prepared_usec := Time.get_ticks_usec()
	var compute_list := _rendering_device.compute_list_begin()
	_rendering_device.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rendering_device.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rendering_device.compute_list_dispatch(
		compute_list, int((cell_count + LOCAL_SIZE - 1) / LOCAL_SIZE), 1, 1
	)
	_rendering_device.compute_list_end()
	_rendering_device.submit()
	_rendering_device.sync()
	var synchronized_usec := Time.get_ticks_usec()
	var output_bytes: Array[PackedByteArray] = []
	for index in range(13, 20):
		output_bytes.append(_rendering_device.buffer_get_data(buffers[index]))
	var readback_usec := Time.get_ticks_usec()
	_rendering_device.free_rid(uniform_set)
	_free_rids(buffers)
	return _unpack_result(
		output_bytes,
		cells,
		input_lane,
		batch,
		started_usec,
		prepared_usec,
		synchronized_usec,
		readback_usec
	)


func _pack_request(
	batch: Dictionary,
	cells: Array,
	densities: PackedFloat32Array,
	gradients: PackedVector3Array,
	materials: PackedInt32Array,
	authored: PackedByteArray,
	input_lane: String
) -> Dictionary:
	var field_values := PackedFloat32Array()
	var field_meta := PackedInt32Array()
	field_values.resize(densities.size() * 4)
	field_meta.resize(densities.size() * 4)
	for index in range(densities.size()):
		if not is_finite(densities[index]) or not gradients[index].is_finite():
			return _failure("GPU meshing samples must be finite")
		field_values[index * 4] = densities[index]
		field_values[index * 4 + 1] = gradients[index].x
		field_values[index * 4 + 2] = gradients[index].y
		field_values[index * 4 + 3] = gradients[index].z
		field_meta[index * 4] = materials[index]
		field_meta[index * 4 + 1] = authored[index]
		field_meta[index * 4 + 2] = index
		field_meta[index * 4 + 3] = 1
	var headers := PackedInt32Array()
	var origins := PackedFloat32Array()
	var options := PackedFloat32Array()
	var references := PackedInt32Array()
	headers.resize(cells.size() * 4)
	origins.resize(cells.size() * 4)
	options.resize(cells.size() * 4)
	for cell_index in range(cells.size()):
		if not cells[cell_index] is Dictionary:
			return _failure("GPU meshing cell descriptor is not a Dictionary")
		var cell: Dictionary = cells[cell_index]
		var cell_type := ["regular", "transition"].find(str(cell.get("type", "")))
		var expected_sample_count := 8 if cell_type == 0 else 9
		var sample_indices := PackedInt32Array(cell.get("sample_indices", PackedInt32Array()))
		var orientation := int(cell.get("orientation", 0))
		var origin := _vector3(cell.get("origin", Vector3.ZERO))
		var spacing := float(cell.get("cell_size", cell.get("sample_spacing", 0.0)))
		var transition_width := float(cell.get("transition_width", 0.0))
		var isovalue := float(cell.get("isovalue", 0.0))
		if cell_type < 0 or sample_indices.size() != expected_sample_count \
				or not origin.is_finite() or not is_finite(spacing) or spacing <= 0.0 \
				or not is_finite(isovalue) \
				or (cell_type == 1 and (orientation < 0 or orientation > 5 \
					or not is_finite(transition_width) or transition_width <= 0.0)):
			return _failure("GPU meshing cell descriptor is invalid at index %d" % cell_index)
		for sample_index in sample_indices:
			if sample_index < 0 or sample_index >= densities.size():
				return _failure("GPU meshing sample reference is out of bounds")
		headers[cell_index * 4] = cell_type
		headers[cell_index * 4 + 1] = orientation
		headers[cell_index * 4 + 2] = references.size()
		headers[cell_index * 4 + 3] = sample_indices.size()
		origins[cell_index * 4] = origin.x
		origins[cell_index * 4 + 1] = origin.y
		origins[cell_index * 4 + 2] = origin.z
		origins[cell_index * 4 + 3] = spacing
		options[cell_index * 4] = transition_width
		options[cell_index * 4 + 1] = isovalue
		references.append_array(sample_indices)
	var identity: Dictionary = batch.get("identity", {})
	var source_revision := int(identity.get("source_revision", 0))
	var world_revision := int(identity.get("world_revision", 0))
	var config := PackedInt32Array([
		cells.size(), densities.size(), references.size(), 1 if input_lane == "tqp59_gpu_field" else 0,
		int(identity.get("page_x", 0)), int(identity.get("page_y", 0)),
		int(identity.get("page_z", 0)), int(identity.get("lod", 0)),
		int(identity.get("generation", 0)), _low_i32(source_revision),
		_high_i32(source_revision), _low_i32(world_revision),
		_high_i32(world_revision), int(identity.get("transition_mask", 0)),
		int(identity.get("field_mode", 0)), int(identity.get("sample_count", densities.size())),
	])
	return {
		"status": "PASS",
		"input_buffers": [
			field_values.to_byte_array(),
			field_meta.to_byte_array(),
			headers.to_byte_array(),
			origins.to_byte_array(),
			options.to_byte_array(),
			references.to_byte_array(),
			config.to_byte_array(),
			PackedInt32Array(_tables["regular_cell_class"]).to_byte_array(),
			PackedInt32Array(_tables["regular_cell_data"]).to_byte_array(),
			PackedInt32Array(_tables["regular_vertex_data"]).to_byte_array(),
			PackedInt32Array(_tables["transition_cell_class"]).to_byte_array(),
			PackedInt32Array(_tables["transition_cell_data"]).to_byte_array(),
			PackedInt32Array(_tables["transition_vertex_data"]).to_byte_array(),
		],
	}


func _unpack_result(
	output_bytes: Array[PackedByteArray],
	cells: Array,
	input_lane: String,
	batch: Dictionary,
	started_usec: int,
	prepared_usec: int,
	synchronized_usec: int,
	readback_usec: int
) -> Dictionary:
	var position_values := output_bytes[0].to_float32_array()
	var normal_values := output_bytes[1].to_float32_array()
	var vertex_meta := output_bytes[2].to_int32_array()
	var reuse_values := output_bytes[3].to_int32_array()
	var index_values := output_bytes[4].to_int32_array()
	var cell_meta := output_bytes[5].to_int32_array()
	var identity_values := output_bytes[6].to_int32_array()
	var cell_count := cells.size()
	if position_values.size() != cell_count * MAXIMUM_VERTICES_PER_CELL * 4 \
			or normal_values.size() != position_values.size() \
			or vertex_meta.size() != position_values.size() \
			or reuse_values.size() != position_values.size() \
			or index_values.size() != cell_count * MAXIMUM_INDICES_PER_CELL \
			or cell_meta.size() != cell_count * 4 or identity_values.size() != 12:
		return _failure("GPU meshing readback size is invalid")
	var results: Array[Dictionary] = []
	var failures: Array[String] = []
	var regular_count := 0
	var transition_count := 0
	var total_vertices := 0
	var total_indices := 0
	for cell_index in range(cell_count):
		var descriptor: Dictionary = cells[cell_index]
		var status_code := cell_meta[cell_index * 4]
		var vertex_count := cell_meta[cell_index * 4 + 2]
		var index_count := cell_meta[cell_index * 4 + 3]
		if status_code < 0 or status_code >= STATUS_NAMES.size() \
				or vertex_count < 0 or vertex_count > MAXIMUM_VERTICES_PER_CELL \
				or index_count < 0 or index_count > MAXIMUM_INDICES_PER_CELL \
				or index_count % 3 != 0:
			failures.append("GPU meshing metadata is invalid for cell %d" % cell_index)
			continue
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var cell_materials := PackedInt32Array()
		var cell_authored := PackedInt32Array()
		var endpoint_a := PackedInt32Array()
		var endpoint_b := PackedInt32Array()
		var reuse_data := PackedInt32Array()
		vertices.resize(vertex_count)
		normals.resize(vertex_count)
		cell_materials.resize(vertex_count)
		cell_authored.resize(vertex_count)
		endpoint_a.resize(vertex_count)
		endpoint_b.resize(vertex_count)
		reuse_data.resize(vertex_count)
		for vertex_index in range(vertex_count):
			var slot := cell_index * MAXIMUM_VERTICES_PER_CELL + vertex_index
			var offset := slot * 4
			if reuse_values[offset + 1] != cell_index or reuse_values[offset + 2] != vertex_index \
					or reuse_values[offset + 3] != 1:
				failures.append("GPU meshing vertex ordering marker is invalid")
				break
			vertices[vertex_index] = Vector3(
				position_values[offset], position_values[offset + 1], position_values[offset + 2]
			)
			normals[vertex_index] = Vector3(
				normal_values[offset], normal_values[offset + 1], normal_values[offset + 2]
			)
			cell_materials[vertex_index] = vertex_meta[offset]
			cell_authored[vertex_index] = vertex_meta[offset + 1]
			endpoint_a[vertex_index] = vertex_meta[offset + 2]
			endpoint_b[vertex_index] = vertex_meta[offset + 3]
			reuse_data[vertex_index] = reuse_values[offset]
		var backend_indices := PackedInt32Array()
		backend_indices.resize(index_count)
		for index in range(index_count):
			var value := index_values[cell_index * MAXIMUM_INDICES_PER_CELL + index]
			if value < 0 or value >= vertex_count:
				failures.append("GPU meshing index is out of bounds")
			backend_indices[index] = value
		var render_indices := backend_indices.duplicate()
		for triangle in range(0, render_indices.size(), 3):
			var swap := render_indices[triangle + 1]
			render_indices[triangle + 1] = render_indices[triangle + 2]
			render_indices[triangle + 2] = swap
		var cell_type := str(descriptor.get("type", ""))
		regular_count += 1 if cell_type == "regular" else 0
		transition_count += 1 if cell_type == "transition" else 0
		total_vertices += vertex_count
		total_indices += index_count
		results.append({
			"id": descriptor.get("id", "cell_%d" % cell_index),
			"type": cell_type,
			"orientation": int(descriptor.get("orientation", 0)),
			"status": STATUS_NAMES[status_code],
			"ok": status_code == 1,
			"empty": status_code == 0,
			"case_code": cell_meta[cell_index * 4 + 1],
			"vertex_count": vertex_count,
			"index_count": index_count,
			"triangle_count": index_count / 3,
			"vertices": vertices,
			"normals": normals,
			"materials": cell_materials,
			"material_authored": cell_authored,
			"endpoint_a": endpoint_a,
			"endpoint_b": endpoint_b,
			"reuse_data": reuse_data,
			"backend_indices": backend_indices,
			"indices": render_indices,
		})
	var raw_bytes := PackedByteArray()
	for bytes in output_bytes:
		raw_bytes.append_array(bytes)
	return {
		"schema": RESULT_SCHEMA,
		"status": "PASS" if failures.is_empty() else "FAIL",
		"backend": "world_transvoxel_terrain_gpu_meshing_candidate",
		"input_lane": input_lane,
		"field_schema": batch.get("schema", ""),
		"fallback_used": false,
		"cpu_meshing_used": false,
		"table_identity": get_table_identity(),
		"identity": _unpack_identity(identity_values),
		"cell_count": cell_count,
		"regular_cell_count": regular_count,
		"transition_cell_count": transition_count,
		"vertex_count": total_vertices,
		"index_count": total_indices,
		"triangle_count": total_indices / 3,
		"cells": results,
		"raw_signature": _bytes_sha256(raw_bytes),
		"timing_usec": {
			"prepare": prepared_usec - started_usec,
			"compute_sync": synchronized_usec - prepared_usec,
			"readback": readback_usec - synchronized_usec,
			"total": readback_usec - started_usec,
		},
		"failures": failures,
	}


func _validate_tables(tables: Dictionary) -> bool:
	if str(tables.get("schema", "")) != TABLE_SCHEMA \
			or str(tables.get("authority", "")) != "NATIVE_TRANSVOXEL_BACKEND_TABLE_EXPORT" \
			or str(tables.get("backend_id", "")) != "transvoxel_mit_official":
		_error = "native GPU meshing table identity is invalid"
		return false
	var expected_sizes := {
		"regular_cell_class": 256,
		"regular_cell_data": 16 * 16,
		"regular_vertex_data": 256 * 12,
		"transition_cell_class": 512,
		"transition_cell_data": 56 * 37,
		"transition_vertex_data": 512 * 12,
	}
	for table_name in expected_sizes:
		if PackedInt32Array(tables.get(table_name, PackedInt32Array())).size() \
				!= int(expected_sizes[table_name]):
			_error = "native GPU meshing table size is invalid: " + table_name
			return false
	return true


func _storage_buffer(bytes: PackedByteArray, rids: Array[RID]) -> RID:
	var rid := _rendering_device.storage_buffer_create(bytes.size(), bytes)
	rids.append(rid)
	return rid


func _empty_storage_buffer(size: int, rids: Array[RID]) -> RID:
	var rid := _rendering_device.storage_buffer_create(size)
	rids.append(rid)
	return rid


func _free_rids(rids: Array[RID]) -> void:
	for rid in rids:
		if rid.is_valid():
			_rendering_device.free_rid(rid)


static func _unpack_identity(values: PackedInt32Array) -> Dictionary:
	return {
		"page_x": values[0],
		"page_y": values[1],
		"page_z": values[2],
		"lod": values[3],
		"generation": values[4],
		"source_revision": _join_i64(values[5], values[6]),
		"world_revision": _join_i64(values[7], values[8]),
		"transition_mask": values[9],
		"field_mode": values[10],
		"sample_count": values[11],
	}


static func _low_i32(value: int) -> int:
	var bits := value & 0xffffffff
	return bits if bits < 0x80000000 else bits - 0x100000000


static func _high_i32(value: int) -> int:
	var bits := (value >> 32) & 0xffffffff
	return bits if bits < 0x80000000 else bits - 0x100000000


static func _join_i64(low: int, high: int) -> int:
	return (low & 0xffffffff) | ((high & 0xffffffff) << 32)


static func _bytes_sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


static func _vector3(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Vector3i:
		return Vector3(value)
	if value is Array and value.size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


static func _failure(message: String) -> Dictionary:
	return {
		"schema": RESULT_SCHEMA,
		"status": "FAIL",
		"fallback_used": false,
		"cpu_meshing_used": false,
		"failures": [message],
	}
