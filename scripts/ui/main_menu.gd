extends Control
## Main menu (run/main_scene): Bot Arena (map, difficulty), LAN (host with map and bot fill /
## join from the discovered list or a typed IP / lobby, where the host can still change the
## map), Settings (look, aim assist, FOV, armor colour with a 3D preview, keybinds) and Quit, plus the
## player name. Maps come from MapList; the last pick is Settings.map_id. Built in code on MenuTheme. Pad and keyboard navigable via
## ui_* focus; Esc / B / Start goes back a page. Everything persists through the Settings
## autoload (user://settings.cfg).

enum Page { MAIN, BOTS, LAN, LOBBY, SETTINGS, KEYBINDS }

var _pages: Dictionary = {}
var _page: Page = Page.MAIN
var _status: Label
var _now_playing: Label
var _name_edit: LineEdit
var _servers: ItemList
var _server_data: Array = []
var _ip_edit: LineEdit
var _bot_fill: CheckButton
var _bot_refill: CheckButton
var _lobby_list: VBoxContainer
var _lobby_start: Button
var _lobby_title: Label
var _lobby_map: OptionButton
var _lobby_map_label: Label
var _host_map: OptionButton
var _bots_map: OptionButton
var _preview: ArmorPreview
var _swatches: Array[Button] = []
var _visor_swatches: Array[Button] = []
## Settings colour tabs: 0 = armor, 1 = visor (which grid shows, what the custom picker edits).
var _colour_tab: int = 0
var _colour_grids: Array = []
var _colour_tabs: Array[Button] = []
var _colour_picker: ColorPickerButton
## Keybinds page: action -> Array[Button] (one per Keybinds.SLOTS).
var _bind_buttons: Dictionary = {}
var _bind_status: Label
## Waiting for an input to bind: {"action": String, "slot": int}; empty when not capturing.
var _capture: Dictionary = {}
var _first_focus: Dictionary = {}


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	theme = MenuTheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = MenuTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 96)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 24)
	margin.add_child(column)
	column.add_child(MenuTheme.label("Project Long Colt", MenuTheme.TITLE_SIZE, MenuTheme.ACCENT))
	_status = MenuTheme.label("", 20, MenuTheme.TEXT_DIM)
	column.add_child(_status)
	_now_playing = MenuTheme.label("Sanctuary OS  ·  Dusqk", 16, MenuTheme.TEXT_DIM)
	column.add_child(_now_playing)
	_show_track(Music.title)
	Music.track_changed.connect(_show_track)
	var holder := Control.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(holder)
	_pages[Page.MAIN] = _build_main()
	_pages[Page.BOTS] = _build_bots()
	_pages[Page.LAN] = _build_lan()
	_pages[Page.LOBBY] = _build_lobby()
	_pages[Page.SETTINGS] = _build_settings()
	_pages[Page.KEYBINDS] = _build_keybinds()
	for page: int in _pages:
		holder.add_child(_pages[page])
	Net.players_changed.connect(_refresh_lobby)
	Net.joined.connect(_on_joined)
	Net.join_failed.connect(_on_join_failed)
	Net.session_ended.connect(_on_session_ended)
	Net.servers_changed.connect(_on_servers_changed)
	if Net.last_end_reason != "":
		_status.text = Net.last_end_reason.to_upper()
		Net.last_end_reason = ""
	_show(Page.MAIN)


func _unhandled_input(event: InputEvent) -> void:
	var back := event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"action_pause")
	if not back or _page == Page.MAIN:
		return
	get_viewport().set_input_as_handled()
	_back()


func _back() -> void:
	match _page:
		Page.LOBBY:
			Net.leave()
			_show(Page.LAN)
		Page.SETTINGS:
			Settings.save_settings()
			Net.update_my_info()
			_show(Page.MAIN)
		Page.KEYBINDS:
			_end_capture()
			Settings.save_settings()
			_show(Page.SETTINGS)
		_:
			_show(Page.MAIN)


func _show(page: Page) -> void:
	_page = page
	for key: int in _pages:
		(_pages[key] as Control).visible = key == page
	if page == Page.LAN:
		Net.discovery.start_listening()
		_on_servers_changed(Net.discovery.get_servers())
	elif page != Page.LOBBY:
		Net.discovery.stop_listening()
	if page == Page.LOBBY:
		_refresh_lobby()
	var focus: Control = _first_focus.get(page)
	if focus != null:
		focus.grab_focus.call_deferred()


func _column(page: Page) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.set_meta(&"page", page)
	return column


func _add_first(page: Page, parent: Control, node: Control) -> Control:
	parent.add_child(node)
	if not _first_focus.has(page):
		_first_focus[page] = node
	return node


# ------------------------------------------------------------------ pages


func _build_main() -> Control:
	var column := _column(Page.MAIN)
	_add_first(Page.MAIN, column, MenuTheme.button("Bot Arena", _show.bind(Page.BOTS)))
	column.add_child(MenuTheme.button("LAN", _show.bind(Page.LAN)))
	column.add_child(MenuTheme.button("Settings", _show.bind(Page.SETTINGS)))
	column.add_child(MenuTheme.button("Quit", get_tree().quit))
	column.add_child(MenuTheme.label("Player name", 18, MenuTheme.TEXT_DIM))
	_name_edit = LineEdit.new()
	_name_edit.text = Settings.player_name
	_name_edit.max_length = Settings.NAME_MAX
	_name_edit.custom_minimum_size = Vector2(360, 48)
	_name_edit.text_changed.connect(_on_name_changed)
	column.add_child(_name_edit)
	return column


func _build_bots() -> Control:
	var column := _column(Page.BOTS)
	column.add_child(MenuTheme.label("Bot Arena - FFA", MenuTheme.HEADER_SIZE))
	column.add_child(MenuTheme.label("Map", 18, MenuTheme.TEXT_DIM))
	_bots_map = _map_picker(Settings.map_id, _pick_menu_map)
	column.add_child(_bots_map)
	column.add_child(MenuTheme.label("Difficulty", 18, MenuTheme.TEXT_DIM))
	for diff: String in Settings.DIFFICULTIES:
		var pick := MenuTheme.button(diff, _start_bots.bind(diff))
		if diff == Settings.bot_difficulty:
			pick.text = "> %s <" % diff.to_upper()
			_first_focus[Page.BOTS] = pick
		column.add_child(pick)
	column.add_child(MenuTheme.button("Back", _back))
	return column


func _build_lan() -> Control:
	var column := _column(Page.LAN)
	column.add_child(MenuTheme.label("LAN - Host", MenuTheme.HEADER_SIZE))
	_bot_fill = CheckButton.new()
	_bot_fill.text = "FILL EMPTY SLOTS WITH BOTS"
	_bot_fill.button_pressed = Settings.host_bot_fill
	_bot_fill.toggled.connect(func(on: bool) -> void: Settings.host_bot_fill = on)
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override(&"separation", 14)
	_add_first(Page.LAN, host_row, MenuTheme.button("Host Game", _host))
	_host_map = _map_picker(Settings.map_id, _pick_menu_map)
	host_row.add_child(_host_map)
	column.add_child(host_row)
	column.add_child(_bot_fill)
	_bot_refill = CheckButton.new()
	_bot_refill.text = "REFILL EMPTY SLOTS WITH BOTS"
	_bot_refill.tooltip_text = "A player who leaves mid-match is replaced by a bot."
	_bot_refill.button_pressed = Settings.host_bot_refill
	_bot_refill.toggled.connect(func(on: bool) -> void: Settings.host_bot_refill = on)
	column.add_child(_bot_refill)
	column.add_child(MenuTheme.label("LAN - Join", MenuTheme.HEADER_SIZE))
	_servers = ItemList.new()
	_servers.custom_minimum_size = Vector2(720, 180)
	_servers.item_activated.connect(_join_listed)
	column.add_child(_servers)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	_ip_edit = LineEdit.new()
	_ip_edit.text = Settings.last_join_ip
	_ip_edit.placeholder_text = "IP address"
	_ip_edit.custom_minimum_size = Vector2(360, 48)
	_ip_edit.text_submitted.connect(func(_t: String) -> void: _join_ip())
	row.add_child(_ip_edit)
	row.add_child(MenuTheme.button("Join IP", _join_ip))
	column.add_child(row)
	column.add_child(MenuTheme.button("Back", _back))
	return column


func _build_lobby() -> Control:
	var column := _column(Page.LOBBY)
	_lobby_title = MenuTheme.label("Lobby", MenuTheme.HEADER_SIZE)
	column.add_child(_lobby_title)
	_lobby_map = _map_picker(Net.map_id, _pick_lobby_map)
	column.add_child(_lobby_map)
	_lobby_map_label = MenuTheme.label("", 22, MenuTheme.ACCENT)
	column.add_child(_lobby_map_label)
	_lobby_list = VBoxContainer.new()
	column.add_child(_lobby_list)
	_lobby_start = MenuTheme.button("Start Match", Net.start_match)
	_add_first(Page.LOBBY, column, _lobby_start)
	column.add_child(MenuTheme.button("Leave", _back))
	return column


func _build_settings() -> Control:
	var page := _column(Page.SETTINGS)
	page.add_child(MenuTheme.label("Settings", MenuTheme.HEADER_SIZE))
	var split := HBoxContainer.new()
	split.add_theme_constant_override(&"separation", 48)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(split)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	split.add_child(column)
	var mouse := _slider(column, "Mouse sensitivity", 0.25, 3.0, Settings.mouse_sensitivity_scale)
	mouse.value_changed.connect(func(v: float) -> void: Settings.mouse_sensitivity_scale = v)
	_first_focus[Page.SETTINGS] = mouse
	var stick := _slider(column, "Stick sensitivity", 0.25, 3.0, Settings.stick_sensitivity_scale)
	stick.value_changed.connect(func(v: float) -> void: Settings.stick_sensitivity_scale = v)
	var fov_value := Settings.fov if Settings.fov > 0.0 else 75.0
	var fov := _slider(column, "Field of view", Settings.FOV_MIN, Settings.FOV_MAX, fov_value)
	fov.step = 1.0
	fov.value_changed.connect(func(v: float) -> void: Settings.fov = v)
	var music := _slider(column, "Music", 0.0, 1.0, Settings.music_volume)
	music.value_changed.connect(_on_music_volume)
	var assist := CheckButton.new()
	assist.text = "MOUSE AIM ASSIST"
	assist.button_pressed = Settings.mouse_aim_assist
	assist.toggled.connect(func(on: bool) -> void: Settings.mouse_aim_assist = on)
	column.add_child(assist)
	# Colour tabs: ARMOR / VISOR share the swatch area and the custom picker.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override(&"separation", 8)
	column.add_child(tabs)
	var group := ButtonGroup.new()
	for i in 2:
		var tab := Button.new()
		tab.text = "ARMOR" if i == 0 else "VISOR"
		tab.toggle_mode = true
		tab.button_group = group
		tab.button_pressed = i == 0
		tab.custom_minimum_size = Vector2(176, 44)
		tab.focus_mode = Control.FOCUS_ALL
		tab.pressed.connect(_show_colour_tab.bind(i))
		tabs.add_child(tab)
		_colour_tabs.append(tab)
	_colour_picker = ColorPickerButton.new()
	_colour_picker.edit_alpha = false
	_colour_picker.custom_minimum_size = Vector2(360, 48)
	_colour_picker.text = "CUSTOM"
	_colour_picker.color_changed.connect(_on_custom_colour)
	var armor := _swatch_grid(PlayerColor.PRESETS, _swatches, false)
	var visor := _swatch_grid(PlayerColor.VISOR_PRESETS, _visor_swatches, true)
	_colour_grids = [armor, visor]
	column.add_child(armor)
	column.add_child(visor)
	column.add_child(_colour_picker)
	column.add_child(MenuTheme.button("Keybinds", _show.bind(Page.KEYBINDS)))
	column.add_child(MenuTheme.button("Back", _back))
	var preview_column := VBoxContainer.new()
	preview_column.add_theme_constant_override(&"separation", 8)
	split.add_child(preview_column)
	_preview = ArmorPreview.new()
	_preview.set_color(Settings.primary_color)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_column.add_child(_preview)
	preview_column.add_child(MenuTheme.label("Drag to turn", 16, MenuTheme.TEXT_DIM))
	_preview.set_visor_color(Settings.visor_color)
	_mark_swatch(Settings.primary_color)
	_mark_visor_swatch(Settings.visor_color)
	_show_colour_tab(0)
	return page


## 8-wide grid of preset swatches. Pressing one sets the armor (or visor) colour; focusing one
## (pad / keyboard) previews it on the body until focus leaves.
func _swatch_grid(presets: Array[Dictionary], into: Array[Button], visor: bool) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override(&"h_separation", 8)
	grid.add_theme_constant_override(&"v_separation", 8)
	into.clear()
	for preset: Dictionary in presets:
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(56, 40)
		swatch.tooltip_text = str(preset.name)
		swatch.focus_mode = Control.FOCUS_ALL
		var color: Color = preset.color
		swatch.set_meta(&"color", color)
		swatch.add_theme_stylebox_override(&"hover", MenuTheme.box(color, MenuTheme.RIM))
		swatch.add_theme_stylebox_override(&"pressed", MenuTheme.box(color, MenuTheme.ACCENT))
		swatch.add_theme_stylebox_override(
			&"focus", MenuTheme.box(Color(0, 0, 0, 0), MenuTheme.ACCENT, 3)
		)
		if visor:
			swatch.pressed.connect(
				func() -> void:
					_colour_picker.color = color
					_set_visor(color)
			)
			swatch.focus_entered.connect(func() -> void: _preview.set_visor_color(color))
			swatch.focus_exited.connect(
				func() -> void: _preview.set_visor_color(Settings.visor_color)
			)
		else:
			swatch.pressed.connect(
				func() -> void:
					_colour_picker.color = color
					_set_color(color)
			)
			swatch.focus_entered.connect(func() -> void: _preview.set_color(color))
			swatch.focus_exited.connect(func() -> void: _preview.set_color(Settings.primary_color))
		grid.add_child(swatch)
		into.append(swatch)
	return grid


## 0 = armor, 1 = visor: show that grid and point the custom picker at that colour.
func _show_colour_tab(tab: int) -> void:
	_colour_tab = tab
	for i in _colour_grids.size():
		(_colour_grids[i] as Control).visible = i == tab
	for i in _colour_tabs.size():
		_colour_tabs[i].set_pressed_no_signal(i == tab)
	_colour_picker.color = Settings.visor_color if tab == 1 else Settings.primary_color


func _on_custom_colour(color: Color) -> void:
	if _colour_tab == 1:
		_set_visor(color)
	else:
		_set_color(color)


func _set_visor(color: Color) -> void:
	color.a = 1.0
	Settings.visor_color = color
	if _preview != null:
		_preview.set_visor_color(color)
	_mark_visor_swatch(color)


func _mark_visor_swatch(color: Color) -> void:
	_mark_swatches(_visor_swatches, color)


func _build_keybinds() -> Control:
	var page := _column(Page.KEYBINDS)
	page.add_child(MenuTheme.label("Keybinds - keyboard and mouse", MenuTheme.HEADER_SIZE))
	page.add_child(
		MenuTheme.label(
			"Select a binding, then press a key or mouse button. Esc cancels, Delete clears.",
			18,
			MenuTheme.TEXT_DIM
		)
	)
	_bind_status = MenuTheme.label("", 18, MenuTheme.ACCENT)
	page.add_child(_bind_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	page.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 1 + Keybinds.SLOTS
	grid.add_theme_constant_override(&"h_separation", 14)
	grid.add_theme_constant_override(&"v_separation", 8)
	scroll.add_child(grid)
	grid.add_child(MenuTheme.label("Action", 18, MenuTheme.TEXT_DIM))
	grid.add_child(MenuTheme.label("Primary", 18, MenuTheme.TEXT_DIM))
	grid.add_child(MenuTheme.label("Secondary", 18, MenuTheme.TEXT_DIM))
	for entry: Dictionary in Keybinds.ACTIONS:
		var action := str(entry.action)
		if not InputMap.has_action(action):
			continue
		var name_label := MenuTheme.label(str(entry.label), 20)
		name_label.custom_minimum_size = Vector2(320, 0)
		grid.add_child(name_label)
		var buttons: Array[Button] = []
		for slot in Keybinds.SLOTS:
			var button := MenuTheme.button("-", _start_capture.bind(action, slot))
			button.custom_minimum_size = Vector2(260, 44)
			if not _first_focus.has(Page.KEYBINDS):
				_first_focus[Page.KEYBINDS] = button
			grid.add_child(button)
			buttons.append(button)
		_bind_buttons[action] = buttons
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	row.add_child(MenuTheme.button("Reset to defaults", _reset_binds))
	row.add_child(MenuTheme.button("Back", _back))
	page.add_child(row)
	_refresh_binds()
	return page


func _refresh_binds() -> void:
	for action: String in _bind_buttons:
		var codes := Keybinds.get_codes(action)
		var buttons: Array = _bind_buttons[action]
		for slot in buttons.size():
			(buttons[slot] as Button).text = Keybinds.code_label(codes[slot]).to_upper()


func _start_capture(action: String, slot: int) -> void:
	_capture = {"action": action, "slot": slot}
	_refresh_binds()
	(_bind_buttons[action][slot] as Button).text = "PRESS A KEY..."
	_bind_status.text = ""


func _end_capture() -> void:
	_capture = {}
	if _bind_buttons.size() > 0:
		_refresh_binds()


func _reset_binds() -> void:
	_end_capture()
	Keybinds.reset_all()
	Settings.save_settings()
	_refresh_binds()
	_bind_status.text = "DEFAULTS RESTORED"


## Capture mode swallows every input until a key or mouse button arrives (bind it), Esc or a pad
## cancel (cancel), or Delete / Backspace (clear the slot).
func _input(event: InputEvent) -> void:
	if _capture.is_empty():
		return
	if event is InputEventMouseMotion or event is InputEventJoypadMotion:
		return
	get_viewport().set_input_as_handled()
	if event is InputEventJoypadButton:
		if event.is_action_pressed(&"ui_cancel"):
			_end_capture()
		return
	if not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey
	if key != null and key.physical_keycode == KEY_ESCAPE:
		_end_capture()
		return
	var code := Keybinds.event_to_code(event)
	if key != null and key.physical_keycode in [KEY_DELETE, KEY_BACKSPACE]:
		code = ""
	if code == "" and key == null:
		return
	var action := str(_capture.action)
	var taken := Keybinds.bind(action, int(_capture.slot), code)
	var label := _action_label(action)
	if code == "":
		_bind_status.text = ("%s: cleared" % label).to_upper()
	elif taken.is_empty():
		_bind_status.text = ("%s: %s" % [label, Keybinds.code_label(code)]).to_upper()
	else:
		_bind_status.text = (
			("%s: %s (removed from %s)" % [label, Keybinds.code_label(code), ", ".join(taken)])
			.to_upper()
		)
	Settings.save_settings()
	_end_capture()


func _action_label(action: String) -> String:
	for entry: Dictionary in Keybinds.ACTIONS:
		if str(entry.action) == action:
			return str(entry.label)
	return action


## Thick amber rim on the armor swatch matching color (none for a custom colour).
func _mark_swatch(color: Color) -> void:
	_mark_swatches(_swatches, color)


func _mark_swatches(swatches: Array[Button], color: Color) -> void:
	for swatch: Button in swatches:
		var swatch_color: Color = swatch.get_meta(&"color")
		var selected := PlayerColor.same_color(swatch_color, color)
		var rim := MenuTheme.ACCENT if selected else MenuTheme.RIM.darkened(0.4)
		var style := MenuTheme.box(swatch_color, rim, 4 if selected else 2)
		swatch.add_theme_stylebox_override(&"normal", style)


## Map dropdown (MapList order) starting on selected; on_pick gets the chosen map id.
func _map_picker(selected: String, on_pick: Callable) -> OptionButton:
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(360, 48)
	picker.focus_mode = Control.FOCUS_ALL
	for map: Dictionary in MapList.MAPS:
		picker.add_item(str(map.name).to_upper())
	picker.select(MapList.index_of(MapList.sanitize(selected)))
	picker.item_selected.connect(
		func(index: int) -> void: on_pick.call(str(MapList.MAPS[index].id))
	)
	return picker


func _slider(parent: Control, text: String, low: float, high: float, value: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	var name_label := MenuTheme.label(text, 20)
	name_label.custom_minimum_size = Vector2(320, 0)
	row.add_child(name_label)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(360, 32)
	slider.focus_mode = Control.FOCUS_ALL
	row.add_child(slider)
	var readout := MenuTheme.label("%.2f" % value, 20, MenuTheme.ACCENT)
	slider.value_changed.connect(func(v: float) -> void: readout.text = "%.2f" % v)
	row.add_child(readout)
	parent.add_child(row)
	return slider


# ------------------------------------------------------------------ actions


func _show_track(track_title: String) -> void:
	if _now_playing == null:
		return
	if track_title == "" or track_title == "Sanctuary OS":
		_now_playing.text = "SANCTUARY OS  ·  DUSQK"
	else:
		_now_playing.text = "SANCTUARY OS  ·  %s  ·  DUSQK" % track_title.to_upper()


func _on_music_volume(value: float) -> void:
	Settings.music_volume = value
	Settings.apply_music_volume()


func _on_name_changed(text: String) -> void:
	Settings.player_name = Settings.sanitize_name(text)
	Settings.save_settings()


func _set_color(color: Color) -> void:
	color.a = 1.0
	Settings.primary_color = color
	if _preview != null:
		_preview.set_color(color)
	_mark_swatch(color)


## Bot Arena / LAN Host pickers share the remembered map.
func _pick_menu_map(map_id: String) -> void:
	Settings.map_id = map_id
	Settings.save_settings()
	for picker: OptionButton in [_bots_map, _host_map]:
		if picker != null:
			picker.select(MapList.index_of(map_id))


## Lobby (host only): change the session map; clients follow via the registry broadcast.
func _pick_lobby_map(map_id: String) -> void:
	_pick_menu_map(map_id)
	Net.set_map(map_id)


func _start_bots(difficulty: String) -> void:
	Settings.bot_difficulty = difficulty
	Settings.save_settings()
	Net.start_offline()


func _host() -> void:
	Settings.save_settings()
	var err := Net.host(Net.DEFAULT_PORT, _bot_fill.button_pressed, _bot_refill.button_pressed)
	if err != OK:
		_status.text = "COULD NOT HOST ON PORT %d (%s)" % [Net.DEFAULT_PORT, error_string(err)]
		return
	_status.text = "HOSTING ON PORT %d" % Net.DEFAULT_PORT
	_show(Page.LOBBY)


func _join_ip() -> void:
	var address := _ip_edit.text.strip_edges()
	if address == "":
		return
	Settings.last_join_ip = address
	Settings.save_settings()
	_join(address, Net.DEFAULT_PORT)


func _join_listed(index: int) -> void:
	if index < 0 or index >= _server_data.size():
		return
	var server: Dictionary = _server_data[index]
	_join(str(server.ip), int(server.port))


func _join(address: String, port: int) -> void:
	var err := Net.join(address, port)
	if err != OK:
		_status.text = "COULD NOT CONNECT (%s)" % error_string(err)
		return
	_status.text = "CONNECTING TO %s:%d" % [address, port]


func _on_joined() -> void:
	_status.text = "JOINED"
	_show(Page.LOBBY)


func _on_join_failed(reason: String) -> void:
	_status.text = reason.to_upper()
	_show(Page.LAN)


func _on_session_ended(reason: String) -> void:
	_status.text = reason.to_upper()
	if _page == Page.LOBBY:
		_show(Page.LAN)


func _on_servers_changed(servers: Array) -> void:
	_server_data.clear()
	_server_data.append_array(servers)
	_servers.clear()
	for server: Dictionary in _server_data:
		var line := "%s  -  %s  %d/%d" % [server.name, server.map, server.players, server.max]
		if not server.version_ok:
			line += "  (version mismatch)"
		_servers.add_item(line)
	if _servers.item_count == 0:
		_servers.add_item("Searching for games...")
		_servers.set_item_disabled(0, true)
		_server_data.clear()


func _refresh_lobby() -> void:
	if _lobby_list == null:
		return
	for child in _lobby_list.get_children():
		child.queue_free()
	for peer: int in Net.players:
		var tag := "  (host)" if peer == 1 else ""
		var line := MenuTheme.label(Net.name_of(peer) + tag, 22)
		line.add_theme_color_override(&"font_color", Net.color_of(peer).lightened(0.25))
		_lobby_list.add_child(line)
	_lobby_start.visible = Net.is_host()
	_lobby_map.visible = Net.is_host()
	_lobby_map.select(MapList.index_of(MapList.sanitize(Net.map_id)))
	_lobby_map_label.visible = not Net.is_host()
	_lobby_map_label.text = ("Map: %s" % MapList.name_of(Net.map_id)).to_upper()
	var fill := " + bots" if Net.is_host() and Net.bot_fill else ""
	_lobby_title.text = ("Lobby %d/%d%s" % [Net.players.size(), Net.MAX_PLAYERS, fill]).to_upper()
