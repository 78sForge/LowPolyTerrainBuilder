@tool
extends EditorPlugin

## EditorPlugin script that bridges the Godot 3D viewports with the low poly terrain tools.
## Handles a persistent, semi-transparent 3D brush gizmo and processes painting signals.


# Centralized color mapping matching the tool modes for intuitive 3D editor feedback
const BRUSH_COLORS: Dictionary = {
	LowPolyTerrainManager.BrushMode.RAISE: Color(0.3, 0.65, 1.0, 0.8),              # Light Blue (Raise)
	LowPolyTerrainManager.BrushMode.LOWER: Color(0.1, 0.25, 0.7, 0.85),             # Dark Blue (Lower)
	LowPolyTerrainManager.BrushMode.FLATTEN: Color(0.75, 0.4, 0.2, 0.8),            # Orange (Flatten)
	LowPolyTerrainManager.BrushMode.SMOOTH: Color(0.6, 0.2, 0.85, 0.8),             # Purple (Smooth)
	LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK: Color(0.15, 0.85, 0.15, 0.75),  # Green (Activate)
	LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK: Color(0.85, 0.15, 0.15, 0.75) # Red (Deactivate)
}
const FallBackColor := Color(1.0, 1.0, 1.0, 0.9) # Default fallback color
# Centralized definition array driven directly by the manager's master enum
# Formatting: [Enum/Index, Identifier String, Display Name, Icon Path, Default Key String]
const BRUSH_TOOL_DEFINITIONS: Array = [
	[LowPolyTerrainManager.BrushMode.RAISE, "raise_terrain", "Raise", "res://addons/lowpolyterrain/icons/raise.svg", "Q"],
	[LowPolyTerrainManager.BrushMode.LOWER, "lower_terrain", "Lower", "res://addons/lowpolyterrain/icons/lower.svg", "W"],
	[LowPolyTerrainManager.BrushMode.FLATTEN, "flatten_terrain", "Flatten", "res://addons/lowpolyterrain/icons/flatten.svg", "E"],
	[LowPolyTerrainManager.BrushMode.SMOOTH, "smooth_terrain", "Smooth", "res://addons/lowpolyterrain/icons/smooth.svg", "R"],
	[LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK, "activate_chunk", "Activate Chunk", "res://addons/lowpolyterrain/icons/activate.svg", "A"],
	[LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK, "deactivate_chunk", "Deactivate Chunk", "res://addons/lowpolyterrain/icons/deactivate.svg", "S"],
	[LowPolyTerrainManager.BrushMode.DECREASE_BRUSH_RADIUS, "decrease_brush_radius", "Decrease Brush Size", "", "COMMA"], # Plugin specific helper index
	[LowPolyTerrainManager.BrushMode.INCREASE_BRUSH_RADIUS, "increase_brush_radius", "Increase Brush Size", "", "PERIOD"]   # Plugin specific helper index
]



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
	# Register the custom type node
	add_custom_type(
		"LowPolyTerrainManager", 
		"Node3D", 
		preload("res://addons/lowpolyterrain/LowPolyTerrainManager.gd"), 
		preload("res://addons/lowpolyterrain/icon.svg")
	)
	
	_initialize_editor_shortcuts()
	_create_brush_ui_panel()
	
	# Listen for global editor setting updates
	var settings := EditorInterface.get_editor_settings()
	if settings and not settings.settings_changed.is_connected(_on_editor_settings_changed):
		settings.settings_changed.connect(_on_editor_settings_changed)
		
	# [FIX] Connect the native EditorPlugin signal directly to this script instance
	if not main_screen_changed.is_connected(_on_main_screen_changed):
		main_screen_changed.connect(_on_main_screen_changed)

	# [FIX] Clean connection to the native scene tab change signal
	if not scene_changed.is_connected(_on_editor_scene_changed):
		scene_changed.connect(_on_editor_scene_changed)

func _exit_tree() -> void:
	remove_custom_type("LowPolyTerrainManager")
	_destroy_brush_ui_panel()
	
	var settings := EditorInterface.get_editor_settings()
	if settings and settings.settings_changed.is_connected(_on_editor_settings_changed):
		settings.settings_changed.disconnect(_on_editor_settings_changed)
		
	# [FIX] Clean up the signal connection on plugin exit
	if main_screen_changed.is_connected(_on_main_screen_changed):
		main_screen_changed.disconnect(_on_main_screen_changed)
		
	# [FIX] Disconnect on exit to keep memory clean
	if scene_changed.is_connected(_on_editor_scene_changed):
		scene_changed.disconnect(_on_editor_scene_changed)



## Automatically fired by Godot 4.7 when the user switches between open scene tabs.
func _on_editor_scene_changed(new_scene_root: Node) -> void:
	# Reset the active manager to put the plugin to sleep
	if active_manager and is_instance_valid(active_manager):
		active_manager.set_meta("_edit_lock_", false)
		if "is_paint_stroke_active" in active_manager:
			active_manager.is_paint_stroke_active = false
			
	active_manager = null
	is_drawing = false
	
	# Instantly clear UI visual fragments
	if mouse_label:
		mouse_label.visible = false
		
	_destroy_3d_brush_gizmo()
	_show_brush_ui_panel(false)



func _handles(object: Object) -> bool:
	return object is LowPolyTerrainManager


func _edit(object: Object) -> void:
	# Disconnect old signal handlers cleanly to prevent double bindings
	if active_manager and is_instance_valid(active_manager):
		if active_manager.is_connected("signal_brush_settings_changed", _on_signal_brush_settings_changed):
			active_manager.disconnect("signal_brush_settings_changed", _on_signal_brush_settings_changed)
			
		# Explicitly unbind the custom export signal from the previous manager instance
		if active_manager.is_connected("signal_export_requested", _open_export_dialog_from_plugin):
			active_manager.disconnect("signal_export_requested", _open_export_dialog_from_plugin)
			
		var inspector := EditorInterface.get_inspector()
		if inspector and inspector.is_connected("property_edited", _on_inspector_property_edited):
			inspector.disconnect("property_edited", _on_inspector_property_edited)

	if object is LowPolyTerrainManager and object.is_inside_tree():
		active_manager = object
		active_manager.set_meta("_edit_lock_", true)
		active_manager.rebuild_chunks_structure()
		
		# Connect only the custom scaling/hotkey signal
		if not active_manager.is_connected("signal_brush_settings_changed", _on_signal_brush_settings_changed):
			active_manager.connect("signal_brush_settings_changed", _on_signal_brush_settings_changed)
			
		# Securely bridge the manager button with the isolated editor plugin UI pipeline
		if not active_manager.is_connected("signal_export_requested", _open_export_dialog_from_plugin):
			active_manager.connect("signal_export_requested", _open_export_dialog_from_plugin)
			
		# Connect the inspector click hook safely
		var inspector := EditorInterface.get_inspector()
		if inspector and not inspector.is_connected("property_edited", _on_inspector_property_edited):
			inspector.connect("property_edited", _on_inspector_property_edited)
			
		_create_3d_brush_gizmo()
		_show_brush_ui_panel(true)
		_sync_ui_buttons_with_manager()
		
		# [FIX] Force-update the 3D ring mesh and 2D text label to instantly match the newly selected manager
		_update_gizmo_scale()
	else:
		if active_manager and is_instance_valid(active_manager):
			active_manager.set_meta("_edit_lock_", false)
			if "is_paint_stroke_active" in active_manager:
				active_manager.is_paint_stroke_active = false
				
		active_manager = null
		is_drawing = false
		
		if mouse_label:
			mouse_label.visible = false
			
		_destroy_3d_brush_gizmo()
		_show_brush_ui_panel(false)



func _make_visible(visible: bool) -> void:
	if not visible:
		if active_manager:
			active_manager.set_meta("_edit_lock_", false)
		active_manager = null
		is_drawing = false
		_destroy_3d_brush_gizmo()



## Automatically fired by Godot when switching between 2D, 3D, and Script screens.
func _on_main_screen_changed(screen_name: String) -> void:
	# Hide the 2D canvas label immediately if the user leaves the 3D viewport canvas
	if screen_name != "3D":
		if mouse_label:
			mouse_label.visible = false
			
		# Reset session state variables inside the manager to prevent continuous drawing states
		if active_manager:
			active_manager.is_paint_stroke_active = false
		is_drawing = false



func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not active_manager:
		return 0 # EditorPlugin.AFTER_GUI_INPUT_PASS
		
	# Process brush size and tool switching shortcuts inside the 3D viewport
	if event is InputEventKey and event.pressed:
		for mode in brush_shortcuts.keys():
			var sc: Shortcut = brush_shortcuts[mode]
			if sc.matches_event(event):
				if mode == LowPolyTerrainManager.BrushMode.DECREASE_BRUSH_RADIUS:
					active_manager.brush_radius = clampi(active_manager.brush_radius - 1, 1, 50)
					active_manager.notify_property_list_changed.call_deferred()
					return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
				elif mode == LowPolyTerrainManager.BrushMode.INCREASE_BRUSH_RADIUS:
					active_manager.brush_radius = clampi(active_manager.brush_radius + 1, 1, 50)
					active_manager.notify_property_list_changed.call_deferred()
					return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
				else:
					if not event.echo:
						_select_brush_mode(mode)
						return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
		
	# Track and update the 2D label and 3D gizmo position on mouse motion
	if event is InputEventMouseMotion:
		_update_gizmo_position(viewport_camera, event.position)
		
		if mouse_label and brush_gizmo and brush_gizmo.visible:
			var global_mouse_pos: Vector2 = event.global_position
			mouse_label.position = global_mouse_pos + Vector2(20, 20)
			mouse_label.visible = true
		elif mouse_label:
			mouse_label.visible = false
			
		if is_drawing:
			_process_paint_stroke(viewport_camera, event.position, event.shift_pressed)
			return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
			
	# Process active mouse click strokes for sculpting operations
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_drawing = event.pressed
			
			# [UNDO/REDO INTERCEPT] Handle stroke lifecycle management inside the editor workspace
			if is_drawing and active_manager:
				var manager_undo_redo: EditorUndoRedoManager = get_undo_redo()
				if active_manager.has_method("stroke_started"):
					active_manager.stroke_started(manager_undo_redo)
			
			# When the user releases the left mouse button, reset the session cache in the manager
			# needed for FLATTEN mode where is_paint_stroke_active is set to true
			if not is_drawing and active_manager:
				active_manager.is_paint_stroke_active = false
				if active_manager.has_method("stroke_finished"):
					active_manager.stroke_finished()
				
			if is_drawing:
				_process_paint_stroke(viewport_camera, event.position, event.shift_pressed)
				return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP

	return 0 # EditorPlugin.AFTER_GUI_INPUT_PASS

# New 2D label reference inside the plugin script
var mouse_label: Label = null

func _create_3d_brush_gizmo() -> void:
	if not active_manager or brush_gizmo: 
		return
	
	brush_gizmo = MeshInstance3D.new()
	brush_gizmo.name = "DEBUG_BrushGizmo_Transient"
	active_manager.add_child(brush_gizmo)
	
	var gizmo_material := StandardMaterial3D.new()
	gizmo_material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	gizmo_material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	gizmo_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	gizmo_material.no_depth_test = true
	brush_gizmo.material_override = gizmo_material
	
	# Instantiate the 2D canvas label on top of the editor base viewport
	if not mouse_label:
		mouse_label = Label.new()
		mouse_label.name = "Gizmo_Mouse_Label"
		
		# Enforce absolute pass-through for mouse clicks to unblock the brush
		mouse_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		
		var outline_color := Color(0, 0, 0, 0.8)
		mouse_label.add_theme_color_override("font_color", Color.WHITE)
		mouse_label.add_theme_color_override("font_outline_color", outline_color)
		mouse_label.add_theme_constant_override("outline_size", 6)
		
		var editor_base: Control = EditorInterface.get_base_control()
		if editor_base:
			editor_base.add_child(mouse_label)
	
	_update_gizmo_scale()


func _update_gizmo_scale() -> void:
	if not brush_gizmo or not active_manager: 
		return
	
	var ring_mesh: MeshInstance3D = brush_gizmo
	var mode_idx: int = active_manager.tool_mode
	var current_radius: float = float(active_manager.brush_radius) * active_manager.cell_size
	
	var mat: StandardMaterial3D = ring_mesh.material_override
	if mat:
		if BRUSH_COLORS.has(mode_idx):
			mat.albedo_color = BRUSH_COLORS[mode_idx]
		else:
			mat.albedo_color = FallBackColor
			
	# Safely extract text fields using absolute indexing to make MouseLabel visible
	if mouse_label:
		var mode_name: String = ""
		for def in BRUSH_TOOL_DEFINITIONS:
			# Check the specific Enum value from the first array slot (index 0)
			if def[0] == mode_idx:
				mode_name = def[2] as String
				break
				
		if mode_idx == LowPolyTerrainManager.BrushMode.RAISE or mode_idx == LowPolyTerrainManager.BrushMode.LOWER or mode_idx == LowPolyTerrainManager.BrushMode.SMOOTH: 
			mouse_label.text = "%s\nR: %d | S: %.2f" % [mode_name, active_manager.brush_radius, active_manager.brush_strength]
		else: 
			mouse_label.text = "%s\nR: %d" % [mode_name, active_manager.brush_radius]
			
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments: int = 36
	var center_vertex := Vector3(0.0, 0.03, 0.0)
	
	for i in range(segments):
		var theta0: float = (float(i) / float(segments)) * TAU
		var theta1: float = (float(i + 1) / float(segments)) * TAU
		
		var p0 := Vector3(sin(theta0) * current_radius, 0.03, cos(theta0) * current_radius)
		var p1 := Vector3(sin(theta1) * current_radius, 0.03, cos(theta1) * current_radius)
		
		st.add_vertex(center_vertex)
		st.add_vertex(p0)
		st.add_vertex(p1)
		
	ring_mesh.mesh = st.commit()





func _destroy_3d_brush_gizmo() -> void:
	if brush_gizmo:
		if brush_gizmo.get_parent():
			brush_gizmo.get_parent().remove_child(brush_gizmo)
		brush_gizmo.free()
		brush_gizmo = null
		
	if mouse_label:
		if mouse_label.get_parent():
			mouse_label.get_parent().remove_child(mouse_label)
		mouse_label.free()
		mouse_label = null


## Casts a mouse ray against chunk dimensions using accelerated AABB segment pre-testing.
func _update_gizmo_position(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not brush_gizmo or not active_manager:
		return
	
	var ray_origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(mouse_pos)
	
	var closest_hit: float = INF
	var world_hit_point: Vector3 = Vector3.ZERO
	var found_hit: bool = false
	
	# Iterate through all instantiated terrain chunks managed by the central matrix
	for chunk in active_manager.chunks_dict.values():
		if not chunk or not chunk.is_inside_tree() or not chunk.mesh:
			continue
		
		# Transform the ray directly into the local coordinate space of the current chunk
		var inv_transform: Transform3D = chunk.global_transform.inverse()
		var local_origin: Vector3 = inv_transform * ray_origin
		var local_ray_end: Vector3 = local_origin + (inv_transform.basis * ray_dir) * 5000.0
		
		# Ultra-fast AABB segment pre-test to reject distant chunks in O(1) time
		if not chunk.mesh.get_aabb().intersects_segment(local_origin, local_ray_end):
			continue
			
		# Extract the exact physical triangles only for chunks that pass the bounding box check
		var faces: PackedVector3Array = chunk.mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var intersect = Geometry3D.ray_intersects_triangle(
				local_origin, 
				inv_transform.basis * ray_dir, 
				faces[i], 
				faces[i+1], 
				faces[i+2]
			)
			if intersect != null:
				var dist: float = local_origin.distance_to(intersect)
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


## Target handler fired when custom hotkeys or script calls update the brush properties.
func _on_signal_brush_settings_changed() -> void:
	if active_manager and brush_gizmo:
		print("_on_signal_brush_settings_changed -> Updating 3D gizmo scale!")
		_update_gizmo_scale()


## Registers shortcuts cleanly inside the Editor Settings using the central constants template.
func _initialize_editor_shortcuts() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings: return
	
	for def in BRUSH_TOOL_DEFINITIONS:
		var mode_idx: int = def[0] as int
		var id_str: String = def[1] as String
		var default_key_str: String = def[4] as String
		
		# Create a standardized, native editor setting path for the input key
		var settings_path: String = "plugins/low_poly_terrain_builder/shortcuts/" + id_str
		
		# Force a complete overwrite of the setting to break Godot's internal type caching
		if settings.has_setting(settings_path):
			var current_val = settings.get_setting(settings_path)
			if typeof(current_val) == TYPE_INT:
				var healed_str: String = OS.get_keycode_string(current_val as Key)
				if healed_str.is_empty(): healed_str = default_key_str
				settings.set_setting(settings_path, healed_str)
		else:
			settings.set_setting(settings_path, default_key_str)
			
		# Enforce the default fallback state value explicitly as a clear string type
		settings.set_initial_value(settings_path, default_key_str, false)
		
		# Explicitly register property info metadata to tell the editor UI this is a string
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
		
		# Fetch the current configuration string from the settings registry
		var current_key_str: String = str(settings.get_setting(settings_path))
		
		# [FIX] Automatically map raw character inputs back to formal engine key identifiers
		if current_key_str == ",":
			current_key_str = "COMMA"
		elif current_key_str == ".":
			current_key_str = "PERIOD"
			
		var resolved_keycode: int = OS.find_keycode_from_string(current_key_str)
		
		key_event.keycode = resolved_keycode as Key
		shortcut.events.append(key_event)
		
		brush_shortcuts[mode_idx] = shortcut


## Generates the modern horizontal Radio-Button toolbar interface driven by the central constant.
func _create_brush_ui_panel() -> void:
	if brush_panel_container: 
		return
	
	brush_panel_container = HBoxContainer.new()
	brush_panel_container.name = "TerrainBuilder_Toolbar_Container"
	brush_panel_container.hide()
	
	button_group = ButtonGroup.new()
	
	for def in BRUSH_TOOL_DEFINITIONS:
		var mode_idx: int = def[0] as int
		
		# Restrict UI loop to terrain tools only, skipping the radius shortcut identifiers
		if mode_idx > LowPolyTerrainManager.BrushMode.NO_FURTHER_BUTTONS:
			continue
			
		var label_text: String = def[2] as String
		var icon_path: String = def[3] as String
		
		var btn := Button.new()
		btn.toggle_mode = true
		btn.button_group = button_group
		btn.set_meta("brush_mode", mode_idx)
		btn.autowrap_mode = TextServer.AUTOWRAP_OFF
		
		if ResourceLoader.exists(icon_path):
			btn.icon = load(icon_path) as Texture2D
			
			var editor_theme := EditorInterface.get_editor_theme()
			if editor_theme:
				var normal_color: Color = editor_theme.get_color("icon_normal_color", "Editor")
				var pressed_color: Color = editor_theme.get_color("icon_pressed_color", "Editor")
				var hover_color: Color = editor_theme.get_color("icon_hover_color", "Editor")
				
				btn.add_theme_color_override("icon_normal_color", normal_color)
				btn.add_theme_color_override("icon_pressed_color", pressed_color)
				btn.add_theme_color_override("icon_hover_color", hover_color)
				btn.add_theme_color_override("icon_focus_color", hover_color)
				
		var shortcut_node = brush_shortcuts.get(mode_idx)
		if shortcut_node and shortcut_node is Shortcut and not shortcut_node.events.is_empty():
			var shortcut_text: String = shortcut_node.get_as_text()
			
			if shortcut_text == "Comma": 
				shortcut_text = ","
			if shortcut_text == "Period": 
				shortcut_text = "."
			
			btn.text = "%s (%s)" % [label_text, shortcut_text]
			btn.tooltip_text = "%s (%s)" % [label_text, shortcut_text]
		else:
			btn.text = label_text

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
	
	if mode_idx == LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK or mode_idx == LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK:
		if not active_manager.show_deactivated_chunks:
			active_manager.show_deactivated_chunks = true
			active_manager.rebuild_chunks_structure()
			
	active_manager.notify_property_list_changed()
	_sync_ui_buttons_with_manager()
	
	# [FIX] Instantly refresh the visual brush ring color, mesh, and text when the tool changes
	_update_gizmo_scale()


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
			
			# Force immediate redrawing update on active state color toggles
			child.queue_redraw()


## Automatically fired when the user modifies any configuration inside the Editor Settings.
func _on_editor_settings_changed() -> void:
	if not brush_panel_container: return
	
	# Force clean refresh of internal shortcuts cache
	_initialize_editor_shortcuts()
	
	# Update active button label displays on the fly without breaking tree allocations
	for child in brush_panel_container.get_children():
		if child is Button and child.has_meta("brush_mode"):
			var mode_idx: int = child.get_meta("brush_mode")
			var label_text: String = ""
			
			# Extract display name directly from our centralized constant array blueprint
			for def in BRUSH_TOOL_DEFINITIONS:
				if def[0] == mode_idx:
					label_text = def[2]
					break
					
			var shortcut_node = brush_shortcuts.get(mode_idx)
			if shortcut_node and shortcut_node is Shortcut and not shortcut_node.events.is_empty():
				var shortcut_text: String = shortcut_node.get_as_text()
				child.text = "%s (%s)" % [label_text, shortcut_text]
				child.tooltip_text = "%s (%s)" % [label_text, shortcut_text]

## Triggered dynamically whenever any property (like brush_strength) is modified inside the inspector.
func _on_manager_property_changed() -> void:
	if active_manager and brush_gizmo:
		# [FIX] Force immediate synchronization of text labels and scales on inspector input frames
		_update_gizmo_scale()
		

## Automatically fired by Godot only when a property is actively modified in the Inspector.
## Updates the editor properties and intercepts the inspector export button trigger cleanly.
func _on_inspector_property_edited(property_name: String) -> void:
	if not active_manager or not brush_gizmo: return
	
	# Intercept the export button press event before it can trigger inside a runtime context
	if property_name == "export_gltf_button":
		_open_export_dialog_from_plugin()
		return
		
	if property_name == "tool_mode" or property_name == "brush_radius" or property_name == "brush_strength":
		# 1. Update the 3D visual circle mesh and floating text label
		_update_gizmo_scale()
		
		# 2. Force the toolbar radio buttons to depress the correct tool icon instantly
		_sync_ui_buttons_with_manager()


## Opens a native editor save dialog. Safe from release build compilation errors since
## this entire script is automatically stripped by Godot during the export process.
func _open_export_dialog_from_plugin() -> void:
	if not active_manager or not is_instance_valid(active_manager):
		return
		
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.gltf", "GLTF 3D Asset")
	dialog.current_path = active_manager.export_target_path
	
	dialog.file_selected.connect(
		func(selected_path: String) -> void:
			active_manager.export_target_path = selected_path
			_execute_gltf_export_pipeline(selected_path)
			dialog.queue_free()
	)
	
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	
	var editor_base: Control = EditorInterface.get_base_control()
	if editor_base:
		editor_base.add_child(dialog)
		dialog.popup_file_dialog()


## Isolated editor-only engine that packages and writes the visual trimesh blocks to disk.
func _execute_gltf_export_pipeline(target_path: String) -> void:
	print("Starting GLTF terrain export to: %s" % target_path)
	
	var export_root := Node3D.new()
	export_root.name = "Exported_LowPoly_Terrain"
	var chunks_exported: int = 0
	
	# The plugin iterates through the active manager's chunks directly
	for coord in active_manager.chunks_dict.keys():
		if not active_manager.is_chunk_active(coord.x, coord.y):
			continue
			
		var chunk: LowPolyTerrainChunk = active_manager.chunks_dict[coord]
		if chunk == null or chunk.mesh == null: 
			continue
			
		var chunk_instance := MeshInstance3D.new()
		chunk_instance.name = "Terrain_Chunk_%d_%d" % [coord.x, coord.y]
		chunk_instance.mesh = chunk.mesh
		
		if chunk.material_override != null:
			chunk_instance.material_override = chunk.material_override
			
		chunk_instance.position = chunk.position
		export_root.add_child(chunk_instance)
		chunk_instance.set_owner(export_root)
		chunks_exported += 1
		
	if chunks_exported == 0:
		print("Export Cancelled: No active chunk meshes found to package.")
		export_root.free()
		return
		
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	gltf_doc.append_from_scene(export_root, gltf_state)
	
	var error_code: Error = gltf_doc.write_to_filesystem(gltf_state, target_path)
	export_root.free()
	
	if error_code == OK:
		print("SUCCESS: Successfully exported %d terrain chunks to GLTF format!" % chunks_exported)
		
		# Native call is 100% legal here, since this script runs exclusively within editor RAM
		var filesystem := EditorInterface.get_resource_filesystem()
		if filesystem:
			filesystem.scan()
	else:
		print("ERROR: GLTF export failed with engine error code: %d" % error_code)
