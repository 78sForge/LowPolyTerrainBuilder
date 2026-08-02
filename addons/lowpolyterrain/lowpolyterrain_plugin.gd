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
	LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK: Color(0.85, 0.15, 0.15, 0.75), # Red (Deactivate)
	LowPolyTerrainManager.BrushMode.RAMP: Color(0.95, 0.8, 0.2, 0.85),              # Gold (Ramp)
	LowPolyTerrainManager.BrushMode.PAINT: Color(0.9, 0.35, 0.75, 0.8)              # Magenta (Paint)
}
const FallBackColor := Color(1.0, 1.0, 1.0, 0.9) # Default fallback color
# Centralized definition array driven directly by the manager's master enum
# Formatting: [Enum/Index, Identifier String, Display Name, Icon Path, Default Key String]
#
# The brush tools deliberately ship WITHOUT a default key. _forward_3d_gui_input() consumes
# whatever it matches, so any default would take that key away from Godot for as long as a
# terrain node is selected - and the 3D viewport has no key left to spare: letters are taken by
# the tool modes, freelook and the Blender-style instant transforms, both number rows switch
# the view, and every modifier fails on at least one platform (Alt is dead-key and special
# character input on macOS and the menu mnemonic on Windows, Ctrl and Cmd are reserved, Shift
# is the freelook speed modifier). Users assign these themselves under
# Editor Settings > Plugins > Low Poly Terrain Builder > Shortcuts.
#
# Comma and Period are the exception: Godot leaves them alone in the 3D viewport, and they sit
# in the same place on QWERTY and QWERTZ alike.
const BRUSH_TOOL_DEFINITIONS: Array = [
	[LowPolyTerrainManager.BrushMode.RAISE, "raise_terrain", "Raise", "res://addons/lowpolyterrain/icons/raise.svg", ""],
	[LowPolyTerrainManager.BrushMode.LOWER, "lower_terrain", "Lower", "res://addons/lowpolyterrain/icons/lower.svg", ""],
	[LowPolyTerrainManager.BrushMode.FLATTEN, "flatten_terrain", "Flatten", "res://addons/lowpolyterrain/icons/flatten.svg", ""],
	[LowPolyTerrainManager.BrushMode.SMOOTH, "smooth_terrain", "Smooth", "res://addons/lowpolyterrain/icons/smooth.svg", ""],
	[LowPolyTerrainManager.BrushMode.ACTIVATE_CHUNK, "activate_chunk", "Activate Chunk", "res://addons/lowpolyterrain/icons/activate.svg", ""],
	[LowPolyTerrainManager.BrushMode.DEACTIVATE_CHUNK, "deactivate_chunk", "Deactivate Chunk", "res://addons/lowpolyterrain/icons/deactivate.svg", ""],
	[LowPolyTerrainManager.BrushMode.RAMP, "ramp_terrain", "Ramp", "res://addons/lowpolyterrain/icons/ramp.svg", ""],
	[LowPolyTerrainManager.BrushMode.PAINT, "paint_terrain", "Paint", "res://addons/lowpolyterrain/icons/paint.svg", ""],
	[LowPolyTerrainManager.BrushMode.DECREASE_BRUSH_RADIUS, "decrease_brush_radius", "Decrease Brush Size", "", "COMMA"], # Plugin specific helper index
	[LowPolyTerrainManager.BrushMode.INCREASE_BRUSH_RADIUS, "increase_brush_radius", "Increase Brush Size", "", "PERIOD"]   # Plugin specific helper index
]



var active_manager: LowPolyTerrainManager = null
var is_drawing: bool = false

## True while Shift is held, which temporarily inverts the active tool. Tracked so the ring
## colour and the caption can follow the stroke instead of describing the toolbar selection.
var _shift_held: bool = false

## How much of the brush a stroke keeps while it rests on one spot. A held button applies once
## per frame, so at full strength standing still digs as fast as a sweep across the terrain.
const HELD_STILL_STRENGTH: float = 0.5

## Distance, in cells, that returns a stroke to full strength. Kept small on purpose: only a
## stroke that genuinely rests is meant to be softened, and any real drag clears this within a
## single frame. Ramped rather than switched, so a slow drag cannot flicker between the two.
const FULL_STRENGTH_DISTANCE_CELLS: float = 0.25

## Brush position of the previous sculpting frame, for the movement measure above.
var _last_paint_position: Vector3 = Vector3.ZERO

# --- RAMP TOOL ---
# Two clicks rather than a stroke: the first anchors one end, the second commits the ramp. In
# between, a line follows the cursor so the span being built is visible before it is applied.
var _ramp_anchor_set: bool = false
var _ramp_anchor: Vector3 = Vector3.ZERO
var _ramp_line: MeshInstance3D = null
var _ramp_line_material: StandardMaterial3D = null
var _ramp_flank_material: StandardMaterial3D = null

## Opacity of the ramp preview's upward facing surface. Low enough to read the terrain
## underneath, high enough to judge the shape it would take.
const RAMP_PREVIEW_ALPHA: float = 0.4

## The cuts the ramp makes down to the surrounding ground, in a darker tone and more opaque.
## Tinting them like the top made the whole preview read as one flat patch of colour, which hid
## the very thing worth seeing: how far the ramp reaches and how steeply it lands.
const RAMP_FLANK_COLOR: Color = Color(0.55, 0.22, 0.02, 0.6)

## Default opacity of the brush disc. Kept low deliberately: the ring marks where the brush
## sits, and the terrain being sculpted has to stay readable underneath it. Bright terrain can
## swallow it entirely, which is why the value is a setting rather than a constant.
const BRUSH_FILL_ALPHA: float = 0.15

## Default opacity of the brush outline, which is what actually carries the tool colour.
const BRUSH_OUTLINE_ALPHA: float = 0.95

## Where the two live in the Editor Settings. Deliberately not inspector properties on the
## manager: how visible the brush needs to be depends on the terrain's brightness and on the
## person looking at it, not on the terrain itself - and a per-manager value would have to be
## set again for every terrain in the project, then saved into scenes that do not own it.
const SETTING_FILL_ALPHA: String = "plugins/low_poly_terrain_builder/brush/fill_opacity"
const SETTING_OUTLINE_ALPHA: String = "plugins/low_poly_terrain_builder/brush/outline_opacity"

## Segment count of the brush circle. Higher than the disc alone needed, because the outline
## now defines the silhouette and a coarse one reads as a polygon rather than a circle.
const BRUSH_RING_SEGMENTS: int = 64

## Every manager property the brush ring or its caption is built from. Editing one of them in
## the inspector has to refresh both at once.
##
## A named list rather than a chain of comparisons, because the chain went stale exactly the way
## such chains do: brush_falloff_strength reached the caption and nobody added it here, so the
## readout kept showing the previous value while the brush already used the new one. Adding a
## brush setting now means adding one line to this list.
const BRUSH_OVERLAY_PROPERTIES: PackedStringArray = [
	"tool_mode",
	"brush_radius",
	"brush_strength",
	"brush_falloff_strength",
	"paint_layer",
	"paint_material",
]

# Split across two surfaces so the outline can stay opaque while the disc is barely there.
var _brush_fill_material: StandardMaterial3D = null
var _brush_outline_material: StandardMaterial3D = null

# Transient 3D mesh instance used as a visual preview tool inside the editor viewport
var brush_gizmo: MeshInstance3D = null

# UI Control elements for the responsive brush tool selection panel
var brush_panel_container: HBoxContainer = null
var button_group: ButtonGroup = null

# List of native editor shortcut resources tied to each specific brush profile
var brush_shortcuts: Dictionary = {}

## Draws paint_layer as four buttons instead of a slider. Registered in _enter_tree().
var _inspector_plugin: EditorInspectorPlugin = null

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
	
	# Enabled only while a terrain manager is selected; see _process().
	set_process(false)

	_initialize_editor_shortcuts()
	_initialize_brush_appearance_settings()
	_create_brush_ui_panel()

	# Turns the paint_layer slider into a row of colour-tinted buttons.
	_inspector_plugin = LowPolyTerrainInspector.new()
	add_inspector_plugin(_inspector_plugin)
	
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

	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	_destroy_brush_ui_panel()

	# Both overlays live OUTSIDE this plugin node - the ring under the terrain manager, the
	# label under the editor's base control - so freeing the plugin does not take them with it.
	# Without this, disabling the plugin or reloading this @tool script leaves a stray label
	# behind in the editor UI, and another one appears on every re-enable.
	_release_active_manager()
	_destroy_3d_brush_gizmo()

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
	_release_active_manager()
	_faces_cache.clear()

	# Instantly clear UI visual fragments
	if mouse_label:
		mouse_label.visible = false

	_destroy_3d_brush_gizmo()
	_show_brush_ui_panel(false)



func _handles(object: Object) -> bool:
	return object is LowPolyTerrainManager


## Detaches from whichever manager is being edited: disconnects its signals, clears the edit
## lock and drops the reference.
##
## Shared by every path that stops editing a terrain. _on_editor_scene_changed() used to only
## null the reference, which left the previous manager wired to this plugin: switching scene
## tabs meant a manager in the background could still rescale the active one's brush, and
## _edit() could no longer reach it to disconnect, because the reference was already gone.
func _release_active_manager() -> void:
	var inspector := EditorInterface.get_inspector()
	if inspector and inspector.property_edited.is_connected(_on_inspector_property_edited):
		inspector.property_edited.disconnect(_on_inspector_property_edited)

	if active_manager and is_instance_valid(active_manager):
		if active_manager.signal_brush_settings_changed.is_connected(_on_signal_brush_settings_changed):
			active_manager.signal_brush_settings_changed.disconnect(_on_signal_brush_settings_changed)

		# Explicitly unbind the custom export signal from the previous manager instance
		if active_manager.signal_export_requested.is_connected(_open_export_dialog_from_plugin):
			active_manager.signal_export_requested.disconnect(_open_export_dialog_from_plugin)

		if active_manager.signal_shrink_confirmation_requested.is_connected(_confirm_shrink):
			active_manager.signal_shrink_confirmation_requested.disconnect(_confirm_shrink)

		active_manager.set_meta("_edit_lock_", false)
		if "is_paint_stroke_active" in active_manager:
			active_manager.is_paint_stroke_active = false

	active_manager = null
	is_drawing = false


func _edit(object: Object) -> void:
	_release_active_manager()

	if object is LowPolyTerrainManager and object.is_inside_tree():
		active_manager = object
		active_manager.set_meta("_edit_lock_", true)
		# [E3] Only rebuilds when the chunk structure is actually missing. Selecting the
		# manager no longer regenerates every chunk mesh in the world.
		active_manager.ensure_chunks_built()
		_faces_cache.clear()
		
		# [CRITICAL FIX] Force-inject the active UndoRedo manager immediately upon selection
		if active_manager.has_method("stroke_started"):
			active_manager.stroke_started(get_undo_redo())
		
		# Connect only the custom scaling/hotkey signal
		if not active_manager.signal_brush_settings_changed.is_connected(_on_signal_brush_settings_changed):
			active_manager.signal_brush_settings_changed.connect(_on_signal_brush_settings_changed)

		# Securely bridge the manager button with the isolated editor plugin UI pipeline
		if not active_manager.signal_export_requested.is_connected(_open_export_dialog_from_plugin):
			active_manager.signal_export_requested.connect(_open_export_dialog_from_plugin)

		# Applying smaller dimensions destroys terrain and cannot be undone, so it asks first.
		if not active_manager.signal_shrink_confirmation_requested.is_connected(_confirm_shrink):
			active_manager.signal_shrink_confirmation_requested.connect(_confirm_shrink)

		# Connect the inspector click hook safely
		var inspector := EditorInterface.get_inspector()
		if inspector and not inspector.property_edited.is_connected(_on_inspector_property_edited):
			inspector.property_edited.connect(_on_inspector_property_edited)
			
		_create_3d_brush_gizmo()
		_show_brush_ui_panel(true)
		_sync_ui_buttons_with_manager()

		# The pointer-left-the-viewport poll only has to run while a terrain is being edited.
		set_process(true)
		
		# [FIX] Force-update the 3D ring mesh and 2D text label to instantly match the newly selected manager
		_update_gizmo_scale()
	else:
		# _release_active_manager() already ran at the top of this function.
		if mouse_label:
			mouse_label.visible = false
			
		_destroy_3d_brush_gizmo()
		_show_brush_ui_panel(false)



func _make_visible(visible: bool) -> void:
	if not visible:
		_release_active_manager()
		_destroy_3d_brush_gizmo()
		# The toolbar was left visible here while active_manager was already null, so it kept
		# showing a depressed tool button for a terrain the plugin no longer had a handle on.
		_show_brush_ui_panel(false)



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
		
	# Events that carry the modifier update it immediately; _process() polls it as well, so a
	# bare Shift press is picked up even when no event follows.
	if event is InputEventWithModifiers:
		_set_shift_held((event as InputEventWithModifiers).shift_pressed)

	# Escape drops a pending ramp anchor. Consumed only when there is something to drop, so
	# Escape keeps its usual editor meaning the rest of the time.
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE and _ramp_anchor_set:
			_cancel_ramp()
			return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP

	# Process brush size and tool switching shortcuts inside the 3D viewport
	if event is InputEventKey and event.pressed:
		if _try_handle_brush_shortcut(event as InputEventKey):
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
			# The stroke itself is applied once per frame from _process(), NOT here. Applying
			# it per motion event meant a high polling rate mouse sculpted many times per
			# frame - every one of them at the same spot, because _update_gizmo_position() is
			# frame guarded. That was redundant work, and it tied the sculpting speed to the
			# mouse hardware instead of to the brush settings.
			# The event is still consumed, or dragging would orbit the editor camera.
			return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
			
	# Process active mouse click strokes for sculpting operations
	if event is InputEventMouseButton:
		# RAMP is a two-click operation, not a stroke. Handled before the stroke branch so it
		# never sets is_drawing and therefore never reaches the per-frame sculpting path.
		if active_manager.resolve_brush_mode(_shift_held) == LowPolyTerrainManager.BrushMode.RAMP:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				if _handle_ramp_click():
					return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
			# Right-click abandons a pending anchor rather than orbiting straight out of the
			# half-finished operation.
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and _ramp_anchor_set:
				_cancel_ramp()
				return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP
			return 0 # EditorPlugin.AFTER_GUI_INPUT_PASS

		if event.button_index == MOUSE_BUTTON_LEFT:
			is_drawing = event.pressed
			
			# [UNDO/REDO INTERCEPT] Handle stroke lifecycle management inside the editor workspace
			if is_drawing and active_manager:
				var manager_undo_redo: EditorUndoRedoManager = get_undo_redo()
				if active_manager.has_method("stroke_started"):
					active_manager.stroke_started(manager_undo_redo)

				# Seeded here, or the first held frame would measure its travel against
				# wherever the PREVIOUS stroke ended and start at full strength by accident.
				if brush_gizmo:
					_last_paint_position = brush_gizmo.global_position
			
			# When the user releases the left mouse button, reset the session cache in the manager
			# needed for FLATTEN mode where is_paint_stroke_active is set to true
			if not is_drawing:
				_end_paint_stroke()

			if is_drawing:
				_process_paint_stroke()
				return 1 # EditorPlugin.AFTER_GUI_INPUT_STOP

	return 0 # EditorPlugin.AFTER_GUI_INPUT_PASS

# New 2D label reference inside the plugin script
var mouse_label: Label = null

## Control hosting the 3D viewport. Cached because it is looked up once per frame while a
## terrain manager is selected.
var _viewport_container: Control = null


## Records the Shift modifier and refreshes the brush overlays when it actually changed.
##
## Single entry point on purpose: the poll in _process() and any event that carries the
## modifier both land here, so the ring colour and the caption cannot disagree about it.
func _set_shift_held(held: bool) -> void:
	if held == _shift_held:
		return
	_shift_held = held
	_update_gizmo_scale()


## Step the falloff moves per keypress. Matches the inspector slider's own increment, so the
## keyboard cannot reach values the slider refuses to show.
const FALLOFF_STEP: float = 0.05


## The bare keycode a mode's shortcut is bound to, or KEY_NONE when it has none.
func _shortcut_keycode(mode: int) -> int:
	var shortcut: Shortcut = brush_shortcuts.get(mode) as Shortcut
	if shortcut == null or shortcut.events.is_empty():
		return KEY_NONE
	var first: InputEventKey = shortcut.events[0] as InputEventKey
	return first.keycode if first != null else KEY_NONE


## Applies whichever brush shortcut matches the event. Returns true when one did.
##
## Shared by the two delivery paths below rather than living in either, because they differ
## only in how the event reaches the plugin, not in what it should do.
func _try_handle_brush_shortcut(event: InputEventKey) -> bool:
	if active_manager == null:
		return false

	# Shift turns the two size keys into falloff keys.
	#
	# Checked before the loop and against the bare keycode, because matches_event() compares
	# modifiers exactly: the stored shortcut carries no Shift, so a shifted press never matches
	# it and would otherwise fall through to nothing at all.
	if event.shift_pressed:
		var step: float = 0.0
		if event.keycode == _shortcut_keycode(
				LowPolyTerrainManager.BrushMode.DECREASE_BRUSH_RADIUS):
			step = -FALLOFF_STEP
		elif event.keycode == _shortcut_keycode(
				LowPolyTerrainManager.BrushMode.INCREASE_BRUSH_RADIUS):
			step = FALLOFF_STEP

		if not is_zero_approx(step):
			active_manager.brush_falloff_strength = clampf(
				active_manager.brush_falloff_strength + step, 0.0, 1.0
			)
			active_manager.notify_property_list_changed.call_deferred()
			# brush_falloff_strength emits no signal of its own, unlike brush_radius, so the
			# overlays are refreshed here rather than waiting for one.
			_update_gizmo_scale()
			return true

	for mode: int in brush_shortcuts.keys():
		var sc: Shortcut = brush_shortcuts[mode]
		if not sc.matches_event(event):
			continue

		if mode == LowPolyTerrainManager.BrushMode.DECREASE_BRUSH_RADIUS:
			active_manager.brush_radius = clampi(active_manager.brush_radius - 1, 1, 50)
			active_manager.notify_property_list_changed.call_deferred()
			return true
		elif mode == LowPolyTerrainManager.BrushMode.INCREASE_BRUSH_RADIUS:
			active_manager.brush_radius = clampi(active_manager.brush_radius + 1, 1, 50)
			active_manager.notify_property_list_changed.call_deferred()
			return true
		elif not event.echo:
			# Auto-repeat must not re-trigger a tool switch, but it is welcome on the radius
			# keys above, where holding the key is the intended way to resize the brush.
			_select_brush_mode(mode)
			return true

	return false


## Second delivery path for the brush shortcuts, used when the 3D viewport does not hold
## keyboard focus.
##
## _forward_3d_gui_input() is driven by the viewport's gui_input, and a Control only receives
## key events while it is focused. Mouse events need no focus, so right after the editor starts
## the brush ring already tracks the cursor while every shortcut stays dead until the user
## clicks into the viewport once - which is exactly what made the radius keys look broken.
##
## Gated on the pointer being over a VISIBLE 3D viewport: the container keeps its rect while
## the Script editor is open, so without the visibility check typing a comma into a script
## would resize the brush.
func _shortcut_input(event: InputEvent) -> void:
	if active_manager == null:
		return
	if not _pointer_is_over_viewport():
		return

	# Also here, not only in _forward_3d_gui_input(): key events reach the viewport only while
	# it holds keyboard focus, and this path does not depend on that.
	if event is InputEventWithModifiers:
		_set_shift_held((event as InputEventWithModifiers).shift_pressed)

	var key_event: InputEventKey = event as InputEventKey
	if key_event == null or not key_event.pressed:
		return

	if _try_handle_brush_shortcut(key_event):
		get_viewport().set_input_as_handled()


## True while the pointer sits over a 3D viewport that is actually on screen.
func _pointer_is_over_viewport() -> bool:
	var container: Control = _get_viewport_container()
	if container == null or not container.is_visible_in_tree():
		return false
	return container.get_global_rect().has_point(container.get_global_mouse_position())


## Resolves the Control the 3D viewport is drawn into, so the plugin can tell whether the
## mouse is still over it.
func _get_viewport_container() -> Control:
	if is_instance_valid(_viewport_container):
		return _viewport_container
	var sub_viewport: SubViewport = EditorInterface.get_editor_viewport_3d(0)
	if sub_viewport == null:
		return null
	_viewport_container = sub_viewport.get_parent() as Control
	return _viewport_container


## Hides the brush ring and its label the moment the pointer leaves the 3D viewport.
##
## Both are only ever refreshed from _forward_3d_gui_input(), which stops receiving events
## as soon as the mouse moves into the Inspector or any other dock. Without this poll the ring
## simply freezes in place and the label keeps floating over unrelated editor UI, offset from
## the cursor. Polling rather than the Control's mouse_exited signal, because that also fires
## when moving onto a child control such as the viewport toolbar, which would make the brush
## flicker.
func _process(_delta: float) -> void:
	if active_manager == null:
		return

	if not _pointer_is_over_viewport():
		_hide_brush_visuals()
		return

	# Polled rather than read off an event. A bare modifier press does not reliably arrive as
	# a key event in the viewport, so the event-driven version only noticed Shift once the
	# mouse moved and something carried shift_pressed along. Gated on the pointer being over
	# the viewport, so holding Shift while typing elsewhere leaves the brush alone.
	_set_shift_held(Input.is_key_pressed(KEY_SHIFT))

	_drive_held_paint_stroke()
	_refresh_layer_swatches_if_changed()


## Keeps a held mouse button sculpting even while the cursor stays perfectly still.
##
## The stroke used to be driven purely by InputEventMouseMotion, so pressing the button applied
## the brush exactly once and then waited for the mouse to move. Holding still - the natural way
## to raise a single hill - did nothing at all.
##
## Rate is one application per frame, which is at or below what dragging already produced,
## since the motion path applies the brush per motion event rather than per frame.
func _drive_held_paint_stroke() -> void:
	if not is_drawing:
		return

	# Also the safety net for a release this plugin never saw, for instance when the button
	# came up outside the viewport: without it the stroke would silently resume on re-entry.
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_paint_stroke()
		return

	if brush_gizmo == null or not brush_gizmo.visible:
		return

	# Full strength as soon as the brush genuinely travels, softened while it rests.
	var moved: float = brush_gizmo.global_position.distance_to(_last_paint_position)
	var full_at: float = maxf(active_manager.cell_size * FULL_STRENGTH_DISTANCE_CELLS, 0.0001)
	var travelled: float = clampf(moved / full_at, 0.0, 1.0)
	_last_paint_position = brush_gizmo.global_position

	_process_paint_stroke(lerpf(HELD_STILL_STRENGTH, 1.0, travelled))


## Closes a sculpting stroke: drops the FLATTEN height lock and commits the undo action.
func _end_paint_stroke() -> void:
	is_drawing = false
	if active_manager == null:
		return

	active_manager.is_paint_stroke_active = false
	if active_manager.has_method("stroke_finished"):
		active_manager.stroke_finished()


## Hides both brush overlays. Never used to show them: the ring's visibility depends on whether
## the picking ray actually hit terrain, which only _update_gizmo_position() can decide.
func _hide_brush_visuals() -> void:
	if mouse_label and mouse_label.visible:
		mouse_label.visible = false
	if brush_gizmo and brush_gizmo.visible:
		brush_gizmo.visible = false
	# The anchor itself survives leaving the viewport; only its line stops being drawn, since
	# it would otherwise point at a cursor position that is no longer meaningful.
	if _ramp_line and _ramp_line.visible:
		_ramp_line.visible = false

## Shared setup for both brush materials: unlit, alpha blended, visible through the terrain and
## from either side, so the ring reads the same however the camera is angled.
func _new_brush_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	return mat


func _create_3d_brush_gizmo() -> void:
	if not active_manager or brush_gizmo: 
		return
	
	brush_gizmo = MeshInstance3D.new()
	brush_gizmo.name = "DEBUG_BrushGizmo_Transient"
	active_manager.add_child(brush_gizmo)
	
	# Two materials rather than one material_override, because the disc and its outline need
	# different alpha. material_override applies to every surface at once, so the split has to
	# happen through per-surface overrides; see _update_gizmo_scale().
	_brush_fill_material = _new_brush_material()
	_brush_outline_material = _new_brush_material()

	# Separate node from the ring: its endpoints move with the cursor every frame, while the
	# ring mesh only changes when a setting does. Sharing one mesh would rebuild both.
	_ramp_line = MeshInstance3D.new()
	_ramp_line.name = "DEBUG_RampLine_Transient"
	# Per-surface overrides rather than material_override, which would tint both surfaces alike
	# and defeat the split.
	_ramp_line_material = _new_brush_material()
	_ramp_flank_material = _new_brush_material()
	_ramp_line.visible = false
	active_manager.add_child(_ramp_line)

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
			
		# [FIX] Enforce hidden status on initial creation to prevent top-left corner leaks
		mouse_label.visible = false
	
	_update_gizmo_scale()


## Builds the brush caption, listing only the settings that actually reach the given mode.
##
## Deliberately not the same set for every tool. brush_strength never reaches FLATTEN, which
## interpolates towards a fixed target height, and brush_falloff_strength never reaches SMOOTH,
## which always applies the full smoothstep curve. Printing them anyway would invite tuning a
## value that does nothing.
## Static and manager-parameterised so it can be unit tested; GUT cannot instantiate an
## EditorPlugin, which is how the old caption kept its wrong tool name unnoticed.
static func _build_brush_label(
	manager: LowPolyTerrainManager,
	mode_idx: int,
	shift_held: bool
) -> String:
	if manager == null:
		return ""

	var mode_name: String = ""
	for def in BRUSH_TOOL_DEFINITIONS:
		# Check the specific Enum value from the first array slot (index 0)
		if def[0] == mode_idx:
			mode_name = def[2] as String
			break

	if shift_held:
		# Named so the caption cannot be mistaken for the toolbar selection having changed.
		mode_name += " (Shift)"

	var parts := PackedStringArray()
	parts.append("R: %d" % manager.brush_radius)

	if mode_idx == LowPolyTerrainManager.BrushMode.RAISE \
	or mode_idx == LowPolyTerrainManager.BrushMode.LOWER \
	or mode_idx == LowPolyTerrainManager.BrushMode.SMOOTH \
	or mode_idx == LowPolyTerrainManager.BrushMode.PAINT:
		parts.append("S: %.2f" % manager.brush_strength)

	# RAMP belongs here too: it shapes the corridor edges with the very same curve, even though
	# it takes its heights from the terrain rather than from brush_strength.
	if mode_idx == LowPolyTerrainManager.BrushMode.RAISE \
	or mode_idx == LowPolyTerrainManager.BrushMode.LOWER \
	or mode_idx == LowPolyTerrainManager.BrushMode.FLATTEN \
	or mode_idx == LowPolyTerrainManager.BrushMode.RAMP \
	or mode_idx == LowPolyTerrainManager.BrushMode.PAINT:
		parts.append("F: %.2f" % manager.brush_falloff_strength)

	# Which layer is about to be deposited is the one thing PAINT cannot be read off the ring.
	if mode_idx == LowPolyTerrainManager.BrushMode.PAINT:
		parts.append("L: %d" % manager.paint_layer)

	return "%s\n%s" % [mode_name, " | ".join(parts)]



## The colour the brush ring is drawn in for a given tool.
##
## PAINT is the exception: a fixed tool colour there would say nothing about WHICH of the four
## layers the next stroke deposits, which is the one thing the ring cannot otherwise show. The
## configured layer colour is used instead, at the tool colour's opacity.
func _brush_color_for(mode_idx: int) -> Color:
	var fallback: Color = BRUSH_COLORS[mode_idx] if BRUSH_COLORS.has(mode_idx) else FallBackColor
	if mode_idx != LowPolyTerrainManager.BrushMode.PAINT or active_manager == null:
		return fallback

	var layer: Color = active_manager.get_paint_layer_color(active_manager.paint_layer)
	return Color(layer.r, layer.g, layer.b, fallback.a)


func _update_gizmo_scale() -> void:
	if not brush_gizmo or not active_manager: 
		return
	
	var ring_mesh: MeshInstance3D = brush_gizmo
	# The mode the stroke would actually perform right now, Shift included. Using tool_mode
	# here left the ring green and captioned "Activate Chunk" while Shift was deactivating.
	var mode_idx: int = active_manager.resolve_brush_mode(_shift_held)
	var current_radius: float = float(active_manager.brush_radius) * active_manager.cell_size

	var tool_color: Color = _brush_color_for(mode_idx)

	# The outline carries the colour, the disc only hints at the area. Splitting the alpha this
	# way is what makes the terrain under the brush readable while sculpting it.
	if _brush_outline_material:
		_brush_outline_material.albedo_color = Color(
			tool_color.r, tool_color.g, tool_color.b,
			_brush_opacity(SETTING_OUTLINE_ALPHA, BRUSH_OUTLINE_ALPHA)
		)
	if _brush_fill_material:
		_brush_fill_material.albedo_color = Color(
			tool_color.r, tool_color.g, tool_color.b,
			_brush_opacity(SETTING_FILL_ALPHA, BRUSH_FILL_ALPHA)
		)

	if mouse_label:
		mouse_label.text = _build_brush_label(active_manager, mode_idx, _shift_held)

	# The ramp preview is built from brush_radius and brush_falloff_strength, so it belongs to
	# this refresh too. Hanging it off mouse motion alone left it stale until the cursor moved.
	_update_ramp_line()

	var plane_y: float = 0.03
	var center_vertex := Vector3(0.0, plane_y, 0.0)

	var fill := SurfaceTool.new()
	fill.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := SurfaceTool.new()
	outline.begin(Mesh.PRIMITIVE_LINE_STRIP)

	for i in range(BRUSH_RING_SEGMENTS):
		var theta0: float = (float(i) / float(BRUSH_RING_SEGMENTS)) * TAU
		var theta1: float = (float(i + 1) / float(BRUSH_RING_SEGMENTS)) * TAU

		var p0 := Vector3(sin(theta0) * current_radius, plane_y, cos(theta0) * current_radius)
		var p1 := Vector3(sin(theta1) * current_radius, plane_y, cos(theta1) * current_radius)

		fill.add_vertex(center_vertex)
		fill.add_vertex(p0)
		fill.add_vertex(p1)

		outline.add_vertex(p0)

	# Repeat the first point so the line strip closes instead of leaving a gap.
	outline.add_vertex(Vector3(0.0, plane_y, current_radius))

	# Surface 0 is the disc, surface 1 the outline. Committed in that order because the
	# per-surface material overrides below address them by index.
	var mesh: ArrayMesh = fill.commit()
	outline.commit(mesh)
	ring_mesh.mesh = mesh
	ring_mesh.set_surface_override_material(0, _brush_fill_material)
	ring_mesh.set_surface_override_material(1, _brush_outline_material)





func _destroy_3d_brush_gizmo() -> void:
	# Nothing left to watch over once the overlays are gone.
	set_process(false)

	if brush_gizmo:
		if brush_gizmo.get_parent():
			brush_gizmo.get_parent().remove_child(brush_gizmo)
		brush_gizmo.free()
		brush_gizmo = null

	if _ramp_line:
		if _ramp_line.get_parent():
			_ramp_line.get_parent().remove_child(_ramp_line)
		_ramp_line.free()
		_ramp_line = null
	_ramp_anchor_set = false

	# Dropped with the instance they belonged to; _create_3d_brush_gizmo() makes fresh ones.
	_brush_fill_material = null
	_brush_outline_material = null
	_ramp_line_material = null
	_ramp_flank_material = null

	if mouse_label:
		if mouse_label.get_parent():
			mouse_label.get_parent().remove_child(mouse_label)
		mouse_label.free()
		mouse_label = null


# [E2] De-indexed triangle soup per chunk, keyed by coordinate. ArrayMesh.get_faces() allocates
# a full copy of the geometry on every call, and the picking loop used to call it for every
# ray-crossed chunk on every single mouse motion event.
var _faces_cache: Dictionary = {}

# [E2] Frame guard: high polling-rate mice emit several motion events per rendered frame, and
# re-running the whole picking pass for each of them buys nothing visible.
var _last_gizmo_frame: int = -1

# Reused across frames so the picking pass allocates nothing per call.
var _terrain_pick: Dictionary = {}


## Casts a mouse ray against the terrain and places the brush gizmo on the nearest hit.
func _update_gizmo_position(camera: Camera3D, mouse_pos: Vector2) -> void:
	if not brush_gizmo or not active_manager:
		return

	var current_frame: int = Engine.get_process_frames()
	if current_frame == _last_gizmo_frame:
		return
	_last_gizmo_frame = current_frame

	var ray_origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(mouse_pos)
	
	# The terrain pass lives in LowPolyTerrainPicking so it can be unit tested; GUT cannot
	# instantiate an EditorPlugin. Cache and result dictionary are passed in and reused, so
	# this allocates nothing per frame.
	var found_hit: bool = LowPolyTerrainPicking.raycast_terrain(
		active_manager, ray_origin, ray_dir, _faces_cache, _terrain_pick
	)
	var closest_hit: float = float(_terrain_pick["distance"])
	var world_hit_point: Vector3 = _terrain_pick["point"]

	# The SERVERS backend draws deactivated chunks without any pickable geometry, so their
	# flat preview plane is intersected analytically instead. In MESH_NODES the clickable red
	# quads still exist as real meshes and were already covered by the loop above.
	if active_manager.terrain_backend == LowPolyTerrainManager.TerrainBackend.SERVERS:
		var pick: Dictionary = LowPolyTerrainPicking.pick_deactivated_chunk(
			active_manager, ray_origin, ray_dir
		)
		if bool(pick["hit"]) and float(pick["distance"]) < closest_hit:
			world_hit_point = pick["point"]
			found_hit = true

	if found_hit:
		brush_gizmo.visible = true
		brush_gizmo.global_position = world_hit_point
	else:
		brush_gizmo.visible = false

	# The span follows the cursor, so it is redrawn wherever the ring moves. Frame guarded
	# along with the pick above, not per motion event.
	_update_ramp_line()


## Handles one click for the two-click ramp tool. Returns true when the click was consumed.
func _handle_ramp_click() -> bool:
	if active_manager == null or brush_gizmo == null or not brush_gizmo.visible:
		return false

	if not _ramp_anchor_set:
		_ramp_anchor = brush_gizmo.global_position
		_ramp_anchor_set = true
		_update_ramp_line()
		return true

	active_manager.apply_ramp(_ramp_anchor, brush_gizmo.global_position)
	_cancel_ramp()
	return true


## Drops a pending first click. Also the exit for Escape, right-click and any tool change, so
## an anchor can never survive into a context where the next click would mean something else.
func _cancel_ramp() -> void:
	if not _ramp_anchor_set:
		return
	_ramp_anchor_set = false
	if _ramp_line:
		_ramp_line.visible = false


## Redraws the surface the ramp would leave behind, from the anchor to the cursor.
##
## A thin line only showed WHERE the ramp would run, not what it would do. The manager builds
## the mesh through the same evaluation the tool writes with, so the width follows brush_radius
## and the edges show how brush_falloff_strength feathers them into the ground.
##
## Built in the manager's local space and parented to it, so a moved, rotated or scaled terrain
## needs no special casing here.
func _update_ramp_line() -> void:
	if _ramp_line == null or active_manager == null:
		return

	if not _ramp_anchor_set or brush_gizmo == null or not brush_gizmo.visible:
		_ramp_line.visible = false
		return

	var preview: ArrayMesh = active_manager.build_ramp_preview_mesh(
		_ramp_anchor, brush_gizmo.global_position
	)
	if preview == null:
		_ramp_line.visible = false
		return

	_ramp_line.mesh = preview

	if _ramp_line_material:
		var tool_color: Color = BRUSH_COLORS[LowPolyTerrainManager.BrushMode.RAMP]
		_ramp_line_material.albedo_color = Color(
			tool_color.r, tool_color.g, tool_color.b, RAMP_PREVIEW_ALPHA
		)
	if _ramp_flank_material:
		_ramp_flank_material.albedo_color = RAMP_FLANK_COLOR

	# Surface 0 is the top by construction. The flanks are absent when the ramp lands on ground
	# it already matches, so the second override is only assigned when there is one.
	_ramp_line.set_surface_override_material(0, _ramp_line_material)
	if preview.get_surface_count() > 1:
		_ramp_line.set_surface_override_material(1, _ramp_flank_material)

	_ramp_line.visible = true


## Applies the brush exactly once, at wherever the ring currently sits.
##
## Takes no camera or mouse position: the ring is placed by _update_gizmo_position() and its
## world position IS the brush position. The two arguments this used to carry were never read.
func _process_paint_stroke(strength_scale: float = 1.0) -> void:
	if active_manager == null:
		return
	if brush_gizmo and brush_gizmo.visible:
		active_manager.interact_at_world_position(
			brush_gizmo.global_position, _shift_held, strength_scale
		)


## Target handler fired when custom hotkeys or script calls update the brush properties.
func _on_signal_brush_settings_changed() -> void:
	if active_manager and brush_gizmo:
		_update_gizmo_scale()


## Publishes the two brush opacity sliders in the Editor Settings.
func _initialize_brush_appearance_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings == null:
		return
	_register_opacity_setting(settings, SETTING_FILL_ALPHA, BRUSH_FILL_ALPHA)
	_register_opacity_setting(settings, SETTING_OUTLINE_ALPHA, BRUSH_OUTLINE_ALPHA)


## Declares one 0..1 slider, leaving a value the user already chose untouched.
func _register_opacity_setting(settings: EditorSettings, path: String, fallback: float) -> void:
	if not settings.has_setting(path):
		settings.set_setting(path, fallback)

	# Makes the revert arrow return to the shipped value rather than to zero.
	settings.set_initial_value(path, fallback, false)
	settings.add_property_info({
		"name": path,
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0.0,1.0,0.01",
	})


## Reads one of the opacity settings, falling back to the shipped default.
func _brush_opacity(path: String, fallback: float) -> float:
	var settings := EditorInterface.get_editor_settings()
	if settings == null or not settings.has_setting(path):
		return fallback
	return clampf(float(settings.get_setting(path)), 0.0, 1.0)


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
		
		# Explicitly register property info metadata to tell the editor UI this is a string.
		# add_property_info(), not the 3.x-era add_custom_property_info(): that name no longer
		# exists in Godot 4.7, so the has_method() guard here silently skipped the call and the
		# shortcut settings were published without any type information at all.
		settings.add_property_info({
			"name": settings_path,
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": ""
		})

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


## Where a user assigns the brush shortcuts, shown on every button that has none.
const SHORTCUT_SETTINGS_HINT: String = \
	"No shortcut assigned.\nEditor Settings > Plugins > Low Poly Terrain Builder > Shortcuts"


## Returns a shortcut's display text, or an empty string when it is unassigned.
##
## An unassigned shortcut is NOT an empty one: _initialize_editor_shortcuts() always appends an
## InputEventKey, it just carries keycode 0. So events.is_empty() reports false and
## get_as_text() returns the literal "(unset)", which would otherwise reach the button as
## "Raise ((unset))". Such a shortcut matches no event at all, so it is only a display concern.
static func _shortcut_display_text(shortcut: Shortcut) -> String:
	if shortcut == null or shortcut.events.is_empty():
		return ""

	var first: InputEventKey = shortcut.events[0] as InputEventKey
	if first == null or first.keycode == KEY_NONE:
		return ""

	# get_as_text() spells these out, while the settings field and the viewport both show the
	# actual character.
	var text: String = shortcut.get_as_text()
	if text == "Comma":
		return ","
	if text == "Period":
		return "."
	return text


## Applies a button's caption and tooltip for the shortcut it currently carries, if any.
func _apply_shortcut_labels(btn: Button, label_text: String, mode_idx: int) -> void:
	var shortcut_text: String = _shortcut_display_text(brush_shortcuts.get(mode_idx) as Shortcut)
	if shortcut_text.is_empty():
		btn.text = label_text
		btn.tooltip_text = "%s\n%s" % [label_text, SHORTCUT_SETTINGS_HINT]
		return

	btn.text = "%s (%s)" % [label_text, shortcut_text]
	btn.tooltip_text = "%s (%s)" % [label_text, shortcut_text]


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
				
		_apply_shortcut_labels(btn, label_text, mode_idx)

		btn.pressed.connect(_on_brush_button_pressed.bind(mode_idx))
		brush_panel_container.add_child(btn)

	_create_layer_buttons()
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

	# A pending ramp anchor must not survive a tool change, or the next click would mean
	# something entirely different from what the visible line promises.
	_cancel_ramp()

	# Created on SELECTION, not on the first stroke: the layer colours are what you set up
	# before painting, and an empty inspector slot offers nothing to set up.
	if mode_idx == LowPolyTerrainManager.BrushMode.PAINT:
		active_manager.ensure_paint_material()

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

	_sync_layer_buttons()



# --- PAINT LAYER SELECTOR ---
# Sits beside the tool buttons rather than in the inspector, because the layer is a decision
# made WHILE painting: switching it should not need the cursor to leave the viewport. The
# inspector carries the same property, and the two stay in step through paint_layer itself.

## The four layer buttons, in order. Shown only while the Paint tool is active.
var _layer_buttons: Array[Button] = []
var _layer_button_group: ButtonGroup = null
var _layer_separator: VSeparator = null


## Builds the layer selector once, alongside the tool buttons.
func _create_layer_buttons() -> void:
	if brush_panel_container == null:
		return

	_layer_separator = VSeparator.new()
	brush_panel_container.add_child(_layer_separator)

	# A group of its own: these are not tools, and putting them in the tool group would let
	# picking a layer un-press the active brush.
	_layer_button_group = ButtonGroup.new()
	_layer_buttons.clear()

	for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
		var btn := Button.new()
		btn.toggle_mode = true
		btn.button_group = _layer_button_group
		btn.text = str(layer)
		btn.tooltip_text = "Paint layer %d" % layer
		# The editor theme tints button icons by state - icon_pressed_color and
		# icon_focus_color above all. On a tool glyph that reads as feedback; on a colour
		# swatch it destroys the one thing the swatch is there to show, so every state is
		# pinned to white and the texture keeps its own colour.
		for state in ["icon_normal_color", "icon_pressed_color", "icon_hover_color",
				"icon_focus_color", "icon_disabled_color", "icon_hover_pressed_color"]:
			btn.add_theme_color_override(state, Color.WHITE)
		btn.pressed.connect(_on_layer_button_pressed.bind(layer))
		brush_panel_container.add_child(btn)
		_layer_buttons.append(btn)


func _on_layer_button_pressed(layer: int) -> void:
	if active_manager == null:
		return
	active_manager.paint_layer = layer
	# The ring is tinted with the layer colour, so it has to follow immediately.
	_update_gizmo_scale()


## Shows the selector only in Paint mode, marks the active layer and tints each button with the
## colour it stands for - a number alone says nothing about what is about to be painted.
func _sync_layer_buttons() -> void:
	if active_manager == null or _layer_buttons.is_empty():
		return

	var painting: bool = active_manager.tool_mode == LowPolyTerrainManager.BrushMode.PAINT
	if _layer_separator:
		_layer_separator.visible = painting

	for i in range(_layer_buttons.size()):
		var btn: Button = _layer_buttons[i]
		btn.visible = painting
		btn.set_pressed_no_signal(active_manager.paint_layer == i + 1)
		if painting:
			btn.icon = _layer_swatch(active_manager.get_paint_layer_color(i + 1))


## Last layer colours the swatches were drawn from, to notice an edit to them.
var _layer_swatch_colors: PackedColorArray = PackedColorArray()


## Redraws the layer swatches when a layer colour was edited.
##
## Polled rather than driven by a signal: ShaderMaterial does NOT emit changed() when a shader
## parameter is set - measured, only assigning the shader itself does - so there is nothing to
## connect to. Four colour comparisons per frame, and only while the Paint tool is active.
func _refresh_layer_swatches_if_changed() -> void:
	if active_manager == null or _layer_buttons.is_empty():
		return
	if active_manager.tool_mode != LowPolyTerrainManager.BrushMode.PAINT:
		return

	var current := PackedColorArray()
	for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
		current.append(active_manager.get_paint_layer_color(layer))

	if current == _layer_swatch_colors:
		return
	_layer_swatch_colors = current

	for i in range(_layer_buttons.size()):
		_layer_buttons[i].icon = _layer_swatch(current[i])
	# The ring is tinted with the active layer, so it follows the same edit.
	_update_gizmo_scale()


## A small solid-colour texture standing in for a layer. Rebuilt per sync rather than cached,
## because the colours are inspector values that can change at any moment and the swatch is
## sixteen pixels square.
func _layer_swatch(color: Color) -> ImageTexture:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(color.r, color.g, color.b, 1.0))
	return ImageTexture.create_from_image(image)


## Automatically fired when the user modifies any configuration inside the Editor Settings.
func _on_editor_settings_changed() -> void:
	# Applied before the early return below, so dragging an opacity slider is visible at once
	# rather than only after the next brush event.
	if brush_gizmo and active_manager:
		_update_gizmo_scale()

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
					
			# Unconditional, unlike before: clearing a shortcut in the Editor Settings has to
			# drop the key from the caption too, not leave the previous one showing.
			_apply_shortcut_labels(child as Button, label_text, mode_idx)

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
		
	if BRUSH_OVERLAY_PROPERTIES.has(property_name):
		# 1. Update the 3D visual circle mesh and floating text label
		_update_gizmo_scale()

		# 2. Force the toolbar radio buttons to depress the correct tool icon instantly
		_sync_ui_buttons_with_manager()


## Opens a native editor save dialog. Safe from release build compilation errors since
## this entire script is automatically stripped by Godot during the export process.

## Asks before dimensions are applied that would drop terrain off the edge of the world.
##
## The manager raises this instead of migrating, and nothing happens unless the answer comes
## back. Shrinking has no undo entry - the migration rebuilds the whole grid - so a single
## mistyped number used to cost whatever had been sculpted out there, with only a line in the
## console to show for it.
func _confirm_shrink(lost_chunks: int) -> void:
	if active_manager == null or not is_instance_valid(active_manager):
		return

	var manager: LowPolyTerrainManager = active_manager
	var dialog := ConfirmationDialog.new()
	dialog.title = "Shrink terrain?"
	dialog.dialog_text = (
		"Applying these dimensions removes %d chunk%s from '%s'.\n\n"
		% [lost_chunks, "" if lost_chunks == 1 else "s", manager.name]
		+ "Everything sculpted, painted or deactivated out there is discarded. This can be "
		+ "undone with Ctrl+Z, but not after the scene has been closed."
	)
	dialog.ok_button_text = "Discard and shrink"
	dialog.cancel_button_text = "Keep as is"

	dialog.confirmed.connect(
		func() -> void:
			if is_instance_valid(manager):
				manager.apply_dimension_changes_confirmed()
			dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())

	var editor_base: Control = EditorInterface.get_base_control()
	if editor_base:
		editor_base.add_child(dialog)
		dialog.popup_centered()


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
	
	# The plugin iterates through the active manager's chunks via the backend-agnostic accessors
	for coord: Vector2i in active_manager.get_chunk_coords():
		if not active_manager.is_chunk_active(coord.x, coord.y):
			continue

		var chunk_mesh: ArrayMesh = active_manager.get_chunk_mesh(coord)
		if chunk_mesh == null:
			continue

		var chunk_instance := MeshInstance3D.new()
		chunk_instance.name = "Terrain_Chunk_%d_%d" % [coord.x, coord.y]
		chunk_instance.mesh = chunk_mesh

		var chunk_material: Material = active_manager.get_chunk_material(coord)
		if chunk_material != null:
			chunk_instance.material_override = chunk_material

		chunk_instance.position = active_manager.get_chunk_local_position(coord)
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
