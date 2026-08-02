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
	if name != "paint_layer":
		return false

	add_property_editor(name, LayerSelector.new(object as LowPolyTerrainManager))
	# True means "this property is handled here", which suppresses the default slider.
	return true


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
