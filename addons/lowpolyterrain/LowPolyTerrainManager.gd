@tool
extends Node3D
class_name LowPolyTerrainManager

## Master controller script that handles seamless height coordinates, multi-chunk modification,
## multi-pass smoothing operations, and automated static collision baking.

## signals
signal signal_brush_settings_changed

# Centralized structural constants for advanced Inspector paths
const GROUP_DIMENSIONS := "World Dimensions (Requires Apply)"
const SUBGROUP_METRICS := "Calculated Metrics (Read-Only)"

const PROP_SIZE_METERS := "total_size_meters"
const PROP_TOTAL_VERTICES := "total_vertices"

# Dynamic concatenation to prevent hardcoded duplicate string literals
const PATH_SIZE_METERS := GROUP_DIMENSIONS + "/" + SUBGROUP_METRICS + "/" + PROP_SIZE_METERS
const PATH_TOTAL_VERTICES := GROUP_DIMENSIONS + "/" + SUBGROUP_METRICS + "/" + PROP_TOTAL_VERTICES

# Supported sculpting and utility brush modes for modifying the grid topology
enum BrushMode {
	RAISE,
	LOWER,
	FLATTEN,
	SMOOTH,
	ACTIVATE_CHUNK,   # Replaces toggle mode to explicitly turn on chunk render and collision logic.
	DEACTIVATE_CHUNK # Replaces toggle mode to explicitly shut down chunk visibility and physics.
}

# Active operational configuration values used internally by the grid generation system
var world_chunks: Vector2i = Vector2i(5, 5)
var chunk_size: int = 10
var cell_size: float = 1.0

## Tracks visibility and collision activation state per chunk.
## Size matches (world_chunks.x * world_chunks.y). 1 = Active, 0 = Inactive.
@export_storage var chunk_activity_data: PackedByteArray = PackedByteArray()


@export_group(GROUP_DIMENSIONS)
## Defines the dimensions of the map grid measured in total chunks (Width, Length).
@export var preview_world_chunks: Vector2i = Vector2i(5, 5):
	set(v): preview_world_chunks = v; _update_read_only_metrics()

## Defines the vertex density per chunk. Higher values create more triangles per chunk
## but reduce performance.
@export var preview_chunk_size: int = 10:
	set(v): preview_chunk_size = v; _update_read_only_metrics()

## The spatial size of a single grid cell in meters. Scales the horizontal expansion
## of the entire terrain.
@export var preview_cell_size: float = 1.0:
	set(v): 
		preview_cell_size = v
		_update_read_only_metrics()
		signal_brush_settings_changed.emit()

## If enabled, renders 3D text overlays inside the editor viewport showing the coordinates
## of each active chunk.
@export var show_chunk_labels: bool = false:
	set(v): show_chunk_labels = v; _queue_setup()
	
## If disabled, completely hides the semi-transparent red preview meshes of deactivated chunks.
@export var show_deactivated_chunks: bool = true:
	set(v): show_deactivated_chunks = v; _queue_setup()

	
# REAL INSPECTOR BUTTONS: Resolved via safe Lambda Callables to prevent early parsing errors
## Click to process and apply changes made to World Chunks, Chunk Size, or Cell Size.
## Warning: Shrinking boundaries will delete out-of-bounds data!
@export_tool_button("Apply Dimension Changes", "Node3D")
var apply_dimensions_button: Callable = func() -> void: _apply_dimension_changes()

## Automatically shifts this manager's global position to align the geometric center of the
## terrain perfectly with the scene origin (0,0,0).
@export_tool_button("Center Global Position", "Marker3D")
var center_global_position_button: Callable = func() -> void: _center_global_position_to_origin()


@export_subgroup(SUBGROUP_METRICS)
## The absolute spatial size of the generated terrain world in meters (Width, Length).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var total_size_meters: Vector2:
	get:
		var x_val: float = float(preview_world_chunks.x * preview_chunk_size) * preview_cell_size
		var z_val: float = float(preview_world_chunks.y * preview_chunk_size) * preview_cell_size
		return Vector2(x_val, z_val)

## The total amount of vertices processed across the entire map.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var total_vertices: int:
	get:
		var per_chunk: int = (preview_chunk_size + 1) * (preview_chunk_size + 1)
		return per_chunk * (preview_world_chunks.x * preview_world_chunks.y)

## Seamlessly offsets this node's global transform to center the active terrain dimensions
## around the scene root origin.
func _center_global_position_to_origin() -> void:
	if not Engine.is_editor_hint(): return
	
	print("Centering Low Poly Terrain Builder globally in the scene...")
	
	# Extract the pre-calculated total metrics size directly from our properties
	var world_width_x: float = total_size_meters.x
	var world_length_z: float = total_size_meters.y
	
	# Apply the exact inverse half-bounds offset to shift the spatial layout perfectly
	# onto the origin matrix
	global_position.x = -world_width_x / 2.0
	global_position.z = world_length_z / 2.0
	
	# Force Godot's transform gizmo to refresh visually inside the 3D viewport canvas
	notify_property_list_changed()


##@@

## Triggers an instant inspector refresh to update calculated read-only size metrics
## in real-time.
func _update_read_only_metrics() -> void:
	if Engine.is_editor_hint():
		notify_property_list_changed()


@export_group("Terrain Properties")
## The exact vertical increment (in meters) applied to vertices when using the Raise, Lower,
## or Flatten brushes.
@export var step_height: float = 0.2:
	set(v): step_height = v; _queue_setup(); signal_brush_settings_changed.emit()

## Controls the intensity of random vertex displacement. Higher values break up the grid
## for a more organic Delaunay look.
@export_range(0.0, 0.5, 0.05) var jitter_strength: float = 0.5:
	set(v): jitter_strength = v; _queue_setup()

## The slope incline threshold. Steep cliffs exceeding this value receive full jitter,
## while gentle slopes and flat planes are dampened to prevent noise.
@export_range(0.05, 2.0, 0.05) var jitter_slope_threshold: float = 1.5:
	set(v): jitter_slope_threshold = v; _queue_setup()


## Automatically falls back to a pre-configured terrain_and_cliff ShaderMaterial if left empty.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,StandardMaterial3D") var custom_material: Material = null:
	set(v):
		custom_material = v
		_queue_setup()



@export_group("Brush Tools")
## Selects the active sculpting tool interaction profile.
@export var tool_mode: BrushMode = BrushMode.RAISE

## The operational radius of the painting brush measured in grid vertices.
@export_range(1, 50, 1) var brush_radius: int = 2:
	set(v):
		brush_radius = v
		signal_brush_settings_changed.emit()

## Controls how fast the terrain elevates, lowers, or smooths per stroke.
@export_range(0.05, 5.0, 0.05) var brush_strength: float = 1.0



@export_group("Terrain Smoothing")
## Blending weight factor used during smoothing operations. Higher values result in more
## aggressive terrain blurring per pass.
@export_range(0.0, 1.0, 0.05) var smooth_factor: float = 0.5
## Determines how many consecutive iterations the global smoothing algorithm executes back-to-back
## when clicked.
@export_range(1, 10, 1) var smooth_iterations: int = 1
## Click to run a global smoothing pass over the entire map. Blurs and softens all terrain hills
## based on the smoothing settings below.
@export_tool_button("Smooth Entire Terrain", "Mesh")
var smooth_terrain_button: Callable = func() -> void: _smooth_entire_terrain()


@export_group("Collision Generation")
## The physics layer bitmask assigned to the generated static colliders. Default is Layer 2.
@export_flags_2d_physics var collision_layer: int = 2

## The scene group name assigned to every generated static collision node. Default is "Wall".
@export var collision_group: String = "Wall"

## Bakes static physical colliders for all visible chunks. Generates a permanent container node
## directly parallel to this manager.
@export_tool_button("Bake Live Collisions", "StaticBody3D")
var bake_collisions_button: Callable = func() -> void: _bake_live_collisions_as_child()


## Helper function to check if a chunk at specific grid coordinates is currently active.
func is_chunk_active(cx: int, cz: int) -> bool:
	if cx < 0 or cx >= world_chunks.x or cz < 0 or cz >= world_chunks.y:
		return false
	var index := cz * world_chunks.x + cx
	if index >= chunk_activity_data.size():
		return true
	return chunk_activity_data[index] == 1

##@@

## Sets activation state of chunks within a world-space radius and requests visual rebuild.
func set_chunk_status_in_radius(center_pos: Vector3, activate: bool) -> void:
	# Convert the vertex-based brush radius into world space meters
	var radius_meters: float = float(brush_radius) * cell_size
	var chunk_meters: float = float(chunk_size) * cell_size
	
	# Transpose Z into positive grid space matching the layout orientation
	var grid_center_z: float = -center_pos.z
	
	# Determine bounds of chunks that could potentially intersect the brush radius
	var min_cx: int = clampi(int((center_pos.x - radius_meters) / chunk_meters), 0, world_chunks.x - 1)
	var max_cx: int = clampi(int((center_pos.x + radius_meters) / chunk_meters), 0, world_chunks.x - 1)
	var min_cz: int = clampi(int((grid_center_z - radius_meters) / chunk_meters), 0, world_chunks.y - 1)
	var max_cz: int = clampi(int((grid_center_z + radius_meters) / chunk_meters), 0, world_chunks.y - 1)
	
	var changed: bool = false
	var target_value: int = 1 if activate else 0
	
	# Check all chunks within bounding box for actual intersection with the brush sphere
	for cz in range(min_cz, max_cz + 1):
		for cx in range(min_cx, max_cx + 1):
			# Calculate boundary limits in positive grid space
			var chunk_min_x: float = float(cx) * chunk_meters
			var chunk_max_x: float = float(cx + 1) * chunk_meters
			var chunk_min_z: float = float(cz) * chunk_meters
			var chunk_max_z: float = float(cz + 1) * chunk_meters
			
			var closest_x: float = clampf(center_pos.x, chunk_min_x, chunk_max_x)
			var closest_z: float = clampf(grid_center_z, chunk_min_z, chunk_max_z)
			
			var dist_x: float = center_pos.x - closest_x
			var dist_z: float = grid_center_z - closest_z
			var dist_sq: float = (dist_x * dist_x) + (dist_z * dist_z)
			
			# If the chunk area is within the brush sphere, update its activity state
			if dist_sq <= (radius_meters * radius_meters):
				var index := cz * world_chunks.x + cx
				if index < chunk_activity_data.size() and chunk_activity_data[index] != target_value:
					chunk_activity_data[index] = target_value
					changed = true
					
	if changed:
		_queue_setup()



# --- PERFORMANCE CRITICAL: Flattened array structure instead of Dictionary ---
@export_storage var global_height_data: PackedFloat32Array = PackedFloat32Array()

# Cached structural bounds variables to achieve zero-latency lookup performance
var _total_vertices_x: int = 0
var _total_vertices_z: int = 0

@export_group("Data Export")
## The target path within your project where the generated terrain mesh will be saved
## as a GLTF file.
@export var export_target_path: String = "res://terrain_export.gltf"

## Click to open a native Editor Save Dialog where you can choose a folder and name
## a new GLTF file.
@export_tool_button("Choose Path & Export Terrain", "Save")
var export_gltf_button: Callable:
	get: return func() -> void: if has_method("_open_export_dialog"): call("_open_export_dialog")


## Spawns an integrated Editor FileDialog configured exclusively for naming new assets.
func _open_export_dialog() -> void:
	if not Engine.is_editor_hint(): return
	
	# Instantiate an native editor-themed dialog window
	var dialog := EditorFileDialog.new()
	
	# Configure the window to allow entering non-existent filenames for saving
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.gltf", "GLTF 3D Asset")
	
	# Pre-fill with the currently set path to save time
	dialog.current_path = export_target_path
	
	# Connect the success signal using the clean Godot 4.7+ Callable approach
	dialog.file_selected.connect(
		func(selected_path: String) -> void:
			export_target_path = selected_path
			_export_terrain_as_gltf()
			dialog.queue_free()
	)
	
	# Automatically clean up RAM if the user cancels or closes the window
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	
	# Inject the window into the active Godot Editor UI tree to display it instantly
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_file_dialog()


# --- Internal Operational Logic & Cool-downs ---
var _setup_pending: bool = false
var chunks_dict: Dictionary = {}
var _paint_cooldown: float = 0.1 
var _last_paint_time: float = 0.0


# --- AUTOMATIC INITIALIZATION PIPELINE ---
func _init() -> void:
	# Enforce the default shader selection the exact millisecond the node is created in the editor
	if custom_material == null and Engine.is_editor_hint():
		_apply_default_shader_fallback()


## Helper function to construct and assign the default terrain shader instance
func _apply_default_shader_fallback() -> void:
	var standardMat := StandardMaterial3D.new()
	custom_material = standardMat


func _ready() -> void:
	# Synchronize active operational variables with serialized preview settings on load to
	# guarantee structural persistence
	world_chunks = preview_world_chunks
	chunk_size = preview_chunk_size
	cell_size = preview_cell_size
	
	# Cache matrix constraints instantly for flat O(1) memory mapping functions
	_recalculate_matrix_bounds()
	
	# Compute the dynamic expected collision container name to match the structural safety rules
	var dynamic_collision_name: String = name + "_Collisions"
	
	# Purge old visual RAM chunk nodes on startup, while protecting transient brush gizmos,
	# collisions, and assets
	for child in get_children():
		if child.name == dynamic_collision_name or child.name == "DEBUG_BrushGizmo_Transient" \
		or child.name == "Terrain_Assets":
			continue
		child.free()
		
	# Automatically spawn the persistent asset container inside the editor tree if it's missing
	if Engine.is_editor_hint() and not has_node("Terrain_Assets"):
		var asset_container := Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		if get_tree() and get_tree().edited_scene_root:
			asset_container.set_owner(get_tree().edited_scene_root)
			
	chunks_dict.clear()
	
	# Allocate structural array data if not populated via storage deserialization pipeline
	if global_height_data.is_empty():
		_initialize_empty_grid()
		
	if chunk_activity_data.is_empty():
		chunk_activity_data.resize(world_chunks.x * world_chunks.y)
		chunk_activity_data.fill(1)
		
	rebuild_chunks_structure()


func _queue_setup() -> void:
	if not Engine.is_editor_hint(): return
	if not _setup_pending:
		_setup_pending = true
		rebuild_chunks_structure.call_deferred()


## Highly optimized O(1) continuous memory data lookup.
func get_height_at(x: int, z: int) -> float:
	if x >= 0 and x < _total_vertices_x and z >= 0 and z < _total_vertices_z:
		return global_height_data[z * _total_vertices_x + x]
	return 0.0

##@@

## Highly optimized O(1) mutation method tailored for zero-latency brush sculpting.
func set_height_at(x: int, z: int, value: float) -> void:
	if x >= 0 and x < _total_vertices_x and z >= 0 and z < _total_vertices_z:
		global_height_data[z * _total_vertices_x + x] = value


## Recomputes structural boundaries matching your modular chunk dimensions.
func _recalculate_matrix_bounds() -> void:
	_total_vertices_x = (world_chunks.x * chunk_size) + 1
	_total_vertices_z = (world_chunks.y * chunk_size) + 1


## Allocates dense matrix allocations directly inside editor RAM to prevent tscn bloat.
func _initialize_empty_grid() -> void:
	_recalculate_matrix_bounds()
	var total_cells: int = _total_vertices_x * _total_vertices_z
	global_height_data.resize(total_cells)
	global_height_data.fill(0.0)
	
	chunk_activity_data.resize(world_chunks.x * world_chunks.y)
	chunk_activity_data.fill(1)


## Safeguards world changes by prompting warning logs and transferring active preview parameters.
func _apply_dimension_changes() -> void:
	# Check if world boundaries are shrinking to print an explicit warning message to the console
	if preview_world_chunks.x < world_chunks.x or preview_world_chunks.y < world_chunks.y:
		print("WARNING: Shrinking world dimensions will permanently delete out-of-bounds terrain data!")
	
	# Trigger high-performance grid data block copy migration pipeline
	_migrate_grid_data()


## Lossless Grid Migration Pipeline: Safely transforms and scales the continuous 
## data memory blocks without dropping height values across modified grid matrices.
func _migrate_grid_data() -> void:
	var old_chunks_x: int = world_chunks.x
	var old_chunks_y: int = world_chunks.y
	var old_activity_data: PackedByteArray = chunk_activity_data.duplicate()
	
	var old_vertices_x: int = _total_vertices_x
	var old_vertices_z: int = _total_vertices_z
	var old_height_data: PackedFloat32Array = global_height_data.duplicate()
	
	# Commit preview values to active configuration
	world_chunks = preview_world_chunks
	chunk_size = preview_chunk_size
	cell_size = preview_cell_size
	
	# Update spatial bounds cache for target sizes
	_recalculate_matrix_bounds()
	var new_total_cells: int = _total_vertices_x * _total_vertices_z
	
	var new_height_data := PackedFloat32Array()
	new_height_data.resize(new_total_cells)
	new_height_data.fill(0.0)
	
	var new_activity_data := PackedByteArray()
	new_activity_data.resize(world_chunks.x * world_chunks.y)
	new_activity_data.fill(1)
	
	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var new_chunk_idx: int = cz * world_chunks.x + cx
			if cx < old_chunks_x and cz < old_chunks_y and not old_activity_data.is_empty():
				var old_chunk_idx: int = cz * old_chunks_x + cx
				new_activity_data[new_chunk_idx] = old_activity_data[old_chunk_idx]
	
	chunk_activity_data = new_activity_data
	
	# Direct coordinate block-copy intersection pipeline
	for z in range(_total_vertices_z):
		for x in range(_total_vertices_x):
			var new_index: int = (z * _total_vertices_x) + x
			
			if x < old_vertices_x and z < old_vertices_z and not old_height_data.is_empty():
				var old_index: int = (z * old_vertices_x) + x
				new_height_data[new_index] = old_height_data[old_index]
			else:
				new_height_data[new_index] = 0.0
				
	global_height_data = new_height_data
	
	rebuild_chunks_structure()
	signal_brush_settings_changed.emit()

##@@

## Cleans, tracks, and instantiates RAM-only chunks, assigning localized sub-arrays 
## extracted from the global packed continuous float matrix layout.
func rebuild_chunks_structure() -> void:
	_setup_pending = false
	
	# Fallback healing to prevent empty memory states
	if global_height_data.is_empty():
		_initialize_empty_grid()
		
	if chunk_activity_data.is_empty():
		chunk_activity_data.resize(world_chunks.x * world_chunks.y)
		chunk_activity_data.fill(1)
		
	_recalculate_matrix_bounds()
	
	# 1. HARD CLEANUP: Remove ANY child chunk that falls outside the active world size boundaries
	var dynamic_collision_name: String = name + "_Collisions"
	chunks_dict.clear()
	
	# Pre-calculate spatial stride to safely reverse-engineer coordinates from world positions
	var meters_per_chunk: float = float(chunk_size) * cell_size
	
	for child in get_children():
		# Protect vital infrastructure containers from being wiped during resize passes
		if child.name == "DEBUG_BrushGizmo_Transient" or child.name == dynamic_collision_name \
		or child.name == "Terrain_Assets":
			continue
			
		if child is LowPolyTerrainChunk and not child.name.contains("@"):
			var coord: Vector2i = child.chunk_coord
			
			# Robust position-based healing fallback for scene loading sequence synchronization
			if coord == Vector2i.ZERO and not is_zero_approx(meters_per_chunk):
				var cx_pos: int = roundi(child.position.x / meters_per_chunk)
				var cz_pos: int = roundi(-child.position.z / meters_per_chunk)
				coord = Vector2i(cx_pos, cz_pos)
				child.chunk_coord = coord
			
			if coord.x >= world_chunks.x or coord.y >= world_chunks.y:
				child.free() 
			else:
				chunks_dict[coord] = child
		else:
			child.free()
			
	# Automated self-healing anchor to guarantee the default asset node always exists
	if not has_node("Terrain_Assets"):
		var asset_container := Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			asset_container.set_owner(get_tree().edited_scene_root)

	# 2. INITIALIZE REFRESHED CHUNK NODES & SYNC LOCAL HEIGHT SUB-ARRAYS
	var expected_total_chunks: int = world_chunks.x * world_chunks.y
	if chunk_activity_data.size() < expected_total_chunks:
		chunk_activity_data.resize(expected_total_chunks)
		chunk_activity_data.fill(1)
	
	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var coord := Vector2i(cx, cz)
			
			if not chunks_dict.has(coord):
				var new_chunk := LowPolyTerrainChunk.new()
				new_chunk.name = "Chunk_%d_%d" % [cx, cz]
				new_chunk.chunk_coord = coord
				add_child(new_chunk)
				chunks_dict[coord] = new_chunk
			
			# Assign the correct spatial 3D position BEFORE evaluating the activity status
			chunks_dict[coord].position = Vector3(
				float(cx * chunk_size) * cell_size,
				0.0,
				float(-cz * chunk_size) * cell_size
			)
			
			# If the chunk is deactivated but show_deactivated_chunks is enabled, 
			# we generate a flat box collision mesh for raycasting directly inside the update engine
			if not is_chunk_active(cx, cz) and bool(show_deactivated_chunks) and Engine.is_editor_hint():
				var st_box := SurfaceTool.new()
				st_box.begin(Mesh.PRIMITIVE_TRIANGLES)
				var w: float = float(chunk_size) * cell_size
				var p0 := Vector3(0, 0.05, 0)
				var p1 := Vector3(w, 0.05, 0)
				var p2 := Vector3(w, 0.05, -w)
				var p3 := Vector3(0, 0.05, -w)
				st_box.add_vertex(p0); st_box.add_vertex(p1); st_box.add_vertex(p2)
				st_box.add_vertex(p0); st_box.add_vertex(p2); st_box.add_vertex(p3)
				chunks_dict[coord].mesh = st_box.commit()
				
				var red_mat := StandardMaterial3D.new()
				red_mat.albedo_color = Color(1.0, 0.0, 0.0, 0.25)
				red_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
				red_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				chunks_dict[coord].material_override = red_mat
			
			# Use the unified clean update method to initialize states fluidly
			_update_single_chunk(coord)



##@@

## Global multi-pass cross-filter operation that processes and blurs the entire grid structure smoothly.
func _smooth_entire_terrain() -> void:
	print("Smoothing global terrain (%d passes, completely fluid)..." % smooth_iterations)
	
	for iteration in range(smooth_iterations):
		# High-performance C++ array duplication for rapid read isolations
		var temporary_data: PackedFloat32Array = global_height_data.duplicate()
		
		for gz in range(_total_vertices_z):
			for gx in range(_total_vertices_x):
				var current_index: int = gz * _total_vertices_x + gx
				var current_height: float = temporary_data[current_index]
				
				# [REFAC] Extracted redundant unrolled neighbor checks into a unified helper method
				var average_height: float = _calculate_average_neighbor_height(gx, gz, temporary_data)
				global_height_data[current_index] = lerpf(current_height, average_height, smooth_factor)


	# Synchronize and push fresh data blocks directly into the active chunks using our dry update loop
	for coord in chunks_dict.keys():
		_update_single_chunk(coord)
		
	notify_property_list_changed()


##@@


## Core brush manipulation engine triggered directly by the editor plugin.
func interact_at_world_position(world_pos: Vector3, is_alternative: bool) -> void:
	var current_time: float = Time.get_ticks_msec() / 1000.0
	if current_time - _last_paint_time < _paint_cooldown: return
	_last_paint_time = current_time

	var local_pos: Vector3 = to_local(world_pos)
	
	# Determine operation mode based on current selection and modifier keys
	var mode: BrushMode = tool_mode
	if is_alternative:
		if tool_mode == BrushMode.RAISE:
			mode = BrushMode.LOWER
		elif tool_mode == BrushMode.LOWER:
			mode = BrushMode.RAISE
		elif tool_mode == BrushMode.ACTIVATE_CHUNK:
			mode = BrushMode.DEACTIVATE_CHUNK
		elif tool_mode == BrushMode.DEACTIVATE_CHUNK:
			mode = BrushMode.ACTIVATE_CHUNK
		else:
			mode = BrushMode.SMOOTH
		
	# --- RADIUS-AWARE CHUNK VISIBILITY & COLLISION MANIPULATION ---
	if mode == BrushMode.ACTIVATE_CHUNK or mode == BrushMode.DEACTIVATE_CHUNK:
		# [FIX] Automatically force previews on so raycasting works flawlessly for activation
		if not show_deactivated_chunks:
			show_deactivated_chunks = true
			
		var is_activation_pass: bool = (mode == BrushMode.ACTIVATE_CHUNK)
		set_chunk_status_in_radius(local_pos, is_activation_pass)
		return
	# --------------------------------------------------------------------


	var global_vertex_x: int = roundi(local_pos.x / cell_size)
	var global_vertex_z: int = roundi(-local_pos.z / cell_size)
	
	var chunks_to_update: Array[LowPolyTerrainChunk] = []
	
	# High-performance C++ array duplication for rapid read isolations during local operations
	var temporary_data: PackedFloat32Array = global_height_data.duplicate()
	
	# Pre-calculate the flatten height value from the initial click center to optimize loop execution
	var target_flatten_h: float = 0.0
	if mode == BrushMode.FLATTEN:
		if global_vertex_x >= 0 and global_vertex_x < _total_vertices_x and \
		global_vertex_z >= 0 and global_vertex_z < _total_vertices_z:
			target_flatten_h = snapped(
				temporary_data[global_vertex_z * _total_vertices_x + global_vertex_x],
				step_height
			)
	
	# Pre-calculate squared radius to avoid expensive sqrt/length calculations inside the loop
	var radius_squared: float = float(brush_radius * brush_radius)
	
	for gz in range(global_vertex_z - brush_radius, global_vertex_z + brush_radius + 1):
		if gz < 0 or gz >= _total_vertices_z: continue
		
		for gx in range(global_vertex_x - brush_radius, global_vertex_x + brush_radius + 1):
			if gx < 0 or gx >= _total_vertices_x: continue
			
			var dx: float = float(gx - global_vertex_x)
			var dz: float = float(gz - global_vertex_z)
			
			if (dx * dx + dz * dz) <= radius_squared:
				var vx_chunk: int = clampi(gx / chunk_size, 0, world_chunks.x - 1)
				var vz_chunk: int = clampi(gz / chunk_size, 0, world_chunks.y - 1)
				
				if not is_chunk_active(vx_chunk, vz_chunk):
					continue
					
				var current_index: int = gz * _total_vertices_x + gx
				var current_h: float = temporary_data[current_index]
				var new_h: float = current_h
				
				# Calculate dynamic increment based on current brush strength
				var current_increment: float = step_height * brush_strength
				
				match mode:
					BrushMode.RAISE:
						new_h += current_increment
					BrushMode.LOWER:
						new_h -= current_increment
					BrushMode.FLATTEN:
						new_h = target_flatten_h
					BrushMode.SMOOTH:
						# [REFAC] Reused centralized neighborhood calculation to maintain DRY principles
						var average_height: float = _calculate_average_neighbor_height(gx, gz, temporary_data)
						var dynamic_smooth: float = clampf(smooth_factor * brush_strength, 0.0, 1.0)
						new_h = lerpf(current_h, average_height, dynamic_smooth)

				# Direct O(1) mutations into global storage (No chunk border splitting required anymore)
				global_height_data[current_index] = new_h
				_add_affected_chunks_to_update(gx, gz, chunks_to_update)

	notify_property_list_changed()
	
	# Push chunk data segments to specific nodes and queue mesh updates via the new shared API
	for chunk in chunks_to_update:
		if not chunk: continue
		_update_single_chunk(chunk.chunk_coord)



##@@

## Checks mathematical boundaries to flag all 1-4 edge chunks touching a modified global vertex coordinate.
func _add_affected_chunks_to_update(gx: int, gz: int, update_list: Array[LowPolyTerrainChunk]) -> void:
	# Calculate coordinates using casting logic
	var cx_r: int = gx / chunk_size
	var cz_b: int = gz / chunk_size
	
	# Boundary clamps to catch out-of-bounds calculations at absolute margins
	var cx_l: int = (gx - 1) / chunk_size if gx > 0 else cx_r
	var cz_t: int = (gz - 1) / chunk_size if gz > 0 else cz_b
	var unique_coords: Array[Vector2i] = []
	
	# Evaluate grid quadrant positions intersecting coordinates
	for z in [cz_t, cz_b]:
		for x in [cx_l, cx_r]:
			var c := Vector2i(x, z)
			if x >= 0 and x < world_chunks.x and z >= 0 and z < world_chunks.y:
				if not c in unique_coords:
					unique_coords.append(c)
					
	for coord in unique_coords:
		if chunks_dict.has(coord):
			var chunk: LowPolyTerrainChunk = chunks_dict[coord]
			if not chunk in update_list:
				update_list.append(chunk)


# Bakes and instantiates persistent physical collider nodes directly under the scene root.
## FIXED: Dynamically applies user-defined collision layers and group configurations.
func _bake_live_collisions_as_child() -> void:
	var target_parent: Node = get_parent()
	var scene_root: Node = null
	
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		scene_root = get_tree().edited_scene_root
	else:
		scene_root = target_parent
		
	if target_parent == null:
		print("Baking cancelled: Manager has no parent to place siblings.")
		return
		
	var dynamic_collision_name: String = name + "_Collisions"
	print("Baking static collisions live parallel to manager as: %s" % dynamic_collision_name)
	
	var old_container: Node = target_parent.find_child(dynamic_collision_name, false, false)
	if old_container:
		old_container.free()
		print("Successfully cleared historical collision nodes from parent.")
		
	var collision_root := Node3D.new()
	collision_root.name = dynamic_collision_name
	target_parent.add_child(collision_root)
	
	if Engine.is_editor_hint() and scene_root:
		collision_root.set_owner(scene_root)
	
	for chunk in chunks_dict.values():
		if not is_chunk_active(chunk.chunk_coord.x, chunk.chunk_coord.y):
			continue
			
		if chunk and chunk.mesh:
			chunk.bake_collision(null)
			
			var static_body: StaticBody3D = chunk.find_child(
				"Static_" + chunk.name, false, false
			) as StaticBody3D
			if static_body:
				chunk.remove_child(static_body)
				collision_root.add_child(static_body)
				
				var half_bounds: float = (chunk.chunk_size * chunk.cell_size) / 2.0
				var center_offset := Vector3(half_bounds, 0.0, -half_bounds)
				static_body.global_position = chunk.global_position + center_offset
				
				for grp in static_body.get_groups():
					static_body.remove_from_group(grp)
					
				static_body.collision_layer = collision_layer
				static_body.collision_mask = 0 
				
				if not collision_group.strip_edges().is_empty():
					static_body.add_to_group(collision_group, true)
				
				if Engine.is_editor_hint() and scene_root:
					static_body.set_owner(scene_root)
					for shape_child in static_body.get_children():
						shape_child.set_owner(scene_root)
						
	print("Collisions successfully generated live and anchored parallel to manager!")


## Bundles all active visual chunk meshes into a dynamic node tree and exports them as a clean GLTF asset.
func _export_terrain_as_gltf() -> void:
	if export_target_path.strip_edges().is_empty():
		print("Export Cancelled: Please specify a valid target path in the inspector.")
		return
		
	print("Starting GLTF terrain export to: %s" % export_target_path)
	
	# 1. Create a transient root node to act as the staging anchor for our chunks
	var export_root := Node3D.new()
	export_root.name = "Exported_LowPoly_Terrain"
	
	var chunks_exported: int = 0
	
	# 2. Iterate through all active chunks and duplicate their meshes with physical transforms
	for coord in chunks_dict.keys():
		if not is_chunk_active(coord.x, coord.y):
			continue
			
		var chunk: LowPolyTerrainChunk = chunks_dict[coord]
		if chunk == null or chunk.mesh == null: 
			continue
			
		# Create a fresh standard MeshInstance3D to strip out plugin behaviors from the asset
		var chunk_instance := MeshInstance3D.new()
		chunk_instance.name = "Terrain_Chunk_%d_%d" % [coord.x, coord.y]
		chunk_instance.mesh = chunk.mesh
		
		# Assign the custom material if available so the look is preserved in the file
		if chunk.material_override != null:
			chunk_instance.material_override = chunk.material_override
			
		# Mirror the precise spatial position of the chunk relative to the manager
		chunk_instance.position = chunk.position
		
		# Add to our staging hierarchy
		export_root.add_child(chunk_instance)
		chunk_instance.set_owner(export_root)
		chunks_exported += 1
		
	if chunks_exported == 0:
		print("Export Cancelled: No active chunk meshes found to package.")
		export_root.free()
		return
		
	# 3. Initialize Godot's native GLTF document processing architecture
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	
	# Bake our staging tree into the GLTF state buffer
	gltf_doc.append_from_scene(export_root, gltf_state)
	
	# Save the baked state straight to disk at the specified location
	var error_code: Error = gltf_doc.write_to_filesystem(gltf_state, export_target_path)
	
	# 4. Clean up our memory footprint and evaluate final success state
	export_root.free()
	
	if error_code == OK:
		print("SUCCESS: Successfully exported %d terrain chunks to GLTF format!" % chunks_exported)
		# Force Godot's FileSystem dock to refresh so the new asset shows up immediately
		if Engine.is_editor_hint():
			var editor_interface := EditorInterface.get_resource_filesystem()
			if editor_interface:
				editor_interface.scan()
	else:
		print("ERROR: GLTF export failed with engine error code: %d" % error_code)



## Synchronizes a single chunk's visibility, height data segments, and mesh generation.
func _update_single_chunk(coord: Vector2i) -> void:
	if not chunks_dict.has(coord): return
	var chunk: LowPolyTerrainChunk = chunks_dict[coord]
	if not chunk: return
	
	# Process the visibility state of deactivated chunks based on inspector preview rules
	if not is_chunk_active(coord.x, coord.y):
		chunk.visible = bool(show_deactivated_chunks) if show_deactivated_chunks != null else true
		if chunk.visible:
			# Forward the label visibility toggle state so deactivated previews can render them
			if chunk.has_method("update_label_visibility"):
				chunk.update_label_visibility(show_chunk_labels)
		return
		
	chunk.visible = true
	var vert_stride: int = chunk_size + 1
	var chunk_local_heights := PackedFloat32Array()
	chunk_local_heights.resize(vert_stride * vert_stride)
	
	# Extract a localized sub-array subset out of the global continuous layout array memory
	for lz in range(vert_stride):
		var global_z: int = (coord.y * chunk_size) + lz
		var local_offset: int = lz * vert_stride
		var global_offset: int = global_z * _total_vertices_x + (coord.x * chunk_size)
		
		var slice: PackedFloat32Array = global_height_data.slice(
			global_offset, global_offset + vert_stride
		)
		for i in range(slice.size()):
			chunk_local_heights[local_offset + i] = slice[i]
			
	# Fully re-triangulate and build the visual low-poly terrain mesh geometry
	chunk.initialize(
		coord, chunk_size, cell_size, step_height,
		chunk_local_heights, jitter_strength, show_chunk_labels,
		jitter_slope_threshold, custom_material
	)



## Calculates the average height of valid cross-neighbors for a given vertex coordinate.
func _calculate_average_neighbor_height(gx: int, gz: int, data: PackedFloat32Array) -> float:
	var sum_heights: float = 0.0
	var valid_neighbors: int = 0
	
	if gx + 1 < _total_vertices_x:
		sum_heights += data[gz * _total_vertices_x + (gx + 1)]
		valid_neighbors += 1
	if gx - 1 >= 0:
		sum_heights += data[gz * _total_vertices_x + (gx - 1)]
		valid_neighbors += 1
	if gz + 1 < _total_vertices_z:
		sum_heights += data[(gz + 1) * _total_vertices_x + gx]
		valid_neighbors += 1
	if gz - 1 >= 0:
		sum_heights += data[(gz - 1) * _total_vertices_x + gx]
		valid_neighbors += 1
		
	return sum_heights / float(valid_neighbors) if valid_neighbors > 0 else data[gz * _total_vertices_x + gx]
