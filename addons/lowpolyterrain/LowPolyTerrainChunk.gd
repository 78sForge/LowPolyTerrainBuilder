@tool
extends MeshInstance3D
class_name LowPolyTerrainChunk

## Runtime rendering child node. Gathers geofenced points, performs dynamic edge decimation,
## injects slope-aware vertex jittering, and triangulates organic low-poly meshes via Delaunay.

@export_storage var chunk_coord: Vector2i = Vector2i.ZERO
@export var chunk_size: int = 20
@export var cell_size: float = 0.5
@export var step_height: float = 0.1
var jitter_strength: float = 0.0
var jitter_slope_threshold: float = 0.5

# NOTE: The height window is NOT stored on the chunk. It is only needed while the mesh is
# being built, and keeping a copy per chunk duplicated the manager's entire height matrix
# (measured at 111% of it, since neighbouring chunks each store the shared border row).
# It is therefore passed straight through to the builder instead.
var custom_material: Material = null


func _ready() -> void:
	if name.contains("@"): return
	if not Engine.is_editor_hint():
		var static_body: StaticBody3D = find_child("StaticBody3D", false, false) as StaticBody3D
		if static_body:
			if not static_body.is_in_group("Wall"):
				static_body.add_to_group("Wall")


## Called by the manager to safely pass initialized tracking states, configurations, and raw height arrays.
func initialize(coord: Vector2i, c_size: int, cell_s: float, step_h: float, manager_data: PackedFloat32Array, m_jitter: float, m_threshold: float, m_material: Material) -> void:
	chunk_coord = coord
	chunk_size = c_size
	cell_size = cell_s
	step_height = step_h
	jitter_strength = m_jitter
	jitter_slope_threshold = m_threshold
	custom_material = m_material
	
	# [FIX] Ensure the visibility state from the manager is respected on scene load
	if not visible:
		if Engine.is_editor_hint():
			# If we are in editor, force visibility back to true so the placeholder mesh can be clicked
			visible = true
		else:
			mesh = null
			return

	var vert_count: int = chunk_size + 1
	var required_size: int = vert_count * vert_count

	# Self-healing against a mismatched window; the local copy is discarded again once the
	# mesh has been generated.
	var heights: PackedFloat32Array = manager_data
	if heights.size() != required_size:
		heights.resize(required_size)
		heights.fill(0.0)

	position = Vector3(
		float(coord.x * chunk_size) * cell_size,
		0.0,
		float(-coord.y * chunk_size) * cell_size
	)
	generate_mesh(heights)


##@@

## Core geometry generation engine. Parses the heightmap grid, runs decimation rules, 
## applies slope-damped random displacements, and builds the visual trimesh via Delaunay.
## The height window is a parameter rather than a field: it is dead weight once the mesh
## exists, and storing it per chunk duplicated the manager's whole height matrix.
func generate_mesh(heights: PackedFloat32Array) -> void:
	if heights.is_empty() or not visible:
		mesh = null
		return

	# Delegates to the shared stateless builder so that the MeshInstance3D backend and the
	# RenderingServer backend always emit bit-identical geometry from identical inputs.
	mesh = LowPolyTerrainMeshBuilder.build_chunk_mesh(
		chunk_coord, chunk_size, cell_size, heights,
		jitter_strength, jitter_slope_threshold
	)
	
	# Attach your specific rendering logic, material properties, or visual effects
	_apply_custom_shader()





## Core geometry generation engine. Parses the heightmap grid, runs decimation rules, 
## applies slope-damped random displacements, and builds the visual trimesh via fixed grid indexing.
## Currently not used !!!
func generate_mesh_non_delaunay(heights: PackedFloat32Array) -> void:
	if heights.is_empty() or not visible:
		mesh = null
		return
	var vert_count: int = chunk_size + 1
	
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Color(1.0, 1.0, 1.0)
	
	# --- STEP 1: CALCULATE AND DISPLACE VERTEX MATRIX ---
	var vertices := PackedVector3Array()
	vertices.resize(vert_count * vert_count)
	
	for z in range(vert_count):
		for x in range(vert_count):
			var is_edge: bool = (x == 0 or x == chunk_size or z == 0 or z == chunk_size)
			var is_corner: bool = ((x == 0 or x == chunk_size) and (z == 0 or z == chunk_size))
			
			var current_h: float = heights[x + z * vert_count]
			
			# Cross-examination check for completely flat interior spaces
			var is_flat_center: bool = false
			if not is_edge:
				var h_r: float = heights[(x+1) + z * vert_count]
				var h_l: float = heights[(x-1) + z * vert_count]
				var h_d: float = heights[x + (z+1) * vert_count]
				var h_u: float = heights[x + (z-1) * vert_count]
				if is_equal_approx(current_h, h_r) and is_equal_approx(current_h, h_l) and \
				is_equal_approx(current_h, h_d) and is_equal_approx(current_h, h_u):
					is_flat_center = true
					
			# Boundary edge decimation designed to bypass the spiderweb artifact pattern
			var is_flat_edge_point: bool = false
			if is_edge and not is_corner:
				if z == 0 or z == chunk_size:
					var h_left: float = heights[(x-1) + z * vert_count]
					var h_right: float = heights[(x+1) + z * vert_count]
					if is_equal_approx(current_h, h_left) and is_equal_approx(current_h, h_right):
						is_flat_edge_point = true
				elif x == 0 or x == chunk_size:
					var h_up: float = heights[x + (z-1) * vert_count]
					var h_down: float = heights[x + (z+1) * vert_count]
					if is_equal_approx(current_h, h_up) and is_equal_approx(current_h, h_down):
						is_flat_edge_point = true
			
			# Radical geometry optimization for planar interior surfaces
			if is_flat_center:
				# Store a placeholder vertex; it will be bypassed during face building
				vertices[x + z * vert_count] = Vector3(x * cell_size, current_h, -z * cell_size)
				continue
				
			if is_flat_edge_point:
				if (x == 0 or x == chunk_size):
					if z % 4 != 0: 
						vertices[x + z * vert_count] = Vector3(x * cell_size, current_h, -z * cell_size)
						continue
				else:
					if x % 4 != 0: 
						vertices[x + z * vert_count] = Vector3(x * cell_size, current_h, -z * cell_size)
						continue
			
			# --- ADVANCED SLOPE & EDGE AWARE JITTER DAMPENING ---
			var jitter := Vector3.ZERO
			if not is_edge and jitter_strength > 0.0:
				var h_r: float = heights[clampi(x + 1, 0, chunk_size) + z * vert_count]
				var h_l: float = heights[clampi(x - 1, 0, chunk_size) + z * vert_count]
				var h_d: float = heights[x + clampi(z + 1, 0, chunk_size) * vert_count]
				var h_u: float = heights[x + clampi(z - 1, 0, chunk_size) * vert_count]
				
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
				var edge_damp: float = clampf(minf(dist_to_edge_x, dist_to_edge_z) / 2.0, 0.0, 1.0)
				
				# Final jitter computation
				jitter = _get_jitter_offset(x, z) * slope_factor * edge_damp

			var pos_x: float = x * cell_size + jitter.x
			var pos_z: float = -z * cell_size + jitter.z
			
			vertices[x + z * vert_count] = Vector3(pos_x, current_h, pos_z)
	
	# --- STEP 2: HIGH-PERFORMANCE FIXED GRID FACE ASSEMBLING ---
	# Loop through each quad cell and assemble the two triangles cleanly
	for z in range(chunk_size):
		for x in range(chunk_size):
			# Calculate 1D indices for the 4 corners of the quad cell
			var idx_tl: int = x + z * vert_count
			var idx_tr: int = (x + 1) + z * vert_count
			var idx_bl: int = x + (z + 1) * vert_count
			var idx_br: int = (x + 1) + (z + 1) * vert_count
			
			var p_tl: Vector3 = vertices[idx_tl]
			var p_tr: Vector3 = vertices[idx_tr]
			var p_bl: Vector3 = vertices[idx_bl]
			var p_br: Vector3 = vertices[idx_br]
			
			# Triangle 1 (Top-Left, Bottom-Left, Top-Right)
			var n1: Vector3 = (p_bl - p_tl).cross(p_tr - p_tl).normalized()
			st.set_normal(n1)
			st.set_color(c)
			st.add_vertex(p_tl)
			st.set_normal(n1)
			st.set_color(c)
			st.add_vertex(p_bl)
			st.set_normal(n1)
			st.set_color(c)
			st.add_vertex(p_tr)
			
			# Triangle 2 (Top-Right, Bottom-Left, Bottom-Right)
			var n2: Vector3 = (p_br - p_tr).cross(p_bl - p_tr).normalized()
			st.set_normal(n2)
			st.set_color(c)
			st.add_vertex(p_tr)
			st.set_normal(n2)
			st.set_color(c)
			st.add_vertex(p_bl)
			st.set_normal(n2)
			st.set_color(c)
			st.add_vertex(p_br)
			
	mesh = st.commit()
	_apply_custom_shader()


## Generates pseudo-random, mathematically reproducible coordinate shifts using sine trigonometry hashes.
func _get_jitter_offset(local_x: int, local_z: int) -> Vector3:
	return LowPolyTerrainMeshBuilder.get_jitter_offset(
		chunk_coord, chunk_size, cell_size, jitter_strength, local_x, local_z
	)


##@@

## Maps materials and generates an ultra-high performance editor wireframe overlay.
func _apply_custom_shader() -> void:
	material_override = custom_material



## Generates runtime physical collider shape matrices aligned with the generated mesh.
func bake_collision(scene_root: Node) -> void:
	if not mesh or not visible:
		for child in get_children():
			if child is StaticBody3D: child.free()
		return
		
	for child in get_children():
		if child is StaticBody3D: child.free()
		
	var static_body := StaticBody3D.new()
	static_body.name = "Static_" + name
	var collision_shape := CollisionShape3D.new()
	# Carries the chunk coordinate, so a collider can be traced back to its chunk directly
	# from the scene tree or via find_child("Chunk_3_5_Col", true).
	collision_shape.name = "Chunk_%d_%d_Col" % [chunk_coord.x, chunk_coord.y]
	
	var half_bounds: float = (float(chunk_size) * cell_size) / 2.0
	var center_offset := Vector3(half_bounds, 0.0, -half_bounds)
	
	# See LowPolyTerrainMeshBuilder.build_face_soup(): get_faces() would cache the soup in
	# the mesh permanently, which baking has no reason to pay for.
	var faces_raw: PackedVector3Array = LowPolyTerrainMeshBuilder.build_face_soup(
		mesh as ArrayMesh)
	for i in range(faces_raw.size()):
		faces_raw[i] -= center_offset
		
	var shifted_shape := ConcavePolygonShape3D.new()
	shifted_shape.set_faces(faces_raw)
	collision_shape.shape = shifted_shape
	
	static_body.position = center_offset
	collision_shape.position = Vector3.ZERO 
	
	# NOTE: Layer, Mask and Groups are now dynamically assigned by the manager 
	# inside the central baking engine loop to allow flexible inspector settings.
	static_body.add_child(collision_shape)
	add_child(static_body)
	
	if scene_root:
		static_body.set_owner(scene_root)
		collision_shape.set_owner(scene_root)
