#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) writeonly buffer CompletionTokens {
    uvec4 tokens[];
} completion;

layout(push_constant, std430) uniform Parameters {
    uint global_slot;
    uint ticket;
    uint arena_generation;
    uint marker;
} params;

void main() {
    completion.tokens[params.global_slot] = uvec4(
        params.global_slot,
        params.ticket,
        params.arena_generation,
        params.marker
    );
}
