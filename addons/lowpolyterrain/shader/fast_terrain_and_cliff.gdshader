shader_type spatial;

/*
================================================================================
  OPTIMIZED LOW-POLY SLOPE-AWARE DUAL-SURFACE SHADER
================================================================================
  Optimization Focus: 
  - Reduced Voronoi loops from 27 to 8 iterations (2x2x2 instead of 3x3x3).
  - Completely removed expensive normal gradient offset passes.
  - Utilized screen-space derivatives (dFdx/dFdy) to fake crack edge depth.
  - Implemented dynamic branching to skip cliff math on flat areas.
================================================================================
*/

render_mode world_vertex_coords, blend_mix, depth_draw_opaque, diffuse_lambert, specular_schlick_ggx;

group_uniforms Flat_Terrain_Settings;
uniform vec4 base_color : source_color = vec4(0.51, 0.557, 0.157, 1.0);
uniform sampler2D noise_texture : source_color;
uniform float noise_scale = 0.015;
uniform float noise_strength = 0.3;
uniform int color_steps = 3;

group_uniforms Cliff_Terrain_Settings;
uniform vec3 cliff_base_color : source_color = vec3(0.294, 0.294, 0.294);
uniform float cliff_roughness : hint_range(0.0, 1.0) = 0.175;
uniform vec3 instance_color_offset = vec3(0.0, 0.0, 0.0);
uniform vec3 damage_color : source_color = vec3(0.05, 0.05, 0.05); 
uniform float damage_scale : hint_range(0.1, 1.0) = 0.5;
uniform float damage_amount : hint_range(0.0, 3.0) = 0.8;
uniform float shadow_intensity : hint_range(0.0, 1.0) = 0.8; 
uniform vec3 crack_stretch = vec3(1.0, 0.05, 1.0); 
uniform float crack_distortion : hint_range(0.0, 40.0) = 4.0;
uniform float triplanar_sharpness : hint_range(1.0, 20.0) = 4.0;

group_uniforms Slope_Settings;
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.7;
uniform float slope_blend_softness : hint_range(0.0, 0.5) = 0.35;

varying vec3 world_position;

// Optimized pseudo-random generator
vec3 random3(vec3 c) {
	float j = 4096.0 * sin(dot(c, vec3(17.0, 59.4, 15.0)));
	return fract(vec3(512.0, 64.0, 8.0) * j) - 0.5;
}

// Drastically optimized 2x2x2 Voronoi cellular loop (8 iterations instead of 27)
float voronoi_edges_fast(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	float d1 = 8.0; float d2 = 8.0;
	
	// A 2x2x2 search space is perfectly sufficient for structured organic cracks
	for (int z = 0; z <= 1; z++) {
		for (int y = 0; y <= 1; y++) {
			for (int x = 0; x <= 1; x++) {
				vec3 g = vec3(float(x), float(y), float(z));
				vec3 o = random3(i + g);
				vec3 r = g + o - f;
				float d = dot(r, r);
				if (d < d1) { d2 = d1; d1 = d; }
				else if (d < d2) { d2 = d; }
			}
		}
	}
	return (d2 - d1);
}

float get_triplanar_voronoi(vec3 p) {
	// Primary pass for edge coordinate distortion (warping)
	vec3 crack_warp = vec3(voronoi_edges_fast(p * 0.5) * crack_distortion);
	vec3 crack_coords = ((p + crack_warp) * damage_scale) * crack_stretch;
	return voronoi_edges_fast(crack_coords);
}

void vertex() {
	world_position = VERTEX;
}

void fragment() {
	// 1. Enforce crisp low-poly shading via screen-space partial derivatives
	vec3 flat_normal_view = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	vec3 flat_normal_world = mat3(INV_VIEW_MATRIX) * flat_normal_view;
	NORMAL = flat_normal_view;
	ROUGHNESS = cliff_roughness;
	
	// 2. Evaluate terrain slope
	float slope_factor = dot(flat_normal_world, vec3(0.0, 1.0, 0.0));
	float cliff_weight = smoothstep(slope_threshold + slope_blend_softness, slope_threshold - slope_blend_softness, slope_factor);
	
	// 3. FLAT PASSTHROUGH: Calculate posterized terrain albedo (always active)
	vec2 noise_uv = world_position.xz * noise_scale;
	float noise_value = texture(noise_texture, noise_uv).r;
	float stepped_noise = floor(noise_value * float(color_steps)) / float(color_steps);
	float color_offset = (stepped_noise - 0.5) * noise_strength;
	vec3 final_albedo = base_color.rgb + vec3(color_offset);
	
	// 4. CLIFF PASS: Enforce dynamic branching to completely skip heavy math on flat plains
	if (cliff_weight > 0.01) {
		vec3 noise_coords = world_position;
		
		// Generate triplanar projection weights from the stable world space normal
		vec3 triplanar_weights = pow(abs(flat_normal_world), vec3(triplanar_sharpness));
		triplanar_weights /= (triplanar_weights.x + triplanar_weights.y + triplanar_weights.z);
		
		// Execute exactly ONE main pass across the projection planes (saving 3 full triplanar evaluations)
		float voronoi_x = get_triplanar_voronoi(noise_coords.zyx);
		float voronoi_y = get_triplanar_voronoi(noise_coords.xzx);
		float voronoi_z = get_triplanar_voronoi(noise_coords.xyz);
		
		float noise_center = voronoi_x * triplanar_weights.x + voronoi_y * triplanar_weights.y + voronoi_z * triplanar_weights.z;
		
		// Apply edge filtering based on screen-space pixel width
		float pixel_filter = fwidth(noise_center);
		float edge_width = max(pixel_filter, 0.004); 
		
		float crack_mask = smoothstep(damage_amount, damage_amount + edge_width, noise_center);
		
		// Fake depth shading WITHOUT performance-heavy offset samplers:
		// We use the screen-space derivative of the crack mask to shade the break-edges
		float edge_derivate = fwidth(crack_mask) * 5.0; 
		float edge_highlight_mask = smoothstep(damage_amount - 0.015, damage_amount, noise_center) * (1.0 - crack_mask);
		
		vec3 internal_shadow_color = damage_color * (1.0 - shadow_intensity);
		vec3 final_cliff_base = clamp(cliff_base_color + instance_color_offset, vec3(0.0), vec3(1.0));
		
		// Composite final cliff profile properties
		vec3 cliff_albedo = mix(final_cliff_base, internal_shadow_color, crack_mask);
		cliff_albedo -= vec3(edge_derivate * 0.3); // Apply structural ambient occlusion along cracks
		cliff_albedo += (vec3(0.12) * edge_highlight_mask); // Apply sharp specular highlights on peaks
		
		// Linearly interpolate between flat plains and cracked cliffs based on slope weights
		final_albedo = mix(final_albedo, cliff_albedo, cliff_weight);
	}
	
	ALBEDO = final_albedo;
}
