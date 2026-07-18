@tool
extends MeshInstance3D
class_name LowPolyTerrainChunk

## Runtime rendering child node. Gathers geofenced points, performs dynamic edge decimation,
## injects slope-aware vertex jittering, and triangulates organic low-poly meshes via Delaunay.

var chunk_coord: Vector2i = Vector2i.ZERO
@export var chunk_size: int = 20
@export var cell_size: float = 0.5
@export var step_height: float = 0.1
@export var material_color: Color = Color(0.522, 0.576, 0.478)
var jitter_strength: float = 0.0
var jitter_slope_threshold: float = 0.5

var height_data: Array = []
var custom_material: Material = null

func _ready() -> void:
	if name.contains("@"): return
	if not Engine.is_editor_hint():
		var static_body = find_child("StaticBody3D", false, false) as StaticBody3D
		if static_body:
			if not static_body.is_in_group("Wall"):
				static_body.add_to_group("Wall")
		var label = find_child("ChunkLabel", false, false)
		if label: label.queue_free()

## Called by the manager to safely pass initialized tracking states, configurations, and raw height arrays.
func initialize(coord: Vector2i, c_size: int, cell_s: float, step_h: float, m_color: Color, manager_data: Array, m_jitter: float, show_labels: bool, m_threshold: float, m_material: Material) -> void:
	chunk_coord = coord
	chunk_size = c_size
	cell_size = cell_s
	step_height = step_h
	material_color = m_color
	height_data = manager_data
	jitter_strength = m_jitter
	jitter_slope_threshold = m_threshold
	custom_material = m_material # Wert sichern
	
	var vert_count = chunk_size + 1
	var required_size = vert_count * vert_count
	if height_data.size() != required_size:
		height_data.resize(required_size)
		for i in range(height_data.size()):
			if height_data[i] == null:
				height_data[i] = 0.0
	
	position = Vector3(coord.x * chunk_size * cell_size, 0, -coord.y * chunk_size * cell_size)
	generate_mesh()
	
	if Engine.is_editor_hint():
		if show_labels:
			_update_editor_label()
		else:
			for child in get_children():
				if child is Label3D: child.free()


## Core geometry generation engine. Parses the heightmap grid, runs decimation rules, 
## applies slope-damped random displacements, and builds the visual trimesh.
func generate_mesh() -> void:
	if height_data.size() == 0: return
	var vert_count = chunk_size + 1
	
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c = Color(1.0, 1.0, 1.0)
	
	# --- STEP 1: GATHER ORGANIC COORDINATES (2D & 3D) ---
	var points_2d := PackedVector2Array()
	var points_3d := PackedVector3Array()
	
	for z in range(vert_count):
		for x in range(vert_count):
			var is_edge = (x == 0 or x == chunk_size or z == 0 or z == chunk_size)
			var is_corner = ((x == 0 or x == chunk_size) and (z == 0 or z == chunk_size))
			
			var current_h = height_data[x + z * vert_count]
			
			# Cross-examination check for completely flat interior spaces
			var is_flat_center = false
			if not is_edge:
				var h_r = height_data[(x+1) + z * vert_count]
				var h_l = height_data[(x-1) + z * vert_count]
				var h_d = height_data[x + (z+1) * vert_count]
				var h_u = height_data[x + (z-1) * vert_count]
				if current_h == h_r and current_h == h_l and current_h == h_d and current_h == h_u:
					is_flat_center = true
					
			# Boundary edge decimation designed to bypass the spiderweb artifact pattern
			var is_flat_edge_point = false
			if is_edge and not is_corner:
				if z == 0 or z == chunk_size:
					var h_left = height_data[(x-1) + z * vert_count]
					var h_right = height_data[(x+1) + z * vert_count]
					if current_h == h_left and current_h == h_right:
						is_flat_edge_point = true
				elif x == 0 or x == chunk_size:
					var h_up = height_data[x + (z-1) * vert_count]
					var h_down = height_data[x + (z+1) * vert_count]
					if current_h == h_up and current_h == h_down:
						is_flat_edge_point = true
			
			# Radical geometry optimization for planar interior surfaces
			if is_flat_center:
				continue
				
			if is_flat_edge_point:
				if (x == 0 or x == chunk_size):
					if z % 4 != 0: continue
				else:
					if x % 4 != 0: continue
			
			# --- SLOPE-AWARE JITTER DAMPENING AGAINST VERTEX ARTIFACTS ---
			var jitter = Vector3.ZERO
			if not is_edge and jitter_strength > 0.0:
				# Calculate individual incline levels using adjacent cardinal neighbors
				var h_r = height_data[clampi(x + 1, 0, chunk_size) + z * vert_count]
				var h_l = height_data[clampi(x - 1, 0, chunk_size) + z * vert_count]
				var h_d = height_data[x + clampi(z + 1, 0, chunk_size) * vert_count]
				var h_u = height_data[x + clampi(z - 1, 0, chunk_size) * vert_count]
				
				# FIXED: Measure delta directly from the center point to its neighbors.
				# This ensures mountain peaks and sharp ridges are correctly detected as steep slopes.
				var diff_x = maxf(absf(current_h - h_r), absf(current_h - h_l))
				var diff_z = maxf(absf(current_h - h_d), absf(current_h - h_u))
				var max_diff = maxf(diff_x, diff_z)
				
				# Compute factual geographic terrain slope (independent of axial orientation)
				var true_slope = max_diff / cell_size
				
				# CRASH-PROTECTION: Safe-guard against null or zero configuration parameters
				var current_threshold = jitter_slope_threshold
				if current_threshold == null or is_zero_approx(current_threshold):
					current_threshold = 0.5
				
				# Generate attenuation coefficient: gentle valleys drop noise, sharp cliffs remain jagged
				var slope_factor = clampf(true_slope / current_threshold, 0.0, 1.0)
				
				# Mix deterministic coordinates with calculated attenuation scaling
				jitter = _get_jitter_offset(x, z) * slope_factor

				
			var pos_x = x * cell_size + jitter.x
			var pos_z = -z * cell_size + jitter.z
			
			points_2d.append(Vector2(pos_x, pos_z))
			points_3d.append(Vector3(pos_x, current_h, pos_z))
			
	# --- STEP 2: GODOT DELAUNAY TRIANGULATION ---
	var triangles: PackedInt32Array = Geometry2D.triangulate_delaunay(points_2d)
	if triangles.size() == 0: 
		return
		
	# --- STEP 3: ASSEMBLE MESH GEOMETRY ---
	for i in range(0, triangles.size(), 3):
		var idx0 = triangles[i]
		var idx1 = triangles[i+1]
		var idx2 = triangles[i+2]
		
		var v0_2d = points_2d[idx0]
		var v1_2d = points_2d[idx1]
		var v2_2d = points_2d[idx2]
		
		# Winding Order enforcement to counteract backface culling
		var edge1 = v1_2d - v0_2d
		var edge2 = v2_2d - v0_2d
		var cross_2d = edge1.x * edge2.y - edge1.y * edge2.x
		
		if cross_2d < 0.0:
			var temp = idx1
			idx1 = idx2
			idx2 = temp
		
		var p0 = points_3d[idx0]
		var p1 = points_3d[idx1]
		var p2 = points_3d[idx2]
		
		# Compute standard crisp low-poly flat face normals
		var normal = (p1 - p0).cross(p2 - p0).normalized()
		
		st.set_normal(normal); st.set_color(c); st.add_vertex(p0)
		st.set_normal(normal); st.set_color(c); st.add_vertex(p1)
		st.set_normal(normal); st.set_color(c); st.add_vertex(p2)
		
	mesh = st.commit()
	_apply_custom_shader()

## Generates pseudo-random, mathematically reproducible coordinate shifts using sine trigonometry hashes.
func _get_jitter_offset(local_x: int, local_z: int) -> Vector3:
	if is_zero_approx(jitter_strength): return Vector3.ZERO
	var global_gx = chunk_coord.x * chunk_size + local_x
	var global_gz = chunk_coord.y * chunk_size + local_z
	var hash_x = sin(float(global_gx) * 12.9898 + float(global_gz) * 78.233) * 43758.5453
	var hash_z = sin(float(global_gx) * 37.719  + float(global_gz) * 11.135) * 43758.5453
	var random_x = (hash_x - floorf(hash_x)) * 2.0 - 1.0
	var random_z = (hash_z - floorf(hash_z)) * 2.0 - 1.0
	return Vector3(random_x * cell_size * jitter_strength, 0.0, -random_z * cell_size * jitter_strength)



## Automatically builds and maps a custom ShaderMaterial layout using an injection channel for Perlin noise.
## FIXED: Supports user-defined material overrides with automatic built-in shader fallback.
func _apply_custom_shader() -> void:
	# If the user provided a custom material in the inspector, apply it and exit immediately
	if custom_material != null:
		material_override = custom_material
		return
		
	# Fallback: Build the default low-poly terrain shader
	var generated_material := ShaderMaterial.new()
	var shader_path = "res://addons/lowpolyterrain/shader/terrain_lowpoly.gdshader"
	
	if ResourceLoader.exists(shader_path):
		generated_material.shader = load(shader_path)
	else:
		print("Terrain Error: Custom shader file not found at: %s" % shader_path)
		return
		
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	var noise_texture := NoiseTexture2D.new()
	noise_texture.seamless = true
	noise_texture.noise = noise
	
	generated_material.set_shader_parameter("base_color", material_color)
	generated_material.set_shader_parameter("noise_texture", noise_texture)
	material_override = generated_material



## Refreshes and instantiates persistent runtime node labels mapping structural coordinates within the viewport.
func _update_editor_label() -> void:
	for child in get_children():
		if child is Label3D: child.free()
	var label = Label3D.new()
	label.name = "ChunkLabel"
	add_child(label)
	label.text = "[%d, %d]" % [chunk_coord.x, chunk_coord.y]
	label.pixel_size = 0.015
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color.YELLOW
	var half_bounds = (chunk_size * cell_size) / 2.0
	label.position = Vector3(half_bounds, 2.0, -half_bounds)



## Generates runtime physical collider shape matrices aligned with the generated mesh.
func bake_collision(scene_root: Node) -> void:
	if not mesh: return
	for child in get_children():
		if child is StaticBody3D: child.free()
		
	var static_body = StaticBody3D.new()
	static_body.name = "Static_" + name
	var collision_shape = CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	
	var half_bounds = (chunk_size * cell_size) / 2.0
	var center_offset = Vector3(half_bounds, 0.0, -half_bounds)
	
	var faces_raw: PackedVector3Array = mesh.get_faces()
	for i in range(faces_raw.size()):
		faces_raw[i] -= center_offset
		
	var shifted_shape = ConcavePolygonShape3D.new()
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
