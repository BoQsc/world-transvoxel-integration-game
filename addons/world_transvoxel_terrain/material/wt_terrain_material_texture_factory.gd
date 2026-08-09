extends RefCounted


static func checker_texture(resolution: int) -> Dictionary:
	var image := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
	var checksum := 0
	for y in range(resolution):
		for x in range(resolution):
			var bright := ((x / 4) + (y / 4)) % 2 == 0
			var byte_value := 255 if bright else 158
			var value := float(byte_value) / 255.0
			checksum = int((checksum + ((x + 1) * 31 + (y + 1) * 17) * byte_value) % 2147483647)
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	return {
		"texture": ImageTexture.create_from_image(image),
		"checksum": checksum,
	}


static func texture_bytes(resolution: int, bytes_per_pixel: int) -> int:
	return resolution * resolution * bytes_per_pixel


static func production_atlas(resolution: int, slot: StringName) -> Texture2D:
	var image := Image.create(resolution * 4, resolution, false, Image.FORMAT_RGBA8)
	var base := [
		Color(0.40, 0.62, 0.22, 1.0),
		Color(0.42, 0.43, 0.42, 1.0),
		Color(0.63, 0.53, 0.36, 1.0),
		Color(0.30, 0.30, 0.32, 1.0),
	]
	for y in range(resolution):
		for x in range(resolution * 4):
			var tile := int(x / resolution)
			var color: Color = base[tile]
			if slot == &"normal":
				color = Color(0.5, 0.5, 1.0, 1.0)
			elif slot == &"roughness_orm":
				color = Color(0.0, 0.76 + float(tile) * 0.04, 1.0, 1.0)
			else:
				var grain := 0.90 + 0.10 * float(((x * 13 + y * 7 + tile * 19) % 11)) / 10.0
				color = Color(color.r * grain, color.g * grain, color.b * grain, 1.0)
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


static func production_array(resolution: int, slot: StringName) -> Texture2DArray:
	var base := [
		Color(0.24, 0.25, 0.24, 1.0),
		Color(0.28, 0.39, 0.20, 1.0),
		Color(0.36, 0.35, 0.33, 1.0),
		Color(0.56, 0.49, 0.35, 1.0),
		Color(0.68, 0.70, 0.66, 1.0),
		Color(0.31, 0.32, 0.31, 1.0),
		Color(0.48, 0.29, 0.13, 1.0),
		Color(0.09, 0.10, 0.11, 1.0),
	]
	var images: Array[Image] = []
	for tile in range(base.size()):
		var image := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
		for y in range(resolution):
			for x in range(resolution):
				image.set_pixel(x, y, _production_texel(base[tile], tile, x, y, slot))
		image.generate_mipmaps(slot == &"normal")
		images.append(image)
	var texture := Texture2DArray.new()
	var error := texture.create_from_images(images)
	if error != OK:
		push_error("failed to create terrain texture array: %s" % str(error))
	return texture


static func _production_texel(base: Color, tile: int, x: int, y: int, slot: StringName) -> Color:
	if slot == &"normal":
		var bump := (_noise(tile, x, y, 3) - 0.5) * (0.032 if tile == 6 else 0.018)
		return Color(0.5 + bump, 0.5 - bump, 1.0, 1.0)
	if slot == &"roughness_orm":
		var values := [0.86, 0.95, 0.92, 0.88, 0.74, 0.90, 0.58, 0.88]
		return Color(0.0, values[tile], 1.0, 1.0)
	var grain := 0.88 + 0.18 * _noise(tile, x, y, 1)
	return Color(base.r * grain, base.g * grain, base.b * grain, 1.0)


static func _noise(tile: int, x: int, y: int, salt: int) -> float:
	var value := posmod(x * 157 + y * 311 + tile * 911 + salt * 619, 10007)
	value = posmod(value * value * 73 + value * 19 + 97, 10009)
	return float(value) / 10008.0
