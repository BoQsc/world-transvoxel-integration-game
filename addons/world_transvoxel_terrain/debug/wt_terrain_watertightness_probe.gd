@tool
extends RefCounted
class_name WtTerrainWatertightnessProbe


static func collect(backend: Node, mode: String, center: Vector3, radius: float) -> Dictionary:
	if backend == null:
		return {
			"enabled": true,
			"ok": false,
			"error": "backend_unavailable",
		}
	var edge_counts := {}
	var lod0_edge_counts := {}
	var edge_owners := {}
	var lod0_edge_owners := {}
	var stats := {
		"enabled": true,
		"mode": mode,
		"center": _vector_summary(center),
		"radius": radius,
		"mesh_instances": 0,
		"mesh_instances_in_region": 0,
		"surfaces": 0,
		"triangles_examined": 0,
		"triangles_in_region": 0,
		"lod0_triangles_in_region": 0,
		"zero_area_triangles": 0,
		"normal_agreement_positive": 0,
		"normal_agreement_negative": 0,
		"normal_agreement_near_zero": 0,
	}
	_collect_edges(backend, center, radius, edge_counts, lod0_edge_counts, edge_owners, lod0_edge_owners, stats)
	var edge_summary := _summarize_edge_counts(edge_counts, edge_owners)
	var lod0_edge_summary := _summarize_edge_counts(lod0_edge_counts, lod0_edge_owners)
	for key in edge_summary.keys():
		stats[key] = edge_summary[key]
	for key in lod0_edge_summary.keys():
		stats["lod0_" + str(key)] = lod0_edge_summary[key]
	var positive := int(stats.get("normal_agreement_positive", 0))
	var negative := int(stats.get("normal_agreement_negative", 0))
	var winding_minority := mini(positive, negative)
	stats["winding_mixed"] = positive > 0 and negative > 0
	stats["winding_minority"] = winding_minority
	stats["ok"] = int(stats.get("boundary_edges", 0)) == 0 and \
		winding_minority == 0 and \
		int(stats.get("triangles_in_region", 0)) > 0
	return stats


static func _collect_edges(
	node: Node,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	lod0_edge_counts: Dictionary,
	edge_owners: Dictionary,
	lod0_edge_owners: Dictionary,
	stats: Dictionary
) -> void:
	if node is MeshInstance3D:
		_accumulate_mesh(node as MeshInstance3D, center, radius, edge_counts, lod0_edge_counts, edge_owners, lod0_edge_owners, stats)
	for child in node.get_children():
		if child is Node:
			_collect_edges(child, center, radius, edge_counts, lod0_edge_counts, edge_owners, lod0_edge_owners, stats)


static func _accumulate_mesh(
	instance: MeshInstance3D,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	lod0_edge_counts: Dictionary,
	edge_owners: Dictionary,
	lod0_edge_owners: Dictionary,
	stats: Dictionary
) -> void:
	stats["mesh_instances"] = int(stats.get("mesh_instances", 0)) + 1
	var mesh := instance.mesh
	if mesh == null or not (mesh is ArrayMesh):
		return
	var array_mesh := mesh as ArrayMesh
	var aabb := instance.global_transform * array_mesh.get_aabb()
	if not aabb.grow(radius).has_point(center):
		return
	stats["mesh_instances_in_region"] = int(stats.get("mesh_instances_in_region", 0)) + 1
	var transform := instance.global_transform
	var lod := _mesh_instance_lod(instance)
	var owner := _mesh_owner(instance, lod)
	for surface_index in range(array_mesh.get_surface_count()):
		stats["surfaces"] = int(stats.get("surfaces", 0)) + 1
		var arrays: Array = array_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_INDEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty():
			continue
		if indices.is_empty():
			for vertex_index in range(0, vertices.size() - 2, 3):
				_accumulate_triangle(
					transform,
					vertices,
					normals,
					vertex_index,
					vertex_index + 1,
					vertex_index + 2,
					center,
					radius,
					lod,
					owner,
					edge_counts,
					lod0_edge_counts,
					edge_owners,
					lod0_edge_owners,
					stats
				)
		else:
			for index_offset in range(0, indices.size() - 2, 3):
				_accumulate_triangle(
					transform,
					vertices,
					normals,
					int(indices[index_offset]),
					int(indices[index_offset + 1]),
					int(indices[index_offset + 2]),
					center,
					radius,
					lod,
					owner,
					edge_counts,
					lod0_edge_counts,
					edge_owners,
					lod0_edge_owners,
					stats
				)


static func _accumulate_triangle(
	transform: Transform3D,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	index_a: int,
	index_b: int,
	index_c: int,
	center: Vector3,
	radius: float,
	lod: int,
	owner: String,
	edge_counts: Dictionary,
	lod0_edge_counts: Dictionary,
	edge_owners: Dictionary,
	lod0_edge_owners: Dictionary,
	stats: Dictionary
) -> void:
	stats["triangles_examined"] = int(stats.get("triangles_examined", 0)) + 1
	if index_a < 0 or index_b < 0 or index_c < 0 or \
		index_a >= vertices.size() or index_b >= vertices.size() or index_c >= vertices.size():
		return
	var a: Vector3 = transform * vertices[index_a]
	var b: Vector3 = transform * vertices[index_b]
	var c: Vector3 = transform * vertices[index_c]
	var centroid := (a + b + c) / 3.0
	var selection_radius := radius + 8.0
	if centroid.distance_to(center) > selection_radius:
		return
	stats["triangles_in_region"] = int(stats.get("triangles_in_region", 0)) + 1
	if lod == 0:
		stats["lod0_triangles_in_region"] = int(stats.get("lod0_triangles_in_region", 0)) + 1
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.00000001:
		stats["zero_area_triangles"] = int(stats.get("zero_area_triangles", 0)) + 1
	else:
		_accumulate_normal_agreement(transform, normals, index_a, index_b, index_c, cross, stats)
	_accumulate_edge_if_inner(a, b, center, radius, edge_counts, edge_owners, owner)
	_accumulate_edge_if_inner(b, c, center, radius, edge_counts, edge_owners, owner)
	_accumulate_edge_if_inner(c, a, center, radius, edge_counts, edge_owners, owner)
	if lod == 0:
		_accumulate_edge_if_inner(a, b, center, radius, lod0_edge_counts, lod0_edge_owners, owner)
		_accumulate_edge_if_inner(b, c, center, radius, lod0_edge_counts, lod0_edge_owners, owner)
		_accumulate_edge_if_inner(c, a, center, radius, lod0_edge_counts, lod0_edge_owners, owner)


static func _accumulate_normal_agreement(
	transform: Transform3D,
	normals: PackedVector3Array,
	index_a: int,
	index_b: int,
	index_c: int,
	cross: Vector3,
	stats: Dictionary
) -> void:
	if normals.size() <= maxi(index_a, maxi(index_b, index_c)):
		return
	var normal_sum := transform.basis * normals[index_a] + \
		transform.basis * normals[index_b] + \
		transform.basis * normals[index_c]
	var agreement := cross.dot(normal_sum)
	if agreement > 0.0001:
		stats["normal_agreement_positive"] = int(stats.get("normal_agreement_positive", 0)) + 1
	elif agreement < -0.0001:
		stats["normal_agreement_negative"] = int(stats.get("normal_agreement_negative", 0)) + 1
	else:
		stats["normal_agreement_near_zero"] = int(stats.get("normal_agreement_near_zero", 0)) + 1


static func _accumulate_edge_if_inner(
	a: Vector3,
	b: Vector3,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	edge_owners: Dictionary,
	owner: String
) -> void:
	var midpoint := (a + b) * 0.5
	if midpoint.distance_to(center) > radius:
		return
	var key := _edge_key(a, b)
	edge_counts[key] = int(edge_counts.get(key, 0)) + 1
	if not edge_owners.has(key):
		edge_owners[key] = {}
	var owners: Dictionary = edge_owners[key]
	owners[owner] = int(owners.get(owner, 0)) + 1


static func _summarize_edge_counts(edge_counts: Dictionary, edge_owners: Dictionary) -> Dictionary:
	var boundary_edges := 0
	var nonmanifold_edges := 0
	var matched_edges := 0
	var maximum_edge_use := 0
	var boundary_examples := []
	var nonmanifold_examples := []
	for key in edge_counts.keys():
		var count := int(edge_counts[key])
		maximum_edge_use = maxi(maximum_edge_use, count)
		if count == 1:
			boundary_edges += 1
			if boundary_examples.size() < 8:
				boundary_examples.append("%s owners=%s" % [str(key), _owners_summary(edge_owners.get(key, {}))])
		elif count == 2:
			matched_edges += 1
		else:
			nonmanifold_edges += 1
			if nonmanifold_examples.size() < 8:
				nonmanifold_examples.append("%s count=%d owners=%s" % [
					str(key),
					count,
					_owners_summary(edge_owners.get(key, {})),
				])
	return {
		"edges": edge_counts.size(),
		"matched_edges": matched_edges,
		"boundary_edges": boundary_edges,
		"nonmanifold_edges": nonmanifold_edges,
		"maximum_edge_use": maximum_edge_use,
		"boundary_examples": boundary_examples,
		"nonmanifold_examples": nonmanifold_examples,
	}


static func _edge_key(a: Vector3, b: Vector3) -> String:
	var key_a := _point_key(a)
	var key_b := _point_key(b)
	if key_a < key_b:
		return key_a + "|" + key_b
	return key_b + "|" + key_a


static func _point_key(point: Vector3) -> String:
	var scale := 1024.0
	return "%d,%d,%d" % [
		roundi(point.x * scale),
		roundi(point.y * scale),
		roundi(point.z * scale),
	]


static func _owners_summary(owners: Dictionary) -> String:
	var parts := []
	var keys := owners.keys()
	keys.sort()
	for index in range(mini(keys.size(), 4)):
		var key := str(keys[index])
		parts.append("%s:%d" % [key, int(owners[key])])
	if keys.size() > parts.size():
		parts.append("+%d more" % (keys.size() - parts.size()))
	return "[" + ", ".join(parts) + "]"


static func _mesh_owner(instance: MeshInstance3D, lod: int) -> String:
	return "%s lod=%d" % [str(instance.name), lod]


static func _mesh_instance_lod(instance: MeshInstance3D) -> int:
	var name_text := str(instance.name)
	var marker := name_text.rfind("_L")
	if marker < 0:
		return -1
	return int(name_text.substr(marker + 2))


static func _vector_summary(value: Vector3) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z,
	}
