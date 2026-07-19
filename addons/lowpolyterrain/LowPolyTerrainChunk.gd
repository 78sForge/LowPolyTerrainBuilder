@tool
extends MeshInstance3D
class_name LowPolyTerrainChunk

## Runtime rendering child node. Gathers geofenced points, performs dynamic edge decimation,
## injects slope-aware vertex jittering, and triangulates organic low-poly meshes via Delaunay.

var chunk_coord: Vector2i = Vector2i.ZERO
@export var chunk_size: int = 20
@export var cell_size: float = 0.5
@export var step_height: float = 0.1
var jitter_strength: float = 0.0
var jitter_slope_threshold: float = 0.5

# --- PERFORMANCE CRITICAL: Dense packed float storage array instead of a dynamic list ---
var height_data: PackedFloat32Array = PackedFloat32Array()
var custom_material: Material = null


func _ready() -> void:
	if name.contains("@"): return
	if not Engine.is_editor_hint():
		var static_body: StaticBody3D = find_child("StaticBody3D", false, false) as StaticBody3D
		if static_body:
			if not static_body.is_in_group("Wall"):
				static_body.add_to_group("Wall")
		var label: Node = find_child("ChunkLabel", false, false)
		if label: label.queue_free()


## Called by the manager to safely pass initialized tracking states, configurations, and raw height arrays.
func initialize(coord: Vector2i, c_size: int, cell_s: float, step_h: float, manager_data: PackedFloat32Array, m_jitter: float, show_labels: bool, m_threshold: float, m_material: Material) -> void:
	chunk_coord = coord
	chunk_size = c_size
	cell_size = cell_s
	step_height = step_h
	height_data = manager_data
	jitter_strength = m_jitter
	jitter_slope_threshold = m_threshold
	custom_material = m_material
	
	var vert_count: int = chunk_size + 1
	var required_size: int = vert_count * vert_count
	
	if height_data.size() != required_size:
		height_data.resize(required_size)
		height_data.fill(0.0)
	
	position = Vector3(float(coord.x * chunk_size) * cell_size, 0.0, float(-coord.y * chunk_size) * cell_size)
	generate_mesh()
	
	if Engine.is_editor_hint():
		if show_labels:
			_update_editor_label()
		else:
			for child in get_children():
				if child is Label3D: child.free()


## Core geometry geometry generation engine. Parses the heightmap grid, runs decimation rules, 
## applies slope-damped random displacements, and builds the visual trimesh via Delaunay.
func generate_mesh() -> void:
	if height_data.is_empty(): return
	var vert_count: int = chunk_size + 1
	
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Color(1.0, 1.0, 1.0)
	
	# --- STEP 1: GATHER ORGANIC COORDINATES (2D & 3D) ---
	var points_2d := PackedVector2Array()
	var points_3d := PackedVector3Array()
	
	for z in range(vert_count):
		for x in range(vert_count):
			var is_edge: bool = (x == 0 or x == chunk_size or z == 0 or z == chunk_size)
			var is_corner: bool = ((x == 0 or x == chunk_size) and (z == 0 or z == chunk_size))
			
			var current_h: float = height_data[x + z * vert_count]
			
			# Cross-examination check for completely flat interior spaces
			var is_flat_center: bool = false
			if not is_edge:
				var h_r: float = height_data[(x+1) + z * vert_count]
				var h_l: float = height_data[(x-1) + z * vert_count]
				var h_d: float = height_data[x + (z+1) * vert_count]
				var h_u: float = height_data[x + (z-1) * vert_count]
				if is_equal_approx(current_h, h_r) and is_equal_approx(current_h, h_l) and is_equal_approx(current_h, h_d) and is_equal_approx(current_h, h_u):
					is_flat_center = true
					
			# Boundary edge decimation designed to bypass the spiderweb artifact pattern
			var is_flat_edge_point: bool = false
			if is_edge and not is_corner:
				if z == 0 or z == chunk_size:
					var h_left: float = height_data[(x-1) + z * vert_count]
					var h_right: float = height_data[(x+1) + z * vert_count]
					if is_equal_approx(current_h, h_left) and is_equal_approx(current_h, h_right):
						is_flat_edge_point = true
				elif x == 0 or x == chunk_size:
					var h_up: float = height_data[x + (z-1) * vert_count]
					var h_down: float = height_data[x + (z+1) * vert_count]
					if is_equal_approx(current_h, h_up) and is_equal_approx(current_h, h_down):
						is_flat_edge_point = true
			
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
				# Keeps flat areas completely rigid, eliminates micro-noise, and stabilizes shading.
				var t: float = clampf(true_slope / current_threshold, 0.0, 1.0)
				var slope_factor: float = t * t * (3.0 - 2.0 * t)
				
				# Boundary Distance Damping (Prevents sharp triangle spikes at seams)
				var dist_to_edge_x: float = minf(x, chunk_size - x)
				var dist_to_edge_z: float = minf(z, chunk_size - z)
				# Scales smoothly from 0.0 (edge) to 1.0 (center) over a 2-vertex safety margin
				var edge_damp: float = clampf(minf(dist_to_edge_x, dist_to_edge_z) / 2.0, 0.0, 1.0)
				
				# Final jitter computation combining both attenuation factors
				jitter = _get_jitter_offset(x, z) * slope_factor * edge_damp

			var pos_x: float = x * cell_size + jitter.x
			var pos_z: float = -z * cell_size + jitter.z
			
			points_2d.append(Vector2(pos_x, pos_z))
			points_3d.append(Vector3(pos_x, current_h, pos_z))
			
	# --- STEP 2: GODOT DELAUNAY TRIANGULATION ---
	var triangles: PackedInt32Array = Geometry2D.triangulate_delaunay(points_2d)
	if triangles.size() == 0: 
		return
		
	# --- STEP 3: ASSEMBLE MESH GEOMETRY ---
	for i in range(0, triangles.size(), 3):
		var idx0: int = triangles[i]
		var idx1: int = triangles[i+1]
		var idx2: int = triangles[i+2]
		
		var v0_2d: Vector2 = points_2d[idx0]
		var v1_2d: Vector2 = points_2d[idx1]
		var v2_2d: Vector2 = points_2d[idx2]
		
		var edge1: Vector2 = v1_2d - v0_2d
		var edge2: Vector2 = v2_2d - v0_2d
		var cross_2d: float = edge1.x * edge2.y - edge1.y * edge2.x
		
		if cross_2d < 0.0:
			var temp: int = idx1
			idx1 = idx2
			idx2 = temp
		
		var p0: Vector3 = points_3d[idx0]
		var p1: Vector3 = points_3d[idx1]
		var p2: Vector3 = points_3d[idx2]
		
		var normal: Vector3 = (p1 - p0).cross(p2 - p0).normalized()
		
		st.set_normal(normal); st.set_color(c); st.add_vertex(p0)
		st.set_normal(normal); st.set_color(c); st.add_vertex(p1)
		st.set_normal(normal); st.set_color(c); st.add_vertex(p2)
		
	mesh = st.commit()
	_apply_custom_shader()



## Generates pseudo-random, mathematically reproducible coordinate shifts using sine trigonometry hashes.
func _get_jitter_offset(local_x: int, local_z: int) -> Vector3:
	if is_zero_approx(jitter_strength): return Vector3.ZERO
	var global_gx: int = chunk_coord.x * chunk_size + local_x
	var global_gz: int = chunk_coord.y * chunk_size + local_z
	var hash_x: float = sin(float(global_gx) * 12.9898 + float(global_gz) * 78.233) * 43758.5453
	var hash_z: float = sin(float(global_gx) * 37.719  + float(global_gz) * 11.135) * 43758.5453
	var random_x: float = (hash_x - floorf(hash_x)) * 2.0 - 1.0
	var random_z: float = (hash_z - floorf(hash_z)) * 2.0 - 1.0
	
	# NOTE: Jitter strength multiplication now executes directly within the base calculator
	return Vector3(random_x * cell_size * jitter_strength, 0.0, -random_z * cell_size * jitter_strength)


####################################################################################################
## Maps the user-defined inspector material allocation directly to the mesh instance.
func _apply_custom_shader() -> void:
	material_override = custom_material

	



## Refreshes and instantiates persistent runtime node labels mapping structural coordinates within the viewport.
func _update_editor_label() -> void:
	for child in get_children():
		if child is Label3D: child.free()
		
	var label := Label3D.new()
	label.name = "ChunkLabel"
	add_child(label)
	
	label.text = "[%d, %d]" % [chunk_coord.x, chunk_coord.y]
	label.pixel_size = 0.015
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color.YELLOW
	
	var half_bounds: float = (float(chunk_size) * cell_size) / 2.0
	label.position = Vector3(half_bounds, 2.0, -half_bounds)




## Generates runtime physical collider shape matrices aligned with the generated mesh.
func bake_collision(scene_root: Node) -> void:
	if not mesh: return
	for child in get_children():
		if child is StaticBody3D: child.free()
		
	var static_body := StaticBody3D.new()
	static_body.name = "Static_" + name
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	
	var half_bounds: float = (float(chunk_size) * cell_size) / 2.0
	var center_offset := Vector3(half_bounds, 0.0, -half_bounds)
	
	var faces_raw: PackedVector3Array = mesh.get_faces()
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
