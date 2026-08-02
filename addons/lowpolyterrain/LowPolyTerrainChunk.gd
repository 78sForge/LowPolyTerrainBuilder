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

## Overlay that draws the painted layers on top. Null while nothing is painted.
var paint_overlay: Material = null


func _ready() -> void:
	if name.contains("@"): return
	if not Engine.is_editor_hint():
		var static_body: StaticBody3D = find_child("StaticBody3D", false, false) as StaticBody3D
		if static_body:
			if not static_body.is_in_group("Wall"):
				static_body.add_to_group("Wall")


## Called by the manager to safely pass initialized tracking states, configurations, and raw height arrays.
func initialize(coord: Vector2i, c_size: int, cell_s: float, step_h: float, manager_data: PackedFloat32Array, m_jitter: float, m_threshold: float, m_material: Material, paint_window: PackedByteArray = PackedByteArray(), paint_steps: int = 8, m_paint_overlay: Material = null) -> void:
	chunk_coord = coord
	chunk_size = c_size
	cell_size = cell_s
	step_height = step_h
	jitter_strength = m_jitter
	jitter_slope_threshold = m_threshold
	custom_material = m_material
	paint_overlay = m_paint_overlay
	
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
	generate_mesh(heights, paint_window, paint_steps)


## Core geometry generation engine. Parses the heightmap grid, runs decimation rules, 
## applies slope-damped random displacements, and builds the visual trimesh via Delaunay.
## The height window is a parameter rather than a field: it is dead weight once the mesh
## exists, and storing it per chunk duplicated the manager's whole height matrix.
func generate_mesh(
	heights: PackedFloat32Array,
	paint_window: PackedByteArray = PackedByteArray(),
	paint_steps: int = 8
) -> void:
	if heights.is_empty() or not visible:
		mesh = null
		return

	# Delegates to the shared stateless builder so that the MeshInstance3D backend and the
	# RenderingServer backend always emit bit-identical geometry from identical inputs.
	mesh = LowPolyTerrainMeshBuilder.build_chunk_mesh(
		chunk_coord, chunk_size, cell_size, heights,
		jitter_strength, jitter_slope_threshold,
		paint_window, paint_steps
	)
	
	# Attach your specific rendering logic, material properties, or visual effects
	_apply_custom_shader()


## Generates pseudo-random, mathematically reproducible coordinate shifts using sine trigonometry hashes.
func _get_jitter_offset(local_x: int, local_z: int) -> Vector3:
	return LowPolyTerrainMeshBuilder.get_jitter_offset(
		chunk_coord, chunk_size, cell_size, jitter_strength, local_x, local_z
	)


## Maps materials and generates an ultra-high performance editor wireframe overlay.
func _apply_custom_shader() -> void:
	material_override = custom_material
	# Drawn over the material rather than replacing it, so painting works with any base shader.
	material_overlay = paint_overlay


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
