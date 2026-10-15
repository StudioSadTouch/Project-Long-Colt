extends Control
## Main menu (run/main_scene): Bot Arena (difficulty), LAN (host with bot fill / join from the
## discovered list or a typed IP / lobby), Settings (look, aim assist, FOV, armor colour) and
## Quit, plus the player name. Built in code on MenuTheme. Pad and keyboard navigable via
## ui_* focus; Esc / B / Start goes back a page. Everything persists through the Settings
## autoload (user://settings.cfg).

enum Page { MAIN, BOTS, LAN, LOBBY, SETTINGS }

var _pages: Dictionary = {}
var _page: Page = Page.MAIN
var _status: Label
var _name_edit: LineEdit
var _servers: ItemList
var _server_data: Array = []
var _ip_edit: LineEdit
var _bot_fill: CheckButton
var _bot_refill: CheckButton
var _lobby_list: VBoxContainer
var _lobby_start: Button
var _lobby_title: Label
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
	var holder := Control.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(holder)
	_pages[Page.MAIN] = _build_main()
	_pages[Page.BOTS] = _build_bots()
	_pages[Page.LAN] = _build_lan()
	_pages[Page.LOBBY] = _build_lobby()
	_pages[Page.SETTINGS] = _build_settings()
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
	column.add_child(MenuTheme.label("Bot Arena - Lockout FFA", MenuTheme.HEADER_SIZE))
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
	_add_first(Page.LAN, column, MenuTheme.button("Host Game", _host))
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
	_lobby_list = VBoxContainer.new()
	column.add_child(_lobby_list)
	_lobby_start = MenuTheme.button("Start Match", Net.start_match)
	_add_first(Page.LOBBY, column, _lobby_start)
	column.add_child(MenuTheme.button("Leave", _back))
	return column


func _build_settings() -> Control:
	var column := _column(Page.SETTINGS)
	column.add_child(MenuTheme.label("Settings", MenuTheme.HEADER_SIZE))
	var mouse := _slider(column, "Mouse sensitivity", 0.25, 3.0, Settings.mouse_sensitivity_scale)
	mouse.value_changed.connect(func(v: float) -> void: Settings.mouse_sensitivity_scale = v)
	_first_focus[Page.SETTINGS] = mouse
	var stick := _slider(column, "Stick sensitivity", 0.25, 3.0, Settings.stick_sensitivity_scale)
	stick.value_changed.connect(func(v: float) -> void: Settings.stick_sensitivity_scale = v)
	var fov_value := Settings.fov if Settings.fov > 0.0 else 75.0
	var fov := _slider(column, "Field of view", Settings.FOV_MIN, Settings.FOV_MAX, fov_value)
	fov.step = 1.0
	fov.value_changed.connect(func(v: float) -> void: Settings.fov = v)
	var assist := CheckButton.new()
	assist.text = "MOUSE AIM ASSIST"
	assist.button_pressed = Settings.mouse_aim_assist
	assist.toggled.connect(func(on: bool) -> void: Settings.mouse_aim_assist = on)
	column.add_child(assist)
	column.add_child(MenuTheme.label("Armor colour", 18, MenuTheme.TEXT_DIM))
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override(&"h_separation", 8)
	grid.add_theme_constant_override(&"v_separation", 8)
	column.add_child(grid)
	var picker := ColorPickerButton.new()
	picker.color = Settings.primary_color
	picker.edit_alpha = false
	picker.custom_minimum_size = Vector2(360, 48)
	picker.text = "CUSTOM"
	picker.color_changed.connect(_set_color)
	for preset: Dictionary in PlayerColor.PRESETS:
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(64, 44)
		swatch.tooltip_text = str(preset.name)
		swatch.focus_mode = Control.FOCUS_ALL
		var color: Color = preset.color
		var normal := MenuTheme.box(color, MenuTheme.RIM.darkened(0.4))
		swatch.add_theme_stylebox_override(&"normal", normal)
		swatch.add_theme_stylebox_override(&"hover", MenuTheme.box(color, MenuTheme.RIM))
		swatch.add_theme_stylebox_override(&"pressed", MenuTheme.box(color, MenuTheme.ACCENT))
		swatch.pressed.connect(
			func() -> void:
				picker.color = color
				_set_color(color)
		)
		grid.add_child(swatch)
	column.add_child(picker)
	column.add_child(MenuTheme.button("Back", _back))
	return column


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


func _on_name_changed(text: String) -> void:
	Settings.player_name = Settings.sanitize_name(text)
	Settings.save_settings()


func _set_color(color: Color) -> void:
	color.a = 1.0
	Settings.primary_color = color


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
	var fill := " + bots" if Net.is_host() and Net.bot_fill else ""
	_lobby_title.text = ("Lobby %d/%d%s" % [Net.players.size(), Net.MAX_PLAYERS, fill]).to_upper()
