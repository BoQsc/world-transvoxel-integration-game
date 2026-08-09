extends RefCounted


static func summarize(
	edge_counts: Dictionary,
	edge_owners: Dictionary,
	edge_directions: Dictionary = {}
) -> Dictionary:
	var boundary_edges := 0
	var nonmanifold_edges := 0
	var matched_edges := 0
	var orientation_inconsistent_edges := 0
	var maximum_edge_use := 0
	var boundary_examples := []
	var nonmanifold_examples := []
	var orientation_inconsistent_examples := []
	for key in edge_counts.keys():
		var count := int(edge_counts[key])
		maximum_edge_use = maxi(maximum_edge_use, count)
		if count == 1:
			boundary_edges += 1
			if boundary_examples.size() < 8:
				boundary_examples.append("%s owners=%s" % [str(key), _owners_summary(edge_owners.get(key, {}))])
		elif count == 2:
			matched_edges += 1
			if int(edge_directions.get(key, 0)) != 0:
				orientation_inconsistent_edges += 1
				if orientation_inconsistent_examples.size() < 8:
					orientation_inconsistent_examples.append("%s direction_sum=%d owners=%s" % [
						str(key),
						int(edge_directions.get(key, 0)),
						_owners_summary(edge_owners.get(key, {})),
					])
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
		"orientation_inconsistent_edges": orientation_inconsistent_edges,
		"boundary_edges": boundary_edges,
		"nonmanifold_edges": nonmanifold_edges,
		"maximum_edge_use": maximum_edge_use,
		"boundary_examples": boundary_examples,
		"nonmanifold_examples": nonmanifold_examples,
		"orientation_inconsistent_examples": orientation_inconsistent_examples,
	}


static func edge_key(a: Vector3, b: Vector3) -> String:
	var key_a := _point_key(a)
	var key_b := _point_key(b)
	if key_a < key_b:
		return key_a + "|" + key_b
	return key_b + "|" + key_a


static func edge_direction(a: Vector3, b: Vector3) -> int:
	var key_a := _point_key(a)
	var key_b := _point_key(b)
	if key_a < key_b:
		return 1
	if key_b < key_a:
		return -1
	return 0


static func _point_key(point: Vector3) -> String:
	const SCALE := 1024.0
	return "%d,%d,%d" % [
		roundi(point.x * SCALE),
		roundi(point.y * SCALE),
		roundi(point.z * SCALE),
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
