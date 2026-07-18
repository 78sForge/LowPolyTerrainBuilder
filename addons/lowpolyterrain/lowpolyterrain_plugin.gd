@tool
extends EditorPlugin

## EditorPlugin script that bridges the Godot 3D viewports with the low poly terrain tools.
## Handles a persistent, semi-transparent 3D brush gizmo and processes painting signals.

var active_manager: LowPolyTerrainManager = null
var is_drawing: bool = false

# Transient 3D mesh instance used as a visual preview tool inside the editor viewport
var brush_gizmo: MeshInstance3D = null

func _get_plugin_name() -> String:
	return "Low Poly Chunk Terrain"

func _handles(object: Object) -> bool:
	return object is LowPolyTerrainManager

func _edit(object: Object) -> void:
	# Disconnect old signal handler to prevent memory leaks or dual bindings
	if active_manager and active_manager.is_connected("signal_brush_settings_changed", _on_signal_brush_settings_changed):
		active_manager.disconnect("signal_brush_settings_changed", _on_signal_brush_settings_changed)

	if object is LowPolyTerrainManager:
		active_manager = object
		active_manager.set_meta("_edit_lock_", true)
		active_manager.rebuild_chunks_structure()
		
		# Connect signal to dynamic brush scaling updates
		if not active_manager.is_connected("signal_brush_settings_changed", _on_signal_brush_settings_changed):
			active_manager.connect("signal_brush_settings_changed", _on_signal_brush_settings_changed)
			
		_create_3d_brush_gizmo()
	else:
		if active_manager:
			active_manager.set_meta("_edit_lock_", false)
		active_manager = null
		is_drawing = false
		_destroy_3d_brush_gizmo()

func _make_visible(visible: bool) -> void:
	if not visible:
		if active_manager:
			active_manager.set_meta("_edit_lock_", false)
		active_manager = null
		is_drawing = false
		_destroy_3d_brush_gizmo()

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> EditorPlugin.AfterGUIInput:
	if not active_manager:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
		
	if event is InputEventMouseMotion:
		# Track and update the 3D gizmo position exactly where the cursor ray hits the terrain
		_update_gizmo_position(viewport_camera, event.position)
		if is_drawing:
			_process_paint_stroke(viewport_camera, event.position, event.shift_pressed)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
			
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_drawing = event.pressed
			if is_drawing:
				_process_paint_stroke(viewport_camera, event.position, event.shift_pressed)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
				
	return EditorPlugin.AFTER_GUI_INPUT_PASS

## Spawns a semi-transparent 3D cylinder disk acting as the brush indicator inside the scene tree.
func _create_3d_brush_gizmo() -> void:
	if brush_gizmo or not active_manager: return
	
	brush_gizmo = MeshInstance3D.new()
	brush_gizmo.name = "DEBUG_BrushGizmo_Transient"
	
	# Build a thin, flat cylinder mesh representing a perfect 3D circle overlay
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 0.02
	cyl.radial_segments = 32
	brush_gizmo.mesh = cyl
	
	# Configure an emissive, depth-testing-disabled material for full editor visibility
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED 
	mat.albedo_color = Color(0.2, 0.6, 1.0, 0.35)
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true 
	brush_gizmo.material_override = mat
	
	active_manager.add_child(brush_gizmo)
	_update_gizmo_scale()

func _destroy_3d_brush_gizmo() -> void:
	if brush_gizmo:
		if brush_gizmo.get_parent():
			brush_gizmo.get_parent().remove_child(brush_gizmo)
		brush_gizmo.free()
		brush_gizmo = null

## Instantly recalibrates the gizmo's world scale, bypassing Godot inspector sync latency.
func _update_gizmo_scale() -> void:
	if not brush_gizmo or not active_manager: return
	# Calculate the factual world-space radius based on current grid properties
	var r = active_manager.cell_size * float(active_manager.brush_radius)
	# Scale across horizontal planes while keeping Y flat
	brush_gizmo.scale = Vector3(r, 1.0, r)

## Casts a mouse ray against chunk dimensions to lock the gizmo onto the mesh coordinates.
func _update_gizmo_position(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not brush_gizmo or not active_manager: return
	
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_dir = camera.project_ray_normal(mouse_pos)
	
	var closest_hit: float = INF
	var world_hit_point: Vector3 = Vector3.ZERO
	var found_hit := false
	
	for chunk in active_manager.chunks_dict.values():
		if not chunk or not chunk.is_inside_tree() or not chunk.mesh: continue
		
		var inv_transform = chunk.global_transform.inverse()
		var local_origin = inv_transform * ray_origin
		var local_ray_end = local_origin + (inv_transform.basis * ray_dir) * 5000.0
		
		# High-performance AABB segment pre-test to reject distant chunks immediately
		if not chunk.mesh.get_aabb().intersects_segment(local_origin, local_ray_end):
			continue
			
		var faces = chunk.mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var intersect = Geometry3D.ray_intersects_triangle(local_origin, inv_transform.basis * ray_dir, faces[i], faces[i+1], faces[i+2])
			if intersect != null:
				var dist = local_origin.distance_to(intersect)
				if dist < closest_hit:
					closest_hit = dist
					world_hit_point = chunk.global_transform * intersect
					found_hit = true
					
	if found_hit:
		brush_gizmo.visible = true
		brush_gizmo.global_position = world_hit_point
	else:
		brush_gizmo.visible = false

func _process_paint_stroke(camera: Camera3D, mouse_pos: Vector2, is_shift: bool) -> void:
	if not active_manager: return
	if brush_gizmo and brush_gizmo.visible:
		active_manager.interact_at_world_position(brush_gizmo.global_position, is_shift)

## Target handler fired automatically when custom inspector signals require a gizmo resize.
func _on_signal_brush_settings_changed() -> void:
	print("_on_signal_brush_settings_changed -> Updating 3D gizmo scale!")
	_update_gizmo_scale()
