@tool
extends RefCounted
class_name WtTerrainWatertightnessProbe


const CHUNK_CELLS_PER_AXIS := 16
const POINT_KEY_SCALE := 1024
const CHUNK_FACE_TOLERANCE_KEYS := 2

static var _active_point_key_scale := POINT_KEY_SCALE
static var _active_chunk_face_tolerance_keys := CHUNK_FACE_TOLERANCE_KEYS


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
	var edge_directions := {}
	var lod0_edge_directions := {}
	var stats := {
		"enabled": true,
		"mode": mode,
		"center": _vector_summary(center),
		"radius": radius,
		"point_key_scale": _active_point_key_scale,
		"chunk_face_tolerance_keys": _active_chunk_face_tolerance_keys,
		"mesh_instances": 0,
		"mesh_instances_in_region": 0,
		"surfaces": 0,
		"triangles_examined": 0,
		"triangles_in_region": 0,
		"lod0_triangles_in_region": 0,
		"zero_area_triangles": 0,
		"zero_area_chunk_face_triangles": 0,
		"zero_area_interior_triangles": 0,
		"zero_area_unknown_triangles": 0,
		"zero_edge_triangles": 0,
		"repeated_point_key_triangles": 0,
		"repeated_point_key_chunk_face_triangles": 0,
		"repeated_point_key_interior_triangles": 0,
		"repeated_point_key_unknown_triangles": 0,
		"minimum_area_squared": INF,
		"minimum_edge_length_squared": INF,
		"zero_area_examples": [],
		"repeated_point_key_examples": [],
		"normal_agreement_positive": 0,
		"normal_agreement_negative": 0,
		"normal_agreement_near_zero": 0,
		"normal_agreement_positive_examples": [],
	}
	_collect_edges(
		backend,
		center,
		radius,
		edge_counts,
		lod0_edge_counts,
		edge_owners,
		lod0_edge_owners,
		edge_directions,
		lod0_edge_directions,
		stats
	)
	var edge_summary := _summarize_edge_counts(edge_counts, edge_owners, edge_directions)
	var lod0_edge_summary := _summarize_edge_counts(lod0_edge_counts, lod0_edge_owners, lod0_edge_directions)
	for key in edge_summary.keys():
		stats[key] = edge_summary[key]
	for key in lod0_edge_summary.keys():
		stats["lod0_" + str(key)] = lod0_edge_summary[key]
	var positive := int(stats.get("normal_agreement_positive", 0))
	var negative := int(stats.get("normal_agreement_negative", 0))
	var winding_minority := mini(positive, negative)
	var safe_zero_area_interior_triangles := int(stats.get("zero_area_interior_triangles", 0))
	var unsafe_zero_area_triangles := int(stats.get("zero_area_unknown_triangles", 0))
	var unsafe_repeated_point_key_triangles := int(stats.get("repeated_point_key_interior_triangles", 0)) + \
		int(stats.get("repeated_point_key_unknown_triangles", 0))
	stats["allowed_zero_area_chunk_face_triangles"] = int(stats.get("zero_area_chunk_face_triangles", 0))
	stats["safe_zero_area_interior_triangles"] = safe_zero_area_interior_triangles
	stats["unsafe_zero_area_triangles"] = unsafe_zero_area_triangles
	stats["unsafe_repeated_point_key_triangles"] = unsafe_repeated_point_key_triangles
	stats["winding_mixed"] = positive > 0 and negative > 0
	stats["winding_minority"] = winding_minority
	stats["ok"] = int(stats.get("boundary_edges", 0)) == 0 and \
		int(stats.get("nonmanifold_edges", 0)) == 0 and \
		int(stats.get("orientation_conflict_edges", 0)) == 0 and \
		unsafe_zero_area_triangles == 0 and \
		unsafe_repeated_point_key_triangles == 0 and \
		int(stats.get("zero_edge_triangles", 0)) == 0 and \
		int(stats.get("triangles_in_region", 0)) > 0
	return stats


static func collect_precise(
	backend: Node,
	mode: String,
	center: Vector3,
	radius: float,
	point_key_scale: int = 1048576,
	chunk_face_tolerance_keys: int = 2
) -> Dictionary:
	var previous_point_key_scale := _active_point_key_scale
	var previous_chunk_face_tolerance_keys := _active_chunk_face_tolerance_keys
	_active_point_key_scale = maxi(1, point_key_scale)
	_active_chunk_face_tolerance_keys = maxi(0, chunk_face_tolerance_keys)
	var result := collect(backend, mode, center, radius)
	_active_point_key_scale = previous_point_key_scale
	_active_chunk_face_tolerance_keys = previous_chunk_face_tolerance_keys
	return result


static func _collect_edges(
	node: Node,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	lod0_edge_counts: Dictionary,
	edge_owners: Dictionary,
	lod0_edge_owners: Dictionary,
	edge_directions: Dictionary,
	lod0_edge_directions: Dictionary,
	stats: Dictionary
) -> void:
	if node is MeshInstance3D:
		_accumulate_mesh(
			node as MeshInstance3D,
			center,
			radius,
			edge_counts,
			lod0_edge_counts,
			edge_owners,
			lod0_edge_owners,
			edge_directions,
			lod0_edge_directions,
			stats
		)
	for child in node.get_children():
		if child is Node:
			_collect_edges(
				child,
				center,
				radius,
				edge_counts,
				lod0_edge_counts,
				edge_owners,
				lod0_edge_owners,
				edge_directions,
				lod0_edge_directions,
				stats
			)


static func _accumulate_mesh(
	instance: MeshInstance3D,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	lod0_edge_counts: Dictionary,
	edge_owners: Dictionary,
	lod0_edge_owners: Dictionary,
	edge_directions: Dictionary,
	lod0_edge_directions: Dictionary,
	stats: Dictionary
) -> void:
	stats["mesh_instances"] = int(stats.get("mesh_instances", 0)) + 1
	if not instance.is_visible_in_tree():
		return
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
					edge_directions,
					lod0_edge_directions,
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
					edge_directions,
					lod0_edge_directions,
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
	edge_directions: Dictionary,
	lod0_edge_directions: Dictionary,
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
	var area_squared := cross.length_squared()
	var ab_squared := a.distance_squared_to(b)
	var bc_squared := b.distance_squared_to(c)
	var ca_squared := c.distance_squared_to(a)
	var min_edge_squared := minf(ab_squared, minf(bc_squared, ca_squared))
	stats["minimum_area_squared"] = minf(float(stats.get("minimum_area_squared", INF)), area_squared)
	stats["minimum_edge_length_squared"] = minf(
		float(stats.get("minimum_edge_length_squared", INF)),
		min_edge_squared
	)
	var repeated_key := _point_key(a) == _point_key(b) or _point_key(b) == _point_key(c) or _point_key(c) == _point_key(a)
	if repeated_key:
		stats["repeated_point_key_triangles"] = int(stats.get("repeated_point_key_triangles", 0)) + 1
		var repeated_kind := _triangle_kind(
			_point_key(a),
			_point_key(b),
			_point_key(c),
			owner
		)
		if repeated_kind == "chunk_face":
			stats["repeated_point_key_chunk_face_triangles"] = int(stats.get("repeated_point_key_chunk_face_triangles", 0)) + 1
		elif repeated_kind == "interior":
			stats["repeated_point_key_interior_triangles"] = int(stats.get("repeated_point_key_interior_triangles", 0)) + 1
		else:
			stats["repeated_point_key_unknown_triangles"] = int(stats.get("repeated_point_key_unknown_triangles", 0)) + 1
		var repeated_examples: Array = stats.get("repeated_point_key_examples", [])
		if repeated_examples.size() < 8:
			repeated_examples.append({
				"owner": owner,
				"lod": lod,
				"kind": repeated_kind,
				"area_squared": area_squared,
				"minimum_edge_length_squared": min_edge_squared,
				"a": _vector_summary(a),
				"b": _vector_summary(b),
				"c": _vector_summary(c),
				"a_key": _point_key(a),
				"b_key": _point_key(b),
				"c_key": _point_key(c),
			})
			stats["repeated_point_key_examples"] = repeated_examples
	if min_edge_squared <= 0.000000000001:
		stats["zero_edge_triangles"] = int(stats.get("zero_edge_triangles", 0)) + 1
	if area_squared <= 0.00000001:
		stats["zero_area_triangles"] = int(stats.get("zero_area_triangles", 0)) + 1
		var zero_area_kind := _triangle_kind(
			_point_key(a),
			_point_key(b),
			_point_key(c),
			owner
		)
		if zero_area_kind == "chunk_face":
			stats["zero_area_chunk_face_triangles"] = int(stats.get("zero_area_chunk_face_triangles", 0)) + 1
		elif zero_area_kind == "interior":
			stats["zero_area_interior_triangles"] = int(stats.get("zero_area_interior_triangles", 0)) + 1
		else:
			stats["zero_area_unknown_triangles"] = int(stats.get("zero_area_unknown_triangles", 0)) + 1
		var examples: Array = stats.get("zero_area_examples", [])
		if examples.size() < 8:
			examples.append({
				"owner": owner,
				"lod": lod,
				"kind": zero_area_kind,
				"area_squared": area_squared,
				"minimum_edge_length_squared": min_edge_squared,
				"a": _vector_summary(a),
				"b": _vector_summary(b),
				"c": _vector_summary(c),
				"a_key": _point_key(a),
				"b_key": _point_key(b),
				"c_key": _point_key(c),
			})
			stats["zero_area_examples"] = examples
	else:
		_accumulate_normal_agreement(
			transform,
			normals,
			index_a,
			index_b,
			index_c,
			cross,
			stats,
			a,
			b,
			c,
			lod,
			owner,
			area_squared,
			min_edge_squared
		)
	_accumulate_edge_if_inner(a, b, center, radius, edge_counts, edge_owners, edge_directions, owner)
	_accumulate_edge_if_inner(b, c, center, radius, edge_counts, edge_owners, edge_directions, owner)
	_accumulate_edge_if_inner(c, a, center, radius, edge_counts, edge_owners, edge_directions, owner)
	if lod == 0:
		_accumulate_edge_if_inner(a, b, center, radius, lod0_edge_counts, lod0_edge_owners, lod0_edge_directions, owner)
		_accumulate_edge_if_inner(b, c, center, radius, lod0_edge_counts, lod0_edge_owners, lod0_edge_directions, owner)
		_accumulate_edge_if_inner(c, a, center, radius, lod0_edge_counts, lod0_edge_owners, lod0_edge_directions, owner)


static func _accumulate_normal_agreement(
	transform: Transform3D,
	normals: PackedVector3Array,
	index_a: int,
	index_b: int,
	index_c: int,
	cross: Vector3,
	stats: Dictionary,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	lod: int,
	owner: String,
	area_squared: float,
	min_edge_squared: float
) -> void:
	if normals.size() <= maxi(index_a, maxi(index_b, index_c)):
		return
	var normal_sum := transform.basis * normals[index_a] + \
		transform.basis * normals[index_b] + \
		transform.basis * normals[index_c]
	var agreement := cross.dot(normal_sum)
	if agreement > 0.0001:
		stats["normal_agreement_positive"] = int(stats.get("normal_agreement_positive", 0)) + 1
		var examples: Array = stats.get("normal_agreement_positive_examples", [])
		if examples.size() < 8:
			examples.append({
				"owner": owner,
				"lod": lod,
				"agreement": agreement,
				"area_squared": area_squared,
				"minimum_edge_length_squared": min_edge_squared,
				"a": _vector_summary(a),
				"b": _vector_summary(b),
				"c": _vector_summary(c),
				"a_key": _point_key(a),
				"b_key": _point_key(b),
				"c_key": _point_key(c),
			})
			stats["normal_agreement_positive_examples"] = examples
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
	edge_directions: Dictionary,
	owner: String
) -> void:
	var midpoint := (a + b) * 0.5
	if midpoint.distance_to(center) > radius:
		return
	var key := _edge_key(a, b)
	var direction_key := _directed_edge_key(a, b)
	edge_counts[key] = int(edge_counts.get(key, 0)) + 1
	if not edge_owners.has(key):
		edge_owners[key] = {}
	var owners: Dictionary = edge_owners[key]
	owners[owner] = int(owners.get(owner, 0)) + 1
	if not edge_directions.has(key):
		edge_directions[key] = {}
	var directions: Dictionary = edge_directions[key]
	directions[direction_key] = int(directions.get(direction_key, 0)) + 1


static func _summarize_edge_counts(
	edge_counts: Dictionary,
	edge_owners: Dictionary,
	edge_directions: Dictionary
) -> Dictionary:
	var boundary_edges := 0
	var interior_boundary_edges := 0
	var chunk_face_boundary_edges := 0
	var unknown_boundary_edges := 0
	var nonmanifold_edges := 0
	var nonmanifold_chunk_face_edges := 0
	var nonmanifold_interior_edges := 0
	var nonmanifold_unknown_edges := 0
	var orientation_conflict_edges := 0
	var orientation_conflict_chunk_face_edges := 0
	var orientation_conflict_interior_edges := 0
	var orientation_conflict_unknown_edges := 0
	var matched_edges := 0
	var maximum_edge_use := 0
	var boundary_examples := []
	var interior_boundary_examples := []
	var nonmanifold_examples := []
	var orientation_conflict_examples := []
	for key in edge_counts.keys():
		var count := int(edge_counts[key])
		maximum_edge_use = maxi(maximum_edge_use, count)
		if count == 1:
			boundary_edges += 1
			var owners: Dictionary = edge_owners.get(key, {})
			var boundary_kind := _boundary_edge_kind(str(key), owners)
			if boundary_kind == "interior":
				interior_boundary_edges += 1
				if interior_boundary_examples.size() < 8:
					interior_boundary_examples.append("%s owners=%s" % [str(key), _owners_summary(owners)])
			elif boundary_kind == "chunk_face":
				chunk_face_boundary_edges += 1
			else:
				unknown_boundary_edges += 1
			if boundary_examples.size() < 8:
				boundary_examples.append("%s kind=%s owners=%s" % [str(key), boundary_kind, _owners_summary(owners)])
		elif count == 2:
			matched_edges += 1
			var directions: Dictionary = edge_directions.get(key, {})
			if directions.keys().size() != 2:
				orientation_conflict_edges += 1
				var orientation_kind := _nonmanifold_edge_kind(str(key), edge_owners.get(key, {}))
				if orientation_kind == "chunk_face":
					orientation_conflict_chunk_face_edges += 1
				elif orientation_kind == "interior":
					orientation_conflict_interior_edges += 1
				else:
					orientation_conflict_unknown_edges += 1
				if orientation_conflict_examples.size() < 8:
					orientation_conflict_examples.append("%s kind=%s directions=%s owners=%s" % [
						str(key),
						orientation_kind,
						_owners_summary(directions),
						_owners_summary(edge_owners.get(key, {})),
					])
		else:
			nonmanifold_edges += 1
			var nonmanifold_kind := _nonmanifold_edge_kind(str(key), edge_owners.get(key, {}))
			if nonmanifold_kind == "chunk_face":
				nonmanifold_chunk_face_edges += 1
			elif nonmanifold_kind == "interior":
				nonmanifold_interior_edges += 1
			else:
				nonmanifold_unknown_edges += 1
			if nonmanifold_examples.size() < 8:
				nonmanifold_examples.append("%s kind=%s count=%d owners=%s" % [
					str(key),
					nonmanifold_kind,
					count,
					_owners_summary(edge_owners.get(key, {})),
				])
	return {
		"edges": edge_counts.size(),
		"matched_edges": matched_edges,
		"boundary_edges": boundary_edges,
		"interior_boundary_edges": interior_boundary_edges,
		"chunk_face_boundary_edges": chunk_face_boundary_edges,
		"unknown_boundary_edges": unknown_boundary_edges,
		"nonmanifold_edges": nonmanifold_edges,
		"nonmanifold_chunk_face_edges": nonmanifold_chunk_face_edges,
		"nonmanifold_interior_edges": nonmanifold_interior_edges,
		"nonmanifold_unknown_edges": nonmanifold_unknown_edges,
		"orientation_conflict_edges": orientation_conflict_edges,
		"orientation_conflict_chunk_face_edges": orientation_conflict_chunk_face_edges,
		"orientation_conflict_interior_edges": orientation_conflict_interior_edges,
		"orientation_conflict_unknown_edges": orientation_conflict_unknown_edges,
		"maximum_edge_use": maximum_edge_use,
		"boundary_examples": boundary_examples,
		"interior_boundary_examples": interior_boundary_examples,
		"nonmanifold_examples": nonmanifold_examples,
		"orientation_conflict_examples": orientation_conflict_examples,
	}


static func _edge_key(a: Vector3, b: Vector3) -> String:
	var key_a := _point_key(a)
	var key_b := _point_key(b)
	if key_a < key_b:
		return key_a + "|" + key_b
	return key_b + "|" + key_a


static func _directed_edge_key(a: Vector3, b: Vector3) -> String:
	return _point_key(a) + ">" + _point_key(b)


static func _point_key(point: Vector3) -> String:
	var scale := float(_active_point_key_scale)
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


static func _boundary_edge_kind(edge_key: String, owners: Dictionary) -> String:
	if owners.size() != 1:
		return "unknown"
	var owner_keys := owners.keys()
	var owner := str(owner_keys[0])
	var chunk := _parse_owner_chunk_key(owner)
	if chunk.is_empty():
		return "unknown"
	var points := _parse_edge_points(edge_key)
	if points.size() != 2:
		return "unknown"
	if _edge_on_chunk_face(points[0], points[1], chunk):
		return "chunk_face"
	return "interior"


static func _nonmanifold_edge_kind(edge_key: String, owners: Dictionary) -> String:
	var points := _parse_edge_points(edge_key)
	if points.size() != 2:
		return "unknown"
	var parsed_owner_count := 0
	for owner_key in owners.keys():
		var chunk := _parse_owner_chunk_key(str(owner_key))
		if chunk.is_empty():
			continue
		parsed_owner_count += 1
		if _edge_on_chunk_face(points[0], points[1], chunk):
			return "chunk_face"
	if parsed_owner_count == 0:
		return "unknown"
	return "interior"


static func _parse_edge_points(edge_key: String) -> Array:
	var parts := edge_key.split("|", false)
	if parts.size() != 2:
		return []
	var first := _parse_point_key(str(parts[0]))
	var second := _parse_point_key(str(parts[1]))
	if first.size() != 3 or second.size() != 3:
		return []
	return [first, second]


static func _triangle_kind(
	a_key: String,
	b_key: String,
	c_key: String,
	owner: String
) -> String:
	var chunk := _parse_owner_chunk_key(owner)
	if chunk.is_empty():
		return "unknown"
	var first := _parse_point_key(a_key)
	var second := _parse_point_key(b_key)
	var third := _parse_point_key(c_key)
	if first.size() != 3 or second.size() != 3 or third.size() != 3:
		return "unknown"
	if _triangle_on_chunk_face(first, second, third, chunk):
		return "chunk_face"
	return "interior"


static func _parse_point_key(point_key: String) -> Array:
	var parts := point_key.split(",", false)
	if parts.size() != 3:
		return []
	return [int(parts[0]), int(parts[1]), int(parts[2])]


static func _parse_owner_chunk_key(owner: String) -> Dictionary:
	var name_text := owner
	var space := name_text.find(" ")
	if space >= 0:
		name_text = name_text.substr(0, space)
	var retiring := name_text.find("_retiring_")
	if retiring >= 0:
		name_text = name_text.substr(0, retiring)
	var prefix := "WT_Render_"
	if not name_text.begins_with(prefix):
		return {}
	var parts := name_text.substr(prefix.length()).split("_", false)
	if parts.size() != 4:
		return {}
	var lod_text := str(parts[3])
	if not lod_text.begins_with("L"):
		return {}
	return {
		"x": int(parts[0]),
		"y": int(parts[1]),
		"z": int(parts[2]),
		"lod": int(lod_text.substr(1)),
	}


static func _edge_on_chunk_face(first: Array, second: Array, chunk: Dictionary) -> bool:
	var lod := int(chunk.get("lod", -1))
	if lod < 0:
		return false
	var extent := CHUNK_CELLS_PER_AXIS * int(1 << lod)
	var point_key_scale := _active_point_key_scale
	var minimum := [
		int(chunk.get("x", 0)) * extent * point_key_scale,
		int(chunk.get("y", 0)) * extent * point_key_scale,
		int(chunk.get("z", 0)) * extent * point_key_scale,
	]
	var maximum := [
		(int(chunk.get("x", 0)) * extent + extent) * point_key_scale,
		(int(chunk.get("y", 0)) * extent + extent) * point_key_scale,
		(int(chunk.get("z", 0)) * extent + extent) * point_key_scale,
	]
	var tolerance := _active_chunk_face_tolerance_keys
	for axis in range(3):
		if abs(int(first[axis]) - int(minimum[axis])) <= tolerance and \
				abs(int(second[axis]) - int(minimum[axis])) <= tolerance:
			return true
		if abs(int(first[axis]) - int(maximum[axis])) <= tolerance and \
				abs(int(second[axis]) - int(maximum[axis])) <= tolerance:
			return true
	return false


static func _triangle_on_chunk_face(first: Array, second: Array, third: Array, chunk: Dictionary) -> bool:
	var lod := int(chunk.get("lod", -1))
	if lod < 0:
		return false
	var extent := CHUNK_CELLS_PER_AXIS * int(1 << lod)
	var point_key_scale := _active_point_key_scale
	var minimum := [
		int(chunk.get("x", 0)) * extent * point_key_scale,
		int(chunk.get("y", 0)) * extent * point_key_scale,
		int(chunk.get("z", 0)) * extent * point_key_scale,
	]
	var maximum := [
		(int(chunk.get("x", 0)) * extent + extent) * point_key_scale,
		(int(chunk.get("y", 0)) * extent + extent) * point_key_scale,
		(int(chunk.get("z", 0)) * extent + extent) * point_key_scale,
	]
	var tolerance := _active_chunk_face_tolerance_keys
	for axis in range(3):
		if abs(int(first[axis]) - int(minimum[axis])) <= tolerance and \
				abs(int(second[axis]) - int(minimum[axis])) <= tolerance and \
				abs(int(third[axis]) - int(minimum[axis])) <= tolerance:
			return true
		if abs(int(first[axis]) - int(maximum[axis])) <= tolerance and \
				abs(int(second[axis]) - int(maximum[axis])) <= tolerance and \
				abs(int(third[axis]) - int(maximum[axis])) <= tolerance:
			return true
	return false


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
