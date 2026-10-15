class_name ScopeOverlay
extends Control
## Bungie-era scope overlays, one identity per WeaponData.ScopeStyle, drawn in _draw with no
## textures. Every size is in reference pixels at 1080p and scaled by u = size.y / 1080, so the
## overlay is resolution independent and ultrawide just gets more mask.
## Client-local: the HUD (local player only) drives it each frame through show_scope().
## Direction: docs/hud/scope_overlay_direction.md.

const REF_HEIGHT := 1080.0
const CIRCLE_SEGMENTS := 96
const CAP_SEGMENTS := 32

## Palette: board "Frozen blue-grey" plus the sodium amber accent; reticle = HUD frame white.
const MASK := Color(0.043, 0.059, 0.078, 1.0)  # near-black blue (#0b0f14)
const BEZEL := Color(0.114, 0.149, 0.188, 1.0)  # #1d2630
const BEZEL_EDGE := Color(0.243, 0.298, 0.353, 1.0)  # #3e4c5a
const BEZEL_LIP := Color(0.431, 0.506, 0.569, 1.0)  # #6e8191
const LINE := Color(0.875, 0.902, 0.918, 0.95)  # #dfe6ea
const LINE_TARGET := Color(1.0, 0.18, 0.15, 0.95)  # HUD RETICLE_TARGET_COLOR
const SHADOW := Color(0.0, 0.0, 0.0, 0.5)
const AMBER := Color(0.878, 0.627, 0.251, 0.95)  # #e0a040, sodium amber lifted for text
const AMBER_DIM := Color(0.769, 0.478, 0.173, 0.8)  # #c47a2c
const GLASS_TINT := Color(0.35, 0.78, 1.0, 0.04)  # HUD SHIELD_FILL, barely there
const SCANLINE := Color(0.0, 0.0, 0.0, 0.045)
const TEXT_SIZE := 26.0
const TEXT_SIZE_SMALL := 18.0

## Ranging targets: the Player capsule is 1.8 m tall and its hurtbox about 0.7 m wide.
const TARGET_HEIGHT_M := 1.8
const TARGET_WIDTH_M := 0.7
const RIFLE_RANGES: Array[float] = [20.0, 40.0, 60.0]
const MARKSMAN_RANGES: Array[float] = [25.0, 50.0, 75.0, 100.0]
## Mil tick spacing candidates; the first that is at least MIL_TICK_MIN_PX (ref px) apart wins.
const MIL_STEPS: Array[int] = [1, 2, 5, 10, 20, 50]
const MIL_TICK_MIN_PX := 12.0

var style: WeaponData.ScopeStyle = WeaponData.ScopeStyle.NONE
## Optical magnification for the readout.
var magnification: float = 1.0
## Current camera vertical FOV in degrees; mil ticks and stadia are true at this FOV.
var view_fov: float = 75.0
var mode_text: String = ""
var on_target: bool = false

var _u: float = 1.0
var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


## Per-frame update from the HUD. blend 0..1 is the zoom fade (alpha); 0 hides the node.
func show_scope(
	p_style: WeaponData.ScopeStyle,
	blend: float,
	p_view_fov: float,
	p_magnification: float,
	p_mode_text: String,
	p_on_target: bool
) -> void:
	style = p_style
	view_fov = p_view_fov
	magnification = p_magnification
	mode_text = p_mode_text
	on_target = p_on_target
	var alpha := clampf(blend, 0.0, 1.0)
	visible = style != WeaponData.ScopeStyle.NONE and alpha > 0.001
	modulate.a = alpha
	if visible:
		queue_redraw()


## Screen pixels per milliradian at the current FOV.
func px_per_mil() -> float:
	var half := tan(deg_to_rad(clampf(view_fov, 1.0, 179.0)) * 0.5)
	return 0.001 / half * size.y * 0.5


## Screen size in pixels of meters seen at distance (pinhole, vertical FOV).
func px_for(meters: float, distance: float) -> float:
	return meters / distance * 1000.0 * px_per_mil()


func _draw() -> void:
	_u = size.y / REF_HEIGHT
	if _font == null:
		_font = ThemeDB.fallback_font
	var c := size * 0.5
	match style:
		WeaponData.ScopeStyle.SIDEARM:
			_draw_sidearm(c)
		WeaponData.ScopeStyle.SERVICE_RIFLE:
			_draw_service_rifle(c)
		WeaponData.ScopeStyle.MARKSMAN:
			_draw_marksman(c)
		WeaponData.ScopeStyle.FIELD:
			_draw_field(c)


# --- Identities ---------------------------------------------------------------------------


## Pistol: compact round eyepiece, thick bezel with four tabs, broken ring + heavy posts.
func _draw_sidearm(c: Vector2) -> void:
	var r := 300.0 * _u
	var pts := _circle_points(c, r, CIRCLE_SEGMENTS)
	_draw_glass(pts)
	_draw_mask(c, pts, 0.94)
	_draw_bezel(pts, 16.0)
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		_draw_tab(c + d * (r + 8.0 * _u), d, 44.0, 16.0)
	var col := _reticle_color()
	for i in 4:
		var a := TAU * i / 4.0 + TAU / 8.0
		_arc(c, 34.0 * _u, a - 0.5, a + 0.5, col, 3.0)
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		_line(c + d * 50.0 * _u, c + d * 96.0 * _u, col, 5.0)
	_dot(c, 3.0, col)
	_text(_mag_text(), c + Vector2(0.0, r - 34.0 * _u), TEXT_SIZE, AMBER)


## Rifle: wide stadium aperture, rail tabs, split horizontal + lower post, width stadia bars.
func _draw_service_rifle(c: Vector2) -> void:
	var hh := 330.0 * _u
	var hw := minf(650.0 * _u, size.x * 0.47)
	var pts := _pill_points(c, hw, hh, CAP_SEGMENTS)
	_draw_glass(pts)
	_draw_mask(c, pts, 0.95)
	_draw_bezel(pts, 14.0)
	_draw_tab(c + Vector2(0.0, -hh - 6.0 * _u), Vector2.UP, 120.0, 14.0)
	_draw_tab(c + Vector2(0.0, hh + 6.0 * _u), Vector2.DOWN, 120.0, 14.0)
	var col := _reticle_color()
	_line(c + Vector2(-140.0, 0.0) * _u, c + Vector2(-20.0, 0.0) * _u, col, 3.0)
	_line(c + Vector2(20.0, 0.0) * _u, c + Vector2(140.0, 0.0) * _u, col, 3.0)
	_line(c + Vector2(-260.0, 0.0) * _u, c + Vector2(-170.0, 0.0) * _u, col, 6.0)
	_line(c + Vector2(170.0, 0.0) * _u, c + Vector2(260.0, 0.0) * _u, col, 6.0)
	_line(c + Vector2(0.0, 20.0) * _u, c + Vector2(0.0, 64.0) * _u, col, 3.0)
	_dot(c, 2.5, col)
	# Simple ranging: a 0.7 m torso fills the bar at its range. Bars sit on the lower post.
	var y := c.y + 100.0 * _u
	for i in RIFLE_RANGES.size():
		var half_w := px_for(TARGET_WIDTH_M, RIFLE_RANGES[i]) * 0.5
		var row_y := y + 34.0 * _u * i
		_line(Vector2(c.x - half_w, row_y), Vector2(c.x + half_w, row_y), AMBER, 2.5)
		_line(Vector2(c.x - half_w, row_y - 6.0 * _u), Vector2(c.x - half_w, row_y), AMBER, 2.5)
		_line(Vector2(c.x + half_w, row_y - 6.0 * _u), Vector2(c.x + half_w, row_y), AMBER, 2.5)
		_text(
			str(int(RIFLE_RANGES[i])),
			Vector2(c.x + maxf(half_w, 20.0 * _u) + 22.0 * _u, row_y + 6.0 * _u),
			TEXT_SIZE_SMALL,
			AMBER_DIM
		)
	# Readouts sit where the flat bottom edge meets the caps, so they never fall under the mask.
	var edge_x := maxf(hw - hh, 120.0 * _u)
	_text(_mag_text(), c + Vector2(edge_x, hh - 44.0 * _u), TEXT_SIZE, AMBER)
	if mode_text != "":
		_text(mode_text, c + Vector2(-edge_x, hh - 44.0 * _u), TEXT_SIZE_SMALL, AMBER_DIM)


## Carbine: big round tube, notched bezel, duplex with mil ticks, stadia ladder, scanlines.
func _draw_marksman(c: Vector2) -> void:
	var r := 470.0 * _u
	var pts := _circle_points(c, r, CIRCLE_SEGMENTS)
	_draw_glass(pts)
	_draw_scanlines(c, r)
	_draw_mask(c, pts, 0.97)
	_draw_bezel(pts, 20.0)
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		var n := d.orthogonal()
		var tip := c + d * (r - 26.0 * _u)
		var base := c + d * (r + 2.0 * _u)
		draw_colored_polygon(
			PackedVector2Array([tip, base + n * 14.0 * _u, base - n * 14.0 * _u]), BEZEL_EDGE
		)
	var col := _reticle_color()
	var inner := r * 0.36
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		_line(c + d * inner, c + d * (r - 4.0 * _u), col, 7.0)
		_line(c + d * 8.0 * _u, c + d * inner, col, 1.5)
	_dot(c, 2.0, col)
	# Mil ticks on the thin crosshair at a readable step (true mils at the current FOV);
	# every fifth tick is major and labelled in mils.
	var mil := px_per_mil()
	var mil_step := MIL_STEPS[MIL_STEPS.size() - 1]
	for candidate in MIL_STEPS:
		if candidate * mil >= MIL_TICK_MIN_PX * _u:
			mil_step = candidate
			break
	var tick_px := mil_step * mil
	if tick_px > 0.0:
		var count := int(inner / tick_px)
		for k in range(1, count + 1):
			var major := k % 5 == 0
			var half := (8.0 if major else 4.0) * _u
			var o := k * tick_px
			for side in [-1.0, 1.0]:
				var so: float = side * o
				_line(c + Vector2(so, -half), c + Vector2(so, half), col, 1.5)
				_line(c + Vector2(-half, so), c + Vector2(half, so), col, 1.5)
			if major:
				_text(str(k * mil_step), c + Vector2(o, 28.0 * _u), TEXT_SIZE_SMALL, AMBER_DIM)
	# Stadia ladder, lower left: each post is a 1.8 m Spartan at its range, feet on the baseline.
	var base_y := c.y + r * 0.50
	var x := c.x - r * 0.62
	var step := 34.0 * _u
	_line(Vector2(x - 14.0 * _u, base_y), Vector2(x + step * 3.0 + 14.0 * _u, base_y), AMBER, 2.5)
	for i in MARKSMAN_RANGES.size():
		var h := px_for(TARGET_HEIGHT_M, MARKSMAN_RANGES[i])
		var px := x + step * i
		_line(Vector2(px, base_y), Vector2(px, base_y - h), AMBER, 3.0)
		_line(Vector2(px - 6.0 * _u, base_y - h), Vector2(px + 6.0 * _u, base_y - h), AMBER, 2.5)
		_text(str(int(MARKSMAN_RANGES[i])), Vector2(px, base_y + 24.0 * _u), TEXT_SIZE_SMALL, AMBER_DIM)
	_text("MIL", c + Vector2(inner + 30.0 * _u, -14.0 * _u), TEXT_SIZE_SMALL, AMBER_DIM)
	_text(_mag_text(), c + Vector2(r * 0.55, r * 0.55), TEXT_SIZE, AMBER)


## Fallback for any other zoomer: chamfered octagon, T-post with a centre circle.
func _draw_field(c: Vector2) -> void:
	var hw := minf(540.0 * _u, size.x * 0.46)
	var hh := 380.0 * _u
	var ch := 130.0 * _u
	var pts := PackedVector2Array([
		c + Vector2(-hw + ch, -hh), c + Vector2(hw - ch, -hh), c + Vector2(hw, -hh + ch),
		c + Vector2(hw, hh - ch), c + Vector2(hw - ch, hh), c + Vector2(-hw + ch, hh),
		c + Vector2(-hw, hh - ch), c + Vector2(-hw, -hh + ch),
	])
	_draw_glass(pts)
	_draw_mask(c, _subdivide(pts, 8), 0.95)
	_draw_bezel(pts, 14.0)
	var col := _reticle_color()
	_line(c + Vector2(-120.0, 0.0) * _u, c + Vector2(-18.0, 0.0) * _u, col, 3.0)
	_line(c + Vector2(18.0, 0.0) * _u, c + Vector2(120.0, 0.0) * _u, col, 3.0)
	_line(c + Vector2(0.0, 18.0) * _u, c + Vector2(0.0, 150.0) * _u, col, 6.0)
	_arc(c, 10.0 * _u, 0.0, TAU, col, 2.0)
	_text(_mag_text(), c + Vector2(0.0, hh - 40.0 * _u), TEXT_SIZE, AMBER)


# --- Helpers ------------------------------------------------------------------------------


func _w(px: float) -> float:
	return maxf(1.0, px * _u)


func _reticle_color() -> Color:
	return LINE_TARGET if on_target else LINE


func _mag_text() -> String:
	return "%.1fx" % magnification


## Line with a dark under-stroke so it reads on snow and on sodium-lit concrete alike.
func _line(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	draw_line(a, b, SHADOW, _w(width) + _w(2.0), true)
	draw_line(a, b, col, _w(width), true)


func _arc(c: Vector2, r: float, a0: float, a1: float, col: Color, width: float) -> void:
	var n := maxi(8, int(absf(a1 - a0) / TAU * CIRCLE_SEGMENTS))
	draw_arc(c, r, a0, a1, n, SHADOW, _w(width) + _w(2.0), true)
	draw_arc(c, r, a0, a1, n, col, _w(width), true)


func _dot(c: Vector2, half: float, col: Color) -> void:
	var h := maxf(1.0, half * _u)
	draw_rect(Rect2(c - Vector2(h + _u, h + _u), Vector2(h + _u, h + _u) * 2.0), SHADOW)
	draw_rect(Rect2(c - Vector2(h, h), Vector2(h, h) * 2.0), col)


func _text(text: String, center: Vector2, ref_size: float, col: Color) -> void:
	if _font == null:
		return
	var fs := maxi(8, int(round(ref_size * _u)))
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := Vector2(center.x - width * 0.5, center.y + fs * 0.35)
	draw_string(_font, pos + Vector2(_u, _u) * 1.5, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SHADOW)
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _circle_points(c: Vector2, r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		pts.append(c + Vector2.from_angle(TAU * i / n) * r)
	return pts


## Horizontal stadium: semicircle caps left and right, flat top and bottom.
func _pill_points(c: Vector2, hw: float, hh: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var off := maxf(hw - hh, 0.0)
	for i in n + 1:
		pts.append(c + Vector2(off, 0.0) + Vector2.from_angle(-PI * 0.5 + PI * i / n) * hh)
	for i in n + 1:
		pts.append(c + Vector2(-off, 0.0) + Vector2.from_angle(PI * 0.5 + PI * i / n) * hh)
	return _subdivide(pts, 6)


## Splits long edges so the radial mask quads stay small.
func _subdivide(pts: PackedVector2Array, parts: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		var steps := parts if a.distance_to(b) > 60.0 * _u else 1
		for k in steps:
			out.append(a.lerp(b, float(k) / steps))
	return out


## Everything outside the (star-shaped around c) aperture, as radial quads to the far edge.
func _draw_mask(c: Vector2, pts: PackedVector2Array, alpha: float) -> void:
	var far := size.length() + 16.0
	var col := Color(MASK, alpha)
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		var fa := c + (a - c).normalized() * far
		var fb := c + (b - c).normalized() * far
		draw_colored_polygon(PackedVector2Array([a, b, fb, fa]), col)


func _draw_glass(pts: PackedVector2Array) -> void:
	draw_colored_polygon(pts, GLASS_TINT)


## Chunky ring: dark body, mid-grey inner edge, thin lit lip on the glass side.
func _draw_bezel(pts: PackedVector2Array, width: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, BEZEL, _w(width), true)
	draw_polyline(closed, BEZEL_EDGE, _w(width * 0.3), true)
	draw_polyline(closed, BEZEL_LIP, _w(1.0), true)


## Rectangular clamp tab straddling the bezel, long side tangent to it.
func _draw_tab(center: Vector2, outward: Vector2, length: float, depth: float) -> void:
	var t := outward.orthogonal() * length * 0.5 * _u
	var n := outward * depth * 0.5 * _u
	var quad := PackedVector2Array([center - t - n, center + t - n, center + t + n, center - t + n])
	draw_colored_polygon(quad, BEZEL)
	var outline := quad.duplicate()
	outline.append(quad[0])
	draw_polyline(outline, BEZEL_EDGE, _w(2.0), true)


## Faint horizontal scanlines inside a circle (one draw_multiline).
func _draw_scanlines(c: Vector2, r: float) -> void:
	var spacing := maxf(3.0, 4.0 * _u)
	var segs := PackedVector2Array()
	var y := -r + spacing
	while y < r:
		var half := sqrt(r * r - y * y)
		segs.append(c + Vector2(-half, y))
		segs.append(c + Vector2(half, y))
		y += spacing
	if segs.size() >= 2:
		draw_multiline(segs, SCANLINE, _w(1.0))
