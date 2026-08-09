@tool
extends RefCounted


static func remove_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	_remove_directory_contents(absolute)
	DirAccess.remove_absolute(absolute)


static func _remove_directory_contents(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name != "." and name != "..":
			var child := path.path_join(name)
			if directory.current_is_dir():
				_remove_directory_contents(child)
				DirAccess.remove_absolute(child)
			else:
				DirAccess.remove_absolute(child)
		name = directory.get_next()
	directory.list_dir_end()


static func lod_from_render_name(node_name: String) -> int:
	var marker := node_name.find("_L")
	if marker < 0:
		return 0
	return int(node_name.substr(marker + 2).get_slice("_", 0))


static func format_integer(value: int) -> String:
	var digits := str(absi(value))
	var formatted := ""
	for index in range(digits.length()):
		if index > 0 and (digits.length() - index) % 3 == 0:
			formatted += ","
		formatted += digits[index]
	return ("-" if value < 0 else "") + formatted


static func vector_summary(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


static func add_box_lines(immediate: ImmediateMesh, minimum: Vector3, maximum: Vector3) -> void:
	var corners := [
		Vector3(minimum.x, minimum.y, minimum.z), Vector3(maximum.x, minimum.y, minimum.z),
		Vector3(maximum.x, maximum.y, minimum.z), Vector3(minimum.x, maximum.y, minimum.z),
		Vector3(minimum.x, minimum.y, maximum.z), Vector3(maximum.x, minimum.y, maximum.z),
		Vector3(maximum.x, maximum.y, maximum.z), Vector3(minimum.x, maximum.y, maximum.z),
	]
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		immediate.surface_add_vertex(corners[edge[0]])
		immediate.surface_add_vertex(corners[edge[1]])
