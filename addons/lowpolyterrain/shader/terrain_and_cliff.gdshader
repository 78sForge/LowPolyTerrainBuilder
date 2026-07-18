shader_type spatial;

/*
================================================================================
  LOW-POLY SLOPE-AWARE DUAL-SURFACE SHADER (WITH TRIPLANAR CLIFF PROJECTION)
================================================================================
  Architectural Overview:
  This spatial shader procedurally splits the low-poly terrain into two distinct
  surface profiles (flat plains vs. cracked cliffs) based on geometric incline.
  By calculating slopes in world space, it achieves 100% camera independence.

  Key Pipelines:
  1. Flat Pass:  Utilizes a 2D texture layer with quantized color posterization
                 (color_steps) to achieve a stylized low-poly gradient layout.
  2. Cliff Pass: Generates a fully procedural 3D Voronoi edge-network to render
                 organic stone cracks, dynamic highlights, and depth gradients.
                 Enhanced via Triplanar Projection to eliminate vertical stretching.
  3. Blending:   Uses a directional dot-product threshold. Setting softness to 
                 0.0 forces hard face snaps perfect for flat-shaded aesthetics.
================================================================================
*/

// Enforces world coordinates for all vertex calculations (Required for the terrain plugin)
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
uniform float damage_depth : hint_range(0.0, 10.0) = 6.0;    
uniform float shadow_intensity : hint_range(0.0, 1.0) = 0.8; 
uniform vec3 crack_stretch = vec3(1.0, 0.05, 1.0); 
uniform float crack_distortion : hint_range(0.0, 40.0) = 4.0;
// Sharpness of the blend between the three projection axes (Higher = sharper transitions)
uniform float triplanar_sharpness : hint_range(1.0, 20.0) = 4.0;

group_uniforms Slope_Settings;
// 1.0 = completely flat, 0.0 = vertical wall. 0.7 is roughly 45 degrees.
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.7;
// Controls transition sharpness (0.0 = hard low-poly edge snap)
uniform float slope_blend_softness : hint_range(0.0, 0.5) = 0.35;

// Transport stable world coordinates into the fragment processor
varying vec3 world_position;

// Pseudo-random noise function for the voronoi crack generation
vec3 random3(vec3 c) {
	float j = 4096.0 * sin(dot(c, vec3(17.0, 59.4, 15.0)));
	vec3 r;
	r.z = fract(512.0 * j); j *= .125;
	r.x = fract(512.0 * j); j *= .125;
	r.y = fract(512.0 * j); return r - 0.5;
}

// 3D Voronoi cellular edges calculation (F2 - F1)
float voronoi_edges(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	float d1 = 8.0; float d2 = 8.0;
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
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

// Helper function to calculate warped voronoi coordinates for a given projection plane
float get_triplanar_voronoi(vec3 p) {
	vec3 crack_warp = vec3(voronoi_edges(p * 0.5) * crack_distortion);
	vec3 crack_coords = ((p + crack_warp) * damage_scale) * crack_stretch;
	return voronoi_edges(crack_coords);
}

void vertex() {
	// VERTEX returns world coordinates directly because world_vertex_coords is enabled
	world_position = VERTEX;
}

void fragment() {
	// 1. Enforce crisp low-poly shading by calculating flat face normals via partial derivatives
	// NOTE: Because of Godot's pipeline, VERTEX in fragment() is in View Space.
	vec3 flat_normal_view = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	
	// Transform the normal from View Space to World Space to isolate it from camera movement
	vec3 flat_normal_world = mat3(INV_VIEW_MATRIX) * flat_normal_view;
	
	// Use the View Space normal for the engine's lighting pipeline
	NORMAL = flat_normal_view;
	
	// 2. Slope evaluation using the stable World Space normal
	float slope_factor = dot(flat_normal_world, vec3(0.0, 1.0, 0.0));
	float cliff_weight = smoothstep(slope_threshold + slope_blend_softness, slope_threshold - slope_blend_softness, slope_factor);
	
	// 3. FLAT TERRAIN: Color and posterized noise calculation
	vec2 noise_uv = world_position.xz * noise_scale;
	float noise_value = texture(noise_texture, noise_uv).r;
	float stepped_noise = floor(noise_value * float(color_steps)) / float(color_steps);
	float color_offset = (stepped_noise - 0.5) * noise_strength;
	vec3 flat_albedo = base_color.rgb + vec3(color_offset);
	
	// 4. CLIFF TERRAIN: Procedural Voronoi cracks with Triplanar Projection
	vec3 noise_coords = world_position; 
	float delta = 0.005;
	
	// Calculate triplanar blending weights from the stable world space normal
	vec3 triplanar_weights = pow(abs(flat_normal_world), vec3(triplanar_sharpness));
	triplanar_weights /= (triplanar_weights.x + triplanar_weights.y + triplanar_weights.z);
	
	// Sample procedural voronoi fields across three orthogonal axes to prevent stretching
	float voronoi_x = get_triplanar_voronoi(noise_coords.zyx); // Side view (YZ plane)
	float voronoi_y = get_triplanar_voronoi(noise_coords.xzx); // Top view (XZ plane)
	float voronoi_z = get_triplanar_voronoi(noise_coords.xyz); // Front view (XY plane)
	
	// Blend the three axes together using the triplanar weight matrix
	float noise_center = voronoi_x * triplanar_weights.x + voronoi_y * triplanar_weights.y + voronoi_z * triplanar_weights.z;
	
	// Sample offset passes for normal gradient depth generation
	float noise_x_offset = get_triplanar_voronoi(noise_coords.zyx + vec3(delta, 0.0, 0.0) * damage_scale * crack_stretch) * triplanar_weights.x +
	                       get_triplanar_voronoi(noise_coords.xzx + vec3(delta, 0.0, 0.0) * damage_scale * crack_stretch) * triplanar_weights.y +
	                       get_triplanar_voronoi(noise_coords.xyz + vec3(delta, 0.0, 0.0) * damage_scale * crack_stretch) * triplanar_weights.z;
	
	float noise_y_offset = get_triplanar_voronoi(noise_coords.zyx + vec3(0.0, delta, 0.0) * damage_scale * crack_stretch) * triplanar_weights.x +
	                       get_triplanar_voronoi(noise_coords.xzx + vec3(0.0, delta, 0.0) * damage_scale * crack_stretch) * triplanar_weights.y +
	                       get_triplanar_voronoi(noise_coords.xyz + vec3(0.0, delta, 0.0) * damage_scale * crack_stretch) * triplanar_weights.z;
	
	float noise_z_offset = get_triplanar_voronoi(noise_coords.zyx + vec3(0.0, 0.0, delta) * damage_scale * crack_stretch) * triplanar_weights.x +
	                       get_triplanar_voronoi(noise_coords.xzx + vec3(0.0, 0.0, delta) * damage_scale * crack_stretch) * triplanar_weights.y +
	                       get_triplanar_voronoi(noise_coords.xyz + vec3(0.0, 0.0, delta) * damage_scale * crack_stretch) * triplanar_weights.z;
	
	// Apply edge filtering and masking
	float pixel_filter = fwidth(noise_center);
	float edge_width = max(pixel_filter, 0.004); 
	
	float crack_mask = smoothstep(damage_amount, damage_amount + edge_width, noise_center);
	float edge_highlight_mask = smoothstep(damage_amount - 0.015, damage_amount, noise_center) * (1.0 - crack_mask);
	
	vec3 internal_shadow_color = damage_color * (1.0 - shadow_intensity);
	vec3 final_cliff_base = clamp(cliff_base_color + instance_color_offset, vec3(0.0), vec3(1.0));
	
	vec3 cliff_albedo = mix(final_cliff_base, internal_shadow_color, crack_mask);
	cliff_albedo += (vec3(0.12) * edge_highlight_mask);
	
	// Calculate crack normal vectors (depth gradients)
	float grad_x = (noise_x_offset - noise_center) / delta;
	float grad_y = (noise_y_offset - noise_center) / delta;
	float grad_z = (noise_z_offset - noise_center) / delta;
	vec3 cliff_gradient = vec3(grad_x, grad_y, grad_z);
	
	// Transform directly from World to View space since world_vertex_coords is active
	vec3 view_gradient = mat3(VIEW_MATRIX) * cliff_gradient;
	vec3 deep_normal = normalize(flat_normal_view + view_gradient * damage_depth);
	vec3 cliff_normal = mix(flat_normal_view, deep_normal, crack_mask * 0.98);
	
	// 5. FINAL BLENDING: Mix flat and cliff surfaces based on the slope weight matrix
	ALBEDO = mix(flat_albedo, cliff_albedo, cliff_weight);
	NORMAL = mix(flat_normal_view, cliff_normal, cliff_weight);
	ROUGHNESS = mix(0.8, cliff_roughness, cliff_weight);
	SPECULAR = 0.1;
}
