@tool
extends RefCounted
class_name LowPolyTerrainPicking

## Pure analytic picking helpers for the terrain editor brush.
##
## Deliberately free of any Editor* type or singleton, so the logic runs inside exported
## release builds and can be unit tested by GUT without instantiating an EditorPlugin.
##
## Deactivated chunks are drawn as a flat quad at a constant height. That makes them a plane,
## not a mesh, so a ray/plane intersection resolves them in O(1) without handing any geometry
## or collision shape to the engine.


## Upper bound on how many chunks keep a cached triangle soup. De-indexing a chunk allocates
## a full copy of its geometry, so the picking loop must not redo it every frame.
const FACES_CACHE_LIMIT: int = 64


## Casts a ray against the terrain geometry of every chunk and reports the nearest hit.
##
## Lives here rather than inside the EditorPlugin so it can be unit tested: GUT cannot
## instantiate an EditorPlugin, which is exactly why a hardcoded 5000-unit reach could sit in
## this loop unnoticed until it was found by hand on a very large terrain.
##
## `result` is filled in place and `faces_cache` is owned by the caller, both deliberately:
## the caller reuses one dictionary across frames, so this runs without allocating anything
## per call. Returns true when `result` describes a hit.
static func raycast_terrain(
	manager: LowPolyTerrainManager,
	ray_origin: Vector3,
	ray_dir: Vector3,
	faces_cache: Dictionary,
	result: Dictionary
) -> bool:
	result["hit"] = false
	result["point"] = Vector3.ZERO
	result["coord"] = Vector2i.ZERO
	result["distance"] = INF

	if manager == null:
		return false

	var closest: float = INF

	for coord: Vector2i in manager.get_chunk_coords():
		var chunk_mesh: ArrayMesh = manager.get_chunk_mesh(coord)
		if chunk_mesh == null:
			continue

		var chunk_xform: Transform3D = manager.get_chunk_global_transform(coord)

		# Transform the ray into the chunk's local space. affine_inverse() rather than
		# inverse(): the latter is only valid for orthonormal bases and silently produces
		# garbage the moment the manager carries any scale.
		var inv_transform: Transform3D = chunk_xform.affine_inverse()
		var local_origin: Vector3 = inv_transform * ray_origin
		var local_dir: Vector3 = inv_transform.basis * ray_dir

		# Ultra-fast AABB pre-test to reject distant chunks in O(1) time.
		#
		# Deliberately an unbounded ray rather than a segment. A segment needs a length, and
		# any fixed length is wrong for some terrain size: the previous 5000-unit cap made the
		# brush vanish once a zoomed-out editor camera sat farther away than that.
		# intersects_ray() returns the hit point or null and never a bool, so the comparison is
		# explicit - relying on Vector3 truthiness would additionally discard a hit landing
		# exactly on the local origin.
		if chunk_mesh.get_aabb().intersects_ray(local_origin, local_dir) == null:
			continue

		var faces: PackedVector3Array = cached_faces(faces_cache, coord, chunk_mesh)
		for i in range(0, faces.size(), 3):
			var intersect = Geometry3D.ray_intersects_triangle(
				local_origin, local_dir, faces[i], faces[i + 1], faces[i + 2]
			)
			if intersect != null:
				# Measured in world space so hits from differently transformed chunks, and the
				# analytic deactivated-grid pass, share one common metric.
				var candidate: Vector3 = chunk_xform * intersect
				var dist: float = ray_origin.distance_to(candidate)
				if dist < closest:
					closest = dist
					result["hit"] = true
					result["point"] = candidate
					result["coord"] = coord
					result["distance"] = dist

	return bool(result["hit"])


## Returns a chunk's triangle soup, reusing the cached copy while the geometry is unchanged.
static func cached_faces(
	cache: Dictionary,
	coord: Vector2i,
	chunk_mesh: ArrayMesh
) -> PackedVector3Array:
	# Keyed on the mesh RID rather than on a strong reference: holding the ArrayMesh itself
	# would keep superseded meshes alive long after the chunks that owned them were rebuilt.
	var mesh_rid: RID = chunk_mesh.get_rid()
	var entry: Dictionary = cache.get(coord, {})
	if entry.has("rid") and entry["rid"] == mesh_rid:
		return entry["faces"]

	# Not get_faces(): that caches inside the mesh for good, so simply moving the mouse
	# across the terrain would permanently accumulate memory per chunk crossed.
	var faces: PackedVector3Array = LowPolyTerrainMeshBuilder.build_face_soup(chunk_mesh)
	if cache.size() >= FACES_CACHE_LIMIT:
		cache.clear()
	cache[coord] = { "rid": mesh_rid, "faces": faces }
	return faces


## Analytically intersects a viewport ray with the deactivated-chunk preview plane.
## Returns { "hit": bool, "point": Vector3, "coord": Vector2i, "distance": float }.
## Reports a miss for anything that is not an actually deactivated chunk inside the grid.
static func pick_deactivated_chunk(
	manager: LowPolyTerrainManager,
	ray_origin: Vector3,
	ray_dir: Vector3
) -> Dictionary:
	var miss: Dictionary = {
		"hit": false,
		"point": Vector3.ZERO,
		"coord": Vector2i.ZERO,
		"distance": INF,
	}

	if manager == null or not manager.is_inside_tree():
		return miss
	if not bool(manager.show_deactivated_chunks):
		return miss

	var meters_per_chunk: float = float(manager.chunk_size) * manager.cell_size
	if is_zero_approx(meters_per_chunk):
		return miss

	# Work in the manager's local space so rotation and scale are handled implicitly.
	var inv: Transform3D = manager.global_transform.affine_inverse()
	var local_origin: Vector3 = inv * ray_origin
	var local_dir: Vector3 = inv.basis * ray_dir

	if is_zero_approx(local_dir.y):
		return miss

	var t: float = (LowPolyTerrainMeshBuilder.PREVIEW_PLANE_Y - local_origin.y) / local_dir.y
	if t < 0.0:
		return miss

	var local_hit: Vector3 = local_origin + local_dir * t

	# floori() rather than integer division: int(-0.5 / 10.0) truncates toward zero and would
	# fold every negative coordinate onto chunk 0, producing phantom hits off the west edge.
	var cx: int = floori(local_hit.x / meters_per_chunk)
	var cz: int = floori(-local_hit.z / meters_per_chunk)

	# Rejected rather than clamped on purpose. Clamping would report a hit on a border chunk
	# for a ray that crosses the plane far beyond the terrain, making the brush snap to the
	# map corner whenever the mouse hovers empty space below the horizon.
	if cx < 0 or cx >= manager.world_chunks.x or cz < 0 or cz >= manager.world_chunks.y:
		return miss
	if manager.is_chunk_active(cx, cz):
		return miss

	var world_hit: Vector3 = manager.global_transform * local_hit
	return {
		"hit": true,
		"point": world_hit,
		"coord": Vector2i(cx, cz),
		"distance": ray_origin.distance_to(world_hit),
	}
