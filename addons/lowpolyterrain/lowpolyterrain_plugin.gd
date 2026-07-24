@tool
extends EditorPlugin

## EditorPlugin script that bridges the Godot 3D viewports with the low poly terrain tools.
## Handles a persistent, semi-transparent 3D brush gizmo and processes painting signals.


# Mirror the manager's enum and extend it cleanly for utility shortcuts
enum PluginToolMode {
	RAISE = 0,
	LOWER = 1,
	FLATTEN = 2,
	SMOOTH = 3,
	ACTIVATE_CHUNK = 4,
	DEACTIVATE_CHUNK = 5,
	# [MARKER] Everything below this value will be skipped by the UI generator loop
	NO_FURTHER_BUTTONS = 5, 
	DECREASE_BRUSH_RADIUS = 6,
	INCREASE_BRUSH_RADIUS = 7,
	DEFAULT = 20 # used for default assigements
}

# Centralized color mapping matching the tool modes for intuitive 3D editor feedback
const BRUSH_COLORS: Dictionary = {
	PluginToolMode.RAISE: Color(0.3, 0.65, 1.0, 0.8),             # Light Blue (Raise)
	PluginToolMode.LOWER: Color(0.1, 0.25, 0.7, 0.85),            # Dark Blue (Lower)
	PluginToolMode.FLATTEN: Color(0.65, 0.65, 0.65, 0.8),         # Gray (Flatten)
	PluginToolMode.SMOOTH: Color(0.6, 0.2, 0.85, 0.8),            # Purple (Smooth)
	PluginToolMode.ACTIVATE_CHUNK: Color(0.15, 0.85, 0.15, 0.75),  # Green (Activate)
	PluginToolMode.DEACTIVATE_CHUNK: Color(0.85, 0.15, 0.15, 0.75), # Red (Deactivate)
	PluginToolMode.DEFAULT: Color(1.0, 1.0, 1.0, 0.9)
}


# Centralized definition array for zero-redundancy UI and shortcut handling
# Format: [Enum Index, Identifier/Setting String, Display Name, Icon Path, Default Key String]
const BRUSH_TOOL_DEFINITIONS: Array = [
	[PluginToolMode.RAISE, "raise_terrain", "Raise", "res://addons/lowpolyterrain/icons/raise.svg", "Q"],
	[PluginToolMode.LOWER, "lower_terrain", "Lower", "res://addons/lowpolyterrain/icons/lower.svg", "W"],
	[PluginToolMode.FLATTEN, "flatten_terrain", "Flatten", "res://addons/lowpolyterrain/icons/flatten.svg", "E"],
	[PluginToolMode.SMOOTH, "smooth_terrain", "Smooth", "res://addons/lowpolyterrain/icons/smooth.svg", "R"],
	[PluginToolMode.ACTIVATE_CHUNK, "activate_chunk", "Activate Chunk", "res://addons/lowpolyterrain/icons/activate.svg", "A"],
	[PluginToolMode.DEACTIVATE_CHUNK, "deactivate_chunk", "Deactivate Chunk", "res://addons/lowpolyterrain/icons/deactivate.svg", "S"],
	[PluginToolMode.DECREASE_BRUSH_RADIUS, "decrease_brush_radius", "Decrease Brush Size", "", "COMMA"],
	[PluginToolMode.INCREASE_BRUSH_RADIUS, "increase_brush_radius", "Increase Brush Size", "", "PERIOD"]
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
	# Registriert den neuen Node mit Ihrem Custom-Icon
	add_custom_type(
		"LowPolyTerrainManager", 
		"Node3D", 
		preload("res://addons/lowpolyterrain/LowPolyTerrainManager.gd"), 
		preload("res://addons/lowpolyterrain/icon.svg")
	)
	
	_initialize_editor_shortcuts()
	_create_brush_ui_panel()
	
	# Listen for global editor setting updates to dynamically refresh button text
	var settings := EditorInterface.get_editor_settings()
	if settings and not settings.settings_changed.is_connected(_on_editor_settings_changed):
		settings.settings_changed.connect(_on_editor_settings_changed)

func _exit_tree() -> void:
	remove_custom_type("LowPolyTerrainManager")
	_destroy_brush_ui_panel()
	
	var settings := EditorInterface.get_editor_settings()
	if settings and settings.settings_changed.is_connected(_on_editor_settings_changed):
		settings.settings_changed.disconnect(_on_editor_settings_changed)

func _handles(object: Object) -> bool:
	return object is LowPolyTerrainManager

func _edit(object: Object) -> void:
	# Disconnect old signal handlers cleanly to prevent double bindings
	if active_manager:
		if active_manager.is_connected("signal_brush_settings_changed", _on_signal_brush_settings_changed):
			active_manager.disconnect("signal_brush_settings_changed", _on_signal_brush_settings_changed)
			
		var inspector := EditorInterface.get_inspector()
		if inspector and inspector.is_connected("property_edited", _on_inspector_property_edited):
			inspector.disconnect("property_edited", _on_inspector_property_edited)

	if object is LowPolyTerrainManager:
		active_manager = object
		active_manager.set_meta("_edit_lock_", true)
		active_manager.rebuild_chunks_structure()
		
		# Connect only the custom scaling/hotkey signal
		if not active_manager.is_connected("signal_brush_settings_changed", _on_signal_brush_settings_changed):
			active_manager.connect("signal_brush_settings_changed", _on_signal_brush_settings_changed)
			
		# Connect the inspector click hook safely
		var inspector := EditorInterface.get_inspector()
		if inspector and not inspector.is_connected("property_edited", _on_inspector_property_edited):
			inspector.connect("property_edited", _on_inspector_property_edited)
			
		_create_3d_brush_gizmo()
		_show_brush_ui_panel(true)
		_sync_ui_buttons_with_manager()
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
		_show_brush_ui_panel(false)



func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> EditorPlugin.AfterGUIInput:
	if not active_manager:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
		
	if event is InputEventKey and event.pressed:
		for mode in brush_shortcuts.keys():
			var sc: Shortcut = brush_shortcuts[mode]
			if sc.matches_event(event):
				# Use clean enum identifiers instead of fragile magic numbers
				if mode == PluginToolMode.DECREASE_BRUSH_RADIUS:
					active_manager.brush_radius = clampi(active_manager.brush_radius - 1, 1, 250)
					active_manager.notify_property_list_changed.call_deferred()
					return EditorPlugin.AFTER_GUI_INPUT_STOP
				elif mode == PluginToolMode.INCREASE_BRUSH_RADIUS:
					active_manager.brush_radius = clampi(active_manager.brush_radius + 1, 1, 250)
					active_manager.notify_property_list_changed.call_deferred()
					return EditorPlugin.AFTER_GUI_INPUT_STOP
				else:
					if not event.echo:
						_select_brush_mode(mode)
						return EditorPlugin.AFTER_GUI_INPUT_STOP
						

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
#


## Spawns a semi-transparent 3D cylinder disk acting as the brush indicator inside the scene tree.
## Instantiates the transient, RAM-only 3D sculpting ring and text feedback label.
func _create_3d_brush_gizmo() -> void:
	if not active_manager or brush_gizmo: return
	
	brush_gizmo = MeshInstance3D.new() as MeshInstance3D
	brush_gizmo.name = "DEBUG_BrushGizmo_Transient"
	active_manager.add_child(brush_gizmo)
	
	var gizmo_material := StandardMaterial3D.new()
	gizmo_material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	gizmo_material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	gizmo_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	
	# [FIX] Disable depth testing so the colored brush circle always renders cleanly on top of the terrain polygons
	gizmo_material.no_depth_test = true
	
	brush_gizmo.material_override = gizmo_material
	
	var text_label := Label3D.new()
	text_label.name = "Gizmo_Text_Label"
	text_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	text_label.no_depth_test = true
	
	text_label.font_size = 128
	text_label.outline_size = 16
	text_label.modulate = Color(1.0, 1.0, 1.0, 0.95)
	text_label.position = Vector3(0, 1.2, 0.0)
	brush_gizmo.add_child(text_label)
	
	_update_gizmo_scale()



func _destroy_3d_brush_gizmo() -> void:
	if brush_gizmo:
		if brush_gizmo.get_parent():
			brush_gizmo.get_parent().remove_child(brush_gizmo)
		brush_gizmo.free()
		brush_gizmo = null

## Instantly recalibrates the gizmo's world scale, bypassing Godot inspector sync latency.
## Dynamically updates the gizmo mesh, material colors, and floating text feedback.
func _update_gizmo_scale() -> void:
	if not brush_gizmo or not active_manager: return
	
	var ring_mesh: MeshInstance3D = brush_gizmo as MeshInstance3D
	var text_label: Label3D = brush_gizmo.get_node_or_null("Gizmo_Text_Label") as Label3D
	
	var mode_idx: int = active_manager.tool_mode
	var current_radius: float = float(active_manager.brush_radius) * active_manager.cell_size
	
	# 1. UPDATE MATERIAL CODES & ENFORCE ACTIVE COLOR SYNCHRONIZATION
	var mat: StandardMaterial3D = ring_mesh.material_override as StandardMaterial3D
	if mat:
		if BRUSH_COLORS.has(mode_idx):
			mat.albedo_color = BRUSH_COLORS[mode_idx] as Color
		else:
			mat.albedo_color = BRUSH_COLORS[PluginToolMode.DEFAULT] as Color
			
	# 2. [FIX] EXTRACT CLEAN LABELS VIA EXPLICIT ARRAY INDEX POSITION DEF
	if text_label:
		var mode_name: String = ""
		for def in BRUSH_TOOL_DEFINITIONS:
			if def[0] as int == mode_idx:
				mode_name = def[2] as String # Safely retrieve the human-readable text from index 2
				break
				
		if mode_idx == PluginToolMode.RAISE or mode_idx == PluginToolMode.LOWER or mode_idx == PluginToolMode.SMOOTH: 
			text_label.text = "%s\nR: %d | S: %.2f" % [mode_name, active_manager.brush_radius, active_manager.brush_strength]
		else: 
			text_label.text = "%s\nR: %d" % [mode_name, active_manager.brush_radius]
			
		if BRUSH_COLORS.has(mode_idx):
			var border_color: Color = BRUSH_COLORS[mode_idx]
			text_label.outline_modulate = Color(border_color.r * 0.2, border_color.g * 0.2, border_color.b * 0.2, 1.0)
			
	# 3. BUILD A SOLID TRANSPARENT 3D BRUSH CIRCLE SURFACE
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
	if brush_panel_container: return
	
	brush_panel_container = HBoxContainer.new()
	brush_panel_container.name = "TerrainBuilder_Toolbar_Container"
	brush_panel_container.hide()
	
	button_group = ButtonGroup.new()
	
	for def in BRUSH_TOOL_DEFINITIONS:
		var mode_idx: int = def[0] as int
		
		if mode_idx > PluginToolMode.NO_FURTHER_BUTTONS:
			continue
			
		var label_text: String = def[2] as String
		var icon_path: String = def[3] as String
		
		var btn := Button.new()
		btn.toggle_mode = true
		btn.button_group = button_group
		btn.set_meta("brush_mode", mode_idx)
		btn.autowrap_mode = TextServer.AUTOWRAP_OFF
		
		# Universal white asset loading with built-in theme-aware modulation overrides
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
			
			if shortcut_text == "Comma": shortcut_text = ","
			if shortcut_text == "Period": shortcut_text = "."
			
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
	
	if mode_idx == PluginToolMode.ACTIVATE_CHUNK or mode_idx == PluginToolMode.DEACTIVATE_CHUNK:
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
func _on_inspector_property_edited(property_name: String) -> void:
	if not active_manager or not brush_gizmo: return
	
	# Handle explicit sculpting property updates cleanly without full array frame-spam
	if property_name == "tool_mode" or property_name == "brush_radius" or property_name == "brush_strength":
		# 1. Update the 3D visual circle mesh and floating text label
		_update_gizmo_scale()
		
		# 2. Force the toolbar radio buttons to depress the correct tool icon instantly
		_sync_ui_buttons_with_manager()
