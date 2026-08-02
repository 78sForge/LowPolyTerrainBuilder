shader_type spatial;
render_mode world_vertex_coords, blend_mix, cull_back, diffuse_lambert, specular_schlick_ggx,
	depth_draw_never;

// world_vertex_coords and diffuse_lambert are here to MATCH the bundled terrain shaders.
//
// Without the first, this pass ran the position through a different transform chain than the
// surface it is drawn on - model to view here, model to world to view there. The two are the
// same on paper and not in floating point, so the depths came out a hair apart and the overlay
// flickered exactly like z-fighting. Sharing the chain removes the discrepancy at the source.
//
// The second only matters for looks: a painted patch lit by a different diffuse model than the
// ground around it reads as a seam.

// Drawn ON TOP of whatever material the terrain already carries, as a material overlay.
//
// An overlay rather than next_pass on purpose: next_pass would have to be written INTO the
// user's material, and that material is usually a shared .tres. Painting one terrain would
// then change every other object using the same resource, and the change would be saved.
//
// The trade against inlining the include into your own shader: this pass blends the finished,
// lit result instead of the material properties. At full weight the two are identical; in a
// transition they differ slightly, because two lit results are mixed rather than one set of
// properties being lit once. On stylised terrain that difference is not visible.

#include "res://addons/lowpolyterrain/shader/terrain_paint.gdshaderinc"

// How far the overlay is lifted towards the camera, per unit of distance to it.
//
// Matching the transform chain above fixes the bundled shaders, but a base material this
// addon has never seen may still take a third route to the same position. A hair of lead in
// the depth test costs nothing and makes the overlay independent of that. Scaled by distance
// so it stays below a pixel whether the camera is on the ground or far above it.
const float DEPTH_LEAD = 0.0004;

void vertex() {
	// VERTEX is world space here, because of world_vertex_coords.
	vec3 to_camera = CAMERA_POSITION_WORLD - VERTEX;
	VERTEX += normalize(to_camera) * length(to_camera) * DEPTH_LEAD;
}

void fragment() {
	// The weight sum is the coverage. A layer colour's alpha already limited how much weight
	// the brush could deposit, so it must not be applied again here.
	float total = lpt_paint_total(COLOR);

	// Nothing painted here: leave the material underneath completely alone. Discarding rather
	// than writing zero alpha also spares the blend on the vast majority of a typical terrain.
	if (total <= 0.001) {
		discard;
	}

	// Flat per-face normal, matching what the terrain shaders do. Without it the overlay would
	// be lit smoothly while the surface under it is faceted, and the seam would show.
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));

	ALBEDO = lpt_paint_layer_color(COLOR);
	ROUGHNESS = lpt_paint_layer_roughness(COLOR);
	ALPHA = total;
}
