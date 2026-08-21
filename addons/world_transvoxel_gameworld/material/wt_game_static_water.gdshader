shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec3 deep_color : source_color = vec3(0.015, 0.14, 0.20);
uniform vec3 edge_color : source_color = vec3(0.08, 0.38, 0.46);
uniform float deep_tint : hint_range(0.0, 1.0) = 0.34;
uniform float edge_tint : hint_range(0.0, 1.0) = 0.52;
uniform float refraction_strength : hint_range(0.0, 0.05) = 0.008;

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float fresnel = pow(1.0 - facing, 5.0);
	vec2 offset = NORMAL.xy * refraction_strength * (0.35 + 0.65 * fresnel);
	vec2 sample_uv = clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999));
	vec3 background = textureLod(screen_texture, sample_uv, 0.0).rgb;
	vec3 tint = mix(deep_color, edge_color, fresnel);
	float tint_strength = mix(deep_tint, edge_tint, fresnel);
	// The nearest rear face is the water exit boundary when the camera is inside.
	if (!FRONT_FACING) {
		tint = deep_color;
		tint_strength = max(tint_strength, 0.58);
	}
	ALBEDO = mix(background, tint, tint_strength);
	// Alpha one makes every chunk replace, rather than compound over, the same
	// opaque-scene sample. Transparent-pass depth writes retain the nearest shell
	// without hiding the opaque terrain from screen_texture.
	ALPHA = 1.0;
}
