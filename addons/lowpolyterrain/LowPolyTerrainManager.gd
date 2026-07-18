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



# Active operational configuration values used internally by the grid generation system
var world_chunks: Vector2i = Vector2i(5, 5)
var chunk_size: int = 10
var cell_size: float = 1.0

@export_group(GROUP_DIMENSIONS)
## Defines the dimensions of the map grid measured in total chunks (Width, Length).
@export var preview_world_chunks: Vector2i = Vector2i(5, 5):
	set(v): preview_world_chunks = v; _update_read_only_metrics()

## Defines the vertex density per chunk. Higher values create more triangles per chunk but reduce performance.
@export var preview_chunk_size: int = 10:
	set(v): preview_chunk_size = v; _update_read_only_metrics()

## The spatial size of a single grid cell in meters. Scales the horizontal expansion of the entire terrain.
@export var preview_cell_size: float = 1.0:
	set(v): 
		preview_cell_size = v
		_update_read_only_metrics()
		signal_brush_settings_changed.emit()

## If enabled, renders 3D text overlays inside the editor viewport showing the coordinates of each active chunk.
@export var show_chunk_labels: bool = false:
	set(v): show_chunk_labels = v; _queue_setup()
	
@export_subgroup(SUBGROUP_METRICS)
## The absolute spatial size of the generated terrain world in meters (Width, Length). Formulated as: preview_world_chunks * preview_chunk_size * preview_cell_size.
@export var total_size_meters: Vector2:
	get: return Vector2(float(preview_world_chunks.x * preview_chunk_size) * preview_cell_size, float(preview_world_chunks.y * preview_chunk_size) * preview_cell_size)

## The total amount of vertices processed across the entire map. Formulated as: (preview_chunk_size + 1)^2 * total_chunks.
@export var total_vertices: int:
	get: return (preview_chunk_size + 1) * (preview_chunk_size + 1) * (preview_world_chunks.x * preview_world_chunks.y)


# REAL INSPECTOR BUTTONS: Resolved via safe Lambda Callables to prevent early parsing errors
## Click to process and apply changes made to World Chunks, Chunk Size, or Cell Size. Warning: Shrinking boundaries will delete out-of-bounds data!
@export_tool_button("Apply Dimension Changes", "Node3D")
var apply_dimensions_button: Callable = func(): _apply_dimension_changes()

## Automatically shifts this manager's global position to align the geometric center of the terrain perfectly with the scene origin (0,0,0).
@export_tool_button("Center Global Position", "Marker3D")
var center_global_position_button: Callable = func() -> void: _center_global_position_to_origin()

## Seamlessly offsets this node's global transform to center the active terrain dimensions around the scene root origin.
func _center_global_position_to_origin() -> void:
	if not Engine.is_editor_hint(): return
	
	print("Centering Low Poly Terrain Builder globally in the scene...")
	
	# Extract the pre-calculated total metrics size directly from our properties
	var world_width_x: float = total_size_meters.x
	var world_length_z: float = total_size_meters.y
	
	# Apply the exact inverse half-bounds offset to shift the spatial layout perfectly onto the origin matrix
	global_position.x = -world_width_x / 2.0
	global_position.z = world_length_z / 2.0
	
	# Force Godot's transform gizmo to refresh visually inside the 3D viewport canvas
	notify_property_list_changed()


## Triggers an instant inspector refresh to update calculated read-only size metrics in real-time.
func _update_read_only_metrics() -> void:
	if Engine.is_editor_hint():
		notify_property_list_changed()




@export_group("Terrain Properties")
## The exact vertical increment (in meters) applied to vertices when using the Raise, Lower, or Flatten brushes.
@export var step_height: float = 0.2:
	set(v): step_height = v; _queue_setup(); signal_brush_settings_changed.emit()

## Controls the intensity of random vertex displacement. Higher values break up the grid for a more organic Delaunay look.
@export_range(0.0, 0.5, 0.05) var jitter_strength: float = 0.5:
	set(v): jitter_strength = v; _queue_setup()

## The slope incline threshold. Steep cliffs exceeding this value receive full jitter, while gentle slopes and flat planes are dampened to prevent noise.
@export_range(0.05, 2.0, 0.05) var jitter_slope_threshold: float = 1.5:
	set(v): jitter_slope_threshold = v; _queue_setup()

## The base albedo color passed directly into the custom low-poly terrain shader.
@export var material_color: Color = Color(0.522, 0.576, 0.478):
	set(v): material_color = v; _queue_setup()

## Optional custom 3D material to override the terrain shader. Accepts ShaderMaterial or StandardMaterial3D.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial,StandardMaterial3D") var custom_material: Material = null:
	set(v): custom_material = v; _queue_setup()



## Defines the available sculpting tool profiles for terrain interaction.
enum BrushMode {
	RAISE = 0,   ## Elevates vertices by the step_height
	LOWER = 1,   ## Lowers vertices by the step_height
	FLATTEN = 2, ## Snaps vertices to the initial click elevation
	SMOOTH = 3   ## Blurs and softens adjacent vertex elevations
}

@export_group("Brush Tools")
## Selects the active sculpting tool interaction profile: Raise, Lower, Flatten, or Smooth.
@export var tool_mode: BrushMode = BrushMode.RAISE

## The operational radius of the painting brush measured in grid vertices.
@export_range(1, 10, 1) var brush_radius: int = 2:
	set(v):
		brush_radius = v
		signal_brush_settings_changed.emit()


@export_group("Terrain Smoothing")
## Blending weight factor used during smoothing operations. Higher values result in more aggressive terrain blurring per pass.
@export_range(0.0, 1.0, 0.05) var smooth_factor: float = 0.5
## Determines how many consecutive iterations the global smoothing algorithm executes back-to-back when clicked.
@export_range(1, 10, 1) var smooth_iterations: int = 1
## Click to run a global smoothing pass over the entire map. Blurs and softens all terrain hills based on the smoothing settings below.
@export_tool_button("Smooth Entire Terrain", "Mesh")
var smooth_terrain_button: Callable = func(): _smooth_entire_terrain()



@export_group("Collision Generation")
## The physics layer bitmask assigned to the generated static colliders. Default is Layer 2.
@export_flags_2d_physics var collision_layer: int = 2

## The scene group name assigned to every generated static collision node. Default is "Wall".
@export var collision_group: String = "Wall"

## Bakes static physical colliders for all visible chunks. Generates a permanent container node directly parallel to this manager.
@export_tool_button("Bake Live Collisions", "StaticBody3D")
var bake_collisions_button: Callable = func(): _bake_live_collisions_as_child()





# The master serializable data. Keys: Vector2i (coordinates), Values: Array[float] (vertex heights)
# Removed @export to hide it from users, but kept it inside Godot's serialization pipeline
var global_height_data: Dictionary = {} 

# Tells Godot to serialize the property into the scene file without showing it in the Inspector
# Tells Godot which hidden or custom properties to show or store inside the active inspector layout
# FIXED: Prefixed the property names with the exact subgroup paths to force correct inspector placement
func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	
	# Keep your vital height data safely serialized on disk
	properties.append({
		"name": "global_height_data",
		"type": TYPE_DICTIONARY,
		"usage": PROPERTY_USAGE_STORAGE
	})
	
	# Register the calculated metrics with full path names to slide them under the correct subgroup layout
	properties.append({
		"name": PATH_SIZE_METERS,
		"type": TYPE_VECTOR2,
		"usage": PROPERTY_USAGE_EDITOR
	})
	properties.append({
		"name": PATH_TOTAL_VERTICES,
		"type": TYPE_INT,
		"usage": PROPERTY_USAGE_EDITOR
	})
	
	return properties

# Automatically intercepts properties before rendering to enforce a true grayed-out read-only state
func _validate_property(property: Dictionary) -> void:
	if PROP_SIZE_METERS in property.name or PROP_TOTAL_VERTICES in property.name:
		property.usage |= PROPERTY_USAGE_READ_ONLY

# Resolves inspector read requests for custom dynamically paths properties
func _get(property: StringName) -> Variant:
	if property == PATH_SIZE_METERS:
		return Vector2(float(preview_world_chunks.x * preview_chunk_size) * preview_cell_size, float(preview_world_chunks.y * preview_chunk_size) * preview_cell_size)
	elif property == PATH_TOTAL_VERTICES:
		return (preview_chunk_size + 1) * (preview_chunk_size + 1) * (preview_world_chunks.x * preview_world_chunks.y)
	return null

# Intercepts write attempts to ensure custom properties remain strictly read-only
func _set(property: StringName, value: Variant) -> bool:
	if PROP_SIZE_METERS in property or PROP_TOTAL_VERTICES in property:
		return true # Action handled, value discarded to enforce read-only constraint
	return false




var _setup_pending: bool = false
var chunks_dict: Dictionary = {}
var _paint_cooldown: float = 0.1 
var _last_paint_time: float = 0.0


	
func _ready() -> void:
	# Synchronize active operational variables with serialized preview settings on load to guarantee structural persistence
	world_chunks = preview_world_chunks
	chunk_size = preview_chunk_size
	cell_size = preview_cell_size
	
	# Compute the dynamic expected collision container name to match the structural safety rules
	var dynamic_collision_name: String = name + "_Collisions"
	
	# Purge old visual RAM chunk nodes on startup, while protecting transient brush gizmos, collisions, and assets
	for child in get_children():
		if child.name == dynamic_collision_name or child.name == "DEBUG_BrushGizmo_Transient" or child.name == "Terrain_Assets":
			continue
		child.free()
		
	# NEW: Automatically spawn the persistent asset container inside the editor tree if it's missing
	if Engine.is_editor_hint() and not has_node("Terrain_Assets"):
		var asset_container = Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		if get_tree() and get_tree().edited_scene_root:
			asset_container.set_owner(get_tree().edited_scene_root)
			
	chunks_dict.clear()
	rebuild_chunks_structure()



	

func _queue_setup() -> void:
	if not Engine.is_editor_hint(): return
	if not _setup_pending:
		_setup_pending = true
		rebuild_chunks_structure.call_deferred()

	
## Safeguards world changes by prompting warning logs and transferring active preview parameters.
func _apply_dimension_changes() -> void:
	# Check if world boundaries are shrinking to print an explicit warning message to the console
	if preview_world_chunks.x < world_chunks.x or preview_world_chunks.y < world_chunks.y:
		print("WARNING: Shrinking world dimensions will permanently delete out-of-bounds terrain data!")
	
	# Commit preview values to active configuration
	world_chunks = preview_world_chunks
	chunk_size = preview_chunk_size
	cell_size = preview_cell_size
	
	# Trigger the full rebuild pipeline
	rebuild_chunks_structure()
	signal_brush_settings_changed.emit()



## Cleans, tracks, and instantiates RAM-only chunks, executing lossless geometric grid data migration if dimensions scale.
## FIXED: Implements a lossless geometric grid migration filter when chunk_size changes.
func rebuild_chunks_structure() -> void:
	_setup_pending = false
	
	# CRASH-PROTECTION: Automatically heal the dictionary if it ever becomes null or corrupted
	if global_height_data == null:
		global_height_data = {}

	
	# 1. EVALUATE GEOMETRIC GRID MIGRATION REQUIREMENTS
	var old_vert_count: int = -1
	var new_vert_count: int = chunk_size + 1
	
	# Determine historical array lengths from active data entries
	for coord in global_height_data.keys():
		if global_height_data[coord] is Array and global_height_data[coord].size() > 0:
			old_vert_count = roundi(sqrt(global_height_data[coord].size()))
			break
			
	# Execute coordinate-accurate point migration if chunk dimensions were modified
	if old_vert_count != -1 and old_vert_count != new_vert_count:
		print("Chunk size changed! Migrating terrain height matrix safely...")
		var migrated_data: Dictionary = {}
		var old_chunk_size = old_vert_count - 1
		
		for cz in range(world_chunks.y):
			for cx in range(world_chunks.x):
				var coord = Vector2i(cx, cz)
				var new_array: Array[float] = []
				new_array.resize(new_vert_count * new_vert_count)
				new_array.fill(0.0)
				
				# Map historical vertex heights to precise global coordinates within the refreshed grid layout
				for lz in range(new_vert_count):
					for lx in range(new_vert_count):
						# Calculate spatial world-space coordinates
						var global_gx = cx * chunk_size + lx
						var global_gz = cz * chunk_size + lz
						
						# Locate matching historical chunk assignments
						var old_cx = floori(float(global_gx) / old_chunk_size)
						var old_cz = floori(float(global_gz) / old_chunk_size)
						var old_coord = Vector2i(old_cx, old_cz)
						
						if global_height_data.has(old_coord):
							var old_lx = global_gx - (old_cx * old_chunk_size)
							var old_lz = global_gz - (old_cz * old_chunk_size)
							
							if old_lx >= 0 and old_lx < old_vert_count and old_lz >= 0 and old_lz < old_vert_count:
								var old_idx = old_lx + old_lz * old_vert_count
								new_array[lx + lz * new_vert_count] = global_height_data[old_coord][old_idx]
								
				migrated_data[coord] = new_array
		global_height_data = migrated_data

	# 2. HARD CLEANUP: Remove ANY child chunk that falls outside the active world size boundaries
	var dynamic_collision_name: String = name + "_Collisions"
	chunks_dict.clear()
	for child in get_children():
		# Protect vital infrastructure containers from being wiped during resize passes
		if child.name == "DEBUG_BrushGizmo_Transient" or child.name == dynamic_collision_name or child.name == "Terrain_Assets":
			continue
			
		if child is LowPolyTerrainChunk and not child.name.contains("@"):
			var coord = child.chunk_coord
			if coord.x >= world_chunks.x or coord.y >= world_chunks.y:
				child.free() # Purge out-of-bounds instances instantly
			else:
				chunks_dict[coord] = child
		else:
			child.free()
			
	# NEW: Automated self-healing anchor to guarantee the default asset node always exists
	if not has_node("Terrain_Assets"):
		var asset_container = Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			asset_container.set_owner(get_tree().edited_scene_root)

			
	# 3. PURGE OBSOLETE DATA KEYS
	for coord in global_height_data.keys():
		if coord.x >= world_chunks.x or coord.y >= world_chunks.y:
			global_height_data.erase(coord)
			
	# 4. INITIALIZE REFRESHED CHUNK NODES
	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var coord = Vector2i(cx, cz)
			
			if not chunks_dict.has(coord):
				var new_chunk = LowPolyTerrainChunk.new()
				new_chunk.name = "Chunk_%d_%d" % [cx, cz]
				new_chunk.chunk_coord = coord
				add_child(new_chunk)
				chunks_dict[coord] = new_chunk
			
			if not global_height_data.has(coord):
				var empty_array: Array[float] = []
				empty_array.resize(new_vert_count * new_vert_count)
				empty_array.fill(0.0)
				global_height_data[coord] = empty_array
				

			chunks_dict[coord].initialize(
				coord, 
				chunk_size, 
				cell_size, 
				step_height, 
				material_color, 
				global_height_data[coord], 
				jitter_strength, 
				show_chunk_labels, 
				jitter_slope_threshold,
				custom_material
			)




## Global multi-pass cross-filter operation that processes and blurs the entire grid structure smoothly.
func _smooth_entire_terrain() -> void:
	print("Smoothing global terrain (%d passes, completely fluid)..." % smooth_iterations)
	
	var max_vertex_x = world_chunks.x * chunk_size
	var max_vertex_z = world_chunks.y * chunk_size
	
	for iteration in range(smooth_iterations):
		var temporary_data: Dictionary = {}
		for coord in global_height_data.keys():
			temporary_data[coord] = global_height_data[coord].duplicate()
			
		for gz in range(max_vertex_z + 1):
			for gx in range(max_vertex_x + 1):
				var current_height = _get_global_vertex_height_from_copy(gx, gz, temporary_data)
				if current_height == null: continue
					
				var sum_heights: float = 0.0
				var valid_neighbors: int = 0
				var neighbors = [Vector2i(gx + 1, gz), Vector2i(gx - 1, gz), Vector2i(gx, gz + 1), Vector2i(gx, gz - 1)]
				
				for n in neighbors:
					var h = _get_global_vertex_height_from_copy(n.x, n.y, temporary_data)
					if h != null:
						sum_heights += h
						valid_neighbors += 1
						
				if valid_neighbors > 0:
					var average_height = sum_heights / float(valid_neighbors)
					var new_height = lerpf(current_height, average_height, smooth_factor)
					_set_global_vertex_height(gx, gz, new_height)
					
	# POST-PROCESSING SNAPPING BLOCK REMOVED ACCORDING TO ORIGINAL ARCHITECTURE
	# Values remain inside the data matrix as highly accurate floating-point numbers
					
	for chunk in chunks_dict.values():
		if chunk: chunk.generate_mesh()
	notify_property_list_changed()



## Safely reads a vertex height from a data copy dictionary using global world coordinates, accounting for boundaries.
func _get_global_vertex_height_from_copy(gx: int, gz: int, copy_dict: Dictionary) -> Variant:
	var cx = floori(float(gx) / chunk_size)
	var cz = floori(float(gz) / chunk_size)
	
	# Clamp calculation indexes to secure the absolute outer edges of the world grid
	if cx >= world_chunks.x: cx = world_chunks.x - 1
	if cz >= world_chunks.y: cz = world_chunks.y - 1
	
	var coord = Vector2i(cx, cz)
	if not copy_dict.has(coord): return null
	
	var vert_count = chunk_size + 1
	# Calculate localized positions directly relative to the targeted destination chunk mapping
	var lx = gx - (cx * chunk_size)
	var lz = gz - (cz * chunk_size)
	
	if lx >= 0 and lx < vert_count and lz >= 0 and lz < vert_count:
		return copy_dict[coord][lx + lz * vert_count]
	return null

func idx_calc(lx: int, lz: int, vc: int) -> int:
	return lx + lz * vc

## Safe-write method that maps a single global coordinate down to its 1-4 intersecting chunk edge boundaries.
func _set_global_vertex_height(gx: int, gz: int, new_h: float) -> void:
	var cx = floori(float(gx) / chunk_size)
	var cz = floori(float(gz) / chunk_size)
	_write_to_array(cx, cz, gx, gz, new_h)
	if gx % chunk_size == 0 and gx > 0: _write_to_array(cx - 1, cz, gx, gz, new_h)
	if gz % chunk_size == 0 and gz > 0: _write_to_array(cx, cz - 1, gx, gz, new_h)
	if gx % chunk_size == 0 and gz % chunk_size == 0 and gx > 0 and gz > 0: _write_to_array(cx - 1, cz - 1, gx, gz, new_h)

func _write_to_array(cx: int, cz: int, gx: int, gz: int, new_h: float) -> void:
	# Safety check: Validate whether the target destination chunk exists within global map grid limits
	if cx < 0 or cx >= world_chunks.x or cz < 0 or cz >= world_chunks.y: return
	
	var coord = Vector2i(cx, cz)
	if not global_height_data.has(coord): return
	
	var vert_count = chunk_size + 1
	# Calculate localized position strictly based on the target chunk parameter to prevent boundary overflow bugs
	var lx = gx - (cx * chunk_size)
	var lz = gz - (cz * chunk_size)
	
	if lx >= 0 and lx < vert_count and lz >= 0 and lz < vert_count:
		global_height_data[coord][lx + lz * vert_count] = new_h





# Bakes and instantiates persistent physical collider nodes directly under the scene root.
## FIXED: Dynamically applies user-defined collision layers and group configurations.
func _bake_live_collisions_as_child() -> void:
	# Fallback tree selection sequence to support both live Editor scenes and isolated GUT test runners
	var scene_root: Node = null
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		scene_root = get_tree().edited_scene_root
	elif get_parent() != null:
		scene_root = get_parent()
		
	if scene_root == null:
		print("Baking cancelled: Active editor scene root not found.")
		return
		
	var dynamic_collision_name: String = name + "_Collisions"
	print("Baking static collisions live into the scene root hierarchy as: %s" % dynamic_collision_name)
	
	# 1. PURGE OUTDATED LIVE COLLISION CONTAINERS FROM THE ENTIRE SCENE ROOT
	var old_container = scene_root.find_child(dynamic_collision_name, false, false)
	if old_container:
		old_container.free()
		print("Successfully cleared historical collision nodes from scene root.")
		
	# 2. INSTANTIATE REFRESHED ROOT CONTAINER DIRECTLY UNDER SCENE ROOT
	var collision_root = Node3D.new()
	collision_root.name = dynamic_collision_name
	scene_root.add_child(collision_root)
	
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		collision_root.set_owner(scene_root)
	
	# 3. ITERATE ACTIVE CHUNKS TO BUILD COLLIDER SHAPES
	for chunk in chunks_dict.values():
		if chunk and chunk.mesh:
			# Pass null to chunk.bake_collision so it doesn't set faulty owners prematurely
			chunk.bake_collision(null)
			
			var static_body = chunk.find_child("Static_" + chunk.name, false, false)
			if static_body:
				chunk.remove_child(static_body)
				collision_root.add_child(static_body)
				
				# --- STRUCTURAL AND VISUAL ALIGNMENT FIX ---
				var half_bounds = (chunk.chunk_size * chunk.cell_size) / 2.0
				var center_offset = Vector3(half_bounds, 0.0, -half_bounds)
				static_body.global_position = chunk.global_position + center_offset
				
				# --- DYNAMIC LAYER & GROUP ASSIGNMENT ---
				# Clean old groups to prevent duplicate entries if settings changed
				for grp in static_body.get_groups():
					static_body.remove_from_group(grp)
					
				# Apply the user-defined properties from the inspector fields
				static_body.collision_layer = collision_layer
				static_body.collision_mask = 0 # Static terrain typically doesn't need a mask
				
				# Only add to a group if the string is not empty
				if not collision_group.strip_edges().is_empty():
					static_body.add_to_group(collision_group, true)
				
				# Distribute structural ownership cleanly down the tree hierarchy
				if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
					static_body.set_owner(scene_root)
					for shape_child in static_body.get_children():
						shape_child.set_owner(scene_root)
						
	print("Collisions successfully generated live and anchored under the scene root!")



## Core brush manipulation engine triggered directly by the editor plugin.
func interact_at_world_position(world_pos: Vector3, is_alternative: bool) -> void:
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - _last_paint_time < _paint_cooldown: return
	_last_paint_time = current_time

	var local_pos = to_local(world_pos)
	var global_vertex_x = roundi(local_pos.x / cell_size)
	var global_vertex_z = roundi(-local_pos.z / cell_size)
	
	# Determine operation mode based on current selection and modifier keys
	var mode: BrushMode = tool_mode
	if is_alternative:
		# FIXED: Restore the original intuitive shift-invert behavior for painting
		if tool_mode == BrushMode.RAISE:
			mode = BrushMode.LOWER
		elif tool_mode == BrushMode.LOWER:
			mode = BrushMode.RAISE
		else:
			# Fallback for Flatten or other modes when holding Shift
			mode = BrushMode.SMOOTH
		
	var chunks_to_update: Array[LowPolyTerrainChunk] = []
	
	var temporary_data: Dictionary = {}
	for coord in global_height_data.keys():
		temporary_data[coord] = global_height_data[coord].duplicate()
		
	for gz in range(global_vertex_z - brush_radius, global_vertex_z + brush_radius + 1):
		for gx in range(global_vertex_x - brush_radius, global_vertex_x + brush_radius + 1):
			if Vector2(gx - global_vertex_x, gz - global_vertex_z).length() <= brush_radius:
				
				var current_h = _get_global_vertex_height_from_copy(gx, gz, temporary_data)
				if current_h == null: continue
				
				var new_h = current_h
				
				match mode:
					BrushMode.RAISE:
						new_h += step_height
					BrushMode.LOWER:
						new_h -= step_height
					BrushMode.FLATTEN:
						var target_h = _get_global_vertex_height_from_copy(global_vertex_x, global_vertex_z, temporary_data)
						new_h = snapped(target_h if target_h != null else 0.0, step_height)
					BrushMode.SMOOTH:
						var sum_heights: float = 0.0
						var valid_neighbors: int = 0
						var neighbors = [Vector2i(gx + 1, gz), Vector2i(gx - 1, gz), Vector2i(gx, gz + 1), Vector2i(gx, gz - 1)]
						
						for n in neighbors:
							var h = _get_global_vertex_height_from_copy(n.x, n.y, temporary_data)
							if h != null:
								sum_heights += h
								valid_neighbors += 1
								
						if valid_neighbors > 0:
							var average_height = sum_heights / float(valid_neighbors)
							new_h = lerpf(current_h, average_height, smooth_factor)
					
				_set_global_vertex_height(gx, gz, new_h)
				_add_affected_chunks_to_update(gx, gz, chunks_to_update)

	notify_property_list_changed()
	
	for chunk in chunks_to_update:
		if chunk: chunk.generate_mesh()





## Checks mathematical boundaries to flag all 1-4 edge chunks touching a modified global vertex coordinate.
func _add_affected_chunks_to_update(gx: int, gz: int, update_list: Array) -> void:
	var cx = floori(float(gx) / chunk_size)
	var cz = floori(float(gz) / chunk_size)
	
	# Initialize location tracking table maps containing target boundary coordinates
	var coords = [Vector2i(cx, cz)]
	
	# Intersecting seam edge handling evaluation triggers
	if gx % chunk_size == 0 and gx > 0: 
		coords.append(Vector2i(cx - 1, cz))
	if gz % chunk_size == 0 and gz > 0: 
		coords.append(Vector2i(cx, cz - 1))
	if gx % chunk_size == 0 and gz % chunk_size == 0 and gx > 0 and gz > 0: 
		coords.append(Vector2i(cx - 1, cz - 1))
		
	# Populate update arrays filtering out redundant duplicate items
	for c in coords:
		if chunks_dict.has(c):
			var chunk = chunks_dict[c]
			if not chunk in update_list:
				update_list.append(chunk)

## Legacy helper method used to write tracking parameters into isolated single-chunk registers.
func _set_height_in_chunk(cx: int, cz: int, gx: int, gz: int, mode: int, center_gx: int, center_gz: int, update_list: Array) -> void:
	var c_coord = Vector2i(cx, cz)
	if not chunks_dict.has(c_coord): return
	
	var chunk = chunks_dict[c_coord]
	var vert_count = chunk_size + 1
	var local_vx = gx - (cx * chunk_size)
	var local_vz = gz - (cz * chunk_size)
	
	if local_vx >= 0 and local_vx < vert_count and local_vz >= 0 and local_vz < vert_count:
		var idx = local_vx + local_vz * vert_count
		var data_array: Array = global_height_data[c_coord]

		
		if mode == 0: 
			data_array[idx] += step_height
		elif mode == 1: 
			data_array[idx] -= step_height # Hier startet dein Schnipsel
		elif mode == 2: # Das Einebnen-Werkzeug
			var ccx = floori(float(center_gx) / chunk_size)
			var ccz = floori(float(center_gz) / chunk_size)
			if global_height_data.has(Vector2i(ccx, ccz)):
				var clx = center_gx - (ccx * chunk_size)
				var clz = center_gz - (ccz * chunk_size)
				data_array[idx] = snapped(global_height_data[Vector2i(ccx, ccz)][clx + clz * (chunk_size + 1)], step_height)
				
		if not chunk in update_list: 
			update_list.append(chunk)
