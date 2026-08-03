@tool
extends Node3D
class_name LowPolyTerrainManager

## Master controller script that handles seamless height coordinates, multi-chunk modification,
## multi-pass smoothing operations, and automated static collision baking.

## signals
signal signal_brush_settings_changed
## Signal to notify the editor plugin when the user requests a terrain export.
signal signal_export_requested
## Raised when applying the dimensions would discard terrain, so the editor plugin can ask
## first. Carries how many chunks would be lost. Nothing happens until the answer comes back
## through apply_dimension_changes_confirmed().
signal signal_shrink_confirmation_requested(lost_chunks: int)

# Centralized structural constants for advanced Inspector paths
const GROUP_DIMENSIONS := "World Dimensions (Requires Apply)"
const SUBGROUP_METRICS := "Calculated Metrics (Read-Only)"

const PROP_SIZE_METERS := "total_size_meters"
const PROP_TOTAL_VERTICES := "total_vertices"

# Dynamic concatenation to prevent hardcoded duplicate string literals
const PATH_SIZE_METERS := GROUP_DIMENSIONS + "/" + SUBGROUP_METRICS + "/" + PROP_SIZE_METERS
const PATH_TOTAL_VERTICES := GROUP_DIMENSIONS + "/" + SUBGROUP_METRICS + "/" + PROP_TOTAL_VERTICES

# Centralized terrain sculpting and chunk state tools
# Values 0..5 are STORED in scenes through tool_mode, so they must never be renumbered.
# RAMP was appended as 6 and the two plugin-internal helpers moved up accordingly; those two
# never reach tool_mode, because the shortcut handler acts on them and returns before the
# selection is written.
enum BrushMode {
	RAISE = 0,
	LOWER = 1,
	FLATTEN = 2,
	SMOOTH = 3,
	ACTIVATE_CHUNK = 4,
	DEACTIVATE_CHUNK = 5,
	RAMP = 6,
	PAINT = 7,
	NO_FURTHER_BUTTONS = 7,
	DECREASE_BRUSH_RADIUS = 8,
	INCREASE_BRUSH_RADIUS = 9
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



## Settings that only ever take effect for TerrainBackend.SERVERS.
const SERVER_ONLY_PROPERTIES: PackedStringArray = [
	"runtime_collision",
	"collision_debug_draw",
]

## Settings that only ever take effect for TerrainBackend.MESH_NODES.
const MESH_NODES_ONLY_PROPERTIES: PackedStringArray = [
	"bake_collisions_button",
]

## Settings that additionally require RuntimeCollision.LAZY, because they govern colliders
## being built and released - which is the only mode where that happens at all.
const LAZY_ONLY_PROPERTIES: PackedStringArray = [
	"collision_retain_limit",
]

## The four per-layer slope ranges, indexed by layer number. Only the selected one is shown.
const PAINT_SLOPE_PROPERTIES: PackedStringArray = [
	"paint_layer_1_slope",
	"paint_layer_2_slope",
	"paint_layer_3_slope",
	"paint_layer_4_slope",
]

## Settings that only describe HOW the culling follows its targets, and therefore only mean
## anything once enable_collision_culling is on.
const CULLING_ONLY_PROPERTIES: PackedStringArray = [
	"collision_cull_targets",
	"collision_cull_radius",
]


## Hides the settings belonging to the other backend. They stay stored, they just stop
## advertising themselves in a mode where they genuinely cannot do anything - which is
## otherwise easy to misread as the setting being broken.
func _validate_property(property: Dictionary) -> void:
	var name: String = property["name"]
	var hidden: bool = false

	if terrain_backend == TerrainBackend.SERVERS:
		hidden = MESH_NODES_ONLY_PROPERTIES.has(name)
		# A second axis: some settings only mean anything while colliders are actually being
		# built and released, which is what LAZY does and the other policies do not.
		if not hidden and runtime_collision != RuntimeCollision.LAZY:
			hidden = LAZY_ONLY_PROPERTIES.has(name)
	else:
		hidden = SERVER_ONLY_PROPERTIES.has(name) or LAZY_ONLY_PROPERTIES.has(name)

	# A third axis, independent of the backend: the culling works in both of them.
	if not hidden and not enable_collision_culling:
		hidden = CULLING_ONLY_PROPERTIES.has(name)

	# And a fourth: four slope ranges exist, but showing all of them at once would bury the one
	# that matters under three that do not. They stay stored either way.
	if not hidden and PAINT_SLOPE_PROPERTIES.has(name):
		hidden = name != PAINT_SLOPE_PROPERTIES[clampi(paint_layer - 1, 0, PAINT_LAYER_COUNT - 1)]

	if hidden:
		# Clear ONLY the editor bit. Assigning PROPERTY_USAGE_NO_EDITOR outright would replace
		# the whole mask and drop PROPERTY_USAGE_SCRIPT_VARIABLE with it, at which point the
		# .tscn loader discards the stored value and the property silently falls back to its
		# default on every scene load.
		property["usage"] = int(property["usage"]) & ~PROPERTY_USAGE_EDITOR


## Triggers an instant inspector refresh to update calculated read-only size metrics
## in real-time.
func _update_read_only_metrics() -> void:
	if Engine.is_editor_hint():
		notify_property_list_changed()




# Noise and smoothing share a group because they are usually used in sequence: scatter
# detail, then take the harshness back out of it.
@export_group("Noise and Smooth")
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

## Which paint layer the Paint brush deposits, 1 to 4.
##
## The layers live in the four channels of the vertex colour; whatever they leave unused belongs
## to the base material, so an unpainted terrain shows the base alone. Hold Shift while painting
## to wipe back towards it.
@export_range(1, 4, 1) var paint_layer: int = 1:
	set(v):
		paint_layer = v
		# Only the selected layer's slope range is shown, so the list has to be re-read.
		notify_property_list_changed()

## Range of surface angles the selected layer may be painted on, in degrees.
##
## Zero is level ground, ninety is a vertical wall. The default spans everything, so the filter
## is off until you narrow it. Rock between 35 and 90, sand between 0 and 12, scree in between -
## then you can sweep the brush across a whole hillside and each layer lands where it belongs.
##
## Per layer rather than global, so a stroke needs no aiming. Only the range of the layer you
## are painting with is shown; the other three are still there and still stored.
##
## Erasing ignores this entirely: Shift must always be able to clean up, including where the
## filter currently lets nothing through.
@export_custom(PROPERTY_HINT_RANGE, "0,90,0.5,degrees")
var paint_layer_1_slope: Vector2 = Vector2(0.0, 90.0)

@export_custom(PROPERTY_HINT_RANGE, "0,90,0.5,degrees")
var paint_layer_2_slope: Vector2 = Vector2(0.0, 90.0)

@export_custom(PROPERTY_HINT_RANGE, "0,90,0.5,degrees")
var paint_layer_3_slope: Vector2 = Vector2(0.0, 90.0)

@export_custom(PROPERTY_HINT_RANGE, "0,90,0.5,degrees")
var paint_layer_4_slope: Vector2 = Vector2(0.0, 90.0)

## How far beyond the range above the layer fades out, in degrees.
##
## The range itself is painted at full strength; this is the run-out past its edges. Zero gives
## a hard contour line across the terrain, which on faceted geometry is very visible.
##
## Global rather than per layer: it describes how sharp your transitions look, which is a
## property of the terrain rather than of one material.
@export_range(0.0, 45.0, 0.5, "degrees") var paint_slope_feather: float = 6.0


## Draws the painted layers on top of whatever custom_material produces.
##
## An OVERLAY, not a replacement: your terrain shader keeps doing everything it does - slope
## blending, triplanar cliffs, noise - and the painted layers are blended over the result. That
## is why painting works with any base material, not only with the ones shipped here.
##
## Left empty, a copy of the bundled overlay shader is created on the first stroke, so the four
## layer colours and roughness values belong to this terrain alone. Assign your own to share one
## look across several terrains. Only applied while something is actually painted.
##
## For a single draw call, and for blending the material PROPERTIES rather than the lit results,
## include terrain_paint.gdshaderinc in your own shader instead and clear this slot.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ShaderMaterial") var paint_material: Material = null:
	set(v):
		paint_material = v
		_queue_setup()


@export_group("Collision Generation")

## Controls how much collision the SERVERS backend keeps resident at runtime.
enum RuntimeCollision {
	LAZY = 0,     ## A collider is created the first time a target comes near the chunk.
	PREBUILT = 1, ## Every active chunk has a collider from the start; the radius only
				  ## switches them on and off (default).
	NONE = 2,     ## No runtime collision at all.
}

## SERVERS BACKEND ONLY. Under MESH_NODES this setting does nothing at all, which is why the
## inspector hides it there rather than offering a choice that cannot take effect.
##
## The reason is that the two backends obtain their collision from different places. SERVERS
## creates PhysicsServer3D bodies itself, so it can decide when to do so - that is what this
## setting picks. MESH_NODES has no such step: its collision consists of StaticBody3D nodes
## produced by the Bake Live Collisions button, and those exist from the moment you bake them.
##
## Collision CULLING is a separate question and works in both backends: it enables and disables
## whatever colliders exist. Only their creation is what this setting governs.
##
## Decides WHEN a chunk's collider is created, which is a trade of frame time against memory.
##
## PREBUILT creates all of them up front. Memory scales with the total chunk count and the
## per-frame cost is nil, since the culling radius then only switches colliders on and off.
## This mirrors what a baked MESH_NODES terrain does, minus the nodes.
##
## LAZY creates a collider the first time a target comes near the chunk. Memory scales with
## the region actually reached rather than the whole world, which is what makes very large
## terrains feasible. The price is that a first visit has to construct a concave shape and its
## acceleration structure, and that happens inside the physics step - so a target crossing
## many new chunks per second produces noticeable spikes. Revisits are cheap, because a chunk
## leaving the radius is parked rather than destroyed; see collision_retain_limit.
##
## PREBUILT is the default: it is the predictable choice, and LAZY only pays off once the
## terrain is large enough that holding every collider becomes the actual constraint.
##
## A game using LAZY MUST drive the culling, either through collision_cull_targets or by
## calling update_collision_culling() itself, or the terrain will have no collision at all.
@export var runtime_collision: RuntimeCollision = RuntimeCollision.PREBUILT:
	set(v):
		runtime_collision = v
		if _server_backend != null:
			_server_backend.set_collision_policy(int(v))
		# collision_retain_limit only applies to LAZY, so the inspector has to re-check.
		notify_property_list_changed()

## How many colliders outside the culling radius stay built but switched off.
##
## `LAZY` only pays for a chunk the first time it is reached. Afterwards a chunk leaving the
## radius is parked rather than destroyed, so returning to it costs a fraction of a microsecond
## instead of a full rebuild - which matters because a target moving through the world crosses
## the same chunks again and again.
##
## Parked colliders take part in no collision test, they only hold their memory. This value
## caps how many may do so; beyond it the least recently parked one is genuinely released.
## Raise it for a target that roams a small area, lower it when memory is the tighter
## constraint. Zero restores the old behaviour of releasing immediately.
##
## Only relevant for `SERVERS` with `RuntimeCollision.LAZY`.
@export_range(0, 512, 1) var collision_retain_limit: int = 64


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
## Useful mainly for watching RuntimeCollision.LAZY work: only the chunks that currently own
## a collider light up, so the culling radius becomes directly visible.
##
## The overlay costs extra line geometry per visible chunk, so leave it off when profiling.
@export var collision_debug_draw: CollisionDebugDraw = CollisionDebugDraw.FOLLOW_DEBUG_MENU:
	set(v):
		collision_debug_draw = v
		_sync_collision_debug_draw()

## Lets the manager keep collision loaded around moving targets instead of everywhere at once.
##
## The targets and the radius below only mean anything while this is on, so they are hidden
## when it is off. Turning it off does not clear either of them, and any chunk the culling was
## holding is handed back on the next frame.
##
## Defaults to on, which is what every scene did before this switch existed. Untick it to take
## the two settings out of the inspector on a terrain that has no use for them.
##
## Independent of runtime_collision, which decides WHEN a collider is built. This decides
## WHERE. Manual update_collision_culling() calls work regardless of this setting.
@export var enable_collision_culling: bool = true:
	set(v):
		enable_collision_culling = v
		# The two settings below appear and disappear with this one.
		notify_property_list_changed()
		_refresh_culling_target_state()

## Nodes the collision culling should follow, typically the player's CharacterBody3D.
##
## While at least one valid target is assigned the manager drives update_collision_culling()
## itself once per physics frame, so RuntimeCollision.LAZY needs no glue code at all. The
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
@export_flags_3d_physics var collision_layer: int = 2:
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


## Extends the activity array to cover the current world size, defaulting only the entries
## that were not there before to active.
##
## The regular resize path is _migrate_grid_data(), which remaps every chunk by coordinate and
## is what "Apply Dimension Changes" uses. This is the safety net for an array that is short
## for some other reason, such as data written by an older version. Filling the whole array
## here instead would reactivate every chunk the user had deactivated.
func _grow_chunk_activity_data() -> void:
	var expected_total_chunks: int = world_chunks.x * world_chunks.y
	var previous_count: int = chunk_activity_data.size()
	if previous_count >= expected_total_chunks:
		return

	chunk_activity_data.resize(expected_total_chunks)
	for i in range(previous_count, expected_total_chunks):
		chunk_activity_data[i] = 1


# One quad and one material shared by every deactivated chunk. Both used to be rebuilt inline
# at two separate places, which allocated a fresh ArrayMesh and StandardMaterial3D per chunk
# and meant a geometry fix had to be applied three times to take effect everywhere.
var _preview_mesh_cache: ArrayMesh = null
var _preview_mesh_dims: Vector2 = Vector2.ZERO
var _preview_material_cache: StandardMaterial3D = null


## The flat red quad marking a deactivated chunk, rebuilt only when the dimensions change.
func _get_deactivated_preview_mesh() -> ArrayMesh:
	var dims := Vector2(float(chunk_size), cell_size)
	if _preview_mesh_cache == null or _preview_mesh_dims != dims:
		_preview_mesh_cache = LowPolyTerrainMeshBuilder.build_deactivated_preview_mesh(
			chunk_size, cell_size)
		_preview_mesh_dims = dims
	return _preview_mesh_cache


## The material for that quad. A single instance serves the whole terrain.
func _get_deactivated_preview_material() -> StandardMaterial3D:
	if _preview_material_cache == null:
		_preview_material_cache = LowPolyTerrainMeshBuilder.build_deactivated_preview_material()
	return _preview_material_cache


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
					# [SPARSE UNDO] Capture the previous state before overwriting it, exactly
					# like the sculpting brushes do. Only the first change per chunk and stroke
					# is recorded, so the entry always holds the pre-stroke value.
					if (Engine.is_editor_hint() or _active_undo_redo_manager != null) \
					and not _undo_activity_delta.has(index):
						_undo_activity_delta[index] = chunk_activity_data[index]

					chunk_activity_data[index] = target_value

					# Direct update of the changed without global rebuild
					var coord := Vector2i(cx, cz)
					if _has_chunk(coord):
						_update_single_chunk(coord)





# --- PERFORMANCE CRITICAL: Flattened array structure instead of Dictionary ---
@export_storage var global_height_data: PackedFloat32Array = PackedFloat32Array()

## Per-vertex paint weights, four bytes per grid point, indexed exactly like the heights above.
##
## The four bytes are the weights of paint layers 1 to 4; whatever is left over belongs to the
## base material. All zero therefore means "not painted", which is why an EMPTY array is a
## valid state and the default one: a terrain that was never painted stores nothing at all and
## renders exactly as it did before this feature existed.
@export_storage var global_paint_data: PackedByteArray = PackedByteArray()

## Number of distinct values a paint weight can take.
##
## Not a storage concern - a byte would hold 256. It exists so the mesh decimation can compare
## neighbouring weights for EQUALITY: an evenly painted area otherwise gives every grid point a
## slightly different value, nothing is ever "flat", and painting would cost the full vertex
## count even where the result is uniform.
##
## Set to 32 rather than the 8 the decimation alone would prefer. Eight steps left a soft edge
## with too few levels to read as a gradient, and worse, a per-pass deposit smaller than half a
## step rounded away to nothing on every pass, so the outer ring of a soft brush could never
## take any paint at all. The extra levels cost roughly a sixth more vertices on a soft stroke,
## measured, and buy an edge that is actually soft.
const PAINT_STEPS: int = 32

## How many layers can be painted on top of the base material. One per colour channel.
const PAINT_LAYER_COUNT: int = 4

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

## Same idea for the Activate/Deactivate Chunk brushes.
## Format: { chunk_index (int): old_activity (int) }
var _undo_activity_delta: Dictionary = {}

## Same idea for the Paint brush.
## Format: { byte offset of the grid point (int): the four bytes it held (PackedByteArray) }
var _undo_paint_delta: Dictionary = {}

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
	
	# Purge chunk nodes left over from a previous session. They are rebuilt from the height
	# matrix below, so dropping them loses nothing.
	#
	# Only LowPolyTerrainChunk children, deliberately. This loop used to free everything that
	# was not on a short list of known infrastructure names, which silently destroyed anything
	# a user had parented to the terrain - a spawn marker, a prop, a light - and it did so at
	# runtime too, because _ready() is not editor-only.
	for child in get_children():
		if child is LowPolyTerrainChunk:
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


## Highly optimized O(1) mutation method tailored for zero-latency brush sculpting.
func set_height_at(x: int, z: int, value: float) -> void:
	if x >= 0 and x < _total_vertices_x and z >= 0 and z < _total_vertices_z:
		global_height_data[z * _total_vertices_x + x] = value



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
## A larger cell_size reduces the error, because the slope per metre drops with it.
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
## Snapshot of the paint array taken before a dimension change rewrites the grid bounds.
## Held as a field rather than passed along, because the height migration already commits the
## new bounds before the paint can be remapped against the old ones.
var _paint_migration_source: PackedByteArray = PackedByteArray()


## Carries the paint across a dimension change, coordinate by coordinate.
##
## The array is indexed by row width, so growing or shrinking the world moves every point to a
## different slot - copying it verbatim would smear the paint diagonally across the terrain.
func _migrate_paint_data(old_vertices_x: int, old_vertices_z: int) -> void:
	if _paint_migration_source.is_empty():
		global_paint_data = PackedByteArray()
		return

	var migrated := PackedByteArray()
	migrated.resize(_total_vertices_x * _total_vertices_z * 4)

	for z in range(mini(_total_vertices_z, old_vertices_z)):
		for x in range(mini(_total_vertices_x, old_vertices_x)):
			var source: int = (z * old_vertices_x + x) * 4
			var target: int = (z * _total_vertices_x + x) * 4
			if source + 3 >= _paint_migration_source.size():
				continue
			for channel in range(4):
				migrated[target + channel] = _paint_migration_source[source + channel]

	global_paint_data = migrated
	_paint_migration_source = PackedByteArray()


## Path of the bundled overlay shader, instantiated when the Paint tool is first selected.
const PAINT_OVERLAY_SHADER: String = \
	"res://addons/lowpolyterrain/shader/terrain_paint_overlay.gdshader"

## Starting look of the four layers: sand, rock, snow, soil.
##
## These MIRROR the defaults written into terrain_paint.gdshaderinc, which exist so the shader
## still looks sensible when someone includes it by hand. Change one, change the other.
##
## The layers' DETAIL TEXTURE settings are deliberately absent. Mirroring exists only because
## something here has to read a value back - the brush ring tints itself with the layer colour -
## and nothing on this side ever asks about the textures. They keep the shader's own defaults,
## which start them switched off.
const PAINT_LAYER_DEFAULT_COLORS: PackedColorArray = [
	Color(0.76, 0.70, 0.50),
	Color(0.45, 0.45, 0.47),
	Color(0.95, 0.96, 1.00),
	Color(0.35, 0.26, 0.18),
]
const PAINT_LAYER_DEFAULT_ROUGHNESS: PackedFloat32Array = [0.85, 0.70, 0.25, 0.90]


## Returns the paint material, creating the bundled one if this terrain has none yet.
##
## Called when the Paint tool is SELECTED rather than when the first stroke lands: the layer
## colours are what you want to set up before painting, and an empty slot in the inspector gives
## you nothing to set up. Stored on this terrain, so its four layers are its own.
func ensure_paint_material() -> Material:
	if paint_material != null:
		return paint_material

	var shader: Shader = load(PAINT_OVERLAY_SHADER) as Shader
	if shader == null:
		push_warning("LowPolyTerrain '%s': the bundled paint overlay shader is missing at %s."
			% [name, PAINT_OVERLAY_SHADER])
		return null

	var created := ShaderMaterial.new()
	created.shader = shader

	# Written out rather than left to the shader's own defaults, because Godot exposes no way to
	# READ those back: get_shader_parameter() reports null for anything not explicitly set, and
	# the RenderingServer route needs a compiled shader. The brush ring has to know the layer
	# colour to tint itself with, so the values have to exist as parameters.
	for layer in range(PAINT_LAYER_COUNT):
		created.set_shader_parameter(
			"paint_layer_%d_color" % (layer + 1), PAINT_LAYER_DEFAULT_COLORS[layer]
		)
		created.set_shader_parameter(
			"paint_layer_%d_roughness" % (layer + 1), PAINT_LAYER_DEFAULT_ROUGHNESS[layer]
		)

	paint_material = created
	return paint_material


## The overlay to actually draw with, or null while there is nothing painted.
##
## Deliberately separate from ensure_paint_material(): the material may exist so its layers can
## be configured, while the overlay is still not worth hanging on the chunks. An overlay that
## discards every fragment costs a second pass over the whole terrain for no result.
func get_active_paint_material() -> Material:
	return paint_material if has_paint_data() else null


## The configured colour of one paint layer, 1 to 4. Falls back to white when the material does
## not carry the uniform, which is the case for a hand-written shader that only implements some
## of them.
func get_paint_layer_color(layer: int) -> Color:
	var shader_material: ShaderMaterial = paint_material as ShaderMaterial
	if shader_material == null:
		return Color.WHITE

	var index: int = clampi(layer, 1, PAINT_LAYER_COUNT)
	var value: Variant = shader_material.get_shader_parameter("paint_layer_%d_color" % index)
	if value is Color:
		return value

	# Unset means either a hand-written shader that omits this uniform, or a material built
	# without ensure_paint_material(). Falling back to the shipped default beats reporting a
	# colour the brush would then wrongly advertise.
	return PAINT_LAYER_DEFAULT_COLORS[index - 1]


## True once anything has been painted. An unpainted terrain keeps an empty array, so this is
## also the cheap way to skip every paint-related code path entirely.
func has_paint_data() -> bool:
	return not global_paint_data.is_empty()


## Allocates the paint array on first use. Deliberately not done in _ready(): a terrain that is
## never painted should not carry a second full-size array in its scene file.
func _ensure_paint_data() -> void:
	var required: int = _total_vertices_x * _total_vertices_z * 4
	if required <= 0:
		return
	if global_paint_data.size() == required:
		return

	var previous: PackedByteArray = global_paint_data
	global_paint_data = PackedByteArray()
	global_paint_data.resize(required)
	# resize() zero-fills, which is exactly "unpainted", so only an existing array needs copying.
	if not previous.is_empty():
		var shared: int = mini(previous.size(), required)
		for i in range(shared):
			global_paint_data[i] = previous[i]


## The four layer weights at a grid point, as a Color in the 0..1 range the mesh expects.
func get_paint_at(x: int, z: int) -> Color:
	if global_paint_data.is_empty():
		return Color(0.0, 0.0, 0.0, 0.0)
	if x < 0 or x >= _total_vertices_x or z < 0 or z >= _total_vertices_z:
		return Color(0.0, 0.0, 0.0, 0.0)

	var base: int = (z * _total_vertices_x + x) * 4
	var scale: float = 1.0 / float(PAINT_STEPS - 1)
	return Color(
		float(global_paint_data[base]) * scale,
		float(global_paint_data[base + 1]) * scale,
		float(global_paint_data[base + 2]) * scale,
		float(global_paint_data[base + 3]) * scale
	)


## Writes the four layer weights at a grid point, quantised and normalised.
##
## Normalised because the base material occupies whatever the four layers leave unused: letting
## them sum past 1 would drive the base out entirely and make the last stroke win rather than
## blend, which is not what a weight is.
func set_paint_at(x: int, z: int, weights: Color) -> void:
	if x < 0 or x >= _total_vertices_x or z < 0 or z >= _total_vertices_z:
		return
	_ensure_paint_data()
	if global_paint_data.is_empty():
		return

	var r: float = maxf(weights.r, 0.0)
	var g: float = maxf(weights.g, 0.0)
	var b: float = maxf(weights.b, 0.0)
	var a: float = maxf(weights.a, 0.0)

	var total: float = r + g + b + a
	if total > 1.0:
		r /= total
		g /= total
		b /= total
		a /= total

	var top: int = PAINT_STEPS - 1
	var steps: PackedInt32Array = [
		clampi(roundi(r * float(top)), 0, top),
		clampi(roundi(g * float(top)), 0, top),
		clampi(roundi(b * float(top)), 0, top),
		clampi(roundi(a * float(top)), 0, top),
	]

	# Normalising in floats is not enough: each channel then rounds up independently and the
	# sum creeps back past the limit. Trimming the largest channel repairs that in the domain
	# the values are actually stored in. At most three passes - four channels can exceed the
	# limit by at most three steps once each was individually clamped to it.
	var total_steps: int = steps[0] + steps[1] + steps[2] + steps[3]
	while total_steps > top:
		var largest: int = 0
		for channel in range(1, 4):
			if steps[channel] > steps[largest]:
				largest = channel
		steps[largest] -= 1
		total_steps -= 1

	var base: int = (z * _total_vertices_x + x) * 4
	for channel in range(4):
		global_paint_data[base + channel] = steps[channel]


## Bilinearly samples the height matrix at fractional GRID coordinates, in LOCAL units.
##
## Shared by the world-space query and by the ramp tool so both read the surface the same way.
## Coordinates outside the grid are clamped to the border rather than rejected: the cell origin
## stops one short of the last vertex so the +1 neighbours stay in range, and the interpolation
## factors then carry the clamping.
func sample_grid_height(grid_x: float, grid_z: float) -> float:
	if _total_vertices_x <= 0 or _total_vertices_z <= 0 or global_height_data.is_empty():
		return 0.0

	var x0: int = clampi(floori(grid_x), 0, maxi(_total_vertices_x - 2, 0))
	var z0: int = clampi(floori(grid_z), 0, maxi(_total_vertices_z - 2, 0))
	var x1: int = mini(x0 + 1, _total_vertices_x - 1)
	var z1: int = mini(z0 + 1, _total_vertices_z - 1)

	var tx: float = clampf(grid_x - float(x0), 0.0, 1.0)
	var tz: float = clampf(grid_z - float(z0), 0.0, 1.0)

	var row0: int = z0 * _total_vertices_x
	var row1: int = z1 * _total_vertices_x

	return lerpf(
		lerpf(global_height_data[row0 + x0], global_height_data[row0 + x1], tx),
		lerpf(global_height_data[row1 + x0], global_height_data[row1 + x1], tx),
		tz
	)


func get_height_at_world_coords(world_x: float, world_z: float) -> float:
	if is_zero_approx(cell_size) or global_height_data.is_empty():
		return 0.0
	if _total_vertices_x <= 0 or _total_vertices_z <= 0:
		return 0.0

	var local: Vector3 = to_local(Vector3(world_x, 0.0, world_z))
	var height: float = sample_grid_height(local.x / cell_size, -local.z / cell_size)

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


## How many chunks the pending dimensions would drop off the edge of the world.
##
## Only the count of chunks that exist today and would not exist afterwards. Growing the world,
## or changing only the cell size, loses nothing and answers zero.
func count_chunks_lost_by_pending_dimensions() -> int:
	var lost: int = 0
	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			if cx >= preview_world_chunks.x or cz >= preview_world_chunks.y:
				lost += 1
	return lost


## Applies the pending world dimensions, asking first when that would destroy terrain.
##
## Shrinking is irreversible - the migration rebuilds the grid and there is no undo entry for
## it - and it used to happen on a single click with nothing but a line in the console to show
## for it. A console nobody has open while modelling is not a warning.
func _apply_dimension_changes() -> void:
	var lost: int = count_chunks_lost_by_pending_dimensions()

	# Ask only where someone can answer, and only when something is actually at stake.
	if lost > 0 and Engine.is_editor_hint() and not global_height_data.is_empty():
		signal_shrink_confirmation_requested.emit(lost)
		return

	apply_dimension_changes_confirmed()


## Performs the change for real. Public because the confirmation dialog calls back into it.
func apply_dimension_changes_confirmed() -> void:
	# Everything the migration is about to rewrite, captured while it still exists.
	var previous_chunks: Vector2i = world_chunks
	var previous_chunk_size: int = chunk_size
	var previous_cell_size: float = cell_size
	var previous_heights: PackedFloat32Array = global_height_data.duplicate()
	var previous_activity: PackedByteArray = chunk_activity_data.duplicate()
	var previous_paint: PackedByteArray = global_paint_data.duplicate()

	# Trigger high-performance grid data block copy migration pipeline
	_migrate_grid_data()

	_register_dimension_undo(
		previous_chunks, previous_chunk_size, previous_cell_size,
		previous_heights, previous_activity, previous_paint
	)


## Files one undo entry for a completed dimension change.
##
## A whole-grid snapshot, like the noise and smoothing generators use. It is the only shape that
## works here: the migration re-indexes every array by the new row width, so there is no sparse
## delta to record - every single value moves.
func _register_dimension_undo(
	previous_chunks: Vector2i,
	previous_chunk_size: int,
	previous_cell_size: float,
	previous_heights: PackedFloat32Array,
	previous_activity: PackedByteArray,
	previous_paint: PackedByteArray
) -> void:
	if not Engine.is_editor_hint():
		return

	if _active_undo_redo_manager == null:
		var editor: Object = Engine.get_singleton("EditorInterface")
		if editor and editor.has_method("get_undo_redo"):
			_active_undo_redo_manager = editor.call("get_undo_redo")
	if _active_undo_redo_manager == null:
		return

	_active_undo_redo_manager.create_action("Apply Terrain Dimensions", 0, self)
	_active_undo_redo_manager.add_do_method(
		self, _apply_dimension_snapshot.get_method(),
		world_chunks, chunk_size, cell_size,
		global_height_data.duplicate(), chunk_activity_data.duplicate(),
		global_paint_data.duplicate()
	)
	_active_undo_redo_manager.add_undo_method(
		self, _apply_dimension_snapshot.get_method(),
		previous_chunks, previous_chunk_size, previous_cell_size,
		previous_heights, previous_activity, previous_paint
	)
	_active_undo_redo_manager.commit_action(false)


## Restores a complete grid state: dimensions and all three data layers at once.
##
## The preview values are pulled along deliberately. They are what the inspector shows and what
## the Apply button would act on next, so leaving them pointing at the undone size would invite
## re-applying it by accident.
func _apply_dimension_snapshot(
	restored_chunks: Vector2i,
	restored_chunk_size: int,
	restored_cell_size: float,
	heights: PackedFloat32Array,
	activity: PackedByteArray,
	paint: PackedByteArray
) -> void:
	world_chunks = restored_chunks
	chunk_size = restored_chunk_size
	cell_size = restored_cell_size
	preview_world_chunks = restored_chunks
	preview_chunk_size = restored_chunk_size
	preview_cell_size = restored_cell_size

	_recalculate_matrix_bounds()
	global_height_data = heights.duplicate()
	chunk_activity_data = activity.duplicate()
	global_paint_data = paint.duplicate()

	_apply_derived_cull_radius()
	rebuild_chunks_structure()
	notify_property_list_changed()


## Lossless Grid Migration Pipeline: Safely transforms and scales the continuous 
## data memory blocks without dropping height values across modified grid matrices.
func _migrate_grid_data() -> void:
	var old_chunks_x: int = world_chunks.x
	var old_chunks_y: int = world_chunks.y
	var old_activity_data: PackedByteArray = chunk_activity_data.duplicate()
	
	var old_vertices_x: int = _total_vertices_x
	var old_vertices_z: int = _total_vertices_z
	var old_height_data: PackedFloat32Array = global_height_data.duplicate()
	_paint_migration_source = global_paint_data.duplicate()
	
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
	_migrate_paint_data(old_vertices_x, old_vertices_z)

	# The culling radius is expressed in metres, so it has to follow the new chunk dimensions.
	_apply_derived_cull_radius()

	# 3. REBUILD INFRASTRUCTURE SYSTEM
	rebuild_chunks_structure()
	signal_brush_settings_changed.emit()



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
	chunks_dict.clear()

	# Pre-calculate spatial stride to safely reverse-engineer coordinates from world positions
	var meters_per_chunk: float = float(chunk_size) * cell_size

	# Only chunk nodes are touched. Everything else belongs to the user or to the plugin's own
	# infrastructure; freeing it here used to destroy any node parented to the terrain.
	for child in get_children():
		if not (child is LowPolyTerrainChunk) or child.name.contains("@"):
			continue

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

	# Automated self-healing anchor to guarantee the default asset node always exists
	if not has_node("Terrain_Assets"):
		var asset_container := Node3D.new()
		asset_container.name = "Terrain_Assets"
		add_child(asset_container)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			asset_container.set_owner(get_tree().edited_scene_root)

	# 2. INITIALIZE REFRESHED CHUNK NODES & SYNC LOCAL HEIGHT SUB-ARRAYS
	_grow_chunk_activity_data()

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
				chunks_dict[coord].mesh = _get_deactivated_preview_mesh()
				chunks_dict[coord].material_override = _get_deactivated_preview_material()
			
			# Use the unified clean update method to initialize states fluidly
			_update_single_chunk(coord)




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





## Core brush manipulation engine triggered directly by the editor plugin.
## Blends a straight ramp between two world positions into the terrain.
##
## The heights at both ends are read from the terrain itself, so the ramp starts and finishes
## flush with whatever is already there. Along the connecting segment the target height is
## interpolated linearly; across it, `brush_radius` sets the width and `brush_falloff_strength`
## how softly the edges meet the surrounding ground.
##
## Distance is measured to the SEGMENT, not to the infinite line, which gives the corridor
## rounded caps: the ramp runs out at its endpoints instead of being cut off square.
##
## Public so it can be scripted and unit tested; the editor's RAMP brush is only the two clicks
## that supply the endpoints.
## Converts a world position into fractional grid coordinates, the space the ramp works in.
func _world_to_grid(world_pos: Vector3) -> Vector2:
	var local: Vector3 = to_local(world_pos)
	return Vector2(local.x / cell_size, -local.z / cell_size)


## The height the ramp would leave at one grid point, given the current height there.
##
## The single source of truth for the ramp's shape: apply_ramp() writes what this returns, and
## the editor preview draws it. Splitting the two would let the overlay promise a surface the
## tool does not build.
##
## Outside the radius the blend factor is zero, so the answer is simply the existing height.
## That is what lets the preview mesh be evaluated over a slightly larger box and still meet
## the surrounding ground exactly.
func _ramp_projection(
	point: Vector2, a: Vector2, axis: Vector2, axis_length_sq: float
) -> Vector2:
	# Clamped so both ends round off rather than extending the ramp beyond the picked points.
	var t: float = 0.0
	if not is_zero_approx(axis_length_sq):
		t = clampf((point - a).dot(axis) / axis_length_sq, 0.0, 1.0)
	return Vector2(t, point.distance_to(a + axis * t))


func _ramp_height_at(
	point: Vector2,
	a: Vector2,
	axis: Vector2,
	axis_length_sq: float,
	radius: float,
	height_a: float,
	height_b: float,
	current: float
) -> float:
	var projection: Vector2 = _ramp_projection(point, a, axis, axis_length_sq)
	var t: float = projection.x
	var distance: float = projection.y
	if distance >= radius:
		return current

	# Same curve the sculpting brushes use, so the tool feels like the others.
	var radius_factor: float = distance / radius
	var smooth_curve: float = clampf(
		1.0 - (radius_factor * radius_factor * (3.0 - 2.0 * radius_factor)), 0.0, 1.0
	)
	var falloff: float = lerpf(1.0, smooth_curve, brush_falloff_strength)

	return lerpf(current, lerpf(height_a, height_b, t), falloff)


func apply_ramp(from_world: Vector3, to_world: Vector3) -> void:
	if is_zero_approx(cell_size) or global_height_data.is_empty():
		return
	if brush_radius <= 0:
		return

	# Everything below happens in grid units, where brush_radius is already expressed.
	var a: Vector2 = _world_to_grid(from_world)
	var b: Vector2 = _world_to_grid(to_world)

	var height_a: float = sample_grid_height(a.x, a.y)
	var height_b: float = sample_grid_height(b.x, b.y)

	var axis: Vector2 = b - a
	var axis_length_sq: float = axis.length_squared()
	var radius: float = float(brush_radius)

	var old_state: PackedFloat32Array = global_height_data.duplicate()

	# Only the capsule around the segment can change, so the sweep stays local to it.
	var min_x: int = clampi(floori(minf(a.x, b.x) - radius), 0, _total_vertices_x - 1)
	var max_x: int = clampi(ceili(maxf(a.x, b.x) + radius), 0, _total_vertices_x - 1)
	var min_z: int = clampi(floori(minf(a.y, b.y) - radius), 0, _total_vertices_z - 1)
	var max_z: int = clampi(ceili(maxf(a.y, b.y) + radius), 0, _total_vertices_z - 1)

	var touched: Dictionary = {}

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var cx: int = clampi(x / chunk_size, 0, world_chunks.x - 1)
			var cz: int = clampi(z / chunk_size, 0, world_chunks.y - 1)
			if not is_chunk_active(cx, cz):
				continue

			var index: int = z * _total_vertices_x + x
			var current: float = global_height_data[index]
			var updated: float = _ramp_height_at(
				Vector2(float(x), float(z)), a, axis, axis_length_sq, radius,
				height_a, height_b, current
			)
			if is_equal_approx(updated, current):
				continue

			global_height_data[index] = updated

			touched[Vector2i(cx, cz)] = true
			# A vertex on a chunk border belongs to its neighbours as well, or the seam splits.
			if x % chunk_size == 0 and cx > 0:
				touched[Vector2i(cx - 1, cz)] = true
			if z % chunk_size == 0 and cz > 0:
				touched[Vector2i(cx, cz - 1)] = true

	for coord: Vector2i in touched:
		if _has_chunk(coord):
			_update_single_chunk(coord)

	_register_ramp_undo(old_state)


## How much of a triangle's normal has to point up before it counts as the ramp's top rather
## than as one of its flanks. Roughly 45 degrees, which separates a walkable slope from the
## cuts the ramp makes down to the surrounding ground.
const PREVIEW_FLANK_THRESHOLD: float = 0.7


## Builds the surface apply_ramp() would leave behind, in this manager's LOCAL space.
##
## Evaluated through the very same _ramp_height_at() the tool writes with, so the overlay shows
## the result rather than an impression of it: the corridor width comes out of brush_radius and
## the way it feathers into the surrounding ground out of brush_falloff_strength. At falloff 0
## the edges are a clean step, above it they curve down onto the existing surface.
##
## The box is one cell wider than the affected capsule on every side. Outside the radius the
## evaluation returns the current terrain height, so that border row stitches the preview onto
## the ground instead of ending in mid-air.
##
## Returns null when there is nothing to show.
func build_ramp_preview_mesh(from_world: Vector3, to_world: Vector3) -> ArrayMesh:
	if is_zero_approx(cell_size) or global_height_data.is_empty() or brush_radius <= 0:
		return null

	var a: Vector2 = _world_to_grid(from_world)
	var b: Vector2 = _world_to_grid(to_world)
	var height_a: float = sample_grid_height(a.x, a.y)
	var height_b: float = sample_grid_height(b.x, b.y)

	var axis: Vector2 = b - a
	var axis_length_sq: float = axis.length_squared()
	var radius: float = float(brush_radius)

	var min_x: int = clampi(floori(minf(a.x, b.x) - radius) - 1, 0, _total_vertices_x - 1)
	var max_x: int = clampi(ceili(maxf(a.x, b.x) + radius) + 1, 0, _total_vertices_x - 1)
	var min_z: int = clampi(floori(minf(a.y, b.y) - radius) - 1, 0, _total_vertices_z - 1)
	var max_z: int = clampi(ceili(maxf(a.y, b.y) + radius) + 1, 0, _total_vertices_z - 1)

	if max_x <= min_x or max_z <= min_z:
		return null

	# Heights are read once per vertex rather than once per quad corner, which would evaluate
	# every interior vertex four times over. The distance is kept alongside them, because the
	# quad loop below needs it to decide what is worth drawing at all.
	var width: int = max_x - min_x + 1
	var depth: int = max_z - min_z + 1
	var heights := PackedFloat32Array()
	var distances := PackedFloat32Array()
	heights.resize(width * depth)
	distances.resize(width * depth)

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var point := Vector2(float(x), float(z))
			var slot: int = (z - min_z) * width + (x - min_x)
			distances[slot] = _ramp_projection(point, a, axis, axis_length_sq).y
			heights[slot] = _ramp_height_at(
				point, a, axis, axis_length_sq, radius,
				height_a, height_b, global_height_data[z * _total_vertices_x + x]
			)

	# One cell diagonal beyond the radius, so the ring that stitches the surface onto the ground
	# is kept and nothing further is.
	var draw_limit: float = radius + 1.5

	# Two surfaces so the editor can colour them apart. A single flat tint made the shape almost
	# unreadable: the sloping top and the near-vertical cuts down to the surrounding ground came
	# out identical, and those cuts are exactly what tells you how far the ramp reaches.
	var top := SurfaceTool.new()
	top.begin(Mesh.PRIMITIVE_TRIANGLES)
	top.set_smooth_group(-1)

	var flanks := SurfaceTool.new()
	flanks.begin(Mesh.PRIMITIVE_TRIANGLES)
	flanks.set_smooth_group(-1)

	for z in range(depth - 1):
		for x in range(width - 1):
			# The bounding box is axis aligned, so a diagonal ramp reaches almost every cell in
			# it while touching only a narrow corridor. Without this the preview covered the
			# whole terrain in colour, sitting flush on ground it never intended to change.
			if minf(
				minf(distances[z * width + x], distances[z * width + x + 1]),
				minf(distances[(z + 1) * width + x], distances[(z + 1) * width + x + 1])
			) > draw_limit:
				continue

			var gx: float = float(min_x + x) * cell_size
			var gz: float = -float(min_z + z) * cell_size
			var step: float = cell_size

			var p00 := Vector3(gx, heights[z * width + x], gz)
			var p10 := Vector3(gx + step, heights[z * width + x + 1], gz)
			var p01 := Vector3(gx, heights[(z + 1) * width + x], gz - step)
			var p11 := Vector3(gx + step, heights[(z + 1) * width + x + 1], gz - step)

			# Clockwise, matching the terrain: Godot treats that winding as front facing.
			_add_preview_triangle(top, flanks, p00, p01, p10)
			_add_preview_triangle(top, flanks, p10, p01, p11)

	top.generate_normals()
	flanks.generate_normals()

	# Surface 0 is always the upward facing part, so the editor can address the two by index.
	# The flanks may legitimately be empty - a ramp laid onto ground it already matches has no
	# cuts at all - in which case the mesh simply carries one surface.
	var mesh: ArrayMesh = top.commit()
	if mesh == null:
		return null
	flanks.commit(mesh)
	return mesh


## Sorts one preview triangle into the upward facing surface or into the flanks.
static func _add_preview_triangle(
	top: SurfaceTool, flanks: SurfaceTool, a: Vector3, b: Vector3, c: Vector3
) -> void:
	# Godot treats clockwise as front facing, which puts the right-hand-rule cross product of an
	# upward facing triangle on the NEGATIVE y axis. Hence the sign flip before comparing.
	var upward: float = -((b - a).cross(c - a)).normalized().y
	var target: SurfaceTool = top if upward >= PREVIEW_FLANK_THRESHOLD else flanks

	target.add_vertex(a)
	target.add_vertex(b)
	target.add_vertex(c)


## Commits one undo entry for a completed ramp, mirroring the global generators.
func _register_ramp_undo(old_state: PackedFloat32Array) -> void:
	if not Engine.is_editor_hint():
		return

	if _active_undo_redo_manager == null:
		var editor: Object = Engine.get_singleton("EditorInterface")
		if editor and editor.has_method("get_undo_redo"):
			_active_undo_redo_manager = editor.call("get_undo_redo")
	if _active_undo_redo_manager == null:
		return

	_active_undo_redo_manager.create_action("Terrain Ramp", 0, self)
	_active_undo_redo_manager.add_do_method(
		self, _apply_historical_snapshot.get_method(), global_height_data.duplicate()
	)
	_active_undo_redo_manager.add_undo_method(
		self, _apply_historical_snapshot.get_method(), old_state
	)
	_active_undo_redo_manager.commit_action()


## The surface angle at a grid point, in degrees. Zero is level, ninety is a vertical wall.
##
## Derived from the height matrix rather than from the mesh, for the same reason the height
## query is: it is the source both backends build from, and it exists at full grid resolution
## even where decimation threw the corresponding vertex away.
##
## Central differences, with the samples clamped at the border so an edge point leans on the
## slope just inside it instead of reporting a cliff that is not there.
func get_slope_angle_at(x: int, z: int) -> float:
	if _total_vertices_x <= 1 or _total_vertices_z <= 1 or is_zero_approx(cell_size):
		return 0.0

	var left: float = get_height_at(maxi(x - 1, 0), z)
	var right: float = get_height_at(mini(x + 1, _total_vertices_x - 1), z)
	var back: float = get_height_at(x, maxi(z - 1, 0))
	var front: float = get_height_at(x, mini(z + 1, _total_vertices_z - 1))

	var dx: float = (right - left) / (2.0 * cell_size)
	var dz: float = (front - back) / (2.0 * cell_size)

	# The upward component of the surface normal is enough; no need to build the whole vector.
	var up: float = 1.0 / sqrt(dx * dx + dz * dz + 1.0)
	return rad_to_deg(acos(clampf(up, -1.0, 1.0)))


## How much of a layer the slope filter lets through at a given angle, 0 to 1.
##
## The configured range is passed at full strength and the feather is the run-out BEYOND it, so
## the numbers you type are the ground you definitely get rather than the ground you might.
func get_slope_mask(angle: float, layer: int) -> float:
	var range_deg: Vector2 = get_paint_layer_slope(layer)
	var low: float = minf(range_deg.x, range_deg.y)
	var high: float = maxf(range_deg.x, range_deg.y)

	if angle >= low and angle <= high:
		return 1.0
	if paint_slope_feather <= 0.0:
		return 0.0

	if angle < low:
		return clampf(1.0 - (low - angle) / paint_slope_feather, 0.0, 1.0)
	return clampf(1.0 - (angle - high) / paint_slope_feather, 0.0, 1.0)


## The configured slope range of one layer, 1 to 4.
func get_paint_layer_slope(layer: int) -> Vector2:
	match clampi(layer, 1, PAINT_LAYER_COUNT):
		1: return paint_layer_1_slope
		2: return paint_layer_2_slope
		3: return paint_layer_3_slope
	return paint_layer_4_slope


## Blends the selected paint layer into the grid around a LOCAL position.
##
## Works on weights rather than heights, but through the same brush settings: brush_radius sets
## the footprint, brush_falloff_strength the edge, and brush_strength how much of the layer one
## pass deposits. Holding Shift wipes back towards the base material instead.
func _apply_paint_at(local_pos: Vector3, erase: bool, strength_scale: float) -> void:
	if is_zero_approx(cell_size) or brush_radius <= 0:
		return
	if global_height_data.is_empty():
		return

	var layer: int = clampi(paint_layer - 1, 0, PAINT_LAYER_COUNT - 1)

	# The alpha of a layer's colour caps how much of the surface that layer may claim.
	#
	# This is what makes a translucent layer read as a glaze rather than as a replacement. The
	# four weights share one surface between them, so a layer reaching full weight necessarily
	# pushes the others out - and then there is nothing left for its transparency to reveal
	# except the base material. Capping the claim instead leaves room for whatever was already
	# there, and the two mix.
	#
	# It therefore acts while PAINTING, not afterwards: changing the alpha later does not
	# repaint what is already on the terrain.
	var layer_opacity: float = clampf(get_paint_layer_color(paint_layer).a, 0.0, 1.0)
	var centre_x: float = local_pos.x / cell_size
	var centre_z: float = -local_pos.z / cell_size
	var radius: float = float(brush_radius)

	# One pass never deposits everything, or the brush would be a stamp rather than a brush.
	# Divided by the strength slider's own maximum so the two ends of it stay meaningful.
	var deposit: float = clampf(brush_strength / 15.0, 0.0, 1.0) * strength_scale

	var min_x: int = clampi(floori(centre_x - radius), 0, _total_vertices_x - 1)
	var max_x: int = clampi(ceili(centre_x + radius), 0, _total_vertices_x - 1)
	var min_z: int = clampi(floori(centre_z - radius), 0, _total_vertices_z - 1)
	var max_z: int = clampi(ceili(centre_z + radius), 0, _total_vertices_z - 1)

	var touched: Dictionary = {}

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var distance: float = Vector2(float(x) - centre_x, float(z) - centre_z).length()
			if distance > radius:
				continue

			var cx: int = clampi(x / chunk_size, 0, world_chunks.x - 1)
			var cz: int = clampi(z / chunk_size, 0, world_chunks.y - 1)
			if not is_chunk_active(cx, cz):
				continue

			# Same curve as the sculpting brushes, so the edge behaves the way users expect.
			var radius_factor: float = distance / radius
			var smooth_curve: float = clampf(
				1.0 - (radius_factor * radius_factor * (3.0 - 2.0 * radius_factor)), 0.0, 1.0
			)
			# The falloff is a CEILING, not a per-pass multiplier.
			#
			# Scaling the deposit by it instead made the edge unreachable twice over: the small
			# per-pass amounts out there rounded back to zero on every single pass, so nothing
			# ever accumulated, while the middle piled up to full weight and the whole stroke
			# came out as a hard disc that merely shrank as the falloff rose.
			#
			# As a ceiling the profile is what the falloff describes and stays that way however
			# long the button is held: full in the middle, tapering to nothing at the rim.
			var ceiling: float = lerpf(1.0, smooth_curve, brush_falloff_strength)
			if not erase:
				ceiling = minf(ceiling, layer_opacity)
				# A third cap, alongside the falloff and the layer's opacity. Folded into the
				# ceiling rather than skipping the point, so the filter fades in and out with
				# the terrain instead of cutting a contour line across it.
				ceiling *= get_slope_mask(get_slope_angle_at(x, z), paint_layer)
			if is_zero_approx(ceiling):
				continue

			_capture_paint_undo(x, z)

			var weights: Color = get_paint_at(x, z)
			var channels: PackedFloat32Array = [weights.r, weights.g, weights.b, weights.a]

			if erase:
				# Towards the base means every layer recedes, not just the selected one. No
				# ceiling here: erasing all the way to nothing is a legitimate destination.
				for i in range(PAINT_LAYER_COUNT):
					channels[i] = maxf(channels[i] - deposit * ceiling, 0.0)
			else:
				# Approach the ceiling at a constant rate, so the stroke builds up evenly and
				# settles into the falloff profile rather than past it.
				#
				# The outer maxf is what stops the ceiling from ERASING. Without it, a second
				# stroke laid beside a finished one cut the old paint back to its own soft rim
				# wherever the two overlapped: min() does not care that the value it lowers was
				# put there by someone else. A brush adds; only Shift takes away.
				channels[layer] = maxf(
					channels[layer], minf(channels[layer] + deposit, ceiling)
				)
				# The others give way, so the four weights plus the base stay a partition
				# rather than piling up and clipping.
				var room: float = 1.0 - channels[layer]
				var others: float = 0.0
				for i in range(PAINT_LAYER_COUNT):
					if i != layer:
						others += channels[i]
				if others > room and others > 0.0:
					var scale: float = room / others
					for i in range(PAINT_LAYER_COUNT):
						if i != layer:
							channels[i] *= scale

			set_paint_at(x, z, Color(channels[0], channels[1], channels[2], channels[3]))
			touched[Vector2i(cx, cz)] = true

			# A border vertex belongs to its neighbours too, or the seam would split.
			if x % chunk_size == 0 and cx > 0:
				touched[Vector2i(cx - 1, cz)] = true
			if z % chunk_size == 0 and cz > 0:
				touched[Vector2i(cx, cz - 1)] = true

	for coord: Vector2i in touched:
		if _has_chunk(coord):
			_update_single_chunk(coord)


## Turns one painting stroke into a single undo entry.
##
## Sparse like the sculpting undo: only the grid points the brush actually touched are stored,
## with the four bytes they held before the stroke began.
func _commit_paint_stroke() -> void:
	if _undo_paint_delta.is_empty():
		return

	var offsets := PackedInt32Array()
	var before := PackedByteArray()
	var after := PackedByteArray()

	for offset: int in _undo_paint_delta:
		offsets.append(offset)
		var old_bytes: PackedByteArray = _undo_paint_delta[offset]
		for channel in range(4):
			before.append(old_bytes[channel])
			after.append(global_paint_data[offset + channel])

	_undo_paint_delta.clear()

	_active_undo_redo_manager.create_action("Paint Terrain", 0, self)
	_active_undo_redo_manager.add_do_method(
		self, _apply_paint_delta.get_method(), offsets, after
	)
	_active_undo_redo_manager.add_undo_method(
		self, _apply_paint_delta.get_method(), offsets, before
	)
	_active_undo_redo_manager.commit_action(false)


## Writes a sparse set of paint bytes back and rebuilds only the chunks they belong to.
func _apply_paint_delta(offsets: PackedInt32Array, values: PackedByteArray) -> void:
	if offsets.is_empty():
		return
	_ensure_paint_data()

	var touched: Dictionary = {}
	for i in range(offsets.size()):
		var offset: int = offsets[i]
		if offset + 3 >= global_paint_data.size():
			continue
		for channel in range(4):
			global_paint_data[offset + channel] = values[i * 4 + channel]

		var point: int = offset / 4
		var gx: int = point % _total_vertices_x
		var gz: int = point / _total_vertices_x
		var cx: int = clampi(gx / chunk_size, 0, world_chunks.x - 1)
		var cz: int = clampi(gz / chunk_size, 0, world_chunks.y - 1)
		touched[Vector2i(cx, cz)] = true
		if gx % chunk_size == 0 and cx > 0:
			touched[Vector2i(cx - 1, cz)] = true
		if gz % chunk_size == 0 and cz > 0:
			touched[Vector2i(cx, cz - 1)] = true

	for coord: Vector2i in touched:
		if _has_chunk(coord):
			_update_single_chunk(coord)


## Records a grid point's paint once per stroke, before the first change to it.
func _capture_paint_undo(x: int, z: int) -> void:
	if not (Engine.is_editor_hint() or _active_undo_redo_manager != null):
		return
	_ensure_paint_data()

	var base: int = (z * _total_vertices_x + x) * 4
	if _undo_paint_delta.has(base) or base + 3 >= global_paint_data.size():
		return

	_undo_paint_delta[base] = PackedByteArray([
		global_paint_data[base], global_paint_data[base + 1],
		global_paint_data[base + 2], global_paint_data[base + 3]
	])


## The brush mode that actually runs for the given modifier state.
##
## Public because the editor plugin needs the very same answer to colour the brush ring and
## caption it. Keeping the mapping here rather than duplicating it there is what stops the
## overlay from advertising one tool while the stroke performs another.
func resolve_brush_mode(is_alternative: bool) -> BrushMode:
	if not is_alternative:
		return tool_mode

	match tool_mode:
		BrushMode.RAISE:
			return BrushMode.LOWER
		BrushMode.LOWER:
			return BrushMode.RAISE
		BrushMode.ACTIVATE_CHUNK:
			return BrushMode.DEACTIVATE_CHUNK
		BrushMode.DEACTIVATE_CHUNK:
			return BrushMode.ACTIVATE_CHUNK
		BrushMode.RAMP:
			# Deliberately unchanged. RAMP is a two-click operation, and swapping the tool
			# under the user between the first and the second click would be hostile.
			return BrushMode.RAMP
		BrushMode.PAINT:
			# Also unchanged: Shift inverts what PAINT does rather than which tool runs. It
			# wipes back towards the base material, which interact_at_world_position() reads
			# from its is_alternative argument directly.
			return BrushMode.PAINT

	# FLATTEN and SMOOTH have no natural opposite, so the modifier reaches for SMOOTH.
	return BrushMode.SMOOTH


## Applies the brush once at a world position.
##
## `strength_scale` attenuates this single pass without touching brush_strength, so the caller
## can soften a stroke without writing to a property the inspector is showing. The editor uses
## it to weaken a stroke held still on one spot, which would otherwise dig at the full rate of
## a moving one every single frame. It multiplies the falloff, which is the one term every
## sculpting mode already scales by, so all of them attenuate consistently.
func interact_at_world_position(
	world_pos: Vector3,
	is_alternative: bool,
	strength_scale: float = 1.0
) -> void:
	
	# [TEST-SAFE COOLDOWN] Bypass throttling if we are running automated history checks
	if _active_undo_redo_manager == null:
		var current_time: float = Time.get_ticks_msec() / 1000.0
		if current_time - _last_paint_time < _paint_cooldown:
			return
		_last_paint_time = current_time
		

	var local_pos: Vector3 = to_local(world_pos)
	
	# Determine operation mode based on current selection and modifier keys
	var mode: BrushMode = resolve_brush_mode(is_alternative)

	# Painting writes layer weights, never heights, so it leaves before the sculpting pass.
	# Shift is read straight from is_alternative here rather than through the mode: it inverts
	# what the tool DOES - wiping back towards the base - not which tool runs.
	if mode == BrushMode.PAINT:
		_apply_paint_at(local_pos, is_alternative, strength_scale)
		return

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

				# Every mode below multiplies by final_falloff, so attenuating it here is what
				# makes strength_scale act uniformly instead of per-mode.
				final_falloff *= strength_scale

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

				# The WHOLE transform, not just the origin.
				#
				# The body is built as a child of the chunk, where it inherits the manager's
				# orientation for free, and is then reparented into a container that is a
				# SIBLING of the manager and therefore unrotated. Godot carries the local
				# transform across a reparent, not the global one, so assigning only the
				# position left every collider axis-aligned while the terrain was tilted - the
				# chunk origins stepped down the slope and the flat colliders formed a
				# staircase under the mesh.
				#
				# center_offset is a chunk-local vector (bake_collision() shifts the faces by
				# its negative), so it has to travel through the same transform rather than
				# being added in world space.
				static_body.global_transform = Transform3D(
					chunk.global_transform.basis,
					chunk.global_transform * center_offset
				)
				
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
			chunk.mesh = _get_deactivated_preview_mesh()
			chunk.material_override = _get_deactivated_preview_material()

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
		jitter_slope_threshold, custom_material,
		extract_chunk_paint(coord), PAINT_STEPS,
		get_active_paint_material()
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
	
	# Reset the sparse delta matrices to ensure a clean state for the upcoming stroke
	_undo_sparse_delta.clear()
	_undo_activity_delta.clear()



## Registers the finalized thin delta package directly into the native engine history.
func stroke_finished() -> void:
	# [E5] One inspector refresh per stroke instead of one per paint event.
	if Engine.is_editor_hint():
		notify_property_list_changed()

	if not Engine.is_editor_hint() or _active_undo_redo_manager == null:
		return

	# A stroke uses exactly one brush mode, so at most one of these ever has anything to say.
	_commit_activity_stroke()
	_commit_paint_stroke()

	if _undo_sparse_delta.is_empty():
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


## Registers the Activate/Deactivate Chunk stroke in the editor history, using the same thin
## delta approach as sculpting: only the chunks that actually flipped are stored.
func _commit_activity_stroke() -> void:
	if _undo_activity_delta.is_empty():
		return

	var affected_indices := PackedInt32Array()
	var old_states := PackedByteArray()
	var new_states := PackedByteArray()

	var total_elements: int = _undo_activity_delta.size()
	affected_indices.resize(total_elements)
	old_states.resize(total_elements)
	new_states.resize(total_elements)

	var cursor: int = 0
	for idx in _undo_activity_delta.keys():
		affected_indices[cursor] = idx
		old_states[cursor] = int(_undo_activity_delta[idx])
		new_states[cursor] = chunk_activity_data[idx]
		cursor += 1

	# Pass 'self' as the custom context so the action binds to the active scene tab.
	_active_undo_redo_manager.create_action("Terrain Chunk Activation", 0, self)
	_active_undo_redo_manager.add_do_method(
		self,
		_apply_activity_delta.get_method(),
		affected_indices,
		new_states
	)
	_active_undo_redo_manager.add_undo_method(
		self,
		_apply_activity_delta.get_method(),
		affected_indices,
		old_states
	)
	_active_undo_redo_manager.commit_action()

	_undo_activity_delta.clear()


## Targeted mutation callback for chunk activation, invoked by the engine's undo/redo pipeline.
func _apply_activity_delta(indices: PackedInt32Array, states: PackedByteArray) -> void:
	if indices.is_empty() or indices.size() != states.size():
		return
	if world_chunks.x <= 0:
		return

	for i in range(indices.size()):
		var chunk_index: int = indices[i]
		if chunk_index < 0 or chunk_index >= chunk_activity_data.size():
			continue
		chunk_activity_data[chunk_index] = states[i]

		# Only the chunks that actually changed are refreshed, never the whole world.
		_update_single_chunk(Vector2i(
			chunk_index % world_chunks.x,
			chunk_index / world_chunks.x
		))

	notify_property_list_changed()


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


## The paint window of one chunk, laid out like extract_chunk_heights() but four bytes wide.
##
## Returns an EMPTY array while nothing has been painted, which the builder reads as "no paint
## anywhere" and skips outright. That keeps an unpainted terrain on exactly the code path it
## had before this feature.
func extract_chunk_paint(coord: Vector2i) -> PackedByteArray:
	if global_paint_data.is_empty():
		return PackedByteArray()

	var vert_stride: int = chunk_size + 1
	var window := PackedByteArray()
	window.resize(vert_stride * vert_stride * 4)

	for lz in range(vert_stride):
		var global_z: int = (coord.y * chunk_size) + lz
		var local_offset: int = lz * vert_stride * 4
		var global_row_start: int = (global_z * _total_vertices_x + (coord.x * chunk_size)) * 4

		for i in range(vert_stride * 4):
			var source: int = global_row_start + i
			if source < global_paint_data.size():
				window[local_offset + i] = global_paint_data[source]

	return window


## SERVERS counterpart of rebuild_chunks_structure(). Registers one RenderingServer instance
## per chunk instead of instantiating MeshInstance3D children.
func _rebuild_server_chunks() -> void:
	if _server_backend == null:
		return

	# Clear out any chunk node left behind by a previous MESH_NODES session. Nothing else is
	# touched: infrastructure containers and anything the user parented here are not ours.
	for child in get_children():
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

	_grow_chunk_activity_data()

	_server_backend.prune_out_of_bounds(world_chunks)

	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var coord := Vector2i(cx, cz)

			# AT RUNTIME: Only register a chunk if it is active
			if is_chunk_active(cx, cz) or Engine.is_editor_hint():
				_server_backend.ensure_chunk(coord)

			_update_single_chunk(coord)



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
	# is not fully reproducible from global_height_data. Nothing else is touched.
	for child in get_children():
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
	elif not Engine.is_editor_hint() and runtime_collision == RuntimeCollision.LAZY:
		# LAZY builds nothing on its own, so a game that forgets to drive the radius would
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



## Removes the baked collider container, because the server bodies replace it entirely and
## keeping both alive would produce duplicated physics geometry.
##
## Deliberately NOT registered as an undoable action. This runs from the terrain_backend
## setter, and the inspector already has its own UndoRedo action open at that point to record
## the property change; a nested action does not work there. Even if it did, undoing it alone
## would restore the container while the backend stayed on SERVERS - which is exactly the
## duplicated physics this removal exists to prevent.
##
## Disabling the shapes instead of removing them is not an option either: measured on 100
## chunks, `disabled = true` gives back 0.01 MB of the 12.26 MB the colliders occupy, and the
## nodes stay in the scene and therefore in every build.
##
## None of this loses work. The container is derived data, rebuilt identically from
## global_height_data by the "Bake Live Collisions" button.
func _delete_baked_collision_container() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return

	var container: Node = parent.find_child(name + "_Collisions", false, false)
	if container == null:
		return

	parent.remove_child(container)
	container.queue_free()

	print("Removed the baked collision container '%s_Collisions'. " % name
		+ "Ctrl+Z does not bring it back: switch back to MESH_NODES and press "
		+ "'Bake Live Collisions' to regenerate it from the terrain data.")


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
		# the true starting state: baked MESH_NODES colliders and SERVERS bodies under the PREBUILT
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
		# has_active_body(), not has_body(): a parked collider still exists but takes part in
		# no collision test, so counting it as enabled would let the culling believe a chunk
		# was already switched on and skip actually enabling it. The MESH_NODES branch below
		# has always asked the same question - whether the collider is ON, not whether it is
		# there - and the two must not diverge. Under LAZY nothing exists yet either way.
		return _server_backend != null and _server_backend.has_active_body(coord)

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


## One-shot diagnostic for the LAZY policy, which produces no collision until the game
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
	if runtime_collision != RuntimeCollision.LAZY:
		return
	# Targets drive the culling automatically, so their presence is not a misconfiguration -
	# but only while enable_collision_culling actually lets them. Without that second half,
	# assigned targets plus an unticked checkbox silenced this warning while producing exactly
	# the situation it exists to report: a LAZY terrain nothing ever builds collision for.
	if enable_collision_culling and not collision_cull_targets.is_empty():
		return

	push_warning("LowPolyTerrain '%s': runtime_collision is LAZY but " % name
		+ "update_collision_culling() has never been called, so this terrain currently has no "
		+ "collision at all. Call it once per physics frame with the player position, or "
		+ "switch runtime_collision to PREBUILT.")


# --- AUTOMATIC CULLING TARGETS ---


## Registers a node for collision culling. Use this for players created at runtime, which an
## inspector reference cannot reach.
func add_culling_target(target: Node3D) -> void:
	if target == null or collision_cull_targets.has(target):
		return

	# Warned rather than auto-enabled: silently switching an inspector checkbox from code would
	# be worse than saying nothing happened, and this is the only symptom a caller would get.
	if not enable_collision_culling:
		push_warning("LowPolyTerrain '%s': add_culling_target() was called but " % name
			+ "enable_collision_culling is off, so the target will not be followed. Tick "
			+ "Enable Collision Culling in the inspector, or set it from code.")

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
	if enable_collision_culling:
		for target in collision_cull_targets:
			if is_instance_valid(target):
				has_target = true
				break

	# Switching the feature off is treated exactly like losing the last target, so the chunks it
	# was holding are handed back below instead of staying resident for the rest of the session.
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

	if runtime_collision == RuntimeCollision.PREBUILT:
		push_warning("LowPolyTerrain '%s': culling targets are assigned, but " % name
			+ "runtime_collision is PREBUILT, so every chunk keeps its collider and the culling "
			+ "only toggles them. Switch to LAZY to actually reclaim the memory.")
	elif runtime_collision == RuntimeCollision.NONE:
		push_warning("LowPolyTerrain '%s': culling targets are assigned, but " % name
			+ "runtime_collision is NONE, so there is no collision to cull at all.")



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
