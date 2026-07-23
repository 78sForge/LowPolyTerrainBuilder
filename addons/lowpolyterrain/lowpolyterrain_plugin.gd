@tool
extends EditorPlugin

## EditorPlugin script that bridges the Godot 3D viewports with the low poly terrain tools.
## Handles a persistent, semi-transparent 3D brush gizmo and processes painting signals.

var active_manager: LowPolyTerrainManager = null
var is_drawing: bool = false

# Transient 3D mesh instance used as a visual preview tool inside the editor viewport
var brush_gizmo: MeshInstance3D = null

# UI Control elements for the responsive brush tool selection panel
var brush_panel_container: HBoxContainer = null
var button_group: ButtonGroup = null

# List of native editor shortcut resources tied to each specific brush profile
var brush_shortcuts: Dictionary = {}

func _get_plugin_name() -> String:
	return "Low Poly Terrain Builder"


func _enter_tree() -> void:
	# Registriert den neuen Node mit Ihrem Custom-Icon
	add_custom_type(
		"LowPolyTerrainManager", 
		"Node3D", 
		preload("res://addons/lowpolyterrain/LowPolyTerrainManager.gd"), 
		preload("res://addons/lowpolyterrain/icon.svg")
	)
	
	# Initialize and register customizable system shortcuts inside the global editor dictionary
	_initialize_editor_shortcuts()
	
	# Construct the modern horizontal radio button bar layout interface
	_create_brush_ui_panel()


func _exit_tree() -> void:
	remove_custom_type("LowPolyTerrainManager")
	_destroy_brush_ui_panel()


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
		_show_brush_ui_panel(true)
		_sync_ui_buttons_with_manager()
	else:
		if active_manager:
			active_manager.set_meta("_edit_lock_", false)
		active_manager = null
		is_drawing = false
		_destroy_3d_brush_gizmo()
		_show_brush_ui_panel(false)


func _make_visible(visible: bool) -> void:
	if not visible:
		if active_manager:
			active_manager.set_meta("_edit_lock_", false)
		active_manager = null
		is_drawing = false
		_destroy_3d_brush_gizmo()
		_show_brush_ui_panel(false)


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> EditorPlugin.AfterGUIInput:
	if not active_manager:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
		
	# Check for key presses to switch modes instantly via user shortcuts inside the 3D viewport
	if event is InputEventKey and event.pressed and not event.echo:
		for mode in brush_shortcuts.keys():
			var sc: Shortcut = brush_shortcuts[mode]
			if sc.matches_event(event):
				_select_brush_mode(mode)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		
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


## Registers shortcuts cleanly inside the Editor Settings under the plugin's own section.
func _initialize_editor_shortcuts() -> void:
	# Profiles map: [Enum Index, Setting Identity String, Default Keyboard Key String]
	var profiles: Array = [
		[0, "raise_terrain", "Q"],
		[1, "lower_terrain", "W"],
		[2, "flatten_terrain", "E"],
		[3, "smooth_terrain", "R"],
		[4, "activate_chunk", "A"],
		[5, "deactivate_chunk", "S"]
	]
	
	var settings := EditorInterface.get_editor_settings()
	if not settings: return
	
	for item in profiles:
		var mode_idx: int = item[0] as int
		var id_str: String = item[1] as String
		var default_key_str: String = item[2] as String
		
		# Create a standardized, native editor setting path for the input key
		var settings_path: String = "plugins/low_poly_terrain_builder/shortcuts/" + id_str
		
		# Force a complete overwrite of the setting to break Godot's internal type caching
		if settings.has_setting(settings_path):
			var current_val = settings.get_setting(settings_path)
			if typeof(current_val) == TYPE_INT:
				var healed_str: String = OS.get_keycode_string(current_val as Key)
				if healed_str.is_empty():
					healed_str = default_key_str
				settings.set_setting(settings_path, healed_str)
		else:
			settings.set_setting(settings_path, default_key_str)
			
		# Enforce the default fallback state value explicitly as a clear string type
		settings.set_initial_value(settings_path, default_key_str, false)
		
		# [FIX] Explicitly register property info metadata to tell the editor UI this is a string
		var property_info := {
			"name": settings_path,
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": ""
		}
		if settings.has_method("add_custom_property_info"):
			settings.call("add_custom_property_info", property_info)
			
		var shortcut := Shortcut.new()
		var key_event := InputEventKey.new()
		
		# Fetch the current configuration string and safely resolve it back to an engine KeyCode
		var current_key_str: String = str(settings.get_setting(settings_path))
		var resolved_keycode: int = OS.find_keycode_from_string(current_key_str)
		
		key_event.keycode = resolved_keycode as Key
		shortcut.events.append(key_event)
		
		brush_shortcuts[mode_idx] = shortcut


## Generates the modern horizontal Radio-Button toolbar interface inside the main editor container.
func _create_brush_ui_panel() -> void:
	if brush_panel_container: return
	
	brush_panel_container = HBoxContainer.new()
	brush_panel_container.name = "TerrainBuilder_Toolbar_Container"
	brush_panel_container.hide()
	
	button_group = ButtonGroup.new()
	
	var button_definitions: Array = [
		[0, "Raise", "ToolsElevation.svg"],
		[1, "Lower", "ToolsElevationLower.svg"],
		[2, "Flatten", "ToolsFlatten.svg"],
		[3, "Smooth", "ToolsSmooth.svg"],
		[4, "Activate Chunk", "TileChecked.svg"],
		[5, "Deactivate Chunk", "TileUnchecked.svg"]
	]
	
	var base_control := EditorInterface.get_base_control()
	
	for def in button_definitions:
		# [FIX] Extract the data cleanly from the definition array indexes
		var mode_idx: int = def[0] as int
		var label_text: String = def[1] as String
		var fallback_icon_name: String = def[2] as String
		
		var btn := Button.new()
		btn.text = label_text
		btn.toggle_mode = true
		btn.button_group = button_group
		btn.set_meta("brush_mode", mode_idx)
		
		if base_control and base_control.theme:
			if base_control.has_theme_icon(fallback_icon_name, "EditorIcons"):
				btn.icon = base_control.get_theme_icon(fallback_icon_name, "EditorIcons")
				
		var shortcut_node = brush_shortcuts.get(mode_idx)
		if shortcut_node and shortcut_node is Shortcut and not shortcut_node.events.is_empty():
			# [FIX] This now automatically extracts the real character name (e.g. "Q") instead of ASCII codes
			btn.tooltip_text = "%s (%s)" % [label_text, shortcut_node.get_as_text()]

			
		btn.pressed.connect(_on_brush_button_pressed.bind(mode_idx))
		brush_panel_container.add_child(btn)
		
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, brush_panel_container)



## Clears out the UI elements from the memory tree completely to prevent leaks.
func _destroy_brush_ui_panel() -> void:
	if brush_panel_container:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, brush_panel_container)
		brush_panel_container.queue_free()
		brush_panel_container = null
		button_group = null


## Toggles visibility status of the tool selection menu container dynamically.
func _show_brush_ui_panel(visible: bool) -> void:
	if brush_panel_container:
		brush_panel_container.visible = visible


## Updates the manager state and forces property list synchronization on click.
func _select_brush_mode(mode_idx: int) -> void:
	if not active_manager: return
	active_manager.tool_mode = mode_idx as LowPolyTerrainManager.BrushMode
	active_manager.notify_property_list_changed()
	_sync_ui_buttons_with_manager()


## Internal signal event wrapper fired when clicking any item on the toolbar.
func _on_brush_button_pressed(mode_idx: int) -> void:
	_select_brush_mode(mode_idx)


## Pulls active settings directly from the selected node to depress the correct button instance.
func _sync_ui_buttons_with_manager() -> void:
	if not active_manager or not brush_panel_container: return
	var active_mode: int = active_manager.tool_mode
	
	for child in brush_panel_container.get_children():
		if child is Button and child.has_meta("brush_mode"):
			var btn_mode: int = child.get_meta("brush_mode")
			child.set_pressed_no_signal(btn_mode == active_mode)
