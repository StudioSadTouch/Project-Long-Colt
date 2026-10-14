extends CanvasLayer
## Minimal combat HUD: ammo count and a crosshair whose gap tracks weapon spread.

const TICK_LENGTH := 6.0
const TICK_WIDTH := 2.0
const MIN_GAP := 3.0
const HIT_FLASH_TIME := 0.12

@export var holder_path: NodePath

var _holder: WeaponHolder
var _weapon: Weapon
var _hit_flash: float = 0.0
var _hit_color: Color = Weapon.zone_color(Weapon.HitZone.BODY)

@onready var ammo_label: Label = $Ammo
@onready var crosshair: Control = $Crosshair


func _ready() -> void:
	crosshair.draw.connect(_draw_crosshair)
	_holder = get_node_or_null(holder_path) as WeaponHolder
	if _holder == null:
		push_warning("HUD has no WeaponHolder")
		return
	_holder.active_weapon_changed.connect(_on_weapon_changed)
	_on_weapon_changed(_holder.get_active())


func _process(delta: float) -> void:
	_hit_flash = maxf(_hit_flash - delta, 0.0)
	crosshair.queue_redraw()


func _on_weapon_changed(weapon: Weapon) -> void:
	if is_instance_valid(_weapon):
		if _weapon.ammo_changed.is_connected(_on_ammo_changed):
			_weapon.ammo_changed.disconnect(_on_ammo_changed)
		if _weapon.hit_confirmed.is_connected(_on_hit):
			_weapon.hit_confirmed.disconnect(_on_hit)
	_weapon = weapon
	if _weapon == null:
		ammo_label.text = ""
		return
	_weapon.ammo_changed.connect(_on_ammo_changed)
	_weapon.hit_confirmed.connect(_on_hit)
	_on_ammo_changed(_weapon.magazine, _weapon.reserve)


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
