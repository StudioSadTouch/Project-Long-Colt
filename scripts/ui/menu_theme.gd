class_name MenuTheme
extends RefCounted
## Halo 2-era military UI built from code (Theme + StyleBoxFlat, no textures): dark steel
## panels with a thin cyan-steel rim, chunky square buttons that light amber on focus, all-caps
## condensed labels. Shared by the main menu and the in-match MatchUI.

const BG := Color(0.035, 0.045, 0.055, 0.94)
const PANEL := Color(0.07, 0.09, 0.105, 0.92)
const RIM := Color(0.35, 0.55, 0.62, 0.9)
const TEXT := Color(0.78, 0.86, 0.9)
const TEXT_DIM := Color(0.5, 0.58, 0.62)
const ACCENT := Color(0.95, 0.68, 0.2)
const BUTTON := Color(0.11, 0.14, 0.16, 0.95)
const BUTTON_HOVER := Color(0.16, 0.2, 0.22, 0.95)
const DANGER := Color(0.75, 0.2, 0.15)
const FONT_SIZE := 22
const TITLE_SIZE := 56
const HEADER_SIZE := 30


static func box(fill: Color, rim: Color, border: int = 2, pad: int = 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = rim
	style.set_border_width_all(border)
	style.set_corner_radius_all(0)
	style.content_margin_left = pad * 1.5
	style.content_margin_right = pad * 1.5
	style.content_margin_top = pad * 0.6
	style.content_margin_bottom = pad * 0.6
	# Halo 2 bevel: one chamfered corner.
	style.corner_detail = 1
	style.corner_radius_top_right = 10
	return style


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = FONT_SIZE
	for kind: StringName in [&"Button", &"OptionButton", &"CheckButton", &"ColorPickerButton"]:
		theme.set_stylebox(&"normal", kind, box(BUTTON, RIM.darkened(0.4)))
		theme.set_stylebox(&"hover", kind, box(BUTTON_HOVER, RIM))
		theme.set_stylebox(&"pressed", kind, box(ACCENT.darkened(0.55), ACCENT))
		theme.set_stylebox(&"focus", kind, box(Color(0, 0, 0, 0), ACCENT, 3))
		theme.set_stylebox(&"disabled", kind, box(BUTTON.darkened(0.3), RIM.darkened(0.7)))
		theme.set_color(&"font_color", kind, TEXT)
		theme.set_color(&"font_hover_color", kind, Color.WHITE)
		theme.set_color(&"font_focus_color", kind, ACCENT)
		theme.set_color(&"font_pressed_color", kind, ACCENT)
		theme.set_color(&"font_disabled_color", kind, TEXT_DIM)
	theme.set_stylebox(&"panel", &"PanelContainer", box(PANEL, RIM, 2, 18))
	theme.set_stylebox(&"panel", &"Panel", box(PANEL, RIM, 2, 18))
	theme.set_color(&"font_color", &"Label", TEXT)
	theme.set_stylebox(&"normal", &"LineEdit", box(BG, RIM.darkened(0.3)))
	theme.set_stylebox(&"focus", &"LineEdit", box(BG, ACCENT, 3))
	theme.set_color(&"font_color", &"LineEdit", Color.WHITE)
	theme.set_color(&"caret_color", &"LineEdit", ACCENT)
	var slider_track := box(BG, RIM.darkened(0.3), 1, 4)
	theme.set_stylebox(&"slider", &"HSlider", slider_track)
	theme.set_stylebox(&"grabber_area", &"HSlider", box(RIM.darkened(0.2), RIM, 1, 4))
	theme.set_stylebox(
		&"grabber_area_highlight", &"HSlider", box(ACCENT.darkened(0.2), ACCENT, 1, 4)
	)
	theme.set_stylebox(&"panel", &"ItemList", box(BG, RIM.darkened(0.3)))
	theme.set_stylebox(&"focus", &"ItemList", box(Color(0, 0, 0, 0), ACCENT, 3))
	theme.set_stylebox(&"selected", &"ItemList", box(ACCENT.darkened(0.6), ACCENT, 1, 4))
	theme.set_stylebox(&"selected_focus", &"ItemList", box(ACCENT.darkened(0.5), ACCENT, 1, 4))
	theme.set_color(&"font_color", &"ItemList", TEXT)
	theme.set_color(&"font_selected_color", &"ItemList", Color.WHITE)
	return theme


static func label(text: String, size: int = FONT_SIZE, color: Color = TEXT) -> Label:
	var node := Label.new()
	node.text = text.to_upper()
	node.add_theme_font_size_override(&"font_size", size)
	node.add_theme_color_override(&"font_color", color)
	return node


static func button(text: String, action: Callable) -> Button:
	var node := Button.new()
	node.text = text.to_upper()
	node.custom_minimum_size = Vector2(360, 52)
	node.focus_mode = Control.FOCUS_ALL
	node.pressed.connect(action)
	return node


## Labelled HSlider row with a live readout, added to `parent`. Returns the slider.
static func slider(parent: Control, text: String, low: float, high: float, value: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	var name_label := label(text, 20)
	name_label.custom_minimum_size = Vector2(320, 0)
	row.add_child(name_label)
	var node := HSlider.new()
	node.min_value = low
	node.max_value = high
	node.step = 0.05
	node.value = value
	node.custom_minimum_size = Vector2(360, 32)
	node.focus_mode = Control.FOCUS_ALL
	row.add_child(node)
	var readout := label("%.2f" % value, 20, ACCENT)
	node.value_changed.connect(func(v: float) -> void: readout.text = "%.2f" % v)
	row.add_child(readout)
	parent.add_child(row)
	return node
