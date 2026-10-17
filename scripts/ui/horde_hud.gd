class_name HordeHud
extends CanvasLayer
## Horde HUD for the local player (HordeMatch adds it): wave, enemies left, shared lives and
## your points along the top; the countdown between waves in the middle; "DOWN" while you wait
## for a life; and, once the wave is down to its last few (HordeMatch.is_hunting), a marker
## over each remaining enemy, pinned to the screen edge when off screen.

const TOP_FONT_SIZE := 24
## Baseline of the status line: under the HUD's shield bar.
const TOP_LINE_Y := 88.0
const CENTER_FONT_SIZE := 40
const MARKER_SIZE := 10.0
const EDGE_MARGIN := 40.0
const MARKER_HEIGHT := 0.5
## The faction tell: turquoise means enemy.
const ENEMY_COLOR := Color("6cc3bd")
const TEXT_COLOR := Color(0.95, 0.93, 0.88)

var horde: HordeMatch
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
	if horde == null:
		return
	var font := ThemeDB.fallback_font
	var size := _canvas.size
	var parts: Array[String] = []
	if horde.wave > 0:
		parts.append("WAVE %d  %s" % [horde.wave, horde.wave_name().to_upper()])
	if horde.phase == HordeMatch.Phase.WAVE:
		parts.append("ENEMIES %d" % horde.enemies_left())
	parts.append("LIVES %d" % horde.lives)
	if is_instance_valid(player):
		parts.append("POINTS %d" % horde.points_of(player))
	_centered(font, "   ·   ".join(parts), size.x * 0.5, TOP_LINE_Y, TOP_FONT_SIZE, TEXT_COLOR)
	var waiting := (
		horde.phase == HordeMatch.Phase.STARTING or horde.phase == HordeMatch.Phase.INTERMISSION
	)
	if waiting:
		var text := "WAVE %d IN %d" % [horde.wave + 1, ceili(maxf(horde.time_left, 0.0))]
		_centered(font, text, size.x * 0.5, size.y * 0.32, CENTER_FONT_SIZE, TEXT_COLOR)
	if is_instance_valid(player) and horde.is_down(player):
		var text := "DOWN: NO LIVES LEFT. HOLD ON TILL THE ROUND ENDS"
		_centered(font, text, size.x * 0.5, size.y * 0.42, TOP_FONT_SIZE, Color(1, 0.5, 0.4))
	if horde.is_hunting():
		_draw_markers(size)


func _draw_markers(size: Vector2) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var rect := Rect2(Vector2.ONE * EDGE_MARGIN, size - Vector2.ONE * EDGE_MARGIN * 2.0)
	for e in horde.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var world := e.global_position + Vector3.UP * (e.enemy_type.height + MARKER_HEIGHT)
		var behind := camera.is_position_behind(world)
		var screen := camera.unproject_position(world)
		if behind:
			screen = size - screen  # mirror: points the right way along the edge
		if behind or not rect.has_point(screen):
			var centre := size * 0.5
			var dir := (screen - centre).normalized()
			var reach := minf(
				(rect.size.x * 0.5) / maxf(absf(dir.x), 0.001),
				(rect.size.y * 0.5) / maxf(absf(dir.y), 0.001)
			)
			screen = centre + dir * reach
		var s := MARKER_SIZE
		var diamond := PackedVector2Array(
			[
				screen + Vector2(0, -s),
				screen + Vector2(s, 0),
				screen + Vector2(0, s),
				screen + Vector2(-s, 0),
			]
		)
		_canvas.draw_colored_polygon(diamond, ENEMY_COLOR)


func _centered(font: Font, text: String, x: float, y: float, font_size: int, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := Vector2(x - width * 0.5, y)
	var left := HORIZONTAL_ALIGNMENT_LEFT
	_canvas.draw_string_outline(font, at, text, left, -1, font_size, 6, Color.BLACK)
	_canvas.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
