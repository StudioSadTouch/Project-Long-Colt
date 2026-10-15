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
const PLATE := Color(0.075, 0.098, 0.125, 0.94)  # readout backing, between mask and bezel
const LINE := Color(0.875, 0.902, 0.918, 0.97)  # #dfe6ea
const LINE_TARGET := Color(1.0, 0.18, 0.15, 0.97)  # HUD RETICLE_TARGET_COLOR
const OUTLINE := Color(0.02, 0.027, 0.035, 0.72)  # dark halo under every reticle element
const AMBER := Color(0.878, 0.627, 0.251, 1.0)  # #e0a040, sodium amber lifted for text
const AMBER_DIM := Color(0.82, 0.53, 0.2, 0.95)  # toward #c47a2c, for range numerals
const GLASS_TINT := Color(0.35, 0.78, 1.0, 0.04)  # HUD SHIELD_FILL, barely there
const RIM_SHADE := Color(0.02, 0.03, 0.04, 0.035)  # per band; bands stack toward the rim
const RIM_BANDS := 8
const SCANLINE := Color(0.0, 0.0, 0.0, 0.045)

## Type sizes (ref px): magnification, fire mode, range / mil numerals.
const TEXT_MAG := 26.0
const TEXT_MODE := 22.0
const TEXT_RANGE := 18.0
## Reticle strokes never go under this many screen px; halo is this many ref px per side.
const RETICLE_MIN_PX := 2.0
const HALO_PX := 1.5

## Ranging: the Player capsule is 1.8 m tall. Stadia are feet lines: hold the head on the
## centre and the feet land on the bar for that range.
const TARGET_HEIGHT_M := 1.8
const RIFLE_RANGES: Array[float] = [20.0, 40.0]
const MARKSMAN_RANGES: Array[float] = [25.0, 50.0, 75.0]
## Mil tick spacing candidates; the first that is at least MIL_TICK_MIN_PX (ref px) apart wins.
const MIL_STEPS: Array[int] = [1, 2, 5, 10, 20, 50]
const MIL_TICK_MIN_PX := 14.0

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


## Per-frame update from the HUD. blend 0..1 is the zoom fade-in (alpha); 0 hides the node.
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


## Pistol: compact round eyepiece, heavy bezel with three tabs and the readout plate, broken
## ring + heavy posts. No ranging: the fastest read of the set.
func _draw_sidearm(c: Vector2) -> void:
	var r := 300.0 * _u
	var bezel := 28.0
	var pts := _circle_points(c, r, CIRCLE_SEGMENTS)
	_draw_glass(c, pts, 50.0)
	_draw_mask(c, pts, 0.94)
	_draw_bezel(c, pts, bezel)
	for i in 3:
		var d := Vector2.from_angle(PI + TAU * i / 4.0)  # left, top, right
		_draw_tab(c + d * (r + bezel * 0.5 * _u), d, 76.0, 40.0)
	var col := _reticle_color()
	for i in 4:
		var a := TAU * i / 4.0 + TAU / 8.0
		_arc(c, 38.0 * _u, a - 0.5, a + 0.5, col, 5.0)
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		_line(c + d * 54.0 * _u, c + d * 106.0 * _u, col, 7.0)
	_dot(c, 4.0, col)
	_plate(_mag_text(), c + Vector2(0.0, r + bezel * 0.5 * _u), TEXT_MAG, AMBER)


## Rifle: wide stadium aperture, rail tabs, split horizontal + lower post, two bold feet-line
## stadia (20 / 40 m) on the post.
func _draw_service_rifle(c: Vector2) -> void:
	var hh := 330.0 * _u
	var hw := minf(650.0 * _u, size.x * 0.46)
	var bezel := 24.0
	var pts := _pill_points(c, hw, hh, CAP_SEGMENTS)
	_draw_glass(c, pts, 60.0)
	_draw_mask(c, pts, 0.95)
	_draw_bezel(c, pts, bezel)
	_draw_tab(c + Vector2(0.0, -hh - bezel * 0.5 * _u), Vector2.UP, 170.0, 38.0)
	_draw_tab(c + Vector2(0.0, hh + bezel * 0.5 * _u), Vector2.DOWN, 170.0, 38.0)
	var col := _reticle_color()
	var feet: Array[float] = []
	for rng in RIFLE_RANGES:
		feet.append(px_for(TARGET_HEIGHT_M, rng))
	var post_end := maxf(70.0 * _u, feet[0] + 18.0 * _u)
	_line(c + Vector2(-150.0, 0.0) * _u, c + Vector2(-22.0, 0.0) * _u, col, 4.0)
	_line(c + Vector2(22.0, 0.0) * _u, c + Vector2(150.0, 0.0) * _u, col, 4.0)
	_line(c + Vector2(-280.0, 0.0) * _u, c + Vector2(-185.0, 0.0) * _u, col, 6.0)
	_line(c + Vector2(185.0, 0.0) * _u, c + Vector2(280.0, 0.0) * _u, col, 6.0)
	_line(c + Vector2(0.0, 22.0 * _u), c + Vector2(0.0, post_end), col, 4.0)
	_dot(c, 3.0, col)
	for i in RIFLE_RANGES.size():
		var y := c.y + feet[i]
		var half_w := 36.0 * _u
		_line(Vector2(c.x - half_w, y), Vector2(c.x + half_w, y), AMBER, 5.0)
		_line(Vector2(c.x - half_w, y - 12.0 * _u), Vector2(c.x - half_w, y), AMBER, 5.0)
		_line(Vector2(c.x + half_w, y - 12.0 * _u), Vector2(c.x + half_w, y), AMBER, 5.0)
		_text(
			str(int(RIFLE_RANGES[i])),
			Vector2(c.x + half_w + 26.0 * _u, y - 4.0 * _u),
			TEXT_RANGE,
			AMBER_DIM
		)
	# Readout plates sit on the flat bottom bezel, clear of the centre tab.
	var edge_x := maxf(hw - hh, 150.0 * _u)
	var plate_y := c.y + hh + bezel * 0.5 * _u
	_plate(_mag_text(), Vector2(c.x + edge_x, plate_y), TEXT_MAG, AMBER)
	if mode_text != "":
		_plate(mode_text, Vector2(c.x - edge_x, plate_y), TEXT_MODE, AMBER)


## Carbine: big round tube, notched bezel, duplex with true mil ticks, feet-line stadia stack
## (25 / 50 / 75 m) hanging from the lower post, faint scanlines.
func _draw_marksman(c: Vector2) -> void:
	var r := 470.0 * _u
	var bezel := 34.0
	var pts := _circle_points(c, r, CIRCLE_SEGMENTS)
	_draw_glass(c, pts, 80.0)
	_draw_scanlines(c, r)
	_draw_mask(c, pts, 0.97)
	_draw_bezel(c, pts, bezel)
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		var n := d.orthogonal()
		var tip := c + d * (r - 30.0 * _u)
		var base := c + d * (r + 4.0 * _u)
		var notch := PackedVector2Array([tip, base + n * 22.0 * _u, base - n * 22.0 * _u])
		draw_colored_polygon(notch, BEZEL)
		var notch_edge := notch.duplicate()
		notch_edge.append(notch[0])
		draw_polyline(notch_edge, BEZEL_LIP, _w(2.0), true)
	var col := _reticle_color()
	var inner := r * 0.36
	for i in 4:
		var d := Vector2.from_angle(TAU * i / 4.0)
		_line(c + d * inner, c + d * (r - 2.0 * _u), col, 6.0)
		_line(c + d * 10.0 * _u, c + d * inner, col, 2.5)
	_dot(c, 3.0, col)
	# Mil ticks on the horizontal only (lead reads; no bullet drop, and down carries the
	# stadia). Every fifth is major; only the right-hand majors are labelled.
	var mil := px_per_mil()
	var mil_step := MIL_STEPS[MIL_STEPS.size() - 1]
	for candidate in MIL_STEPS:
		if candidate * mil >= MIL_TICK_MIN_PX * _u:
			mil_step = candidate
			break
	var tick_px := mil_step * mil
	if tick_px > 0.0:
		var count := int((inner - 6.0 * _u) / tick_px)
		for k in range(1, count + 1):
			var major := k % 5 == 0
			var half := (11.0 if major else 6.0) * _u
			var o := k * tick_px
			var tick_w := 3.0 if major else 2.0
			_line(c + Vector2(o, -half), c + Vector2(o, half), col, tick_w)
			_line(c + Vector2(-o, -half), c + Vector2(-o, half), col, tick_w)
			if major:
				_text(str(k * mil_step), c + Vector2(o, 30.0 * _u), TEXT_RANGE, AMBER_DIM)
	# Stadia stack: graduated amber feet lines on the lower post, labels to the right.
	for i in MARKSMAN_RANGES.size():
		var y := px_for(TARGET_HEIGHT_M, MARKSMAN_RANGES[i])
		if y > inner - 8.0 * _u:
			continue
		var half_w := (30.0 - 7.0 * i) * _u
		var p := c + Vector2(0.0, y)
		_line(p - Vector2(half_w, 0.0), p + Vector2(half_w, 0.0), AMBER, 4.0)
		_text(
			str(int(MARKSMAN_RANGES[i])),
			p + Vector2(half_w + 22.0 * _u, 0.0),
			TEXT_RANGE,
			AMBER_DIM
		)
	_plate(_mag_text(), c + Vector2.from_angle(PI * 0.25) * (r + bezel * 0.5 * _u), TEXT_MAG, AMBER)


## Fallback for any other zoomer: chamfered octagon, T-post with a centre circle.
func _draw_field(c: Vector2) -> void:
	var hw := minf(540.0 * _u, size.x * 0.45)
	var hh := 380.0 * _u
	var ch := 130.0 * _u
	var bezel := 24.0
	var corners := PackedVector2Array(
		[
			c + Vector2(-hw + ch, -hh),
			c + Vector2(hw - ch, -hh),
			c + Vector2(hw, -hh + ch),
			c + Vector2(hw, hh - ch),
			c + Vector2(hw - ch, hh),
			c + Vector2(-hw + ch, hh),
			c + Vector2(-hw, hh - ch),
			c + Vector2(-hw, -hh + ch),
		]
	)
	var pts := _subdivide(corners, 8)
	_draw_glass(c, pts, 60.0)
	_draw_mask(c, pts, 0.95)
	_draw_bezel(c, pts, bezel)
	var col := _reticle_color()
	_line(c + Vector2(-130.0, 0.0) * _u, c + Vector2(-20.0, 0.0) * _u, col, 4.0)
	_line(c + Vector2(20.0, 0.0) * _u, c + Vector2(130.0, 0.0) * _u, col, 4.0)
	_line(c + Vector2(0.0, 20.0) * _u, c + Vector2(0.0, 160.0) * _u, col, 6.0)
	_arc(c, 12.0 * _u, 0.0, TAU, col, 3.0)
	_plate(_mag_text(), c + Vector2(0.0, hh + bezel * 0.5 * _u), TEXT_MAG, AMBER)


# --- Helpers ------------------------------------------------------------------------------


## Hardware width: ref px to screen px, at least 1 px.
func _w(px: float) -> float:
	return maxf(1.0, px * _u)


## Reticle width: ref px to screen px, at least RETICLE_MIN_PX.
func _rw(px: float) -> float:
	return maxf(RETICLE_MIN_PX, px * _u)


func _halo() -> float:
	return maxf(1.0, HALO_PX * _u)


func _reticle_color() -> Color:
	return LINE_TARGET if on_target else LINE


func _mag_text() -> String:
	return "%.1fx" % magnification


## Line with a dark halo on every side (ends included) so it reads on snow and dark walls.
func _line(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var w := _rw(width)
	var h := _halo()
	var dir := (b - a).normalized()
	draw_line(a - dir * h, b + dir * h, OUTLINE, w + h * 2.0, true)
	draw_line(a, b, col, w, true)


func _arc(c: Vector2, r: float, a0: float, a1: float, col: Color, width: float) -> void:
	var w := _rw(width)
	var h := _halo()
	var n := maxi(8, int(absf(a1 - a0) / TAU * CIRCLE_SEGMENTS))
	var pad := 0.0 if absf(a1 - a0) >= TAU else h / maxf(r, 1.0)
	draw_arc(c, r, a0 - pad, a1 + pad, n, OUTLINE, w + h * 2.0, true)
	draw_arc(c, r, a0, a1, n, col, w, true)


func _dot(c: Vector2, half: float, col: Color) -> void:
	var s := maxf(RETICLE_MIN_PX * 0.5, half * _u)
	var h := _halo()
	draw_rect(Rect2(c - Vector2(s + h, s + h), Vector2(s + h, s + h) * 2.0), OUTLINE)
	draw_rect(Rect2(c - Vector2(s, s), Vector2(s, s) * 2.0), col)


func _font_px(ref_size: float) -> int:
	return maxi(10, int(round(ref_size * _u)))


## Text centred on a point, with a dark outline.
func _text(text: String, center: Vector2, ref_size: float, col: Color) -> void:
	if _font == null:
		return
	var fs := _font_px(ref_size)
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := Vector2(center.x - width * 0.5, center.y + fs * 0.36)
	var outline := maxi(2, int(round(4.0 * _u)))
	draw_string_outline(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline, OUTLINE)
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## Military readout: amber text on a small dark plate with a bevelled edge.
func _plate(text: String, center: Vector2, ref_size: float, col: Color) -> void:
	if _font == null:
		return
	var fs := _font_px(ref_size)
	var width := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var plate_size := Vector2(width + 26.0 * _u, fs * 1.35)
	var rect := Rect2(center - plate_size * 0.5, plate_size)
	draw_rect(rect, PLATE)
	draw_rect(rect, BEZEL_EDGE, false, _w(2.0))
	var lip := _w(1.5)
	draw_line(
		rect.position + Vector2(lip * 2.0, lip * 1.5),
		Vector2(rect.end.x - lip * 2.0, rect.position.y + lip * 1.5),
		BEZEL_LIP,
		lip
	)
	_text(text, center, ref_size, col)


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


## Splits long edges so radial mask quads and offset rings stay small.
func _subdivide(pts: PackedVector2Array, parts: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		var steps := parts if a.distance_to(b) > 60.0 * _u else 1
		for k in steps:
			out.append(a.lerp(b, float(k) / steps))
	return out


## Mitred offset of a convex outline around c: positive grows it, negative shrinks it.
func _offset(c: Vector2, pts: PackedVector2Array, d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var p := pts[i]
		var n1 := _edge_normal(c, pts[(i + n - 1) % n], p)
		var n2 := _edge_normal(c, p, pts[(i + 1) % n])
		var m := (n1 + n2).normalized()
		if m == Vector2.ZERO:
			m = (p - c).normalized()
		var k := maxf(m.dot(n1 if n1 != Vector2.ZERO else m), 0.3)
		out.append(p + m * (d / k))
	return out


func _edge_normal(c: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var e := (b - a).orthogonal().normalized()
	if e.dot((a + b) * 0.5 - c) < 0.0:
		e = -e
	return e


## Band between two outlines with the same point count.
func _draw_ring(inner: PackedVector2Array, outer: PackedVector2Array, col: Color) -> void:
	var n := inner.size()
	for i in n:
		var j := (i + 1) % n
		draw_colored_polygon(PackedVector2Array([inner[i], inner[j], outer[j], outer[i]]), col)


func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	out.append(pts[0])
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


## Glass: faint cyan tint plus stacked dark bands toward the rim for depth (rim_depth ref px).
func _draw_glass(c: Vector2, pts: PackedVector2Array, rim_depth: float) -> void:
	draw_colored_polygon(pts, GLASS_TINT)
	for k in RIM_BANDS:
		var inner := _offset(c, pts, -rim_depth * _u * float(k + 1) / RIM_BANDS)
		_draw_ring(inner, pts, RIM_SHADE)


## Chunky bezel outside the aperture: dark body, lit inner chamfer, 2 px glass lip, rim edge.
func _draw_bezel(c: Vector2, pts: PackedVector2Array, width: float) -> void:
	var outer := _offset(c, pts, width * _u)
	var chamfer := _offset(c, pts, width * 0.3 * _u)
	_draw_ring(pts, outer, BEZEL)
	_draw_ring(pts, chamfer, BEZEL_EDGE)
	draw_polyline(_closed(_offset(c, pts, _w(1.0))), BEZEL_LIP, _w(2.0), true)
	draw_polyline(_closed(outer), BEZEL_EDGE, _w(2.0), true)


## Rectangular clamp tab straddling the bezel, long side tangent to it, with a lit edge.
func _draw_tab(center: Vector2, outward: Vector2, length: float, depth: float) -> void:
	var t := outward.orthogonal() * length * 0.5 * _u
	var n := outward * depth * 0.5 * _u
	var quad := PackedVector2Array([center - t - n, center + t - n, center + t + n, center - t + n])
	draw_colored_polygon(quad, BEZEL)
	draw_polyline(_closed(quad), BEZEL_EDGE, _w(3.0), true)
	var inset := outward * _w(4.0)
	draw_line(
		center - t * 0.85 + n - inset, center + t * 0.85 + n - inset, BEZEL_LIP, _w(2.0), true
	)


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
