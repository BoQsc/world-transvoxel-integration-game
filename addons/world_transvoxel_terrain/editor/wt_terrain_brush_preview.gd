@tool
extends RefCounted

const PREVIEW_NAME := "WT_TerrainAuthoringPreview"


static func update(world: Node, document: Resource) -> MeshInstance3D:
	clear(world)
	if world == null or document == null or not bool(document.get("preview_enabled")):
		return null
	var preview := MeshInstance3D.new()
	preview.name = PREVIEW_NAME
	preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if int(document.get("brush_shape")) == 1:
		var box := BoxMesh.new()
		box.size = Vector3(document.get("box_extents")) * 2.0
		preview.mesh = box
	else:
		var sphere := SphereMesh.new()
		sphere.radius = float(document.get("radius"))
		sphere.height = float(document.get("radius")) * 2.0
		preview.mesh = sphere
	preview.position = Vector3(document.get("center"))
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = _preview_color(int(document.get("mode")))
	preview.material_override = material
	preview.set_meta("world_transvoxel_editor_preview", true)
	world.add_child(preview)
	return preview


static func clear(world: Node) -> void:
	if world == null:
		return
	var existing := world.get_node_or_null(PREVIEW_NAME)
	if existing != null:
		existing.queue_free()


static func _preview_color(mode: int) -> Color:
	if mode == 0:
		return Color(0.95, 0.25, 0.20, 0.28)
	if mode == 3:
		return Color(0.25, 0.55, 1.0, 0.28)
	return Color(0.25, 0.90, 0.45, 0.28)
