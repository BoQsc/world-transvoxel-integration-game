"""Reproduce the recorded peak seam defect without launching Godot.

Exit 0 means the saved defect was reproduced, not that terrain qualifies.
The double-precision ray calculation is an offline diagnostic, not a rasterizer.
"""

from __future__ import annotations

import json
from pathlib import Path


def subtract(a, b):
    return tuple(x - y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def ray_triangle(origin, direction, triangle):
    a, b, c = triangle
    ab, ac = subtract(b, a), subtract(c, a)
    p = cross(direction, ac)
    determinant = dot(ab, p)
    if abs(determinant) < 1e-12:
        return None
    offset = subtract(origin, a)
    u = dot(offset, p) / determinant
    q = cross(offset, ab)
    v = dot(direction, q) / determinant
    distance = dot(ac, q) / determinant
    if u < 0 or v < 0 or u + v > 1 or distance < 0:
        return None
    return distance


def triangles(entry):
    vertices = entry["vertex_positions"]
    indices = entry["indices"]
    assert len(indices) % 3 == 0
    for offset in range(0, len(indices), 3):
        ids = indices[offset:offset + 3]
        assert all(0 <= index < len(vertices) for index in ids)
        yield [vertices[index] for index in ids]


def main():
    sample = json.loads(Path(__file__).with_name("peak_sweep_failure.json").read_text())
    assert sample["label"] == "12_peak_sweep_f054"
    ray = sample["sky_pixel_rays"][0]
    origin = tuple(ray["origin"][axis] for axis in "xyz")
    direction = tuple(ray["direction"][axis] for axis in "xyz")
    plane_z = 896.0
    distance = (plane_z - origin[2]) / direction[2]
    point = tuple(o + distance * d for o, d in zip(origin, direction))
    entries = sample["gpu_geometry_ray_probe"]["rays"][0]["entries"]
    borders = []
    hit_count = 0
    tested_triangles = 0
    for entry in entries:
        identity = entry["identity"]
        for triangle in triangles(entry):
            tested_triangles += 1
            hit = ray_triangle(origin, direction, triangle)
            hit_count += hit is not None and hit <= ray["max_distance"]
            edge = [vertex for vertex in triangle if vertex[2] == plane_z]
            if len(edge) != 2 or edge[0][0] == edge[1][0]:
                continue
            if not min(v[0] for v in edge) <= point[0] <= max(v[0] for v in edge):
                continue
            alpha = (point[0] - edge[0][0]) / (edge[1][0] - edge[0][0])
            height = edge[0][1] + alpha * (edge[1][1] - edge[0][1])
            borders.append({"identity": identity, "edge": edge, "height": height})
    assert hit_count == 0, "saved ray unexpectedly intersects active geometry"
    assert len(borders) == 2, "expected the two recorded LOD boundary edges"
    fine = next(border for border in borders if border["identity"]["lod"] == 2)
    coarse = next(border for border in borders if border["identity"]["lod"] == 3)
    assert fine["height"] < point[1] < coarse["height"]
    assert coarse["identity"]["transition_mask"] & 32 == 0
    print(json.dumps({
        "status": "RECORDED_DEFECT_REPRODUCED_NOT_TERRAIN_PASS",
        "pixel": ray["screen_point"], "ray_at_shared_face": point,
        "tested_triangles": tested_triangles, "ray_hits": hit_count,
        "boundary_height_difference": coarse["height"] - fine["height"],
        "borders": borders,
        "scope": "one saved ray; not every captured pixel or whole-world topology",
    }, indent=2))


if __name__ == "__main__":
    main()
