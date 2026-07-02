shader_type spatial;
render_mode diffuse_burley, cull_back;

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

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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

void fragment() {
	if (clean_visual_enabled) {
		vec3 clean_color = clean_albedo_color.rgb;
		if (clean_texture_enabled) {
			clean_color = clamp(texture(clean_albedo_texture, world_position.xz * clean_texture_world_scale).rgb * clean_albedo_color.rgb * 1.15, vec3(0.0), vec3(1.0));
		}
		ALBEDO = clean_color;
		ROUGHNESS = 0.88;
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
