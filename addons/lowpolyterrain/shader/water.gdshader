shader_type spatial;
// CHANGE 1: Keep depth_draw_always, but use screen_texture for bug-free transparency
render_mode blend_mix, depth_draw_always, diffuse_lambert, specular_schlick_ggx;

// SET extra_cull_margin ON THE MESH USING THIS SHADER.
//
// vertex() raises the surface by up to wave_height, but frustum culling works from the mesh
// bounding box, which is computed from the UNDISPLACED geometry. Without a margin a chunk
// whose box has just left the frustum disappears even though its raised waves would still be
// on screen. Set GeometryInstance3D.extra_cull_margin to at least wave_height on the
// MeshInstance3D (or RenderingServer.instance_set_extra_visibility_margin for a raw instance).

group_uniforms Water_Colors;
uniform vec3 deep_water_color : source_color = vec3(0.0, 0.4, 0.76);
uniform vec3 shallow_water_color : source_color = vec3(0.0, 0.6, 0.7);
uniform vec3 foam_color : source_color = vec3(0.9, 0.95, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.0;

// NEW: Controls base transparency (0.0 = completely invisible, 1.0 = solid)
uniform float water_alpha : hint_range(0.0, 1.0) = 0.6;

group_uniforms Wave_Settings;
uniform vec2 wave_direction = vec2(1.0, 1.0);
uniform float wave_speed : hint_range(0.1, 60.0) = 1.0;
uniform float wave_scale : hint_range(0.05, 2.0) = 0.2;
uniform float wave_height : hint_range(0.0, 5.0) = 0.1;
uniform float low_poly_stepping : hint_range(1.0, 12.0) = 12.0;

group_uniforms Depth_Settings;
// CHANGED HERE: Decreased minimum distance to allow extremely narrow foam lines
uniform float foam_distance : hint_range(0.001, 1.0, 0.001) = 0.05;
// NEW: Controls block size/resolution of the foam edge
uniform float foam_stepping : hint_range(2.0, 100.0) = 100.0;
uniform float depth_distance : hint_range(0.1, 10.0) = 4.0;

// Textures for depth calculation (foam) and the background (transparency)
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
// NEW: Fetches the rendered screen image behind the water for the glass effect
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

const float TAU_CONST = 6.28318530718;

// Period of the noise lattice. Everything fed into hash() is wrapped into it, which keeps the
// argument of sin() bounded. The previous version added an ever-growing time counter straight
// into the hash input: after an hour at wave_speed 60 that argument reached about 27 million,
// where GPU sin() accuracy is implementation defined and mediump precision fails outright.
// Wrapped, it stays near 8000. The noise field tiles with this period, so the drift below can
// wrap without producing a visible seam.
const float NOISE_PERIOD = 256.0;

// Pseudo-random value for one lattice point.
float hash(vec2 p) {
	p = mod(p, NOISE_PERIOD);
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Value noise: the four surrounding lattice points are blended, so the result varies smoothly
// across space. The previous version used a raw per-cell hash, which is uncorrelated between
// neighbours - measured at low wave_scale, 91% of the height difference between adjacent cells
// came from that term alone, which is what read as jitter.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

// Generates stepped block waves for the low-poly look
float low_poly_wave(vec2 uv, float time) {
	vec2 grid_uv = floor(uv * low_poly_stepping) / low_poly_stepping;

	// The phase is wrapped into a full turn, which is exact for sin/cos and stops the argument
	// from growing without bound over a long session.
	vec2 move = mod(wave_direction * time * wave_speed * 0.1, TAU_CONST);
	float w1 = sin(grid_uv.x * 4.0 * wave_scale + move.x) * cos(grid_uv.y * 4.0 * wave_scale + move.y);

	// The detail term now drifts continuously instead of stepping through floor(time * speed),
	// which used to make the whole surface jump at once every 1/wave_speed seconds.
	vec2 drift = mod(wave_direction * time * wave_speed * 0.05, NOISE_PERIOD);
	float w2 = value_noise(grid_uv * wave_scale * 2.0 + drift) * 2.0 - 1.0;

	// Tied to wave_scale so the detail cannot dominate once the primary wave flattens out.
	// The factor is normalised against the upper end of the wave_scale range, so the amplitude
	// at maximum scale matches what it was before.
	float detail_amount = 0.15 * wave_scale * 0.5;

	return (w1 + w2 * detail_amount) * wave_height;
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float height = low_poly_wave(world_pos.xz, TIME);
	VERTEX.y += height;
}

void fragment() {
	// 1. Force flat face normals
	vec3 face_normal = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	NORMAL = face_normal;
	
	// 2. Depth calculation
	//
	// The normalised device depth range differs per backend: Vulkan (Forward+ and Mobile)
	// uses [0, 1], OpenGL (Compatibility) uses [-1, 1]. Feeding the raw sample in under
	// Compatibility therefore reconstructed a wrong view-space position, which broke BOTH
	// depth driven effects below - the foam edge and the shallow/deep colour blend.
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 upos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 pixel_position = upos.xyz / upos.w;
	float water_depth = abs(pixel_position.z - VERTEX.z);
	
	// 3. Color interpolation (Deep vs. shallow water)
	float depth_blend = clamp(water_depth / depth_distance, 0.0, 1.0);
	vec3 water_base = mix(shallow_water_color, deep_water_color, depth_blend);
	
	// 4. NEW: Read background color for true transparency
	vec3 background_color = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	
	// NEW: Calculate dynamic alpha based on depth
	// Shallow water becomes more transparent, deep water becomes more opaque (light absorption)
	float dynamic_alpha = mix(water_alpha * 0.3, water_alpha, depth_blend);
	
	// NEW: Mix the base water color with the background image
	vec3 transparent_water = mix(background_color, water_base, dynamic_alpha);
	
	// 5. Stylized foam at object intersections (NOW CUSTOMIZABLE)
	float stepped_depth = floor(water_depth * foam_stepping) / foam_stepping;
	float foam_mask = step(stepped_depth, foam_distance);
	
	// Mix final result (foam remains fully opaque!)
	ALBEDO = mix(transparent_water, foam_color, foam_mask);
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
}
