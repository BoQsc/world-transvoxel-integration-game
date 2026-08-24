@tool
extends RefCounted
class_name WtTerrainGpuMeshingDifferential

const SCHEMA := "world_transvoxel.terrain.gpu_meshing_differential.v1"
const MAXIMUM_VECTOR_DIFFERENCE := 0.00001
const FLOAT32_EPSILON := 0.00000011920928955078125
const MAXIMUM_VERTEX_RELATIVE_DIFFERENCE := FLOAT32_EPSILON * 4.0


static func compare_cells(authority_cells: Array, candidate_cells: Array) -> Dictionary:
	if authority_cells.size() != candidate_cells.size():
		return _failure("GPU and CPU authority cell counts differ", -1)
	for index in range(authority_cells.size()):
		if not authority_cells[index] is Dictionary \
				or not candidate_cells[index] is Dictionary:
			return _failure("cell payload is not a Dictionary", index)
		var difference := _compare_cell(authority_cells[index], candidate_cells[index])
		if not difference.is_empty():
			difference["cell_id"] = str(authority_cells[index].get("id", ""))
			difference["cell_type"] = str(authority_cells[index].get("type", ""))
			difference["cell_orientation"] = int(
				authority_cells[index].get("orientation", 0)
			)
			difference["cell_case_code"] = int(
				authority_cells[index].get("case_code", 0)
			)
			return _failure(str(difference.get("error", "cell differs")), index, difference)
	return {
		"schema": SCHEMA,
		"status": "PASS",
		"matched": true,
		"cell_count": authority_cells.size(),
		"failed_cell_index": -1,
		"error": "",
	}


static func _compare_cell(authority: Dictionary, candidate: Dictionary) -> Dictionary:
	for key in [
		"id", "type", "orientation", "status", "case_code", "vertex_count",
		"index_count", "triangle_count",
	]:
		if authority.get(key) != candidate.get(key):
			return {"error": "%s differs" % key, "field": key}
	for key in [
		"backend_indices", "indices", "materials", "material_authored",
		"endpoint_a", "endpoint_b", "reuse_data",
	]:
		if PackedInt32Array(authority.get(key, PackedInt32Array())) \
				!= PackedInt32Array(candidate.get(key, PackedInt32Array())):
			return {"error": "%s differs" % key, "field": key}
	var vertex_difference := _compare_vectors(
		authority.get("vertices", PackedVector3Array()),
		candidate.get("vertices", PackedVector3Array()),
		MAXIMUM_VECTOR_DIFFERENCE,
		MAXIMUM_VERTEX_RELATIVE_DIFFERENCE
	)
	if not vertex_difference.is_empty():
		vertex_difference["error"] = "vertices differ"
		vertex_difference["field"] = "vertices"
		return vertex_difference
	var normal_difference := _compare_vectors(
		authority.get("normals", PackedVector3Array()),
		candidate.get("normals", PackedVector3Array()),
		MAXIMUM_VECTOR_DIFFERENCE,
		0.0
	)
	if not normal_difference.is_empty():
		normal_difference["error"] = "normals differ"
		normal_difference["field"] = "normals"
		return normal_difference
	return {}


static func _compare_vectors(
	left: PackedVector3Array,
	right: PackedVector3Array,
	absolute_tolerance: float,
	relative_tolerance: float
) -> Dictionary:
	if left.size() != right.size():
		return {
			"maximum": INF,
			"maximum_allowed": 0.0,
			"maximum_ratio": INF,
			"vector_index": -1,
			"component": "size",
		}
	var maximum := 0.0
	var maximum_allowed := absolute_tolerance
	var maximum_ratio := 0.0
	var vector_index := -1
	var component := ""
	for index in range(left.size()):
		var difference := (left[index] - right[index]).abs()
		var allowed := absolute_tolerance + relative_tolerance * maxf(
			absf(left[index].x), absf(right[index].x)
		)
		var ratio := difference.x / allowed if allowed > 0.0 else INF
		if ratio > maximum_ratio:
			maximum = difference.x
			maximum_allowed = allowed
			maximum_ratio = ratio
			vector_index = index
			component = "x"
		allowed = absolute_tolerance + relative_tolerance * maxf(
			absf(left[index].y), absf(right[index].y)
		)
		ratio = difference.y / allowed if allowed > 0.0 else INF
		if ratio > maximum_ratio:
			maximum = difference.y
			maximum_allowed = allowed
			maximum_ratio = ratio
			vector_index = index
			component = "y"
		allowed = absolute_tolerance + relative_tolerance * maxf(
			absf(left[index].z), absf(right[index].z)
		)
		ratio = difference.z / allowed if allowed > 0.0 else INF
		if ratio > maximum_ratio:
			maximum = difference.z
			maximum_allowed = allowed
			maximum_ratio = ratio
			vector_index = index
			component = "z"
	if maximum_ratio <= 1.0:
		return {}
	return {
		"maximum": maximum,
		"maximum_allowed": maximum_allowed,
		"maximum_ratio": maximum_ratio,
		"vector_index": vector_index,
		"component": component,
	}


static func _failure(
	error: String,
	cell_index: int,
	details: Dictionary = {}
) -> Dictionary:
	var result := {
		"schema": SCHEMA,
		"status": "FAIL",
		"matched": false,
		"cell_count": 0,
		"failed_cell_index": cell_index,
		"error": error,
	}
	for key in details:
		if key != "error":
			result[key] = details[key]
	return result
