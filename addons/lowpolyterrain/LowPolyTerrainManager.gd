@tool
extends Node3D
class_name LowPolyTerrainManager

## Master controller script that handles seamless height coordinates, multi-chunk modification,
## multi-pass smoothing operations, and automated static collision baking.

## signals
signal signal_brush_settings_changed
## Signal to notify the editor plugin when the user requests a terrain export.
signal signal_export_requested

# Centralized structural constants for advanced Inspector paths
const GROUP_DIMENSIONS := "World Dimensions (Requires Apply)"
const SUBGROUP_METRICS := "Calculated Metrics (Read-Only)"

const PROP_SIZE_METERS := "total_size_meters"
const PROP_TOTAL_VERTICES := "total_vertices"

# Dynamic concatenation to prevent hardcoded duplicate string literals
const PATH_SIZE_METERS := GROUP_DIMENSIONS + "/" + SUBGROUP_METRICS + "/" + PROP_SIZE_METERS
const PATH_TOTAL_VERTICES := GROUP_DIMENSIONS + "/" + SUBGROUP_METRICS + "/" + PROP_TOTAL_VERTICES

# Centralized terrain sculpting and chunk state tools
enum BrushMode {
	RAISE = 0,
	LOWER = 1,
	FLATTEN = 2,
	SMOOTH = 3,
	ACTIVATE_CHUNK = 4,
	DEACTIVATE_CHUNK = 5,
	NO_FURTHER_BUTTONS = 5,
	DECREASE_BRUSH_RADIUS = 6,
	INCREASE_BRUSH_RADIUS = 7
}


## Selects how terrain chunks are submitted to the engine.
enum TerrainBackend {
	MESH_NODES = 0, ## Classic MeshInstance3D children plus baked StaticBody3D colliders.
	SERVERS = 1     ## Direct RenderingServer and PhysicsServer3D RIDs, without any child node.
}

## Chooses the rendering and physics submission strategy used for every terrain chunk.
## MESH_NODES creates RAM-only MeshInstance3D children and relies on baked collider nodes.
## SERVERS registers chunks straight into RenderingServer and PhysicsServer3D, which removes
## the per-chunk node overhead entirely. Both modes read from the very same height data, so
## switching back and forth is lossless.
@export var terrain_backend: TerrainBackend = TerrainBackend.MESH_NODES:
	set(v):
		var previous: TerrainBackend = terrain_backend
		terrain_backend = v
		# Some settings only exist for one backend, so the inspector has to re-evaluate which
		# of them it should still be showing.
		notify_property_list_changed()
		# Property setters already fire while the scene is being deserialized, long before
		# _ready() runs and before this node is inside the tree. Activating a backend at that
		# point would touch a world that does not exist yet, so _ready() performs the initial
		# activation for whatever value was restored from disk.
		if not is_node_ready():
			return
		if previous == v:
			return
		_switch_terrain_backend(previous, v)


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

## If enabled, overlays a wireframe grid along the chunk boundaries inside the editor viewport.
##
## Replaces the former per-chunk 3D text labels: a single line mesh covers the whole terrain
## regardless of chunk count, and unlike text it stays legible at any zoom level. Toggling it
## costs nothing but a visibility flag, where the labels forced a full world rebuild.
@export var show_chunk_grid: bool = false:
	set(v):
		show_chunk_grid = v
		_update_chunk_grid_overlay()

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

## Settings that only ever take effect for TerrainBackend.SERVERS.
const SERVER_ONLY_PROPERTIES: PackedStringArray = [
	"runtime_collision",
	"collision_debug_draw",
]

## Settings that only ever take effect for TerrainBackend.MESH_NODES.
const MESH_NODES_ONLY_PROPERTIES: PackedStringArray = [
	"bake_collisions_button",
]


## Hides the settings belonging to the other backend. They stay stored, they just stop
## advertising themselves in a mode where they genuinely cannot do anything - which is
## otherwise easy to misread as the setting being broken.
func _validate_property(property: Dictionary) -> void:
	var hidden: bool = false
	if terrain_backend == TerrainBackend.SERVERS:
		hidden = MESH_NODES_ONLY_PROPERTIES.has(property["name"])
	else:
		hidden = SERVER_ONLY_PROPERTIES.has(property["name"])

	if hidden:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR


## Triggers an instant inspector refresh to update calculated read-only size metrics
## in real-time.
func _update_read_only_metrics() -> void:
	if Engine.is_editor_hint():
		notify_property_list_changed()




@export_group("Noise Generation")
## The maximum vertical scaling applied to the added noise. 
## Generates balanced heights and depths centered around zero.
@export var noise_amplitude: float = 1.5

## The FastNoiseLite resource used to generate organic landscapes (Perlin, Cellular, etc.).
## Leave empty to add fallback random height values.
@export var terrain_noise: FastNoiseLite = null

## Click to add random or noise-based height values onto the existing terrain.
@export_tool_button("Generate Noise Terrain", "Grid")
var generate_noise_button: Callable = func() -> void: _generate_noise_terrain()


## Iterates through the active terrain matrix and adds coordinate-aligned noise heights.
func _generate_noise_terrain() -> void:
	print("Adding organic low-poly noise to active chunks...")
	
	# [GLOBAL UNDO] Register structural snapshot before running the generator logic
	var old_state: PackedFloat32Array = global_height_data.duplicate()
	
	# Fallback setup if no noise resource is assigned in the inspector
	var use_random_fallback: bool = (terrain_noise == null)
	if use_random_fallback:
		print("No noise resource found. Adding balanced random heights via amplitude.")
		
	var total_x: int = _total_vertices_x
	var total_z: int = _total_vertices_z
	var amp: float = noise_amplitude
	var c_size: int = chunk_size
	
	var local_rng := RandomNumberGenerator.new()
	local_rng.randomize()
	
	for z in range(total_z):
		for x in range(total_x):
			var cx: int = clampi(x / c_size, 0, world_chunks.x - 1)
			var cz: int = clampi(z / c_size, 0, world_chunks.y - 1)
			
			if not is_chunk_active(cx, cz):
				continue
				
			var added_height: float = 0.0
			if use_random_fallback:
				added_height = local_rng.randf_range(-amp, amp)
			else:
				var noise_val: float = terrain_noise.get_noise_2d(float(x), float(z))
				added_height = noise_val * amp
				
			var current_index: int = z * total_x + x
			global_height_data[current_index] += added_height

	for coord in _get_chunk_coords():
		_update_single_chunk(coord)
		
	# [GLOBAL UNDO] Securely fetch manager and commit history entry inside editor workspace
	if Engine.is_editor_hint():
		if _active_undo_redo_manager == null:
			var ei: Object = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_undo_redo"):
				_active_undo_redo_manager = ei.call("get_undo_redo")
				
			
		if _active_undo_redo_manager:
			# Pass 'self' as 3rd arg (custom_context) to secure scene tab focus
			_active_undo_redo_manager.create_action("Generate Noise Terrain", 0, self)
			_active_undo_redo_manager.add_do_method(
				self, 
				_apply_historical_snapshot.get_method(), 
				global_height_data.duplicate()
			)
			_active_undo_redo_manager.add_undo_method(
				self, 
				_apply_historical_snapshot.get_method(), 
				old_state
			)
			_active_undo_redo_manager.commit_action()



		
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



@export_group("Brush Settings")

# [FIX] Changed from @export to @export_storage to completely hide the redundant dropdown from the inspector
@export_storage var tool_mode: BrushMode = BrushMode.RAISE

## The operational radius of the painting brush measured in grid vertices.
@export_range(1, 50, 1) var brush_radius: int = 3:
	set(v):
		brush_radius = v
		signal_brush_settings_changed.emit()

## Controls how fast the terrain elevates, lowers, or smooths per stroke.
@export_range(0.05, 15.0, 0.05) var brush_strength: float = 3.0

## Controls the sharpness of the brush edges. 0.0 is completely sharp/linear, 1.0 is soft smoothstep.
@export_range(0.0, 1.0, 0.05) var brush_falloff_strength: float = 0.0

##@@

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

## Controls how much collision the SERVERS backend keeps resident at runtime.
enum RuntimeCollision {
	CULLED = 0, ## Colliders are built only for chunks update_collision_culling() reports.
	ALL = 1,    ## Every active chunk keeps a collider for the entire session (default).
	NONE = 2,   ## No runtime collision at all.
}

## SERVERS backend only; the MESH_NODES backend is unaffected and still uses the bake button.
##
## Concave colliders dominate the memory profile. Measured on a 10x10 grid of size-16 chunks:
##
##   MESH_NODES, never baked              6.1 MB
##   MESH_NODES, baked                   18.3 MB
##   SERVERS, RuntimeCollision.ALL       17.5 MB
##   SERVERS, CULLED with a 20 m radius   8.0 MB
##
## ALL is the default because it is the safe choice: it matches a baked MESH_NODES terrain
## while costing slightly less. CULLED only ever builds a collider for a chunk that
## update_collision_culling() has reported as reachable, which is where the large saving comes
## from - a collider that is released does NOT hand its physics-server memory back, so the
## only cheap collider is one that was never created. A game using CULLED therefore MUST call
## update_collision_culling() or it will have no terrain collision at all.
@export var runtime_collision: RuntimeCollision = RuntimeCollision.ALL:
	set(v):
		runtime_collision = v
		if _server_backend != null:
			_server_backend.set_collision_policy(int(v))

## Controls the translucent overlay that visualises the SERVERS backend's live colliders.
enum CollisionDebugDraw {
	FOLLOW_DEBUG_MENU = 0, ## Follow Godot's own Debug > Visible Collision Shapes toggle.
	ALWAYS = 1,            ## Always draw the overlay.
	NEVER = 2,             ## Never draw the overlay.
}

## SERVERS only. Godot's built-in "Visible Collision Shapes" cannot show these colliders,
## because that feature lives inside CollisionShape3D and this backend has no such node.
## This draws the very same geometry instead, taken straight from Shape3D.get_debug_mesh().
##
## Useful mainly for watching RuntimeCollision.CULLED work: only the chunks that currently own
## a collider light up, so the culling radius becomes directly visible.
##
## The overlay costs extra line geometry per visible chunk, so leave it off when profiling.
@export var collision_debug_draw: CollisionDebugDraw = CollisionDebugDraw.FOLLOW_DEBUG_MENU:
	set(v):
		collision_debug_draw = v
		_sync_collision_debug_draw()

## Nodes the collision culling should follow, typically the player's CharacterBody3D.
##
## While at least one valid target is assigned the manager drives update_collision_culling()
## itself once per physics frame, so RuntimeCollision.CULLED needs no glue code at all. The
## enabled set is the union of every target's radius. Leave empty to drive culling manually.
##
## An inspector reference can only point inside the same scene. For a player spawned at
## runtime use add_culling_target() / remove_culling_target() instead.
@export var collision_cull_targets: Array[Node3D] = []:
	set(v):
		collision_cull_targets = v
		_refresh_culling_target_state()

## Radius in METRES around every culling target that keeps its collision loaded.
##
## Pre-filled with two chunk edge lengths (chunk_size * cell_size * 2) and re-derived whenever
## the terrain dimensions change - but only while the value still matches what was derived
## last time, so a deliberate override is never silently overwritten.
##
## Bigger is safer: collision must be present BEFORE a target arrives, so fast movers need
## more lead than walkers. Cost grows with the area, hence quadratically with this value.
@export var collision_cull_radius: float = 0.0

## Last automatically derived radius, kept so a manual override stays recognisable across
## dimension changes and scene reloads.
@export_storage var _derived_cull_radius: float = 0.0

## The physics layer bitmask assigned to the generated static colliders. Default is Layer 2.
@export_flags_2d_physics var collision_layer: int = 2:
	set(v):
		collision_layer = v
		# Baked collider nodes read this value at bake time, so only the live server bodies
		# need an explicit refresh here.
		if _server_backend != null:
			_server_backend.refresh_collision_layer()

## The scene group name assigned to every generated static collision node. In SERVERS mode
## PhysicsServer3D bodies cannot join a scene group, so the manager joins it on their behalf
## and the bodies report the manager as their collider. Default is "Wall".
@export var collision_group: String = "Wall":
	set(v):
		collision_group = v
		if terrain_backend == TerrainBackend.SERVERS and is_node_ready():
			_leave_collision_group()
			_join_collision_group()

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



## Sets activation state of chunks within a world-space radius and requests localized visual rebuild.
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
	var radius_squared: float = radius_meters * radius_meters
	
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
			if dist_sq <= radius_squared:
				var index := cz * world_chunks.x + cx
				if index < chunk_activity_data.size() and chunk_activity_data[index] != target_value:
					chunk_activity_data[index] = target_value
					
					# Direct update of the changed without global rebuild
					var coord := Vector2i(cx, cz)
					if _has_chunk(coord):
						_update_single_chunk(coord)





# --- PERFORMANCE CRITICAL: Flattened array structure instead of Dictionary ---
@export_storage var global_height_data: PackedFloat32Array = PackedFloat32Array()

# Cached structural bounds variables to achieve zero-latency lookup performance
var _total_vertices_x: int = 0
var _total_vertices_z: int = 0

@export_group("Data Export")
## The target path within your project where the generated terrain mesh will be saved
## as a GLTF file.
@export var export_target_path: String = "res://terrain_export.gltf"

# Click to open a native Editor Save Dialog where you can choose a folder and name
## a new GLTF file.
@export_tool_button("Choose Path & Export Terrain", "Save")
var export_gltf_button: Callable = func() -> void: signal_export_requested.emit()



# --- Internal Operational Logic & Cool-downs ---
var _setup_pending: bool = false
var chunks_dict: Dictionary = {}
var _paint_cooldown: float = 0.1 
var _last_paint_time: float = 0.0


# Persistent sculpting data to lock the initial flatten height across frames
var is_paint_stroke_active: bool = false
var locked_flatten_height: float = 0.0


# --- HIGH-PERFORMANCE SPARSE DELTA STORAGE FOR SCULPTING UNDO/REDO ---
var _undo_sparse_delta: Dictionary = {} # Format: { global_index (int): old_height (float) }
var _active_undo_redo_manager: Object = null


# --- SERVER BACKEND STATE ---
## Owns every RenderingServer and PhysicsServer3D RID while TerrainBackend.SERVERS is active.
## Stays null in TerrainBackend.MESH_NODES so the classic node pipeline is never touched.
var _server_backend: LowPolyTerrainServerBackend = null

## Remembers which scene group this manager joined, so it can leave exactly that group again
## even after collision_group was edited in the meantime.
var _joined_collision_group: String = ""



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
		or child.name == "Terrain_Assets" or child.name == CHUNK_GRID_NODE_NAME:
			continue
		child.free()
		
	# Automatically spawn the persistent asset container inside the editor tree if it's missing
	if Engine.is_editor_hint() and not has_node("Terrain_Assets"):
		var asset_container := Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		
		# SAFE RUNTIME LOOKUP: Fetches the main loop as a generic Object. Using a dynamic string
		# query bypasses the compiler type-check entirely, preventing release export crashes.
		var main_loop: Object = Engine.get_main_loop()
		if main_loop:
			var scene_root: Variant = main_loop.get("edited_scene_root")
			if scene_root:
				asset_container.set_owner(scene_root)
			
	chunks_dict.clear()
	
	# Allocate structural array data if not populated via storage deserialization pipeline
	if global_height_data.is_empty():
		_initialize_empty_grid()
		
	if chunk_activity_data.is_empty():
		chunk_activity_data.resize(world_chunks.x * world_chunks.y)
		chunk_activity_data.fill(1)

	_apply_derived_cull_radius()

	# NOTIFICATION_ENTER_WORLD already fired before this point, at which time the backend did
	# not exist yet, so the initial activation for the deserialized value happens here.
	if terrain_backend == TerrainBackend.SERVERS:
		_activate_server_backend(false)
	else:
		rebuild_chunks_structure()

	# Runs after the backend is up, so the very first pass can already build colliders.
	_refresh_culling_target_state()





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


##@@

## Returns the terrain height at a world-space XZ position, in WORLD space.
##
## O(1): four array reads and three interpolations, no physics query and no geometry involved.
## Works identically in both backends because it samples the height matrix rather than the
## generated mesh, and it honours this manager's transform.
##
## ACCURACY. With jitter_strength at 0 the result matches the rendered and collided surface
## exactly (measured below 0.5 mm). Jitter is what introduces error, because it displaces mesh
## vertices horizontally while the height matrix stays on its regular grid, and on a slope a
## sideways shift reads as a height difference. The error therefore scales with
##
##     jitter_strength * (height change between neighbouring vertices)
##
## and was measured up to roughly 1.4x that product. Concretely, on a 3x3 chunk terrain with
## cell_size 1.0 and jitter_strength 0.5: a gentle 0.26 m per cell relief deviates by 6 mm on
## average and 4.5 cm at worst, while a steep 0.77 m per cell relief deviates by 10 cm on
## average and 53 cm at worst. A larger cell_size reduces it, since the slope per metre drops.
##
## So: exact on unjittered terrain, good enough for placing props and AI queries on gentle
## jittered terrain, and not a substitute for a raycast on steep jittered terrain.
##
## Coordinates outside the terrain are clamped to the border, so the nearest edge height comes
## back rather than a sentinel value. Use is_inside_terrain() when that distinction matters.
##
## Note that "the height at an XZ position" stops being well defined if this manager is rotated
## around X or Z, because a vertical ray can then cross the surface more than once. Translation,
## scale and rotation around Y are all handled correctly.
func get_height_at_world_coords(world_x: float, world_z: float) -> float:
	if is_zero_approx(cell_size) or global_height_data.is_empty():
		return 0.0
	if _total_vertices_x <= 0 or _total_vertices_z <= 0:
		return 0.0

	var local: Vector3 = to_local(Vector3(world_x, 0.0, world_z))
	var grid_x: float = local.x / cell_size
	var grid_z: float = -local.z / cell_size

	# The cell origin is clamped one short of the last vertex so the +1 neighbours below stay
	# in range; the interpolation factors then carry the clamping for out-of-bounds queries.
	var x0: int = clampi(floori(grid_x), 0, maxi(_total_vertices_x - 2, 0))
	var z0: int = clampi(floori(grid_z), 0, maxi(_total_vertices_z - 2, 0))
	var x1: int = mini(x0 + 1, _total_vertices_x - 1)
	var z1: int = mini(z0 + 1, _total_vertices_z - 1)

	var tx: float = clampf(grid_x - float(x0), 0.0, 1.0)
	var tz: float = clampf(grid_z - float(z0), 0.0, 1.0)

	var row0: int = z0 * _total_vertices_x
	var row1: int = z1 * _total_vertices_x

	var height: float = lerpf(
		lerpf(global_height_data[row0 + x0], global_height_data[row0 + x1], tx),
		lerpf(global_height_data[row1 + x0], global_height_data[row1 + x1], tx),
		tz
	)

	# Sampled in local space, handed back in world space, so a moved or scaled manager reports
	# the height the caller can actually place something at.
	return (global_transform * Vector3(local.x, height, local.z)).y


## Convenience wrapper taking a world position; its Y component is ignored.
func get_height_at_world_position(world_pos: Vector3) -> float:
	return get_height_at_world_coords(world_pos.x, world_pos.z)


## True when the world-space XZ position lies within the terrain grid, so a height query there
## returns a sampled value rather than a clamped border one. Says nothing about whether the
## chunk at that spot is activated.
func is_inside_terrain(world_x: float, world_z: float) -> bool:
	if is_zero_approx(cell_size) or _total_vertices_x <= 0 or _total_vertices_z <= 0:
		return false

	var local: Vector3 = to_local(Vector3(world_x, 0.0, world_z))
	var grid_x: float = local.x / cell_size
	var grid_z: float = -local.z / cell_size

	return grid_x >= 0.0 and grid_x <= float(_total_vertices_x - 1) \
		and grid_z >= 0.0 and grid_z <= float(_total_vertices_z - 1)


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
	
	# 1. MIGRATE CHUNK ACTIVITY LAYER DATA Safely
	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var new_chunk_idx: int = cz * world_chunks.x + cx
			if cx < old_chunks_x and cz < old_chunks_y and not old_activity_data.is_empty():
				var old_chunk_idx: int = cz * old_chunks_x + cx
				if old_chunk_idx < old_activity_data.size():
					new_activity_data[new_chunk_idx] = old_activity_data[old_chunk_idx]
	
	chunk_activity_data = new_activity_data
	
	# 2. FIXED INDEX LOOKUP: Enforce hard clamps against historical matrix bounds
	for z in range(_total_vertices_z):
		var is_valid_z: bool = (z < old_vertices_z)
		var new_row_offset: int = z * _total_vertices_x
		var old_row_offset: int = z * old_vertices_x
		
		for x in range(_total_vertices_x):
			var new_index: int = new_row_offset + x
			
			# Enforce multi-layered structural validation checks to fully block memory leaks
			if is_valid_z and x < old_vertices_x and not old_height_data.is_empty():
				var old_index: int = old_row_offset + x
				if old_index >= 0 and old_index < old_height_data.size():
					new_height_data[new_index] = old_height_data[old_index]
				else:
					new_height_data[new_index] = 0.0
			else:
				new_height_data[new_index] = 0.0
				
	global_height_data = new_height_data

	# The culling radius is expressed in metres, so it has to follow the new chunk dimensions.
	_apply_derived_cull_radius()

	# 3. REBUILD INFRASTRUCTURE SYSTEM
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

	# Dimensions are final at this point, so one call here keeps the grid overlay correct for
	# both backends without duplicating it into the branch below.
	_update_chunk_grid_overlay()

	if terrain_backend == TerrainBackend.SERVERS:
		_rebuild_server_chunks()
		return

	# 1. HARD CLEANUP: Remove ANY child chunk that falls outside the active world size boundaries
	var dynamic_collision_name: String = name + "_Collisions"
	chunks_dict.clear()
	
	# Pre-calculate spatial stride to safely reverse-engineer coordinates from world positions
	var meters_per_chunk: float = float(chunk_size) * cell_size
	
	for child in get_children():
		# Protect vital infrastructure containers from being wiped during resize passes
		if child.name == "DEBUG_BrushGizmo_Transient" or child.name == dynamic_collision_name \
		or child.name == "Terrain_Assets" or child.name == CHUNK_GRID_NODE_NAME:
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
			
			# AT RUNTIME: Only add chunk to dict if active
			if is_chunk_active(cx, cz) or Engine.is_editor_hint():
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
	
	# [GLOBAL UNDO] Register structural snapshot before running the smoothing loops
	var old_state: PackedFloat32Array = global_height_data.duplicate()
	
	for iteration in range(smooth_iterations):
		# High-performance C++ array duplication for rapid read isolations
		var temporary_data: PackedFloat32Array = global_height_data.duplicate()
		
		for gz in range(_total_vertices_z):
			for gx in range(_total_vertices_x):
				var current_index: int = gz * _total_vertices_x + gx
				var current_height: float = temporary_data[current_index]
				
				var average_height: float = _calculate_average_neighbor_height(gx, gz, temporary_data)
				global_height_data[current_index] = lerpf(current_height, average_height, smooth_factor)

	# Synchronize and push fresh data blocks directly into the active chunks
	for coord in _get_chunk_coords():
		_update_single_chunk(coord)
		
	# [GLOBAL UNDO] Securely fetch manager and commit history entry inside editor workspace
	if Engine.is_editor_hint():
		if _active_undo_redo_manager == null:
			var ei: Object = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_undo_redo"):
				_active_undo_redo_manager = ei.call("get_undo_redo")
				
		if _active_undo_redo_manager:
			# Pass 'self' as 4th arg (custom_context) to bind action to the active scene tab
			_active_undo_redo_manager.create_action("Smooth Entire Terrain", 0, self)
			_active_undo_redo_manager.add_do_method(
				self, 
				_apply_historical_snapshot.get_method(), 
				global_height_data.duplicate()
			)
			_active_undo_redo_manager.add_undo_method(
				self, 
				_apply_historical_snapshot.get_method(), 
				old_state
			)
			_active_undo_redo_manager.commit_action()

		
	notify_property_list_changed()



##@@


## Core brush manipulation engine triggered directly by the editor plugin.
func interact_at_world_position(world_pos: Vector3, is_alternative: bool) -> void:
	
	# [TEST-SAFE COOLDOWN] Bypass throttling if we are running automated history checks
	if _active_undo_redo_manager == null:
		var current_time: float = Time.get_ticks_msec() / 1000.0
		if current_time - _last_paint_time < _paint_cooldown:
			return
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
		if not show_deactivated_chunks:
			show_deactivated_chunks = true
			
		var is_activation_pass: bool = (mode == BrushMode.ACTIVATE_CHUNK)
		set_chunk_status_in_radius(local_pos, is_activation_pass)
		return
	# --------------------------------------------------------------------

	var global_vertex_x: int = roundi(local_pos.x / cell_size)
	var global_vertex_z: int = roundi(-local_pos.z / cell_size)
	
	var chunks_to_update: Array[Vector2i] = []

	# [E4] Only SMOOTH needs an isolated read copy, because it averages NEIGHBOURING vertices
	# that the same pass is also writing. Every other mode reads exactly the index it writes,
	# and writes it exactly once, so it can read the live array directly. That removes a
	# full-matrix duplicate from every single paint event of the three most-used brushes.
	var temporary_data: PackedFloat32Array = PackedFloat32Array()
	if mode == BrushMode.SMOOTH:
		temporary_data = global_height_data.duplicate()

	var target_flatten_h: float = 0.0
	if mode == BrushMode.FLATTEN:
		# Check if this is the absolute first frame of the active click session
		if not is_paint_stroke_active:
			is_paint_stroke_active = true
			if global_vertex_x >= 0 and global_vertex_x < _total_vertices_x and global_vertex_z >= 0 and global_vertex_z < _total_vertices_z:
				locked_flatten_height = snapped(
					global_height_data[global_vertex_z * _total_vertices_x + global_vertex_x],
					step_height
				)
		
		# Lock the current frame's flatten target straight to the session cache
		target_flatten_h = locked_flatten_height


	var radius_squared: float = float(brush_radius * brush_radius)
	
	for gz in range(global_vertex_z - brush_radius, global_vertex_z + brush_radius + 1):
		if gz < 0 or gz >= _total_vertices_z:
			continue
		
		for gx in range(global_vertex_x - brush_radius, global_vertex_x + brush_radius + 1):
			if gx < 0 or gx >= _total_vertices_x:
				continue
			
			var dx: float = float(gx - global_vertex_x)
			var dz: float = float(gz - global_vertex_z)
			var dist_sq: float = (dx * dx + dz * dz)
			
			if dist_sq <= radius_squared:
				var vx_chunk: int = clampi(gx / chunk_size, 0, world_chunks.x - 1)
				var vz_chunk: int = clampi(gz / chunk_size, 0, world_chunks.y - 1)
				
				if not is_chunk_active(vx_chunk, vz_chunk):
					continue
					
				var current_index: int = gz * _total_vertices_x + gx
				# [E4] Safe for every mode: this index is written exactly once per pass, and
				# the write happens after this read, so the live array still holds the value
				# the pre-pass snapshot would have carried.
				var current_h: float = global_height_data[current_index]
				var new_h: float = current_h
				
				var current_increment: float = step_height * brush_strength
				
				# 1. Calculate the distance factor from the brush center (0.0 center to 1.0 edge)
				var distance_from_center: float = sqrt(dist_sq)
				var radius_factor: float = distance_from_center / float(brush_radius)
				
				# 2. Compute the smoothstep curve profile
				var smooth_curve: float = 1.0 - (radius_factor * radius_factor * (3.0 - 2.0 * radius_factor))
				smooth_curve = clampf(smooth_curve, 0.0, 1.0)
				
				# 3. Dynamic blending based on mode and inspector settings
				var final_falloff: float = 1.0
				
				if mode == BrushMode.SMOOTH:
					# Smooth brush always uses the organic smoothstep transition curve
					final_falloff = smooth_curve
				else:
					# RAISE, LOWER, and FLATTEN blend linearly between hard (1.0) and soft (smooth_curve)
					final_falloff = lerpf(1.0, smooth_curve, brush_falloff_strength)
				
				match mode:
					BrushMode.RAISE:
						new_h += current_increment * final_falloff
					BrushMode.LOWER:
						new_h -= current_increment * final_falloff
					BrushMode.FLATTEN:
						new_h = lerpf(current_h, target_flatten_h, final_falloff)
					BrushMode.SMOOTH:
						var average_height: float = _calculate_average_neighbor_height(gx, gz, temporary_data)
						var dynamic_smooth: float = clampf(smooth_factor * brush_strength * final_falloff, 0.0, 1.0)
						new_h = lerpf(current_h, average_height, dynamic_smooth)

				# [PERFORMANCE UNDO] Capture the historical vertex state before writing the mutation
				# [EXPORT-SAFE & TEST-READY UNDO] Track updates inside editor or mock test contexts
				if (Engine.is_editor_hint() or _active_undo_redo_manager != null) and _undo_sparse_delta != null:
					if not _undo_sparse_delta.has(current_index):
						_undo_sparse_delta[current_index] = current_h


				global_height_data[current_index] = new_h
				_add_affected_chunks_to_update(gx, gz, chunks_to_update)

	# [E5] notify_property_list_changed() deliberately does NOT run here. It rebuilds the whole
	# inspector, and nothing it displays changes while painting: the read-only metrics derive
	# purely from the preview_* dimensions. It is issued once per stroke in stroke_finished().
	for coord in chunks_to_update:
		_update_single_chunk(coord)


##@@

## Checks mathematical boundaries to flag all 1-4 edge chunks touching a modified global vertex coordinate.
func _add_affected_chunks_to_update(gx: int, gz: int, update_list: Array[Vector2i]) -> void:
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
		if _has_chunk(coord):
			if not coord in update_list:
				update_list.append(coord)


# Bakes and instantiates persistent physical collider nodes directly under the scene root.
## FIXED: Dynamically applies user-defined collision layers and group configurations.
func _bake_live_collisions_as_child() -> void:
	if terrain_backend == TerrainBackend.SERVERS:
		# Baking would duplicate the physics that PhysicsServer3D already provides, and
		# switching to SERVERS deliberately removes any previously baked container.
		print("Baking is unavailable in SERVERS mode: collision is registered directly into " \
			+ "PhysicsServer3D. Switch to MESH_NODES to bake persistent collider nodes.")
		return

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



## Synchronizes a single chunk's visibility, height data segments, and mesh generation.
func _update_single_chunk(coord: Vector2i) -> void:
	if terrain_backend == TerrainBackend.SERVERS:
		if _server_backend != null:
			_server_backend.update_chunk(coord)
		return

	if not chunks_dict.has(coord):
		return
	var chunk: LowPolyTerrainChunk = chunks_dict[coord]
	if not chunk:
		return
	
	# Process the visibility state of deactivated chunks based on inspector preview rules
	if not is_chunk_active(coord.x, coord.y):
		chunk.visible = bool(show_deactivated_chunks) if show_deactivated_chunks != null else true
		if not chunk.visible:
			chunk.mesh = null
			chunk.material_override = null
		else:
			# Incremental building of the red preview box
			var st_box := SurfaceTool.new()
			st_box.begin(Mesh.PRIMITIVE_TRIANGLES)
			var w: float = float(chunk_size) * cell_size
			var p0 := Vector3(0, 0.05, 0)
			var p1 := Vector3(w, 0.05, 0)
			var p2 := Vector3(w, 0.05, -w)
			var p3 := Vector3(0, 0.05, -w)
			
			st_box.add_vertex(p0)
			st_box.add_vertex(p1)
			st_box.add_vertex(p2)
			st_box.add_vertex(p0)
			st_box.add_vertex(p2)
			st_box.add_vertex(p3)
			chunk.mesh = st_box.commit()
			
			var red_mat := StandardMaterial3D.new()
			red_mat.albedo_color = Color(1.0, 0.0, 0.0, 0.25)
			red_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
			red_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			chunk.material_override = red_mat

		return

	chunk.visible = true
	var vert_stride: int = chunk_size + 1
	var chunk_local_heights := PackedFloat32Array()
	chunk_local_heights.resize(vert_stride * vert_stride)
	
	# Direct O(1) index mapping without any temporary .slice() memory allocations
	for lz in range(vert_stride):
		var global_z: int = (coord.y * chunk_size) + lz
		var local_offset: int = lz * vert_stride
		var global_row_start: int = global_z * _total_vertices_x + (coord.x * chunk_size)
		
		for i in range(vert_stride):
			chunk_local_heights[local_offset + i] = global_height_data[global_row_start + i]
			
	# Fully re-triangulate and build the visual low-poly terrain mesh geometry via Delaunay
	chunk.initialize(
		coord, chunk_size, cell_size, step_height,
		chunk_local_heights, jitter_strength,
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





## Marks the official initiation frame of an editor interaction sequence.
func stroke_started(editor_ur: Object) -> void:
	if not Engine.is_editor_hint(): return
	
	# Securely cache the central engine manager reference
	_active_undo_redo_manager = editor_ur
	
	# Reset the sparse delta matrix to ensure a clean state for the upcoming stroke
	_undo_sparse_delta.clear()



## Registers the finalized thin delta package directly into the native engine history.
func stroke_finished() -> void:
	# [E5] One inspector refresh per stroke instead of one per paint event.
	if Engine.is_editor_hint():
		notify_property_list_changed()

	if not Engine.is_editor_hint() or _active_undo_redo_manager == null or _undo_sparse_delta.is_empty():
		return
		
	# Build precise, compressed primitive arrays for the native Undo pipeline
	var affected_indices := PackedInt32Array()
	var old_heights := PackedFloat32Array()
	var new_heights := PackedFloat32Array()
	
	var total_elements: int = _undo_sparse_delta.size()
	affected_indices.resize(total_elements)
	old_heights.resize(total_elements)
	new_heights.resize(total_elements)
	
	var cursor: int = 0
	for idx in _undo_sparse_delta.keys():
		affected_indices[cursor] = idx
		old_heights[cursor] = _undo_sparse_delta[idx]
		new_heights[cursor] = global_height_data[idx]
		cursor += 1
		
	# Register inside Godot's Undo system using minimal memory footprint primitives
	# Pass 'self' as 4th arg (custom_context) to secure scene tab focus during paint strokes
	_active_undo_redo_manager.create_action("Terrain Sculpt Step", 0, self)
	_active_undo_redo_manager.add_do_method(
		self, 
		_apply_sparse_delta.get_method(), 
		affected_indices, 
		new_heights
	)
	_active_undo_redo_manager.add_undo_method(
		self, 
		_apply_sparse_delta.get_method(), 
		affected_indices, 
		old_heights
	)
	_active_undo_redo_manager.commit_action()



	_undo_sparse_delta.clear()


## High-speed targeted mutation callback invoked by the engine's central undo/redo pipeline.
func _apply_sparse_delta(indices: PackedInt32Array, heights: PackedFloat32Array) -> void:
	if indices.is_empty() or indices.size() != heights.size(): 
		return
		
	var unique_chunks_to_rebuild: Array[Vector2i] = []
	
	# Apply only the modified slices back to the flat global data array
	for i in range(indices.size()):
		var global_index: int = indices[i]
		global_height_data[global_index] = heights[i]
		
		# Reverse-engineer the chunk coordinates from the flat global index to optimize updates
		var gz: int = global_index / _total_vertices_x
		var gx: int = global_index % _total_vertices_x
		
		var cx: int = clampi(gx / chunk_size, 0, world_chunks.x - 1)
		var cz: int = clampi(gz / chunk_size, 0, world_chunks.y - 1)
		var chunk_coord_vec := Vector2i(cx, cz)
		
		if not chunk_coord_vec in unique_chunks_to_rebuild:
			unique_chunks_to_rebuild.append(chunk_coord_vec)
			
	# Visually update only the specific chunk nodes that were actually modified by this delta
	for coord in unique_chunks_to_rebuild:
		_update_single_chunk(coord)
		
	notify_property_list_changed()



## Native callback targeted by the engine loop during reverse or forward history evaluations.
func _apply_historical_snapshot(target_matrix: PackedFloat32Array) -> void:
	if target_matrix.is_empty(): return
	global_height_data = target_matrix.duplicate()

	# Full matrix structural re-triangulation synchronizations
	for coord in _get_chunk_coords():
		_update_single_chunk(coord)

	notify_property_list_changed()


##@@
# =====================================================================================
# SERVER BACKEND
# A raw RenderingServer instance has no parent and no place in the SceneTree, so every
# piece of bookkeeping a MeshInstance3D would inherit automatically has to be mirrored
# by hand here: world membership, transform, visibility and destruction.
# =====================================================================================


## Copies a chunk's height window out of the flat global matrix without any temporary slicing.
func extract_chunk_heights(coord: Vector2i) -> PackedFloat32Array:
	var vert_stride: int = chunk_size + 1
	var chunk_local_heights := PackedFloat32Array()
	chunk_local_heights.resize(vert_stride * vert_stride)

	# Direct O(1) index mapping without any temporary .slice() memory allocations
	for lz in range(vert_stride):
		var global_z: int = (coord.y * chunk_size) + lz
		var local_offset: int = lz * vert_stride
		var global_row_start: int = global_z * _total_vertices_x + (coord.x * chunk_size)

		for i in range(vert_stride):
			chunk_local_heights[local_offset + i] = global_height_data[global_row_start + i]

	return chunk_local_heights


## SERVERS counterpart of rebuild_chunks_structure(). Registers one RenderingServer instance
## per chunk instead of instantiating MeshInstance3D children.
func _rebuild_server_chunks() -> void:
	if _server_backend == null:
		return

	# Clear out any chunk node left behind by a previous MESH_NODES session, while protecting
	# the infrastructure containers exactly like the node path does.
	var dynamic_collision_name: String = name + "_Collisions"
	for child in get_children():
		if child.name == "DEBUG_BrushGizmo_Transient" or child.name == dynamic_collision_name \
		or child.name == "Terrain_Assets" or child.name == CHUNK_GRID_NODE_NAME:
			continue
		if child is LowPolyTerrainChunk:
			child.free()
	chunks_dict.clear()

	# Automated self-healing anchor to guarantee the default asset node always exists
	if not has_node("Terrain_Assets"):
		var asset_container := Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			asset_container.set_owner(get_tree().edited_scene_root)

	var expected_total_chunks: int = world_chunks.x * world_chunks.y
	if chunk_activity_data.size() < expected_total_chunks:
		chunk_activity_data.resize(expected_total_chunks)
		chunk_activity_data.fill(1)

	_server_backend.prune_out_of_bounds(world_chunks)

	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var coord := Vector2i(cx, cz)

			# AT RUNTIME: Only register a chunk if it is active
			if is_chunk_active(cx, cz) or Engine.is_editor_hint():
				_server_backend.ensure_chunk(coord)

			_update_single_chunk(coord)


##@@

## Central entry point for TerrainBackend changes made through the inspector.
func _switch_terrain_backend(from_backend: TerrainBackend, to_backend: TerrainBackend) -> void:
	if to_backend == TerrainBackend.SERVERS:
		_activate_server_backend(true)
	else:
		_activate_mesh_node_backend()


## Brings the RenderingServer / PhysicsServer3D pipeline online. Height data is never written
## during this, so the switch is lossless in both directions.
func _activate_server_backend(remove_baked_collisions: bool) -> void:
	# Chunk nodes are RAM-only (added without set_owner), so freeing them loses nothing that
	# is not fully reproducible from global_height_data.
	var dynamic_collision_name: String = name + "_Collisions"
	for child in get_children():
		if child.name == "DEBUG_BrushGizmo_Transient" or child.name == dynamic_collision_name \
		or child.name == "Terrain_Assets" or child.name == CHUNK_GRID_NODE_NAME:
			continue
		if child is LowPolyTerrainChunk:
			child.free()
	chunks_dict.clear()

	# PhysicsServer3D bodies cannot join a SceneTree group, so the manager joins it on their
	# behalf. Combined with body_attach_object_instance_id() this keeps existing game code
	# such as collider.is_in_group("Wall") working unchanged.
	_join_collision_group()

	# Off by default for performance, so a Node3D receives no transform notifications at all
	# unless it explicitly asks for them.
	set_notify_transform(true)

	if _server_backend == null:
		_server_backend = LowPolyTerrainServerBackend.new()
		_server_backend.setup(self)
	_server_backend.set_collision_policy(int(runtime_collision))
	_sync_collision_debug_draw()
	if _culling_handover_done:
		_server_backend.notify_culling_active()
	elif not Engine.is_editor_hint() and runtime_collision == RuntimeCollision.CULLED:
		# CULLED builds nothing on its own, so a game that forgets to drive the radius would
		# silently end up with terrain you fall straight through. Check back once and say so.
		_warn_if_culling_never_started.call_deferred()

	if is_inside_tree():
		_server_backend.attach_to_world(get_world_3d())
		_server_backend.on_transform_changed(global_transform)
		_server_backend.on_visibility_changed(is_visible_in_tree())

	rebuild_chunks_structure()

	if remove_baked_collisions:
		_delete_baked_collision_container()


## Returns to the classic MeshInstance3D pipeline and releases every server resource.
func _activate_mesh_node_backend() -> void:
	if _server_backend != null:
		_server_backend.destroy_all()
		_server_backend = null

	_leave_collision_group()
	set_notify_transform(false)

	rebuild_chunks_structure()


## Name of the editor-only chunk boundary grid overlay child.
const CHUNK_GRID_NODE_NAME := "Chunk_Grid"


## Creates, refreshes or removes the chunk boundary grid. A single MeshInstance3D holds the
## whole grid, so this is identical in both backends and costs one node in total. Deliberately
## never given an owner, so it stays out of the .tscn like every other RAM-only helper.
func _update_chunk_grid_overlay() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return

	var existing: Node = find_child(CHUNK_GRID_NODE_NAME, false, false)

	if not show_chunk_grid:
		if existing != null:
			existing.free()
		return

	var grid: MeshInstance3D = existing as MeshInstance3D
	if grid == null:
		if existing != null:
			existing.free()
		grid = MeshInstance3D.new()
		grid.name = CHUNK_GRID_NODE_NAME
		add_child(grid)

	grid.mesh = LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(
		world_chunks, chunk_size, cell_size
	)
	grid.material_override = LowPolyTerrainMeshBuilder.build_chunk_grid_material()
	grid.position = Vector3.ZERO
	grid.visible = true


## Resolves collision_debug_draw against Godot's debug flag and forwards it to the backend.
func _sync_collision_debug_draw() -> void:
	if _server_backend == null:
		return
	_server_backend.set_collision_debug_enabled(is_collision_debug_draw_active())


## True when the collider overlay should currently be drawn.
func is_collision_debug_draw_active() -> bool:
	match collision_debug_draw:
		CollisionDebugDraw.ALWAYS:
			return true
		CollisionDebugDraw.NEVER:
			return false
		_:
			# Set by running the project with Debug > Visible Collision Shapes enabled, which
			# is the same switch the node-based colliders react to.
			if not is_inside_tree() or get_tree() == null:
				return false
			return get_tree().debug_collisions_hint


## Adds this manager to the configured collision group so server bodies remain identifiable.
func _join_collision_group() -> void:
	var group_name: String = collision_group.strip_edges()
	if group_name.is_empty():
		return
	if not is_in_group(group_name):
		add_to_group(group_name, true)
	_joined_collision_group = group_name


## Leaves exactly the group that was joined earlier, even if collision_group changed meanwhile.
func _leave_collision_group() -> void:
	if _joined_collision_group.is_empty():
		return
	if is_in_group(_joined_collision_group):
		remove_from_group(_joined_collision_group)
	_joined_collision_group = ""


##@@

## Mirrors the node bookkeeping that a MeshInstance3D child would otherwise inherit for free.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_TRANSFORM_CHANGED:
			if _server_backend == null:
				return
			_server_backend.on_transform_changed(global_transform)

		NOTIFICATION_VISIBILITY_CHANGED:
			if _server_backend == null:
				return
			_server_backend.on_visibility_changed(is_visible_in_tree())

		NOTIFICATION_ENTER_WORLD:
			# Fires BEFORE _ready(), so on first load the backend does not exist yet and
			# _ready() is responsible for pushing world, transform and visibility instead.
			if _server_backend == null:
				return
			_server_backend.attach_to_world(get_world_3d())
			_server_backend.on_transform_changed(global_transform)
			_server_backend.on_visibility_changed(is_visible_in_tree())

		NOTIFICATION_EXIT_WORLD:
			if _server_backend == null:
				return
			_server_backend.detach_from_world()

		NOTIFICATION_PREDELETE:
			# The node is already being destroyed here. Touching get_tree(), global_transform
			# or get_world_3d() at this point is undefined, so only RIDs are released.
			if _server_backend != null:
				_server_backend.destroy_all()
				_server_backend = null


##@@

## Returns the coordinates of every chunk tracked by whichever backend is currently active.
func get_chunk_coords() -> Array:
	return _get_chunk_coords()


## Returns the renderable geometry of a chunk, or null when the chunk carries none.
func get_chunk_mesh(coord: Vector2i) -> ArrayMesh:
	if terrain_backend == TerrainBackend.SERVERS:
		return _server_backend.get_mesh(coord) if _server_backend != null else null
	if not chunks_dict.has(coord):
		return null
	var chunk: LowPolyTerrainChunk = chunks_dict[coord]
	return chunk.mesh as ArrayMesh if chunk else null


## Returns the world-space transform a chunk's geometry is rendered with.
func get_chunk_global_transform(coord: Vector2i) -> Transform3D:
	if terrain_backend == TerrainBackend.SERVERS:
		if _server_backend == null:
			return global_transform
		return global_transform * _server_backend.get_local_transform(coord)
	if not chunks_dict.has(coord):
		return global_transform
	var chunk: LowPolyTerrainChunk = chunks_dict[coord]
	return chunk.global_transform if chunk else global_transform


## Returns a chunk's offset inside this manager's local space.
func get_chunk_local_position(coord: Vector2i) -> Vector3:
	if terrain_backend == TerrainBackend.SERVERS:
		if _server_backend == null:
			return Vector3.ZERO
		return _server_backend.get_local_transform(coord).origin
	if not chunks_dict.has(coord):
		return Vector3.ZERO
	var chunk: LowPolyTerrainChunk = chunks_dict[coord]
	return chunk.position if chunk else Vector3.ZERO


## Returns the material a chunk renders with, or null when none is assigned.
func get_chunk_material(coord: Vector2i) -> Material:
	if terrain_backend == TerrainBackend.SERVERS:
		return custom_material
	if not chunks_dict.has(coord):
		return null
	var chunk: LowPolyTerrainChunk = chunks_dict[coord]
	return chunk.material_override if chunk else null


## [E3] Rebuilds the chunk structure only when it is actually missing or out of date.
## Selecting the manager in the editor used to trigger an unconditional full-world rebuild,
## which regenerates every single chunk mesh even though nothing changed.
func ensure_chunks_built() -> void:
	var expected: int = world_chunks.x * world_chunks.y
	if not Engine.is_editor_hint():
		# At runtime deactivated chunks are intentionally never instantiated.
		expected = 0
		for cz in range(world_chunks.y):
			for cx in range(world_chunks.x):
				if is_chunk_active(cx, cz):
					expected += 1

	if _get_chunk_coords().size() != expected:
		rebuild_chunks_structure()


## Backend-agnostic replacement for direct chunks_dict.keys() iteration.
func _get_chunk_coords() -> Array:
	if terrain_backend == TerrainBackend.SERVERS and _server_backend != null:
		return _server_backend.get_coords()
	return chunks_dict.keys()


## Backend-agnostic replacement for direct chunks_dict.has() lookups.
func _has_chunk(coord: Vector2i) -> bool:
	if terrain_backend == TerrainBackend.SERVERS and _server_backend != null:
		return _server_backend.has_chunk(coord)
	return chunks_dict.has(coord)


##@@

## Safely resolves the editor's history manager without leaking an Editor* static type into
## a script that also runs inside exported release builds.
func _fetch_undo_redo() -> Object:
	if not Engine.is_editor_hint():
		return null
	if _active_undo_redo_manager != null:
		return _active_undo_redo_manager
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei and ei.has_method("get_undo_redo"):
		_active_undo_redo_manager = ei.call("get_undo_redo")
	return _active_undo_redo_manager


## Removes the baked collider container, because the server bodies replace it entirely and
## keeping both alive would produce duplicated physics geometry. Registered as an undoable
## action so an accidental backend switch can be reverted with a single Ctrl+Z.
func _delete_baked_collision_container() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return

	var container: Node = parent.find_child(name + "_Collisions", false, false)
	if container == null:
		return

	var undo_redo: Object = _fetch_undo_redo()
	if undo_redo == null:
		parent.remove_child(container)
		container.queue_free()
		return

	# Captured before removal, because get_index() is meaningless once detached.
	var restore_index: int = container.get_index()

	undo_redo.create_action("Switch Terrain Backend (Remove Baked Collisions)", 0, self)
	undo_redo.add_do_method(parent, &"remove_child", container)
	undo_redo.add_undo_method(parent, &"add_child", container)
	undo_redo.add_undo_method(parent, &"move_child", container, restore_index)
	undo_redo.add_undo_method(self, &"_restore_scene_owner_recursive", container)
	# The history owns the detached subtree while the action is undone.
	undo_redo.add_undo_reference(container)
	undo_redo.commit_action()


##@@
# =====================================================================================
# DISTANCE BASED COLLISION CULLING
# The chunk grid is regular, so the set of chunks near the player can be derived
# arithmetically instead of measuring the distance to every collider. That turns culling
# from O(all chunks) into O(chunks inside the radius) and removes the need to amortize
# the work across frames, which in turn removes the reaction delay that amortization costs.
# =====================================================================================

## Coordinates whose collision is currently enabled. Only the delta against this set is ever
## pushed to the physics engine.
var _culling_enabled: Dictionary = {}

## Reused buffer for the set being collected, swapped with _culling_enabled on commit so a
## per-frame pass allocates nothing.
var _culling_scratch: Dictionary = {}

## Chunk cell each target occupied last time, so the pass can be skipped entirely while nobody
## has crossed a chunk boundary. Aligned index-by-index with collision_cull_targets.
var _cull_target_cells: Array[Vector2i] = []

## Reused buffer for the target world positions handed to update_collision_culling_multi().
var _cull_target_positions: Array[Vector3] = []

## True while the assigned targets own the enabled set, so dropping the last one knows to
## release it instead of leaving a manually driven set alone.
var _culling_driven_by_targets: bool = false

## Cached coord -> CollisionShape3D map for the baked MESH_NODES collider container.
var _culling_shape_cache: Dictionary = {}
var _culling_cached_container: Node = null

## True once update_collision_culling() has run, which is the point where the radius takes
## over responsibility for collider lifetime.
var _culling_handover_done: bool = false


## Enables physics only for the chunks intersecting the given world-space sphere and disables
## every chunk that just left it. Backend-agnostic: MESH_NODES toggles CollisionShape3D.disabled
## on the baked Static_Chunk_X_Y bodies, SERVERS toggles the registered body RIDs.
##
## Call this once per physics frame with the player position. There is no internal throttling,
## because the cost already scales with the radius rather than with the world size.
func update_collision_culling(world_pos: Vector3, radius_meters: float) -> void:
	if is_zero_approx(float(chunk_size) * cell_size) or radius_meters < 0.0:
		return
	_begin_culling_pass()
	_collect_chunks_in_radius(world_pos, radius_meters, _culling_scratch)
	_commit_culling_set()


## Same as update_collision_culling(), but for several targets at once: the enabled set is the
## union of all their radii, so split-screen players or companion NPCs each keep ground.
func update_collision_culling_multi(world_positions: Array, radius_meters: float) -> void:
	if is_zero_approx(float(chunk_size) * cell_size) or radius_meters < 0.0:
		return
	if world_positions.is_empty():
		return
	_begin_culling_pass()
	for world_pos: Vector3 in world_positions:
		_collect_chunks_in_radius(world_pos, radius_meters, _culling_scratch)
	_commit_culling_set()


func _begin_culling_pass() -> void:
	if not _culling_handover_done:
		_culling_handover_done = true
		if _server_backend != null:
			_server_backend.notify_culling_active()

		# Seed the bookkeeping with everything that is currently switched ON, because that is
		# the true starting state: baked MESH_NODES colliders and SERVERS bodies under the ALL
		# policy all begin enabled. Without this the very first pass compares against an empty
		# set, so it can only ever ADD chunks and never disables the ones outside the radius -
		# leaving the whole terrain collidable until a target happens to walk through a chunk
		# and back out of it again.
		_seed_culling_state_from_current_colliders()

	_culling_scratch.clear()


## Records every chunk that presently owns enabled collision, so the first culling pass has a
## truthful baseline to diff against.
func _seed_culling_state_from_current_colliders() -> void:
	_culling_enabled.clear()
	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			if not is_chunk_active(cx, cz):
				continue
			var coord := Vector2i(cx, cz)
			if _chunk_collision_is_enabled(coord):
				_culling_enabled[coord] = true


## True when the chunk currently has collision the culling would have to switch off.
func _chunk_collision_is_enabled(coord: Vector2i) -> bool:
	if terrain_backend == TerrainBackend.SERVERS:
		# Under CULLED nothing exists yet, so there is nothing to switch off either.
		return _server_backend != null and _server_backend.has_body(coord)

	var shape: CollisionShape3D = _find_baked_collision_shape(coord)
	return shape != null and not shape.disabled


## Adds every active chunk intersecting the given world-space sphere into `out`.
func _collect_chunks_in_radius(world_pos: Vector3, radius_meters: float, out: Dictionary) -> void:
	var meters_per_chunk: float = float(chunk_size) * cell_size
	var local_pos: Vector3 = to_local(world_pos)

	# Transpose Z into positive grid space matching the layout orientation
	var grid_center_z: float = -local_pos.z

	var min_cx: int = clampi(
		floori((local_pos.x - radius_meters) / meters_per_chunk), 0, world_chunks.x - 1)
	var max_cx: int = clampi(
		floori((local_pos.x + radius_meters) / meters_per_chunk), 0, world_chunks.x - 1)
	var min_cz: int = clampi(
		floori((grid_center_z - radius_meters) / meters_per_chunk), 0, world_chunks.y - 1)
	var max_cz: int = clampi(
		floori((grid_center_z + radius_meters) / meters_per_chunk), 0, world_chunks.y - 1)

	var radius_squared: float = radius_meters * radius_meters

	# Same closest-point-on-AABB test that set_chunk_status_in_radius() already uses, so brush
	# radius and culling radius agree on what "inside" means.
	for cz in range(min_cz, max_cz + 1):
		for cx in range(min_cx, max_cx + 1):
			if not is_chunk_active(cx, cz):
				continue

			var chunk_min_x: float = float(cx) * meters_per_chunk
			var chunk_max_x: float = float(cx + 1) * meters_per_chunk
			var chunk_min_z: float = float(cz) * meters_per_chunk
			var chunk_max_z: float = float(cz + 1) * meters_per_chunk

			var closest_x: float = clampf(local_pos.x, chunk_min_x, chunk_max_x)
			var closest_z: float = clampf(grid_center_z, chunk_min_z, chunk_max_z)

			var dist_x: float = local_pos.x - closest_x
			var dist_z: float = grid_center_z - closest_z

			if (dist_x * dist_x) + (dist_z * dist_z) <= radius_squared:
				out[Vector2i(cx, cz)] = true


## Pushes only the delta between the freshly collected set and the currently enabled one.
func _commit_culling_set() -> void:
	for coord: Vector2i in _culling_enabled:
		if not _culling_scratch.has(coord):
			_set_chunk_collision_enabled(coord, false)

	for coord: Vector2i in _culling_scratch:
		if not _culling_enabled.has(coord):
			_set_chunk_collision_enabled(coord, true)

	# Swapped rather than assigned, so both dictionaries stay alive and get reused. This pass
	# can run every physics frame, and allocating a fresh dictionary each time would be waste.
	var previous: Dictionary = _culling_enabled
	_culling_enabled = _culling_scratch
	_culling_scratch = previous
	_culling_scratch.clear()


## One-shot diagnostic for the CULLED policy, which produces no collision until the game
## starts reporting a radius. Waits a moment so a caller wiring this up in _ready() or in the
## first _physics_process() is not falsely accused.
func _warn_if_culling_never_started() -> void:
	if not is_inside_tree() or get_tree() == null:
		return
	await get_tree().create_timer(2.0).timeout

	if not is_instance_valid(self) or _culling_handover_done:
		return
	if terrain_backend != TerrainBackend.SERVERS:
		return
	if runtime_collision != RuntimeCollision.CULLED:
		return
	# Targets drive the culling automatically, so their presence is not a misconfiguration.
	if not collision_cull_targets.is_empty():
		return

	push_warning("LowPolyTerrain '%s': runtime_collision is CULLED but " % name
		+ "update_collision_culling() has never been called, so this terrain currently has no "
		+ "collision at all. Call it once per physics frame with the player position, or "
		+ "switch runtime_collision to ALL.")


##@@
# --- AUTOMATIC CULLING TARGETS ---


## Registers a node for collision culling. Use this for players created at runtime, which an
## inspector reference cannot reach.
func add_culling_target(target: Node3D) -> void:
	if target == null or collision_cull_targets.has(target):
		return
	collision_cull_targets.append(target)
	_cull_target_cells.clear()
	_refresh_culling_target_state()


## Stops following a node. Chunks it was keeping alive are released on the next pass.
func remove_culling_target(target: Node3D) -> void:
	var index: int = collision_cull_targets.find(target)
	if index < 0:
		return
	collision_cull_targets.remove_at(index)
	_cull_target_cells.clear()
	_refresh_culling_target_state()


## Enables the per-frame pass only while it can actually do something, and never in the editor.
func _refresh_culling_target_state() -> void:
	if not is_inside_tree() or not is_node_ready():
		return

	# A @tool script receives _physics_process inside the editor too. Guarding the body would
	# still pay the call 60 times a second, so the callback is switched off outright.
	if Engine.is_editor_hint():
		set_physics_process(false)
		return

	var has_target: bool = false
	for target in collision_cull_targets:
		if is_instance_valid(target):
			has_target = true
			break

	set_physics_process(has_target)

	if not has_target:
		# Losing the last target must hand the chunks back, otherwise whatever it was keeping
		# alive would stay resident for the rest of the session. Only touched when the targets
		# were actually driving, so a manually driven set is never stomped.
		if _culling_driven_by_targets:
			_culling_driven_by_targets = false
			_begin_culling_pass()
			_commit_culling_set()
		return

	_culling_driven_by_targets = true
	_warn_on_culling_policy_mismatch()

	# Build the initial set immediately. Waiting for the first _physics_process would risk the
	# target being stepped before the manager, leaving it one frame without ground under it.
	_run_culling_from_targets(true)


## Follows the assigned targets. Skips the whole pass while none of them has crossed a chunk
## boundary, because the resulting set cannot have changed in that case.
func _physics_process(_delta: float) -> void:
	_run_culling_from_targets(false)


func _run_culling_from_targets(force: bool) -> void:
	if collision_cull_targets.is_empty():
		return

	var meters_per_chunk: float = float(chunk_size) * cell_size
	if is_zero_approx(meters_per_chunk):
		return

	if _cull_target_cells.size() != collision_cull_targets.size():
		_cull_target_cells.clear()
		_cull_target_cells.resize(collision_cull_targets.size())
		force = true

	# First pass is allocation free and usually ends here: it only reads transforms.
	var changed: bool = force
	var any_valid: bool = false

	for i in range(collision_cull_targets.size()):
		var target: Node3D = collision_cull_targets[i]
		if not is_instance_valid(target) or not target.is_inside_tree():
			continue
		any_valid = true

		var local_pos: Vector3 = to_local(target.global_position)
		var cell := Vector2i(
			floori(local_pos.x / meters_per_chunk),
			floori(-local_pos.z / meters_per_chunk)
		)
		if _cull_target_cells[i] != cell:
			_cull_target_cells[i] = cell
			changed = true

	if not any_valid or not changed:
		return

	var radius: float = collision_cull_radius
	if radius <= 0.0:
		radius = _derive_cull_radius()

	_cull_target_positions.clear()
	for target in collision_cull_targets:
		if is_instance_valid(target) and target.is_inside_tree():
			_cull_target_positions.append(target.global_position)

	update_collision_culling_multi(_cull_target_positions, radius)


func _derive_cull_radius() -> float:
	return float(chunk_size) * cell_size * 2.0


## Pre-fills collision_cull_radius from the terrain dimensions, leaving a manual override alone.
func _apply_derived_cull_radius() -> void:
	var derived: float = _derive_cull_radius()
	if is_zero_approx(collision_cull_radius) \
	or is_equal_approx(collision_cull_radius, _derived_cull_radius):
		collision_cull_radius = derived
	_derived_cull_radius = derived


## Points out target setups that cannot do what they look like they are doing.
func _warn_on_culling_policy_mismatch() -> void:
	if terrain_backend != TerrainBackend.SERVERS:
		return

	if runtime_collision == RuntimeCollision.ALL:
		push_warning("LowPolyTerrain '%s': culling targets are assigned, but " % name
			+ "runtime_collision is ALL, so every chunk keeps its collider and the culling "
			+ "only toggles them. Switch to CULLED to actually reclaim the memory.")
	elif runtime_collision == RuntimeCollision.NONE:
		push_warning("LowPolyTerrain '%s': culling targets are assigned, but " % name
			+ "runtime_collision is NONE, so there is no collision to cull at all.")


##@@

## Releases the culling bookkeeping and hands collider lifetime back to the active policy.
func reset_collision_culling() -> void:
	_culling_enabled.clear()
	_culling_shape_cache.clear()
	_culling_cached_container = null
	_culling_handover_done = false

	if terrain_backend == TerrainBackend.SERVERS and _server_backend != null:
		# Rebuild whatever the policy asks for now that no radius is constraining it.
		for coord: Vector2i in _get_chunk_coords():
			if runtime_collision == RuntimeCollision.NONE:
				_server_backend.release_chunk_collision(coord)
			else:
				_server_backend.ensure_chunk_collision(coord)
		return

	for coord: Vector2i in _get_chunk_coords():
		var shape: CollisionShape3D = _find_baked_collision_shape(coord)
		if shape != null:
			shape.set_deferred(&"disabled", false)


func _set_chunk_collision_enabled(coord: Vector2i, enabled: bool) -> void:
	if terrain_backend == TerrainBackend.SERVERS:
		if _server_backend != null:
			_server_backend.set_chunk_collision_enabled(coord, enabled)
		return

	var shape: CollisionShape3D = _find_baked_collision_shape(coord)
	if shape != null:
		shape.set_deferred(&"disabled", not enabled)


## Resolves the baked CollisionShape3D of a chunk, caching the lookup because the container
## only changes when collisions are re-baked.
func _find_baked_collision_shape(coord: Vector2i) -> CollisionShape3D:
	var parent: Node = get_parent()
	if parent == null:
		return null

	var container: Node = parent.find_child(name + "_Collisions", false, false)
	if container == null:
		_culling_shape_cache.clear()
		_culling_cached_container = null
		return null

	if container != _culling_cached_container:
		_culling_shape_cache.clear()
		_culling_cached_container = container

	if _culling_shape_cache.has(coord):
		var cached: CollisionShape3D = _culling_shape_cache[coord]
		return cached if is_instance_valid(cached) else null

	var body: Node = container.find_child("Static_Chunk_%d_%d" % [coord.x, coord.y], false, false)
	var shape: CollisionShape3D = null
	if body != null:
		# Resolved by TYPE rather than by name on purpose. Newly baked shapes are called
		# "Chunk_<x>_<z>_Col", while scenes baked before that rename still carry the old
		# "CollisionShape3D", and both have to keep working.
		for child in body.get_children():
			if child is CollisionShape3D:
				shape = child
				break
	_culling_shape_cache[coord] = shape
	return shape


##@@

## Re-assigns scene ownership across a restored subtree so it saves back into the .tscn.
func _restore_scene_owner_recursive(node: Node) -> void:
	if not Engine.is_editor_hint() or node == null:
		return
	if not is_inside_tree() or get_tree() == null:
		return
	var scene_root: Node = get_tree().edited_scene_root
	if scene_root == null:
		return
	node.set_owner(scene_root)
	for child in node.get_children():
		_restore_scene_owner_recursive(child)
