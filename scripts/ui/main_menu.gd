extends Control
## Main menu (run/main_scene): Bot Arena (map, player count, bot count, mode, difficulty),
## Multiplayer (host with map, player count, bot count, mode, bot fill, port, UPnP and an
## optional password / join by address (IP or domain, :port), password, from the recent and
## favorite servers or the LAN list / lobby, where the host can still change the map, player
## count, bot count and mode, and sees whether the game is reachable from the internet),
## Settings (look, aim assist, FOV, music, armor colour with a 3D preview, keybinds) and Quit,
## plus the player name. Maps come from MapList, player counts from GameMode, bot counts from
## Settings.bot_count, rules from GameModes. The last picks are Settings.map_id / mode_id /
## bot_count / rules_id. Built in code on MenuTheme. Pad and keyboard navigable via
## ui_* focus; Esc / B / Start goes back a page. Everything persists through the Settings
## autoload (user://settings.cfg).

enum Page { MAIN, BOTS, LAN, LOBBY, SETTINGS, KEYBINDS, CUSTOMIZATION }
## Settings colour tabs, in tab order (index into COLOUR_TAB_NAMES and _colour_grids).
enum ColourSlot { ARMOR, SHOULDER, VISOR }

const COLOUR_TAB_NAMES: Array[String] = ["ARMOR", "SHOULDER", "VISOR"]

var _pages: Dictionary = {}
var _page: Page = Page.MAIN
var _status: Label
var _now_playing: Label
var _name_edit: LineEdit
var _servers: ItemList
var _server_data: Array = []
var _ip_edit: LineEdit
var _join_password: LineEdit
## Recent and favorite servers ("host:port"), favorites first.
var _saved: ItemList
var _saved_data: Array[String] = []
var _port_edit: LineEdit
var _upnp_toggle: CheckButton
var _host_password: LineEdit
var _lobby_net: Label
## The address being joined, remembered as recent once the join succeeds.
var _pending_address: String = ""
var _bot_fill: CheckButton
var _bot_refill: CheckButton
var _lobby_list: VBoxContainer
var _lobby_start: Button
var _lobby_title: Label
var _lobby_map: OptionButton
var _lobby_players: OptionButton
var _lobby_bots: OptionButton
var _lobby_mode: OptionButton
var _lobby_map_label: Label
var _host_map: OptionButton
var _host_players: OptionButton
var _host_bots: OptionButton
var _host_mode: OptionButton
var _bots_map: OptionButton
var _bots_players: OptionButton
var _bots_bots: OptionButton
var _bots_mode: OptionButton
## True while bot pickers are being rebuilt, so select() cannot write Settings.bot_count.
var _syncing_bots: bool = false
var _preview: ArmorPreview
var _swatches: Array[Button] = []
var _accent_swatches: Array[Button] = []
var _visor_swatches: Array[Button] = []
## Settings colour tab (which grid shows, what the custom picker edits).
var _colour_tab: ColourSlot = ColourSlot.ARMOR
var _colour_grids: Array = []
var _colour_tabs: Array[Button] = []
var _colour_picker: ColorPickerButton
## Armor piece pickers: slot -> the Label showing the chosen variant.
var _armor_labels: Dictionary = {}
## Keybinds page: action -> Array[Button] (one per Keybinds.SLOTS).
var _bind_buttons: Dictionary = {}
var _bind_status: Label
## Waiting for an input to bind: {"action": String, "slot": int}; empty when not capturing.
var _capture: Dictionary = {}
var _first_focus: Dictionary = {}


func _ready() -> void:
	if DedicatedServer.requested():
		return  # no menu on a dedicated server: DedicatedServer swaps in its idle scene
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
	_pages[Page.CUSTOMIZATION] = _build_customization()
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
		Page.KEYBINDS, Page.CUSTOMIZATION:
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
	column.add_child(MenuTheme.button("Multiplayer", _show.bind(Page.LAN)))
	column.add_child(MenuTheme.button("Level Editor", _open_level_editor))
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


func _open_level_editor() -> void:
	get_tree().change_scene_to_file("res://scenes/editor/level_editor.tscn")


func _build_bots() -> Control:
	var column := _column(Page.BOTS)
	column.add_child(MenuTheme.label("Bot Arena", MenuTheme.HEADER_SIZE))
	column.add_child(MenuTheme.label("Map", 18, MenuTheme.TEXT_DIM))
	_bots_map = _map_picker(Settings.map_id, _pick_menu_map)
	column.add_child(_bots_map)
	column.add_child(MenuTheme.label("Players", 18, MenuTheme.TEXT_DIM))
	_bots_players = _players_picker(Settings.mode_id, _pick_menu_players)
	column.add_child(_bots_players)
	column.add_child(MenuTheme.label("Bots", 18, MenuTheme.TEXT_DIM))
	_bots_bots = _bots_picker(Settings.mode_id)
	column.add_child(_bots_bots)
	column.add_child(MenuTheme.label("Mode", 18, MenuTheme.TEXT_DIM))
	_bots_mode = _mode_picker(Settings.rules_id, _pick_menu_rules)
	column.add_child(_bots_mode)
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
	column.add_child(MenuTheme.label("Host", MenuTheme.HEADER_SIZE))
	_bot_fill = CheckButton.new()
	_bot_fill.text = "FILL EMPTY SLOTS WITH BOTS"
	_bot_fill.tooltip_text = "Spawn the chosen number of bots, up to the empty slots. Off spawns none."
	_bot_fill.button_pressed = Settings.host_bot_fill
	_bot_fill.toggled.connect(func(on: bool) -> void: Settings.host_bot_fill = on)
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override(&"separation", 14)
	_add_first(Page.LAN, host_row, MenuTheme.button("Host Game", _host))
	_host_map = _map_picker(Settings.map_id, _pick_menu_map)
	host_row.add_child(_host_map)
	_host_players = _players_picker(Settings.mode_id, _pick_menu_players)
	host_row.add_child(_host_players)
	_host_bots = _bots_picker(Settings.mode_id)
	host_row.add_child(_host_bots)
	_host_mode = _mode_picker(Settings.rules_id, _pick_menu_rules, true)
	host_row.add_child(_host_mode)
	column.add_child(host_row)
	column.add_child(_bot_fill)
	_bot_refill = CheckButton.new()
	_bot_refill.text = "REFILL EMPTY SLOTS WITH BOTS"
	_bot_refill.tooltip_text = "A player who leaves mid-match is replaced by a bot, up to the chosen bot count."
	_bot_refill.button_pressed = Settings.host_bot_refill
	_bot_refill.toggled.connect(func(on: bool) -> void: Settings.host_bot_refill = on)
	column.add_child(_bot_refill)
	var net_row := HBoxContainer.new()
	net_row.add_theme_constant_override(&"separation", 14)
	net_row.add_child(MenuTheme.label("Port", 20, MenuTheme.TEXT_DIM))
	_port_edit = LineEdit.new()
	_port_edit.text = str(Settings.host_port)
	_port_edit.custom_minimum_size = Vector2(120, 48)
	_port_edit.tooltip_text = "UDP port players connect to (default 7777)."
	net_row.add_child(_port_edit)
	_upnp_toggle = CheckButton.new()
	_upnp_toggle.text = "OPEN TO INTERNET (UPNP)"
	_upnp_toggle.tooltip_text = (
		"Ask your router to forward the port so players outside your network can join."
		+ " Without UPnP, forward the UDP port on the router by hand."
	)
	_upnp_toggle.button_pressed = Settings.host_upnp
	_upnp_toggle.toggled.connect(func(on: bool) -> void: Settings.host_upnp = on)
	net_row.add_child(_upnp_toggle)
	_host_password = LineEdit.new()
	_host_password.placeholder_text = "Password (optional)"
	_host_password.secret = true
	_host_password.custom_minimum_size = Vector2(260, 48)
	net_row.add_child(_host_password)
	column.add_child(net_row)
	column.add_child(MenuTheme.label("Join", MenuTheme.HEADER_SIZE))
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	_ip_edit = LineEdit.new()
	_ip_edit.text = Settings.last_join_ip
	_ip_edit.placeholder_text = "Address: IP or domain, :port if not 7777"
	_ip_edit.custom_minimum_size = Vector2(460, 48)
	_ip_edit.text_submitted.connect(func(_t: String) -> void: _join_ip())
	row.add_child(_ip_edit)
	_join_password = LineEdit.new()
	_join_password.placeholder_text = "Password (if any)"
	_join_password.secret = true
	_join_password.custom_minimum_size = Vector2(240, 48)
	_join_password.text_submitted.connect(func(_t: String) -> void: _join_ip())
	row.add_child(_join_password)
	row.add_child(MenuTheme.button("Join", _join_ip))
	row.add_child(MenuTheme.button("Favorite", _toggle_favorite))
	column.add_child(row)
	column.add_child(MenuTheme.label("Favorites and recent", 20, MenuTheme.TEXT_DIM))
	_saved = ItemList.new()
	_saved.custom_minimum_size = Vector2(720, 140)
	_saved.item_selected.connect(_pick_saved)
	_saved.item_activated.connect(func(index: int) -> void:
		_pick_saved(index)
		_join_ip())
	column.add_child(_saved)
	column.add_child(MenuTheme.label("On your network", 20, MenuTheme.TEXT_DIM))
	_servers = ItemList.new()
	_servers.custom_minimum_size = Vector2(720, 140)
	_servers.item_activated.connect(_join_listed)
	column.add_child(_servers)
	column.add_child(MenuTheme.button("Back", _back))
	_refresh_saved()
	return column


func _build_lobby() -> Control:
	var column := _column(Page.LOBBY)
	_lobby_title = MenuTheme.label("Lobby", MenuTheme.HEADER_SIZE)
	column.add_child(_lobby_title)
	_lobby_map = _map_picker(Net.map_id, _pick_lobby_map)
	column.add_child(_lobby_map)
	_lobby_players = _players_picker(Net.mode_id, _pick_lobby_players)
	column.add_child(_lobby_players)
	_lobby_bots = _bots_picker(Net.mode_id)
	column.add_child(_lobby_bots)
	_lobby_mode = _mode_picker(Net.rules_id, _pick_lobby_rules, true)
	column.add_child(_lobby_mode)
	_lobby_map_label = MenuTheme.label("", 22, MenuTheme.ACCENT)
	column.add_child(_lobby_map_label)
	_lobby_net = MenuTheme.label("", 20, MenuTheme.TEXT_DIM)
	column.add_child(_lobby_net)
	Net.upnp.changed.connect(_on_upnp_changed)
	_lobby_list = VBoxContainer.new()
	column.add_child(_lobby_list)
	_lobby_start = MenuTheme.button("Start Match", Net.start_match)
	_add_first(Page.LOBBY, column, _lobby_start)
	column.add_child(MenuTheme.button("Leave", _back))
	return column


func _build_settings() -> Control:
	var page := _column(Page.SETTINGS)
	page.add_child(MenuTheme.label("Settings", MenuTheme.HEADER_SIZE))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	page.add_child(column)
	var mouse := MenuTheme.slider(
		column, "Mouse sensitivity", 0.25, 3.0, Settings.mouse_sensitivity_scale
	)
	mouse.value_changed.connect(func(v: float) -> void: Settings.mouse_sensitivity_scale = v)
	_first_focus[Page.SETTINGS] = mouse
	var stick := MenuTheme.slider(
		column, "Stick sensitivity", 0.25, 3.0, Settings.stick_sensitivity_scale
	)
	stick.value_changed.connect(func(v: float) -> void: Settings.stick_sensitivity_scale = v)
	var fov_value := Settings.fov if Settings.fov > 0.0 else 75.0
	var fov := MenuTheme.slider(column, "Field of view", Settings.FOV_MIN, Settings.FOV_MAX, fov_value)
	fov.step = 1.0
	fov.value_changed.connect(func(v: float) -> void: Settings.fov = v)
	var gui_scale := MenuTheme.slider(
		column, "GUI scale", Settings.GUI_SCALE_MIN, Settings.GUI_SCALE_MAX, Settings.gui_scale
	)
	gui_scale.step = Settings.GUI_SCALE_STEP
	gui_scale.value_changed.connect(func(v: float) -> void:
		Settings.gui_scale = v
	)
	var music := MenuTheme.slider(column, "Music", 0.0, 1.0, Settings.music_volume)
	music.value_changed.connect(_on_music_volume)
	# Aim assist and fullscreen share a row
	var assist_row := HBoxContainer.new()
	assist_row.add_theme_constant_override(&"separation", 12)
	column.add_child(assist_row)
	var assist := CheckButton.new()
	assist.text = "MOUSE AIM ASSIST"
	assist.button_pressed = Settings.mouse_aim_assist
	assist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	assist.toggled.connect(func(on: bool) -> void: Settings.mouse_aim_assist = on)
	assist_row.add_child(assist)
	var full := CheckButton.new()
	full.text = "FULLSCREEN (F11)"
	full.button_pressed = Settings.fullscreen
	full.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	full.toggled.connect(
		func(on: bool) -> void:
			Settings.fullscreen = on
			Settings.apply_display()
	)
	assist_row.add_child(full)
	# One row for both camera toggles
	var camera_row := HBoxContainer.new()
	camera_row.add_theme_constant_override(&"separation", 12)
	column.add_child(camera_row)
	var third := CheckButton.new()
	third.text = "THIRD PERSON (T)"
	third.button_pressed = Settings.third_person
	third.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	third.toggled.connect(func(on: bool) -> void: Settings.third_person = on)
	camera_row.add_child(third)
	var shoulder := CheckButton.new()
	shoulder.text = "LEFT SHOULDER (B)"
	shoulder.button_pressed = Settings.left_shoulder
	shoulder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shoulder.toggled.connect(func(on: bool) -> void: Settings.left_shoulder = on)
	camera_row.add_child(shoulder)

	# Submenu entries
	column.add_child(MenuTheme.button("Customize Armor", _show.bind(Page.CUSTOMIZATION)))
	column.add_child(MenuTheme.button("Keybinds", _show.bind(Page.KEYBINDS)))
	column.add_child(MenuTheme.button("Back", _back))
	return page


func _build_customization() -> Control:
	var page := _column(Page.CUSTOMIZATION)
	page.add_child(MenuTheme.label("Armor Customization", MenuTheme.HEADER_SIZE))
	var split := HBoxContainer.new()
	split.add_theme_constant_override(&"separation", 48)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(split)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	split.add_child(column)

	# Colour tabs: ARMOR / SHOULDER / VISOR share the swatch area and the custom picker.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override(&"separation", 8)
	column.add_child(tabs)
	var group := ButtonGroup.new()
	for i in COLOUR_TAB_NAMES.size():
		var tab := Button.new()
		tab.text = COLOUR_TAB_NAMES[i]
		tab.toggle_mode = true
		tab.button_group = group
		tab.button_pressed = i == 0
		tab.custom_minimum_size = Vector2(162, 44)
		tab.focus_mode = Control.FOCUS_ALL
		tab.pressed.connect(_show_colour_tab.bind(i))
		tabs.add_child(tab)
		_colour_tabs.append(tab)
	_colour_picker = ColorPickerButton.new()
	_colour_picker.edit_alpha = false
	_colour_picker.custom_minimum_size = Vector2(360, 48)
	_colour_picker.text = "CUSTOM"
	_colour_picker.color_changed.connect(_on_custom_colour)
	_colour_grids = [
		_swatch_grid(PlayerColor.PRESETS, _swatches, ColourSlot.ARMOR),
		_swatch_grid(PlayerColor.PRESETS, _accent_swatches, ColourSlot.SHOULDER),
		_swatch_grid(PlayerColor.VISOR_PRESETS, _visor_swatches, ColourSlot.VISOR),
	]
	for grid: Control in _colour_grids:
		column.add_child(grid)
	column.add_child(_colour_picker)
	_armor_rows(column)
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
	_preview.set_accent_color(Settings.accent_color)
	_preview.set_armor_loadout(Settings.armor_loadout)
	_mark_swatch(Settings.primary_color)
	_mark_accent_swatch(Settings.accent_color)
	_mark_visor_swatch(Settings.visor_color)
	_show_colour_tab(ColourSlot.ARMOR)
	_first_focus[Page.CUSTOMIZATION] = tabs.get_child(0)
	return page


## One row per armor slot: < variant >. Saved with the other profile settings on Back.
func _armor_rows(column: VBoxContainer) -> void:
	for slot: String in ArmorLoadout.SLOTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		column.add_child(row)
		var slot_name := String(ArmorLoadout.SLOT_NAMES[slot]).to_upper()
		var title := MenuTheme.label(slot_name, 18, MenuTheme.TEXT_DIM)
		title.custom_minimum_size = Vector2(130, 0)
		row.add_child(title)
		var prev := Button.new()
		prev.text = "<"
		prev.custom_minimum_size = Vector2(44, 40)
		prev.focus_mode = Control.FOCUS_ALL
		prev.pressed.connect(_cycle_armor.bind(slot, -1))
		row.add_child(prev)
		var value := MenuTheme.label("", 18)
		value.custom_minimum_size = Vector2(190, 0)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(value)
		_armor_labels[slot] = value
		var next := Button.new()
		next.text = ">"
		next.custom_minimum_size = Vector2(44, 40)
		next.focus_mode = Control.FOCUS_ALL
		next.pressed.connect(_cycle_armor.bind(slot, 1))
		row.add_child(next)
	_refresh_armor_labels()


func _cycle_armor(slot: String, step: int) -> void:
	Settings.armor_loadout = ArmorLoadout.cycle(Settings.armor_loadout, slot, step)
	if _preview != null:
		_preview.set_armor_loadout(Settings.armor_loadout)
	_refresh_armor_labels()


func _refresh_armor_labels() -> void:
	var loadout := ArmorLoadout.sanitize(Settings.armor_loadout)
	for slot: String in _armor_labels:
		(_armor_labels[slot] as Label).text = ArmorLoadout.variant_name(slot, loadout[slot])


## 8-wide grid of preset swatches. Pressing one sets that slot's colour; focusing one
## (pad / keyboard) previews it on the body until focus leaves.
func _swatch_grid(presets: Array[Dictionary], into: Array[Button], slot: ColourSlot) -> GridContainer:
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
		swatch.pressed.connect(
			func() -> void:
				_colour_picker.color = color
				_set_slot_colour(slot, color)
		)
		swatch.focus_entered.connect(func() -> void: _preview_slot(slot, color))
		swatch.focus_exited.connect(func() -> void: _preview_slot(slot, _slot_colour(slot)))
		grid.add_child(swatch)
		into.append(swatch)
	return grid


## Show that slot's grid and point the custom picker at its colour.
func _show_colour_tab(tab: ColourSlot) -> void:
	_colour_tab = tab
	for i in _colour_grids.size():
		(_colour_grids[i] as Control).visible = i == tab
	for i in _colour_tabs.size():
		_colour_tabs[i].set_pressed_no_signal(i == tab)
	_colour_picker.color = _slot_colour(tab)


func _on_custom_colour(color: Color) -> void:
	_set_slot_colour(_colour_tab, color)


func _slot_colour(slot: ColourSlot) -> Color:
	match slot:
		ColourSlot.SHOULDER:
			return Settings.accent_color
		ColourSlot.VISOR:
			return Settings.visor_color
	return Settings.primary_color


func _set_slot_colour(slot: ColourSlot, color: Color) -> void:
	match slot:
		ColourSlot.SHOULDER:
			_set_accent(color)
		ColourSlot.VISOR:
			_set_visor(color)
		_:
			_set_color(color)


## Tint the preview without touching Settings (swatch focus).
func _preview_slot(slot: ColourSlot, color: Color) -> void:
	match slot:
		ColourSlot.SHOULDER:
			_preview.set_accent_color(color)
		ColourSlot.VISOR:
			_preview.set_visor_color(color)
		_:
			_preview.set_color(color)


func _set_accent(color: Color) -> void:
	color.a = 1.0
	Settings.accent_color = color
	if _preview != null:
		_preview.set_accent_color(color)
	_mark_accent_swatch(color)


func _mark_accent_swatch(color: Color) -> void:
	_mark_swatches(_accent_swatches, color)


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
	picker.name = "MapPicker"
	picker.custom_minimum_size = Vector2(360, 48)
	picker.focus_mode = Control.FOCUS_ALL
	# Built-in maps, then the Level Editor's saved levels (custom:<name>).
	var maps := MapList.all_maps()
	for map: Dictionary in maps:
		var custom := MapList.is_custom(str(map.id))
		picker.add_item(("Custom: " if custom else "") + str(map.name).to_upper())
	picker.select(MapList.index_of(MapList.sanitize(selected)))
	picker.item_selected.connect(
		func(index: int) -> void: on_pick.call(str(maps[index].id))
	)
	return picker


## Player-count dropdown (GameMode order). The item text includes the cap.
func _players_picker(selected: String, on_pick: Callable) -> OptionButton:
	var picker := OptionButton.new()
	picker.name = "PlayersPicker"
	picker.custom_minimum_size = Vector2(360, 48)
	picker.focus_mode = Control.FOCUS_ALL
	for game_mode: Dictionary in GameMode.MODES:
		var text := "%s (%d)" % [game_mode.name, int(game_mode.max_players)]
		picker.add_item(text.to_upper())
	picker.select(GameMode.index_of(GameMode.sanitize(selected)))
	picker.item_selected.connect(
		func(index: int) -> void: on_pick.call(str(GameMode.MODES[index].id))
	)
	return picker


## Bot-count dropdown: 0 through the mode's empty seats (max_players - 1). The saved count can
## be higher than this list; the shown row is the count this mode will actually spawn.
func _bots_picker(mode_id: String) -> OptionButton:
	var picker := OptionButton.new()
	picker.name = "BotsPicker"
	picker.custom_minimum_size = Vector2(240, 48)
	picker.focus_mode = Control.FOCUS_ALL
	picker.tooltip_text = (
		"How many bots to spawn. A smaller match spawns fewer and keeps the higher number."
	)
	_fill_bots_picker(picker, mode_id)
	picker.item_selected.connect(func(index: int) -> void: _pick_bots(index))
	return picker


func _fill_bots_picker(picker: OptionButton, mode_id: String) -> void:
	if picker == null:
		return
	var slots := maxi(GameMode.max_players(mode_id) - 1, 0)
	_syncing_bots = true
	picker.clear()
	for n in slots + 1:
		picker.add_item("1 BOT" if n == 1 else "%d BOTS" % n)
	picker.select(clampi(Settings.bot_count, 0, slots))
	_syncing_bots = false


func _sync_bots_pickers() -> void:
	_fill_bots_picker(_bots_bots, Settings.mode_id)
	_fill_bots_picker(_host_bots, Settings.mode_id)
	_fill_bots_picker(_lobby_bots, Net.mode_id)


## Rules dropdown (GameModes order). online = true (LAN host / lobby) leaves out offline-only
## rules (Horde); the shown ids are kept in the picker's "rules_ids" meta.
func _mode_picker(selected: String, on_pick: Callable, online: bool = false) -> OptionButton:
	var picker := OptionButton.new()
	picker.name = "ModePicker"
	picker.custom_minimum_size = Vector2(240, 48)
	picker.focus_mode = Control.FOCUS_ALL
	var rules_ids := GameModes.ids(online)
	for id in rules_ids:
		picker.add_item(GameModes.name_of(id).to_upper())
	picker.set_meta(&"rules_ids", rules_ids)
	_select_rules(picker, selected)
	picker.item_selected.connect(func(index: int) -> void: on_pick.call(rules_ids[index]))
	return picker


## Shows rules_id in a rules picker (the default rules when the picker doesn't list it).
static func _select_rules(picker: OptionButton, rules_id: String) -> void:
	var rules_ids: Array[String] = picker.get_meta(&"rules_ids", [] as Array[String])
	var index := rules_ids.find(GameModes.sanitize(rules_id))
	picker.select(index if index >= 0 else maxi(rules_ids.find(GameModes.DEFAULT_ID), 0))


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
	if map_id == "range" and Settings.rules_id != "range":
		_pick_menu_rules("range")
	elif map_id != "range" and Settings.rules_id == "range":
		_pick_menu_rules(GameModes.DEFAULT_ID)
	Settings.save_settings()
	for picker: OptionButton in [_bots_map, _host_map]:
		if picker != null:
			picker.select(MapList.index_of(map_id))


## Lobby (host only): change the session map; clients follow via the registry broadcast.
func _pick_lobby_map(map_id: String) -> void:
	_pick_menu_map(map_id)
	Net.set_map(map_id)
	Net.set_rules(Settings.rules_id)
	_refresh_lobby()


## Bot Arena / LAN Host pickers share the remembered player count.
func _pick_menu_players(mode_id: String) -> void:
	Settings.mode_id = mode_id
	# A free-for-all count can't play teams-only rules (CTF): fall back to Slayer.
	if GameModes.fit_mode(Settings.rules_id, mode_id) != mode_id:
		_pick_menu_rules(GameModes.DEFAULT_ID)
	Settings.save_settings()
	for picker: OptionButton in [_bots_players, _host_players]:
		if picker != null:
			picker.select(GameMode.index_of(mode_id))
	_sync_bots_pickers()


## Remember the chosen bot count. Rebuilding the other pickers must not write it back down
## when the current mode has fewer seats.
func _pick_bots(count: int) -> void:
	if _syncing_bots:
		return
	Settings.bot_count = clampi(count, 0, GameMode.MAX_PLAYERS_ANY - 1)
	Settings.save_settings()
	_sync_bots_pickers()


## Lobby (host only): change the session player count. Net refuses a count smaller than the
## lobby; the picker then snaps back to the current one.
func _pick_lobby_players(mode_id: String) -> void:
	if Net.set_mode(mode_id):
		_pick_menu_players(mode_id)
	else:
		_status.text = "TOO MANY PLAYERS FOR %s" % GameMode.name_of(mode_id).to_upper()
	_refresh_lobby()


## Bot Arena / LAN Host pickers share the remembered rules (Slayer / SWAT).
func _pick_menu_rules(rules_id: String) -> void:
	Settings.rules_id = rules_id
	Settings.save_settings()
	for picker: OptionButton in [_bots_mode, _host_mode]:
		if picker != null:
			_select_rules(picker, rules_id)
	# Teams-only rules (CTF) move a free-for-all pick to the team count with the same seats.
	var fitted := GameModes.fit_mode(rules_id, Settings.mode_id)
	if fitted != Settings.mode_id:
		_pick_menu_players(fitted)


## Lobby (host only): change the session rules; clients follow via the registry broadcast.
func _pick_lobby_rules(rules_id: String) -> void:
	_pick_menu_rules(rules_id)
	Net.set_rules(rules_id)
	_refresh_lobby()


func _start_bots(difficulty: String) -> void:
	Settings.bot_difficulty = difficulty
	Settings.save_settings()
	Net.start_offline()


func _host() -> void:
	var port_text := _port_edit.text.strip_edges()
	if not port_text.is_valid_int() or int(port_text) < 1 or int(port_text) > 65535:
		_status.text = "THE PORT MUST BE A NUMBER FROM 1 TO 65535"
		return
	Settings.host_port = int(port_text)
	Settings.save_settings()
	var port := Settings.host_port
	var err := Net.host(
		port,
		_bot_fill.button_pressed,
		_bot_refill.button_pressed,
		"",
		"",
		"",
		_upnp_toggle.button_pressed,
		_host_password.text
	)
	if err != OK:
		_status.text = "COULD NOT HOST ON PORT %d (%s)" % [port, error_string(err)]
		return
	_status.text = "HOSTING ON PORT %d" % port
	_show(Page.LOBBY)


## Join the typed address (IP or domain, optional :port) with the typed password.
func _join_ip() -> void:
	var text := _ip_edit.text.strip_edges()
	var parsed := NetAddress.parse(text, Net.DEFAULT_PORT)
	if not parsed.ok:
		_status.text = str(parsed.error).to_upper()
		return
	Settings.last_join_ip = text
	Settings.save_settings()
	_join(str(parsed.host), int(parsed.port), _join_password.text)


func _join_listed(index: int) -> void:
	if index < 0 or index >= _server_data.size():
		return
	var server: Dictionary = _server_data[index]
	# Into the address box too, so a password can be added if the server asks for one.
	_ip_edit.text = NetAddress.format(str(server.ip), int(server.port))
	_join(str(server.ip), int(server.port), _join_password.text)


func _join(address: String, port: int, password: String = "") -> void:
	var err := Net.join(address, port, password)
	if err != OK:
		_status.text = "COULD NOT CONNECT (%s)" % error_string(err)
		return
	_pending_address = NetAddress.format(address, port)
	_status.text = "CONNECTING TO %s" % _pending_address


func _pick_saved(index: int) -> void:
	if index >= 0 and index < _saved_data.size():
		_ip_edit.text = _saved_data[index]


## Stars or unstars the address in the box.
func _toggle_favorite() -> void:
	var parsed := NetAddress.parse(_ip_edit.text, Net.DEFAULT_PORT)
	if not parsed.ok:
		_status.text = str(parsed.error).to_upper()
		return
	var address := NetAddress.format(str(parsed.host), int(parsed.port))
	var starred := Settings.toggle_favorite(address)
	Settings.save_settings()
	_status.text = ("ADDED %s TO FAVORITES" if starred else "REMOVED %s FROM FAVORITES") % address
	_refresh_saved()


func _refresh_saved() -> void:
	if _saved == null:
		return
	_saved.clear()
	_saved_data.clear()
	for address in Settings.favorite_servers:
		_saved_data.append(address)
		_saved.add_item("★  " + address)
	for address in Settings.recent_servers:
		if not Settings.favorite_servers.has(address):
			_saved_data.append(address)
			_saved.add_item("    " + address)
	if _saved.item_count == 0:
		_saved.add_item("Servers you join show up here. Favorite them to keep them.")
		_saved.set_item_disabled(0, true)


func _on_joined() -> void:
	_status.text = "JOINED %s" % Net.server_name.to_upper() if Net.server_name != "" else "JOINED"
	if _pending_address != "":
		Settings.remember_server(_pending_address)
		Settings.save_settings()
		_refresh_saved()
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
	_lobby_players.visible = Net.is_host()
	_lobby_players.select(GameMode.index_of(GameMode.sanitize(Net.mode_id)))
	_lobby_bots.visible = Net.is_host()
	_fill_bots_picker(_lobby_bots, Net.mode_id)
	_lobby_mode.visible = Net.is_host()
	_select_rules(_lobby_mode, Net.rules_id)
	_lobby_map_label.visible = not Net.is_host()
	_lobby_map_label.text = (
		(
			"%s  -  %s  -  %s"
			% [MapList.name_of(Net.map_id), GameMode.name_of(Net.mode_id), GameModes.name_of(Net.rules_id)]
		).to_upper()
	)
	_lobby_net.visible = Net.is_host() or Net.server_name != ""
	if Net.is_host():
		_lobby_net.text = _host_reach_text().to_upper()
	else:
		_lobby_net.text = ("%s  -  waiting for the match to start" % Net.server_name).to_upper()
	var fill := ""
	if Net.is_host() and Net.bot_fill:
		var bots := Settings.bot_count_for(maxi(Net.max_players() - Net.players.size(), 0))
		if bots == 1:
			fill = " + 1 bot"
		elif bots > 1:
			fill = " + %d bots" % bots
	_lobby_title.text = (
		("Lobby %d/%d%s" % [Net.players.size(), Net.max_players(), fill]).to_upper()
	)


func _on_upnp_changed(_state: NetUpnp.State, _message: String) -> void:
	_refresh_lobby()


## Host lobby: how players reach this game (UPnP outcome, or LAN plus manual forwarding).
func _host_reach_text() -> String:
	var port := Settings.host_port
	match Net.upnp.state:
		NetUpnp.State.WORKING, NetUpnp.State.OPEN, NetUpnp.State.FAILED:
			return Net.upnp.message
		_:
			return (
				"LAN on port %d. For internet play, forward UDP %d on your router (or enable UPnP)"
				% [port, port]
			)
