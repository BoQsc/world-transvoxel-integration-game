extends RefCounted

const CHUNK_SIZE := 16.0
const MAXIMUM_VIEWERS := 2
const RADIUS_CHUNKS := 3


static func centers(origin: Vector3, direction: Vector3, distance: float) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not origin.is_finite() or not direction.is_finite() or \
			not is_finite(distance) or distance <= 0.0 or direction.is_zero_approx():
		return result
	var count := ceili(distance / (3.0 * CHUNK_SIZE))
	if count > MAXIMUM_VIEWERS:
		return result
	var step := distance / float(count)
	var forward := direction.normalized()
	# Every ray point is within 1.5 chunks of a center. The possible quantized
	# offsets fit the native radius-3 sphere, including diagonal rays.
	for index in range(count):
		result.append(origin + forward * (float(index) + 0.5) * step)
	return result
