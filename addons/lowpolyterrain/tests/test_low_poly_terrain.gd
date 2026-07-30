extends GutTest

## Automated stability test suite for the Low Poly Terrain plugin.
## Verifies core matrix allocation, seam synchronization, enum-driven brushes, and physics baking.

var manager: LowPolyTerrainManager = null


# Runs automatically before EACH individual test method
func before_each() -> void:
	manager = LowPolyTerrainManager.new()
	manager.name = "TestTerrainManager"
	add_child(manager)
	
	manager.world_chunks = Vector2i(2, 2)
	manager.chunk_size = 10
	manager.cell_size = 1.0
	manager.step_height = 0.5
	manager.brush_strength = 1.0
	manager.collision_layer = 2
	manager.collision_group = "Wall"
	
	# INITIALIZE NEW FALLOFF VARIABLE TO HARD EDGES FOR PRECISE ASSERTS
	manager.brush_falloff_strength = 0.0
	
	manager.global_height_data = PackedFloat32Array()
	manager.chunk_activity_data = PackedByteArray()
	manager._setup_pending = false
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
	manager.brush_radius = 1 # FIXED: Enforce a minimum radius of 1 to prevent division by zero (NaN)
	
	# Act: Execute mock paint stroke interaction
	manager.interact_at_world_position(target_pos, false)
	
	# Assert: Extract global coordinates using the O(1) getter API
	var current_height: float = manager.get_height_at(5, 5)
	assert_eq(
		current_height, manager.step_height * manager.brush_strength,
		"The target vertex height should match exactly one step_height after being raised."
	)


# --- TEST 3: SEAM BLENDING & CARDINAL EDGE COMPENSATION ---
func test_seam_handling_writes_simultaneously_to_neighboring_chunks() -> void:
	var boundary_vertex_x: int = 10
	var boundary_vertex_z: int = 10
	var target_pos := Vector3(float(boundary_vertex_x), 0.0, -float(boundary_vertex_z))
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 1 # FIXED: Enforce a minimum radius of 1 to prevent division by zero (NaN)
	
	# Act: Apply brush modifications directly onto the shared seam boundary point coordinates
	manager.interact_at_world_position(target_pos, false)
	
	# Assert: In the flat array, a single write fixes all chunk boundaries simultaneously
	var height_at_shared_seam: float = manager.get_height_at(boundary_vertex_x, boundary_vertex_z)
	assert_eq(
		height_at_shared_seam, manager.step_height * manager.brush_strength,
		"Seam error: Global flat memory allocation failed to synchronize boundary coordinates!"
	)

# --- TEST 4:
func test_chunk_mesh_generation_creates_valid_triangles_and_correct_winding() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)] as LowPolyTerrainChunk
	manager.set_height_at(5, 5, 2.0)
	
	var vert_stride: int = manager.chunk_size + 1
	var chunk_local_heights := PackedFloat32Array()
	chunk_local_heights.resize(vert_stride * vert_stride)
	
	# Direct O(1) index mapping matching the optimized manager implementation without .slice()
	for lz in range(vert_stride):
		var global_offset: int = lz * manager._total_vertices_x
		for i in range(vert_stride):
			chunk_local_heights[lz * vert_stride + i] = manager.global_height_data[global_offset + i]
			
	chunk.initialize(
		Vector2i(0,0), manager.chunk_size, manager.cell_size, manager.step_height,
		chunk_local_heights, manager.jitter_strength,
		manager.jitter_slope_threshold, manager.custom_material
	)
	
	assert_not_null(chunk.mesh, "Chunk generation should yield a valid ArrayMesh resource.")
	var faces: PackedVector3Array = chunk.mesh.get_faces()
	assert_true(faces.size() > 0, "Generated mesh must contain active geometric triangle faces.")
	assert_eq(faces.size() % 3, 0, "Mesh face array length must be a multiple of 3.")

	var chunk_local_heights_cliff := PackedFloat32Array()
	chunk_local_heights_cliff.resize(vert_stride * vert_stride)
	chunk_local_heights_cliff.fill(0.0)
	chunk_local_heights_cliff[5 + 5 * vert_stride] = 50.0 
	chunk.height_data = chunk_local_heights_cliff
	
	var current_h: float = chunk.height_data[5 + 5 * vert_stride]
	var h_r: float = chunk.height_data[clampi(5 + 1, 0, chunk.chunk_size) + 5 * vert_stride]
	var h_l: float = chunk.height_data[clampi(5 - 1, 0, chunk.chunk_size) + 5 * vert_stride]
	var h_d: float = chunk.height_data[5 + clampi(5 + 1, 0, chunk.chunk_size) * vert_stride]
	var h_u: float = chunk.height_data[5 + clampi(5 - 1, 0, chunk.chunk_size) * vert_stride]
	
	var diff_x: float = maxf(absf(current_h - h_r), absf(current_h - h_l))
	var diff_z: float = maxf(absf(current_h - h_d), absf(current_h - h_u))
	var true_slope: float = maxf(diff_x, diff_z) / chunk.cell_size
	
	var t: float = clampf(true_slope / chunk.jitter_slope_threshold, 0.0, 1.0)
	var slope_factor_cliff: float = t * t * (3.0 - 2.0 * t)
	
	var dist_to_edge_x: float = minf(5.0, float(chunk.chunk_size) - 5.0)
	var dist_to_edge_z: float = minf(5.0, float(chunk.chunk_size) - 5.0)
	var edge_damp: float = clampf(minf(dist_to_edge_x, dist_to_edge_z) / 2.0, 0.0, 1.0)
	
	var final_cliff_jitter: Vector3 = chunk._get_jitter_offset(5, 5) * slope_factor_cliff * edge_damp
	assert_true(slope_factor_cliff > 0.0, "Steep incline must resolve positive slope attenuation.")
	assert_ne(final_cliff_jitter, Vector3.ZERO, "Steep slopes must allow structural fracturing.")



# --- TEST 5: LOSSLESS GRID MIGRATION (RESIZING) ---
func test_grid_migration_safely_transfers_heightmaps_when_chunk_size_mutates() -> void:
	var target_global_x: int = 5
	var target_global_z: int = 5
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 1 # FIXED: Enforce a minimum radius of 1 to prevent division by zero (NaN)
	manager.interact_at_world_position(Vector3(float(target_global_x), 0.0, -float(target_global_z)), false)
	
	var baseline_h: float = manager.get_height_at(target_global_x, target_global_z)
	assert_eq(baseline_h, manager.step_height * manager.brush_strength, "Baseline peak tracking failure.")
	
	manager.preview_chunk_size = 5
	manager._apply_dimension_changes()
	
	var migrated_h: float = manager.get_height_at(target_global_x, target_global_z)
	assert_eq(migrated_h, baseline_h, "Spatial height parameters were lost or displaced during scaling.")


# --- TEST 6: UX CONTEXTUAL SHIFT-INVERT BEHAVIOR ---
func test_shift_modifier_successfully_inverts_sculpting_brush_polarity() -> void:
	var target_pos := Vector3(2.0, 0.0, -2.0)
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 1 # FIXED: Enforce a minimum radius of 1 to prevent division by zero (NaN)
	manager.interact_at_world_position(target_pos, true)
	
	var inverted_height: float = manager.get_height_at(2, 2)
	var expected_lowered_value: float = -(manager.step_height * manager.brush_strength)
	assert_eq(inverted_height, expected_lowered_value, "Holding Shift failed to invert RAISE into LOWER.")


# --- TEST 7: HEIGHT DATA SERIALIZATION & CRASH HEALING ---
func test_height_data_heals_automatically_when_corrupted_or_null() -> void:
	var target_script: Script = manager.get_script()
	var found_storage_flag := false
	
	for prop in target_script.get_script_property_list():
		if prop["name"] == "global_height_data":
			if prop["usage"] & PROPERTY_USAGE_STORAGE:
				found_storage_flag = true
				break
				
	assert_true(found_storage_flag, "global_height_data must be configured with @export_storage.")
	
	manager.global_height_data = PackedFloat32Array()
	manager.rebuild_chunks_structure()
	
	var expected_total_vertices: int = ((manager.world_chunks.x * manager.chunk_size) + 1) * \
	((manager.world_chunks.y * manager.chunk_size) + 1)
	assert_eq(manager.global_height_data.size(), expected_total_vertices, "Crash Protection Failure.")


# --- TEST 8: CHUNK DEACTIVATION & TOGGLE LOGIC ---
func test_toggle_chunk_status_toggles_activity_and_preserves_heights() -> void:
	assert_true(manager.is_chunk_active(0, 0), "Chunk should be active by default.")
	
	var target_pos := Vector3(5.0, 0.0, -5.0) # Center of Chunk 0,0
	manager.brush_radius = 1
	manager.set_chunk_status_in_radius(target_pos, false)
	assert_false(manager.is_chunk_active(0, 0), "Chunk activity state should flip to inactive.")
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 0
	manager.interact_at_world_position(target_pos, false)
	
	var height_after_sculpt: float = manager.get_height_at(5, 5)
	assert_eq(height_after_sculpt, 0.0, "Inactive chunks must shield height data from brush mutations.")


# --- TEST 9: STATIC COLLISION EXCLUSION FOR INACTIVE CHUNKS ---
func test_collision_baking_skips_inactive_chunks() -> void:
	var target_pos_inactive := Vector3(15.0, 0.0, -15.0) # Center of Chunk 1,1
	manager.brush_radius = 1
	manager.set_chunk_status_in_radius(target_pos_inactive, false)
	manager._bake_live_collisions_as_child()
	
	var container_name: String = manager.name + "_Collisions"
	var container: Node = manager.get_parent().get_node_or_null(container_name)
	assert_not_null(container, "Collision root container node must be successfully instantiated.")
	
	var omitted_body: Node = container.get_node_or_null("Static_Chunk_1_1")
	assert_null(omitted_body, "Inactive chunks must be completely skipped during collision pass.")
	
	var active_body: Node = container.get_node_or_null("Static_Chunk_0_0")
	assert_not_null(active_body, "Fully active chunks must generate valid physics shapes.")


# --- TEST 10: BRUSH STRENGTH MULTIPLIER VALIDATION ---
func test_brush_strength_scales_elevation_increments() -> void:
	var target_pos := Vector3(5.0, 0.0, -5.0)
	
	manager.tool_mode = manager.BrushMode.RAISE
	manager.brush_radius = 1 # FIXED: Enforce a minimum radius of 1 to prevent division by zero (NaN)
	manager.brush_strength = 3.0
	
	manager.interact_at_world_position(target_pos, false)
	
	var expected_height: float = manager.step_height * 3.0
	assert_eq(manager.get_height_at(5, 5), expected_height, "Brush strength multiplier failed.")


# --- TEST 11: VISIBILITY TOGGLE FOR DEACTIVATED CHUNKS ---
func test_deactivated_chunks_visibility_respects_inspector_toggle() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)] as LowPolyTerrainChunk
	
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager.show_deactivated_chunks = true
	await wait_process_frames(2)
	assert_true(chunk.visible, "Deactivated chunk preview mesh should be visible.")
	
	manager.show_deactivated_chunks = false
	manager.rebuild_chunks_structure()
	await wait_process_frames(2)
	assert_false(chunk.visible, "Deactivated chunk preview mesh should be hidden.")


# --- TEST 12: RADIUS-BASED MULTI-CHUNK MANIPULATION ---
func test_brush_mode_activation_and_deactivation_respects_radius() -> void:
	var seam_pos := Vector3(10.0, 0.0, -10.0)
	manager.brush_radius = 5
	manager.set_chunk_status_in_radius(seam_pos, false)
	
	assert_false(manager.is_chunk_active(0, 0), "Chunk 0,0 failed to deactivate within radius.")
	assert_false(manager.is_chunk_active(1, 0), "Chunk 1,0 failed to deactivate within radius.")
	assert_false(manager.is_chunk_active(0, 1), "Chunk 0,1 failed to deactivate within radius.")
	assert_false(manager.is_chunk_active(1, 1), "Chunk 1,1 failed to deactivate within radius.")


# --- TEST 13: GLOBAL SMOOTHING VISIBILITY FOR INACTIVE CHUNKS ---
func test_global_smoothing_preserves_deactivated_chunks_visibility() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)] as LowPolyTerrainChunk
	
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager.show_deactivated_chunks = true
	manager.rebuild_chunks_structure()
	manager._smooth_entire_terrain()
	
	assert_true(chunk.visible, "Global terrain smoothing accidentally hid deactivated chunk preview meshes.")


# --- TEST 14: AUTOMATIC PREVIEW ENABLING FOR CHUNK MANIPULATION ---
func test_chunk_brush_automatically_forces_deactivated_previews_visible() -> void:
	manager.show_deactivated_chunks = false
	manager.tool_mode = manager.BrushMode.ACTIVATE_CHUNK
	
	if manager.tool_mode == manager.BrushMode.ACTIVATE_CHUNK or manager.tool_mode == manager.BrushMode.DEACTIVATE_CHUNK:
		manager.show_deactivated_chunks = true
		manager.rebuild_chunks_structure()
	
	assert_true(manager.show_deactivated_chunks, "Switching to chunk tools must enforce visibility.")


func test_material_assignment_stability() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0,0)] as LowPolyTerrainChunk
	var test_mat := StandardMaterial3D.new()
	
	manager.custom_material = test_mat
	manager._update_single_chunk(Vector2i(0,0))
	
	assert_eq(chunk.material_override, test_mat, "Custom material mapping failed on incremental single-chunk update.")


##@@
# --- WORLD SPACE HEIGHT QUERY ---


func test_world_height_matches_the_grid_on_exact_vertices() -> void:
	manager.set_height_at(3, 4, 7.25)
	# cell_size is 1.0 here, and Z runs negative in world space.
	assert_almost_eq(manager.get_height_at_world_coords(3.0, -4.0), 7.25, 0.0001,
		"A query straight on a vertex must return that vertex's stored height.")


func test_world_height_interpolates_between_vertices() -> void:
	manager.set_height_at(0, 0, 0.0)
	manager.set_height_at(1, 0, 10.0)

	assert_almost_eq(manager.get_height_at_world_coords(0.5, 0.0), 5.0, 0.0001,
		"Halfway between two vertices must return their average.")
	assert_almost_eq(manager.get_height_at_world_coords(0.25, 0.0), 2.5, 0.0001,
		"A quarter along must interpolate linearly.")


func test_world_height_clamps_outside_the_terrain() -> void:
	manager.set_height_at(0, 0, 4.0)

	# Far outside on both axes must fall back to the nearest border vertex.
	assert_almost_eq(manager.get_height_at_world_coords(-500.0, 500.0), 4.0, 0.0001,
		"Outside the terrain the nearest border height must be returned.")


func test_world_height_follows_the_manager_transform() -> void:
	manager.set_height_at(3, 4, 2.0)
	manager.position = Vector3(100.0, 25.0, -50.0)

	# The sample is taken in local space and handed back in world space, so the manager's own
	# elevation has to show up in the result.
	assert_almost_eq(manager.get_height_at_world_coords(103.0, -54.0), 27.0, 0.0001,
		"A moved manager must report world heights, not local ones.")

	manager.position = Vector3.ZERO
	manager.scale = Vector3(1.0, 3.0, 1.0)
	assert_almost_eq(manager.get_height_at_world_coords(3.0, -4.0), 6.0, 0.0001,
		"A vertically scaled manager must scale the reported height too.")


func test_world_height_position_wrapper_ignores_y() -> void:
	manager.set_height_at(2, 2, 5.5)
	var from_coords: float = manager.get_height_at_world_coords(2.0, -2.0)
	var from_position: float = manager.get_height_at_world_position(Vector3(2.0, 999.0, -2.0))
	assert_almost_eq(from_position, from_coords, 0.0001,
		"The convenience wrapper must ignore the Y component it is handed.")


func test_is_inside_terrain_reports_the_grid_bounds() -> void:
	# 2 chunks of 10 cells at 1 metre each spans 0..20 metres, Z negative.
	assert_true(manager.is_inside_terrain(10.0, -10.0), "The centre must be inside.")
	assert_true(manager.is_inside_terrain(0.0, 0.0), "The origin corner must be inside.")
	assert_true(manager.is_inside_terrain(20.0, -20.0), "The far corner must be inside.")
	assert_false(manager.is_inside_terrain(20.5, -10.0), "Just past the east edge is outside.")
	assert_false(manager.is_inside_terrain(-0.5, -10.0), "Just past the west edge is outside.")
	assert_false(manager.is_inside_terrain(10.0, 0.5), "Positive Z is outside the grid.")


## Builds a deterministic relief and returns the worst deviation from the real mesh surface,
## together with the largest height step between neighbouring vertices.
func _measure_height_query_drift() -> Dictionary:
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_height_at(gx, gz, sin(float(gx) * 0.4) * 3.0 + cos(float(gz) * 0.3) * 2.0)
	manager.rebuild_chunks_structure()

	var max_step: float = 0.0
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x - 1):
			max_step = maxf(max_step,
				absf(manager.get_height_at(gx + 1, gz) - manager.get_height_at(gx, gz)))

	var cache: Dictionary = {}
	var result: Dictionary = {}
	var worst: float = 0.0
	var samples: int = 0

	for i in range(40):
		var wx: float = 3.0 + float(i) * 0.35
		var wz: float = -3.0 - float(i) * 0.28
		if not LowPolyTerrainPicking.raycast_terrain(
				manager, Vector3(wx, 200.0, wz), Vector3.DOWN, cache, result):
			continue
		samples += 1
		worst = maxf(worst, absf(
			manager.get_height_at_world_coords(wx, wz) - (result["point"] as Vector3).y))

	return { "worst": worst, "max_step": max_step, "samples": samples }


func test_world_height_is_exact_without_jitter() -> void:
	# Jitter is the ONLY reason the matrix sample and the mesh can disagree: without it the
	# mesh vertices sit exactly on the grid the matrix describes.
	manager.jitter_strength = 0.0
	var measured: Dictionary = _measure_height_query_drift()

	assert_gt(int(measured["samples"]), 20, "Enough rays must have hit to mean anything.")
	assert_lt(float(measured["worst"]), 0.001,
		"Without jitter the query must match the real surface, but drifted %.4f m."
		% measured["worst"])


func test_world_height_drift_stays_within_the_documented_bound() -> void:
	# With jitter the error scales with jitter_strength times the height step between
	# neighbouring vertices, because a sideways vertex shift reads as a height difference on
	# a slope. Measured worst case was about 1.4x that product; 2.5x is the guard rail.
	manager.jitter_strength = 0.5
	var measured: Dictionary = _measure_height_query_drift()

	var bound: float = 2.5 * manager.jitter_strength * float(measured["max_step"])
	assert_gt(int(measured["samples"]), 20, "Enough rays must have hit to mean anything.")
	assert_lt(float(measured["worst"]), bound,
		"Drift %.3f m exceeded the documented bound of %.3f m (max step %.3f m per cell)."
		% [measured["worst"], bound, measured["max_step"]])


##@@
# --- BAKED COLLIDER CULLING ---
# These assert the ACTUAL disabled flags rather than the culling bookkeeping. Checking only
# the bookkeeping is what let the first pass silently leave every collider switched on.


func _count_enabled_baked_shapes() -> int:
	var container: Node = manager.get_parent().get_node_or_null(manager.name + "_Collisions")
	if container == null:
		return -1
	var count: int = 0
	for body in container.get_children():
		for child in body.get_children():
			if child is CollisionShape3D and not child.disabled:
				count += 1
	return count


func test_first_culling_pass_disables_everything_outside_the_radius() -> void:
	manager._bake_live_collisions_as_child()
	assert_eq(_count_enabled_baked_shapes(), 4, "Precondition: baking enables all 4 chunks.")

	# A 2 metre radius at the origin reaches only chunk (0,0) of this 10 metre grid.
	manager.update_collision_culling(Vector3.ZERO, 2.0)
	# disabled is written through set_deferred(), so the flags land at the end of the frame.
	await get_tree().process_frame

	assert_eq(_count_enabled_baked_shapes(), 1,
		"The very first pass must already switch off every chunk outside the radius.")


func test_culling_follows_a_moving_centre_across_baked_chunks() -> void:
	manager._bake_live_collisions_as_child()

	manager.update_collision_culling(Vector3.ZERO, 2.0)
	await get_tree().process_frame
	var container: Node = manager.get_parent().get_node_or_null(manager.name + "_Collisions")
	var near: CollisionShape3D = manager._find_baked_collision_shape(Vector2i(0, 0))
	var far: CollisionShape3D = manager._find_baked_collision_shape(Vector2i(1, 1))
	assert_false(near.disabled, "The chunk under the centre must be enabled.")
	assert_true(far.disabled, "The distant chunk must be disabled.")

	# Walk to the opposite corner of the 2x2 grid.
	manager.update_collision_culling(Vector3(18.0, 0.0, -18.0), 2.0)
	await get_tree().process_frame

	assert_true(near.disabled, "The chunk left behind must be switched off again.")
	assert_false(far.disabled, "The newly reached chunk must be switched on.")


##@@
# --- BAKED COLLIDER NAMING ---


func test_baked_collision_shapes_carry_their_chunk_coordinate() -> void:
	manager._bake_live_collisions_as_child()
	var container: Node = manager.get_parent().get_node_or_null(manager.name + "_Collisions")
	assert_not_null(container, "Precondition: the collision container exists.")

	for cz in range(manager.world_chunks.y):
		for cx in range(manager.world_chunks.x):
			var body: Node = container.get_node_or_null("Static_Chunk_%d_%d" % [cx, cz])
			assert_not_null(body, "Chunk (%d,%d) must have a baked body." % [cx, cz])
			assert_not_null(body.get_node_or_null("Chunk_%d_%d_Col" % [cx, cz]),
				"The shape of chunk (%d,%d) must be named after its coordinate." % [cx, cz])


func test_culling_resolves_shapes_by_type_not_by_name() -> void:
	manager._bake_live_collisions_as_child()

	var found: CollisionShape3D = manager._find_baked_collision_shape(Vector2i(0, 0))
	assert_not_null(found, "The renamed shape must still be resolvable.")
	assert_eq(found.name, "Chunk_0_0_Col", "Precondition: the new naming is in place.")

	# Scenes baked before the rename still carry the old name, so the lookup must not depend
	# on it. Simulate such a legacy node and make sure it is still found.
	manager._culling_shape_cache.clear()
	found.name = "CollisionShape3D"
	var legacy: CollisionShape3D = manager._find_baked_collision_shape(Vector2i(0, 0))
	assert_not_null(legacy, "A pre-rename shape must keep working with the culling lookup.")


##@@
# --- CHUNK BOUNDARY GRID OVERLAY ---
# Replaced the former per-chunk Label3D overlay. The builder is pure and runtime-safe, so the
# geometry can be asserted here even though the overlay node itself is editor-only.


func test_chunk_grid_mesh_spans_every_boundary_once() -> void:
	var grid: ArrayMesh = LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(
		Vector2i(2, 3), 10, 1.0)
	assert_not_null(grid, "The grid builder must produce a mesh.")

	assert_eq(grid.surface_get_primitive_type(0), Mesh.PRIMITIVE_LINES,
		"The overlay must be a line mesh, not triangles.")

	# One boundary per column and per row, plus the closing edge on each axis, two verts each.
	var expected_vertices: int = ((2 + 1) + (3 + 1)) * 2
	var verts: PackedVector3Array = grid.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(verts.size(), expected_vertices,
		"A 2x3 chunk world needs exactly %d line vertices." % expected_vertices)


func test_chunk_grid_mesh_covers_the_full_world_bounds() -> void:
	var grid: ArrayMesh = LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(
		Vector2i(2, 2), 10, 1.0)
	var bounds: AABB = grid.get_aabb()

	# 2 chunks of 10 cells at 1 metre each spans 20 metres, and Z runs negative.
	assert_almost_eq(bounds.position.x, 0.0, 0.0001, "Grid must start at the world origin in X.")
	assert_almost_eq(bounds.size.x, 20.0, 0.0001, "Grid must span the full world width.")
	assert_almost_eq(bounds.position.z, -20.0, 0.0001, "Grid must reach the far Z edge.")
	assert_almost_eq(bounds.size.z, 20.0, 0.0001, "Grid must span the full world depth.")


func test_chunk_grid_cost_is_independent_of_chunk_count() -> void:
	# The point of replacing the labels: one mesh for the whole terrain instead of one per
	# chunk. Vertex count must grow with the grid PERIMETER, not with the chunk count.
	var small: ArrayMesh = LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(
		Vector2i(10, 10), 8, 1.0)
	var large: ArrayMesh = LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(
		Vector2i(100, 100), 8, 1.0)

	var small_verts: int = (small.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var large_verts: int = (large.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

	assert_eq(small_verts, 44, "A 100-chunk world needs 44 line vertices.")
	assert_eq(large_verts, 404, "A 10000-chunk world needs 404 line vertices.")
	assert_eq(small.get_surface_count(), 1, "One surface regardless of chunk count.")
	assert_eq(large.get_surface_count(), 1, "One surface regardless of chunk count.")


func test_chunk_grid_builder_rejects_degenerate_dimensions() -> void:
	assert_null(LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(Vector2i(0, 5), 10, 1.0),
		"A zero-width world must not produce a mesh.")
	assert_null(LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(Vector2i(5, 5), 0, 1.0),
		"A zero chunk size must not produce a mesh.")
	assert_null(LowPolyTerrainMeshBuilder.build_chunk_grid_mesh(Vector2i(5, 5), 10, 0.0),
		"A zero cell size must not produce a mesh.")


func test_chunk_grid_material_reads_through_terrain() -> void:
	var mat: StandardMaterial3D = LowPolyTerrainMeshBuilder.build_chunk_grid_material()
	assert_eq(mat.shading_mode, StandardMaterial3D.SHADING_MODE_UNSHADED,
		"An overlay must not be lit.")
	assert_true(mat.no_depth_test,
		"The grid must read through hills instead of vanishing inside them.")
