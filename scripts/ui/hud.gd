extends CanvasLayer
## Combat HUD, Bungie-era: chunky shield meter top centre with segmented health under it,
## low-shield flash + beep hook, ammo and fire mode bottom right, a bloom-tracking crosshair,
## and a Halo CE-style scope overlay for weapons with data.zoom_overlay.
## No audio here: listen to sfx_event(name) (names: "low_shield_beep", "shield_broken",
## "shield_recharge", "shield_full") or low_shield_warning(active).

signal sfx_event(event: StringName)
signal low_shield_warning(active: bool)

const TICK_LENGTH := 6.0
const TICK_WIDTH := 2.0
const MIN_GAP := 3.0
const HIT_FLASH_TIME := 0.12

## Shield meter (top centre, ShieldMeter node).
const SHIELD_FILL := Color(0.35, 0.78, 1.0, 0.95)
const SHIELD_LOW_FILL := Color(1.0, 0.3, 0.2, 0.95)
const SHIELD_EMPTY := Color(0.05, 0.07, 0.09, 0.7)
const FRAME_COLOR := Color(0.75, 0.8, 0.82, 0.9)
const HEALTH_FILL := Color(0.95, 0.85, 0.35, 0.95)
const HEALTH_EMPTY := Color(0.12, 0.1, 0.06, 0.7)
const SHIELD_BAR_HEIGHT := 18.0
const HEALTH_BAR_HEIGHT := 7.0
const HEALTH_BAR_WIDTH_FRACTION := 0.6
const BAR_GAP := 6.0
## Scope overlay.
const SCOPE_RADIUS_FRACTION := 0.44
const SCOPE_SEGMENTS := 64
const SCOPE_COLOR := Color(0.0, 0.0, 0.0, 1.0)
const SCOPE_RETICLE := Color(0.85, 0.95, 0.85, 0.9)

@export var holder_path: NodePath
@export var health_path: NodePath
## Shield fraction (0..1) at or below which the meter flashes and beeps.
@export_range(0.0, 1.0) var low_shield_threshold: float = 0.25
## Seconds between low_shield_beep events while the warning is active.
@export var low_shield_beep_interval: float = 0.5
## Flashes per second while low.
@export var low_shield_flash_rate: float = 4.0
@export var health_segments: int = 5

var _holder: WeaponHolder
var _weapon: Weapon
var _hit_flash: float = 0.0
var _hit_color: Color = Weapon.zone_color(Weapon.HitZone.BODY)
var _health: HealthShield
var _shield_fraction: float = 1.0
var _health_fraction: float = 1.0
var _low_shield: bool = false
var _beep_left: float = 0.0
var _time: float = 0.0

@onready var ammo_label: Label = $Ammo
@onready var mode_label: Label = $FireMode
@onready var prompt_label: Label = $Prompt
@onready var prompt_bar: ProgressBar = $Prompt/Hold
@onready var crosshair: Control = $Crosshair
@onready var shield_meter: Control = $ShieldMeter
@onready var scope: Control = $Scope


func _ready() -> void:
	crosshair.draw.connect(_draw_crosshair)
	shield_meter.draw.connect(_draw_shield_meter)
	scope.draw.connect(_draw_scope)
	_health = get_node_or_null(health_path) as HealthShield
	if _health != null:
		_health.changed.connect(_on_health_changed)
		_health.shield_broken.connect(sfx_event.emit.bind(&"shield_broken"))
		_health.shield_recharge_started.connect(sfx_event.emit.bind(&"shield_recharge"))
		_health.shield_full.connect(sfx_event.emit.bind(&"shield_full"))
		_on_health_changed(_health.shield, _health.health)
	else:
		shield_meter.visible = false
	_holder = get_node_or_null(holder_path) as WeaponHolder
	if _holder == null:
		push_warning("HUD has no WeaponHolder")
		return
	_holder.active_weapon_changed.connect(_on_weapon_changed)
	_on_weapon_changed(_holder.get_active())


func _process(delta: float) -> void:
	_time += delta
	_hit_flash = maxf(_hit_flash - delta, 0.0)
	_update_low_shield(delta)
	var scoped := _is_scoped()
	scope.visible = scoped
	crosshair.visible = not scoped
	if scoped:
		scope.queue_redraw()
	else:
		crosshair.queue_redraw()
	shield_meter.queue_redraw()
	_update_prompt()


func _is_scoped() -> bool:
	return (
		is_instance_valid(_weapon)
		and _weapon.data != null
		and _weapon.data.zoom_overlay
		and _weapon.zoomed
	)


func _update_low_shield(delta: float) -> void:
	var low := _health != null and not _health.dead and _shield_fraction <= low_shield_threshold
	if low != _low_shield:
		_low_shield = low
		low_shield_warning.emit(low)
		_beep_left = 0.0
	if not low:
		return
	_beep_left -= delta
	if _beep_left <= 0.0:
		_beep_left = low_shield_beep_interval
		sfx_event.emit(&"low_shield_beep")


func _update_prompt() -> void:
	var text := _holder.get_pickup_prompt() if _holder != null else ""
	prompt_label.visible = text != ""
	if text == "":
		return
	prompt_label.text = text
	prompt_bar.value = _holder.get_pickup_progress()


func _on_weapon_changed(weapon: Weapon) -> void:
	if is_instance_valid(_weapon):
		if _weapon.ammo_changed.is_connected(_on_ammo_changed):
			_weapon.ammo_changed.disconnect(_on_ammo_changed)
		if _weapon.hit_confirmed.is_connected(_on_hit):
			_weapon.hit_confirmed.disconnect(_on_hit)
		if _weapon.fire_mode_changed.is_connected(_on_fire_mode_changed):
			_weapon.fire_mode_changed.disconnect(_on_fire_mode_changed)
	_weapon = weapon
	if _weapon == null:
		ammo_label.text = ""
		mode_label.text = ""
		return
	_weapon.ammo_changed.connect(_on_ammo_changed)
	_weapon.hit_confirmed.connect(_on_hit)
	_weapon.fire_mode_changed.connect(_on_fire_mode_changed)
	_on_fire_mode_changed(_weapon.fire_mode)
	_on_ammo_changed(_weapon.magazine, _weapon.reserve)


func _on_health_changed(shield: float, health: float) -> void:
	_shield_fraction = shield / maxf(_health.max_shield, 0.001)
	_health_fraction = health / maxf(_health.max_health, 0.001)


func _draw_shield_meter() -> void:
	var w := shield_meter.size.x
	# Shield: framed bar with chamfered-look corner brackets.
	var bar := Rect2(0.0, 0.0, w, SHIELD_BAR_HEIGHT)
	shield_meter.draw_rect(bar, SHIELD_EMPTY)
	var fill := SHIELD_FILL
	if _low_shield and fmod(_time * low_shield_flash_rate, 1.0) < 0.5:
		fill = SHIELD_LOW_FILL
	if _shield_fraction > 0.0:
		shield_meter.draw_rect(
			Rect2(2.0, 2.0, (w - 4.0) * _shield_fraction, SHIELD_BAR_HEIGHT - 4.0), fill
		)
	shield_meter.draw_rect(bar, FRAME_COLOR, false, 2.0)
	for x in [0.0, w]:
		var dir := 1.0 if x == 0.0 else -1.0
		shield_meter.draw_line(Vector2(x, -4.0), Vector2(x + dir * 14.0, -4.0), FRAME_COLOR, 2.0)
		shield_meter.draw_line(Vector2(x, -4.0), Vector2(x, 4.0), FRAME_COLOR, 2.0)
	# Health: segments under the shield bar, centred.
	var hw := w * HEALTH_BAR_WIDTH_FRACTION
	var x0 := (w - hw) * 0.5
	var y0 := SHIELD_BAR_HEIGHT + BAR_GAP
	var count := maxi(health_segments, 1)
	var seg_w := (hw - 3.0 * (count - 1)) / count
	for i in count:
		var seg := Rect2(x0 + i * (seg_w + 3.0), y0, seg_w, HEALTH_BAR_HEIGHT)
		var lit := clampf(_health_fraction * count - i, 0.0, 1.0)
		shield_meter.draw_rect(seg, HEALTH_EMPTY)
		if lit > 0.0:
			shield_meter.draw_rect(
				Rect2(seg.position, Vector2(seg_w * lit, HEALTH_BAR_HEIGHT)), HEALTH_FILL
			)


## Halo CE-style scope: black outside a circle, thin ring, crosshair with a centre gap.
func _draw_scope() -> void:
	var size := scope.size
	var center := size * 0.5
	var radius := minf(size.x, size.y) * SCOPE_RADIUS_FRACTION
	var far := size.length()
	for i in SCOPE_SEGMENTS:
		var a0 := TAU * i / SCOPE_SEGMENTS
		var a1 := TAU * (i + 1) / SCOPE_SEGMENTS
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		scope.draw_colored_polygon(
			PackedVector2Array(
				[center + d0 * radius, center + d1 * radius, center + d1 * far, center + d0 * far]
			),
			SCOPE_COLOR
		)
	scope.draw_arc(center, radius, 0.0, TAU, SCOPE_SEGMENTS, SCOPE_RETICLE, 2.0)
	var gap := radius * 0.06
	for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		scope.draw_line(center + dir * gap, center + dir * radius * 0.9, SCOPE_RETICLE, 1.5)
	scope.draw_rect(Rect2(center - Vector2.ONE, Vector2(2.0, 2.0)), SCOPE_RETICLE)


func _on_fire_mode_changed(_mode: int) -> void:
	if not is_instance_valid(_weapon) or _weapon.data == null:
		mode_label.text = ""
		return
	mode_label.text = _weapon.get_fire_mode_name()


func _on_ammo_changed(magazine: int, reserve: int) -> void:
	ammo_label.text = "%d / %d" % [magazine, reserve]


func _on_hit(_target: Object, info: Dictionary) -> void:
	_hit_flash = HIT_FLASH_TIME
	_hit_color = Weapon.zone_color(info.get("hit_zone", Weapon.HitZone.BODY))


func _draw_crosshair() -> void:
	var center := crosshair.size * 0.5
	var gap := MIN_GAP
	if is_instance_valid(_weapon) and _weapon.camera != null:
		# Spread cone edge projected to screen pixels at the current FOV.
		var half_fov := deg_to_rad(_weapon.camera.fov * 0.5)
		var spread := deg_to_rad(_weapon.get_spread())
		gap = maxf(MIN_GAP, tan(spread) / tan(half_fov) * crosshair.size.y * 0.5)
	var color := _hit_color if _hit_flash > 0.0 else Color(0.92, 0.93, 0.9, 0.9)
	crosshair.draw_rect(Rect2(center - Vector2.ONE, Vector2(2, 2)), color)
	for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		var a: Vector2 = center + dir * gap
		var b: Vector2 = center + dir * (gap + TICK_LENGTH)
		crosshair.draw_line(a, b, color, TICK_WIDTH)
