extends RefCounted

const EDGE_QUANTIZATION := 10000.0


static func collect(root: Node, center: Vector3, radius: float) -> Dictionary:
	var report := {
		"ok": false,
		"center": _vector_summary(center),
		"radius": radius,
		"instances": [],
		"triangles": 0,
		"outward_faces": 0,
		"inward_faces": 0,
		"degenerate_faces": 0,
		"boundary_edges": 0,
		"nonmanifold_edges": 0,
		"maximum_edge_length": 0.0,
		"maximum_triangle_area": 0.0,
	}
	if root == null or radius <= 0.0:
		report["error"] = "invalid_root_or_radius"
		return report
	var edge_counts := {}
	_collect_node(root, center, radius, edge_counts, report)
	for count_value in edge_counts.values():
		var count := int(count_value)
		if count == 1:
			report["boundary_edges"] = int(report["boundary_edges"]) + 1
		elif count > 2:
			report["nonmanifold_edges"] = int(report["nonmanifold_edges"]) + 1
	report["ok"] = int(report["triangles"]) > 0
	report["coherent_winding"] = \
		int(report["outward_faces"]) == 0 or int(report["inward_faces"]) == 0
	report["closed_edge_topology"] = \
		int(report["boundary_edges"]) == 0 and int(report["nonmanifold_edges"]) == 0
	return report


static func _collect_node(
	node: Node,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	report: Dictionary
) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).is_visible_in_tree():
		_collect_instance(node as MeshInstance3D, center, radius, edge_counts, report)
	for child in node.get_children():
		if child is Node:
			_collect_node(child, center, radius, edge_counts, report)


static func _collect_instance(
	instance: MeshInstance3D,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	report: Dictionary
) -> void:
	if not instance.mesh is ArrayMesh:
		return
	var mesh := instance.mesh as ArrayMesh
	var instance_triangles := 0
	for surface_index in range(mesh.get_surface_count()):
		if str(mesh.surface_get_name(surface_index)) != "water":
			continue
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			for first in range(0, vertices.size() - 2, 3):
				if _collect_triangle(
					instance, vertices[first], vertices[first + 1], vertices[first + 2],
					center, radius, edge_counts, report
				):
					instance_triangles += 1
		else:
			for first in range(0, indices.size() - 2, 3):
				if _collect_triangle(
					instance,
					vertices[indices[first]],
					vertices[indices[first + 1]],
					vertices[indices[first + 2]],
					center, radius, edge_counts, report
				):
					instance_triangles += 1
	if instance_triangles > 0:
		report["instances"].append({
			"name": str(instance.name),
			"triangles": instance_triangles,
		})


static func _collect_triangle(
	instance: MeshInstance3D,
	local_a: Vector3,
	local_b: Vector3,
	local_c: Vector3,
	center: Vector3,
	radius: float,
	edge_counts: Dictionary,
	report: Dictionary
) -> bool:
	var a := instance.global_transform * local_a
	var b := instance.global_transform * local_b
	var c := instance.global_transform * local_c
	var selection_radius := radius + 2.0
	if minf(a.distance_to(center), minf(b.distance_to(center), c.distance_to(center))) > \
			selection_radius:
		return false
	report["triangles"] = int(report["triangles"]) + 1
	var edge_ab := b - a
	var edge_ac := c - a
	var edge_bc := c - b
	var face := edge_ab.cross(edge_ac)
	var doubled_area := face.length()
	if doubled_area <= 0.000001:
		report["degenerate_faces"] = int(report["degenerate_faces"]) + 1
	else:
		var radial := ((a + b + c) / 3.0) - center
		var orientation := face.dot(radial)
		if orientation > 0.000001:
			report["outward_faces"] = int(report["outward_faces"]) + 1
		elif orientation < -0.000001:
			report["inward_faces"] = int(report["inward_faces"]) + 1
	report["maximum_edge_length"] = maxf(
		float(report["maximum_edge_length"]),
		maxf(edge_ab.length(), maxf(edge_ac.length(), edge_bc.length()))
	)
	report["maximum_triangle_area"] = maxf(
		float(report["maximum_triangle_area"]), doubled_area * 0.5
	)
	_count_edge(edge_counts, a, b)
	_count_edge(edge_counts, b, c)
	_count_edge(edge_counts, c, a)
	return true


static func _count_edge(edge_counts: Dictionary, a: Vector3, b: Vector3) -> void:
	var a_key := _point_key(a)
	var b_key := _point_key(b)
	var key := "%s|%s" % [a_key, b_key] if a_key < b_key else "%s|%s" % [b_key, a_key]
	edge_counts[key] = int(edge_counts.get(key, 0)) + 1


static func _point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [
		roundi(point.x * EDGE_QUANTIZATION),
		roundi(point.y * EDGE_QUANTIZATION),
		roundi(point.z * EDGE_QUANTIZATION),
	]


static func _vector_summary(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}
