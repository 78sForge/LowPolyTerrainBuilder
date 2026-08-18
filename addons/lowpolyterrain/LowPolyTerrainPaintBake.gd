@tool
extends RefCounted
class_name LowPolyTerrainPaintBake

## Stateless converter that turns painted layer weights into the two textures glTF understands.
##
## This exists because glTF carries materials as PBR PROPERTIES, never as programs. A
## ShaderMaterial therefore has no representation in the format at all - Godot writes it out as
## an empty material and the terrain arrives white, which is exactly how painted terrain used to
## come back from an export.
##
## The paint layers are the one part of the look that CAN cross over, because they are data
## rather than code: four colours, four roughness values, and a weight per grid point. What this
## class does is run terrain_paint.gdshaderinc's arithmetic on the CPU, once per texel, and hand
## back a StandardMaterial3D that any glTF reader can draw.
##
## ONE PAIR OF TEXTURES FOR THE WHOLE TERRAIN, not one per chunk. Per-chunk textures were the
## obvious first shape and the wrong one: a 10x10 world wrote 200 PNG files next to the .gltf,
## every one of them a separate import for the editor to chew through. A single terrain-wide
## bake also removes the question of whether neighbouring chunks agree along their shared border,
## because with no tile boundaries there is nothing left to disagree.
##
## Holds no state, exactly like LowPolyTerrainMeshBuilder, so it is callable from the editor
## plugin and from a test alike.


## Baked texture pixels per terrain CELL along one edge.
##
## The chunk meshes already carry UVs running 0..1 across the chunk (see
## LowPolyTerrainMeshBuilder.build_chunk_mesh), so the resolution is chosen against the PAINT
## GRID rather than against the geometry. One pixel per grid point would already be lossless for
## the weights, since the grid is where they live; the second one is there because the exported
## texture is filtered linearly, and a brush edge falling between two grid points otherwise
## smears across a full cell instead of half of one.
const CELL_RESOLUTION: int = 2


## Ceiling on either texture edge.
##
## A terrain-wide bake grows with the world, and the loop below is GDScript running once per
## texel. 2048 keeps the worst case in the seconds rather than the minutes, and a terrain large
## enough to hit it is one where a quarter of a cell of paint precision is invisible anyway. The
## cap costs resolution, never coverage - the texture still spans the whole terrain.
const MAX_TEXTURE_EDGE: int = 2048


## The baked texture edge for a terrain that is `cells` cells wide, capped.
##
## Public because the caller wants to know whether the cap bit, which is worth saying out loud.
static func texture_edge_for(cells: int) -> int:
	return mini(maxi(cells, 1) * CELL_RESOLUTION + 1, MAX_TEXTURE_EDGE)


## Bakes the whole terrain's paint into an albedo and a roughness texture and returns the single
## material every chunk renders with.
##
## `paint_data` is the manager's global weight array, `vertices_x` and `vertices_z` its grid
## dimensions. `base_color` and `base_roughness` are what shows through wherever the four layers
## leave the surface uncovered.
static func bake_terrain_material(
	paint_data: PackedByteArray,
	vertices_x: int,
	vertices_z: int,
	paint_steps: int,
	layer_colors: PackedColorArray,
	layer_roughness: PackedFloat32Array,
	base_color: Color,
	base_roughness: float,
	terrain_name: String = "Terrain"
) -> StandardMaterial3D:
	var cells_x: int = maxi(vertices_x - 1, 1)
	var cells_z: int = maxi(vertices_z - 1, 1)
	var edge_x: int = texture_edge_for(cells_x)
	var edge_z: int = texture_edge_for(cells_z)

	# LINEAR SPACE THROUGHOUT, because that is where the shader mixes. A source_color uniform is
	# converted on its way to the GPU, so blending the inspector's values directly would run both
	# the layer-against-layer and the paint-against-base transitions along a different curve than
	# the editor draws, and every soft brush edge would come out a shade off.
	var linear_layers := PackedColorArray()
	for entry: Color in layer_colors:
		linear_layers.append(entry.srgb_to_linear())
	var linear_base: Color = base_color.srgb_to_linear()

	var albedo_bytes := PackedByteArray()
	var roughness_bytes := PackedByteArray()
	albedo_bytes.resize(edge_x * edge_z * 4)
	roughness_bytes.resize(edge_x * edge_z * 4)

	var span_x: float = float(maxi(edge_x - 1, 1))
	var span_z: float = float(maxi(edge_z - 1, 1))
	var layer_count: int = mini(linear_layers.size(), layer_roughness.size())

	for py in range(edge_z):
		# The grid row this pixel stands for. uv_mapping() below is the exact inverse, so a vertex
		# sitting on a grid point samples that grid point's own weights rather than a blend of it
		# with its neighbour.
		var gz: float = float(py) * float(cells_z) / span_z
		var z0: int = clampi(int(gz), 0, cells_z - 1)
		var z1: int = mini(z0 + 1, cells_z)
		var tz: float = gz - float(z0)

		for px in range(edge_x):
			var gx: float = float(px) * float(cells_x) / span_x
			var x0: int = clampi(int(gx), 0, cells_x - 1)
			var x1: int = mini(x0 + 1, cells_x)
			var tx: float = gx - float(x0)

			# Bilinear across the four surrounding grid points, which is what the rasteriser does
			# to the same weights when it interpolates them across a triangle.
			var top: Color = LowPolyTerrainMeshBuilder.paint_color_at(
				paint_data, vertices_x, x0, z0, paint_steps
			).lerp(
				LowPolyTerrainMeshBuilder.paint_color_at(
					paint_data, vertices_x, x1, z0, paint_steps
				), tx
			)
			var bottom: Color = LowPolyTerrainMeshBuilder.paint_color_at(
				paint_data, vertices_x, x0, z1, paint_steps
			).lerp(
				LowPolyTerrainMeshBuilder.paint_color_at(
					paint_data, vertices_x, x1, z1, paint_steps
				), tx
			)
			var weights: Color = top.lerp(bottom, tz)

			var albedo: Color = linear_base
			var roughness: float = base_roughness

			# The RAW sum divides the layers so they keep their proportions to each other; the
			# CLAMPED one is the coverage the base still shows through. lpt_paint_layer_color()
			# and lpt_paint_total() draw exactly this distinction, and collapsing the two would
			# darken every overlap.
			var raw_total: float = weights.r + weights.g + weights.b + weights.a
			if raw_total > 0.0:
				var coverage: float = clampf(raw_total, 0.0, 1.0)
				var mix_r: float = 0.0
				var mix_g: float = 0.0
				var mix_b: float = 0.0
				var mix_roughness: float = 0.0

				for layer in range(layer_count):
					var weight: float = weight_of_layer(weights, layer)
					mix_r += linear_layers[layer].r * weight
					mix_g += linear_layers[layer].g * weight
					mix_b += linear_layers[layer].b * weight
					mix_roughness += layer_roughness[layer] * weight

				albedo = Color(
					lerpf(linear_base.r, mix_r / raw_total, coverage),
					lerpf(linear_base.g, mix_g / raw_total, coverage),
					lerpf(linear_base.b, mix_b / raw_total, coverage),
					1.0
				)
				roughness = lerpf(base_roughness, mix_roughness / raw_total, coverage)

			var offset: int = (py * edge_x + px) * 4
			var srgb: Color = albedo.linear_to_srgb()
			albedo_bytes[offset] = to_byte(srgb.r)
			albedo_bytes[offset + 1] = to_byte(srgb.g)
			albedo_bytes[offset + 2] = to_byte(srgb.b)
			albedo_bytes[offset + 3] = 255

			# Green, because that is the channel glTF's metallicRoughnessTexture keeps roughness
			# in and the one TEXTURE_CHANNEL_GREEN below reads back. Written raw rather than
			# encoded: roughness is a number, not a colour, and no viewer gamma-decodes it.
			roughness_bytes[offset + 1] = to_byte(roughness)
			roughness_bytes[offset + 3] = 255

	var albedo_texture := ImageTexture.create_from_image(
		Image.create_from_data(edge_x, edge_z, false, Image.FORMAT_RGBA8, albedo_bytes)
	)
	var roughness_texture := ImageTexture.create_from_image(
		Image.create_from_data(edge_x, edge_z, false, Image.FORMAT_RGBA8, roughness_bytes)
	)

	# Named because a .gltf export writes its images as files, and the exporter derives their
	# names from the resource. Unnamed textures land on disk as a bare "_albedo.png".
	albedo_texture.resource_name = "%s_paint_albedo" % terrain_name
	roughness_texture.resource_name = "%s_paint_roughness" % terrain_name

	var material := StandardMaterial3D.new()
	material.resource_name = "%s_paint" % terrain_name
	material.albedo_texture = albedo_texture
	material.roughness_texture = roughness_texture
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	material.roughness = 1.0
	material.metallic = 0.0

	# CLAMP, not repeat. The texture spans the terrain exactly, so there is nothing beyond its
	# edge to fetch; repeating would fold the far side of the world in along the outer border.
	material.texture_repeat = false
	return material


## The affine map from one chunk mesh's own 0..1 UVs into the terrain-wide bake's coordinates.
##
## Derived rather than approximated. A texel `i` holds the weights at grid position
## `i * cells / (edge - 1)`, and a linear sampler reads texel `uv * edge - 0.5`. Setting the two
## equal for a vertex standing at grid position `g` gives `uv = (g * (edge - 1) / cells + 0.5) /
## edge`, which is affine in the chunk-local UV - so it survives as a Transform2D and every
## vertex lands on the texel that carries its own paint instead of half a texel beside it.
static func uv_mapping(
	coord: Vector2i, chunk_size: int, cells: Vector2i, edge: Vector2i
) -> Transform2D:
	var cells_x: float = float(maxi(cells.x, 1))
	var cells_z: float = float(maxi(cells.y, 1))
	var edge_x: float = float(maxi(edge.x, 1))
	var edge_z: float = float(maxi(edge.y, 1))
	var texels_x: float = edge_x - 1.0
	var texels_z: float = edge_z - 1.0

	var scale_x: float = float(chunk_size) * texels_x / (cells_x * edge_x)
	var scale_z: float = float(chunk_size) * texels_z / (cells_z * edge_z)
	var offset_x: float = (
		float(coord.x * chunk_size) * texels_x / cells_x + 0.5
	) / edge_x
	var offset_z: float = (
		float(coord.y * chunk_size) * texels_z / cells_z + 0.5
	) / edge_z

	return Transform2D(
		Vector2(scale_x, 0.0), Vector2(0.0, scale_z), Vector2(offset_x, offset_z)
	)


## One layer's weight out of the four packed into a vertex colour, in the shader's channel order.
static func weight_of_layer(weights: Color, layer: int) -> float:
	match layer:
		0: return weights.r
		1: return weights.g
		2: return weights.b
		_: return weights.a


## Quantises a 0..1 value into one texture byte, rounded rather than truncated.
static func to_byte(value: float) -> int:
	return int(clampf(value, 0.0, 1.0) * 255.0 + 0.5)


## The export's copy of a chunk mesh: UVs moved into the terrain-wide bake, vertex colours gone.
##
## THE COLOURS ARE THE PAINT WEIGHTS, and glTF gives COLOR_0 a fixed meaning: every conformant
## reader multiplies it into the base colour. Four weights that are zero across most of a terrain
## - and across all of an unpainted one - would therefore black the whole thing out, and where
## paint does sit they would tint the baked texture a second time. The weights have done their
## job by the time the bake is written, so they are dropped rather than shipped as something the
## format will read as a different quantity entirely.
##
## Pass Transform2D.IDENTITY to leave the UVs where they are, which is what an unpainted terrain
## wants: nothing samples a bake that was never made.
static func mesh_for_export(source: ArrayMesh, uv_transform: Transform2D) -> ArrayMesh:
	var stripped := ArrayMesh.new()
	stripped.resource_name = source.resource_name

	for surface in range(source.get_surface_count()):
		var arrays: Array = source.surface_get_arrays(surface)
		arrays[Mesh.ARRAY_COLOR] = null

		if uv_transform != Transform2D.IDENTITY:
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			if uvs != null and not uvs.is_empty():
				for i in range(uvs.size()):
					uvs[i] = uv_transform * uvs[i]
				arrays[Mesh.ARRAY_TEX_UV] = uvs

		stripped.add_surface_from_arrays(
			source.surface_get_primitive_type(surface), arrays
		)

	return stripped
