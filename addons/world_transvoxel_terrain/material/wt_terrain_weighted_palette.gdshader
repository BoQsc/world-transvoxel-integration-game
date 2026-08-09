shader_type spatial;
render_mode diffuse_burley, cull_back;

uniform sampler2D checker_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray terrain_albedo_array : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray terrain_normal_array : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray terrain_roughness_array : filter_linear_mipmap, repeat_enable;
uniform bool clean_visual_enabled = false;
uniform bool clean_texture_enabled = false;
uniform sampler2D clean_albedo_texture : source_color, repeat_enable;
uniform vec4 clean_albedo_color : source_color = vec4(0.72, 0.65, 0.50, 1.0);
uniform float clean_texture_world_scale = 0.125;
uniform bool clean_triplanar_enabled = true;
uniform float clean_triplanar_blend_sharpness = 4.0;
uniform bool clean_material_variation_enabled = false;
uniform float clean_material_variation_strength = 0.08;

const float TEXTURE_WORLD_SCALE = 0.125;
const float TRIPLANAR_SHARPNESS = 4.0;

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

vec3 triplanar_weights(vec3 normal, float sharpness) {
	vec3 weights = pow(max(abs(normal), vec3(0.0001)), vec3(max(sharpness, 0.001)));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}

vec4 sample_albedo_layer(float layer, vec3 position, vec3 normal) {
	vec3 weights = triplanar_weights(normal, TRIPLANAR_SHARPNESS);
	vec4 x_sample = texture(terrain_albedo_array, vec3(fract(position.zy * TEXTURE_WORLD_SCALE), layer));
	vec4 y_sample = texture(terrain_albedo_array, vec3(fract(position.xz * TEXTURE_WORLD_SCALE), layer));
	vec4 z_sample = texture(terrain_albedo_array, vec3(fract(position.xy * TEXTURE_WORLD_SCALE), layer));
	return x_sample * weights.x + y_sample * weights.y + z_sample * weights.z;
}

float sample_roughness_layer(float layer, vec3 position, vec3 normal) {
	vec3 weights = triplanar_weights(normal, TRIPLANAR_SHARPNESS);
	float x_sample = texture(terrain_roughness_array, vec3(fract(position.zy * TEXTURE_WORLD_SCALE), layer)).g;
	float y_sample = texture(terrain_roughness_array, vec3(fract(position.xz * TEXTURE_WORLD_SCALE), layer)).g;
	float z_sample = texture(terrain_roughness_array, vec3(fract(position.xy * TEXTURE_WORLD_SCALE), layer)).g;
	return x_sample * weights.x + y_sample * weights.y + z_sample * weights.z;
}

float material_weight_sum(vec4 low_weights, vec4 high_weights) {
	vec4 low = max(low_weights, vec4(0.0));
	vec4 high = max(high_weights, vec4(0.0));
	return low.x + low.y + low.z + low.w + high.x + high.y + high.z + high.w;
}

vec4 weighted_albedo(vec4 low_weights, vec4 high_weights, vec3 position, vec3 normal) {
	vec4 low = max(low_weights, vec4(0.0));
	vec4 high = max(high_weights, vec4(0.0));
	float total = material_weight_sum(low, high);
	if (total <= 0.0001) return sample_albedo_layer(0.0, position, normal);
	vec4 value = vec4(0.0);
	value += sample_albedo_layer(0.0, position, normal) * low.x;
	value += sample_albedo_layer(1.0, position, normal) * low.y;
	value += sample_albedo_layer(2.0, position, normal) * low.z;
	value += sample_albedo_layer(3.0, position, normal) * low.w;
	value += sample_albedo_layer(4.0, position, normal) * high.x;
	value += sample_albedo_layer(5.0, position, normal) * high.y;
	value += sample_albedo_layer(6.0, position, normal) * high.z;
	value += sample_albedo_layer(7.0, position, normal) * high.w;
	return value / total;
}

float weighted_roughness(vec4 low_weights, vec4 high_weights, vec3 position, vec3 normal) {
	vec4 low = max(low_weights, vec4(0.0));
	vec4 high = max(high_weights, vec4(0.0));
	float total = material_weight_sum(low, high);
	if (total <= 0.0001) return sample_roughness_layer(0.0, position, normal);
	float value = 0.0;
	value += sample_roughness_layer(0.0, position, normal) * low.x;
	value += sample_roughness_layer(1.0, position, normal) * low.y;
	value += sample_roughness_layer(2.0, position, normal) * low.z;
	value += sample_roughness_layer(3.0, position, normal) * low.w;
	value += sample_roughness_layer(4.0, position, normal) * high.x;
	value += sample_roughness_layer(5.0, position, normal) * high.y;
	value += sample_roughness_layer(6.0, position, normal) * high.z;
	value += sample_roughness_layer(7.0, position, normal) * high.w;
	return value / total;
}

vec3 clean_texture_color(vec3 position, vec3 normal) {
	if (!clean_triplanar_enabled) return texture(clean_albedo_texture, position.xz * clean_texture_world_scale).rgb;
	vec3 weights = triplanar_weights(normal, clean_triplanar_blend_sharpness);
	vec3 x_sample = texture(clean_albedo_texture, position.zy * clean_texture_world_scale).rgb;
	vec3 y_sample = texture(clean_albedo_texture, position.xz * clean_texture_world_scale).rgb;
	vec3 z_sample = texture(clean_albedo_texture, position.xy * clean_texture_world_scale).rgb;
	return x_sample * weights.x + y_sample * weights.y + z_sample * weights.z;
}

vec3 weighted_debug_tint(vec4 low, vec4 high) {
	float total = max(material_weight_sum(low, high), 0.0001);
	return (
		vec3(0.40, 0.42, 0.43) * low.x + vec3(0.48, 0.60, 0.38) * low.y +
		vec3(0.52, 0.42, 0.30) * low.z + vec3(0.78, 0.68, 0.50) * low.w +
		vec3(0.84, 0.86, 0.84) * high.x + vec3(0.52, 0.52, 0.49) * high.y +
		vec3(0.72, 0.47, 0.20) * high.z + vec3(0.13, 0.14, 0.15) * high.w
	) / total;
}

void fragment() {
	vec4 low = max(generated_material_weights_low + authored_material_weights_low, vec4(0.0));
	vec4 high = max(generated_material_weights_high + authored_material_weights_high, vec4(0.0));
	vec3 normal = normalize(world_normal);
	if (clean_visual_enabled) {
		vec3 color = clean_texture_enabled ? clean_texture_color(world_position, normal) * clean_albedo_color.rgb : clean_albedo_color.rgb;
		if (clean_material_variation_enabled) color = mix(color, weighted_debug_tint(low, high), clean_material_variation_strength);
		ALBEDO = clamp(color, vec3(0.0), vec3(1.0));
		ROUGHNESS = 0.9;
	} else {
		ALBEDO = weighted_albedo(low, high, world_position, normal).rgb;
		ROUGHNESS = clamp(weighted_roughness(low, high, world_position, normal), 0.45, 0.98);
	}
	SPECULAR = 0.0;
}
