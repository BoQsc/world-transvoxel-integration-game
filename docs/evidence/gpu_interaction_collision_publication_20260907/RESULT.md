# Interaction collision publication pin

Native authority: 576c8cd1d3202bc35e4b3e5eec5271de29b752e5

Runtime artifact digest:
292e31fdbf3be0d11cc20a38565deb1bc5287a43f71bc6b5962d62c6c366006b

The game now consumes the native checkpoint that carries player-support and
interaction-focus collision urgency through the bounded publication and
application queues. Staged collision reaches Godot physics independently while
the matching GPU visual remains pending.

The cold {6,0,0,0} target reached the collision sink 17.897 ms after
preparation on Vulkan and 8.827 ms after preparation on D3D12. It preceded
visual readiness by 33.188 ms and 50.302 ms respectively. Both driver routes
passed with six hot edits, seven collision sink applications, complete GPU
lifecycle traces, and sub-1-ms edit submission. Combined visual-plus-collision
readiness remains 84.060 ms on Vulkan and 100.856 ms on D3D12; visual latency is
the next dependency to remove.
