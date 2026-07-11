shader_type spatial;
render_mode diffuse_burley, cull_disabled;

uniform sampler2D checker_texture : source_color, repeat_enable;
uniform sampler2D terrain_albedo_atlas : source_color, repeat_enable;
uniform sampler2D terrain_normal_atlas : hint_normal, repeat_enable;
uniform sampler2D terrain_roughness_atlas : repeat_enable;
uniform vec4 material_1_color : source_color = vec4(0.22, 0.24, 0.27, 1.0);
uniform vec4 material_2_color : source_color = vec4(0.54, 0.76, 0.34, 1.0);
uniform vec4 material_3_color : source_color = vec4(0.42, 0.37, 0.31, 1.0);
uniform vec4 material_4_color : source_color = vec4(0.52, 0.44, 0.32, 1.0);
uniform vec4 material_7_color : source_color = vec4(0.42, 0.43, 0.42, 1.0);
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

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float material_tile(float material_id) {
	if (material_id > 1.5 && material_id < 2.5) {
		return 0.0;
	} else if (material_id > 2.5 && material_id < 3.5) {
		return 1.0;
	} else if (material_id > 3.5 && material_id < 4.5) {
		return 2.0;
	} else if (material_id > 6.5 && material_id < 7.5) {
		return 3.0;
	}
	return 1.0;
}

vec2 atlas_uv(float material_id, vec3 world_pos) {
	vec2 local_uv = fract(world_pos.xz * 0.125);
	return vec2((material_tile(material_id) + local_uv.x) * 0.25, local_uv.y);
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

vec3 material_clean_tint(float material_id) {
	if (material_id > 1.5 && material_id < 2.5) {
		return vec3(0.62, 0.64, 0.48);
	} else if (material_id > 2.5 && material_id < 3.5) {
		return vec3(0.64, 0.57, 0.43);
	} else if (material_id > 3.5 && material_id < 4.5) {
		return vec3(0.76, 0.68, 0.50);
	} else if (material_id > 6.5 && material_id < 7.5) {
		return vec3(0.55, 0.53, 0.48);
	}
	return vec3(0.52, 0.48, 0.40);
}

void fragment() {
	NORMAL = normalize(NORMAL);
	if (clean_visual_enabled) {
		float material_id = UV2.x;
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
		float material_id = UV2.x;
		vec4 base = material_1_color;
		if (material_id > 1.5 && material_id < 2.5) {
			base = material_2_color;
		} else if (material_id > 2.5 && material_id < 3.5) {
			base = material_3_color;
		} else if (material_id > 3.5 && material_id < 4.5) {
			base = material_4_color;
		} else if (material_id > 6.5 && material_id < 7.5) {
			base = material_7_color;
		}
		vec4 texel = texture(checker_texture, world_position.xz * 0.125);
		vec2 uv = atlas_uv(material_id, world_position);
		vec4 albedo_texel = texture(terrain_albedo_atlas, uv);
		vec3 normal_texel = texture(terrain_normal_atlas, uv).rgb * 2.0 - vec3(1.0);
		float roughness_texel = texture(terrain_roughness_atlas, uv).g;
		ALBEDO = mix(base.rgb * texel.rgb, albedo_texel.rgb, 0.72);
		NORMAL_MAP = normalize(normal_texel);
		ROUGHNESS = clamp(roughness_texel, 0.45, 0.98);
	}
}
