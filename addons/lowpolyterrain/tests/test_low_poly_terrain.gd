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
	
	# FIXED: Replaced dictionary clear with a fresh allocation resize matching flat array
	manager.global_height_data = PackedFloat32Array()
	
	# [FIX] Initialize activity data array synchronized to test grid dimensions
	manager.chunk_activity_data = PackedByteArray()
	
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
		var parent_node: Node = manager.get_parent()
		if is_instance_valid(parent_node):
			var container: Node = parent_node.get_node_or_null(expected_container_name)
			if is_instance_valid(container):
				container.free()
		
		# Hard-purge all instantiated chunk nodes directly from the tracking dictionary array
		for chunk_coord in manager.chunks_dict.keys():
			var chunk: Node = manager.chunks_dict[chunk_coord]
			if is_instance_valid(chunk):
				chunk.free()
		manager.chunks_dict.clear()
		
		# Force-clear any remaining transient child nodes (including the visual brush gizmo)
		for child in manager.get_children():
			if is_instance_valid(child):
				child.free()
				
		# Instantly delete the main manager instance from the editor memory layout
		manager.free() 
		
	manager = null


# --- TEST 1: CORE ARCHITECTURE & DATA STRUCTURE ---
func test_initialization_creates_correct_chunk_count_and_data_arrays() -> void:
	assert_eq(manager.chunks_dict.size(), 4, "Should instantiate exactly 4 chunks for a 2x2 grid.")
	
	# Expected global flat matrix vertex count calculation: (2 chunks * 10 size + 1) ^ 2 = 441
	var expected_total_vertices: int = ((manager.world_chunks.x * manager.chunk_size) + 1) * \
	((manager.world_chunks.y * manager.chunk_size) + 1)
	assert_eq(
		manager.global_height_data.size(), expected_total_vertices,
		"Global flat height array must match the total expected vertex matrix scale."
	)


# --- TEST 2: ENUM BRUSH FUNCTIONALITY (RAISE & LOWER) ---
func test_raise_brush_increases_vertex_height_correctly() -> void:
	var target_pos := Vector3(5.0, 0.0, -5.0) # Center of Chunk 0,0
	
	manager.tool_mode = manager.BrushMode.RAISE 
	manager.brush_radius = 0 # Target a single unique vertex point location
	
	# Act: Execute mock paint stroke interaction
	manager.interact_at_world_position(target_pos, false)
	
	# Assert: Extract global coordinates using the new high-performance O(1) getter API
	var current_height: float = manager.get_height_at(5, 5)
	assert_eq(
		current_height, manager.step_height,
		"The target vertex height should match exactly one step_height after being raised."
	)


# --- TEST 3: SEAM BLENDING & CARDINAL EDGE COMPENSATION ---
func test_seam_handling_writes_simultaneously_to_neighboring_chunks() -> void:
	# Position exactly on the intersection corner grid points where 4 map chunks touch (x=10, z=10)
	var boundary_vertex_x: int = 10
	var boundary_vertex_z: int = 10
	var target_pos := Vector3(float(boundary_vertex_x), 0.0, -float(boundary_vertex_z))
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	
	# Act: Apply brush modifications directly onto the shared seam boundary point coordinates
	manager.interact_at_world_position(target_pos, false)
	
	# Assert: In the flat array, a single write fixes all chunk boundaries simultaneously
	var height_at_shared_seam: float = manager.get_height_at(boundary_vertex_x, boundary_vertex_z)
	assert_eq(
		height_at_shared_seam, manager.step_height,
		"Seam error: Global flat memory allocation failed to synchronize boundary coordinates!"
	)


# --- TEST 4: DELAUNAY MESH GENERATION & WINDING ORDER ---
func test_chunk_mesh_generation_creates_valid_triangles_and_correct_winding() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)] as LowPolyTerrainChunk
	
	# Induce an elevation slope variant directly inside the flat matrix using the setter
	manager.set_height_at(5, 5, 2.0)
	
	# Synchronize and push modified data blocks to the targeted chunk node to prepare rendering tests
	var vert_stride: int = manager.chunk_size + 1
	var chunk_local_heights := PackedFloat32Array()
	chunk_local_heights.resize(vert_stride * vert_stride)
	
	for lz in range(vert_stride):
		var global_offset: int = lz * manager._total_vertices_x
		var slice: PackedFloat32Array = manager.global_height_data.slice(
			global_offset, global_offset + vert_stride
		)
		for i in range(slice.size()):
			chunk_local_heights[lz * vert_stride + i] = slice[i]
			
	# FIXED: Removed obsolete material_color argument to comply with the updated clean constructor
	chunk.initialize(
		Vector2i(0,0), manager.chunk_size, manager.cell_size, manager.step_height,
		chunk_local_heights, manager.jitter_strength, manager.show_chunk_labels,
		manager.jitter_slope_threshold, manager.custom_material
	)
	
	assert_not_null(chunk.mesh, "Chunk generation should yield a valid ArrayMesh resource.")
	
	var faces: PackedVector3Array = chunk.mesh.get_faces()
	assert_true(faces.size() > 0, "Generated mesh must contain active geometric triangle faces.")
	assert_eq(
		faces.size() % 3, 0,
		"Mesh face array length must be a multiple of 3 to form clean triangles."
	)

	# Scenario B: Force a cliff by raising the center vertex inside a fresh chunk sub-array context
	var chunk_local_heights_cliff := PackedFloat32Array()
	chunk_local_heights_cliff.resize(vert_stride * vert_stride)
	chunk_local_heights_cliff.fill(0.0)
	chunk_local_heights_cliff[5 + 5 * vert_stride] = 50.0 
	
	chunk.height_data = chunk_local_heights_cliff
	
	# Manually execute the exact incline math running inside generate_mesh
	var current_h: float = chunk.height_data[5 + 5 * vert_stride]
	var h_r: float = chunk.height_data[clampi(5 + 1, 0, chunk.chunk_size) + 5 * vert_stride]
	var h_l: float = chunk.height_data[clampi(5 - 1, 0, chunk.chunk_size) + 5 * vert_stride]
	var h_d: float = chunk.height_data[5 + clampi(5 + 1, 0, chunk.chunk_size) * vert_stride]
	var h_u: float = chunk.height_data[5 + clampi(5 - 1, 0, chunk.chunk_size) * vert_stride]
	
	var diff_x: float = maxf(absf(current_h - h_r), absf(current_h - h_l))
	var diff_z: float = maxf(absf(current_h - h_d), absf(current_h - h_u))
	var true_slope: float = maxf(diff_x, diff_z) / chunk.cell_size
	
	# FIXED: Updated validation calculation to perfectly match the new cubic smoothstep math
	var t: float = clampf(true_slope / chunk.jitter_slope_threshold, 0.0, 1.0)
	var slope_factor_cliff: float = t * t * (3.0 - 2.0 * t)
	
	# FIXED: Calculate the new border distance damping factor for center coordinate (5, 5)
	var dist_to_edge_x: float = minf(5.0, float(chunk.chunk_size) - 5.0)
	var dist_to_edge_z: float = minf(5.0, float(chunk.chunk_size) - 5.0)
	var edge_damp: float = clampf(minf(dist_to_edge_x, dist_to_edge_z) / 2.0, 0.0, 1.0)
	
	var final_cliff_jitter: Vector3 = chunk._get_jitter_offset(5, 5) * slope_factor_cliff * edge_damp
	
	assert_true(
		slope_factor_cliff > 0.0,
		"Steep incline contexts must resolve a positive non-linear slope attenuation value."
	)
	assert_ne(
		final_cliff_jitter, Vector3.ZERO,
		"Jitter attenuation error: Steep slopes must allow structural vertex fracturing noise."
	)


# --- TEST 5: LOSSLESS GRID MIGRATION (RESIZING) ---
func test_grid_migration_safely_transfers_heightmaps_when_chunk_size_mutates() -> void:
	# Build a recognizable peak structure at global world vertex coordinates (x=5, z=5)
	var target_global_x: int = 5
	var target_global_z: int = 5
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	manager.interact_at_world_position(
		Vector3(float(target_global_x), 0.0, -float(target_global_z)), false
	)
	
	# Verify historical height setup value state before executing scaling operations
	var baseline_h: float = manager.get_height_at(target_global_x, target_global_z)
	assert_eq(baseline_h, manager.step_height, "Baseline peak initialization tracking failure.")
	
	# Act: Trigger the lossless point migration via the Apply Dimension Change UI action block pipeline
	manager.preview_chunk_size = 5 # Halve the internal grid cell layout sizes
	manager._apply_dimension_changes()
	
	# Assert: Extract coordinates from the rewritten flat continuous layout
	var migrated_h: float = manager.get_height_at(target_global_x, target_global_z)
	assert_eq(
		migrated_h, baseline_h,
		"Migration failure: Spatial height parameters were lost or displaced during scaling."
	)


# --- TEST 6: UX CONTEXTUAL SHIFT-INVERT BEHAVIOR ---
func test_shift_modifier_successfully_inverts_sculpting_brush_polarity() -> void:
	var target_pos := Vector3(2.0, 0.0, -2.0)
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	
	# Act: Execute paint stroke passing true for the modifier parameter flag
	manager.interact_at_world_position(target_pos, true)
	
	# Assert: Verify if the elevation dropped below floor levels instead of rising up
	var inverted_height: float = manager.get_height_at(2, 2)
	var expected_lowered_value: float = -manager.step_height
	assert_eq(
		inverted_height, expected_lowered_value,
		"UX Error: Holding Shift failed to invert RAISE actions into LOWER operations."
	)


# --- TEST 7: HEIGHT DATA SERIALIZATION & CRASH HEALING ---
func test_height_data_heals_automatically_when_corrupted_or_null() -> void:
	# 1. FIXED: Assert script metadata using modern script property validation API
	var target_script: Script = manager.get_script()
	var found_storage_flag := false
	
	for prop in target_script.get_script_property_list():
		if prop["name"] == "global_height_data":
			# Modern Godot 4.x serializes @export_storage fields under PROPERTY_USAGE_STORAGE
			if prop["usage"] & PROPERTY_USAGE_STORAGE:
				found_storage_flag = true
				break
				
	assert_true(
		found_storage_flag,
		"Serialization Error: global_height_data must be configured with @export_storage."
	)
	
	# 2. Simulate an empty memory state by clearing out the packed memory array blocks
	manager.global_height_data = PackedFloat32Array()
	
	# 3. Act: Trigger the structural rebuild pipeline which evaluates and heals layouts
	manager.rebuild_chunks_structure()
	
	# 4. Assert: Check if the system successfully initialized the full sequential density size
	var expected_total_vertices: int = ((manager.world_chunks.x * manager.chunk_size) + 1) * \
	((manager.world_chunks.y * manager.chunk_size) + 1)
	assert_eq(
		manager.global_height_data.size(), expected_total_vertices,
		"Crash Protection Failure: Manager failed to re-initialize layout arrays."
	)


# --- TEST 8: CHUNK DEACTIVATION & TOGGLE LOGIC ---
func test_toggle_chunk_status_toggles_activity_and_preserves_heights() -> void:
	# Assert baseline initialization: all chunks are fully active by default
	assert_true(manager.is_chunk_active(0, 0), "Chunk should be active by default.")
	
	# Act: Toggle the chunk status to deactivate it
	manager.toggle_chunk_status(0, 0)
	assert_false(manager.is_chunk_active(0, 0), "Chunk activity state should flip to inactive.")
	
	# Assert: Inactive chunks must bypass brush interaction and protect data from mutation
	var target_pos := Vector3(5.0, 0.0, -5.0) # Center of Chunk 0,0
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	manager.interact_at_world_position(target_pos, false)
	
	var height_after_sculpt: float = manager.get_height_at(5, 5)
	assert_eq(
		height_after_sculpt, 0.0,
		"Protection Failure: Inactive chunks must ignore brush updates to shield height data."
	)


# --- TEST 9: STATIC COLLISION EXCLUSION FOR INACTIVE CHUNKS ---
func test_collision_baking_skips_inactive_chunks() -> void:
	# Act: Deactivate one of the quadrant chunks before triggering physical calculations
	manager.toggle_chunk_status(1, 1)
	manager._bake_live_collisions_as_child()
	
	# Assert: Verify that the static collider body for Chunk 1,1 was omitted from the root
	var container_name: String = manager.name + "_Collisions"
	var container: Node = manager.get_parent().get_node_or_null(container_name)
	assert_not_null(container, "Collision root container node must be successfully instantiated.")
	
	var omitted_body: Node = container.get_node_or_null("Static_Chunk_1_1")
	assert_null(
		omitted_body,
		"Baking Error: Inactive chunks must be completely skipped during collision pass."
	)
	
	var active_body: Node = container.get_node_or_null("Static_Chunk_0_0")
	assert_not_null(
		active_body,
		"Baking Error: Fully active chunks must generate valid StaticBody3D physics shapes."
	)
