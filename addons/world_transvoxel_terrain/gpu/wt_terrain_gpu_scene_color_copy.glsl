#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D destination_color;

layout(push_constant, std430) uniform Params {
	ivec4 viewport;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, params.viewport.xy))) {
		return;
	}
	imageStore(destination_color, pixel, texelFetch(source_color, pixel, 0));
}
