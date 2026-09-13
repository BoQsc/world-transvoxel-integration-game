extends RefCounted

const CHUNK_SIZE := 16.0
const MAXIMUM_VIEWERS := 3
const RADIUS_CHUNKS := 2


static func centers(origin: Vector3, direction: Vector3, distance: float) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not origin.is_finite() or not direction.is_finite() or \
			not is_finite(distance) or distance <= 0.0 or direction.is_zero_approx():
		return result
	var count := ceili(distance / (2.0 * CHUNK_SIZE))
	if count > MAXIMUM_VIEWERS:
		return result
	var step := distance / float(count)
	var forward := direction.normalized()
	# Small overlapping spheres cover the tool ray without making two radius-3
	# collision volumes compete with the player's support shell. Accepted edits
	# still promote their exact dirty chunks through the interactive lane.
	for index in range(count):
		result.append(origin + forward * (float(index) + 0.5) * step)
	return result
