class_name EditorUI
extends CanvasLayer
## The level editor's panels (LevelEditor makes one). Everything goes through the editor's
## public methods, so the UI holds no level state of its own.
##   top bar     file (new, save, load), undo / redo, gizmo tool and axes, snapping, grid,
##               level settings, playtest, exit
##   left        Catalog: search + category filter + every LevelCatalog item (click to place);
##               Outliner: every object in the level (click / Shift / Ctrl to select)
##   right       Inspector: label, position, rotation, size or scale, material, properties
##   bottom      status line and the controls
##   dialogs     save, load, level settings, playtest

const TOP_HEIGHT := 52.0
const BOTTOM_HEIGHT := 34.0
const SIDE_WIDTH := 330.0
const SMALL := 15
const NORMAL := 17
const CATEGORY_ALL := "All"
const HINT := "WASD Q/E fly · RMB look · V select · B place · 1 2 3 transform · Ctrl+G group · Tab/F5 playtest"

var editor: Node3D

var _root: Control
var _panels: Array[Control] = []
var _status: Label
var _catalog: ItemList
var _search: LineEdit
var _category: String = CATEGORY_ALL
var _category_buttons: Dictionary = {}
var _category_dropdown: OptionButton
var _catalog_container: VBoxContainer
var _outliner_container: VBoxContainer
var _tab_catalog_btn: Button
var _tab_outliner_btn: Button
var _outliner: ItemList
var _syncing: bool = false
var _select_tool_btn: Button
var _place_tool_btn: Button
var _tool_buttons: Array[Button] = []
var _space_button: Button
var _pos_snap: OptionButton
var _rot_snap: OptionButton
var _undo_button: Button
var _redo_button: Button
var _level_label: Label
# inspector
var _inspector: VBoxContainer
var _insp_title: Label
var _insp_kind: Label
var _insp_label: LineEdit
var _insp_pos: Array[SpinBox] = []
var _insp_rot: Array[SpinBox] = []
var _insp_size: Array[SpinBox] = []
var _size_row: Control
var _insp_scale: SpinBox
var _scale_row: Control
var _insp_material: OptionButton
var _material_row: Control
var _props_box: VBoxContainer
var _props_for: String = ""
var _events_box: VBoxContainer
var _empty_hint: Label
var _detail: VBoxContainer
# dialogs
var _save_dialog: PanelContainer
var _save_name: LineEdit
var _load_dialog: PanelContainer
var _load_list: ItemList
var _settings_dialog: PanelContainer
var _settings_controls: Dictionary = {}
var _playtest_dialog: PanelContainer
var _playtest_rules: OptionButton
var _playtest_bots: SpinBox
var _playtest_at_camera: CheckBox
var _materials: Array[String] = []


func _ready() -> void:
	layer = 15
	_materials = LevelGeometry.material_ids()
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = _theme()
	add_child(_root)
	_build_top_bar()
	_build_left()
	_build_inspector()
	_build_bottom()
	_build_save_dialog()
	_build_load_dialog()
	_build_settings_dialog()
	_build_playtest_dialog()
	editor.selection_changed.connect(_refresh_selection)
	editor.level_changed.connect(_refresh_level)
	editor.tool_changed.connect(_refresh_tool)
	editor.status_changed.connect(func(text: String) -> void: _status.text = text)
	_fill_catalog()
	_refresh_level()
	_refresh_selection()


## The cursor is over a panel or an open dialog (clicks there aren't for the 3D view).
func is_over_ui(mouse: Vector2) -> bool:
	for panel in _panels:
		if panel.is_visible_in_tree() and panel.get_global_rect().has_point(mouse):
			return true
	return false


func any_dialog_open() -> bool:
	for dialog: Control in [_save_dialog, _load_dialog, _settings_dialog, _playtest_dialog]:
		if dialog.visible:
			return true
	return false


# ------------------------------------------------------------------ building


func _theme() -> Theme:
	var theme := MenuTheme.build()
	theme.default_font_size = NORMAL
	for kind: StringName in [&"Button", &"OptionButton", &"CheckButton", &"CheckBox"]:
		theme.set_stylebox(&"normal", kind, MenuTheme.box(MenuTheme.BUTTON, MenuTheme.RIM.darkened(0.4), 1, 6))
		theme.set_stylebox(&"hover", kind, MenuTheme.box(MenuTheme.BUTTON_HOVER, MenuTheme.RIM, 1, 6))
		theme.set_stylebox(&"pressed", kind, MenuTheme.box(MenuTheme.ACCENT.darkened(0.55), MenuTheme.ACCENT, 1, 6))
		theme.set_stylebox(&"focus", kind, MenuTheme.box(Color(0, 0, 0, 0), MenuTheme.ACCENT, 1, 6))
		theme.set_stylebox(&"disabled", kind, MenuTheme.box(MenuTheme.BUTTON.darkened(0.3), MenuTheme.RIM.darkened(0.7), 1, 6))
	theme.set_stylebox(&"panel", &"PanelContainer", MenuTheme.box(MenuTheme.PANEL, MenuTheme.RIM, 1, 8))
	theme.set_stylebox(&"normal", &"LineEdit", MenuTheme.box(MenuTheme.BG, MenuTheme.RIM.darkened(0.3), 1, 4))
	theme.set_stylebox(&"focus", &"LineEdit", MenuTheme.box(MenuTheme.BG, MenuTheme.ACCENT, 1, 4))
	theme.set_stylebox(&"panel", &"ItemList", MenuTheme.box(MenuTheme.BG, MenuTheme.RIM.darkened(0.3), 1, 4))
	theme.set_constant(&"v_separation", &"ItemList", 4)
	theme.set_color(&"font_color", &"CheckBox", MenuTheme.TEXT)
	return theme


func _panel(name_: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = name_
	_root.add_child(panel)
	_panels.append(panel)
	return panel


## Anchors (left, top, right, bottom) and the offsets from them, set explicitly (the anchor
## presets keep the control's current rect, which is still empty while building).
static func _place(control: Control, anchors: Vector4, offsets: Vector4) -> void:
	control.anchor_left = anchors.x
	control.anchor_top = anchors.y
	control.anchor_right = anchors.z
	control.anchor_bottom = anchors.w
	control.offset_left = offsets.x
	control.offset_top = offsets.y
	control.offset_right = offsets.z
	control.offset_bottom = offsets.w


func _label(text: String, size: int = NORMAL, color: Color = MenuTheme.TEXT) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", size)
	label.add_theme_color_override(&"font_color", color)
	return label


func _button(text: String, action: Callable, tooltip: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


func _build_top_bar() -> void:
	var bar := _panel("TopBar")
	_place(bar, Vector4(0.0, 0.0, 1.0, 0.0), Vector4(0.0, 0.0, 0.0, TOP_HEIGHT))
	var main_row := HBoxContainer.new()
	main_row.add_theme_constant_override(&"separation", 6)
	bar.add_child(main_row)

	# Left: Title & Level Name
	main_row.add_child(_label("LEVEL EDITOR", 18, MenuTheme.ACCENT))
	_level_label = _label("", SMALL - 1, MenuTheme.TEXT_DIM)
	_level_label.custom_minimum_size = Vector2(80.0, 0.0)
	_level_label.clip_text = true
	main_row.add_child(_level_label)
	main_row.add_child(VSeparator.new())

	# Center: Horizontally scrollable toolbar so every button is always accessible
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_row.add_child(scroll)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 5)
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	scroll.add_child(row)

	# File
	row.add_child(_button("New", _confirm_new, "Start an empty level"))
	row.add_child(_button("Save", open_save_dialog, "Save (Ctrl+S)"))
	row.add_child(_button("Load", open_load_dialog, "Open a saved level"))
	row.add_child(VSeparator.new())

	# History
	_undo_button = _button("Undo", editor.undo, "Ctrl+Z")
	_redo_button = _button("Redo", editor.redo, "Ctrl+Y / Ctrl+Shift+Z")
	row.add_child(_undo_button)
	row.add_child(_redo_button)
	row.add_child(VSeparator.new())

	# Tool modes
	_select_tool_btn = _button("Select (V)", func() -> void: editor.set_tool(LevelEditor.Tool.SELECT), "Select mode (V / Esc)")
	_select_tool_btn.toggle_mode = true
	row.add_child(_select_tool_btn)
	_place_tool_btn = _button("Place (B)", func() -> void: editor.set_tool(LevelEditor.Tool.PLACE), "Place mode (B)")
	_place_tool_btn.toggle_mode = true
	row.add_child(_place_tool_btn)
	row.add_child(VSeparator.new())

	# Gizmos
	var tools := [["Move", "1"], ["Rotate", "2"], ["Resize", "3"]]
	for i in tools.size():
		var button := _button("%s %s" % [tools[i][1], tools[i][0]], editor.set_gizmo_mode.bind(i), "%s tool (%s)" % [tools[i][0], tools[i][1]])
		button.toggle_mode = true
		row.add_child(button)
		_tool_buttons.append(button)
	_space_button = _button("World", editor.toggle_local_space, "Gizmo axes: world or local (L)")
	row.add_child(_space_button)
	row.add_child(VSeparator.new())

	# Snapping
	row.add_child(_label("Snap", SMALL - 1, MenuTheme.TEXT_DIM))
	_pos_snap = OptionButton.new()
	_pos_snap.focus_mode = Control.FOCUS_NONE
	_pos_snap.tooltip_text = "Position snap"
	for value in LevelEditor.SNAP_POS_OPTIONS:
		_pos_snap.add_item("off" if value <= 0.0 else "%s m" % _trim(value))
	_pos_snap.item_selected.connect(editor.set_pos_snap_index)
	row.add_child(_pos_snap)
	_rot_snap = OptionButton.new()
	_rot_snap.focus_mode = Control.FOCUS_NONE
	_rot_snap.tooltip_text = "Rotation snap"
	for value in LevelEditor.SNAP_ROT_OPTIONS:
		_rot_snap.add_item("off" if value <= 0.0 else "%d°" % int(value))
	_rot_snap.item_selected.connect(editor.set_rot_snap_index)
	row.add_child(_rot_snap)
	row.add_child(_button("Grid", editor.toggle_grid, "Toggle grid (G)"))
	row.add_child(VSeparator.new())

	# Assemblies
	row.add_child(_button("Group", editor.group_selected, "Group selection into Assembly (Ctrl+G)"))
	row.add_child(_button("Ungroup", editor.ungroup_selected, "Ungroup Assembly (Ctrl+Shift+G)"))
	row.add_child(VSeparator.new())

	# Operations
	row.add_child(_button("Bake Nav", editor.bake_navmesh, "Bake dynamic AI navigation mesh"))
	row.add_child(_button("Settings", open_settings_dialog, "Level environment & settings"))

	# Right: Pinned Playtest & Exit
	main_row.add_child(VSeparator.new())
	var play := _button("Playtest (Tab)", open_playtest_dialog, "Play this level (Tab / F5)")
	play.add_theme_color_override(&"font_color", MenuTheme.ACCENT)
	main_row.add_child(play)
	main_row.add_child(_button("Exit", editor.exit_to_menu, "Back to the main menu (save first)"))


func _build_left() -> void:
	var panel := _panel("LeftPanel")
	_place(panel, Vector4(0.0, 0.0, 0.0, 1.0), Vector4(0.0, TOP_HEIGHT + 4.0, SIDE_WIDTH, -BOTTOM_HEIGHT - 4.0))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 6)
	panel.add_child(column)

	# Tab switcher: Catalog vs Outliner
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override(&"separation", 4)
	column.add_child(tab_row)

	var tab_group := ButtonGroup.new()
	_tab_catalog_btn = _button("Catalog", func() -> void: _switch_left_tab(false))
	_tab_catalog_btn.toggle_mode = true
	_tab_catalog_btn.button_group = tab_group
	_tab_catalog_btn.button_pressed = true
	_tab_catalog_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.add_child(_tab_catalog_btn)

	_tab_outliner_btn = _button("Outliner", func() -> void: _switch_left_tab(true))
	_tab_outliner_btn.toggle_mode = true
	_tab_outliner_btn.button_group = tab_group
	_tab_outliner_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.add_child(_tab_outliner_btn)

	# --- CATALOG CONTAINER ---
	_catalog_container = VBoxContainer.new()
	_catalog_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_catalog_container.add_theme_constant_override(&"separation", 6)
	column.add_child(_catalog_container)

	_search = LineEdit.new()
	_search.placeholder_text = "Search everything…"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _fill_catalog())
	_catalog_container.add_child(_search)

	# Clean single-line Category Dropdown
	var cat_row := HBoxContainer.new()
	cat_row.add_theme_constant_override(&"separation", 6)
	_catalog_container.add_child(cat_row)
	cat_row.add_child(_label("Category", SMALL - 1, MenuTheme.TEXT_DIM))
	_category_dropdown = OptionButton.new()
	_category_dropdown.focus_mode = Control.FOCUS_NONE
	_category_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cats := [CATEGORY_ALL] + LevelCatalog.get_categories()
	for i in cats.size():
		var cat_name: String = cats[i]
		_category_dropdown.add_item(cat_name)
		_category_dropdown.set_item_metadata(i, cat_name)
	_category_dropdown.item_selected.connect(func(idx: int) -> void:
		_pick_category(str(_category_dropdown.get_item_metadata(idx)))
	)
	cat_row.add_child(_category_dropdown)

	# Full height catalog item list
	_catalog = ItemList.new()
	_catalog.name = "Catalog"
	_catalog.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_catalog.add_theme_font_size_override(&"font_size", SMALL)
	_catalog.item_clicked.connect(_on_catalog_clicked)
	_catalog_container.add_child(_catalog)

	# --- OUTLINER CONTAINER ---
	_outliner_container = VBoxContainer.new()
	_outliner_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outliner_container.add_theme_constant_override(&"separation", 6)
	_outliner_container.visible = false
	column.add_child(_outliner_container)

	var header := HBoxContainer.new()
	var count := _label("0 objects", SMALL, MenuTheme.TEXT_DIM)
	count.name = "Count"
	count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(count)
	_outliner_container.add_child(header)

	# Full height outliner list
	_outliner = ItemList.new()
	_outliner.name = "Outliner"
	_outliner.select_mode = ItemList.SELECT_MULTI
	_outliner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outliner.add_theme_font_size_override(&"font_size", SMALL)
	_outliner.multi_selected.connect(func(_i: int, _s: bool) -> void: _outliner_changed.call_deferred())
	_outliner.item_activated.connect(func(_i: int) -> void: editor.focus_selection())
	_outliner_container.add_child(_outliner)

	var outliner_actions := HBoxContainer.new()
	outliner_actions.add_theme_constant_override(&"separation", 6)
	var focus_btn := _button("Focus (F)", editor.focus_selection, "Center camera on selection")
	focus_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outliner_actions.add_child(focus_btn)
	var del_btn := _button("Delete", editor.delete_selected, "Delete selection (Del)")
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.add_theme_color_override(&"font_color", MenuTheme.DANGER.lightened(0.3))
	outliner_actions.add_child(del_btn)
	_outliner_container.add_child(outliner_actions)

	_pick_category(CATEGORY_ALL)


func _switch_left_tab(show_outliner: bool) -> void:
	if _catalog_container != null:
		_catalog_container.visible = not show_outliner
	if _outliner_container != null:
		_outliner_container.visible = show_outliner
	if _tab_catalog_btn != null:
		_tab_catalog_btn.set_pressed_no_signal(not show_outliner)
	if _tab_outliner_btn != null:
		_tab_outliner_btn.set_pressed_no_signal(show_outliner)


func _build_inspector() -> void:
	var panel := _panel("Inspector")
	_place(panel, Vector4(1.0, 0.0, 1.0, 1.0), Vector4(-SIDE_WIDTH, TOP_HEIGHT + 4.0, 0.0, -BOTTOM_HEIGHT - 4.0))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override(&"separation", 6)
	scroll.add_child(_inspector)
	_inspector.add_child(_label("INSPECTOR", NORMAL, MenuTheme.ACCENT))
	_empty_hint = _label("Nothing selected.\n\nPick something in the catalog and click in the world to place it, or click an object to select it.", SMALL, MenuTheme.TEXT_DIM)
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector.add_child(_empty_hint)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override(&"separation", 6)
	_inspector.add_child(_detail)
	_insp_title = _label("", NORMAL)
	_insp_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_child(_insp_title)
	_insp_kind = _label("", SMALL - 1, MenuTheme.TEXT_DIM)
	_insp_kind.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_child(_insp_kind)
	_insp_label = LineEdit.new()
	_insp_label.placeholder_text = "Label (optional)"
	_insp_label.text_submitted.connect(func(t: String) -> void:
		editor.set_object_label(t)
		_insp_label.release_focus())
	_insp_label.focus_exited.connect(func() -> void:
		if editor.get_selected_object() != null:
			editor.set_object_label(_insp_label.text))
	_detail.add_child(_insp_label)
	_insp_pos = _vector_row("Position", -2000.0, 2000.0, 0.01, _on_position)
	_insp_rot = _vector_row("Rotation °", -360.0, 360.0, 0.1, _on_rotation)
	_insp_size = _vector_row("Size", LevelShapes.MIN_SIZE, 500.0, 0.01, _on_size)
	_size_row = _insp_size[0].get_parent().get_parent()
	_scale_row = HBoxContainer.new()
	_scale_row.add_child(_field_label("Scale"))
	_insp_scale = _spin(0.05, 50.0, 0.01)
	_insp_scale.value_changed.connect(func(v: float) -> void: if not _syncing: editor.set_object_scale(v))
	_scale_row.add_child(_insp_scale)
	_detail.add_child(_scale_row)
	_material_row = VBoxContainer.new()
	_material_row.add_child(_field_label("Material"))
	_insp_material = OptionButton.new()
	_insp_material.focus_mode = Control.FOCUS_NONE
	_insp_material.fit_to_longest_item = false
	for id in _materials:
		_insp_material.add_item(id.trim_prefix("mat_").replace("_", " "))
	_insp_material.item_selected.connect(func(i: int) -> void: if not _syncing: editor.set_object_material(_materials[i]))
	_material_row.add_child(_insp_material)
	_detail.add_child(_material_row)
	_props_box = VBoxContainer.new()
	_props_box.add_theme_constant_override(&"separation", 4)
	_detail.add_child(_props_box)
	_events_box = VBoxContainer.new()
	_events_box.add_theme_constant_override(&"separation", 6)
	_detail.add_child(_events_box)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override(&"h_separation", 4)
	actions.add_theme_constant_override(&"v_separation", 4)
	actions.add_child(_button("Duplicate", editor.duplicate_selected, "Ctrl+D"))
	actions.add_child(_button("Copy", editor.copy_selected, "Ctrl+C"))
	actions.add_child(_button("Focus", editor.focus_selection, "F"))
	var delete := _button("Delete", editor.delete_selected, "Del")
	delete.add_theme_color_override(&"font_color", MenuTheme.DANGER.lightened(0.3))
	actions.add_child(delete)
	_detail.add_child(actions)


func _field_label(text: String) -> Label:
	var label := _label(text, SMALL, MenuTheme.TEXT_DIM)
	label.custom_minimum_size = Vector2(70.0, 0.0)
	return label


func _spin(low: float, high: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.custom_arrow_step = 0.25 if step < 0.1 else step
	spin.select_all_on_focus = true
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.add_theme_font_size_override(&"font_size", SMALL)
	spin.get_line_edit().add_theme_font_size_override(&"font_size", SMALL)
	return spin


## "Label" then X / Y / Z spin boxes; on_change gets the whole vector.
func _vector_row(text: String, low: float, high: float, step: float, on_change: Callable) -> Array[SpinBox]:
	var block := VBoxContainer.new()
	block.add_child(_field_label(text))
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 3)
	block.add_child(row)
	var spins: Array[SpinBox] = []
	var axes := ["X", "Y", "Z"]
	for i in 3:
		var spin := _spin(low, high, step)
		spin.prefix = axes[i]
		spin.value_changed.connect(func(_v: float) -> void:
			if not _syncing:
				on_change.call(Vector3(spins[0].value, spins[1].value, spins[2].value)))
		row.add_child(spin)
		spins.append(spin)
	_detail.add_child(block)
	return spins


func _build_bottom() -> void:
	var bar := _panel("BottomBar")
	_place(bar, Vector4(0.0, 1.0, 1.0, 1.0), Vector4(0.0, -BOTTOM_HEIGHT, 0.0, 0.0))
	var row := HBoxContainer.new()
	bar.add_child(row)
	_status = _label("", SMALL, MenuTheme.ACCENT)
	_status.custom_minimum_size = Vector2(520.0, 0.0)
	_status.clip_text = true
	row.add_child(_status)
	var hint := _label(HINT, SMALL - 2, MenuTheme.TEXT_DIM)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.clip_text = true
	row.add_child(hint)


func _dialog(name_: String, title: String, width: float) -> VBoxContainer:
	var panel := _panel(name_)
	_place(panel, Vector4(0.5, 0.5, 0.5, 0.5), Vector4(-width * 0.5, 0.0, width * 0.5, 0.0))
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.visible = false
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	panel.add_child(column)
	column.add_child(_label(title, 22, MenuTheme.ACCENT))
	return column


func _dialog_buttons(column: VBoxContainer, ok_text: String, on_ok: Callable, panel: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override(&"separation", 8)
	row.add_child(_button("Cancel", func() -> void: panel.visible = false))
	var ok := _button(ok_text, on_ok)
	ok.add_theme_color_override(&"font_color", MenuTheme.ACCENT)
	row.add_child(ok)
	column.add_child(row)
	return row


func _build_save_dialog() -> void:
	var column := _dialog("SaveDialog", "Save Level", 480.0)
	_save_dialog = column.get_parent() as PanelContainer
	column.add_child(_label("Name (also its map name in Bot Arena and LAN):", SMALL, MenuTheme.TEXT_DIM))
	_save_name = LineEdit.new()
	_save_name.text_submitted.connect(func(_t: String) -> void: _do_save())
	column.add_child(_save_name)
	_dialog_buttons(column, "Save", _do_save, _save_dialog)


func _build_load_dialog() -> void:
	var column := _dialog("LoadDialog", "Load Level", 480.0)
	_load_dialog = column.get_parent() as PanelContainer
	_load_list = ItemList.new()
	_load_list.custom_minimum_size = Vector2(0.0, 300.0)
	_load_list.item_activated.connect(func(_i: int) -> void: _do_load())
	column.add_child(_load_list)
	_dialog_buttons(column, "Load", _do_load, _load_dialog)


func _build_settings_dialog() -> void:
	var column := _dialog("SettingsDialog", "Level Settings", 560.0)
	_settings_dialog = column.get_parent() as PanelContainer
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override(&"h_separation", 12)
	grid.add_theme_constant_override(&"v_separation", 8)
	column.add_child(grid)
	var env := OptionButton.new()
	for key: String in LevelData.ENVIRONMENTS:
		env.add_item(key.capitalize())
	env.item_selected.connect(func(i: int) -> void:
		editor.set_setting("environment", LevelData.ENVIRONMENTS.keys()[i]))
	_setting_row(grid, "Sky / lighting", "environment", env)
	_setting_spin(grid, "Sun direction °", "sun_yaw", -360.0, 360.0, 1.0)
	_setting_spin(grid, "Sun height °", "sun_pitch", -90.0, 0.0, 1.0)
	_setting_spin(grid, "Sun strength", "sun_energy", 0.0, 4.0, 0.05)
	_setting_check(grid, "Ground slab", "ground")
	_setting_spin(grid, "Ground size (m)", "ground_size", 4.0, 2000.0, 1.0)
	var ground_mat := OptionButton.new()
	for id in _materials:
		ground_mat.add_item(id.trim_prefix("mat_").replace("_", " "))
	ground_mat.item_selected.connect(func(i: int) -> void: editor.set_setting("ground_material", _materials[i]))
	_setting_row(grid, "Ground material", "ground_material", ground_mat)
	_setting_spin(grid, "Kill height (m)", "kill_height", -500.0, 100.0, 1.0)
	_setting_check(grid, "Placed enemies in matches", "enemies_in_matches")
	_setting_spin(grid, "Enemy squad respawn (s, 0 = never)", "enemy_respawn", 0.0, 600.0, 5.0)
	var description := LineEdit.new()
	description.placeholder_text = "Shown nowhere yet: notes for yourself"
	description.text_changed.connect(func(t: String) -> void: editor.settings["description"] = t)
	_setting_row(grid, "Description", "description", description)
	var note := _label("Placed enemies always fight in a playtest. In Horde, waves replace them.", SMALL - 1, MenuTheme.TEXT_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_child(_button("Done", func() -> void: _settings_dialog.visible = false))
	column.add_child(row)


func _setting_row(grid: GridContainer, text: String, key: String, control: Control) -> void:
	grid.add_child(_label(text, SMALL, MenuTheme.TEXT_DIM))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.focus_mode = Control.FOCUS_CLICK if control is LineEdit or control is SpinBox else Control.FOCUS_NONE
	grid.add_child(control)
	_settings_controls[key] = control


func _setting_spin(grid: GridContainer, text: String, key: String, low: float, high: float, step: float) -> void:
	var spin := _spin(low, high, step)
	spin.value_changed.connect(func(v: float) -> void: if not _syncing: editor.set_setting(key, v))
	_setting_row(grid, text, key, spin)


func _setting_check(grid: GridContainer, text: String, key: String) -> void:
	var check := CheckBox.new()
	check.toggled.connect(func(on: bool) -> void: if not _syncing: editor.set_setting(key, on))
	_setting_row(grid, text, key, check)


func _build_playtest_dialog() -> void:
	var column := _dialog("PlaytestDialog", "Playtest", 460.0)
	_playtest_dialog = column.get_parent() as PanelContainer
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override(&"h_separation", 12)
	grid.add_theme_constant_override(&"v_separation", 8)
	column.add_child(grid)
	grid.add_child(_label("Rules", SMALL, MenuTheme.TEXT_DIM))
	_playtest_rules = OptionButton.new()
	for id in GameModes.ids():
		_playtest_rules.add_item(GameModes.name_of(id))
		_playtest_rules.set_item_metadata(_playtest_rules.item_count - 1, id)
	_playtest_rules.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_playtest_rules)
	grid.add_child(_label("Bots", SMALL, MenuTheme.TEXT_DIM))
	_playtest_bots = _spin(0.0, 7.0, 1.0)
	_playtest_bots.allow_greater = false
	_playtest_bots.allow_lesser = false
	_playtest_bots.value = 0.0
	grid.add_child(_playtest_bots)
	grid.add_child(_label("Start where the camera is", SMALL, MenuTheme.TEXT_DIM))
	_playtest_at_camera = CheckBox.new()
	_playtest_at_camera.button_pressed = true
	grid.add_child(_playtest_at_camera)
	var note := _label("Everything is live: pickups, lifts, kill volumes, placed enemies, bots. Pause > Back to Editor, or F5, returns here with your camera and selection.", SMALL - 1, MenuTheme.TEXT_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	_dialog_buttons(column, "Play", _do_playtest, _playtest_dialog)


# ------------------------------------------------------------------ dialogs


func open_save_dialog() -> void:
	close_dialogs()
	_save_name.text = editor.level_name
	_save_dialog.visible = true
	_save_name.grab_focus()
	_save_name.select_all()


func open_load_dialog() -> void:
	close_dialogs()
	_load_list.clear()
	for level_name in editor.get_saved_level_names():
		_load_list.add_item(level_name)
	if _load_list.item_count == 0:
		_load_list.add_item("(no saved levels yet)")
		_load_list.set_item_disabled(0, true)
	_load_dialog.visible = true


func open_settings_dialog() -> void:
	close_dialogs()
	_refresh_settings()
	_settings_dialog.visible = true


## Settings dialog controls show the level's current settings.
func _refresh_settings() -> void:
	_syncing = true
	var settings: Dictionary = editor.settings
	for key: String in _settings_controls:
		var control: Control = _settings_controls[key]
		var value: Variant = settings.get(key)
		if control is SpinBox:
			(control as SpinBox).set_value_no_signal(float(value))
		elif control is CheckBox:
			(control as CheckBox).set_pressed_no_signal(bool(value))
		elif control is LineEdit:
			(control as LineEdit).text = str(value)
		elif control is OptionButton:
			var option := control as OptionButton
			if key == "environment":
				option.select(maxi(LevelData.ENVIRONMENTS.keys().find(str(value)), 0))
			else:
				option.select(maxi(_materials.find(str(value)), 0))
	_syncing = false


func open_playtest_dialog() -> void:
	if _playtest_dialog.visible:
		_do_playtest()
		return
	close_dialogs()
	_playtest_dialog.visible = true


func close_dialogs() -> void:
	for dialog: Control in [_save_dialog, _load_dialog, _settings_dialog, _playtest_dialog]:
		dialog.visible = false


func _do_save() -> void:
	if editor.save_level(_save_name.text):
		_save_dialog.visible = false
		_refresh_level()


func _do_load() -> void:
	var picked := _load_list.get_selected_items()
	if picked.is_empty() or _load_list.is_item_disabled(picked[0]):
		return
	if editor.load_level(_load_list.get_item_text(picked[0])):
		_load_dialog.visible = false


func _do_playtest() -> void:
	_playtest_dialog.visible = false
	var rules := str(_playtest_rules.get_item_metadata(_playtest_rules.selected))
	editor.start_playtest(rules, int(_playtest_bots.value), _playtest_at_camera.button_pressed)


func _confirm_new() -> void:
	editor.new_level()


# ------------------------------------------------------------------ catalog / outliner


func _pick_category(category: String) -> void:
	_category = category
	if _category_dropdown != null:
		for i in _category_dropdown.item_count:
			if str(_category_dropdown.get_item_metadata(i)) == category:
				_category_dropdown.select(i)
				break
	for key: String in _category_buttons:
		(_category_buttons[key] as Button).set_pressed_no_signal(key == category)
	_fill_catalog()


func _fill_catalog() -> void:
	if _catalog == null:
		return
	_catalog.clear()
	var query := _search.text.strip_edges().to_lower() if _search != null else ""
	for item in LevelCatalog.get_items():
		if query == "" and _category != CATEGORY_ALL and item.category != _category:
			continue
		var text := "%s" % item.name
		if query != "" and not (text.to_lower().contains(query) or str(item.id).to_lower().contains(query)):
			continue
		var shown := text if _category != CATEGORY_ALL or query != "" else "%s  ·  %s" % [text, item.category]
		var index := _catalog.add_item(shown)
		_catalog.set_item_metadata(index, item.id)
		_catalog.set_item_tooltip(index, "%s\n%s" % [item.name, item.get("path", item.id)])


func _on_catalog_clicked(index: int, _at: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_LEFT:
		editor.start_place(str(_catalog.get_item_metadata(index)))


func _refresh_level() -> void:
	if _outliner == null:
		return
	_syncing = true
	_outliner.clear()
	var objects: Array[Node3D] = editor.get_objects()
	for node in objects:
		var index := _outliner.add_item(str(node.get_meta(&"display_name", node.name)))
		_outliner.set_item_metadata(index, int(node.get_meta(&"uid", 0)))
		_outliner.set_item_tooltip(index, str(node.get_meta(&"catalog_id", "")))
	var header_count := _find_count()
	if header_count != null:
		header_count.text = "%d objects" % objects.size()
	_level_label.text = editor.level_name
	_undo_button.disabled = not editor.history.can_undo()
	_redo_button.disabled = not editor.history.can_redo()
	_syncing = false
	_sync_outliner_selection()


func _find_count() -> Label:
	return _root.find_child("Count", true, false) as Label


func _outliner_changed() -> void:
	if _syncing:
		return
	var nodes: Array[Node3D] = []
	for index in _outliner.get_selected_items():
		var node: Node3D = editor.find_by_uid(int(_outliner.get_item_metadata(index)))
		if node != null:
			nodes.append(node)
	if nodes.is_empty():
		editor.deselect_object()
		return
	editor.select_object(nodes[0])
	for i in range(1, nodes.size()):
		editor.select_object(nodes[i], true)


func _sync_outliner_selection() -> void:
	_syncing = true
	_outliner.deselect_all()
	var uids := {}
	for node in editor.get_selection():
		uids[int(node.get_meta(&"uid", 0))] = true
	for i in _outliner.item_count:
		if uids.has(int(_outliner.get_item_metadata(i))):
			_outliner.select(i, false)
			_outliner.ensure_current_is_visible()
	_syncing = false


# ------------------------------------------------------------------ inspector


func _refresh_tool(_t: LevelEditor.Tool = LevelEditor.Tool.SELECT) -> void:
	if _select_tool_btn != null:
		_select_tool_btn.set_pressed_no_signal(editor.tool == LevelEditor.Tool.SELECT)
	if _place_tool_btn != null:
		_place_tool_btn.set_pressed_no_signal(editor.tool == LevelEditor.Tool.PLACE)
	if editor != null and editor.tool == LevelEditor.Tool.PLACE:
		_switch_left_tab(false)


func _refresh_selection() -> void:
	if _detail == null:
		return
	_sync_outliner_selection()
	_syncing = true
	_refresh_tool()
	for i in _tool_buttons.size():
		_tool_buttons[i].set_pressed_no_signal(editor.get_gizmo().mode == i)
	_space_button.text = "Local" if editor.get_gizmo().local_space else "World"
	_pos_snap.select(editor.get_pos_snap_index())
	_rot_snap.select(editor.get_rot_snap_index())
	_undo_button.disabled = not editor.history.can_undo()
	_redo_button.disabled = not editor.history.can_redo()
	var selection: Array[Node3D] = editor.get_selection()
	var node: Node3D = editor.get_selected_object()
	_empty_hint.visible = node == null
	_detail.visible = node != null
	if node == null:
		_syncing = false
		return
	var id := str(node.get_meta(&"catalog_id", ""))
	var item := LevelCatalog.get_item(id)
	if selection.size() > 1:
		_insp_title.text = "%d objects" % selection.size()
		_insp_kind.text = "Position etc. show the first one; Material, Delete, Duplicate and Copy act on all of them."
	else:
		_insp_title.text = str(node.get_meta(&"display_name", item.get("name", id)))
		_insp_kind.text = "%s · %s" % [item.get("category", ""), item.get("name", id)]
	if not _insp_label.has_focus():
		var label := str(node.get_meta(&"display_name", ""))
		_insp_label.text = label if label != str(item.get("name", "")) else ""
	_set_spins(_insp_pos, node.position)
	_set_spins(_insp_rot, node.rotation_degrees)
	var resizable: bool = node.has_meta(&"size")
	_size_row.visible = resizable
	if resizable:
		_set_spins(_insp_size, node.get_meta(&"size"))
	var scalable := bool(item.get("scalable", false))
	_scale_row.visible = scalable
	if scalable and not _insp_scale.get_line_edit().has_focus():
		_insp_scale.set_value_no_signal(node.scale.x)
	_material_row.visible = node is LevelGeometry
	if node is LevelGeometry:
		_insp_material.select(maxi(_materials.find((node as LevelGeometry).material_id), 0))
	_refresh_props(node, item)
	_refresh_events(node, item)
	_syncing = false


func _set_spins(spins: Array[SpinBox], value: Vector3) -> void:
	for i in 3:
		if not spins[i].get_line_edit().has_focus():
			spins[i].set_value_no_signal(snappedf(value[i], 0.001))


## Property editors for the object's props (rebuilt only when the object changes).
func _refresh_props(node: Node3D, item: Dictionary) -> void:
	var props: Dictionary = node.get_meta(&"props", {})
	var key_for := "%d:%s" % [int(node.get_meta(&"uid", 0)), ",".join(PackedStringArray(props.keys()))]
	if key_for == _props_for:
		for key: String in props:
			var control := _props_box.find_child("Prop_" + key, true, false)
			if control is SpinBox and not (control as SpinBox).get_line_edit().has_focus():
				(control as SpinBox).set_value_no_signal(float(props[key]))
			elif control is CheckBox:
				(control as CheckBox).set_pressed_no_signal(bool(props[key]))
		return
	_props_for = key_for
	for child in _props_box.get_children():
		child.queue_free()
	if props.is_empty():
		return
	_props_box.add_child(_field_label("Properties"))
	var defaults: Dictionary = item.get("props", {})
	for key: String in props:
		var row := HBoxContainer.new()
		var label := _label(key.capitalize(), SMALL, MenuTheme.TEXT_DIM)
		label.custom_minimum_size = Vector2(140.0, 0.0)
		row.add_child(label)
		var value: Variant = props[key]
		if value is bool:
			var check := CheckBox.new()
			check.name = "Prop_" + key
			check.button_pressed = value
			check.toggled.connect(func(on: bool) -> void: editor.set_object_prop(key, on))
			row.add_child(check)
		else:
			var whole := defaults.get(key) is int
			var spin := _spin(0.0, 1000.0, 1.0 if whole else 0.05)
			spin.name = "Prop_" + key
			spin.allow_lesser = false
			spin.value = float(value)
			spin.value_changed.connect(func(v: float) -> void:
				editor.set_object_prop(key, int(v) if whole else v))
			row.add_child(spin)
		_props_box.add_child(row)


func _on_position(value: Vector3) -> void:
	editor.set_object_position(value)


func _on_rotation(value: Vector3) -> void:
	editor.set_object_rotation(value)


func _on_size(value: Vector3) -> void:
	editor.set_object_size(value)


static func _trim(value: float) -> String:
	var text := "%.2f" % value
	return text.rstrip("0").rstrip(".")


func _refresh_events(node: Node3D, _item: Dictionary) -> void:
	if _events_box == null:
		return
	for child in _events_box.get_children():
		child.queue_free()

	if node == null:
		return

	var is_logic: bool = node.has_meta(&"logic_node") or node.has_method(&"get_output_signals") or node.has_method(&"get_input_actions")
	if not is_logic:
		return

	var out_signals: Array = []
	if node.has_method(&"get_output_signals"):
		out_signals = node.call(&"get_output_signals")

	var in_actions: Array = []
	if node.has_method(&"get_input_actions"):
		in_actions = node.call(&"get_input_actions")

	var my_uid_str := str(node.get_meta(&"uid", ""))

	_events_box.add_child(_field_label("Logic & Event Wires"))

	# Existing Connections List
	var conns: Array[Dictionary] = editor.get_event_connections_for_node(node)
	if not conns.is_empty():
		for conn in conns:
			var row := HBoxContainer.new()
			row.add_theme_constant_override(&"separation", 4)
			var is_out: bool = str(conn.get("source_uid")) == my_uid_str
			var other_uid_str: String = str(conn.get("target_uid") if is_out else conn.get("source_uid"))
			var other_node: Node3D = editor.find_by_uid(int(other_uid_str))
			var other_name: String = str(other_node.get_meta(&"display_name", "Node #" + other_uid_str)) if other_node != null else "UID " + other_uid_str

			var desc: String
			if is_out:
				desc = "⚡ %s → %s: %s" % [conn.get("signal_name"), other_name, conn.get("target_action")]
			else:
				desc = "⮐ %s: %s → %s" % [other_name, conn.get("signal_name"), conn.get("target_action")]

			var label := _label(desc, SMALL - 1, MenuTheme.TEXT if is_out else MenuTheme.TEXT_DIM)
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.clip_text = true
			row.add_child(label)

			var del_idx: int = int(conn.get("_index", -1))
			var del_btn := _button("✕", func() -> void:
				editor.remove_event_connection(del_idx)
			, "Delete connection wire")
			del_btn.custom_minimum_size = Vector2(24.0, 20.0)
			del_btn.add_theme_color_override(&"font_color", MenuTheme.DANGER.lightened(0.3))
			row.add_child(del_btn)
			_events_box.add_child(row)

	# Add Connection Form (if this node can emit signals)
	if not out_signals.is_empty():
		var targets: Array[Node3D] = editor.get_available_logic_targets(node)
		if not targets.is_empty():
			var form_box := VBoxContainer.new()
			form_box.add_theme_constant_override(&"separation", 4)

			var header := _label("Connect Wire", SMALL - 1, MenuTheme.ACCENT)
			form_box.add_child(header)

			# Signal selector
			var sig_row := HBoxContainer.new()
			var sig_lbl := _label("Signal", SMALL - 1, MenuTheme.TEXT_DIM)
			sig_lbl.custom_minimum_size = Vector2(50.0, 0.0)
			sig_row.add_child(sig_lbl)
			var sig_opt := OptionButton.new()
			sig_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sig_opt.focus_mode = Control.FOCUS_NONE
			for s in out_signals:
				sig_opt.add_item(str(s))
			sig_row.add_child(sig_opt)
			form_box.add_child(sig_row)

			# Target selector
			var tgt_row := HBoxContainer.new()
			var tgt_lbl := _label("Target", SMALL - 1, MenuTheme.TEXT_DIM)
			tgt_lbl.custom_minimum_size = Vector2(50.0, 0.0)
			tgt_row.add_child(tgt_lbl)
			var tgt_opt := OptionButton.new()
			tgt_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tgt_opt.focus_mode = Control.FOCUS_NONE
			for i in targets.size():
				var t_node := targets[i]
				var t_name := str(t_node.get_meta(&"display_name", t_node.name))
				var t_uid := int(t_node.get_meta(&"uid", 0))
				tgt_opt.add_item("%s (#%d)" % [t_name, t_uid])
				tgt_opt.set_item_metadata(i, t_node)
			tgt_row.add_child(tgt_opt)
			form_box.add_child(tgt_row)

			# Action selector
			var act_row := HBoxContainer.new()
			var act_lbl := _label("Action", SMALL - 1, MenuTheme.TEXT_DIM)
			act_lbl.custom_minimum_size = Vector2(50.0, 0.0)
			act_row.add_child(act_lbl)
			var act_opt := OptionButton.new()
			act_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			act_opt.focus_mode = Control.FOCUS_NONE
			act_row.add_child(act_opt)
			form_box.add_child(act_row)

			var update_actions := func() -> void:
				act_opt.clear()
				var sel_idx := tgt_opt.selected
				if sel_idx < 0 or sel_idx >= targets.size():
					return
				var chosen_t: Node3D = tgt_opt.get_item_metadata(sel_idx) as Node3D
				if chosen_t != null and chosen_t.has_method(&"get_input_actions"):
					var acts: Array = chosen_t.call(&"get_input_actions")
					for a in acts:
						act_opt.add_item(str(a))
				elif chosen_t != null:
					act_opt.add_item("trigger")

			tgt_opt.item_selected.connect(func(_i: int) -> void: update_actions.call())
			update_actions.call()

			# Connect Button
			var btn := _button("+ Connect Wire", func() -> void:
				if sig_opt.selected < 0 or tgt_opt.selected < 0 or act_opt.selected < 0:
					return
				var chosen_sig: String = sig_opt.get_item_text(sig_opt.selected)
				var chosen_t: Node3D = tgt_opt.get_item_metadata(tgt_opt.selected) as Node3D
				if chosen_t == null:
					return
				var chosen_act: String = act_opt.get_item_text(act_opt.selected)
				editor.add_event_connection(int(node.get_meta(&"uid")), chosen_sig, int(chosen_t.get_meta(&"uid")), chosen_act)
			)
			btn.add_theme_color_override(&"font_color", MenuTheme.ACCENT)
			form_box.add_child(btn)

			_events_box.add_child(form_box)
