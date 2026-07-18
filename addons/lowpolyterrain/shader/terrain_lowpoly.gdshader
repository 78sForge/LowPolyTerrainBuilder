shader_type spatial;

// Enforces world coordinates for all vertex calculations
render_mode world_vertex_coords;

uniform vec4 base_color : source_color = vec4(0.3, 0.6, 0.2, 1.0);
uniform sampler2D noise_texture : source_color;
uniform float noise_scale = 0.015;
uniform float noise_strength = 0.3;
uniform int color_steps = 3;

// This variable stabley transports the factual world coordinates into the fragment processor
varying vec3 world_position;

void vertex() {
	// Stores the immutable spatial position in world space
	world_position = VERTEX;
}

void fragment() {
	// 1. Enforce crisp low-poly shading by calculating flat face normals via partial derivatives
	vec3 flat_normal = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	NORMAL = flat_normal;
	
	// 2. FIX: Utilize the stable world_position coordinates instead of view-space VERTEX
	// This anchors the noise pattern firmly to the terrain geometry when the camera rotates
	vec2 noise_uv = world_position.xz * noise_scale;
	float noise_value = texture(noise_texture, noise_uv).r;
	
	// 3. Calculate the quantized stepping/posterization effect
	float stepped_noise = floor(noise_value * float(color_steps)) / float(color_steps);
	
	// 4. Compute and apply color attenuation offsets
	float color_offset = (stepped_noise - 0.5) * noise_strength;
	vec3 final_color = base_color.rgb + vec3(color_offset);
	
	ALBEDO = final_color;
	
	ROUGHNESS = 0.8;
	SPECULAR = 0.1;
}
