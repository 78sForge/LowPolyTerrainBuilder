// Shared blending for the terrain vertex painter.
//
// The Paint brush stores four layer weights in the mesh's vertex colour: R, G, B and A are how
// much of layer 1 to 4 sits on that point. Whatever the four leave unused belongs to the base
// material, so an unpainted terrain - all weights zero - shows the base alone.
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
//          ...
//          void fragment() {
//              // ... your own shading ...
//              ALBEDO    = lpt_paint_albedo(ALBEDO, COLOR);
//              ROUGHNESS = lpt_paint_roughness(ROUGHNESS, COLOR);
//          }

// Grouped so each layer's colour and roughness sit together in the inspector. Listing all
// four colours and then all four roughness values put the two halves of one layer far apart.

group_uniforms Layer_1;
uniform vec4 paint_layer_1_color : source_color = vec4(0.76, 0.70, 0.50, 1.0);
uniform float paint_layer_1_roughness : hint_range(0.0, 1.0) = 0.85;
group_uniforms;

group_uniforms Layer_2;
uniform vec4 paint_layer_2_color : source_color = vec4(0.45, 0.45, 0.47, 1.0);
uniform float paint_layer_2_roughness : hint_range(0.0, 1.0) = 0.70;
group_uniforms;

group_uniforms Layer_3;
uniform vec4 paint_layer_3_color : source_color = vec4(0.95, 0.96, 1.00, 1.0);
uniform float paint_layer_3_roughness : hint_range(0.0, 1.0) = 0.25;
group_uniforms;

group_uniforms Layer_4;
uniform vec4 paint_layer_4_color : source_color = vec4(0.35, 0.26, 0.18, 1.0);
uniform float paint_layer_4_roughness : hint_range(0.0, 1.0) = 0.90;
group_uniforms;


// How much of the surface the four layers cover between them. The remainder is the base.
// Clamped because a weight is a share, and shares do not exceed the whole.
float lpt_paint_total(vec4 weights) {
	return clamp(weights.r + weights.g + weights.b + weights.a, 0.0, 1.0);
}


// The layers' own colour, before it is blended onto anything. Divided by the total so the
// layers keep their proportions to each other rather than darkening where they overlap.
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


// NOTE ON THE ALPHA of a layer colour: it is a BRUSH setting, not a shading one.
//
// The four weights share one surface between them, so a layer at full weight pushes the others
// out and its transparency could then only reveal the base material - never the paint that was
// there before. The alpha therefore caps how much of the surface the brush lets that layer
// claim, which leaves room for what was already there. By the time the weights reach this
// shader the transparency is already expressed in them, and applying it a second time here
// would count it twice.


// Blends the painted layers over a base colour. For the inline route.
vec3 lpt_paint_albedo(vec3 base, vec4 weights) {
	return mix(base, lpt_paint_layer_color(weights), lpt_paint_total(weights));
}


// Blends the painted layers' roughness over a base roughness. For the inline route.
float lpt_paint_roughness(float base, vec4 weights) {
	return mix(base, lpt_paint_layer_roughness(weights), lpt_paint_total(weights));
}
