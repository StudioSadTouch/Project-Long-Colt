class_name CtfHud
extends CanvasLayer
## Capture the Flag HUD for the local player (CtfMatch adds it): the capture score at the top,
## a marker over each flag (pinned to the screen edge when it is off screen or behind you) with
## its state and distance, and while you carry the enemy flag a prompt plus a marker on your
## own base. Drawn with the active camera, so it works in first and third person.

const EDGE_MARGIN := 48.0
const MARKER_SIZE := 13.0
const FONT_SIZE := 18
const SCORE_FONT_SIZE := 26
## Markers float this far above the flag's foot (or carrier's feet).
const MARKER_HEIGHT := 2.7

var ctf: CtfMatch
var player: Player

var _canvas: Control


func _ready() -> void:
	layer = 5
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_hud)
	add_child(_canvas)


func _process(_delta: float) -> void:
	_canvas.queue_redraw()


func _draw_hud() -> void:
	if ctf == null or not is_instance_valid(player):
		return
	var font := ThemeDB.fallback_font
	var size := _canvas.size
	var my_team := ArenaEvents.team_of(player)
	_draw_score(font, size)
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	for team: int in GameMode.TEAMS:
		var flag := ctf.flag_of(team)
		if flag.is_empty():
			continue
		var color := GameMode.team_color(team).lightened(0.35)
		var where := ctf.flag_position(flag)
		var label := "%s FLAG" % ("YOUR" if team == my_team else "ENEMY")
		match int(flag.state):
			CtfMatch.FlagState.CARRIED:
				label += " - TAKEN" if flag.carrier != player else ""
			CtfMatch.FlagState.DROPPED:
				label += " - DROPPED"
		if flag.state == CtfMatch.FlagState.CARRIED and flag.carrier == player:
			continue  # it's on your back
		var carrying := not ctf.carried_by(player).is_empty()
		if carrying and team == my_team and flag.state == CtfMatch.FlagState.HOME:
			continue  # drawn below as YOUR BASE (same spot)
		_draw_marker(font, camera, where + Vector3.UP * MARKER_HEIGHT, color, label, size)
	var mine := ctf.carried_by(player)
	if not mine.is_empty() and GameMode.is_team_id(my_team):
		var home: Vector3 = ctf.flag_of(my_team).home
		var tint := GameMode.team_color(my_team).lightened(0.45)
		_draw_marker(font, camera, home + Vector3.UP * 1.5, tint, "YOUR BASE", size)
		var own := ctf.flag_of(my_team)
		var prompt := "YOU HAVE THE FLAG - TAKE IT TO YOUR BASE"
		if own.state != CtfMatch.FlagState.HOME:
			prompt = "YOU HAVE THE FLAG - YOUR FLAG MUST BE HOME TO SCORE"
		var width := font.get_string_size(prompt, HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE).x
		_text(font, Vector2((size.x - width) * 0.5, size.y * 0.72), prompt, FONT_SIZE, tint)


func _draw_score(font: Font, size: Vector2) -> void:
	var red := int(ctf.captures.get(GameMode.TEAM_RED, 0))
	var blue := int(ctf.captures.get(GameMode.TEAM_BLUE, 0))
	var left := "RED %d" % red
	var right := "%d BLUE" % blue
	var mid := "  -  "
	var y := 128.0  # under the HUD's team-name label (68-98 px)
	var lw := font.get_string_size(left, HORIZONTAL_ALIGNMENT_LEFT, -1, SCORE_FONT_SIZE).x
	var mw := font.get_string_size(mid, HORIZONTAL_ALIGNMENT_LEFT, -1, SCORE_FONT_SIZE).x
	var x := size.x * 0.5 - mw * 0.5
	_text(font, Vector2(x - lw, y), left, SCORE_FONT_SIZE, GameMode.team_color(GameMode.TEAM_RED).lightened(0.4))
	_text(font, Vector2(x, y), mid, SCORE_FONT_SIZE, Color(0.85, 0.85, 0.85))
	_text(font, Vector2(x + mw, y), right, SCORE_FONT_SIZE, GameMode.team_color(GameMode.TEAM_BLUE).lightened(0.4))
	var caption := "CAPTURE THE FLAG - FIRST TO %d" % ctf.capture_limit
	var cw := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	_text(font, Vector2((size.x - cw) * 0.5, y + 20.0), caption, 14, Color(0.75, 0.75, 0.75, 0.8))


func _draw_marker(
	font: Font, camera: Camera3D, world: Vector3, color: Color, label: String, size: Vector2
) -> void:
	var behind := camera.is_position_behind(world)
	var p := camera.unproject_position(world)
	var centre := size * 0.5
	if behind:
		p = centre + (centre - p)  # mirror: something behind you shows at the far edge
	var rect := Rect2(Vector2.ONE * EDGE_MARGIN, size - Vector2.ONE * EDGE_MARGIN * 2.0)
	var pinned := behind or not rect.has_point(p)
	if pinned:
		var dir := (p - centre)
		if dir.length_squared() < 1.0:
			dir = Vector2.DOWN
		# Scale the direction until it touches the margin rectangle.
		var half := rect.size * 0.5
		var k := minf(
			half.x / maxf(absf(dir.x), 0.001), half.y / maxf(absf(dir.y), 0.001)
		)
		p = centre + dir * k
	var s := MARKER_SIZE
	var diamond := PackedVector2Array([p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0)])
	_canvas.draw_colored_polygon(diamond, Color(color, 0.85))
	_canvas.draw_polyline(diamond + PackedVector2Array([diamond[0]]), Color(0, 0, 0, 0.6), 2.0)
	var distance := 0.0
	if is_instance_valid(player):
		distance = player.global_position.distance_to(world - Vector3.UP * MARKER_HEIGHT)
	var text := "%s  %dm" % [label, roundi(distance)]
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var at := p + Vector2(-w * 0.5, -s - 6.0)
	at.x = clampf(at.x, 4.0, size.x - w - 4.0)
	at.y = maxf(at.y, FONT_SIZE + 2.0)
	_text(font, at, text, FONT_SIZE, color)


func _text(font: Font, at: Vector2, text: String, font_size: int, color: Color) -> void:
	_canvas.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.75))
	_canvas.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
