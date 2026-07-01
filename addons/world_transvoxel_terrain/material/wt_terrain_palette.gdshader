shader_type spatial;
render_mode diffuse_burley, cull_back;

uniform sampler2D checker_texture : source_color, repeat_enable;
uniform vec4 material_1_color : source_color = vec4(0.22, 0.24, 0.27, 1.0);
uniform vec4 material_2_color : source_color = vec4(0.54, 0.76, 0.34, 1.0);
uniform vec4 material_3_color : source_color = vec4(0.42, 0.37, 0.31, 1.0);
uniform vec4 material_4_color : source_color = vec4(0.52, 0.44, 0.32, 1.0);
uniform vec4 material_7_color : source_color = vec4(0.42, 0.43, 0.42, 1.0);

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
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
	ALBEDO = mix(base.rgb * 0.75, base.rgb * texel.rgb, 0.35);
	ROUGHNESS = 0.92;
}
