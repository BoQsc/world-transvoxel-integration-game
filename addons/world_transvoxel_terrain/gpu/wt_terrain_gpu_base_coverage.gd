@tool
extends RefCounted
class_name WtTerrainGpuBaseCoverage

const ROOT_LOD := 3
const ROOT_EXTENT := 128
const DRAW_COMMAND_STRIDE := 20

var _device: RenderingDevice
var _rids: Array[RID] = []
var _entry: Dictionary = {}
var _roots: Array = []
var _root_inventory: Dictionary = {}
var _initial_indirect := PackedByteArray()
var _selected_tokens: Dictionary = {}
var _cut_roots: Dictionary = {}
var _source_revision := 0
var _error := ""


func initialize(device: RenderingDevice, vertex_format: int, upload: Dictionary) -> bool:
	if device == null or vertex_format < 0 or not bool(upload.get("ok", false)) \
			or int(upload.get("lod", -1)) != ROOT_LOD:
		_error = "validated LOD3 base upload is required"
		return false
	var positions: PackedByteArray = upload.get("positions", PackedByteArray())
	var normals: PackedByteArray = upload.get("normals", PackedByteArray())
	var metadata: PackedByteArray = upload.get("metadata", PackedByteArray())
	var indices: PackedByteArray = upload.get("indices", PackedByteArray())
	var indirect: PackedByteArray = upload.get("indirect", PackedByteArray())
	var vertex_count := int(upload.get("vertex_count", 0))
	var index_count := int(upload.get("index_count", 0))
	var draw_count := int(upload.get("draw_count", 0))
	var roots: Array = upload.get("roots", [])
	if vertex_count <= 0 or index_count <= 0 or draw_count <= 0 \
			or roots.is_empty() or positions.size() != vertex_count * 12 \
			or normals.size() != vertex_count * 4 \
			or metadata.size() != vertex_count * 4 \
			or indices.size() != index_count * 4 \
			or indirect.size() != draw_count * DRAW_COMMAND_STRIDE:
		_error = "base upload buffer inventory is invalid"
		return false
	_device = device
	var position_buffer := device.vertex_buffer_create(
		positions.size(), positions, RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	)
	var normal_buffer := device.vertex_buffer_create(
		normals.size(), normals, RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	)
	var metadata_buffer := device.vertex_buffer_create(
		metadata.size(), metadata, RenderingDevice.BUFFER_CREATION_AS_STORAGE_BIT
	)
	var index_buffer := device.index_buffer_create(
		index_count, RenderingDevice.INDEX_BUFFER_FORMAT_UINT32
	)
	var indirect_buffer := device.storage_buffer_create(
		indirect.size(), indirect,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
	)
	_rids = [position_buffer, normal_buffer, metadata_buffer, index_buffer, indirect_buffer]
	for rid in _rids:
		if not rid.is_valid():
			_error = "base GPU buffer allocation failed"
			close()
			return false
	if device.buffer_update(index_buffer, 0, indices.size(), indices) != OK:
		_error = "base GPU index upload failed"
		close()
		return false
	var vertex_array := device.vertex_array_create(
		vertex_count, vertex_format,
		[position_buffer, normal_buffer, metadata_buffer]
	)
	var index_array := device.index_array_create(index_buffer, 0, index_count)
	_rids.append_array([vertex_array, index_array])
	if not vertex_array.is_valid() or not index_array.is_valid():
		_error = "base GPU vertex/index views failed"
		close()
		return false
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for root_value in roots:
		var root := Dictionary(root_value)
		var key: Vector3i = root.get("key", Vector3i.ZERO)
		var text_key := _root_key(key)
		if _root_inventory.has(text_key):
			_error = "duplicate base root"
			close()
			return false
		_root_inventory[text_key] = true
		minimum = minimum.min(Vector3(key) * ROOT_EXTENT)
		maximum = maximum.max(Vector3(key + Vector3i.ONE) * ROOT_EXTENT)
		var draw_index := int(root.get("draw_index", -2))
		if draw_index < -1 or draw_index >= draw_count:
			_error = "base root draw index is invalid"
			close()
			return false
	_roots = roots
	_initial_indirect = indirect
	_source_revision = int(upload.get("source_revision", 0))
	_entry = {
		"identity": {"surface": "terrain", "base_coverage": true},
		"resident_kind": "base_coverage",
		"vertex_array": vertex_array,
		"index_array": index_array,
		"indirect_buffer": indirect_buffer,
		"indirect_offset": 0,
		"indirect_draw_count": draw_count,
		"gpu_slot": -1,
		"bounds_min": minimum,
		"bounds_max": maximum,
		"cell_count": 0,
	}
	_error = ""
	return true


func is_ready() -> bool:
	return not _entry.is_empty()


func get_error() -> String:
	return _error


func get_draw_entry() -> Dictionary:
	return _entry


func get_selected_tokens() -> Dictionary:
	return _selected_tokens


func get_retained_root_count() -> int:
	return _roots.size() - _cut_roots.size()


func get_cut_root_count() -> int:
	return _cut_roots.size()


func reconcile(active_entries: Array) -> bool:
	if not is_ready():
		return false
	var leaves: Dictionary = {}
	var entry_by_token: Dictionary = {}
	for entry_value in active_entries:
		var entry := Dictionary(entry_value)
		var identity := Dictionary(entry.get("identity", {}))
		if str(identity.get("surface", "")) != "terrain" \
				or int(identity.get("source_revision", -1)) != _source_revision \
				or bool(entry.get("counts_pending", true)) \
				or int(entry.get("failure_cell_count", 0)) != 0:
			continue
		var lod := int(identity.get("lod", -1))
		if lod < 0 or lod > ROOT_LOD:
			continue
		var token := str(entry.get("token", ""))
		if token.is_empty():
			continue
		var key := _leaf_key(
			int(identity.get("page_x", -999999)),
			int(identity.get("page_y", -999999)),
			int(identity.get("page_z", -999999)), lod
		)
		leaves[key] = token
		entry_by_token[token] = entry
	var proposed: Dictionary = {}
	for root_value in _roots:
		var root := Dictionary(root_value)
		var key: Vector3i = root.get("key", Vector3i.ZERO)
		var selected: Array[String] = []
		if _cover(key.x, key.y, key.z, ROOT_LOD, leaves, selected, entry_by_token):
			proposed[_root_key(key)] = selected
	var changed := true
	while changed:
		changed = false
		for root_value in _roots:
			var root := Dictionary(root_value)
			var root_key: Vector3i = root.get("key", Vector3i.ZERO)
			var text_key := _root_key(root_key)
			if not proposed.has(text_key):
				continue
			if not _balanced_against_retained_base(
				root_key, Array(proposed[text_key]), proposed, entry_by_token
			):
				proposed.erase(text_key)
				changed = true
	if proposed == _cut_roots:
		return true
	var updated := _initial_indirect.duplicate()
	var selected_tokens: Dictionary = {}
	for root_value in _roots:
		var root := Dictionary(root_value)
		var root_key: Vector3i = root.get("key", Vector3i.ZERO)
		var text_key := _root_key(root_key)
		var draw_index := int(root.get("draw_index", -1))
		if draw_index >= 0:
			updated.encode_s32(
				draw_index * DRAW_COMMAND_STRIDE + 4,
				0 if proposed.has(text_key) else 1
			)
		if proposed.has(text_key):
			for token in Array(proposed[text_key]):
				selected_tokens[str(token)] = true
	if _device.buffer_update(
			_entry["indirect_buffer"], 0, updated.size(), updated
	) != OK:
		_error = "base cut upload failed; previous complete cut retained"
		return false
	_cut_roots = proposed
	_selected_tokens = selected_tokens
	_error = ""
	return true


func close() -> void:
	if _device != null:
		# Views depend on their backing buffers and must be freed first.
		for index in range(_rids.size() - 1, -1, -1):
			var rid: RID = _rids[index]
			if rid.is_valid():
				_device.free_rid(rid)
	_rids.clear()
	_entry.clear()
	_roots.clear()
	_root_inventory.clear()
	_initial_indirect.clear()
	_selected_tokens.clear()
	_cut_roots.clear()


static func _root_key(key: Vector3i) -> String:
	return "%d:%d:%d" % [key.x, key.y, key.z]


static func _leaf_key(x: int, y: int, z: int, lod: int) -> String:
	return "%d:%d:%d:%d" % [x, y, z, lod]


func _cover(
	x: int, y: int, z: int, lod: int,
	leaves: Dictionary, selected: Array[String], entries: Dictionary = {}
) -> bool:
	var key := _leaf_key(x, y, z, lod)
	# A complete finer cut wins over retained coarse coverage. The old parent
	# remains selected until every child region has a validated replacement.
	if lod > 0:
		var children: Array[String] = []
		var complete := true
		for dx in range(2):
			for dy in range(2):
				for dz in range(2):
					if not _cover(
						x * 2 + dx, y * 2 + dy, z * 2 + dz,
						lod - 1, leaves, children, entries
					):
						complete = false
						break
				if not complete:
					break
			if not complete:
				break
		if complete:
			selected.append_array(children)
			return true
	if leaves.has(key):
		var token := str(leaves[key])
		var entry := Dictionary(entries.get(token, {}))
		var identity := Dictionary(entry.get("identity", {}))
		var mask := int(entry.get(
			"regular_visibility_mask", identity.get("regular_visibility_mask", 0xff)
		))
		if mask < 0 or mask > 0xff or (lod == 0 and mask != 0xff):
			return false
		var start := selected.size()
		selected.append(token)
		if mask == 0xff:
			return true
		for dx in range(2):
			for dy in range(2):
				for dz in range(2):
					var brick := dx + 2 * dy + 4 * dz
					if (mask & (1 << brick)) != 0:
						continue
					if not _cover(
						x * 2 + dx, y * 2 + dy, z * 2 + dz,
						lod - 1, leaves, selected, entries
					):
						selected.resize(start)
						return false
		return true
	return false


func _balanced_against_retained_base(
	root_key: Vector3i, selected: Array,
	proposed: Dictionary, entries: Dictionary
) -> bool:
	for face in range(6):
		var neighbor := root_key
		var axis := face >> 1
		neighbor[axis] += -1 if face % 2 == 0 else 1
		if proposed.has(_root_key(neighbor)) or not _has_root(neighbor):
			continue
		var boundary := root_key[axis] * ROOT_EXTENT \
			if face % 2 == 0 else (root_key[axis] + 1) * ROOT_EXTENT
		for token in selected:
			var entry := Dictionary(entries.get(str(token), {}))
			var identity := Dictionary(entry.get("identity", {}))
			var lod := int(identity.get("lod", -1))
			var coordinate := int(identity.get(
				["page_x", "page_y", "page_z"][axis], -999999
			))
			var extent := 16 << lod
			var touches := coordinate * extent == boundary \
				if face % 2 == 0 else (coordinate + 1) * extent == boundary
			if touches and (lod < ROOT_LOD - 1 or (
				lod == ROOT_LOD - 1 and
				(int(identity.get("transition_mask", 0)) & (1 << face)) == 0
			)):
				return false
	return true


func _has_root(key: Vector3i) -> bool:
	return _root_inventory.has(_root_key(key))
