shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(0.4, 0.7, 0.4, 1.0);
uniform vec4 wire_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// hint_range creates a slider in the Inspector
uniform float wire_intensity : hint_range(0.0, 10.0) = 2.0; 
uniform float wire_width : hint_range(0.0, 0.5) = 0.015;
uniform float wire_smoothness : hint_range(0.0, 0.1) = 0.05;

varying vec3 barycentric;

void vertex() {
	// Since Delaunay meshes are often split in the index array, we use 
	// a mathematical approximation based on the vertex ID.
	int id = VERTEX_ID % 3;
	if (id == 0) barycentric = vec3(1.0, 0.0, 0.0);
	else if (id == 1) barycentric = vec3(0.0, 1.0, 0.0);
	else barycentric = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	// Calculate the minimum distance to one of the three edges of the triangle
	float min_bary = min(barycentric.x, min(barycentric.y, barycentric.z));
	
	// Create a sharp edge with adjustable smoothing (anti-aliasing)
	float edge = smoothstep(wire_width, wire_width - wire_smoothness, min_bary);
	
	// Smoothly blend the terrain color with the edge color using the calculated factor
	vec3 final_color = mix(albedo.rgb, wire_color.rgb, edge);
	
	ALBEDO = final_color;
	// ONLY the wire color emits light: EMISSION is 0 on faces and scales with wire_intensity on edges
	EMISSION = wire_color.rgb * edge * wire_intensity;
	ROUGHNESS = 0.8;
}
