@tool
extends RefCounted
class_name LowPolyTerrainMeshBuilder

## Stateless geometry factory shared by every terrain backend. Gathers geofenced points,
## performs dynamic edge decimation, injects slope-aware vertex jittering, and triangulates
## organic low-poly meshes via Delaunay.
##
## This class holds no instance state whatsoever. Both the MeshInstance3D based chunk nodes
## and the RenderingServer based backend call the very same static functions, which guarantees
## that the produced geometry is bit-identical across backends.


## True when two grid points carry identical paint. Compared byte for byte on purpose: the
## weights are quantised precisely so that neighbours inside one painted area come out equal
## and can still be decimated away.
static func _same_paint(
	paint_data: PackedByteArray, vert_count: int, ax: int, az: int, bx: int, bz: int
) -> bool:
	var a: int = (ax + az * vert_count) * 4
	var b: int = (bx + bz * vert_count) * 4
	if a < 0 or b < 0 or a + 3 >= paint_data.size() or b + 3 >= paint_data.size():
		return false

	return (paint_data[a] == paint_data[b] and paint_data[a + 1] == paint_data[b + 1]
		and paint_data[a + 2] == paint_data[b + 2] and paint_data[a + 3] == paint_data[b + 3])


## Reads one grid point's paint weights as a Color for the mesh's vertex colour channel.
static func _paint_color(
	paint_data: PackedByteArray, vert_count: int, x: int, z: int, steps: int
) -> Color:
	var base: int = (x + z * vert_count) * 4
	if base < 0 or base + 3 >= paint_data.size():
		return Color(0.0, 0.0, 0.0, 0.0)

	var scale: float = 1.0 / float(maxi(steps - 1, 1))
	return Color(
		float(paint_data[base]) * scale,
		float(paint_data[base + 1]) * scale,
		float(paint_data[base + 2]) * scale,
		float(paint_data[base + 3]) * scale
	)


## Core geometry generation engine. Parses the heightmap grid, runs decimation rules,
## applies slope-damped random displacements, and builds the visual trimesh via Delaunay.
## Returns null when the supplied data cannot produce any triangle.
## `paint_data` carries four bytes of layer weight per grid point, or is EMPTY when the terrain
## was never painted. It reaches the mesh as vertex colours and, just as importantly, takes part
## in the decimation below: two neighbouring points only count as flat when their PAINT matches
## as well, because a vertex that was thrown away cannot carry a colour.
static func build_chunk_mesh(
	chunk_coord: Vector2i,
	chunk_size: int,
	cell_size: float,
	height_data: PackedFloat32Array,
	jitter_strength: float,
	jitter_slope_threshold: float,
	paint_data: PackedByteArray = PackedByteArray(),
	paint_steps: int = 8
) -> ArrayMesh:
	if height_data.is_empty():
		return null
	var vert_count: int = chunk_size + 1

	# An unpainted terrain keeps the exact behaviour it had before painting existed: white
	# vertices, and a flatness test that only looks at heights.
	var has_paint: bool = paint_data.size() >= vert_count * vert_count * 4

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Zero, not white. The vertex colour now means one thing only - "how much of each paint
	# layer is on this point" - and an unpainted terrain has none of any. White would read as
	# all four layers at full weight and cover the base material completely.
	#
	# Safe to change because no shipped shader ever read COLOR, and StandardMaterial3D ignores
	# it unless vertex_color_use_as_albedo is switched on.
	var c := Color(0.0, 0.0, 0.0, 0.0)

	# --- STEP 1: PRE-ALLOCATE ARRAYS TO ELIMINATE RE-ALLOCATION LATENCY ---
	var max_points: int = vert_count * vert_count
	var points_2d := PackedVector2Array()
	var points_3d := PackedVector3Array()
	# Parallel to the two above: the paint of every point that survives decimation, so the
	# triangle assembly can hand each vertex its own weights.
	var points_paint := PackedColorArray()

	points_2d.resize(max_points)
	points_3d.resize(max_points)
	points_paint.resize(max_points)

	# Tracker index for direct O(1) array insertions
	var active_count: int = 0

	for z in range(vert_count):
		for x in range(vert_count):
			var is_edge: bool = (x == 0 or x == chunk_size or z == 0 or z == chunk_size)
			var is_corner: bool = (
				(x == 0 or x == chunk_size) and (z == 0 or z == chunk_size)
			)

			var current_h: float = height_data[x + z * vert_count]

			# Cross-examination check for completely flat interior spaces
			var is_flat_center: bool = false
			if not is_edge:
				var h_r: float = height_data[(x+1) + z * vert_count]
				var h_l: float = height_data[(x-1) + z * vert_count]
				var h_d: float = height_data[x + (z+1) * vert_count]
				var h_u: float = height_data[x + (z-1) * vert_count]
				if is_equal_approx(current_h, h_r) and is_equal_approx(current_h, h_l) and \
				is_equal_approx(current_h, h_d) and is_equal_approx(current_h, h_u):
					is_flat_center = true
				if is_flat_center and has_paint:
					is_flat_center = (
						_same_paint(paint_data, vert_count, x, z, x + 1, z)
						and _same_paint(paint_data, vert_count, x, z, x - 1, z)
						and _same_paint(paint_data, vert_count, x, z, x, z + 1)
						and _same_paint(paint_data, vert_count, x, z, x, z - 1)
					)

			# Boundary edge decimation designed to bypass the spiderweb artifact pattern
			var is_flat_edge_point: bool = false
			if is_edge and not is_corner:
				if z == 0 or z == chunk_size:
					var h_left: float = height_data[(x-1) + z * vert_count]
					var h_right: float = height_data[(x+1) + z * vert_count]
					if is_equal_approx(current_h, h_left) and is_equal_approx(current_h, h_right):
						is_flat_edge_point = true
					if is_flat_edge_point and has_paint:
						is_flat_edge_point = (
							_same_paint(paint_data, vert_count, x, z, x - 1, z)
							and _same_paint(paint_data, vert_count, x, z, x + 1, z)
						)
				elif x == 0 or x == chunk_size:
					var h_up: float = height_data[x + (z-1) * vert_count]
					var h_down: float = height_data[x + (z+1) * vert_count]
					if is_equal_approx(current_h, h_up) and is_equal_approx(current_h, h_down):
						is_flat_edge_point = true
					if is_flat_edge_point and has_paint:
						is_flat_edge_point = (
							_same_paint(paint_data, vert_count, x, z, x, z - 1)
							and _same_paint(paint_data, vert_count, x, z, x, z + 1)
						)

			# Radical geometry optimization for planar interior surfaces
			if is_flat_center:
				continue

			if is_flat_edge_point:
				if (x == 0 or x == chunk_size):
					if z % 4 != 0: continue
				else:
					if x % 4 != 0: continue

			# --- ADVANCED SLOPE & EDGE AWARE JITTER DAMPENING ---
			var jitter := Vector3.ZERO
			if not is_edge and jitter_strength > 0.0:
				var h_r: float = height_data[clampi(x + 1, 0, chunk_size) + z * vert_count]
				var h_l: float = height_data[clampi(x - 1, 0, chunk_size) + z * vert_count]
				var h_d: float = height_data[x + clampi(z + 1, 0, chunk_size) * vert_count]
				var h_u: float = height_data[x + clampi(z - 1, 0, chunk_size) * vert_count]

				var diff_x: float = maxf(absf(current_h - h_r), absf(current_h - h_l))
				var diff_z: float = maxf(absf(current_h - h_d), absf(current_h - h_u))
				var max_diff: float = maxf(diff_x, diff_z)

				var true_slope: float = max_diff / cell_size
				var current_threshold: float = jitter_slope_threshold

				if is_zero_approx(current_threshold):
					current_threshold = 0.5

				# Non-linear damping via Cubic Hermite Interpolation (Smoothstep)
				var t: float = clampf(true_slope / current_threshold, 0.0, 1.0)
				var slope_factor: float = t * t * (3.0 - 2.0 * t)

				# Boundary Distance Damping
				var dist_to_edge_x: float = minf(x, chunk_size - x)
				var dist_to_edge_z: float = minf(z, chunk_size - z)
				var edge_damp: float = clampf(
					minf(dist_to_edge_x, dist_to_edge_z) / 2.0, 0.0, 1.0
				)

				# Final jitter computation combining both attenuation factors
				jitter = get_jitter_offset(
					chunk_coord, chunk_size, cell_size, jitter_strength, x, z
				) * slope_factor * edge_damp

			var pos_x: float = x * cell_size + jitter.x
			var pos_z: float = -z * cell_size + jitter.z

			# Direct O(1) assignment into the pre-allocated memory blocks
			points_2d[active_count] = Vector2(pos_x, pos_z)
			points_3d[active_count] = Vector3(pos_x, current_h, pos_z)
			points_paint[active_count] = (
				_paint_color(paint_data, vert_count, x, z, paint_steps) if has_paint else c
			)
			active_count += 1

	# Shrink arrays down to the actual active Delaunay points in a single operation
	points_2d.resize(active_count)
	points_3d.resize(active_count)
	points_paint.resize(active_count)

	# --- STEP 2: GODOT DELAUNAY TRIANGULATION ---
	var triangles: PackedInt32Array = Geometry2D.triangulate_delaunay(points_2d)
	if triangles.size() == 0:
		return null

	# --- STEP 3: ASSEMBLE MESH GEOMETRY ---

	# CRITICAL FOR LOW-POLY: Setting the smooth group to -1 disables vertex normal blending.
	# This forces the SurfaceTool to isolate each triangle's face normal later on,
	# ensuring crisp, distinct, and perfectly flat shading boundaries.
	st.set_smooth_group(-1)

	# Iterate through the Delaunay triangulation index array in steps of 3 (one triangle at a time)
	for i in range(0, triangles.size(), 3):
		# Fetch the original lookup indices generated by the Delaunay algorithm
		var idx0: int = triangles[i]
		var idx1: int = triangles[i+1]
		var idx2: int = triangles[i+2]

		# Retrieve the 2D positions of the vertices to perform winding order checks
		var v0_2d: Vector2 = points_2d[idx0]
		var v1_2d: Vector2 = points_2d[idx1]
		var v2_2d: Vector2 = points_2d[idx2]

		# Calculate 2D direction vectors for two adjacent edges of the triangle
		var edge1: Vector2 = v1_2d - v0_2d
		var edge2: Vector2 = v2_2d - v0_2d

		# Perform a 2D cross-product (determinant) to evaluate the winding direction.
		# A negative result indicates a clockwise winding order, which causes backface culling
		# to hide the triangle since Godot expects a counter-clockwise order by default.
		var cross_2d: float = edge1.x * edge2.y - edge1.y * edge2.x

		# If the triangle is wound clockwise, flip two vertex indices to enforce a
		# counter-clockwise order, making the face point upwards and render correctly.
		if cross_2d < 0.0:
			var temp: int = idx1
			idx1 = idx2
			idx2 = temp

		# Fetch the final 3D world coordinates for the correctly ordered vertices
		var p0: Vector3 = points_3d[idx0]
		var p1: Vector3 = points_3d[idx1]
		var p2: Vector3 = points_3d[idx2]

		# Calculate the total bounding size of the terrain chunk for UV normalization
		var max_size: float = chunk_size * cell_size

		# Map the 3D world positions into a normalized 0.0 to 1.0 UV coordinate range.
		# This prevents shader fallbacks and errors in the Compatibility (OpenGL) renderer.
		var uv0 := Vector2(p0.x / max_size, -p0.z / max_size)
		var uv1 := Vector2(p1.x / max_size, -p1.z / max_size)
		var uv2 := Vector2(p2.x / max_size, -p2.z / max_size)

		# Push Vertex 0 data into the SurfaceTool format stack. The colour is per vertex now:
		# it carries this point's paint weights into the shader.
		st.set_color(points_paint[idx0])
		st.set_uv(uv0)
		st.add_vertex(p0)

		# Push Vertex 1 data into the SurfaceTool format stack
		st.set_color(points_paint[idx1])
		st.set_uv(uv1)
		st.add_vertex(p1)

		# Push Vertex 2 data into the SurfaceTool format stack
		st.set_color(points_paint[idx2])
		st.set_uv(uv2)
		st.add_vertex(p2)

	# Automatically generate face normals. Because smooth group is set to -1,
	# vertices at shared boundaries will not blend, preserving the low-poly appearance.
	st.generate_normals()

	# Generate tangent vectors. This is mandatory for stable lighting calculation
	# and custom shader support within the Compatibility Mode backend.
	st.generate_tangents()

	# Optimize the mesh structure by generating an index buffer and merging vertices
	# that share identical position, normal, UV, and color values. Since group -1
	# splits normals per face, this safely reduces GPU vertex load without breaking flat shading.
	st.index()

	# Commit the built geometric arrays into a rendering-ready Mesh resource
	return st.commit()


## Generates pseudo-random, mathematically reproducible coordinate shifts using sine trigonometry
## hashes. Boundary vertices must never receive this offset, which the caller enforces.
static func get_jitter_offset(
	chunk_coord: Vector2i,
	chunk_size: int,
	cell_size: float,
	jitter_strength: float,
	local_x: int,
	local_z: int
) -> Vector3:
	if is_zero_approx(jitter_strength): return Vector3.ZERO
	var global_gx: int = chunk_coord.x * chunk_size + local_x
	var global_gz: int = chunk_coord.y * chunk_size + local_z
	var hash_x: float = sin(float(global_gx) * 12.9898 + float(global_gz) * 78.233) * 43758.5453
	var hash_z: float = sin(float(global_gx) * 37.719  + float(global_gz) * 11.135) * 43758.5453
	var random_x: float = (hash_x - floorf(hash_x)) * 2.0 - 1.0
	var random_z: float = (hash_z - floorf(hash_z)) * 2.0 - 1.0

	# NOTE: Jitter strength multiplication now executes directly within the base calculator
	return Vector3(
		random_x * cell_size * jitter_strength,
		0.0,
		-random_z * cell_size * jitter_strength
	)


## Vertical offset of the flat preview quad drawn for deactivated chunks. Kept slightly above
## zero so the quad never z-fights with neighbouring terrain resting at height zero.
const PREVIEW_PLANE_Y: float = 0.05


## Builds the flat quad used as the editor preview for a deactivated chunk. The result is
## geometry-identical for every deactivated chunk of a given size, so a single instance of this
## mesh can be shared across all of them.
static func build_deactivated_preview_mesh(chunk_size: int, cell_size: float) -> ArrayMesh:
	var st_box := SurfaceTool.new()
	st_box.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w: float = float(chunk_size) * cell_size
	var p0 := Vector3(0, PREVIEW_PLANE_Y, 0)
	var p1 := Vector3(w, PREVIEW_PLANE_Y, 0)
	var p2 := Vector3(w, PREVIEW_PLANE_Y, -w)
	var p3 := Vector3(0, PREVIEW_PLANE_Y, -w)

	# Wound p0,p2,p1 rather than p0,p1,p2, and carrying an explicit normal.
	#
	# Godot treats CLOCKWISE triangles as front-facing, so an upward-facing quad needs a
	# NEGATIVE y in (b - a).cross(c - a). The obvious vertex order gives a positive one, which
	# points the quad at the ground: it was only visible from underneath. The surface also
	# carried no normals at all, which leaves a lit material with nothing to shade against.
	st_box.set_normal(Vector3.UP)
	st_box.add_vertex(p0)
	st_box.set_normal(Vector3.UP)
	st_box.add_vertex(p2)
	st_box.set_normal(Vector3.UP)
	st_box.add_vertex(p1)

	st_box.set_normal(Vector3.UP)
	st_box.add_vertex(p0)
	st_box.set_normal(Vector3.UP)
	st_box.add_vertex(p3)
	st_box.set_normal(Vector3.UP)
	st_box.add_vertex(p2)
	return st_box.commit()


## Returns a mesh as a flat triangle soup, three vertices per face.
##
## Deliberately NOT ArrayMesh.get_faces(). That call caches its result inside the mesh
## permanently - measured at about 88 KB per chunk, never released - which is what made
## released colliders appear to hold on to most of their memory, and what made the editor
## brush accumulate memory for every chunk the mouse ever crossed.
##
## De-indexing the surface arrays by hand produces the same soup with no permanent cost, and
## measured roughly three times faster. The values differ from get_faces() by around 5e-5,
## because get_faces() reads back the mesh's compressed vertex storage while the surface
## arrays are uncompressed. That is far below anything physically meaningful here.
static func build_face_soup(mesh: ArrayMesh) -> PackedVector3Array:
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedVector3Array()

	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

	# An unindexed surface already IS a triangle soup, and it reports ARRAY_INDEX as null
	# rather than as an empty array. The null has to be caught before the typed assignment, not
	# after it: assigning it raises a runtime error that aborts this function and returns an
	# empty soup, which is what left the brush with no geometry to hit over deactivated chunks.
	# Their preview quad is built without an index buffer.
	var raw_indices: Variant = arrays[Mesh.ARRAY_INDEX]
	if raw_indices == null:
		return verts

	var indices: PackedInt32Array = raw_indices
	if indices.is_empty():
		return verts

	var soup := PackedVector3Array()
	soup.resize(indices.size())
	for i in range(indices.size()):
		soup[i] = verts[indices[i]]
	return soup


## Vertical offset of the chunk boundary grid overlay.
const GRID_PLANE_Y: float = 0.05


## Builds the whole chunk boundary grid as a SINGLE line mesh.
##
## This replaces the former per-chunk Label3D overlay. One mesh and one material cover the
## entire terrain no matter how many chunks it has, whereas the labels cost one node, one mesh
## and one material each. Lines also stay legible at any zoom level, while label text shrank
## exactly when the terrain got large enough to actually need the orientation.
static func build_chunk_grid_mesh(
	world_chunks: Vector2i,
	chunk_size: int,
	cell_size: float
) -> ArrayMesh:
	if world_chunks.x <= 0 or world_chunks.y <= 0 or chunk_size <= 0:
		return null

	var meters: float = float(chunk_size) * cell_size
	if is_zero_approx(meters):
		return null

	var width: float = float(world_chunks.x) * meters
	var depth: float = float(world_chunks.y) * meters

	var verts := PackedVector3Array()
	verts.resize(((world_chunks.x + 1) + (world_chunks.y + 1)) * 2)
	var cursor: int = 0

	# Boundaries running along Z, one per chunk column plus the closing edge.
	for cx in range(world_chunks.x + 1):
		var x: float = float(cx) * meters
		verts[cursor] = Vector3(x, GRID_PLANE_Y, 0.0)
		cursor += 1
		verts[cursor] = Vector3(x, GRID_PLANE_Y, -depth)
		cursor += 1

	# Boundaries running along X, one per chunk row plus the closing edge.
	for cz in range(world_chunks.y + 1):
		var z: float = -float(cz) * meters
		verts[cursor] = Vector3(0.0, GRID_PLANE_Y, z)
		cursor += 1
		verts[cursor] = Vector3(width, GRID_PLANE_Y, z)
		cursor += 1

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Builds the material for the chunk boundary grid. Unshaded and depth-test free, so the grid
## reads through hills instead of disappearing inside them, matching the old label behaviour.
static func build_chunk_grid_material() -> StandardMaterial3D:
	var grid_mat := StandardMaterial3D.new()
	grid_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	grid_mat.albedo_color = Color.YELLOW
	grid_mat.no_depth_test = true
	grid_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return grid_mat


## Builds the semi-transparent red material applied to deactivated chunk previews.
static func build_deactivated_preview_material() -> StandardMaterial3D:
	var red_mat := StandardMaterial3D.new()
	red_mat.albedo_color = Color(1.0, 0.0, 0.0, 0.25)
	red_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	red_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# A marker, not a surface. Lit, its colour would depend on where the scene's sun happens to
	# be, so a chunk could read as deactivated in one scene and barely register in another.
	red_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Same reasoning as the chunk grid: a marker that another terrain can hide is no marker.
	# With several managers in one scene the markers of the lower one disappeared entirely
	# behind the geometry of the upper one. The cost is that the quad also draws in front of
	# terrain standing between it and the camera, which is the price of being unmissable.
	red_mat.no_depth_test = true
	return red_mat
