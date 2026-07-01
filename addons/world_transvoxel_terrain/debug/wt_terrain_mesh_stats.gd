@tool
extends RefCounted
class_name WtTerrainMeshStats


static func collect(reference_scene: Node) -> Dictionary:
	var stats := {
		"instances": 0,
		"surfaces": 0,
		"face_vertices": 0,
		"triangles": 0,
		"max_extent": 0.0,
		"implementation": "terrain_addon_mesh_stats",
	}
	if reference_scene == null or not reference_scene.has_method("get_terrain_world"):
		return stats
	var terrain_world = reference_scene.call("get_terrain_world")
	if terrain_world == null or not terrain_world.has_method("get_backend_terrain"):
		return stats
	var backend = terrain_world.call("get_backend_terrain")
	if backend == null:
		return stats
	_accumulate(backend, stats)
	return stats


static func _accumulate(node: Node, stats: Dictionary) -> void:
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		stats["instances"] = int(stats.get("instances", 0)) + 1
		if instance.mesh != null:
			var mesh := instance.mesh
			var faces := mesh.get_faces()
			stats["surfaces"] = int(stats.get("surfaces", 0)) + mesh.get_surface_count()
			stats["face_vertices"] = int(stats.get("face_vertices", 0)) + faces.size()
			stats["triangles"] = int(stats.get("triangles", 0)) + int(faces.size() / 3)
			var size := mesh.get_aabb().size
			stats["max_extent"] = max(float(stats.get("max_extent", 0.0)), max(size.x, max(size.y, size.z)))
	for child in node.get_children():
		if child is Node:
			_accumulate(child, stats)
