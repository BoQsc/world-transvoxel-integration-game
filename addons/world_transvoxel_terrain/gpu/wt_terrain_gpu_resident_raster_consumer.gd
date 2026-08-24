@tool
extends RefCounted

const SHADER_PATH := (
	"res://addons/world_transvoxel_terrain/gpu/wt_terrain_gpu_resident_raster.glsl"
)
const MAXIMUM_VERTICES_PER_CELL := 12
const MAXIMUM_INDICES_PER_CELL := 36
const DRAW_COMMAND_STRIDE := 20
const CLEAR_COLOR := Color(0.03, 0.05, 0.06, 1.0)

var _rendering_device: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _vertex_format := -1
var _framebuffer_format := -1
var _raster_index_buffer := RID()
var _raster_index_capacity := 0


func close() -> void:
	if _rendering_device != null:
		if _pipeline.is_valid():
			_rendering_device.free_rid(_pipeline)
		if _shader.is_valid():
			_rendering_device.free_rid(_shader)
		if _raster_index_buffer.is_valid():
			_rendering_device.free_rid(_raster_index_buffer)
	_rendering_device = null
	_shader = RID()
	_pipeline = RID()
	_vertex_format = -1
	_framebuffer_format = -1
	_raster_index_buffer = RID()
	_raster_index_capacity = 0


func consume(
	rendering_device: RenderingDevice,
	buffers: Array[RID],
	cell_count: int,
	view_center: Vector3,
	view_extent: float,
	target_size: Vector2i
) -> Dictionary:
	if rendering_device == null or buffers.size() != 21:
		return _failure("resident render buffer inventory is invalid")
	if cell_count <= 0 or not view_center.is_finite() or view_extent <= 0.0:
		return _failure("resident raster request is invalid")
	for binding in [13, 14, 15, 17, 20]:
		if not buffers[binding].is_valid():
			return _failure("resident render buffer %d is invalid" % binding)
	if _rendering_device != rendering_device:
		close()
		_rendering_device = rendering_device

	var color_texture := _create_color_texture(target_size)
	var depth_texture := _create_depth_texture(target_size)
	if not color_texture.is_valid() or not depth_texture.is_valid():
		_free_rid(color_texture)
		_free_rid(depth_texture)
		return _failure("resident raster target creation failed")
	var framebuffer := rendering_device.framebuffer_create([color_texture, depth_texture])
	if not framebuffer.is_valid() or not rendering_device.framebuffer_is_valid(framebuffer):
		_free_rid(framebuffer)
		_free_rid(color_texture)
		_free_rid(depth_texture)
		return _failure("resident raster framebuffer creation failed")
	var framebuffer_format := rendering_device.framebuffer_get_format(framebuffer)
	if not _ensure_pipeline(framebuffer_format):
		_free_rid(framebuffer)
		_free_rid(color_texture)
		_free_rid(depth_texture)
		return _failure("resident raster pipeline creation failed")

	var vertex_buffers: Array[RID] = [buffers[13], buffers[14], buffers[15]]
	var index_count := cell_count * MAXIMUM_INDICES_PER_CELL
	var index_bytes := index_count * 4
	if not _ensure_raster_index_buffer(index_count):
		_free_rid(framebuffer)
		_free_rid(color_texture)
		_free_rid(depth_texture)
		return _failure("resident raster index buffer creation failed")
	var copy_error := rendering_device.buffer_copy(
		buffers[17], _raster_index_buffer, 0, 0, index_bytes
	)
	if copy_error != OK:
		_free_rid(framebuffer)
		_free_rid(color_texture)
		_free_rid(depth_texture)
		return _failure(
			"resident raster index copy failed: %s" % error_string(copy_error)
		)
	var vertex_array := rendering_device.vertex_array_create(
		cell_count * MAXIMUM_VERTICES_PER_CELL,
		_vertex_format,
		vertex_buffers
	)
	var index_array := rendering_device.index_array_create(
		_raster_index_buffer, 0, index_count
	)
	if not vertex_array.is_valid() or not index_array.is_valid():
		_free_rid(vertex_array)
		_free_rid(index_array)
		_free_rid(framebuffer)
		_free_rid(color_texture)
		_free_rid(depth_texture)
		return _failure("resident raster vertex or index view creation failed")

	var draw_list := rendering_device.draw_list_begin(
		framebuffer,
		RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH,
		PackedColorArray([CLEAR_COLOR]),
		1.0,
		0,
		Rect2(Vector2.ZERO, Vector2(target_size))
	)
	rendering_device.draw_list_bind_render_pipeline(draw_list, _pipeline)
	rendering_device.draw_list_bind_vertex_array(draw_list, vertex_array)
	rendering_device.draw_list_bind_index_array(draw_list, index_array)
	var push_values := PackedFloat32Array([
		view_center.x, view_center.y, view_center.z, view_extent,
	])
	rendering_device.draw_list_set_push_constant(
		draw_list, push_values.to_byte_array(), 16
	)
	rendering_device.draw_list_draw_indirect(
		draw_list,
		true,
		buffers[20],
		0,
		cell_count,
		DRAW_COMMAND_STRIDE
	)
	rendering_device.draw_list_end()
	rendering_device.submit()
	rendering_device.sync()
	var color_bytes := rendering_device.texture_get_data(color_texture, 0)

	_free_rid(vertex_array)
	_free_rid(index_array)
	_free_rid(framebuffer)
	_free_rid(color_texture)
	_free_rid(depth_texture)

	var expected_bytes := target_size.x * target_size.y * 4
	if color_bytes.size() != expected_bytes:
		return _failure(
			"resident raster readback size %d != %d" % [color_bytes.size(), expected_bytes]
		)
	var foreground_pixels := _count_foreground_pixels(color_bytes)
	var pixel_count := target_size.x * target_size.y
	var coverage := float(foreground_pixels) / float(pixel_count)
	if foreground_pixels < 16 or coverage >= 0.98:
		return _failure(
			"resident raster coverage %.6f is outside the proof bounds" % coverage
		)
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_raster.v1",
		"status": "PASS",
		"fallback_used": false,
		"target_size": [target_size.x, target_size.y],
		"pixel_count": pixel_count,
		"foreground_pixel_count": foreground_pixels,
		"foreground_coverage": coverage,
		"image_sha256": _bytes_sha256(color_bytes),
		"indirect_draw_count": cell_count,
		"indirect_draw_stride_bytes": DRAW_COMMAND_STRIDE,
		"geometry_readback_bytes": 0,
		"geometry_device_local_copy_bytes": index_bytes,
		"device_local_index_copy_used": true,
		"direct_index_storage_alias_supported": false,
		"render_target_readback_bytes": color_bytes.size(),
		"same_device_compute_raster": true,
		"production_scene_publication": false,
	}


func _ensure_pipeline(framebuffer_format: int) -> bool:
	if _pipeline.is_valid() and _framebuffer_format == framebuffer_format:
		return true
	if _pipeline.is_valid():
		_rendering_device.free_rid(_pipeline)
		_pipeline = RID()
	if not _shader.is_valid():
		var shader_file := load(SHADER_PATH) as RDShaderFile
		if shader_file == null:
			return false
		_shader = _rendering_device.shader_create_from_spirv(shader_file.get_spirv())
		if not _shader.is_valid():
			return false
	if _vertex_format < 0:
		var attributes: Array[RDVertexAttribute] = []
		attributes.append(_vertex_attribute(
			0, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		))
		attributes.append(_vertex_attribute(
			1, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		))
		attributes.append(_vertex_attribute(
			2, RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT
		))
		_vertex_format = _rendering_device.vertex_format_create(attributes)
		if _vertex_format < 0:
			return false
	var rasterization := RDPipelineRasterizationState.new()
	rasterization.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var depth_stencil := RDPipelineDepthStencilState.new()
	depth_stencil.enable_depth_test = true
	depth_stencil.enable_depth_write = true
	depth_stencil.depth_compare_operator = RenderingDevice.COMPARE_OP_LESS
	var color_attachment := RDPipelineColorBlendStateAttachment.new()
	color_attachment.enable_blend = false
	var color_blend := RDPipelineColorBlendState.new()
	color_blend.attachments = [color_attachment]
	_pipeline = _rendering_device.render_pipeline_create(
		_shader,
		framebuffer_format,
		_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterization,
		RDPipelineMultisampleState.new(),
		depth_stencil,
		color_blend
	)
	_framebuffer_format = framebuffer_format
	return _pipeline.is_valid()


func _create_color_texture(size: Vector2i) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = size.x
	format.height = size.y
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	return _rendering_device.texture_create(format, RDTextureView.new(), [])


func _create_depth_texture(size: Vector2i) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_D32_SFLOAT
	format.width = size.x
	format.height = size.y
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
	return _rendering_device.texture_create(format, RDTextureView.new(), [])


func _ensure_raster_index_buffer(required_indices: int) -> bool:
	if _raster_index_buffer.is_valid() and required_indices <= _raster_index_capacity:
		return true
	if _raster_index_buffer.is_valid():
		_rendering_device.free_rid(_raster_index_buffer)
	var capacity := 4
	while capacity < required_indices:
		capacity *= 2
	_raster_index_buffer = _rendering_device.index_buffer_create(
		capacity,
		RenderingDevice.INDEX_BUFFER_FORMAT_UINT32
	)
	_raster_index_capacity = capacity if _raster_index_buffer.is_valid() else 0
	return _raster_index_buffer.is_valid()


static func _vertex_attribute(location: int, format: int) -> RDVertexAttribute:
	var attribute := RDVertexAttribute.new()
	attribute.location = location
	attribute.offset = 0
	attribute.format = format
	attribute.stride = 16
	attribute.frequency = RenderingDevice.VERTEX_FREQUENCY_VERTEX
	return attribute


static func _count_foreground_pixels(bytes: PackedByteArray) -> int:
	var clear_r := int(round(CLEAR_COLOR.r * 255.0))
	var clear_g := int(round(CLEAR_COLOR.g * 255.0))
	var clear_b := int(round(CLEAR_COLOR.b * 255.0))
	var count := 0
	for offset in range(0, bytes.size(), 4):
		if abs(int(bytes[offset]) - clear_r) > 2 \
				or abs(int(bytes[offset + 1]) - clear_g) > 2 \
				or abs(int(bytes[offset + 2]) - clear_b) > 2:
			count += 1
	return count


static func _bytes_sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _free_rid(rid: RID) -> void:
	if rid.is_valid() and _rendering_device != null:
		_rendering_device.free_rid(rid)


static func _failure(message: String) -> Dictionary:
	return {
		"schema": "world_transvoxel.terrain.gpu_resident_raster.v1",
		"status": "FAIL",
		"fallback_used": false,
		"geometry_readback_bytes": 0,
		"production_scene_publication": false,
		"error": message,
	}
