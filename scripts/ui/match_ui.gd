class_name MatchUI
extends CanvasLayer
## In-match overlay built in code (MenuTheme): kill feed, scoreboard (hold action_scoreboard:
## Tab / Back), win banner (offline), game-over screen (online: Play Again for the host, Quit),
## and the pause panel, shown whenever the mouse is released (Esc / Start, Player's own toggle)
## with Resume and Quit to Menu. Never pauses the tree: the match keeps running, as on Xbox Live.

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
	_build_over()
	_banner = MenuTheme.label("", MenuTheme.TITLE_SIZE, MenuTheme.ACCENT)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.position.y = 140
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.visible = false
	_root.add_child(_banner)
	if net_match != null:
		net_match.kill_feed.connect(add_feed)
		net_match.scores_changed.connect(_on_scores)
		net_match.game_over.connect(_on_game_over)


func _process(delta: float) -> void:
	var over := _over.visible
	var paused := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not over
	if paused != _pause.visible:
		_pause.visible = paused
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


func _unhandled_input(event: InputEvent) -> void:
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
	_board = _panel(Vector2(720, 360))
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
	column.add_child(MenuTheme.button("Quit to Menu", _on_quit))


func _build_over() -> void:
	_over = _panel(Vector2(760, 480))
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	_over.add_child(column)
	_over_title = MenuTheme.label("Game Over", MenuTheme.HEADER_SIZE, MenuTheme.ACCENT)
	column.add_child(_over_title)
	_over_list = VBoxContainer.new()
	column.add_child(_over_list)
	_again = MenuTheme.button("Play Again", _on_play_again)
	column.add_child(_again)
	_quit_over = MenuTheme.button("Quit to Menu", _on_quit)
	column.add_child(_quit_over)


func _on_scores(scores: Dictionary) -> void:
	_scores = scores
	_fill_scores(_board_list, scores)


static func _fill_scores(list: VBoxContainer, scores: Dictionary) -> void:
	for child in list.get_children():
		child.queue_free()
	list.add_child(
		MenuTheme.label("%-20s %6s %6s" % ["Player", "Kills", "Deaths"], 20, MenuTheme.TEXT_DIM)
	)
	var names: Array = scores.keys()
	names.sort_custom(
		func(a: Variant, b: Variant) -> bool: return int(scores[a].kills) > int(scores[b].kills)
	)
	for who: Variant in names:
		var entry: Dictionary = scores[who]
		var text := "%-20s %6d %6d" % [str(who), int(entry.kills), int(entry.deaths)]
		list.add_child(MenuTheme.label(text, 20))


func _on_game_over(winner: String, scores: Dictionary) -> void:
	_over_title.text = ("%s wins" % winner).to_upper()
	_fill_scores(_over_list, scores)
	_again.visible = Net.is_host()
	_over.visible = true
	_pause.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	(_again if _again.visible else _quit_over).grab_focus()


func _on_resume() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_play_again() -> void:
	Net.start_match()


func _on_quit() -> void:
	Net.return_to_menu()
