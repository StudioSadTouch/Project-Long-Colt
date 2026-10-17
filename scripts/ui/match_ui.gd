class_name MatchUI
extends CanvasLayer
## In-match overlay built in code (MenuTheme): kill feed, scoreboard (hold action_scoreboard:
## Tab / Back), win banner (offline), game-over screen (online: Play Again for the host, Quit),
## and the pause panel, shown whenever the mouse is released (Esc / Start, Player's own toggle)
## with Resume, Settings and Quit to Menu. Never pauses the tree: the match keeps running, as on
## Xbox Live. The Settings page edits the control options live on the local player and saves on
## Back.

const FEED_LINES := 5
const FEED_TIME := 6.0
const BANNER_TIME := 4.0

var net_match: NetMatch

var _root: Control
var _feed: VBoxContainer
var _board: PanelContainer
var _board_list: VBoxContainer
var _pause: PanelContainer
var _resume: Button
var _settings: PanelContainer
var _settings_first: Control
var _in_settings: bool = false
var _over: PanelContainer
var _over_title: Label
var _over_list: VBoxContainer
var _again: Button
var _quit_over: Button
var _banner: Label
var _banner_left: float = 0.0
var _scores: Dictionary = {}


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = MenuTheme.build()
	add_child(_root)
	_build_feed()
	_build_board()
	_build_pause()
	_build_settings()
	_build_over()
	_banner = MenuTheme.label("", MenuTheme.TITLE_SIZE, MenuTheme.ACCENT)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.position.y = 140
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.visible = false
	_root.add_child(_banner)
	if _is_playtest():
		_build_playtest_tag()
	if net_match != null:
		net_match.kill_feed.connect(add_feed)
		net_match.scores_changed.connect(_on_scores)
		net_match.game_over.connect(_on_game_over)


func _process(delta: float) -> void:
	var over := _over.visible
	var paused := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not over
	if not paused and _in_settings:
		# Resumed straight from the Settings page (click outside the panel): keep the changes.
		_close_settings(false)
	if paused != (_pause.visible or _settings.visible):
		_pause.visible = paused and not _in_settings
		_settings.visible = paused and _in_settings
		if paused:
			_resume.grab_focus()
	_board.visible = not over and InputMap.has_action(&"action_scoreboard")
	_board.visible = _board.visible and Input.is_action_pressed(&"action_scoreboard")
	if _banner_left > 0.0:
		_banner_left -= delta
		_banner.visible = _banner_left > 0.0
	for line: Node in _feed.get_children():
		var age: float = line.get_meta(&"age", 0.0) + delta
		line.set_meta(&"age", age)
		if age > FEED_TIME:
			line.queue_free()


func _input(event: InputEvent) -> void:
	# Esc / B / Start on the Settings page goes back to the pause panel. Caught here, before the
	# Player's _unhandled_input sees action_pause and recaptures the mouse (which would resume).
	if not _settings.visible:
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"action_pause"):
		_close_settings(true)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# Level Editor playtest: F5 or Tab goes straight back to the editor.
	if _is_playtest() and event is InputEventKey and event.pressed and not event.echo:
		var code := (event as InputEventKey).keycode
		if code == KEY_F5 or code == KEY_TAB:
			get_viewport().set_input_as_handled()
			CustomLevels.return_to_editor(get_tree())
			return
	# Esc / B / Start from the pause panel resumes (the Player toggles capture on action_pause).
	if _pause.visible and event.is_action_pressed(&"ui_cancel"):
		_on_resume()
		get_viewport().set_input_as_handled()


func add_feed(text: String) -> void:
	var line := MenuTheme.label(text, 18)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed.add_child(line)
	while _feed.get_child_count() > FEED_LINES:
		var oldest := _feed.get_child(0)
		_feed.remove_child(oldest)
		oldest.queue_free()


func show_banner(text: String) -> void:
	_banner.text = text.to_upper()
	_banner.visible = true
	_banner_left = BANNER_TIME


func _build_feed() -> void:
	_feed = VBoxContainer.new()
	_feed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_feed.position = Vector2(-620, 24)
	_feed.custom_minimum_size = Vector2(600, 0)
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_feed)


func _panel(min_size: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = min_size
	panel.position = -min_size * 0.5
	panel.visible = false
	_root.add_child(panel)
	return panel


func _build_board() -> void:
	_board = _panel(Vector2(720, 600))
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_list = VBoxContainer.new()
	_board.add_child(_board_list)


func _build_pause() -> void:
	_pause = _panel(Vector2(440, 260))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	_pause.add_child(column)
	column.add_child(MenuTheme.label("Paused", MenuTheme.HEADER_SIZE, MenuTheme.ACCENT))
	_resume = MenuTheme.button("Resume", _on_resume)
	column.add_child(_resume)
	column.add_child(MenuTheme.button("Settings", _open_settings))
	column.add_child(MenuTheme.button(_quit_text(), _on_quit))


## Control options only: armor colour and keybinds stay on the main menu (colour is sent to the
## other players on join, so changing it mid-match would need a network update).
func _build_settings() -> void:
	_settings = _panel(Vector2(820, 540))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	_settings.add_child(column)
	column.add_child(MenuTheme.label("Settings", MenuTheme.HEADER_SIZE, MenuTheme.ACCENT))
	var mouse := MenuTheme.slider(
		column, "Mouse sensitivity", 0.25, 3.0, Settings.mouse_sensitivity_scale
	)
	mouse.value_changed.connect(
		func(v: float) -> void:
			Settings.mouse_sensitivity_scale = v
			_apply_settings()
	)
	_settings_first = mouse
	var stick := MenuTheme.slider(
		column, "Stick sensitivity", 0.25, 3.0, Settings.stick_sensitivity_scale
	)
	stick.value_changed.connect(
		func(v: float) -> void:
			Settings.stick_sensitivity_scale = v
			_apply_settings()
	)
	var fov_value := Settings.fov if Settings.fov > 0.0 else 75.0
	var fov := MenuTheme.slider(column, "Field of view", Settings.FOV_MIN, Settings.FOV_MAX, fov_value)
	fov.step = 1.0
	fov.value_changed.connect(
		func(v: float) -> void:
			Settings.fov = v
			_apply_settings()
	)
	var assist := CheckButton.new()
	assist.text = "MOUSE AIM ASSIST"
	assist.button_pressed = Settings.mouse_aim_assist
	assist.focus_mode = Control.FOCUS_ALL
	assist.toggled.connect(
		func(on: bool) -> void:
			Settings.mouse_aim_assist = on
			_apply_settings()
	)
	column.add_child(assist)
	var third := CheckButton.new()
	third.text = "THIRD-PERSON CAMERA (T)"
	third.button_pressed = Settings.third_person
	third.focus_mode = Control.FOCUS_ALL
	third.toggled.connect(
		func(on: bool) -> void:
			Settings.third_person = on
			_apply_settings()
	)
	column.add_child(third)
	var shoulder := CheckButton.new()
	shoulder.text = "LEFT SHOULDER (B)"
	shoulder.button_pressed = Settings.left_shoulder
	shoulder.focus_mode = Control.FOCUS_ALL
	shoulder.toggled.connect(
		func(on: bool) -> void:
			Settings.left_shoulder = on
			_apply_settings()
	)
	column.add_child(shoulder)
	var full := CheckButton.new()
	full.text = "FULLSCREEN (F11)"
	full.button_pressed = Settings.fullscreen
	full.focus_mode = Control.FOCUS_ALL
	full.toggled.connect(
		func(on: bool) -> void:
			Settings.fullscreen = on
			Settings.apply_display()
	)
	column.add_child(full)
	column.add_child(MenuTheme.button("Back", _close_settings.bind(true)))


func _build_over() -> void:
	_over = _panel(Vector2(760, 760))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	_over.add_child(column)
	_over_title = MenuTheme.label("Game Over", MenuTheme.HEADER_SIZE, MenuTheme.ACCENT)
	column.add_child(_over_title)
	_over_list = VBoxContainer.new()
	column.add_child(_over_list)
	_again = MenuTheme.button("Play Again", _on_play_again)
	column.add_child(_again)
	_quit_over = MenuTheme.button(_quit_text(), _on_quit)
	column.add_child(_quit_over)


func _on_scores(scores: Dictionary) -> void:
	_scores = scores
	_fill_scores(_board_list, scores, _captures())


## Rebuild the scoreboard from the last scores (CtfMatch calls it when captures change).
func refresh_scores() -> void:
	_on_scores(_scores)


## CTF: team id -> captures (CtfMatch, authoritative); {} in kill modes.
func _captures() -> Dictionary:
	var ctf := net_match.get_node_or_null(^"Ctf") as CtfMatch if net_match != null else null
	return ctf.captures if ctf != null else {}


## captures: CTF team totals (team headers show captures, rows gain a Caps column); {} = kills.
static func _fill_scores(
	list: VBoxContainer, scores: Dictionary, captures: Dictionary = {}
) -> void:
	for child in list.get_children():
		child.queue_free()
	var ctf := not captures.is_empty()
	# Horde: points (HordeMatch's per-kill values) get a column and decide the order.
	var points := false
	for entry: Dictionary in scores.values():
		points = points or entry.has("points")
	var header := "%-20s %6s %6s" % ["Player", "Kills", "Deaths"]
	if ctf:
		header += " %6s" % "Caps"
	if points:
		header += " %6s" % "Points"
	list.add_child(MenuTheme.label(header, 20, MenuTheme.TEXT_DIM))
	var names: Array = scores.keys()
	var key := "points" if points else "kills"
	names.sort_custom(
		func(a: Variant, b: Variant) -> bool:
			return int(scores[a].get(key, 0)) > int(scores[b].get(key, 0))
	)
	var totals := GameMode.team_totals(scores)
	if ctf:
		totals = captures.duplicate()
	var teams: Array = []
	for who: Variant in names:
		var team := int(scores[who].get("team", -1))
		if GameMode.is_team_id(team) and not teams.has(team):
			teams.append(team)
	if teams.is_empty():
		for who: Variant in names:
			list.add_child(MenuTheme.label(_score_line(str(who), scores[who], ctf, points), 20))
		return
	teams.sort_custom(func(a: int, b: int) -> bool: return int(totals[a]) > int(totals[b]))
	for team: int in teams:
		var tint := GameMode.team_color(team).lightened(0.35)
		var team_line := "%-20s %6d" % [GameMode.team_name(team), int(totals.get(team, 0))]
		if ctf:
			team_line += " captures"
		list.add_child(MenuTheme.label(team_line, 22, tint))
		for who: Variant in names:
			if int(scores[who].get("team", -1)) == team:
				var line := _score_line("  " + str(who), scores[who], ctf)
				list.add_child(MenuTheme.label(line, 18, tint))


static func _score_line(
	who: String, entry: Dictionary, caps: bool = false, points: bool = false
) -> String:
	var line := "%-20s %6d %6d" % [who, int(entry.kills), int(entry.deaths)]
	if caps:
		line += " %6d" % int(entry.get("caps", 0))
	if points:
		line += " %6d" % int(entry.get("points", 0))
	return line


func _on_game_over(winner: String, scores: Dictionary) -> void:
	_over_title.text = ("%s wins" % winner).to_upper()
	_fill_scores(_over_list, scores, _captures())
	# Offline (Horde's game over): Play Again restarts the same map and rules.
	_again.visible = Net.is_host() or not Net.is_online()
	_over.visible = true
	_pause.visible = false
	if _in_settings:
		_close_settings(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	(_again if _again.visible else _quit_over).grab_focus()


func _open_settings() -> void:
	_in_settings = true
	_pause.visible = false
	_settings.visible = true
	_settings_first.grab_focus()


## Saves and leaves the Settings page; `to_pause` shows the pause panel again.
func _close_settings(to_pause: bool) -> void:
	_in_settings = false
	_settings.visible = false
	Settings.save_settings()
	if to_pause:
		_pause.visible = true
		_resume.grab_focus()


func _apply_settings() -> void:
	if net_match != null:
		Settings.apply_to_player(net_match.local_player)


func _on_resume() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_play_again() -> void:
	if Net.is_online():
		Net.start_match()
	else:
		Net.start_offline(Net.map_id, Net.mode_id, Net.rules_id)


func _on_quit() -> void:
	if _is_playtest():
		CustomLevels.return_to_editor(get_tree())
		return
	Net.return_to_menu()


## A Level Editor playtest (the editor's level, offline) goes back to the editor instead of the menu.
func _is_playtest() -> bool:
	return CustomLevels.playtest_active and Net.map_id == CustomLevels.PLAYTEST_ID


func _quit_text() -> String:
	return "Back to Editor" if _is_playtest() else "Quit to Menu"


func _build_playtest_tag() -> void:
	var tag := MenuTheme.label("Playtest  ·  F5 back to the editor", 18, MenuTheme.ACCENT)
	tag.set_anchors_preset(Control.PRESET_CENTER_TOP)
	tag.position = Vector2(-200, 14)
	tag.custom_minimum_size = Vector2(400, 0)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(tag)
