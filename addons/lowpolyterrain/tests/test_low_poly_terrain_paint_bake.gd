extends GutTest

## Regression suite for the glTF paint bake.
##
## The bug these guard against: everything painted with the Paint brush disappeared on export.
## The weights did reach the file - they ride along as the mesh's vertex colours - but nothing in
## it knew they were weights, because the thing that turns them into colours is a ShaderMaterial
## and glTF has no way to carry a shader. LowPolyTerrainPaintBake resolves that by running the
## overlay's arithmetic on the CPU and writing out textures instead.
##
## Every assertion below is about a property of the EXPORTED data rather than of the editor
## session, since that is where the loss happened.

var manager: LowPolyTerrainManager = null

const CHUNK_SIZE: int = 8
const WORLD_CHUNKS := Vector2i(2, 1)


func before_each() -> void:
	manager = LowPolyTerrainManager.new()
	manager.name = "PaintBakeTerrain"
	add_child(manager)

	manager.world_chunks = WORLD_CHUNKS
	manager.chunk_size = CHUNK_SIZE
	manager.cell_size = 1.0
	manager.step_height = 0.5
	manager.global_height_data = PackedFloat32Array()
	manager.chunk_activity_data = PackedByteArray()
	manager._setup_pending = false
	manager.rebuild_chunks_structure()
	manager.ensure_paint_material()


func after_each() -> void:
	if is_instance_valid(manager):
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


func _cells() -> Vector2i:
	return Vector2i(WORLD_CHUNKS.x * CHUNK_SIZE, WORLD_CHUNKS.y * CHUNK_SIZE)


func _edge() -> Vector2i:
	var cells: Vector2i = _cells()
	return Vector2i(
		LowPolyTerrainPaintBake.texture_edge_for(cells.x),
		LowPolyTerrainPaintBake.texture_edge_for(cells.y)
	)


func _bake(base_color: Color = Color.WHITE) -> StandardMaterial3D:
	var colors := PackedColorArray()
	var roughness := PackedFloat32Array()
	for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
		colors.append(manager.get_paint_layer_color(layer))
		roughness.append(manager.get_paint_layer_roughness(layer))

	var cells: Vector2i = _cells()
	return LowPolyTerrainPaintBake.bake_terrain_material(
		manager.global_paint_data,
		cells.x + 1,
		cells.y + 1,
		LowPolyTerrainManager.PAINT_STEPS,
		colors,
		roughness,
		base_color,
		1.0,
		"PaintBakeTerrain"
	)


func _paint_column(x: int, weights: Color) -> void:
	for z in range(manager._total_vertices_z):
		manager.set_paint_at(x, z, weights)


## The texel a grid point maps onto, straight out of the UV mapping the export writes.
func _texel_of_grid_point(gx: int, gz: int) -> Vector2i:
	var coord := Vector2i(gx / CHUNK_SIZE, gz / CHUNK_SIZE)
	coord.x = mini(coord.x, WORLD_CHUNKS.x - 1)
	coord.y = mini(coord.y, WORLD_CHUNKS.y - 1)

	var edge: Vector2i = _edge()
	var mapping: Transform2D = LowPolyTerrainPaintBake.uv_mapping(
		coord, CHUNK_SIZE, _cells(), edge
	)
	var local_uv := Vector2(
		float(gx - coord.x * CHUNK_SIZE) / float(CHUNK_SIZE),
		float(gz - coord.y * CHUNK_SIZE) / float(CHUNK_SIZE)
	)
	var uv: Vector2 = mapping * local_uv

	# What a linear sampler reads at that UV.
	return Vector2i(
		roundi(uv.x * float(edge.x) - 0.5), roundi(uv.y * float(edge.y) - 0.5)
	)


# --- THE REPORTED BUG: a painted layer has to reach the exported material ---
func test_full_coverage_bakes_the_layer_colour() -> void:
	_paint_column(2, Color(1.0, 0.0, 0.0, 0.0))

	var material: StandardMaterial3D = _bake()
	assert_not_null(material.albedo_texture, "The bake must produce an albedo texture.")

	var texel: Vector2i = _texel_of_grid_point(2, 4)
	var baked: Color = material.albedo_texture.get_image().get_pixel(texel.x, texel.y)
	var expected: Color = manager.get_paint_layer_color(1)
	assert_almost_eq(baked.r, expected.r, 0.01, "Layer 1 red must survive the bake.")
	assert_almost_eq(baked.g, expected.g, 0.01, "Layer 1 green must survive the bake.")
	assert_almost_eq(baked.b, expected.b, 0.01, "Layer 1 blue must survive the bake.")


func test_unpainted_ground_keeps_the_base_colour() -> void:
	_paint_column(2, Color(1.0, 0.0, 0.0, 0.0))

	var base := Color(0.2, 0.4, 0.1)
	var texel: Vector2i = _texel_of_grid_point(10, 4)
	var baked: Color = _bake(base).albedo_texture.get_image().get_pixel(texel.x, texel.y)

	assert_almost_eq(baked.r, base.r, 0.01, "Unpainted ground must show the base colour.")
	assert_almost_eq(baked.g, base.g, 0.01, "Unpainted ground must show the base colour.")
	assert_almost_eq(baked.b, base.b, 0.01, "Unpainted ground must show the base colour.")


## Partial coverage blends in LINEAR space, because that is where the shader blends. Mixing the
## inspector's sRGB values directly would put every soft brush edge a shade off.
func test_partial_coverage_blends_against_the_base_in_linear_space() -> void:
	_paint_column(2, Color(0.0, 0.0, 0.5, 0.0))

	var texel: Vector2i = _texel_of_grid_point(2, 4)
	var baked: Color = _bake().albedo_texture.get_image().get_pixel(texel.x, texel.y)

	var layer: Color = manager.get_paint_layer_color(3).srgb_to_linear()
	var expected := Color(
		lerpf(1.0, layer.r, 0.5), lerpf(1.0, layer.g, 0.5), lerpf(1.0, layer.b, 0.5)
	).linear_to_srgb()

	assert_almost_eq(baked.r, expected.r, 0.02, "Half coverage must blend in linear space.")
	assert_almost_eq(baked.g, expected.g, 0.02, "Half coverage must blend in linear space.")
	assert_almost_eq(baked.b, expected.b, 0.02, "Half coverage must blend in linear space.")


## The whole point of a terrain-wide bake: a vertex must land on the texel carrying its OWN
## weights. Half a texel off and every painted edge shifts by a quarter of a cell.
func test_uv_mapping_lands_every_grid_point_on_its_own_texel() -> void:
	var cells: Vector2i = _cells()
	var edge: Vector2i = _edge()

	for gx in range(cells.x + 1):
		for gz in range(cells.y + 1):
			var texel: Vector2i = _texel_of_grid_point(gx, gz)
			assert_eq(
				texel.x, gx * LowPolyTerrainPaintBake.CELL_RESOLUTION,
				"Grid point %d,%d must sample its own column." % [gx, gz]
			)
			assert_eq(
				texel.y, gz * LowPolyTerrainPaintBake.CELL_RESOLUTION,
				"Grid point %d,%d must sample its own row." % [gx, gz]
			)
	assert_between(edge.x, 1, LowPolyTerrainPaintBake.MAX_TEXTURE_EDGE, "Edge stays capped.")


## Two chunks meeting at a shared grid column must read the SAME texel out of the shared texture.
## That is what a terrain-wide bake buys over one texture per chunk: no tile border to disagree.
func test_chunks_meeting_at_a_border_sample_the_same_texel() -> void:
	var cells: Vector2i = _cells()
	var edge: Vector2i = _edge()
	var border_uv := Vector2(1.0, 0.5)

	var left: Vector2 = LowPolyTerrainPaintBake.uv_mapping(
		Vector2i(0, 0), CHUNK_SIZE, cells, edge
	) * border_uv
	var right: Vector2 = LowPolyTerrainPaintBake.uv_mapping(
		Vector2i(1, 0), CHUNK_SIZE, cells, edge
	) * Vector2(0.0, 0.5)

	assert_almost_eq(left.x, right.x, 0.0001, "The shared column must map to one place.")
	assert_almost_eq(left.y, right.y, 0.0001, "The shared column must map to one place.")


func test_layer_roughness_is_baked_into_the_green_channel() -> void:
	_paint_column(2, Color(0.0, 0.0, 1.0, 0.0))

	var material: StandardMaterial3D = _bake()
	assert_not_null(material.roughness_texture, "The bake must produce a roughness texture.")
	assert_eq(
		material.roughness_texture_channel, BaseMaterial3D.TEXTURE_CHANNEL_GREEN,
		"glTF keeps roughness in green, so the material has to read it there."
	)

	var texel: Vector2i = _texel_of_grid_point(2, 4)
	var baked: Color = material.roughness_texture.get_image().get_pixel(texel.x, texel.y)
	assert_almost_eq(
		baked.g, manager.get_paint_layer_roughness(3), 0.01,
		"Layer 3's roughness must reach the exported texture."
	)


## The texture spans the terrain exactly, so repeat would fold the far side of the world back in
## along the outer border.
func test_baked_material_samples_clamped() -> void:
	_paint_column(2, Color(1.0, 0.0, 0.0, 0.0))
	assert_false(_bake().texture_repeat, "The terrain bake must not repeat.")


## One bake, one material, one pair of images - the whole reason for going terrain-wide.
func test_one_texture_pair_covers_the_whole_terrain() -> void:
	_paint_column(2, Color(1.0, 0.0, 0.0, 0.0))

	var material: StandardMaterial3D = _bake()
	var cells: Vector2i = _cells()
	assert_eq(
		material.albedo_texture.get_size(),
		Vector2(_edge().x, _edge().y),
		"The albedo texture must span every cell of the terrain."
	)
	assert_eq(
		material.albedo_texture.get_width(),
		cells.x * LowPolyTerrainPaintBake.CELL_RESOLUTION + 1,
		"An uncapped terrain gets the full bake resolution."
	)
	assert_ne(
		material.albedo_texture.resource_name, material.roughness_texture.resource_name,
		"The two images must not write to the same filename."
	)


## The vertex colours ARE the weights, and glTF gives COLOR_0 a fixed meaning: every conformant
## reader multiplies it into the base colour. Shipping them would black out an unpainted terrain
## and double-tint a painted one on top of the bake.
func test_export_copy_drops_the_weight_vertex_colours() -> void:
	_paint_column(2, Color(1.0, 0.0, 0.0, 0.0))
	manager.rebuild_chunks_structure()

	var source: ArrayMesh = manager.get_chunk_mesh(Vector2i(0, 0))
	assert_not_null(source, "The chunk must have a mesh to export.")

	var stripped: ArrayMesh = LowPolyTerrainPaintBake.mesh_for_export(
		source, Transform2D.IDENTITY
	)
	assert_not_null(
		source.surface_get_arrays(0)[Mesh.ARRAY_COLOR],
		"The live mesh must keep its weights - the shader still draws from them."
	)
	assert_null(
		stripped.surface_get_arrays(0)[Mesh.ARRAY_COLOR],
		"The exported copy must not carry weights glTF would read as a colour."
	)


## The baked texture is sampled by these UVs, so losing or mis-transforming them would leave the
## export with an image nothing maps onto.
func test_export_copy_moves_uvs_without_touching_geometry() -> void:
	_paint_column(2, Color(1.0, 0.0, 0.0, 0.0))
	manager.rebuild_chunks_structure()

	var source: ArrayMesh = manager.get_chunk_mesh(Vector2i(1, 0))
	var mapping: Transform2D = LowPolyTerrainPaintBake.uv_mapping(
		Vector2i(1, 0), CHUNK_SIZE, _cells(), _edge()
	)
	var exported: ArrayMesh = LowPolyTerrainPaintBake.mesh_for_export(source, mapping)

	var source_uvs: PackedVector2Array = source.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var exported_uvs: PackedVector2Array = exported.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	assert_eq(exported_uvs.size(), source_uvs.size(), "Every vertex keeps a UV.")

	# The right-hand chunk must map into the RIGHT half of the shared texture.
	for uv: Vector2 in exported_uvs:
		assert_between(uv.x, 0.49, 1.0, "Chunk 1,0 must sample the right half of the bake.")

	assert_eq(
		exported.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		source.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
		"The export copy must not change the geometry."
	)
	assert_eq(
		exported.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size(),
		source.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size(),
		"The export copy must not change the triangulation."
	)


## An unpainted terrain is baked with an empty array, which must read as "no paint" rather than
## as four zero-weight layers that darken the ground.
func test_an_empty_paint_array_bakes_to_the_base_colour() -> void:
	var base := Color(0.3, 0.5, 0.7)
	var cells: Vector2i = _cells()
	var material: StandardMaterial3D = LowPolyTerrainPaintBake.bake_terrain_material(
		PackedByteArray(),
		cells.x + 1,
		cells.y + 1,
		LowPolyTerrainManager.PAINT_STEPS,
		PackedColorArray([Color.RED, Color.GREEN, Color.BLUE, Color.BLACK]),
		PackedFloat32Array([0.5, 0.5, 0.5, 0.5]),
		base,
		1.0
	)

	var baked: Color = material.albedo_texture.get_image().get_pixel(4, 4)
	assert_almost_eq(baked.r, base.r, 0.01, "No paint must leave the base colour alone.")
	assert_almost_eq(baked.g, base.g, 0.01, "No paint must leave the base colour alone.")
	assert_almost_eq(baked.b, base.b, 0.01, "No paint must leave the base colour alone.")


## A world large enough to blow past the ceiling must still be covered end to end, just coarser.
func test_a_huge_terrain_caps_its_texture_instead_of_growing_without_bound() -> void:
	var huge: int = LowPolyTerrainPaintBake.MAX_TEXTURE_EDGE * 4
	assert_eq(
		LowPolyTerrainPaintBake.texture_edge_for(huge),
		LowPolyTerrainPaintBake.MAX_TEXTURE_EDGE,
		"The bake must not grow past its ceiling."
	)

	var mapping: Transform2D = LowPolyTerrainPaintBake.uv_mapping(
		Vector2i(0, 0), CHUNK_SIZE, Vector2i(huge, huge),
		Vector2i(LowPolyTerrainPaintBake.MAX_TEXTURE_EDGE,
			LowPolyTerrainPaintBake.MAX_TEXTURE_EDGE)
	)
	var uv: Vector2 = mapping * Vector2(1.0, 1.0)
	assert_between(uv.x, 0.0, 1.0, "A capped bake still maps inside the texture.")
	assert_between(uv.y, 0.0, 1.0, "A capped bake still maps inside the texture.")
