@tool
extends EditorInspectorPlugin
class_name LowPolyTerrainInspector

## Replaces the paint_layer slider with four buttons in a row, each tinted with the colour of
## the layer it selects.
##
## A slider gives no clue what layer 3 actually looks like, and the layer colours live right
## below in paint_material - so the choice belongs next to them, not behind a number. The same
## property also has buttons in the viewport toolbar; both write paint_layer and therefore stay
## in step with each other without knowing about each other.


func _can_handle(object: Object) -> bool:
	return object is LowPolyTerrainManager


func _parse_property(
	object: Object,
	type: Variant.Type,
	name: String,
	hint_type: PropertyHint,
	hint_string: String,
	usage_flags: int,
	wide: bool
) -> bool:
	if name == "paint_layer":
		add_property_editor(name, LayerSelector.new(object as LowPolyTerrainManager))
		# True means "this property is handled here", which suppresses the default slider.
		return true

	if LowPolyTerrainManager.PAINT_SLOPE_PROPERTIES.has(name):
		add_property_editor(name, SlopeRange.new())
		return true

	return false


## The row of buttons itself.
class LayerSelector extends EditorProperty:
	var _manager: LowPolyTerrainManager = null
	var _buttons: Array[Button] = []
	var _updating: bool = false

	func _init(manager: LowPolyTerrainManager) -> void:
		_manager = manager

		var row := HBoxContainer.new()
		# Buttons of equal width, so the row reads as one control rather than four.
		row.alignment = BoxContainer.ALIGNMENT_BEGIN

		var group := ButtonGroup.new()
		for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
			var btn := Button.new()
			btn.toggle_mode = true
			btn.button_group = group
			btn.text = str(layer)
			btn.tooltip_text = "Paint layer %d" % layer
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			# The editor theme tints button icons by state - icon_pressed_color and
			# icon_focus_color above all. On a tool glyph that reads as feedback; on a colour
			# swatch it destroys the one thing the swatch is there to show, so every state is
			# pinned to white and the texture keeps its own colour.
			for state in ["icon_normal_color", "icon_pressed_color", "icon_hover_color",
					"icon_focus_color", "icon_disabled_color", "icon_hover_pressed_color"]:
				btn.add_theme_color_override(state, Color.WHITE)
			btn.pressed.connect(_on_layer_pressed.bind(layer))
			row.add_child(btn)
			_buttons.append(btn)

		add_child(row)
		# The inspector only calls _update_property() when paint_layer itself changes, so an
		# edit to a LAYER COLOUR would leave these swatches stale. ShaderMaterial emits nothing
		# on set_shader_parameter(), which leaves polling as the only way to notice.
		set_process(true)
		# Without this the row is drawn beside the property name and squeezed into half the
		# inspector width, which is exactly what makes four buttons unreadable.
		set_bottom_editor(row)

	func _on_layer_pressed(layer: int) -> void:
		if _updating:
			return
		emit_changed(get_edited_property(), layer)

	## Called by the inspector whenever the property changed, from wherever - including the
	## viewport toolbar, which is how the two selectors keep agreeing.
	func _update_property() -> void:
		var current: int = int(get_edited_object().get(get_edited_property()))

		# Guarded because set_pressed_no_signal still triggers a redraw pass that can re-enter.
		_updating = true
		for i in range(_buttons.size()):
			var btn: Button = _buttons[i]
			btn.set_pressed_no_signal(current == i + 1)
			if _manager != null:
				btn.icon = _swatch(_manager.get_paint_layer_color(i + 1))
		_updating = false

	## Last colours the swatches were built from, to notice an edit to them.
	var _swatch_colors: PackedColorArray = PackedColorArray()

	func _process(_delta: float) -> void:
		if _manager == null:
			return

		var current := PackedColorArray()
		for layer in range(1, LowPolyTerrainManager.PAINT_LAYER_COUNT + 1):
			current.append(_manager.get_paint_layer_color(layer))

		if current == _swatch_colors:
			return
		_swatch_colors = current

		for i in range(_buttons.size()):
			_buttons[i].icon = _swatch(current[i])


	## A solid square of the layer's colour, so the choice is visible rather than numbered.
	func _swatch(color: Color) -> ImageTexture:
		var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
		image.fill(Color(color.r, color.g, color.b, 1.0))
		return ImageTexture.create_from_image(image)


## A minimum and a maximum angle, drawn the way a particle material draws its ranges.
##
## Godot renders a Vector2 as an x and a y field, which says nothing about the two numbers
## meaning "from" and "to". Its own paired editor for exactly this - the one in the particle
## process material - lives in C++ as ParticleProcessMaterialMinMaxPropertyEditor and is not
## exposed to scripts, so the bar is rebuilt here: a span with two handles above two spin
## sliders, all three kept in step.
class SlopeRange extends EditorProperty:
	const RANGE_MIN: float = 0.0
	const RANGE_MAX: float = 90.0
	## Height of the range bar. Sized for grabbing with a mouse rather than for looking slim -
	## a thin strip is easy to draw and hard to hit.
	const BAR_HEIGHT: int = 20

	## Width of a handle. Widened along with the bar so the two stay in proportion, and so the
	## grab area is a comfortable square rather than a sliver.
	const HANDLE_WIDTH: float = 8.0

	var _bar: Control = null
	var _low: EditorSpinSlider = null
	var _high: EditorSpinSlider = null
	var _updating: bool = false
	var _dragging_high: bool = false
	var _dragging: bool = false

	func _init() -> void:
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 2)

		_bar = Control.new()
		_bar.custom_minimum_size = Vector2(0, BAR_HEIGHT)
		_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_bar.draw.connect(_draw_bar)
		_bar.gui_input.connect(_on_bar_input)
		column.add_child(_bar)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_low = _make_slider("Min")
		_high = _make_slider("Max")
		row.add_child(_low)
		row.add_child(_high)
		column.add_child(row)

		add_child(column)
		# Full inspector width. Beside the property name the bar and two sliders would share
		# half a column, and none of the three would be usable.
		set_bottom_editor(column)

	func _make_slider(caption: String) -> EditorSpinSlider:
		var slider := EditorSpinSlider.new()
		slider.min_value = RANGE_MIN
		slider.max_value = RANGE_MAX
		slider.step = 0.5
		slider.label = caption
		slider.suffix = "\u00b0"
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(_on_slider_changed)
		return slider

	## Keeps the pair ordered. Whichever handle was moved wins, and the other gives way, so a
	## range can never be turned inside out by dragging past the other end.
	func _order(low: float, high: float, moved_high: bool) -> Vector2:
		if low <= high:
			return Vector2(low, high)
		return Vector2(high, high) if moved_high else Vector2(low, low)

	func _commit(low: float, high: float, moved_high: bool) -> void:
		var ordered: Vector2 = _order(low, high, moved_high)
		emit_changed(get_edited_property(), ordered)
		_apply(ordered)

	func _on_slider_changed(_value: float) -> void:
		# Guarded: _apply() writes the sliders, which fires this again mid-drag.
		if _updating:
			return
		_commit(_low.value, _high.value, not is_equal_approx(_high.value, _current().y))

	func _current() -> Vector2:
		return get_edited_object().get(get_edited_property())

	func _apply(value: Vector2) -> void:
		_updating = true
		_low.value = value.x
		_high.value = value.y
		_updating = false
		if _bar:
			_bar.queue_redraw()

	func _update_property() -> void:
		_apply(_current())

	## Position of an angle along the bar, in pixels.
	func _to_pixels(angle: float) -> float:
		var span: float = maxf(RANGE_MAX - RANGE_MIN, 0.001)
		return (angle - RANGE_MIN) / span * _bar.size.x

	func _to_angle(pixels: float) -> float:
		var span: float = maxf(_bar.size.x, 1.0)
		return snappedf(
			clampf(pixels / span, 0.0, 1.0) * (RANGE_MAX - RANGE_MIN) + RANGE_MIN, 0.5
		)

	func _draw_bar() -> void:
		var theme := EditorInterface.get_editor_theme()
		var track: Color = Color(0.0, 0.0, 0.0, 0.35)
		var accent: Color = Color(0.4, 0.6, 1.0)
		if theme:
			accent = theme.get_color("accent_color", "Editor")

		var height: float = float(BAR_HEIGHT)
		_bar.draw_rect(Rect2(0.0, 0.0, _bar.size.x, height), track)

		var value: Vector2 = _current()
		var left: float = _to_pixels(value.x)
		var right: float = _to_pixels(value.y)
		_bar.draw_rect(Rect2(left, 0.0, maxf(right - left, 1.0), height), accent)

		# The handles, drawn last so they stay visible on top of the span they bound.
		var handle: Color = accent.lightened(0.4)
		for x: float in [left, right]:
			_bar.draw_rect(
				Rect2(x - HANDLE_WIDTH * 0.5, 0.0, HANDLE_WIDTH, height), handle
			)

	func _on_bar_input(event: InputEvent) -> void:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button != null and button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				var value: Vector2 = _current()
				# Grab whichever end is nearer, so a click acts on what was aimed at.
				_dragging_high = absf(button.position.x - _to_pixels(value.y)) \
					< absf(button.position.x - _to_pixels(value.x))
				_dragging = true
				_drag_to(button.position.x)
			else:
				_dragging = false
			return

		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		if motion != null and _dragging:
			_drag_to(motion.position.x)

	func _drag_to(pixels: float) -> void:
		var angle: float = _to_angle(pixels)
		var value: Vector2 = _current()
		if _dragging_high:
			_commit(value.x, angle, true)
		else:
			_commit(angle, value.y, false)
