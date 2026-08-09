shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 deep_color : source_color = vec4(0.015, 0.14, 0.20, 0.72);
uniform vec4 edge_color : source_color = vec4(0.08, 0.38, 0.46, 0.48);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.08;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.05;

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 5.0);
	vec4 color = mix(deep_color, edge_color, fresnel);
	ALBEDO = color.rgb;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	SPECULAR = 0.85;
	ALPHA = color.a;
}
