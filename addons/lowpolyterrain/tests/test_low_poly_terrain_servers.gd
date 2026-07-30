extends GutTest

## Automated stability test suite for the TerrainBackend.SERVERS pipeline.
## Verifies RID allocation and release, geometry parity with the classic node backend,
## cardinal seam synchronization, winding order integrity and analytic brush picking.

var manager: LowPolyTerrainManager = null


func before_each() -> void:
	manager = LowPolyTerrainManager.new()
	manager.name = "TestServerManager"
	add_child(manager)

	manager.world_chunks = Vector2i(2, 2)
	manager.chunk_size = 10
	manager.cell_size = 1.0
	manager.step_height = 0.5
	manager.brush_strength = 1.0
	manager.brush_falloff_strength = 0.0
	manager.collision_layer = 2
	manager.collision_group = "Wall"

	manager.global_height_data = PackedFloat32Array()
	manager.chunk_activity_data = PackedByteArray()
	manager._setup_pending = false
	manager.rebuild_chunks_structure()


func after_each() -> void:
	if is_instance_valid(manager):
		# Releasing the manager must also release every RID the server backend allocated;
		# Godot reports any survivor as "RID allocations of type ... were leaked at exit".
		for chunk_coord in manager.chunks_dict.keys():
			var chunk: Node = manager.chunks_dict[chunk_coord]
			if is_instance_valid(chunk):
				chunk.free()
		manager.chunks_dict.clear()

		for child in manager.get_children():
			if is_instance_valid(child):
				child.free()

		manager.free()

	manager = null


func _use_servers() -> void:
	manager.terrain_backend = LowPolyTerrainManager.TerrainBackend.SERVERS


## Applies a deterministic sculpting sequence so decimation and jitter actually engage.
func _sculpt_some_terrain() -> void:
	for i in range(5):
		manager._last_paint_time = -1000.0
		manager.interact_at_world_position(Vector3(float(i) * 1.5, 0.0, -float(i)), false)
	manager.is_paint_stroke_active = false


##@@
# --- PILLAR 1: GRID ALLOCATION VALIDATION ---


func test_servers_backend_allocates_one_record_per_chunk() -> void:
	_use_servers()
	assert_eq(manager.get_chunk_coords().size(), 4,
		"SERVERS backend must track exactly 4 chunks for a 2x2 grid.")

	for coord in manager.get_chunk_coords():
		assert_not_null(manager.get_chunk_mesh(coord),
			"Chunk %s must expose renderable geometry." % coord)


func test_servers_backend_records_hold_valid_rids() -> void:
	_use_servers()
	for coord in manager.get_chunk_coords():
		var record = manager._server_backend.get_debug_record(coord)
		assert_not_null(record, "Chunk %s must own a backend record." % coord)
		assert_true(record.instance_rid.is_valid(),
			"Chunk %s must hold a valid RenderingServer instance RID." % coord)


func test_servers_backend_creates_no_chunk_nodes() -> void:
	_use_servers()
	var chunk_children: int = 0
	for child in manager.get_children():
		if child is LowPolyTerrainChunk:
			chunk_children += 1
	assert_eq(chunk_children, 0,
		"SERVERS backend must not instantiate a single MeshInstance3D chunk node.")


func test_switching_back_releases_the_server_backend() -> void:
	_use_servers()
	assert_not_null(manager._server_backend, "Backend must exist while SERVERS is active.")

	manager.terrain_backend = LowPolyTerrainManager.TerrainBackend.MESH_NODES
	assert_null(manager._server_backend,
		"Switching back to MESH_NODES must release the server backend and all its RIDs.")
	assert_eq(manager.chunks_dict.size(), 4,
		"MESH_NODES must rebuild all 4 chunk nodes after the switch back.")


func test_backend_round_trip_is_lossless() -> void:
	_sculpt_some_terrain()
	manager.set_chunk_status_in_radius(Vector3(15.0, 0.0, -15.0), false)

	var heights_before: PackedFloat32Array = manager.global_height_data.duplicate()
	var activity_before: PackedByteArray = manager.chunk_activity_data.duplicate()

	_use_servers()
	manager.terrain_backend = LowPolyTerrainManager.TerrainBackend.MESH_NODES

	assert_eq(manager.global_height_data, heights_before,
		"A full backend round trip must not alter a single height value.")
	assert_eq(manager.chunk_activity_data, activity_before,
		"A full backend round trip must not alter chunk activation state.")


func test_server_only_settings_are_hidden_in_mesh_nodes() -> void:
	# Showing a setting that cannot take effect in the active backend reads as a broken
	# setting, which is exactly how it was reported.
	for entry: Dictionary in manager.get_property_list():
		if LowPolyTerrainManager.SERVER_ONLY_PROPERTIES.has(entry["name"]):
			assert_eq(int(entry["usage"]) & PROPERTY_USAGE_EDITOR, 0,
				"'%s' must not be shown while MESH_NODES is active." % entry["name"])
			assert_gt(int(entry["usage"]) & PROPERTY_USAGE_STORAGE, 0,
				"'%s' must still be saved even while hidden." % entry["name"])


func test_server_only_settings_appear_again_under_servers() -> void:
	_use_servers()
	var seen: int = 0
	for entry: Dictionary in manager.get_property_list():
		if LowPolyTerrainManager.SERVER_ONLY_PROPERTIES.has(entry["name"]):
			seen += 1
			assert_gt(int(entry["usage"]) & PROPERTY_USAGE_EDITOR, 0,
				"'%s' must be visible while SERVERS is active." % entry["name"])
	assert_eq(seen, LowPolyTerrainManager.SERVER_ONLY_PROPERTIES.size(),
		"Every server-only setting must be present in the property list.")


func test_bake_button_is_hidden_under_servers() -> void:
	# It refuses to do anything in this mode, so offering it would only invite the click.
	_use_servers()
	for entry: Dictionary in manager.get_property_list():
		if LowPolyTerrainManager.MESH_NODES_ONLY_PROPERTIES.has(entry["name"]):
			assert_eq(int(entry["usage"]) & PROPERTY_USAGE_EDITOR, 0,
				"'%s' must not be shown while SERVERS is active." % entry["name"])


func test_bake_button_is_visible_under_mesh_nodes() -> void:
	var seen: int = 0
	for entry: Dictionary in manager.get_property_list():
		if LowPolyTerrainManager.MESH_NODES_ONLY_PROPERTIES.has(entry["name"]):
			seen += 1
			assert_gt(int(entry["usage"]) & PROPERTY_USAGE_EDITOR, 0,
				"'%s' must be visible while MESH_NODES is active." % entry["name"])
	assert_eq(seen, LowPolyTerrainManager.MESH_NODES_ONLY_PROPERTIES.size(),
		"Every node-backend setting must be present in the property list.")


func test_terrain_backend_is_the_first_editor_property() -> void:
	var props: Array = manager.get_script().get_script_property_list()
	var backend_index: int = -1
	var first_group_index: int = -1

	for i in range(props.size()):
		var entry: Dictionary = props[i]
		if entry["name"] == "terrain_backend":
			backend_index = i
		if first_group_index < 0 and (int(entry["usage"]) & PROPERTY_USAGE_GROUP) != 0:
			first_group_index = i

	assert_gt(backend_index, -1, "terrain_backend must be an exported property.")
	assert_gt(first_group_index, -1, "The inspector must declare at least one group.")
	assert_lt(backend_index, first_group_index,
		"terrain_backend must render above every inspector group.")


func test_migration_preserves_heights_under_servers() -> void:
	_use_servers()
	manager.set_height_at(5, 5, 4.25)

	manager.preview_world_chunks = Vector2i(3, 3)
	manager.preview_chunk_size = 10
	manager.preview_cell_size = 1.0
	manager._apply_dimension_changes()

	assert_almost_eq(manager.get_height_at(5, 5), 4.25, 0.0001,
		"Grid migration under SERVERS must carry existing heights across intact.")


##@@
# --- PILLAR 2: CARDINAL SEAM VERIFICATION ---


func test_servers_backend_seams_match_across_all_four_cardinals() -> void:
	_sculpt_some_terrain()
	_use_servers()

	# The shared boundary between horizontally adjacent chunks, and between vertically
	# adjacent ones, must resolve to the exact same world-space vertices from both sides.
	_assert_shared_edge_matches(Vector2i(0, 0), Vector2i(1, 0), "east/west")
	_assert_shared_edge_matches(Vector2i(0, 0), Vector2i(0, 1), "north/south")


func _assert_shared_edge_matches(a: Vector2i, b: Vector2i, label: String) -> void:
	var mesh_a: ArrayMesh = manager.get_chunk_mesh(a)
	var mesh_b: ArrayMesh = manager.get_chunk_mesh(b)
	assert_not_null(mesh_a, "Chunk %s must carry geometry." % a)
	assert_not_null(mesh_b, "Chunk %s must carry geometry." % b)
	if mesh_a == null or mesh_b == null:
		return

	var offset_a: Vector3 = manager.get_chunk_local_position(a)
	var offset_b: Vector3 = manager.get_chunk_local_position(b)

	var boundary_a: Dictionary = _collect_boundary_vertices(mesh_a, offset_a, a, b)
	var boundary_b: Dictionary = _collect_boundary_vertices(mesh_b, offset_b, b, a)

	assert_gt(boundary_a.size(), 0, "Chunk %s must own %s boundary vertices." % [a, label])

	var unmatched: int = 0
	for key in boundary_a:
		if not boundary_b.has(key):
			unmatched += 1

	assert_eq(unmatched, 0,
		"Seam error on the %s boundary: %d vertices of %s have no counterpart in %s."
		% [label, unmatched, a, b])


## Collects manager-local vertices sitting on the boundary plane shared with `other`.
func _collect_boundary_vertices(mesh: ArrayMesh, offset: Vector3,
		own: Vector2i, other: Vector2i) -> Dictionary:
	var meters: float = float(manager.chunk_size) * manager.cell_size
	var result: Dictionary = {}

	var use_x_axis: bool = own.x != other.x
	var boundary_value: float = 0.0
	if use_x_axis:
		boundary_value = float(maxi(own.x, other.x)) * meters
	else:
		boundary_value = -float(maxi(own.y, other.y)) * meters

	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for v in vertices:
		var world_v: Vector3 = v + offset
		var axis_value: float = world_v.x if use_x_axis else world_v.z
		if absf(axis_value - boundary_value) < 0.0001:
			# Quantized so float noise cannot split otherwise identical seam vertices.
			result[_quantize(world_v)] = true

	return result


func _quantize(v: Vector3) -> String:
	return "%.4f|%.4f|%.4f" % [v.x, v.y, v.z]


##@@
# --- PILLAR 3: WINDING ORDER INTEGRITY ---


func test_servers_backend_mesh_normals_face_upwards() -> void:
	_sculpt_some_terrain()
	_use_servers()

	# Asserted on the NORMAL array rather than on a raw cross product. Godot treats clockwise
	# triangles as front-facing, so for correctly oriented geometry the naive right-hand-rule
	# cross product points DOWN and a cross-product test would fail on working terrain.
	var checked: int = 0
	var downward: int = 0
	for coord in manager.get_chunk_coords():
		var mesh: ArrayMesh = manager.get_chunk_mesh(coord)
		if mesh == null:
			continue
		var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
		for n in normals:
			checked += 1
			if n.y <= 0.0:
				downward += 1

	assert_gt(checked, 0, "There must be normals to inspect.")
	assert_eq(downward, 0,
		"Winding order broken: %d of %d normals point away from the sky." % [downward, checked])


func test_both_backends_produce_identical_geometry() -> void:
	_sculpt_some_terrain()

	var node_faces: Dictionary = {}
	for coord in manager.get_chunk_coords():
		var mesh: ArrayMesh = manager.get_chunk_mesh(coord)
		node_faces[coord] = mesh.get_faces() if mesh != null else PackedVector3Array()

	_use_servers()

	for coord in node_faces:
		var mesh: ArrayMesh = manager.get_chunk_mesh(coord)
		var produced: PackedVector3Array = \
			mesh.get_faces() if mesh != null else PackedVector3Array()
		assert_eq(produced, node_faces[coord],
			"Chunk %s must be bit-identical across both backends, vertex order included."
			% coord)


func test_mesh_builder_matches_the_chunk_node_pipeline() -> void:
	_sculpt_some_terrain()

	var coord := Vector2i(0, 0)
	var chunk: LowPolyTerrainChunk = manager.chunks_dict[coord]
	var via_node: PackedVector3Array = (chunk.mesh as ArrayMesh).get_faces()

	var via_builder_mesh: ArrayMesh = LowPolyTerrainMeshBuilder.build_chunk_mesh(
		coord,
		manager.chunk_size,
		manager.cell_size,
		manager.extract_chunk_heights(coord),
		manager.jitter_strength,
		manager.jitter_slope_threshold
	)

	assert_not_null(via_builder_mesh, "The shared builder must produce geometry.")
	assert_eq(via_builder_mesh.get_faces(), via_node,
		"The shared builder must reproduce the chunk node geometry exactly.")


##@@
# --- SERVER SPECIFIC BEHAVIOUR ---


func test_servers_backend_joins_and_leaves_the_collision_group() -> void:
	assert_false(manager.is_in_group("Wall"),
		"MESH_NODES must not put the manager itself into the collision group.")

	_use_servers()
	assert_true(manager.is_in_group("Wall"),
		"SERVERS must join the collision group so collider.is_in_group() keeps working.")

	manager.terrain_backend = LowPolyTerrainManager.TerrainBackend.MESH_NODES
	assert_false(manager.is_in_group("Wall"),
		"Switching back must leave the collision group again.")


func test_collision_group_rename_moves_the_membership() -> void:
	_use_servers()
	manager.collision_group = "Terrain"

	assert_false(manager.is_in_group("Wall"), "The old group membership must be dropped.")
	assert_true(manager.is_in_group("Terrain"), "The new group must be joined immediately.")


func test_bake_button_is_inert_in_servers_mode() -> void:
	_use_servers()
	manager._bake_live_collisions_as_child()

	var parent: Node = manager.get_parent()
	assert_null(parent.get_node_or_null(manager.name + "_Collisions"),
		"Baking must be refused in SERVERS mode, since it would duplicate the physics.")


func test_deactivated_previews_are_editor_only() -> void:
	_use_servers()
	manager.show_deactivated_chunks = true
	manager.chunk_activity_data.fill(0)
	manager.rebuild_chunks_structure()

	# The red preview quads exist purely as an authoring aid, so a running game never pays
	# for them. This mirrors the node backend, which also skips deactivated chunks at runtime.
	var stats: Dictionary = manager._server_backend.get_debug_preview_stats()
	assert_eq(int(stats["instances"]), 0,
		"Deactivated chunk previews must not be created outside the editor.")


func test_deactivated_previews_share_one_mesh_and_material() -> void:
	_use_servers()
	manager.show_deactivated_chunks = true

	# Driven directly, because update_chunk() gates preview creation on the editor.
	var backend = manager._server_backend
	for cz in range(manager.world_chunks.y):
		for cx in range(manager.world_chunks.x):
			backend._ensure_preview_instance(Vector2i(cx, cz))

	var stats: Dictionary = backend.get_debug_preview_stats()
	assert_eq(int(stats["instances"]), 4, "Each deactivated chunk needs its own instance.")
	assert_eq(int(stats["meshes"]), 1,
		"All %d previews must share a single ArrayMesh, not one per chunk."
		% int(stats["instances"]))
	assert_eq(int(stats["materials"]), 1,
		"All %d previews must share a single material, not one per chunk."
		% int(stats["instances"]))


##@@
# --- ANALYTIC PICKING ---


func test_analytic_pick_ignores_active_chunks() -> void:
	manager.show_deactivated_chunks = true
	var result: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
		manager, Vector3(5.0, 20.0, -5.0), Vector3.DOWN)
	assert_false(bool(result["hit"]),
		"A ray onto an ACTIVE chunk must not register as a deactivated-grid hit.")


func test_analytic_pick_finds_a_deactivated_chunk() -> void:
	manager.show_deactivated_chunks = true
	manager.chunk_activity_data[0] = 0

	var result: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
		manager, Vector3(5.0, 20.0, -5.0), Vector3.DOWN)

	assert_true(bool(result["hit"]), "A ray onto a deactivated chunk must register a hit.")
	assert_eq(result["coord"], Vector2i(0, 0), "The hit must resolve to chunk (0,0).")
	assert_almost_eq(float(result["point"].y), 0.05, 0.0001,
		"The hit must land on the preview plane height.")


func test_analytic_pick_rejects_rays_outside_the_grid() -> void:
	manager.show_deactivated_chunks = true
	manager.chunk_activity_data.fill(0)

	# Far beyond the eastern edge of a 20x20 metre world.
	var outside: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
		manager, Vector3(500.0, 20.0, -5.0), Vector3.DOWN)
	assert_false(bool(outside["hit"]),
		"Coordinates outside the world must be rejected, not clamped onto a border chunk.")

	# Negative side, which naive integer division would fold onto chunk 0.
	var negative: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
		manager, Vector3(-5.0, 20.0, -5.0), Vector3.DOWN)
	assert_false(bool(negative["hit"]),
		"Negative coordinates must be rejected rather than truncated toward zero.")

	# Pointing away from the plane entirely.
	var upward: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
		manager, Vector3(5.0, 20.0, -5.0), Vector3.UP)
	assert_false(bool(upward["hit"]), "A ray pointing away from the plane must miss.")


func test_analytic_pick_is_silent_when_previews_are_hidden() -> void:
	manager.chunk_activity_data[0] = 0
	manager.show_deactivated_chunks = false

	var result: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
		manager, Vector3(5.0, 20.0, -5.0), Vector3.DOWN)
	assert_false(bool(result["hit"]),
		"Hidden deactivated previews must not be pickable.")


##@@
# --- TERRAIN RAYCAST ---
# These guard the brush picking path, which was untestable while it lived inside the
# EditorPlugin. That is precisely how a hardcoded 5000-unit reach survived in it unnoticed.


func _cast(origin: Vector3, dir: Vector3) -> Dictionary:
	var result: Dictionary = {}
	LowPolyTerrainPicking.raycast_terrain(manager, origin, dir, {}, result)
	return result


func _raise_some_relief() -> void:
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_height_at(gx, gz, float((gx + gz) % 4))
	manager.rebuild_chunks_structure()


func test_raycast_reaches_terrain_from_any_distance() -> void:
	_raise_some_relief()

	# The regression: a fixed-length segment made the brush vanish once the editor camera sat
	# farther away than the cap, which happens as soon as a large terrain is zoomed out.
	for height: float in [50.0, 2000.0, 6000.0, 20000.0, 100000.0]:
		var hit: Dictionary = _cast(Vector3(5.0, height, -5.0), Vector3.DOWN)
		assert_true(bool(hit["hit"]),
			"A ray from %.0f units above the terrain must still register a hit." % height)


func test_raycast_misses_when_pointing_away() -> void:
	_raise_some_relief()
	var hit: Dictionary = _cast(Vector3(5.0, 50.0, -5.0), Vector3.UP)
	assert_false(bool(hit["hit"]), "A ray pointing away from the terrain must miss.")


func test_raycast_misses_beside_the_terrain() -> void:
	_raise_some_relief()
	var hit: Dictionary = _cast(Vector3(-500.0, 50.0, -5.0), Vector3.DOWN)
	assert_false(bool(hit["hit"]), "A ray next to the terrain must miss.")


func test_raycast_returns_the_nearest_hit() -> void:
	_raise_some_relief()
	var origin := Vector3(5.0, 500.0, -5.0)
	var hit: Dictionary = _cast(origin, Vector3.DOWN)

	assert_true(bool(hit["hit"]), "Precondition: the ray hits.")
	# The reported distance must match the reported point, and the point must be the highest
	# surface under the ray rather than some lower triangle further along it.
	assert_almost_eq(float(hit["distance"]), origin.distance_to(hit["point"]), 0.001,
		"Reported distance must match the reported hit point.")
	assert_eq(hit["coord"], Vector2i(0, 0), "The hit must be attributed to the right chunk.")


func test_raycast_survives_a_scaled_manager() -> void:
	_raise_some_relief()
	manager.scale = Vector3(3.0, 1.0, 3.0)

	# Guards the affine_inverse() fix: inverse() is only valid for orthonormal bases and would
	# silently mis-transform the ray the moment the manager carries scale.
	var hit: Dictionary = _cast(Vector3(15.0, 500.0, -15.0), Vector3.DOWN)
	assert_true(bool(hit["hit"]), "Picking must keep working on a scaled manager.")
	assert_almost_eq(float(hit["point"].x), 15.0, 0.5,
		"The hit must lie on the cast ray, not somewhere the unscaled maths would put it.")


func test_raycast_survives_a_rotated_manager() -> void:
	_raise_some_relief()
	manager.rotation = Vector3(0.0, deg_to_rad(40.0), 0.0)

	var origin := Vector3(5.0, 500.0, -5.0)
	var hit: Dictionary = _cast(origin, Vector3.DOWN)
	if bool(hit["hit"]):
		assert_almost_eq(float(hit["point"].x), origin.x, 0.5,
			"A hit must lie on the cast ray regardless of manager rotation.")
		assert_almost_eq(float(hit["point"].z), origin.z, 0.5,
			"A hit must lie on the cast ray regardless of manager rotation.")


func test_raycast_agrees_between_both_backends() -> void:
	_raise_some_relief()
	var origin := Vector3(7.0, 400.0, -7.0)

	var from_nodes: Dictionary = _cast(origin, Vector3.DOWN)
	_use_servers()
	var from_servers: Dictionary = _cast(origin, Vector3.DOWN)

	# Picking is the one place where the two backends could silently diverge.
	assert_eq(bool(from_servers["hit"]), bool(from_nodes["hit"]),
		"Both backends must agree on whether the ray hits.")
	assert_true((from_servers["point"] as Vector3).is_equal_approx(from_nodes["point"]),
		"Both backends must report the identical hit point.")


func test_faces_cache_reuses_entries_until_the_mesh_changes() -> void:
	_raise_some_relief()
	var cache: Dictionary = {}
	var coord := Vector2i(0, 0)
	var mesh: ArrayMesh = manager.get_chunk_mesh(coord)

	var first: PackedVector3Array = LowPolyTerrainPicking.cached_faces(cache, coord, mesh)
	assert_eq(cache.size(), 1, "The first lookup must populate the cache.")

	var second: PackedVector3Array = LowPolyTerrainPicking.cached_faces(cache, coord, mesh)
	assert_eq(second, first, "An unchanged mesh must return the cached triangle soup.")

	# Regenerating a chunk commits a brand new ArrayMesh, which must invalidate the entry.
	manager.set_height_at(2, 2, 9.0)
	manager._update_single_chunk(coord)
	var rebuilt: ArrayMesh = manager.get_chunk_mesh(coord)
	var third: PackedVector3Array = LowPolyTerrainPicking.cached_faces(cache, coord, rebuilt)
	assert_ne(third, first, "A rebuilt mesh must not serve stale cached geometry.")


##@@
# --- TRANSFORM SYNCHRONIZATION ---


func test_redundant_transform_notifications_are_ignored() -> void:
	_use_servers()
	manager.position = Vector3(50.0, 0.0, -50.0)

	# Pushing the identical transform again must short-circuit. Without this guard a node
	# ancestor that re-notifies without really moving would drag the whole GDScript sweep
	# through every chunk once per frame for nothing.
	var backend = manager._server_backend
	var before: Transform3D = manager.get_chunk_global_transform(Vector2i(1, 1))
	backend.on_transform_changed(manager.global_transform)
	assert_true(backend._transform_pushed, "The first push must be recorded.")
	assert_true(before.is_equal_approx(manager.get_chunk_global_transform(Vector2i(1, 1))),
		"A redundant push must leave the chunk transforms exactly as they were.")

	# And a genuine change must still get through.
	manager.position = Vector3(120.0, 3.0, -80.0)
	backend.on_transform_changed(manager.global_transform)
	assert_false(before.is_equal_approx(manager.get_chunk_global_transform(Vector2i(1, 1))),
		"A real transform change must still propagate.")


func test_chunk_transforms_follow_the_manager() -> void:
	_use_servers()
	manager.position = Vector3(120.0, 7.0, -64.0)
	manager.rotation = Vector3(0.0, deg_to_rad(35.0), 0.0)

	var coord := Vector2i(1, 1)
	var expected: Transform3D = \
		manager.global_transform * manager._server_backend.get_local_transform(coord)

	assert_true(expected.is_equal_approx(manager.get_chunk_global_transform(coord)),
		"Server chunks must follow the manager transform, since no node does it for them.")


##@@
# --- DISTANCE BASED COLLISION CULLING ---


func test_collision_culling_selects_only_chunks_inside_the_radius() -> void:
	_use_servers()

	# A 3 metre radius at the origin can only reach chunk (0,0) of a 10 metre grid.
	manager.update_collision_culling(Vector3.ZERO, 3.0)
	assert_eq(manager._culling_enabled.size(), 1,
		"A tight radius must select exactly one chunk.")
	assert_true(manager._culling_enabled.has(Vector2i(0, 0)),
		"The selected chunk must be the one under the query point.")

	manager.update_collision_culling(Vector3(10.0, 0.0, -10.0), 40.0)
	assert_eq(manager._culling_enabled.size(), 4,
		"A radius covering the world must select every chunk.")

	manager.update_collision_culling(Vector3(900.0, 0.0, -900.0), 5.0)
	assert_eq(manager._culling_enabled.size(), 0,
		"Moving far away must release every chunk again.")


##@@
# --- AUTOMATIC CULLING TARGETS ---


func _make_target(pos: Vector3) -> Node3D:
	var target := Node3D.new()
	target.name = "CullTarget"
	add_child(target)
	target.global_position = pos
	return target


func test_cull_radius_is_prefilled_from_the_chunk_dimensions() -> void:
	manager._apply_derived_cull_radius()
	# chunk_size 10 cells at 1 metre each, two chunk edge lengths.
	assert_almost_eq(manager.collision_cull_radius, 20.0, 0.0001,
		"The radius must default to two chunk edge lengths, expressed in metres.")


func test_dimension_change_reprefills_an_untouched_radius() -> void:
	manager._apply_derived_cull_radius()
	assert_almost_eq(manager.collision_cull_radius, 20.0, 0.0001, "Precondition.")

	manager.preview_world_chunks = Vector2i(2, 2)
	manager.preview_chunk_size = 25
	manager.preview_cell_size = 2.0
	manager._apply_dimension_changes()

	assert_almost_eq(manager.collision_cull_radius, 100.0, 0.0001,
		"An untouched radius must follow the new chunk dimensions.")


func test_dimension_change_keeps_a_manual_radius() -> void:
	manager._apply_derived_cull_radius()
	manager.collision_cull_radius = 777.0

	manager.preview_world_chunks = Vector2i(2, 2)
	manager.preview_chunk_size = 25
	manager.preview_cell_size = 2.0
	manager._apply_dimension_changes()

	assert_almost_eq(manager.collision_cull_radius, 777.0, 0.0001,
		"A deliberately overridden radius must survive a dimension change.")


func test_assigned_target_drives_culling_without_any_glue_code() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()
	assert_eq(_count_bodies(), 0, "Precondition: CULLED builds nothing on its own.")

	var target: Node3D = _make_target(Vector3(2.0, 0.0, -2.0))
	manager.collision_cull_radius = 3.0
	manager.add_culling_target(target)

	# The initial pass runs immediately, so the target never spends a frame without ground.
	assert_gt(_count_bodies(), 0,
		"Assigning a target must build collision straight away, not one frame later.")
	assert_true(manager._culling_enabled.has(Vector2i(0, 0)),
		"The chunk under the target must be enabled.")

	target.free()


func test_target_movement_updates_the_enabled_set() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()

	var target: Node3D = _make_target(Vector3(2.0, 0.0, -2.0))
	manager.collision_cull_radius = 3.0
	manager.add_culling_target(target)
	assert_true(manager._culling_enabled.has(Vector2i(0, 0)), "Precondition.")

	# Cross into the diagonally opposite chunk of this 2x2 grid of 10 metre chunks.
	target.global_position = Vector3(18.0, 0.0, -18.0)
	manager._run_culling_from_targets(false)

	assert_true(manager._culling_enabled.has(Vector2i(1, 1)),
		"Moving into another chunk must enable it.")
	assert_false(manager._culling_enabled.has(Vector2i(0, 0)),
		"The chunk left behind must be released again.")

	target.free()


func test_culling_pass_is_skipped_while_inside_the_same_chunk() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()

	var target: Node3D = _make_target(Vector3(2.0, 0.0, -2.0))
	manager.collision_cull_radius = 3.0
	manager.add_culling_target(target)

	var handover_before: bool = manager._culling_handover_done
	var enabled_before: int = manager._culling_enabled.size()

	# Movement well inside the same chunk cell cannot change the result, so the pass must not
	# redo the work: this is what keeps a per-physics-frame callback essentially free.
	target.global_position = Vector3(2.5, 0.0, -2.5)
	manager._run_culling_from_targets(false)

	assert_eq(manager._culling_enabled.size(), enabled_before,
		"A sub-chunk move must leave the enabled set untouched.")
	assert_eq(manager._culling_handover_done, handover_before, "State must be unchanged.")

	target.free()


func test_multiple_targets_union_their_radii() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()
	manager.collision_cull_radius = 3.0

	var near := _make_target(Vector3(2.0, 0.0, -2.0))
	var far := _make_target(Vector3(18.0, 0.0, -18.0))
	manager.add_culling_target(near)
	manager.add_culling_target(far)

	assert_true(manager._culling_enabled.has(Vector2i(0, 0)), "First target's chunk.")
	assert_true(manager._culling_enabled.has(Vector2i(1, 1)), "Second target's chunk.")

	near.free()
	far.free()


func test_removing_a_target_releases_its_chunks() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()
	manager.collision_cull_radius = 3.0

	var target: Node3D = _make_target(Vector3(2.0, 0.0, -2.0))
	manager.add_culling_target(target)
	assert_gt(_count_bodies(), 0, "Precondition: the target built collision.")

	manager.remove_culling_target(target)

	assert_eq(manager._culling_enabled.size(), 0,
		"Removing the last target must release every chunk it held.")
	assert_eq(_count_bodies(), 0,
		"The released chunks must give their colliders back, not just be marked disabled.")

	target.free()


func test_freed_targets_do_not_break_the_pass() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()
	manager.collision_cull_radius = 3.0

	var target: Node3D = _make_target(Vector3(2.0, 0.0, -2.0))
	manager.add_culling_target(target)
	target.free()

	# The stale entry must simply be ignored rather than raising on global_position.
	manager._run_culling_from_targets(true)
	assert_true(true, "Running the pass with a freed target must not error.")


func test_collision_culling_skips_deactivated_chunks() -> void:
	_use_servers()
	manager.chunk_activity_data[0] = 0

	manager.update_collision_culling(Vector3.ZERO, 3.0)
	assert_false(manager._culling_enabled.has(Vector2i(0, 0)),
		"A deactivated chunk must never be selected for collision.")


##@@
# --- RUNTIME COLLISION POLICY ---
# GUT runs with Engine.is_editor_hint() == false, so these exercise the real runtime path.


func _count_bodies() -> int:
	var total: int = 0
	for coord in manager.get_chunk_coords():
		if manager._server_backend.has_body(coord):
			total += 1
	return total


func test_collision_policy_all_builds_every_chunk() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	_use_servers()
	assert_eq(_count_bodies(), 4, "ALL must give every active chunk a collider.")


func test_collision_policy_none_builds_nothing() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.NONE
	_use_servers()
	assert_eq(_count_bodies(), 0, "NONE must not create a single collider.")


func test_collision_policy_culled_builds_nothing_until_culling_runs() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()

	# This is the whole point of CULLED: releasing a collider does not return its
	# physics-server memory, so a collider outside the radius must never be built at all.
	assert_eq(_count_bodies(), 0,
		"CULLED must not build colliders before a radius has been reported.")

	# A 3 metre radius at the origin reaches only chunk (0,0) of this 10 metre grid.
	manager.update_collision_culling(Vector3.ZERO, 3.0)
	assert_eq(_count_bodies(), 1, "CULLED must build exactly the chunk inside the radius.")
	assert_true(manager._server_backend.has_body(Vector2i(0, 0)),
		"The built collider must be the chunk under the query point.")


func test_collision_policy_culled_releases_chunks_that_leave_the_radius() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	_use_servers()

	manager.update_collision_culling(Vector3(10.0, 0.0, -10.0), 40.0)
	assert_eq(_count_bodies(), 4, "A wide radius must build every chunk.")

	manager.update_collision_culling(Vector3(900.0, 0.0, -900.0), 5.0)
	assert_eq(_count_bodies(), 0, "Leaving the area must release every collider.")


func test_switching_policy_to_none_releases_existing_colliders() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	_use_servers()
	assert_eq(_count_bodies(), 4, "Precondition: ALL built the colliders.")

	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.NONE
	assert_eq(_count_bodies(), 0, "Switching to NONE must release every collider.")


##@@
# --- COLLISION DEBUG OVERLAY ---


func test_collision_overlay_draws_one_instance_per_live_collider() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	manager.collision_debug_draw = LowPolyTerrainManager.CollisionDebugDraw.ALWAYS
	_use_servers()

	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 4,
		"Every collider must get exactly one overlay instance.")


func test_collision_overlay_tracks_the_culling_radius() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.CULLED
	manager.collision_debug_draw = LowPolyTerrainManager.CollisionDebugDraw.ALWAYS
	_use_servers()

	# This is the overlay's main purpose: making the culled set directly visible.
	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 0,
		"With nothing culled in yet there is no collider and therefore no overlay.")

	manager.update_collision_culling(Vector3.ZERO, 3.0)
	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 1,
		"The overlay must appear for the chunk that just gained a collider.")

	manager.update_collision_culling(Vector3(900.0, 0.0, -900.0), 5.0)
	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 0,
		"The overlay must disappear together with the collider.")


func test_collision_overlay_can_be_toggled_off_again() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	manager.collision_debug_draw = LowPolyTerrainManager.CollisionDebugDraw.ALWAYS
	_use_servers()
	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 4,
		"Precondition: the overlay is up.")

	manager.collision_debug_draw = LowPolyTerrainManager.CollisionDebugDraw.NEVER
	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 0,
		"Switching the overlay off must release every debug instance.")


func test_collision_overlay_is_off_by_default_in_tests() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	_use_servers()

	# FOLLOW_DEBUG_MENU resolves to SceneTree.debug_collisions_hint, which is false unless the
	# project was launched with Visible Collision Shapes enabled.
	assert_false(manager.is_collision_debug_draw_active(),
		"The default must not draw an overlay unless Godot's debug flag asks for it.")
	assert_eq(manager._server_backend.get_debug_collision_overlay_count(), 0,
		"No overlay instances may exist while the overlay is inactive.")


##@@
# --- REGRESSION GUARDS ---


func test_deactivating_a_chunk_releases_its_collider() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	_use_servers()
	assert_true(manager._server_backend.has_body(Vector2i(0, 0)),
		"Precondition: the chunk starts with a collider.")

	manager.chunk_activity_data[0] = 0
	manager._update_single_chunk(Vector2i(0, 0))

	# Otherwise a deactivated area keeps invisible collision AND pins its shape memory.
	assert_false(manager._server_backend.has_body(Vector2i(0, 0)),
		"A deactivated chunk must not keep a collider.")
	var record = manager._server_backend.get_debug_record(Vector2i(0, 0))
	assert_null(record.shape, "The collision shape itself must be released as well.")


func test_collider_follows_a_regenerated_mesh() -> void:
	manager.runtime_collision = LowPolyTerrainManager.RuntimeCollision.ALL
	_use_servers()

	var coord := Vector2i(0, 0)
	var record = manager._server_backend.get_debug_record(coord)
	assert_not_null(record.shape, "Precondition: a shape exists.")
	var faces_before: PackedVector3Array = record.shape.get_faces()

	# Reshape the terrain, then push the update through the normal path.
	for gz in range(manager._total_vertices_z):
		for gx in range(manager._total_vertices_x):
			manager.set_height_at(gx, gz, float((gx + gz) % 5) * 1.5)
	manager._update_single_chunk(coord)

	var faces_after: PackedVector3Array = record.shape.get_faces()
	assert_ne(faces_after, faces_before,
		"The collider must be rebuilt when the render mesh changes, not frozen on frame one.")

	# And it must agree with what is actually being drawn.
	assert_eq(faces_after, (manager.get_chunk_mesh(coord) as ArrayMesh).get_faces(),
		"Collider geometry must match the rendered mesh exactly.")
