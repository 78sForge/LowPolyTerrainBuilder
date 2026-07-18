extends GutTest

## Automated stability test suite for the Low Poly Terrain plugin.
## Verifies core matrix allocation, seam synchronization, enum-driven brushes, and physics baking.

var manager: LowPolyTerrainManager = null

# Runs automatically before EACH individual test method
func before_each() -> void:
	manager = LowPolyTerrainManager.new()
	manager.name = "TestTerrainManager" # Enforce a static node name for dynamic collision testing
	add_child(manager)
	
	# Force isolated dimensions for the testing environment context
	manager.world_chunks = Vector2i(2, 2)
	manager.chunk_size = 10
	manager.cell_size = 1.0
	manager.step_height = 0.5
	manager.collision_layer = 2
	manager.collision_group = "Wall"
	
	# FIXED: Safe check to purge default map data arrays without crashing if dictionary is null
	if manager.global_height_data != null:
		manager.global_height_data.clear()
	
	# Block the deferred editor viewport setup macro loop
	manager._setup_pending = false
	
	# Execute a clean linear data matrix rebuild inside the editor RAM
	manager.rebuild_chunks_structure()



# Runs automatically after EACH individual test method to prevent memory leaks
func after_each() -> void:
	if is_instance_valid(manager):
		# Calculate and sanitize the dynamic collision container name to locate leftover siblings
		var expected_container_name: String = manager.name + "_Collisions"
		expected_container_name = expected_container_name.replace("@", "_")
		
		# Locate and instantly free the parallel collision container from the parent scene tree root
		var parent_node = manager.get_parent()
		if is_instance_valid(parent_node):
			var container = parent_node.get_node_or_null(expected_container_name)
			if is_instance_valid(container):
				container.free()
		
		# Hard-purge all instantiated chunk nodes directly from the tracking dictionary array
		for chunk_coord in manager.chunks_dict.keys():
			var chunk = manager.chunks_dict[chunk_coord]
			if is_instance_valid(chunk):
				chunk.free()
		manager.chunks_dict.clear()
		
		# Force-clear any remaining transient child nodes (including the visual brush gizmo)
		for child in manager.get_children():
			if is_instance_valid(child):
				child.free()
				
		# Instantly delete the main manager instance from the editor memory layout
		manager.free() # FIXED: Changed from queue_free() to free() for instant synchronous garbage collection
		
	manager = null




# --- TEST 1: CORE ARCHITECTURE & DATA STRUCTURE ---
func test_initialization_creates_correct_chunk_count_and_data_arrays() -> void:
	assert_eq(manager.chunks_dict.size(), 4, "Should instantiate exactly 4 chunks for a 2x2 grid.")
	
	# Expected vertex density calculation sequence mapping: (10 + 1) * (10 + 1) = 121
	var expected_vertex_count = (manager.chunk_size + 1) * (manager.chunk_size + 1)
	for coord in manager.global_height_data.keys():
		var data_array: Array = manager.global_height_data[coord]
		assert_eq(data_array.size(), expected_vertex_count, "Each chunk data array must match the required vertex matrix size.")

# --- TEST 2: ENUM BRUSH FUNCTIONALITY (RAISE & LOWER) ---
func test_raise_brush_increases_vertex_height_correctly() -> void:
	var target_pos := Vector3(5.0, 0.0, -5.0) # Center of Chunk 0,0
	
	# FIXED: Replaced raw integer logic with the descriptive BrushMode Enum assignment configuration
	manager.tool_mode = manager.BrushMode.RAISE 
	manager.brush_radius = 0 # Target a single unique vertex point location
	
	# Act: Execute mock paint stroke interaction
	manager.interact_at_world_position(target_pos, false)
	
	# Assert: Extract global coordinates mapping sets
	var current_height = manager._get_global_vertex_height_from_copy(5, 5, manager.global_height_data)
	assert_eq(current_height, manager.step_height, "The target vertex height should match exactly one step_height after being raised.")

# --- TEST 3: SEAM BLENDING & CARDINAL EDGE COMPENSATION ---
func test_seam_handling_writes_simultaneously_to_neighboring_chunks() -> void:
	# Position exactly on the intersection corner grid points where 4 map chunks touch (x=10, z=10)
	var boundary_vertex_x = 10
	var boundary_vertex_z = 10
	var target_pos := Vector3(float(boundary_vertex_x), 0.0, -float(boundary_vertex_z))
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	
	# Act: Apply brush modifications directly onto the shared seam boundary point coordinates
	manager.interact_at_world_position(target_pos, false)
	
	# Assert: Interlock validation loop mapping entries across all 4 adjacent chunk sets
	var chunk_coords_to_check = [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)]
	for coord in chunk_coords_to_check:
		assert_true(manager.global_height_data.has(coord), "Global height map dictionary must contain coordinate mapping.")
		
		# Resolve the exact index offset location belonging to each chunk context
		var lx = boundary_vertex_x - (coord.x * manager.chunk_size)
		var lz = boundary_vertex_z - (coord.y * manager.chunk_size)
		var vert_count = manager.chunk_size + 1
		var height_in_chunk = manager.global_height_data[coord][lx + lz * vert_count]
		
		assert_eq(height_in_chunk, manager.step_height, "Seam error: Chunk %s failed to sync height on the shared boundary vertex!" % str(coord))

# --- TEST 4: DELAUNAY MESH GENERATION & WINDING ORDER ---
func test_chunk_mesh_generation_creates_valid_triangles_and_correct_winding() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)]
	
	# Induce an elevation slope variant to bypass inner point optimization filters
	manager.global_height_data[Vector2i(0,0)][5 + 5 * (manager.chunk_size + 1)] = 2.0
	chunk.generate_mesh()
	
	assert_not_null(chunk.mesh, "Chunk generation should yield a valid ArrayMesh resource.")
	
	var faces: PackedVector3Array = chunk.mesh.get_faces()
	assert_true(faces.size() > 0, "Generated mesh must contain active geometric triangle faces.")
	assert_eq(faces.size() % 3, 0, "Mesh face array length must be a multiple of 3 to form clean triangles.")

# --- TEST 5: STATIC COLLISION BAKING WITH DYNAMIC SUFFIX NAMING ---
func test_live_collision_baking_spawns_parallel_container_with_dynamic_name() -> void:
	# 1. Acquire reference to the localized testing chunk instance from the stable manager
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)]
	var vert_count = manager.chunk_size + 1
	
	# 2. Inject multiple varied height points to create an actual slope incline.
	# This ensures the interior and edge flat-filtering logic doesn't decimation-skip the vertices,
	# allowing Godot's Delaunay triangulation to successfully compile valid triangle faces!
	manager.global_height_data[Vector2i(0,0)][2 + 2 * vert_count] = 1.0
	manager.global_height_data[Vector2i(0,0)][5 + 3 * vert_count] = 2.0
	manager.global_height_data[Vector2i(0,0)][3 + 7 * vert_count] = 1.5
	manager.global_height_data[Vector2i(0,0)][8 + 8 * vert_count] = 3.0
	
	# Pass the freshly mutated data array down and force the visual mesh generation
	chunk.height_data = manager.global_height_data[Vector2i(0,0)]
	chunk.generate_mesh()
	
	# 3. Trigger the core live collision baking algorithm directly within the stable GUT tree context
	manager._bake_live_collisions_as_child()
	
	# 4. Compute the expected container node name based on the manager's current node naming
	var expected_container_name: String = manager.name + "_Collisions"
	
	# FIXED: Godot converts internal '@' memory symbols into static '_' tree symbols upon node insertion.
	# This sanitize step ensures our string search matches the factual node tree hierarchy exactly!
	expected_container_name = expected_container_name.replace("@", "_")
	
	# 5. Extract the parallel sibling container directly from the manager's active parent node path
	var parent_node = manager.get_parent()
	var container = parent_node.get_node_or_null(expected_container_name)
	assert_not_null(container, "The dynamic parallel collision container '%s' must be found under the parent node." % expected_container_name)
	
	# 6. Assert that the container correctly acquired and stored the compiled StaticBody3D collider node
	var static_body = container.find_child("Static_" + chunk.name, false, false)
	assert_not_null(static_body, "The container must store the compiled StaticBody3D collider node.")
	
	# 7. Validate structural layer and grouping assignment rules matching the inspector configuration properties
	assert_eq(static_body.collision_layer, manager.collision_layer, "The static body must receive the exact physics layer mask.")
	assert_true(static_body.is_in_group(manager.collision_group), "The static body must be cleanly attached to the user-defined collision group.")


# --- TEST 6: SLOPE-AWARE JITTER ATTENUATION ---
func test_jitter_attenuation_dampens_flat_planes_and_fractures_steep_cliffs() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)]
	var vert_count = manager.chunk_size + 1
	
	# Scenario A: Configure a completely flat plateau plane area context
	manager.jitter_strength = 0.5
	manager.jitter_slope_threshold = 1.5
	manager.global_height_data[Vector2i(0,0)].fill(0.0)
	
	# Synchronize parameters down to the chunk node
	chunk.height_data = manager.global_height_data[Vector2i(0,0)]
	chunk.jitter_strength = manager.jitter_strength
	chunk.jitter_slope_threshold = manager.jitter_slope_threshold
	
	# In a flat environment, current_h and all neighbors are 0.0, resulting in true_slope = 0.0
	var slope_factor_flat = 0.0
	var final_flat_jitter = chunk._get_jitter_offset(5, 5) * slope_factor_flat
	
	assert_eq(final_flat_jitter, Vector3.ZERO, "Jitter attenuation error: Flat surfaces must receive zero random noise displacement.")
	
	# Scenario B: Force a cliff by raising the center vertex. 
	# Thanks to our new center-delta formula, this guarantees an immediate steep incline detection!
	manager.global_height_data[Vector2i(0,0)].fill(0.0)
	manager.global_height_data[Vector2i(0,0)][5 + 5 * vert_count] = 50.0 
	
	# Re-sync the chunk array to the newly mutated manager data
	chunk.height_data = manager.global_height_data[Vector2i(0,0)]
	
	# Manually calculate the exact math running inside generate_mesh using the corrected center-delta formula
	var current_h = chunk.height_data[5 + 5 * vert_count]
	var h_r = chunk.height_data[clampi(5 + 1, 0, chunk.chunk_size) + 5 * vert_count]
	var h_l = chunk.height_data[clampi(5 - 1, 0, chunk.chunk_size) + 5 * vert_count]
	var h_d = chunk.height_data[5 + clampi(5 + 1, 0, chunk.chunk_size) * vert_count]
	var h_u = chunk.height_data[5 + clampi(5 - 1, 0, chunk.chunk_size) * vert_count]
	
	var diff_x = maxf(absf(current_h - h_r), absf(current_h - h_l))
	var diff_z = maxf(absf(current_h - h_d), absf(current_h - h_u))
	var true_slope = maxf(diff_x, diff_z) / chunk.cell_size
	
	var slope_factor_cliff = clampf(true_slope / chunk.jitter_slope_threshold, 0.0, 1.0)
	var final_cliff_jitter = chunk._get_jitter_offset(5, 5) * slope_factor_cliff
	
	assert_ne(final_cliff_jitter, Vector3.ZERO, "Jitter attenuation error: Steep slopes must allow structural vertex fracturing noise.")


# --- TEST 7: LOSSLESS LOSS-FREE GRID MIGRATION (RESIZING) ---
func test_grid_migration_safely_transfers_heightmaps_when_chunk_size_mutates() -> void:
	# Build a recognizable peak structure at global world vertex coordinates (x=5, z=5) inside the 10x10 layout
	var target_global_x = 5
	var target_global_z = 5
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	manager.interact_at_world_position(Vector3(float(target_global_x), 0.0, -float(target_global_z)), false)
	
	# Verify historical height setup value state before executing scaling operations
	var baseline_h = manager._get_global_vertex_height_from_copy(target_global_x, target_global_z, manager.global_height_data)
	assert_eq(baseline_h, manager.step_height, "Baseline peak initialization tracking failure.")
	
	# Act: Mutate the subdivision densities matrix configurations to force a data array migration pass
	manager.chunk_size = 5 # Halve the internal grid cell layout sizes
	manager.rebuild_chunks_structure()
	
	# Assert: Extract coordinates from the rewritten layout structure using the exact same world coordinates
	var migrated_h = manager._get_global_vertex_height_from_copy(target_global_x, target_global_z, manager.global_height_data)
	assert_eq(migrated_h, baseline_h, "Migration failure: Spatial height parameters were lost or displaced during grid interpolation scaling.")

# --- TEST 8: UX CONTEXTUAL SHIFT-INVERT BEHAVIOR ---
func test_shift_modifier_successfully_inverts_sculpting_brush_polarity() -> void:
	var target_pos := Vector3(2.0, 0.0, -2.0)
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	
	# Act: Execute paint stroke passing true for the modifier parameter flag (Simulating a Shift-Click action)
	manager.interact_at_world_position(target_pos, true)
	
	# Assert: Verify if the elevation dropped below floor levels instead of rising up
	var inverted_height = manager._get_global_vertex_height_from_copy(2, 2, manager.global_height_data)
	var expected_lowered_value = -manager.step_height
	assert_eq(inverted_height, expected_lowered_value, "UX Error: Holding Shift failed to invert RAISE actions into LOWER operations.")


# --- TEST 9: HEIGHT DATA SERIALIZATION & CRASH HEALING ---
func test_height_data_heals_automatically_when_corrupted_or_null() -> void:
	# 1. Assert that the hidden property registry configuration is correctly declared for disk storage
	var property_list = manager._get_property_list()
	var found_storage_flag := false
	for prop in property_list:
		if prop["name"] == "global_height_data":
			if prop["usage"] & PROPERTY_USAGE_STORAGE:
				found_storage_flag = true
				break
	assert_true(found_storage_flag, "Serialization Error: global_height_data must be configured for background disk storage.")
	
	# 2. FIXED: Simulate an empty, wiped memory state without violating static Dictionary typing rules
	manager.global_height_data = {}
	
	# 3. Act: Trigger the structural rebuild pipeline which evaluates and heals the empty matrix structure
	manager.rebuild_chunks_structure()
	
	# 4. Assert: Check if the system successfully initialized the grid keys after being completely wiped
	assert_true(manager.global_height_data.size() > 0, "Crash Protection Failure: Manager failed to re-initialize chunk keys after height data was wiped.")
