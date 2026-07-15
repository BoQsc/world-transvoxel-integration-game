shader_type spatial;
render_mode diffuse_burley, cull_back;

uniform sampler2D checker_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray terrain_albedo_array : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray terrain_normal_array : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray terrain_roughness_array : filter_linear_mipmap, repeat_enable;
uniform vec4 material_1_color : source_color = vec4(0.24, 0.25, 0.24, 1.0);
uniform vec4 material_2_color : source_color = vec4(0.28, 0.39, 0.20, 1.0);
uniform vec4 material_3_color : source_color = vec4(0.36, 0.35, 0.33, 1.0);
uniform vec4 material_4_color : source_color = vec4(0.56, 0.49, 0.35, 1.0);
uniform vec4 material_5_color : source_color = vec4(0.68, 0.70, 0.66, 1.0);
uniform vec4 material_7_color : source_color = vec4(0.31, 0.32, 0.31, 1.0);
uniform vec4 material_8_color : source_color = vec4(0.48, 0.29, 0.13, 1.0);
uniform bool clean_visual_enabled = false;
uniform bool clean_texture_enabled = false;
uniform sampler2D clean_albedo_texture : source_color, repeat_enable;
uniform vec4 clean_albedo_color : source_color = vec4(0.72, 0.65, 0.50, 1.0);
uniform float clean_texture_world_scale = 0.125;
uniform bool clean_triplanar_enabled = true;
uniform float clean_triplanar_blend_sharpness = 4.0;
uniform bool clean_material_variation_enabled = false;
uniform float clean_material_variation_strength = 0.08;
uniform float clean_roughness = 1.0;
uniform float clean_specular = 0.0;
uniform bool surface_biome_worldspace_blend_enabled = true;
uniform float surface_biome_seed_phase = 0.0001;
uniform float surface_biome_height_blend_width = 6.0;
uniform float surface_biome_noise_blend_width = 0.28;

const float PRODUCTION_TEXTURE_WORLD_SCALE = 0.125;
const float PRODUCTION_TRIPLANAR_BLEND_SHARPNESS = 4.0;

varying vec3 world_position;
varying vec3 world_normal;
varying flat float material_id_flat;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	material_id_flat = UV2.x;
}

float material_layer(float material_id) {
	if (material_id > 0.5 && material_id < 1.5) {
		return 0.0;
	} else if (material_id > 1.5 && material_id < 2.5) {
		return 1.0;
	} else if (material_id > 2.5 && material_id < 3.5) {
		return 2.0;
	} else if (material_id > 3.5 && material_id < 4.5) {
		return 3.0;
	} else if (material_id > 4.5 && material_id < 5.5) {
		return 4.0;
	} else if (material_id > 6.5 && material_id < 7.5) {
		return 5.0;
	} else if (material_id > 7.5 && material_id < 8.5) {
		return 6.0;
	}
	return 7.0;
}

vec3 material_array_uv(float material_id, vec2 plane_pos) {
	return vec3(fract(plane_pos * PRODUCTION_TEXTURE_WORLD_SCALE), material_layer(material_id));
}

vec3 triplanar_weights(vec3 normal, float sharpness) {
	vec3 weights = pow(max(abs(normal), vec3(0.0001)), vec3(max(sharpness, 0.001)));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}

vec3 clean_texture_color(vec3 world_pos, vec3 normal) {
	if (!clean_triplanar_enabled) {
		return texture(clean_albedo_texture, world_pos.xz * clean_texture_world_scale).rgb;
	}
	vec3 weights = triplanar_weights(normal, clean_triplanar_blend_sharpness);
	vec3 x_projection = texture(clean_albedo_texture, world_pos.zy * clean_texture_world_scale).rgb;
	vec3 y_projection = texture(clean_albedo_texture, world_pos.xz * clean_texture_world_scale).rgb;
	vec3 z_projection = texture(clean_albedo_texture, world_pos.xy * clean_texture_world_scale).rgb;
	return x_projection * weights.x + y_projection * weights.y + z_projection * weights.z;
}

vec3 production_checker_color(vec3 world_pos, vec3 normal) {
	vec3 weights = triplanar_weights(normal, PRODUCTION_TRIPLANAR_BLEND_SHARPNESS);
	vec3 x_projection = texture(checker_texture, world_pos.zy * PRODUCTION_TEXTURE_WORLD_SCALE).rgb;
	vec3 y_projection = texture(checker_texture, world_pos.xz * PRODUCTION_TEXTURE_WORLD_SCALE).rgb;
	vec3 z_projection = texture(checker_texture, world_pos.xy * PRODUCTION_TEXTURE_WORLD_SCALE).rgb;
	return x_projection * weights.x + y_projection * weights.y + z_projection * weights.z;
}

vec4 production_albedo_color(float material_id, vec3 world_pos, vec3 normal) {
	vec3 weights = triplanar_weights(normal, PRODUCTION_TRIPLANAR_BLEND_SHARPNESS);
	vec4 x_projection = texture(terrain_albedo_array, material_array_uv(material_id, world_pos.zy));
	vec4 y_projection = texture(terrain_albedo_array, material_array_uv(material_id, world_pos.xz));
	vec4 z_projection = texture(terrain_albedo_array, material_array_uv(material_id, world_pos.xy));
	return x_projection * weights.x + y_projection * weights.y + z_projection * weights.z;
}

bool is_surface_biome_material(float material_id) {
	return material_id > 1.5 && material_id < 5.5;
}

float deterministic_macro_biome(vec3 world_pos) {
	return sin(world_pos.x * 0.0042 + surface_biome_seed_phase * 1.5) +
		cos(world_pos.z * 0.0037 - surface_biome_seed_phase * 0.8) +
		0.55 * sin((world_pos.x - world_pos.z) * 0.0021 + surface_biome_seed_phase);
}

float deterministic_dry_biome(vec3 world_pos) {
	return sin((world_pos.x + world_pos.z) * 0.0051 - surface_biome_seed_phase * 0.4) +
		0.42 * cos(world_pos.x * 0.0063 + surface_biome_seed_phase);
}

vec4 surface_biome_worldspace_weights(vec3 world_pos) {
	float height_width = max(surface_biome_height_blend_width, 0.001);
	float noise_width = max(surface_biome_noise_blend_width, 0.001);
	float macro = deterministic_macro_biome(world_pos);
	float dry = deterministic_dry_biome(world_pos);

	float low_sand = 1.0 - smoothstep(10.0 - height_width, 10.0 + height_width, world_pos.y);
	float dry_sand = smoothstep(0.85 - noise_width, 0.85 + noise_width, dry);
	float sand = max(low_sand, dry_sand);

	float high_snow = smoothstep(40.0 - height_width, 40.0 + height_width, world_pos.y);
	float macro_snow = smoothstep(30.0 - height_width, 30.0 + height_width, world_pos.y) *
		smoothstep(0.35 - noise_width, 0.35 + noise_width, macro);
	float snow = max(high_snow, macro_snow);

	float high_gravel = smoothstep(22.0 - height_width, 22.0 + height_width, world_pos.y);
	float macro_gravel = 1.0 - smoothstep(-0.70 - noise_width, -0.70 + noise_width, macro);
	float gravel = max(high_gravel, macro_gravel);

	// Keep priority soft instead of binary. This prevents LOD-dependent material
	// samples from moving visible biome borders, while still preserving broad
	// sand/grass/gravel/snow regions.
	gravel *= 1.0 - snow * 0.65;
	sand *= 1.0 - snow * 0.75;
	float grass = max(0.12, (1.0 - snow) * (1.0 - sand * 0.75) * (1.0 - gravel * 0.55));
	vec4 weights = max(vec4(grass, gravel, sand, snow), vec4(0.0));
	float total = max(weights.x + weights.y + weights.z + weights.w, 0.0001);
	return weights / total;
}

vec4 production_worldspace_surface_albedo_color(vec4 weights, vec3 world_pos, vec3 normal) {
	return production_albedo_color(2.0, world_pos, normal) * weights.x +
		production_albedo_color(3.0, world_pos, normal) * weights.y +
		production_albedo_color(4.0, world_pos, normal) * weights.z +
		production_albedo_color(5.0, world_pos, normal) * weights.w;
}

vec3 production_normal_color(float material_id, vec3 world_pos, vec3 normal) {
	vec3 weights = triplanar_weights(normal, PRODUCTION_TRIPLANAR_BLEND_SHARPNESS);
	vec3 x_projection = texture(terrain_normal_array, material_array_uv(material_id, world_pos.zy)).rgb;
	vec3 y_projection = texture(terrain_normal_array, material_array_uv(material_id, world_pos.xz)).rgb;
	vec3 z_projection = texture(terrain_normal_array, material_array_uv(material_id, world_pos.xy)).rgb;
	return x_projection * weights.x + y_projection * weights.y + z_projection * weights.z;
}

float production_roughness_value(float material_id, vec3 world_pos, vec3 normal) {
	vec3 weights = triplanar_weights(normal, PRODUCTION_TRIPLANAR_BLEND_SHARPNESS);
	float x_projection = texture(terrain_roughness_array, material_array_uv(material_id, world_pos.zy)).g;
	float y_projection = texture(terrain_roughness_array, material_array_uv(material_id, world_pos.xz)).g;
	float z_projection = texture(terrain_roughness_array, material_array_uv(material_id, world_pos.xy)).g;
	return x_projection * weights.x + y_projection * weights.y + z_projection * weights.z;
}

float production_worldspace_surface_roughness_value(vec4 weights, vec3 world_pos, vec3 normal) {
	return production_roughness_value(2.0, world_pos, normal) * weights.x +
		production_roughness_value(3.0, world_pos, normal) * weights.y +
		production_roughness_value(4.0, world_pos, normal) * weights.z +
		production_roughness_value(5.0, world_pos, normal) * weights.w;
}

vec4 normalized_surface_weights(vec4 weights) {
	vec4 safe_weights = max(weights, vec4(0.0));
	float weight_sum = safe_weights.x + safe_weights.y + safe_weights.z + safe_weights.w;
	if (weight_sum <= 0.0001) {
		return vec4(0.0);
	}
	return safe_weights / weight_sum;
}

float surface_weight_sum(vec4 weights) {
	vec4 safe_weights = max(weights, vec4(0.0));
	return clamp(safe_weights.x + safe_weights.y + safe_weights.z + safe_weights.w, 0.0, 1.0);
}

vec3 production_surface_base_tint(vec4 weights) {
	return material_2_color.rgb * weights.x +
		material_3_color.rgb * weights.y +
		material_4_color.rgb * weights.z +
		material_5_color.rgb * weights.w;
}

vec4 production_surface_albedo_color(vec4 weights, vec3 world_pos, vec3 normal) {
	return production_albedo_color(2.0, world_pos, normal) * weights.x +
		production_albedo_color(3.0, world_pos, normal) * weights.y +
		production_albedo_color(4.0, world_pos, normal) * weights.z +
		production_albedo_color(5.0, world_pos, normal) * weights.w;
}

vec3 production_surface_normal_color(vec4 weights, vec3 world_pos, vec3 normal) {
	return production_normal_color(2.0, world_pos, normal) * weights.x +
		production_normal_color(3.0, world_pos, normal) * weights.y +
		production_normal_color(4.0, world_pos, normal) * weights.z +
		production_normal_color(5.0, world_pos, normal) * weights.w;
}

float production_surface_roughness_value(vec4 weights, vec3 world_pos, vec3 normal) {
	return production_roughness_value(2.0, world_pos, normal) * weights.x +
		production_roughness_value(3.0, world_pos, normal) * weights.y +
		production_roughness_value(4.0, world_pos, normal) * weights.z +
		production_roughness_value(5.0, world_pos, normal) * weights.w;
}

vec3 material_clean_tint(float material_id) {
	if (material_id > 0.5 && material_id < 1.5) {
		return vec3(0.40, 0.42, 0.43);
	}
	if (material_id > 1.5 && material_id < 2.5) {
		return vec3(0.48, 0.60, 0.38);
	} else if (material_id > 2.5 && material_id < 3.5) {
		return vec3(0.52, 0.42, 0.30);
	} else if (material_id > 3.5 && material_id < 4.5) {
		return vec3(0.78, 0.68, 0.50);
	} else if (material_id > 4.5 && material_id < 5.5) {
		return vec3(0.84, 0.86, 0.84);
	} else if (material_id > 6.5 && material_id < 7.5) {
		return vec3(0.52, 0.52, 0.49);
	} else if (material_id > 7.5 && material_id < 8.5) {
		return vec3(0.72, 0.47, 0.20);
	}
	return vec3(0.52, 0.48, 0.40);
}

void fragment() {
	NORMAL = normalize(NORMAL);
	if (clean_visual_enabled) {
		float material_id = material_id_flat;
		vec3 clean_color = clean_albedo_color.rgb;
		if (clean_texture_enabled) {
			clean_color = clamp(clean_texture_color(world_position, normalize(world_normal)) * clean_albedo_color.rgb * 1.15, vec3(0.0), vec3(1.0));
		}
		if (clean_material_variation_enabled) {
			clean_color = mix(clean_color, material_clean_tint(material_id), clamp(clean_material_variation_strength, 0.0, 1.0));
		}
		ALBEDO = clean_color;
		METALLIC = 0.0;
		SPECULAR = clamp(clean_specular, 0.0, 1.0);
		ROUGHNESS = clamp(clean_roughness, 0.0, 1.0);
	} else {
		float material_id = material_id_flat;
		vec4 base = material_1_color;
		if (material_id > 1.5 && material_id < 2.5) {
			base = material_2_color;
		} else if (material_id > 2.5 && material_id < 3.5) {
			base = material_3_color;
		} else if (material_id > 3.5 && material_id < 4.5) {
			base = material_4_color;
		} else if (material_id > 4.5 && material_id < 5.5) {
			base = material_5_color;
		} else if (material_id > 6.5 && material_id < 7.5) {
			base = material_7_color;
		} else if (material_id > 7.5 && material_id < 8.5) {
			base = material_8_color;
		}
		vec3 surface_normal = normalize(world_normal);
		vec4 albedo_texel = production_albedo_color(material_id, world_position, surface_normal);
		float roughness_texel = production_roughness_value(material_id, world_position, surface_normal);
		if (surface_biome_worldspace_blend_enabled && is_surface_biome_material(material_id)) {
			vec4 surface_weights = surface_biome_worldspace_weights(world_position);
			albedo_texel = production_worldspace_surface_albedo_color(surface_weights, world_position, surface_normal);
			roughness_texel = production_worldspace_surface_roughness_value(surface_weights, world_position, surface_normal);
		}
		ALBEDO = albedo_texel.rgb;
		SPECULAR = 0.0;
		ROUGHNESS = clamp(roughness_texel, 0.45, 0.98);
	}
}
