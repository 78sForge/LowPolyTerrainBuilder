// Shared blending for the terrain vertex painter.
//
// The Paint brush stores four layer weights in the mesh's vertex colour: R, G, B and A are how
// much of layer 1 to 4 sits on that point. Whatever the four leave unused belongs to the base
// material, so an unpainted terrain - all weights zero - shows the base alone.
//
// Every layer is a flat colour and a roughness by default, and may additionally carry a DETAIL
// TEXTURE and a DETAIL NORMAL MAP. Those are projected onto the world from above and tiled, so
// they need no UV coordinates and line up across chunk borders on their own.
//
// The texture is composited onto the layer colour through its ALPHA: the alpha says where the
// detail is, the RGB says what it looks like there, and the colour is what shows everywhere
// else. Both kinds of image therefore work. A decal-style one - scattered stones on empty
// space, the very asset a Decal node would project - lands its motif on a coloured ground. A
// fully opaque tiling photo covers everything, and the detail amount fades it in over the
// colour instead.
//
// Both detail slots are OFF until their strength is raised above zero, and a layer that leaves
// them there costs exactly what it cost before they existed. The switch is a uniform, so every
// pixel takes the same branch and the skip is genuinely free rather than nearly free.
//
// Two ways to use this file:
//
//   1. Nothing to do. The manager hangs terrain_paint_overlay.gdshader on the chunks as a
//      material overlay, which includes this file and draws the layers over your material.
//
//   2. Inline it, for a single draw call and blending of the material PROPERTIES rather than of
//      the lit results. Add to your own terrain shader:
//
//          #include "res://addons/lowpolyterrain/shader/terrain_paint.gdshaderinc"
//
//          // World position, because the detail textures are projected from above. Under
//          // render_mode world_vertex_coords this is simply `world_position = VERTEX;`.
//          varying vec3 world_position;
//
//          void fragment() {
//              // ... your own shading ...
//              ALBEDO    = lpt_paint_albedo_at(ALBEDO, COLOR, world_position);
//              ROUGHNESS = lpt_paint_roughness(ROUGHNESS, COLOR);
//
//              // Only if you want the detail normal maps. NORMAL is view space in a fragment
//              // shader and the projection is defined in world space, hence the two hops.
//              if (lpt_paint_uses_normal_detail()) {
//                  vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
//                  n = lpt_paint_normal_at(n, COLOR, world_position);
//                  NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
//              }
//          }
//
//      The older lpt_paint_albedo() and lpt_paint_layer_color() are still here and unchanged,
//      so an existing inline shader keeps compiling. They predate the detail textures and
//      ignore them - the `_at` variants are the ones that read them.

// Grouped so each layer's colour and roughness sit together in the inspector. Listing all
// four colours and then all four roughness values put the two halves of one layer far apart.

group_uniforms Layer_1;
uniform vec4 paint_layer_1_color : source_color = vec4(0.76, 0.70, 0.50, 1.0);
uniform float paint_layer_1_roughness : hint_range(0.0, 1.0) = 0.85;
uniform sampler2D paint_layer_1_detail : source_color, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_1_detail_amount : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D paint_layer_1_detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_1_detail_normal_strength : hint_range(0.0, 4.0) = 0.0;
uniform float paint_layer_1_detail_size : hint_range(0.05, 64.0) = 2.0;
group_uniforms;

group_uniforms Layer_2;
uniform vec4 paint_layer_2_color : source_color = vec4(0.45, 0.45, 0.47, 1.0);
uniform float paint_layer_2_roughness : hint_range(0.0, 1.0) = 0.70;
uniform sampler2D paint_layer_2_detail : source_color, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_2_detail_amount : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D paint_layer_2_detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_2_detail_normal_strength : hint_range(0.0, 4.0) = 0.0;
uniform float paint_layer_2_detail_size : hint_range(0.05, 64.0) = 2.0;
group_uniforms;

group_uniforms Layer_3;
uniform vec4 paint_layer_3_color : source_color = vec4(0.95, 0.96, 1.00, 1.0);
uniform float paint_layer_3_roughness : hint_range(0.0, 1.0) = 0.25;
uniform sampler2D paint_layer_3_detail : source_color, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_3_detail_amount : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D paint_layer_3_detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_3_detail_normal_strength : hint_range(0.0, 4.0) = 0.0;
uniform float paint_layer_3_detail_size : hint_range(0.05, 64.0) = 2.0;
group_uniforms;

group_uniforms Layer_4;
uniform vec4 paint_layer_4_color : source_color = vec4(0.35, 0.26, 0.18, 1.0);
uniform float paint_layer_4_roughness : hint_range(0.0, 1.0) = 0.90;
uniform sampler2D paint_layer_4_detail : source_color, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_4_detail_amount : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D paint_layer_4_detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float paint_layer_4_detail_normal_strength : hint_range(0.0, 4.0) = 0.0;
uniform float paint_layer_4_detail_size : hint_range(0.05, 64.0) = 2.0;
group_uniforms;


// How much of the surface the four layers cover between them. The remainder is the base.
// Clamped because a weight is a share, and shares do not exceed the whole.
float lpt_paint_total(vec4 weights) {
	return clamp(weights.r + weights.g + weights.b + weights.a, 0.0, 1.0);
}


// True while at least one layer wants its detail normal map read. A uniform expression, so the
// caller can wrap the whole world-space detour around NORMAL in it and pay nothing when no
// layer uses one.
bool lpt_paint_uses_normal_detail() {
	return paint_layer_1_detail_normal_strength > 0.0
		|| paint_layer_2_detail_normal_strength > 0.0
		|| paint_layer_3_detail_normal_strength > 0.0
		|| paint_layer_4_detail_normal_strength > 0.0;
}


// ON SAMPLING WITH EXPLICIT GRADIENTS, which the two `_at` functions below do throughout.
//
// A plain texture() picks its mipmap by comparing the coordinate against the neighbouring
// pixels of a 2x2 quad, which only works while all four take the same path through the shader.
// These functions bail out early where nothing is painted, and that test differs from pixel to
// pixel - so right along the edge of a painted area the quad would split and the chosen level
// would be undefined. Deriving the gradients once, up front and before any branch, and handing
// them to textureGrad() keeps the level correct there without sampling for pixels that then
// turn out to need nothing.
//
// The gradient is of the WORLD position, so it is divided by the same tile size as the
// coordinate itself.


// ON THE DETAIL TEXTURE'S ALPHA, which is what decides where the detail is at all.
//
// A detail texture is composited ONTO the layer colour through its own alpha, not multiplied
// with it. Multiplying would mean every pixel of the image tints the ground, and for the kind
// of image this is actually for - scattered stones or leaves over empty space, the same asset a
// decal would use - the empty space is not white, it is TRANSPARENT. Its RGB is whatever the
// importer left there, which with the usual 'Fix Alpha Border' is a bleed of the nearest opaque
// pixel. Multiplied, that smears the motif's colour across the entire layer and drags a green
// ground to grey. Composited, it is simply not drawn.
//
// So the alpha is the shape and the RGB is the look inside it, exactly as the same image
// behaves on a Decal. A fully opaque texture - an ordinary tiling ground photo - still works:
// alpha is 1 everywhere, and the detail amount then fades the whole image in over the colour.


// The layers' own colour, before it is blended onto anything. Divided by the total so the
// layers keep their proportions to each other rather than darkening where they overlap.
vec3 lpt_paint_layer_color_at(vec4 weights, vec3 world_pos) {
	vec2 world_dx = dFdx(world_pos.xz);
	vec2 world_dy = dFdy(world_pos.xz);

	float total = weights.r + weights.g + weights.b + weights.a;
	if (total <= 0.0) {
		return vec3(0.0);
	}

	vec3 c1 = paint_layer_1_color.rgb;
	if (paint_layer_1_detail_amount > 0.0) {
		float size = max(paint_layer_1_detail_size, 0.001);
		vec4 detail = textureGrad(
			paint_layer_1_detail, world_pos.xz / size, world_dx / size, world_dy / size
		);
		c1 = mix(c1, detail.rgb, detail.a * paint_layer_1_detail_amount);
	}

	vec3 c2 = paint_layer_2_color.rgb;
	if (paint_layer_2_detail_amount > 0.0) {
		float size = max(paint_layer_2_detail_size, 0.001);
		vec4 detail = textureGrad(
			paint_layer_2_detail, world_pos.xz / size, world_dx / size, world_dy / size
		);
		c2 = mix(c2, detail.rgb, detail.a * paint_layer_2_detail_amount);
	}

	vec3 c3 = paint_layer_3_color.rgb;
	if (paint_layer_3_detail_amount > 0.0) {
		float size = max(paint_layer_3_detail_size, 0.001);
		vec4 detail = textureGrad(
			paint_layer_3_detail, world_pos.xz / size, world_dx / size, world_dy / size
		);
		c3 = mix(c3, detail.rgb, detail.a * paint_layer_3_detail_amount);
	}

	vec3 c4 = paint_layer_4_color.rgb;
	if (paint_layer_4_detail_amount > 0.0) {
		float size = max(paint_layer_4_detail_size, 0.001);
		vec4 detail = textureGrad(
			paint_layer_4_detail, world_pos.xz / size, world_dx / size, world_dy / size
		);
		c4 = mix(c4, detail.rgb, detail.a * paint_layer_4_detail_amount);
	}

	vec3 mixed = c1 * weights.r + c2 * weights.g + c3 * weights.b + c4 * weights.a;
	return mixed / total;
}


// The layers' own colour without any detail texture. Kept because it is what an inline shader
// written before the textures existed calls, and its signature may not change under it.
vec3 lpt_paint_layer_color(vec4 weights) {
	float total = weights.r + weights.g + weights.b + weights.a;
	if (total <= 0.0) {
		return vec3(0.0);
	}
	vec3 mixed = paint_layer_1_color.rgb * weights.r
		+ paint_layer_2_color.rgb * weights.g
		+ paint_layer_3_color.rgb * weights.b
		+ paint_layer_4_color.rgb * weights.a;
	return mixed / total;
}


// The layers' own roughness, mixed the same way. Every further material property - emission,
// metallic, specular - would be one more function of exactly this shape.
float lpt_paint_layer_roughness(vec4 weights) {
	float total = weights.r + weights.g + weights.b + weights.a;
	if (total <= 0.0) {
		return 0.0;
	}
	float mixed = paint_layer_1_roughness * weights.r
		+ paint_layer_2_roughness * weights.g
		+ paint_layer_3_roughness * weights.b
		+ paint_layer_4_roughness * weights.a;
	return mixed / total;
}


// Bends a WORLD SPACE surface normal by the layers' detail normal maps. Returns the normal
// untouched where nothing is painted or no layer carries one.
//
// Only the maps' X and Y are read, because those two ARE the slope the map encodes. Taking them
// alone is what lets this work without per-vertex tangents - the usual way to apply a normal
// map needs to know which direction is "right" on the surface, and a decimated low-poly terrain
// with no UV coordinates has nothing to answer that with. The projection is from above, so the
// two components are simply a tilt in world X and Z.
//
// That tilt is pushed into the surface's own plane before it is applied. Without it a steep
// face would have its normal bent INTO the ground rather than along it, and lighting would come
// apart exactly where the top-down projection is already at its weakest.
//
// MASKED BY THE DETAIL TEXTURE'S ALPHA, not the normal map's own. A normal map imported as one
// is compressed to two channels and has no alpha left to mask with, and the empty space around
// a motif does not survive as flat either - the importer bleeds the nearest opaque pixel into
// it, so an unmasked map would tilt the light across the whole layer instead of only where the
// stones are. The alpha that says where the detail IS lives on the colour texture, which is
// where this reads it from. With no colour texture assigned that alpha is 1 and nothing is
// masked, which is the right answer for a normal map used on its own.
vec3 lpt_paint_normal_at(vec3 base_normal, vec4 weights, vec3 world_pos) {
	vec2 world_dx = dFdx(world_pos.xz);
	vec2 world_dy = dFdy(world_pos.xz);

	float total = weights.r + weights.g + weights.b + weights.a;
	if (total <= 0.0) {
		return base_normal;
	}

	vec2 tilt = vec2(0.0);

	if (paint_layer_1_detail_normal_strength > 0.0) {
		float size = max(paint_layer_1_detail_size, 0.001);
		vec2 uv = world_pos.xz / size;
		vec2 duv_dx = world_dx / size;
		vec2 duv_dy = world_dy / size;
		vec2 encoded = textureGrad(paint_layer_1_detail_normal, uv, duv_dx, duv_dy).xy * 2.0 - 1.0;
		float cover = textureGrad(paint_layer_1_detail, uv, duv_dx, duv_dy).a;
		tilt += encoded * cover * paint_layer_1_detail_normal_strength * weights.r;
	}

	if (paint_layer_2_detail_normal_strength > 0.0) {
		float size = max(paint_layer_2_detail_size, 0.001);
		vec2 uv = world_pos.xz / size;
		vec2 duv_dx = world_dx / size;
		vec2 duv_dy = world_dy / size;
		vec2 encoded = textureGrad(paint_layer_2_detail_normal, uv, duv_dx, duv_dy).xy * 2.0 - 1.0;
		float cover = textureGrad(paint_layer_2_detail, uv, duv_dx, duv_dy).a;
		tilt += encoded * cover * paint_layer_2_detail_normal_strength * weights.g;
	}

	if (paint_layer_3_detail_normal_strength > 0.0) {
		float size = max(paint_layer_3_detail_size, 0.001);
		vec2 uv = world_pos.xz / size;
		vec2 duv_dx = world_dx / size;
		vec2 duv_dy = world_dy / size;
		vec2 encoded = textureGrad(paint_layer_3_detail_normal, uv, duv_dx, duv_dy).xy * 2.0 - 1.0;
		float cover = textureGrad(paint_layer_3_detail, uv, duv_dx, duv_dy).a;
		tilt += encoded * cover * paint_layer_3_detail_normal_strength * weights.b;
	}

	if (paint_layer_4_detail_normal_strength > 0.0) {
		float size = max(paint_layer_4_detail_size, 0.001);
		vec2 uv = world_pos.xz / size;
		vec2 duv_dx = world_dx / size;
		vec2 duv_dy = world_dy / size;
		vec2 encoded = textureGrad(paint_layer_4_detail_normal, uv, duv_dx, duv_dy).xy * 2.0 - 1.0;
		float cover = textureGrad(paint_layer_4_detail, uv, duv_dx, duv_dy).a;
		tilt += encoded * cover * paint_layer_4_detail_normal_strength * weights.a;
	}

	// Weighted like every other property, and faded out with the coverage so a layer at half
	// weight bumps half as much instead of arriving at full force.
	tilt = tilt / total * lpt_paint_total(weights);

	vec3 offset = vec3(tilt.x, 0.0, tilt.y);
	offset -= base_normal * dot(base_normal, offset);
	return normalize(base_normal + offset);
}


// NOTE ON THE ALPHA of a layer colour: it is a BRUSH setting, not a shading one.
//
// The four weights share one surface between them, so a layer at full weight pushes the others
// out and its transparency could then only reveal the base material - never the paint that was
// there before. The alpha therefore caps how much of the surface the brush lets that layer
// claim, which leaves room for what was already there. By the time the weights reach this
// shader the transparency is already expressed in them, and applying it a second time here
// would count it twice.


// Blends the painted layers over a base colour, detail textures included. For the inline route.
vec3 lpt_paint_albedo_at(vec3 base, vec4 weights, vec3 world_pos) {
	return mix(base, lpt_paint_layer_color_at(weights, world_pos), lpt_paint_total(weights));
}


// The same without detail textures, for an inline shader written before they existed.
vec3 lpt_paint_albedo(vec3 base, vec4 weights) {
	return mix(base, lpt_paint_layer_color(weights), lpt_paint_total(weights));
}


// Blends the painted layers' roughness over a base roughness. For the inline route.
float lpt_paint_roughness(float base, vec4 weights) {
	return mix(base, lpt_paint_layer_roughness(weights), lpt_paint_total(weights));
}
