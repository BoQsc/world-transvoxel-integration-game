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
uniform vec4 material_10_color : source_color = vec4(0.09, 0.10, 0.11, 1.0);
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
uniform bool procedural_ore_worldspace_blend_enabled = false;
uniform float procedural_seed_phase = 0.0001;
uniform float procedural_ore_blend_width = 0.12;
uniform bool procedural_rolling_exterior_surface_enabled = false;
uniform float procedural_surface_cover_full_depth = 1.25;
uniform float procedural_surface_cover_fade_depth = 2.75;
uniform float procedural_surface_cover_normal_start = -0.10;
uniform float procedural_surface_cover_normal_end = 0.30;
uniform float procedural_surface_biome_height_blend_width = 2.0;
uniform float procedural_surface_biome_noise_blend_width = 0.14;
uniform bool procedural_road_worldspace_blend_enabled = false;
uniform vec2 procedural_road_grade_0 = vec2(34.0, 39.0);
uniform vec2 procedural_road_grade_1 = vec2(39.0, 40.0);
uniform vec2 procedural_road_grade_2 = vec2(46.0, 39.0);
uniform vec2 procedural_road_grade_3 = vec2(39.0, 34.0);
uniform vec2 procedural_road_grade_4 = vec2(34.0, 33.0);
uniform vec2 procedural_road_grade_5 = vec2(34.0, 34.0);
uniform vec2 procedural_world_size_xz = vec2(2048.0, 2048.0);

const float PRODUCTION_TEXTURE_WORLD_SCALE = 0.125;
const float PRODUCTION_TRIPLANAR_BLEND_SHARPNESS = 4.0;

varying vec3 world_position;
varying vec3 world_normal;
varying vec4 generated_material_weights_low;
varying vec4 generated_material_weights_high;
varying vec4 authored_material_weights_low;
varying vec4 authored_material_weights_high;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	generated_material_weights_low = CUSTOM0;
	generated_material_weights_high = CUSTOM1;
	authored_material_weights_low = CUSTOM2;
	authored_material_weights_high = CUSTOM3;
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
	} else if (material_id > 9.5 && material_id < 10.5) {
		return 7.0;
	}
	return 0.0;
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

float deterministic_procedural_wave(vec3 world_pos, float phase) {
	return sin(world_pos.x * 0.031 + phase * 1.73) * 0.47 +
		cos(world_pos.z * 0.027 - phase * 1.19) * 0.38 +
		sin((world_pos.x + world_pos.z) * 0.014 + world_pos.y * 0.041 + phase) * 0.29;
}

float procedural_ore_worldspace_weight(vec3 world_pos) {
	float vein = sin(world_pos.x * 0.073 + procedural_seed_phase) *
		cos(world_pos.y * 0.097 - procedural_seed_phase * 0.7) *
		sin(world_pos.z * 0.061 + procedural_seed_phase * 1.3);
	float pocket = deterministic_procedural_wave(
		world_pos, procedural_seed_phase * 0.37
	);
	float vein_weight = smoothstep(
		0.48 - procedural_ore_blend_width,
		0.48 + procedural_ore_blend_width,
		vein
	);
	float pocket_weight = smoothstep(
		0.08 - procedural_ore_blend_width,
		0.08 + procedural_ore_blend_width,
		pocket
	);
	return clamp(vein_weight * pocket_weight, 0.0, 1.0);
}

vec3 procedural_road_segment_field(
	vec2 point,
	vec4 segment,
	vec2 endpoint_grades
) {
	vec2 start = segment.xy;
	vec2 end = segment.zw;
	vec2 direction = end - start;
	float t = clamp(
		dot(point - start, direction) /
			max(dot(direction, direction), 1.0),
		0.0,
		1.0
	);
	float distance_to_segment = length(point - mix(start, end, t));
	float grade = mix(endpoint_grades.x, endpoint_grades.y, t);
	float grade_weight = 1.0 - smoothstep(6.0, 11.0, distance_to_segment);
	return vec3(distance_to_segment, grade, grade_weight);
}

vec4 add_procedural_road_segment(vec4 field, vec3 segment) {
	field.x = min(field.x, segment.x);
	field.y += segment.y * segment.z;
	field.z += segment.z;
	field.w = max(field.w, segment.z);
	return field;
}

vec4 procedural_road_field(vec2 point) {
	vec4 field = vec4(1.0e20, 0.0, 0.0, 0.0);
	field = add_procedural_road_segment(field, procedural_road_segment_field(
		point,
		vec4(720.0, 820.0, 900.0, 820.0),
		procedural_road_grade_0
	));
	field = add_procedural_road_segment(field, procedural_road_segment_field(
		point,
		vec4(900.0, 820.0, 1080.0, 820.0),
		procedural_road_grade_1
	));
	field = add_procedural_road_segment(field, procedural_road_segment_field(
		point,
		vec4(900.0, 680.0, 900.0, 820.0),
		procedural_road_grade_2
	));
	field = add_procedural_road_segment(field, procedural_road_segment_field(
		point,
		vec4(900.0, 820.0, 900.0, 960.0),
		procedural_road_grade_3
	));
	field = add_procedural_road_segment(field, procedural_road_segment_field(
		point,
		vec4(720.0, 820.0, 760.0, 900.0),
		procedural_road_grade_4
	));
	field = add_procedural_road_segment(field, procedural_road_segment_field(
		point,
		vec4(900.0, 960.0, 1040.0, 940.0),
		procedural_road_grade_5
	));
	return field;
}

float procedural_rolling_hills_height(vec2 point) {
	vec2 center = procedural_world_size_xz * 0.5 - vec2(0.5);
	vec2 normalized = (point - center) / max(center, vec2(1.0));
	float phase = procedural_seed_phase;
	float broad =
		7.5 * sin(point.x * 0.0052 + phase * 1.7) +
		5.0 * cos(point.y * 0.0047 - phase * 1.2) +
		3.0 * sin((point.x + point.y) * 0.0034 + phase);
	float rolling =
		4.0 * sin((point.x - point.y) * 0.008 + phase) *
		cos((point.x + point.y) * 0.006 - phase * 0.6);
	float central_mound = 8.0 * exp(-2.7 * (
		pow(normalized.x - 0.03, 2.0) + pow(normalized.y + 0.06, 2.0)
	));
	float shallow_valley = -5.5 * exp(-5.0 * (
		pow(normalized.x + 0.34, 2.0) + pow(normalized.y - 0.22, 2.0)
	));
	float local =
		1.2 * sin(point.x * 0.018 - phase * 0.5) +
		0.9 * cos(point.y * 0.016 + phase * 0.9);
	return 26.0 + broad + rolling + central_mound + shallow_valley + local;
}

float procedural_surface_height(vec3 world_pos, vec4 road) {
	float base_surface = procedural_rolling_hills_height(world_pos.xz);
	if (!procedural_road_worldspace_blend_enabled) {
		return base_surface;
	}
	float road_grade = road.z > 0.0 ? road.y / road.z : base_surface;
	return mix(base_surface, road_grade, road.w);
}

float procedural_exterior_surface_coverage(
	vec3 world_pos,
	vec3 surface_normal,
	vec4 road
) {
	float surface = procedural_surface_height(world_pos, road);
	float distance_from_source_surface = abs(surface - world_pos.y);
	float depth_coverage = 1.0 - smoothstep(
		max(procedural_surface_cover_full_depth, 0.0),
		max(procedural_surface_cover_fade_depth,
			procedural_surface_cover_full_depth + 0.001),
		distance_from_source_surface
	);
	float orientation_coverage = smoothstep(
		procedural_surface_cover_normal_start,
		max(procedural_surface_cover_normal_end,
			procedural_surface_cover_normal_start + 0.001),
		surface_normal.y
	);
	return clamp(depth_coverage * orientation_coverage, 0.0, 1.0);
}

vec4 procedural_surface_biome_weights(vec3 world_pos, vec4 road) {
	float surface = procedural_surface_height(world_pos, road);
	float phase = procedural_seed_phase;
	float macro =
		sin(world_pos.x * 0.0042 + phase * 1.5) +
		cos(world_pos.z * 0.0037 - phase * 0.8) +
		0.55 * sin((world_pos.x - world_pos.z) * 0.0021 + phase);
	float dry =
		sin((world_pos.x + world_pos.z) * 0.0051 - phase * 0.4) +
		0.42 * cos(world_pos.x * 0.0063 + phase);
	float height_width = max(procedural_surface_biome_height_blend_width, 0.001);
	float noise_width = max(procedural_surface_biome_noise_blend_width, 0.001);
	float sand = max(
		1.0 - smoothstep(10.0 - height_width, 10.0 + height_width, surface),
		smoothstep(0.85 - noise_width, 0.85 + noise_width, dry)
	);
	float snow = max(
		smoothstep(40.0 - height_width, 40.0 + height_width, surface),
		smoothstep(30.0 - height_width, 30.0 + height_width, surface) *
			smoothstep(0.35 - noise_width, 0.35 + noise_width, macro)
	);
	float gravel = max(
		smoothstep(22.0 - height_width, 22.0 + height_width, surface),
		1.0 - smoothstep(-0.70 - noise_width, -0.70 + noise_width, macro)
	);
	gravel *= 1.0 - snow * 0.65;
	sand *= 1.0 - snow * 0.75;
	float grass = max(
		0.12,
		(1.0 - snow) * (1.0 - sand * 0.75) * (1.0 - gravel * 0.55)
	);
	vec4 weights = max(vec4(grass, gravel, sand, snow), vec4(0.0));
	float total = max(weights.x + weights.y + weights.z + weights.w, 0.0001);
	return weights / total;
}

float procedural_road_worldspace_weight(vec3 world_pos, vec4 road) {
	float road_grade = road.z > 0.0 ? road.y / road.z : world_pos.y;
	float horizontal_weight = 1.0 - smoothstep(5.25, 6.75, road.x);
	float surface_weight = 1.0 - smoothstep(4.0, 7.0, abs(world_pos.y - road_grade));
	return clamp(horizontal_weight * surface_weight, 0.0, 1.0);
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

float material_weight_sum(vec4 low_weights, vec4 high_weights) {
	vec4 safe_low = max(low_weights, vec4(0.0));
	vec4 safe_high = max(high_weights, vec4(0.0));
	return safe_low.x + safe_low.y + safe_low.z + safe_low.w +
		safe_high.x + safe_high.y + safe_high.z + safe_high.w;
}

vec4 production_material_albedo_from_weights(
	vec4 low_weights,
	vec4 high_weights,
	vec3 world_pos,
	vec3 surface_normal
) {
	vec4 safe_low = max(low_weights, vec4(0.0));
	vec4 safe_high = max(high_weights, vec4(0.0));
	float total = material_weight_sum(safe_low, safe_high);
	if (total <= 0.0001) {
		return production_albedo_color(1.0, world_pos, surface_normal);
	}
	vec4 albedo = vec4(0.0);
	if (safe_low.x > 0.0001) albedo += production_albedo_color(1.0, world_pos, surface_normal) * safe_low.x;
	if (safe_low.y > 0.0001) albedo += production_albedo_color(2.0, world_pos, surface_normal) * safe_low.y;
	if (safe_low.z > 0.0001) albedo += production_albedo_color(3.0, world_pos, surface_normal) * safe_low.z;
	if (safe_low.w > 0.0001) albedo += production_albedo_color(4.0, world_pos, surface_normal) * safe_low.w;
	if (safe_high.x > 0.0001) albedo += production_albedo_color(5.0, world_pos, surface_normal) * safe_high.x;
	if (safe_high.y > 0.0001) albedo += production_albedo_color(7.0, world_pos, surface_normal) * safe_high.y;
	if (safe_high.z > 0.0001) albedo += production_albedo_color(8.0, world_pos, surface_normal) * safe_high.z;
	if (safe_high.w > 0.0001) albedo += production_albedo_color(10.0, world_pos, surface_normal) * safe_high.w;
	return albedo / total;
}

float production_material_roughness_from_weights(
	vec4 low_weights,
	vec4 high_weights,
	vec3 world_pos,
	vec3 surface_normal
) {
	vec4 safe_low = max(low_weights, vec4(0.0));
	vec4 safe_high = max(high_weights, vec4(0.0));
	float total = material_weight_sum(safe_low, safe_high);
	if (total <= 0.0001) {
		return production_roughness_value(1.0, world_pos, surface_normal);
	}
	float roughness = 0.0;
	if (safe_low.x > 0.0001) roughness += production_roughness_value(1.0, world_pos, surface_normal) * safe_low.x;
	if (safe_low.y > 0.0001) roughness += production_roughness_value(2.0, world_pos, surface_normal) * safe_low.y;
	if (safe_low.z > 0.0001) roughness += production_roughness_value(3.0, world_pos, surface_normal) * safe_low.z;
	if (safe_low.w > 0.0001) roughness += production_roughness_value(4.0, world_pos, surface_normal) * safe_low.w;
	if (safe_high.x > 0.0001) roughness += production_roughness_value(5.0, world_pos, surface_normal) * safe_high.x;
	if (safe_high.y > 0.0001) roughness += production_roughness_value(7.0, world_pos, surface_normal) * safe_high.y;
	if (safe_high.z > 0.0001) roughness += production_roughness_value(8.0, world_pos, surface_normal) * safe_high.z;
	if (safe_high.w > 0.0001) roughness += production_roughness_value(10.0, world_pos, surface_normal) * safe_high.w;
	return roughness / total;
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
	} else if (material_id > 9.5 && material_id < 10.5) {
		return vec3(0.13, 0.14, 0.15);
	}
	return vec3(0.52, 0.48, 0.40);
}

vec3 material_clean_tint_from_weights(vec4 low_weights, vec4 high_weights) {
	vec4 safe_low = max(low_weights, vec4(0.0));
	vec4 safe_high = max(high_weights, vec4(0.0));
	float total = material_weight_sum(safe_low, safe_high);
	if (total <= 0.0001) {
		return material_clean_tint(1.0);
	}
	vec3 tint =
		material_clean_tint(1.0) * safe_low.x +
		material_clean_tint(2.0) * safe_low.y +
		material_clean_tint(3.0) * safe_low.z +
		material_clean_tint(4.0) * safe_low.w +
		material_clean_tint(5.0) * safe_high.x +
		material_clean_tint(7.0) * safe_high.y +
		material_clean_tint(8.0) * safe_high.z +
		material_clean_tint(10.0) * safe_high.w;
	return tint / total;
}

void fragment() {
	NORMAL = normalize(NORMAL);
	vec4 generated_low = max(generated_material_weights_low, vec4(0.0));
	vec4 generated_high = max(generated_material_weights_high, vec4(0.0));
	vec4 authored_low = max(authored_material_weights_low, vec4(0.0));
	vec4 authored_high = max(authored_material_weights_high, vec4(0.0));
	vec4 total_low = generated_low + authored_low;
	vec4 total_high = generated_high + authored_high;
	if (clean_visual_enabled) {
		vec3 clean_color = clean_albedo_color.rgb;
		if (clean_texture_enabled) {
			clean_color = clamp(clean_texture_color(world_position, normalize(world_normal)) * clean_albedo_color.rgb * 1.15, vec3(0.0), vec3(1.0));
		}
		if (clean_material_variation_enabled) {
			clean_color = mix(
				clean_color,
				material_clean_tint_from_weights(total_low, total_high),
				clamp(clean_material_variation_strength, 0.0, 1.0)
			);
		}
		ALBEDO = clean_color;
		METALLIC = 0.0;
		SPECULAR = clamp(clean_specular, 0.0, 1.0);
		ROUGHNESS = clamp(clean_roughness, 0.0, 1.0);
	} else {
		vec3 surface_normal = normalize(world_normal);
		float generated_coverage = material_weight_sum(generated_low, generated_high);
		float authored_coverage = material_weight_sum(authored_low, authored_high);
		float total_coverage = max(generated_coverage + authored_coverage, 0.0001);
		vec4 road = vec4(1.0e20, 0.0, 0.0, 0.0);
		if (procedural_road_worldspace_blend_enabled) {
			road = procedural_road_field(world_position.xz);
		}
		float exterior_coverage = procedural_rolling_exterior_surface_enabled ?
			procedural_exterior_surface_coverage(
				world_position, surface_normal, road
			) : 1.0;

		vec4 generated_base_low = vec4(generated_low.x, 0.0, 0.0, 0.0);
		vec4 generated_base_high = vec4(0.0, generated_high.y, 0.0, 0.0);
		if (!procedural_ore_worldspace_blend_enabled) {
			generated_base_high.z = generated_high.z;
		}
		if (!procedural_road_worldspace_blend_enabled) {
			generated_base_high.w = generated_high.w;
		}
		vec4 generated_albedo = production_material_albedo_from_weights(
			generated_base_low,
			generated_base_high,
			world_position,
			surface_normal
		);
		float generated_roughness = production_material_roughness_from_weights(
			generated_base_low,
			generated_base_high,
			world_position,
			surface_normal
		);

		if (procedural_ore_worldspace_blend_enabled && generated_coverage > 0.0001) {
			float ore_host_coverage = clamp(
				(generated_low.x + generated_high.z) / generated_coverage,
				0.0,
				1.0
			);
			float ore_weight = procedural_ore_worldspace_weight(world_position) *
				ore_host_coverage;
			generated_albedo = mix(
				generated_albedo,
				production_albedo_color(8.0, world_position, surface_normal),
				ore_weight
			);
			generated_roughness = mix(
				generated_roughness,
				production_roughness_value(8.0, world_position, surface_normal),
				ore_weight
			);
		}

		vec4 surface_weights = vec4(
			generated_low.y,
			generated_low.z,
			generated_low.w,
			generated_high.x
		);
		float surface_coverage = surface_weight_sum(surface_weights);
		if (procedural_rolling_exterior_surface_enabled) {
			surface_weights = procedural_surface_biome_weights(world_position, road);
			surface_coverage = generated_coverage * exterior_coverage;
		}
		if (surface_coverage > 0.001) {
			surface_weights = normalized_surface_weights(surface_weights);
			float coverage = clamp(surface_coverage, 0.0, 1.0);
			generated_albedo = mix(
				generated_albedo,
				production_surface_albedo_color(surface_weights, world_position, surface_normal),
				coverage
			);
			generated_roughness = mix(
				generated_roughness,
				production_surface_roughness_value(surface_weights, world_position, surface_normal),
				coverage
			);
		}
		if (procedural_road_worldspace_blend_enabled) {
			float road_weight = procedural_road_worldspace_weight(world_position, road) *
				generated_coverage * exterior_coverage;
			if (road_weight > 0.001) {
				generated_albedo = mix(
					generated_albedo,
					production_albedo_color(10.0, world_position, surface_normal),
					road_weight
				);
				generated_roughness = mix(
					generated_roughness,
					production_roughness_value(10.0, world_position, surface_normal),
					road_weight
				);
			}
		}

		vec4 authored_albedo = production_material_albedo_from_weights(
			authored_low,
			authored_high,
			world_position,
			surface_normal
		);
		float authored_roughness = production_material_roughness_from_weights(
			authored_low,
			authored_high,
			world_position,
			surface_normal
		);
		float authored_mix = clamp(authored_coverage / total_coverage, 0.0, 1.0);
		vec4 albedo_texel = mix(generated_albedo, authored_albedo, authored_mix);
		float roughness_texel = mix(
			generated_roughness, authored_roughness, authored_mix
		);
		ALBEDO = albedo_texel.rgb;
		SPECULAR = 0.0;
		ROUGHNESS = clamp(roughness_texel, 0.45, 0.98);
	}
}
