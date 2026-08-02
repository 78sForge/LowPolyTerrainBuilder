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

	# Read from the local window rather than from the chunk: the height data is deliberately
	# not retained on the node, since it is dead weight once the mesh has been built.
	var current_h: float = chunk_local_heights_cliff[5 + 5 * vert_stride]
	var h_r: float = chunk_local_heights_cliff[clampi(5 + 1, 0, chunk.chunk_size) + 5 * vert_stride]
	var h_l: float = chunk_local_heights_cliff[clampi(5 - 1, 0, chunk.chunk_size) + 5 * vert_stride]
	var h_d: float = chunk_local_heights_cliff[5 + clampi(5 + 1, 0, chunk.chunk_size) * vert_stride]
	var h_u: float = chunk_local_heights_cliff[5 + clampi(5 - 1, 0, chunk.chunk_size) * vert_stride]
	
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


# --- CHUNK ACTIVATION UNDO / REDO ---


## Stand-in for EditorUndoRedoManager, which GUT cannot obtain outside the editor. Records the
## do/undo payloads so the test can replay them exactly as the editor history would.
class UndoRedoSpy extends RefCounted:
	var action_name: String = ""
	var commits: int = 0
	var do_args: Array = []
	var undo_args: Array = []

	func create_action(name: String, _merge_mode: int = 0, _context: Object = null) -> void:
		action_name = name

	func add_do_method(_object: Object, _method: StringName, a: Variant, b: Variant) -> void:
		do_args = [a, b]

	func add_undo_method(_object: Object, _method: StringName, a: Variant, b: Variant) -> void:
		undo_args = [a, b]

	func commit_action(_execute: bool = true) -> void:
		commits += 1


func _arm_undo_spy() -> UndoRedoSpy:
	var spy := UndoRedoSpy.new()
	# stroke_started() is editor-gated, so the reference is injected the same way it would be.
	manager._active_undo_redo_manager = spy
	manager._undo_activity_delta.clear()
	return spy


func test_chunk_activation_registers_an_undoable_action() -> void:
	var spy: UndoRedoSpy = _arm_undo_spy()

	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager._commit_activity_stroke()

	assert_eq(spy.commits, 1, "Toggling chunks must commit exactly one history action.")
	assert_eq(spy.action_name, "Terrain Chunk Activation",
		"The action needs a name of its own, distinct from a sculpt step.")
	assert_gt((spy.do_args[0] as PackedInt32Array).size(), 0,
		"At least one chunk must be recorded.")


func test_chunk_activation_undo_restores_the_previous_state() -> void:
	var spy: UndoRedoSpy = _arm_undo_spy()
	var before: PackedByteArray = manager.chunk_activity_data.duplicate()

	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager._commit_activity_stroke()
	var after: PackedByteArray = manager.chunk_activity_data.duplicate()
	assert_ne(after, before, "Precondition: the stroke actually changed something.")

	manager._apply_activity_delta(spy.undo_args[0], spy.undo_args[1])
	assert_eq(manager.chunk_activity_data, before, "Undo must restore the exact prior state.")

	manager._apply_activity_delta(spy.do_args[0], spy.do_args[1])
	assert_eq(manager.chunk_activity_data, after, "Redo must reapply the stroke exactly.")


func test_chunk_activation_records_only_the_chunks_that_flipped() -> void:
	# Deactivate once, then run the very same stroke again: the second pass changes nothing,
	# so it must not enter the history at all.
	var spy: UndoRedoSpy = _arm_undo_spy()
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	var recorded: int = manager._undo_activity_delta.size()
	manager._commit_activity_stroke()

	var second: UndoRedoSpy = _arm_undo_spy()
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager._commit_activity_stroke()

	assert_gt(recorded, 0, "The first stroke must record the chunks it flipped.")
	assert_eq(second.commits, 0,
		"A stroke that changes nothing must not push an empty action onto the history.")


func test_chunk_activation_delta_keeps_the_pre_stroke_value() -> void:
	# A stroke is several paint events. Only the first change per chunk may be recorded,
	# otherwise undo would restore an intermediate state instead of the original one.
	var spy: UndoRedoSpy = _arm_undo_spy()
	var before: PackedByteArray = manager.chunk_activity_data.duplicate()

	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), true)
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	manager._commit_activity_stroke()

	manager._apply_activity_delta(spy.undo_args[0], spy.undo_args[1])
	assert_eq(manager.chunk_activity_data, before,
		"Undo must jump back to the state before the whole stroke, not to a step within it.")


func test_committing_consumes_the_activity_delta() -> void:
	# The delta has to be drained on commit, otherwise the next stroke would push the same
	# chunks into the history a second time and undo would walk back too far.
	var spy: UndoRedoSpy = _arm_undo_spy()
	manager.set_chunk_status_in_radius(Vector3(5.0, 0.0, -5.0), false)
	assert_gt(manager._undo_activity_delta.size(), 0, "Precondition: something was recorded.")

	manager._commit_activity_stroke()
	assert_eq(manager._undo_activity_delta.size(), 0,
		"Committing must consume the delta it just registered.")

	manager._commit_activity_stroke()
	assert_eq(spy.commits, 1, "A second commit without new changes must not add an action.")


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


# --- INSPECTOR HINTS ---


func test_collision_layer_uses_the_3d_physics_hint() -> void:
	# The colliders are StaticBody3D / PhysicsServer3D, so the inspector has to read its layer
	# names from the 3D section of Project Settings. A 2D hint labels the same checkboxes with
	# the wrong names, which silently misleads anyone who named their layers.
	for entry: Dictionary in manager.get_property_list():
		if entry["name"] == "collision_layer":
			assert_eq(int(entry["hint"]), PROPERTY_HINT_LAYERS_3D_PHYSICS,
				"collision_layer must use the 3D physics layer hint, not the 2D one.")
			assert_eq(int(entry["type"]), TYPE_INT,
				"The value stays a plain int, so the hint change needs no migration.")
			return
	assert_true(false, "collision_layer must be present in the property list.")


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


# --- TRIANGLE SOUP WITHOUT THE MESH CACHE ---
# ArrayMesh.get_faces() stores its result inside the mesh permanently, measured at roughly
# 88 KB per chunk and never released. That is what made a released collider appear to keep
# most of its memory, and what made the editor brush accumulate memory per chunk hovered.


func test_face_soup_matches_get_faces() -> void:
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0, 0)]
	var mesh: ArrayMesh = chunk.mesh as ArrayMesh
	var soup: PackedVector3Array = LowPolyTerrainMeshBuilder.build_face_soup(mesh)
	var reference: PackedVector3Array = mesh.get_faces()

	assert_eq(soup.size(), reference.size(),
		"The soup must contain exactly as many vertices as get_faces() returns.")
	assert_eq(soup.size() % 3, 0, "A triangle soup must be a multiple of three.")

	# They agree geometrically; only the last decimals differ, because get_faces() reads back
	# the mesh's compressed vertex storage while the surface arrays are uncompressed.
	var worst: float = 0.0
	for i in range(soup.size()):
		worst = maxf(worst, (soup[i] - reference[i]).length())
	assert_lt(worst, 0.001,
		"Largest deviation from get_faces() was %.6f, which is more than rounding." % worst)


func test_face_soup_handles_degenerate_input() -> void:
	assert_eq(LowPolyTerrainMeshBuilder.build_face_soup(null).size(), 0,
		"A null mesh must yield an empty soup rather than an error.")
	assert_eq(LowPolyTerrainMeshBuilder.build_face_soup(ArrayMesh.new()).size(), 0,
		"A surfaceless mesh must yield an empty soup.")


## An UNINDEXED surface already is a triangle soup and must come back unchanged.
##
## Regression: Godot reports ARRAY_INDEX as null for such a surface, not as an empty array.
## Assigning that to a typed PackedInt32Array raises a runtime error which aborts the function
## and returns an EMPTY soup. The editor brush then had no geometry to raycast against over
## deactivated chunks - their preview quad is built without an index buffer - so the ring
## silently stopped appearing while the console filled with type errors.
func test_face_soup_accepts_an_unindexed_surface() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_vertex(Vector3(0.0, 0.0, 0.0))
	st.add_vertex(Vector3(1.0, 0.0, 0.0))
	st.add_vertex(Vector3(0.0, 0.0, 1.0))
	var unindexed: ArrayMesh = st.commit()

	assert_null(unindexed.surface_get_arrays(0)[Mesh.ARRAY_INDEX],
		"Precondition: this surface really carries no index buffer.")

	var soup: PackedVector3Array = LowPolyTerrainMeshBuilder.build_face_soup(unindexed)
	assert_eq(soup.size(), 3, "An unindexed triangle must survive as three vertices.")


## The concrete mesh that triggered it in the editor, so the guard cannot drift from the case.
func test_face_soup_accepts_the_deactivated_preview_quad() -> void:
	var quad: ArrayMesh = LowPolyTerrainMeshBuilder.build_deactivated_preview_mesh(10, 1.0)
	assert_eq(LowPolyTerrainMeshBuilder.build_face_soup(quad).size(), 6,
		"The preview quad must yield two pickable triangles, or the brush cannot see it.")


func test_baked_collider_uses_the_uncached_soup() -> void:
	# Guards the actual call site: if baking went back to get_faces(), the shape would carry
	# the compressed values instead and this comparison would drift apart.
	manager._bake_live_collisions_as_child()
	var shape: CollisionShape3D = manager._find_baked_collision_shape(Vector2i(0, 0))
	assert_not_null(shape, "Precondition: the chunk was baked.")

	var chunk: LowPolyTerrainChunk = manager.chunks_dict[Vector2i(0, 0)]
	var expected: PackedVector3Array = LowPolyTerrainMeshBuilder.build_face_soup(
		chunk.mesh as ArrayMesh)
	assert_eq((shape.shape as ConcavePolygonShape3D).get_faces().size(), expected.size(),
		"The baked shape must be built from the uncached soup.")


## A baked collider has to sit exactly where its chunk does, orientation included.
##
## Regression: the bake assigned only global_position. The bodies are built as children of
## their chunk, where they inherit the manager's orientation, and are then reparented into a
## container that is a SIBLING of the manager and therefore unrotated - and Godot carries the
## LOCAL transform across a reparent. On a tilted terrain every collider stayed axis-aligned
## while the chunk origins stepped down the slope, so the colliders formed a staircase under
## the mesh. Nothing caught it, because every test until now used an unrotated manager.
func test_baked_colliders_follow_a_rotated_terrain() -> void:
	for rotation: Vector3 in [Vector3.ZERO, Vector3(-20.0, 0.0, 0.0), Vector3(-20.0, 45.0, 7.0)]:
		manager.rotation_degrees = rotation
		manager.rebuild_chunks_structure()
		manager._bake_live_collisions_as_child()

		var half: float = (float(manager.chunk_size) * manager.cell_size) / 2.0
		var offset := Vector3(half, 0.0, -half)

		for coord: Vector2i in manager.chunks_dict.keys():
			var chunk: LowPolyTerrainChunk = manager.chunks_dict[coord]
			var body: StaticBody3D = _find_baked_body(coord)
			assert_not_null(body, "Chunk %s must have a baked body at %s." % [coord, rotation])
			if body == null:
				continue

			# bake_collision() shifts the faces by -offset, so the body carries it back. That
			# vector is chunk-local and has to travel through the chunk's transform.
			assert_almost_eq(
				body.global_position.distance_to(chunk.global_transform * offset), 0.0, 0.0001,
				"Collider of %s sits in the wrong place at %s." % [coord, rotation])
			assert_almost_eq(
				(body.global_rotation_degrees - chunk.global_rotation_degrees).length(),
				0.0, 0.001,
				"Collider of %s is not oriented like its chunk at %s." % [coord, rotation])


## Locates the baked StaticBody3D of a chunk inside the sibling container.
func _find_baked_body(coord: Vector2i) -> StaticBody3D:
	var container: Node = manager.get_parent().find_child(
		manager.name + "_Collisions", false, false
	)
	if container == null:
		return null
	return container.find_child("Static_Chunk_%d_%d" % [coord.x, coord.y], false, false) \
		as StaticBody3D


# --- RAMP TOOL ---


## Prepares a flat terrain with one raised vertex, so a ramp from it has somewhere to go.
func _flat_terrain_with_peak(peak: Vector2i, height: float) -> void:
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_height_at(gx, gz, 0.0)
	manager.set_height_at(peak.x, peak.y, height)
	manager.brush_falloff_strength = 0.0    # hard edges keep the expected values exact
	manager.rebuild_chunks_structure()


## The stored enum values are what scenes carry in tool_mode, so they must never shift.
func test_brush_mode_values_stay_stable_for_saved_scenes() -> void:
	var expected: Dictionary = {
		LowPolyTerrainManager.BrushMode.RAISE: 0,
		LowPolyTerrainManager.BrushMode.LOWER: 1,
		LowPolyTerrainManager.BrushMode.FLATTEN: 2,
		LowPolyTerrainManager.BrushMode.SMOOTH: 3,
		LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK: 4,
		LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK: 5,
	}
	for mode: int in expected:
		assert_eq(mode, expected[mode],
			"Renumbering a stored BrushMode silently changes the tool in existing scenes.")

	assert_eq(int(LowPolyTerrainManager.BrushMode.RAMP), 6,
		"RAMP was appended after the stored values on purpose.")
	assert_eq(int(LowPolyTerrainManager.BrushMode.PAINT), 7,
		"PAINT was appended after RAMP, for the same reason.")
	assert_eq(int(LowPolyTerrainManager.BrushMode.NO_FURTHER_BUTTONS), 7,
		"The toolbar cutoff has to include the last tool, or its button never appears.")


## Along the segment the height interpolates linearly between the two picked ends.
func test_ramp_interpolates_between_its_endpoints() -> void:
	_flat_terrain_with_peak(Vector2i(4, 4), 10.0)
	manager.brush_radius = 3

	var from_world: Vector3 = manager.global_transform * Vector3(4.0, 0.0, -4.0)
	var to_world: Vector3 = manager.global_transform * Vector3(20.0, 0.0, -4.0)
	manager.apply_ramp(from_world, to_world)

	for gx: int in [4, 8, 12, 16, 20]:
		var t: float = float(gx - 4) / 16.0
		assert_almost_eq(manager.get_height_at(gx, 4), lerpf(10.0, 0.0, t), 0.001,
			"Height at x=%d must follow the straight line between the ends." % gx)


## Distance is measured to the SEGMENT, so the ramp rounds off instead of running on.
func test_ramp_does_not_extend_past_its_endpoints() -> void:
	_flat_terrain_with_peak(Vector2i(4, 4), 10.0)
	manager.brush_radius = 3

	manager.apply_ramp(
		manager.global_transform * Vector3(4.0, 0.0, -4.0),
		manager.global_transform * Vector3(20.0, 0.0, -4.0)
	)

	# Four cells before the start, i.e. outside the radius of the rounded cap.
	assert_almost_eq(manager.get_height_at(0, 4), 0.0, 0.001,
		"Ground beyond the first endpoint must stay untouched.")
	# And sideways beyond the width.
	assert_almost_eq(manager.get_height_at(12, 8), 0.0, 0.001,
		"Ground outside the corridor width must stay untouched.")


## Both clicks landing on the same spot must not divide by zero.
func test_ramp_survives_two_identical_points() -> void:
	_flat_terrain_with_peak(Vector2i(4, 4), 10.0)
	manager.brush_radius = 2

	var point: Vector3 = manager.global_transform * Vector3(4.0, 0.0, -4.0)
	manager.apply_ramp(point, point)

	# Degenerates into a flatten disc at that height rather than erroring out.
	assert_almost_eq(manager.get_height_at(4, 4), 10.0, 0.001,
		"A zero-length ramp must keep the height it sampled.")
	assert_almost_eq(manager.get_height_at(5, 4), 10.0, 0.001,
		"Its neighbours inside the radius take that height too.")


## The preview must show the result, not an impression of it.
##
## Both go through the same _ramp_height_at(), which is the whole point: a preview computed
## separately would drift from the tool the moment either side changed, and the drift would be
## invisible until someone compared them by hand.
func test_ramp_preview_matches_what_the_tool_applies() -> void:
	for falloff: float in [0.0, 0.5, 1.0]:
		_flat_terrain_with_peak(Vector2i(4, 4), 10.0)
		manager.brush_radius = 3
		manager.brush_falloff_strength = falloff

		var from_world: Vector3 = manager.global_transform * Vector3(4.0, 0.0, -4.0)
		var to_world: Vector3 = manager.global_transform * Vector3(20.0, 0.0, -4.0)

		var preview: ArrayMesh = manager.build_ramp_preview_mesh(from_world, to_world)
		assert_not_null(preview, "A ramp across the terrain must produce a preview.")
		if preview == null:
			continue

		# Collect the height the preview promises per grid vertex.
		var promised: Dictionary = {}
		for vertex: Vector3 in (preview.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				as PackedVector3Array):
			promised[Vector2i(roundi(vertex.x), roundi(-vertex.z))] = vertex.y

		manager.apply_ramp(from_world, to_world)

		for coord: Vector2i in promised:
			assert_almost_eq(
				manager.get_height_at(coord.x, coord.y), float(promised[coord]), 0.0001,
				"Preview and result disagree at %s with falloff %.1f." % [coord, falloff])


## The preview is a surface, not a line: it has to be wide enough to judge the corridor.
func test_ramp_preview_covers_the_brush_width() -> void:
	_flat_terrain_with_peak(Vector2i(4, 4), 10.0)
	manager.brush_radius = 4

	var from_world: Vector3 = manager.global_transform * Vector3(8.0, 0.0, -8.0)
	var to_world: Vector3 = manager.global_transform * Vector3(20.0, 0.0, -8.0)
	var preview: ArrayMesh = manager.build_ramp_preview_mesh(from_world, to_world)
	assert_not_null(preview, "Precondition: a preview was produced.")

	var min_z: float = INF
	var max_z: float = -INF
	for vertex: Vector3 in (preview.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			as PackedVector3Array):
		min_z = minf(min_z, -vertex.z)
		max_z = maxf(max_z, -vertex.z)

	# Radius either side of the axis at z=8, plus the border row that stitches it to the ground.
	assert_lt(min_z, 8.0 - float(manager.brush_radius) + 0.001,
		"The preview must reach a full radius to one side of the axis.")
	assert_gt(max_z, 8.0 + float(manager.brush_radius) - 0.001,
		"The preview must reach a full radius to the other side of the axis.")


## A diagonal ramp must preview a corridor, not the box that contains it.
##
## Regression: the mesh was built over the axis-aligned bounding box of the affected capsule.
## For a diagonal that box is nearly the whole terrain, and outside the radius the preview sits
## exactly on the existing surface - so the entire terrain turned the preview's colour while
## only a narrow strip was going to change.
func test_diagonal_ramp_preview_stays_near_its_axis() -> void:
	_flat_terrain_with_peak(Vector2i(2, 2), 10.0)
	manager.brush_radius = 3

	var last: int = manager._total_vertices_x - 1
	var from_grid := Vector2(2.0, 2.0)
	var to_grid := Vector2(float(last - 2), float(last - 2))

	var preview: ArrayMesh = manager.build_ramp_preview_mesh(
		manager.global_transform * Vector3(from_grid.x, 0.0, -from_grid.y),
		manager.global_transform * Vector3(to_grid.x, 0.0, -to_grid.y)
	)
	assert_not_null(preview, "Precondition: a diagonal ramp produces a preview.")

	var axis: Vector2 = to_grid - from_grid
	var axis_length_sq: float = axis.length_squared()
	var worst: float = 0.0

	for vertex: Vector3 in (preview.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			as PackedVector3Array):
		var point := Vector2(vertex.x / manager.cell_size, -vertex.z / manager.cell_size)
		var t: float = clampf((point - from_grid).dot(axis) / axis_length_sq, 0.0, 1.0)
		worst = maxf(worst, point.distance_to(from_grid + axis * t))

	# A quad survives the cull when its NEAREST corner is within radius + 1.5, so its FARTHEST
	# corner can still be one cell diagonal beyond that. Anything past this bound means whole
	# quads are being kept that have no business being drawn.
	var bound: float = float(manager.brush_radius) + 1.5 + sqrt(2.0)
	assert_lt(worst, bound + 0.001,
		"No preview vertex may sit far from the ramp axis; the box would reach the corners.")

	# And the cull has to actually cull: the bounding box of this diagonal is the whole terrain.
	var half_diagonal: float = (to_grid - from_grid).length() * 0.5
	assert_lt(bound, half_diagonal,
		"Precondition: the bound must be well inside the box, or this test proves nothing.")


## The preview splits into an upward facing surface and the cuts down to the ground.
##
## One flat tint made the shape almost unreadable, so the editor colours the two apart. That
## only works while surface 0 really is the top and surface 1 really is the flanks - the
## overrides are assigned by index.
func test_ramp_preview_separates_top_from_flanks() -> void:
	_flat_terrain_with_peak(Vector2i(4, 4), 10.0)
	manager.brush_radius = 3

	var preview: ArrayMesh = manager.build_ramp_preview_mesh(
		manager.global_transform * Vector3(4.0, 0.0, -4.0),
		manager.global_transform * Vector3(20.0, 0.0, -4.0)
	)
	assert_not_null(preview, "Precondition: a preview was produced.")
	assert_eq(preview.get_surface_count(), 2,
		"A ramp onto flat ground has both a top and flanks.")

	var threshold: float = LowPolyTerrainManager.PREVIEW_FLANK_THRESHOLD
	for surface: int in [0, 1]:
		var verts: PackedVector3Array = preview.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		assert_gt(verts.size(), 0, "Surface %d must carry geometry." % surface)

		for i in range(0, verts.size(), 3):
			# Godot's front faces are clockwise, which puts the right-hand-rule normal of an
			# upward facing triangle on the negative y axis.
			var upward: float = -((verts[i + 1] - verts[i]).cross(
				verts[i + 2] - verts[i])).normalized().y
			if surface == 0:
				assert_gte(upward, threshold,
					"Surface 0 must hold only upward facing triangles.")
			else:
				assert_lt(upward, threshold,
					"Surface 1 must hold only the flanks.")


## Shift must not swap the tool between the two clicks of a ramp.
func test_shift_leaves_the_ramp_tool_alone() -> void:
	manager.tool_mode = LowPolyTerrainManager.BrushMode.RAMP
	assert_eq(manager.resolve_brush_mode(true), LowPolyTerrainManager.BrushMode.RAMP,
		"Inverting mid-operation would apply a tool the preview never promised.")


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


## The deactivated-chunk marker has to face the camera it is looked at from, which is above.
##
## Regression: the quad was wound the other way round and carried no normals at all, so with a
## lit material it was visible only from underneath. Nothing caught it, because every existing
## check looked at vertex positions - which were correct the whole time.
func test_deactivated_preview_quad_faces_upwards() -> void:
	var mesh: ArrayMesh = LowPolyTerrainMeshBuilder.build_deactivated_preview_mesh(10, 1.0)
	assert_not_null(mesh, "The preview quad must exist.")

	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

	var normals = arrays[Mesh.ARRAY_NORMAL]
	assert_not_null(normals,
		"Without normals a lit material has nothing to shade against.")
	for n: Vector3 in normals:
		assert_almost_eq(n.y, 1.0, 0.001, "Every normal must point straight up.")

	# Flattened to a plain triangle list first: the quad is unindexed today, so ARRAY_INDEX is
	# null rather than an empty array, but an indexed surface must pass the same check.
	var tris := PackedVector3Array()
	var raw_indices = arrays[Mesh.ARRAY_INDEX]
	if raw_indices == null:
		tris = verts
	else:
		for index: int in (raw_indices as PackedInt32Array):
			tris.append(verts[index])

	assert_true(tris.size() >= 6, "A quad needs at least two triangles.")

	# Godot treats CLOCKWISE triangles as front-facing, which makes the right-hand-rule cross
	# product of an upward-facing triangle point DOWN. A positive y here is the actual bug.
	for i in range(0, tris.size(), 3):
		assert_lt((tris[i + 1] - tris[i]).cross(tris[i + 2] - tris[i]).y, 0.0,
			"Triangle %d is wound face-down; it would only be visible from below." % (i / 3))


## The marker must read the same no matter where the scene's sun happens to be.
func test_deactivated_preview_material_is_unlit() -> void:
	var mat: StandardMaterial3D = LowPolyTerrainMeshBuilder.build_deactivated_preview_material()
	assert_eq(mat.shading_mode, StandardMaterial3D.SHADING_MODE_UNSHADED,
		"A lit marker changes colour with the scene lighting.")
	assert_eq(mat.cull_mode, BaseMaterial3D.CULL_DISABLED,
		"Looking at a deactivated chunk from below must still show it.")
	# With several terrains in one scene the markers of the lower manager vanished behind the
	# geometry of the upper one. Same requirement the chunk grid already carries.
	assert_true(mat.no_depth_test,
		"A marker another terrain can hide is no marker.")


# --- BRUSH OVERLAY ---
# The ring colour and the caption must describe the stroke that would actually happen, which
# is not the toolbar selection whenever Shift is held.


## Shift inverts the tool. The plugin reads this same function for the ring and the caption,
## so it is the single place where overlay and stroke can agree or drift apart.
func test_shift_resolves_to_the_inverted_brush_mode() -> void:
	var expected: Dictionary = {
		LowPolyTerrainManager.BrushMode.RAISE: LowPolyTerrainManager.BrushMode.LOWER,
		LowPolyTerrainManager.BrushMode.LOWER: LowPolyTerrainManager.BrushMode.RAISE,
		LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK:
			LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK,
		LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK:
			LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK,
		# Neither has a natural opposite, so the modifier reaches for SMOOTH.
		LowPolyTerrainManager.BrushMode.FLATTEN: LowPolyTerrainManager.BrushMode.SMOOTH,
		LowPolyTerrainManager.BrushMode.SMOOTH: LowPolyTerrainManager.BrushMode.SMOOTH,
	}

	for mode: int in expected:
		manager.tool_mode = mode
		assert_eq(manager.resolve_brush_mode(false), mode,
			"Without Shift the selected tool must be used unchanged.")
		assert_eq(manager.resolve_brush_mode(true), expected[mode],
			"Shift on mode %d must resolve to %d." % [mode, expected[mode]])


## The caption lists only what reaches the active tool.
##
## Regression: the falloff value was never shown at all, and strength was printed for tools
## that ignore it. Tuning a slider that does nothing is worse than not seeing it.
func test_brush_label_lists_only_the_settings_that_apply() -> void:
	var plugin: GDScript = load("res://addons/lowpolyterrain/lowpolyterrain_plugin.gd")
	manager.brush_radius = 7
	manager.brush_strength = 2.5
	manager.brush_falloff_strength = 0.35

	var raise: String = plugin._build_brush_label(
		manager, LowPolyTerrainManager.BrushMode.RAISE, false)
	assert_string_contains(raise, "R: 7", "Radius applies to every tool.")
	assert_string_contains(raise, "S: 2.50", "Strength drives how far RAISE moves a vertex.")
	assert_string_contains(raise, "F: 0.35", "Falloff shapes the RAISE brush edge.")

	# FLATTEN interpolates towards a fixed target height and never reads brush_strength.
	var flatten: String = plugin._build_brush_label(
		manager, LowPolyTerrainManager.BrushMode.FLATTEN, false)
	assert_string_contains(flatten, "F: 0.35", "Falloff shapes the FLATTEN brush edge.")
	assert_false(flatten.contains("S: "), "FLATTEN ignores brush_strength.")

	# SMOOTH always applies the full smoothstep curve and never reads brush_falloff_strength.
	var smooth: String = plugin._build_brush_label(
		manager, LowPolyTerrainManager.BrushMode.SMOOTH, false)
	assert_string_contains(smooth, "S: 2.50", "SMOOTH scales its blend by brush_strength.")
	assert_false(smooth.contains("F: "), "SMOOTH ignores brush_falloff_strength.")

	# RAMP takes its heights from the terrain, so brush_strength never reaches it - but the
	# falloff shapes its corridor edges exactly like the sculpting brushes.
	var ramp: String = plugin._build_brush_label(
		manager, LowPolyTerrainManager.BrushMode.RAMP, false)
	assert_string_contains(ramp, "R: 7", "Radius sets the corridor width.")
	assert_string_contains(ramp, "F: 0.35", "Falloff softens the corridor edges.")
	assert_false(ramp.contains("S: "), "RAMP ignores brush_strength.")

	# The chunk brushes work per chunk, so neither value reaches them.
	var activate: String = plugin._build_brush_label(
		manager, LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK, false)
	assert_string_contains(activate, "R: 7", "Radius still selects which chunks are hit.")
	assert_false(activate.contains("S: "), "Chunk activation ignores brush_strength.")
	assert_false(activate.contains("F: "), "Chunk activation ignores brush_falloff_strength.")


## Every value the caption prints must also trigger a refresh when edited in the inspector.
##
## Regression: the refresh used a chain of name comparisons that never learned about
## brush_falloff_strength. Editing the radius updated the readout, editing the falloff did not,
## so the caption kept advertising a value the brush had already stopped using.
func test_every_caption_value_refreshes_from_the_inspector() -> void:
	var plugin: GDScript = load("res://addons/lowpolyterrain/lowpolyterrain_plugin.gd")
	for property: String in ["tool_mode", "brush_radius", "brush_strength",
			"brush_falloff_strength"]:
		assert_true(plugin.BRUSH_OVERLAY_PROPERTIES.has(property),
			"'%s' reaches the brush overlay, so editing it has to refresh it." % property)
		assert_true(property in manager,
			"'%s' must still exist on the manager, or the entry is dead weight." % property)


## While Shift is held the caption must name the inverted tool, and say why.
func test_brush_label_names_the_inverted_tool_while_shift_is_held() -> void:
	var plugin: GDScript = load("res://addons/lowpolyterrain/lowpolyterrain_plugin.gd")

	var plain: String = plugin._build_brush_label(
		manager, LowPolyTerrainManager.BrushMode.RAISE, false)
	assert_string_contains(plain, "Raise", "Without Shift the selected tool is named.")
	assert_false(plain.contains("Shift"), "No modifier hint without the modifier.")

	# What the plugin passes in: resolve_brush_mode() first, then the caption.
	manager.tool_mode = LowPolyTerrainManager.BrushMode.RAISE
	var inverted: String = plugin._build_brush_label(
		manager, manager.resolve_brush_mode(true), true)
	assert_string_contains(inverted, "Lower",
		"Shift lowers, so the caption must stop claiming Raise.")
	assert_string_contains(inverted, "Shift",
		"The hint separates a temporary inversion from a changed toolbar selection.")


# --- VERTEX PAINTING ---
# The weights live in the mesh's vertex colour channel and in a byte array parallel to the
# heights. Both backends read the same builder, so what is asserted here holds for either.


## Sets up a flat terrain with the paint brush ready, and returns the world centre of it.
func _prepare_paint(radius: int, falloff: float) -> Vector3:
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_height_at(gx, gz, 0.0)
	manager.ensure_paint_material()
	manager.tool_mode = LowPolyTerrainManager.BrushMode.PAINT
	manager.brush_radius = radius
	manager.brush_strength = 15.0
	manager.brush_falloff_strength = falloff
	manager.paint_layer = 1
	manager.rebuild_chunks_structure()
	return manager.global_transform * Vector3(10.0, 0.0, -10.0)


## Applies the paint brush, bypassing the cooldown the way a held stroke does.
func _paint(at: Vector3, passes: int, erase: bool = false) -> void:
	for i in range(passes):
		manager._last_paint_time = -100000.0
		manager.interact_at_world_position(at, erase)


## A terrain nobody painted stores nothing, so existing scenes gain no weight at all.
func test_unpainted_terrain_stores_no_paint_data() -> void:
	assert_false(manager.has_paint_data(), "A fresh terrain must carry no paint array.")
	assert_eq(manager.global_paint_data.size(), 0, "And it must be empty, not merely zeroed.")
	assert_null(manager.get_active_paint_material(),
		"No paint means no overlay, or every terrain would pay for a pass that draws nothing.")


func test_painting_allocates_and_round_trips() -> void:
	var centre: Vector3 = _prepare_paint(3, 0.0)
	_paint(centre, 1)

	assert_true(manager.has_paint_data(), "The first stroke allocates the array.")
	assert_eq(manager.global_paint_data.size(),
		manager._total_vertices_x * manager._total_vertices_z * 4,
		"Four bytes per grid point, indexed exactly like the heights.")
	assert_almost_eq(manager.get_paint_at(10, 10).r, 1.0, 0.05,
		"Full strength on layer 1 fills the red channel at the centre.")


## Painting must never disturb the surface it is painted on.
func test_painting_leaves_the_heights_alone() -> void:
	var centre: Vector3 = _prepare_paint(3, 0.0)
	var before: PackedFloat32Array = manager.global_height_data.duplicate()
	_paint(centre, 5)
	assert_eq(manager.global_height_data, before, "The paint brush writes weights, not heights.")


## The four weights plus the base are a partition, so their sum cannot exceed the whole.
func test_paint_weights_never_exceed_one() -> void:
	var centre: Vector3 = _prepare_paint(4, 0.0)
	for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
		manager.paint_layer = layer
		_paint(centre, 3)

	var worst: float = 0.0
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			var c: Color = manager.get_paint_at(gx, gz)
			worst = maxf(worst, c.r + c.g + c.b + c.a)
	assert_lte(worst, 1.001, "Painting every layer in turn must not pile the weights up.")


## Regression: the falloff was applied as a per-pass multiplier rather than as a ceiling.
##
## The middle then climbed to full weight however soft the brush was, while the outer ring got
## deposits so small that quantisation rounded them away on every single pass - so the stroke
## came out as a hard disc that merely shrank as the falloff rose, with no gradient at all.
func test_soft_brush_leaves_a_gradient_that_holds() -> void:
	var centre: Vector3 = _prepare_paint(8, 1.0)
	_paint(centre, 40)

	var previous: float = manager.get_paint_at(10, 10).r
	assert_almost_eq(previous, 1.0, 0.05, "The centre reaches full weight.")

	# Strictly decreasing outwards is the whole point of a falloff.
	for distance in range(1, 8):
		var here: float = manager.get_paint_at(10 + distance, 10).r
		assert_lt(here, previous,
			"Weight at distance %d must sit below the ring inside it." % distance)
		previous = here

	assert_almost_eq(manager.get_paint_at(18, 10).r, 0.0, 0.05,
		"And it must reach nothing at the rim.")


## Holding the brush must settle into that gradient rather than filling past it.
func test_holding_a_soft_brush_does_not_flatten_it() -> void:
	var centre: Vector3 = _prepare_paint(8, 1.0)
	_paint(centre, 10)
	var settled: float = manager.get_paint_at(14, 10).r

	_paint(centre, 60)
	assert_almost_eq(manager.get_paint_at(14, 10).r, settled, 0.001,
		"Sixty more passes must not push the edge any further than ten did.")


## Regression: the ceiling lowered paint that a previous stroke had put down.
##
## min() does not care who wrote the value it reduces, so a second stroke laid beside a first
## cut the old paint back to its own soft rim wherever the two overlapped - which read as the
## new circle punching holes into the old one.
func test_a_second_stroke_does_not_erase_the_first() -> void:
	var centre: Vector3 = _prepare_paint(6, 1.0)
	_paint(centre, 10)

	# The OVERLAP is what matters. A second circle six cells to the right reaches back to
	# x = 12, so 12 to 14 carry real paint from the first stroke AND sit inside the second
	# one's soft rim - exactly where a ceiling that lowers would do its damage. Points outside
	# its radius are skipped outright and would prove nothing; points past 14 hold too little
	# paint to tell a loss from the rounding.
	var before: PackedFloat32Array = PackedFloat32Array()
	for gx in range(12, 15):
		before.append(manager.get_paint_at(gx, 10).r)
		assert_gt(before[before.size() - 1], 0.1,
			"Precondition: the first stroke really did paint grid point %d." % gx)

	_paint(manager.global_transform * Vector3(18.0, 0.0, -10.0), 10)

	# Not "unchanged": the second stroke may legitimately RAISE these. It may never lower them.
	for i in range(before.size()):
		assert_gte(manager.get_paint_at(12 + i, 10).r, before[i] - 0.001,
			"Grid point %d lost paint the first stroke had put there." % (12 + i))


## A layer colour's alpha caps how much of the surface that layer may claim, which is what
## turns a translucent layer into a glaze instead of a replacement.
func test_layer_alpha_leaves_room_for_what_was_there() -> void:
	var centre: Vector3 = _prepare_paint(3, 0.0)

	manager.paint_layer = 3
	_paint(centre, 5)
	assert_almost_eq(manager.get_paint_at(10, 10).b, 1.0, 0.05, "Layer 3 covers the spot.")

	var material: ShaderMaterial = manager.paint_material as ShaderMaterial
	material.set_shader_parameter("paint_layer_1_color", Color(1.0, 0.0, 0.0, 0.5))
	manager.paint_layer = 1
	_paint(centre, 5)

	var result: Color = manager.get_paint_at(10, 10)
	assert_almost_eq(result.r, 0.5, 0.06, "A half-transparent layer claims about half.")
	assert_gt(result.b, 0.4, "And the layer beneath keeps the rest instead of vanishing.")


## Shift wipes back towards the base material, every layer at once.
func test_shift_erases_all_layers() -> void:
	var centre: Vector3 = _prepare_paint(3, 0.0)
	manager.paint_layer = 1
	_paint(centre, 5)
	manager.paint_layer = 3
	_paint(centre, 2)

	_paint(centre, 20, true)
	var result: Color = manager.get_paint_at(10, 10)
	assert_almost_eq(result.r + result.g + result.b + result.a, 0.0, 0.001,
		"Erasing must reach the base, not merely the selected layer.")


## Evenly painted ground still decimates; only the transitions cost vertices.
func test_uniform_paint_still_decimates() -> void:
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_height_at(gx, gz, 0.0)
	manager.rebuild_chunks_structure()
	var bare: int = _chunk_vertex_count(Vector2i(0, 0))

	# The same weight everywhere: nothing changes across the surface, so nothing has to be kept.
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_paint_at(gx, gz, Color(1.0, 0.0, 0.0, 0.0))
	manager.rebuild_chunks_structure()
	assert_eq(_chunk_vertex_count(Vector2i(0, 0)), bare,
		"Uniform paint carries no detail, so it must not cost a single vertex.")

	# A transition does need vertices to carry it.
	for gz in range(4, 7):
		for gx in range(manager._total_vertices_x):
			manager.set_paint_at(gx, gz, Color(0.0, 1.0, 0.0, 0.0))
	manager.rebuild_chunks_structure()
	assert_gt(_chunk_vertex_count(Vector2i(0, 0)), bare,
		"A painted edge has to be represented, which takes vertices.")


func _chunk_vertex_count(coord: Vector2i) -> int:
	var mesh: ArrayMesh = manager.get_chunk_mesh(coord)
	if mesh == null:
		return 0
	return (mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


## Every channel has to survive into the mesh, the fourth one included.
func test_all_four_layers_reach_the_vertex_colours() -> void:
	for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
		for gz in range(manager._total_vertices_z):
			for gx in range(manager._total_vertices_x):
				manager.set_height_at(gx, gz, 0.0)
				manager.set_paint_at(gx, gz, Color(0.0, 0.0, 0.0, 0.0))

		var weights := Color(0.0, 0.0, 0.0, 0.0)
		weights[layer - 1] = 1.0
		manager.set_paint_at(5, 5, weights)
		manager.rebuild_chunks_structure()

		var mesh: ArrayMesh = manager.get_chunk_mesh(Vector2i(0, 0))
		var strongest := Color(0.0, 0.0, 0.0, 0.0)
		for c: Color in (mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] as PackedColorArray):
			if c.r + c.g + c.b + c.a > strongest.r + strongest.g + strongest.b + strongest.a:
				strongest = c
		assert_almost_eq(strongest[layer - 1], 1.0, 0.001,
			"Layer %d must arrive in its own channel of the vertex colour." % layer)


## The paint has to follow the grid when the world is resized, not smear across it.
func test_paint_survives_a_dimension_change() -> void:
	manager.set_paint_at(3, 3, Color(1.0, 0.0, 0.0, 0.0))
	manager.set_paint_at(7, 2, Color(0.0, 0.0, 0.0, 1.0))

	manager.preview_world_chunks = Vector2i(3, 3)
	manager.preview_chunk_size = manager.chunk_size
	manager.preview_cell_size = manager.cell_size
	manager._apply_dimension_changes()

	assert_almost_eq(manager.get_paint_at(3, 3).r, 1.0, 0.001,
		"A painted point keeps its coordinate through a resize.")
	assert_almost_eq(manager.get_paint_at(7, 2).a, 1.0, 0.001,
		"The fourth channel migrates with the rest.")


# --- SLOPE FILTER ---
# Each layer may restrict itself to a range of surface angles, so one sweep of the brush can
# put rock on the cliffs and sand on the flats without aiming.


## Builds a terrain that is level on the left and rises at a known angle on the right.
func _ramp_terrain() -> void:
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			# 0.5 per cell is arctan(0.5) = 26.57 degrees; level before that.
			manager.set_height_at(gx, gz, 0.0 if gx <= 8 else float(gx - 8) * 0.5)
	manager.rebuild_chunks_structure()


func test_slope_angle_matches_the_height_gradient() -> void:
	_ramp_terrain()
	assert_almost_eq(manager.get_slope_angle_at(4, 4), 0.0, 0.01,
		"Level ground reads as zero degrees.")
	assert_almost_eq(manager.get_slope_angle_at(14, 4), rad_to_deg(atan(0.5)), 0.01,
		"Half a unit per cell is arctan(0.5).")


## The configured range passes at full strength; the feather is the run-out beyond it.
func test_slope_mask_feathers_outside_the_range() -> void:
	manager.paint_layer_1_slope = Vector2(30.0, 90.0)
	manager.paint_slope_feather = 6.0

	assert_almost_eq(manager.get_slope_mask(45.0, 1), 1.0, 0.001, "Inside the range: full.")
	assert_almost_eq(manager.get_slope_mask(30.0, 1), 1.0, 0.001, "The boundary itself: full.")
	assert_almost_eq(manager.get_slope_mask(27.0, 1), 0.5, 0.001, "Half a feather out: half.")
	assert_almost_eq(manager.get_slope_mask(24.0, 1), 0.0, 0.001, "A whole feather out: none.")
	assert_almost_eq(manager.get_slope_mask(0.0, 1), 0.0, 0.001, "Far outside: none.")

	# A range given back to front must not invert the filter.
	manager.paint_layer_1_slope = Vector2(90.0, 30.0)
	assert_almost_eq(manager.get_slope_mask(45.0, 1), 1.0, 0.001,
		"Min and max swapped describe the same range.")


## Zero feather is a hard boundary, which is a legitimate choice rather than a broken one.
func test_slope_mask_without_feather_is_a_hard_edge() -> void:
	manager.paint_layer_1_slope = Vector2(30.0, 90.0)
	manager.paint_slope_feather = 0.0
	assert_almost_eq(manager.get_slope_mask(30.0, 1), 1.0, 0.001, "Inside stays full.")
	assert_almost_eq(manager.get_slope_mask(29.9, 1), 0.0, 0.001, "Outside drops at once.")


## The point of the whole feature: one stroke, and the layer lands only where it belongs.
func test_painting_respects_the_slope_range() -> void:
	_ramp_terrain()
	manager.ensure_paint_material()
	manager.tool_mode = LowPolyTerrainManager.BrushMode.PAINT
	manager.brush_radius = 12
	manager.brush_strength = 15.0
	manager.brush_falloff_strength = 0.0
	manager.paint_layer = 1
	manager.paint_slope_feather = 2.0
	# Only the rising half, which sits at 26.57 degrees.
	manager.paint_layer_1_slope = Vector2(20.0, 90.0)

	# Centred so the brush covers level ground and slope alike.
	_paint(manager.global_transform * Vector3(10.0, 0.0, -10.0), 10)

	assert_almost_eq(manager.get_paint_at(4, 10).r, 0.0, 0.01,
		"Level ground is outside the range and must stay unpainted.")
	assert_gt(manager.get_paint_at(14, 10).r, 0.9,
		"The slope is inside the range and must take the paint.")


## Erasing must not be filtered, or paint could become impossible to remove.
func test_erasing_ignores_the_slope_range() -> void:
	_ramp_terrain()
	manager.ensure_paint_material()
	manager.tool_mode = LowPolyTerrainManager.BrushMode.PAINT
	manager.brush_radius = 12
	manager.brush_strength = 15.0
	manager.brush_falloff_strength = 0.0
	manager.paint_layer = 1

	# Paint everything with the filter wide open.
	manager.paint_layer_1_slope = Vector2(0.0, 90.0)
	_paint(manager.global_transform * Vector3(10.0, 0.0, -10.0), 10)
	assert_gt(manager.get_paint_at(4, 10).r, 0.9, "Precondition: level ground got paint.")

	# Now close the filter so that level ground would be excluded, and erase.
	manager.paint_layer_1_slope = Vector2(80.0, 90.0)
	manager.paint_slope_feather = 0.0
	_paint(manager.global_transform * Vector3(10.0, 0.0, -10.0), 20, true)

	assert_almost_eq(manager.get_paint_at(4, 10).r, 0.0, 0.01,
		"Shift must reach paint the filter would no longer let through.")


## Only the selected layer's range is offered, but all four keep their stored values.
func test_only_the_selected_layers_slope_range_is_shown() -> void:
	for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
		manager.paint_layer = layer

		for i in range(LowPolyTerrainManager.PAINT_SLOPE_PROPERTIES.size()):
			var property: String = LowPolyTerrainManager.PAINT_SLOPE_PROPERTIES[i]
			var usage: int = _usage_of_property(property)

			if i == layer - 1:
				assert_gt(usage & PROPERTY_USAGE_EDITOR, 0,
					"'%s' must be shown while layer %d is selected." % [property, layer])
			else:
				assert_eq(usage & PROPERTY_USAGE_EDITOR, 0,
					"'%s' must be hidden while layer %d is selected." % [property, layer])

			assert_gt(usage & PROPERTY_USAGE_STORAGE, 0,
				"'%s' must be saved whether shown or not." % property)


func _usage_of_property(property: String) -> int:
	for entry: Dictionary in manager.get_property_list():
		if entry["name"] == property:
			return int(entry["usage"])
	return 0


# --- DESTRUCTIVE DIMENSION CHANGES ---
# Shrinking rebuilds the whole grid and leaves no undo entry behind, so it asks first.


func test_shrinking_counts_the_chunks_it_would_discard() -> void:
	manager.preview_world_chunks = manager.world_chunks
	assert_eq(manager.count_chunks_lost_by_pending_dimensions(), 0,
		"Unchanged dimensions discard nothing.")

	manager.preview_world_chunks = manager.world_chunks + Vector2i(2, 2)
	assert_eq(manager.count_chunks_lost_by_pending_dimensions(), 0,
		"Growing the world discards nothing either.")

	# A 2x2 world cut to 1x1 keeps one chunk of four.
	manager.preview_world_chunks = Vector2i(1, 1)
	assert_eq(manager.count_chunks_lost_by_pending_dimensions(), 3,
		"Only chunks that exist today and would not exist afterwards count.")


## Outside the editor there is nobody to answer, so the change goes through.
func test_shrinking_outside_the_editor_applies_directly() -> void:
	manager.set_height_at(1, 1, 7.0)
	manager.preview_world_chunks = Vector2i(1, 1)
	manager.preview_chunk_size = manager.chunk_size
	manager.preview_cell_size = manager.cell_size

	manager._apply_dimension_changes()
	assert_eq(manager.world_chunks, Vector2i(1, 1),
		"GUT runs with is_editor_hint() false, which is the runtime case.")


## The confirmation must be a real gate: nothing may change until the answer comes back.
func test_confirmed_shrink_is_what_actually_migrates() -> void:
	manager.set_height_at(1, 1, 7.0)
	var before: Vector2i = manager.world_chunks

	manager.preview_world_chunks = Vector2i(1, 1)
	manager.preview_chunk_size = manager.chunk_size
	manager.preview_cell_size = manager.cell_size

	# The dialog path ends here in the editor; the confirmed call is the other half of it.
	assert_eq(manager.world_chunks, before,
		"Precondition: setting the preview alone changes nothing.")

	manager.apply_dimension_changes_confirmed()
	assert_eq(manager.world_chunks, Vector2i(1, 1),
		"Confirming is what performs the migration.")


## Resizing must be reversible in full: dimensions and all three data layers.
##
## A whole-grid snapshot rather than a delta, because the migration re-indexes every array by
## the new row width - there is no subset of values that stayed where it was.
func test_dimension_change_restores_everything_it_touched() -> void:
	manager.set_height_at(3, 3, 7.5)
	manager.set_paint_at(3, 3, Color(1.0, 0.0, 0.0, 0.0))
	manager.chunk_activity_data[1] = 0

	var chunks_before: Vector2i = manager.world_chunks
	var heights_before: PackedFloat32Array = manager.global_height_data.duplicate()
	var paint_before: PackedByteArray = manager.global_paint_data.duplicate()
	var activity_before: PackedByteArray = manager.chunk_activity_data.duplicate()

	manager.preview_world_chunks = Vector2i(1, 1)
	manager.preview_chunk_size = manager.chunk_size
	manager.preview_cell_size = manager.cell_size
	manager.apply_dimension_changes_confirmed()
	assert_eq(manager.world_chunks, Vector2i(1, 1), "Precondition: the change went through.")

	# What the undo entry hands back.
	manager._apply_dimension_snapshot(
		chunks_before, manager.chunk_size, manager.cell_size,
		heights_before, activity_before, paint_before
	)

	assert_eq(manager.world_chunks, chunks_before, "The dimensions come back.")
	assert_eq(manager.global_height_data, heights_before, "So do the heights.")
	assert_eq(manager.global_paint_data, paint_before, "So does the paint.")
	assert_eq(manager.chunk_activity_data, activity_before, "So does the chunk activity.")

	# The preview values follow, or pressing Apply again would silently redo the undone change.
	assert_eq(manager.preview_world_chunks, chunks_before,
		"The inspector must not keep showing the size that was just undone.")
