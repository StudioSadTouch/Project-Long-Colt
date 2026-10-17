class_name CombatFeedback
extends Control
## Local-player combat presentation. Child of the HUD, so net puppets drop it with the HUD.
## Hit marker: a short X and a tick when your shot confirms.
## Damage indicator: an edge chevron toward the attacker (body yaw, not the pitched camera).
## Blood: a screen splatter when health is lost, plus a small puff where your shot drew health.
## Shield hits stay blue and silent of blood. Hurt and death stingers are 2D on the UI bus.
## A confirmed shot also plays that shield or health impact in 3D at the hit (Foley bus).
## Other guns play in 3D from ArenaEvents.gunfire / NetMatch.remote_shot. The local player's
## own shot is skipped there: WeaponFx already played it on the viewmodel. The sound is the
## weapon scene's own (WeaponAudio), so new guns need no entry here; GUNS is the fallback.

const HIT_TIME := 0.16
const MARK_TIME := 1.15
const MARK_LIMIT := 3
const BLOT_LIMIT := 24
const HEALTH_MARK := Color(1.0, 0.16, 0.08)
const SHIELD_MARK := Color(0.5, 0.9, 1.0)
const HIT_MARKER := preload("res://assets/audio/feedback/hit_marker.wav")
const SHIELD_HIT := preload("res://assets/audio/feedback/shield_hit.wav")
const HEALTH_HIT := preload("res://assets/audio/feedback/health_hit.wav")
const DEATH := preload("res://assets/audio/feedback/death.wav")
const GUNS := {
	"Standard Issue Rifle": preload("res://assets/audio/weapons/standard_issue_rifle_fire.wav"),
	"Marksman Carbine": preload("res://assets/audio/weapons/marksman_carbine_fire.wav"),
	"Combat Shotgun": preload("res://assets/audio/weapons/combat_shotgun_fire.wav"),
	"Service Pistol": preload("res://assets/audio/weapons/service_pistol_fire.wav"),
	"Directed Energy Rifle": preload("res://assets/audio/weapons/der_fire.wav"),
}

var _player: Player
var _weapon: Weapon
var _match: Node
var _marker: AudioStreamPlayer
var _hurt: AudioStreamPlayer
var _death: AudioStreamPlayer
var _hit_left: float = 0.0
var _hit_color: Color = Color(1.0, 0.3, 0.25)
var _vignette: float = 0.0
var _bled: bool = false
var _shield_pending: float = 0.0
var _health_pending: float = 0.0
var _hurt_queued: bool = false
var _marks: Array[Dictionary] = []
var _blots: Array[Dictionary] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hud := get_parent()
	if hud != null:
		_player = hud.get_parent() as Player
	if _player == null or _player.net_puppet:
		set_process(false)
		return
	_marker = _voice(&"UI")
	_hurt = _voice(&"UI")
	_death = _voice(&"UI")
	_player.damaged.connect(_on_damaged)
	_player.died.connect(_on_died)
	if _player.health_shield != null:
		_player.health_shield.shield_damaged.connect(_on_shield_damaged)
		_player.health_shield.health_damaged.connect(_on_health_damaged)
	var holder := _player.get_weapon_holder()
	if holder != null:
		holder.active_weapon_changed.connect(_on_weapon_changed)
		_on_weapon_changed(holder.get_active())
	var events := get_tree().get_first_node_in_group(&"arena_events")
	if events != null and events.has_signal(&"gunfire"):
		events.gunfire.connect(_on_gunfire)
	var scene := get_tree().current_scene
	_match = scene.get_node_or_null(^"NetMatch") if scene != null else null
	if _match != null and _match.has_signal(&"remote_shot"):
		_match.remote_shot.connect(_on_remote_shot)


func _process(delta: float) -> void:
	var drawing := (
		_hit_left > 0.0 or _vignette > 0.01 or not _marks.is_empty() or not _blots.is_empty()
	)
	_hit_left = maxf(_hit_left - delta, 0.0)
	_vignette = maxf(_vignette - delta * 0.85, 0.0)
	_decay(_marks, delta)
	_decay(_blots, delta)
	_bled = false
	if drawing:
		queue_redraw()


## travel is shooter -> victim (Weapon sets "dir"; Player.damage_direction fills the rest).
## The attacker stands on -travel. Angle 0 is in front of the BODY (top of the screen) and
## +PI/2 is the body's right. Pitch lives on Head, so this uses the body basis, not the camera.
## Identity basis, forward (0, 0, -1), right = forward × up = +X:
##   travel +Z (attacker in front) -> 0
##   travel -X (attacker on +X) -> +PI/2
##   travel -Z (attacker behind) -> PI
##   travel +X (attacker on the left) -> -PI/2
## A straight-down shot (no horizontal travel, travel.y < 0) is drawn at the top.
static func attacker_screen_angle(basis: Basis, travel: Vector3) -> float:
	var from := -travel
	from.y = 0.0
	if from.length_squared() < 0.0001:
		return 0.0 if travel.y < 0.0 else PI
	from = from.normalized()
	var fwd := -basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3(0.0, 0.0, -1.0)
	else:
		fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP)
	return atan2(from.dot(right), from.dot(fwd))


func _draw() -> void:
	if size.x < 2.0 or size.y < 2.0:
		return
	var center := size * 0.5
	_draw_blood()
	_draw_marks(center)
	_draw_hit(center)


func _draw_blood() -> void:
	if _vignette > 0.01:
		var bands := 5
		for i in bands:
			var t := float(i) / float(bands)
			var inset := t * 80.0
			var color := Color(0.55, 0.02, 0.03, _vignette * (1.0 - t) * 0.5)
			draw_rect(
				Rect2(inset, inset, size.x - inset * 2.0, size.y - inset * 2.0), color, false, 22.0
			)
	for blot in _blots:
		var life := float(blot["life"])
		var fade := clampf(1.0 - float(blot["age"]) / life, 0.0, 1.0)
		var spot: Vector2 = blot["at"]
		var radius := float(blot["radius"])
		var alpha := float(blot["alpha"]) * fade
		draw_circle(spot, radius, Color(0.5, 0.02, 0.03, alpha))
		draw_circle(spot + blot["nudge"], radius * 0.5, Color(0.32, 0.0, 0.02, alpha * 0.75))


## Edge arc plus an inward chevron. Angle 0 is the top of the screen. Drawn with plain
## strokes: antialiased thick lines were easy to miss on the Forward+ HUD.
func _draw_marks(center: Vector2) -> void:
	var u := size.y / 1080.0
	var radius := minf(size.x, size.y) * 0.5 - 36.0 * u
	if radius < 48.0:
		return
	var span := deg_to_rad(52.0)
	var width := maxf(8.0, 16.0 * u)
	for mark in _marks:
		var life := float(mark["life"])
		var fade := clampf((1.0 - float(mark["age"]) / life) * 1.35, 0.0, 1.0)
		var angle := float(mark["angle"])
		var color: Color = mark["color"]
		color.a = 0.95 * fade
		var mid := angle - PI * 0.5
		var shadow := Color(0.02, 0.01, 0.01, color.a * 0.8)
		draw_arc(center, radius, mid - span * 0.5, mid + span * 0.5, 18, shadow, width + 8.0 * u, false)
		draw_arc(center, radius, mid - span * 0.5, mid + span * 0.5, 18, color, width, false)
		var dir := Vector2(sin(angle), -cos(angle))
		var tangent := Vector2(-dir.y, dir.x)
		var tip := center + dir * (radius - 34.0 * u)
		var wing := 26.0 * u
		var outer := center + dir * (radius - 4.0 * u)
		draw_colored_polygon(
			PackedVector2Array([tip, outer + tangent * wing, outer - tangent * wing]), color
		)


func _draw_hit(center: Vector2) -> void:
	if _hit_left <= 0.0:
		return
	var color := _hit_color
	color.a = 0.95 * clampf(_hit_left / HIT_TIME, 0.0, 1.0)
	var u := size.y / 1080.0
	var gap := 16.0 * u
	var reach := 34.0 * u
	var width := maxf(3.0, 4.0 * u)
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			var dir := Vector2(x, y).normalized()
			draw_line(center + dir * gap, center + dir * reach, color, width, false)


func _on_weapon_changed(weapon: Weapon) -> void:
	if is_instance_valid(_weapon) and _weapon.hit_confirmed.is_connected(_on_hit):
		_weapon.hit_confirmed.disconnect(_on_hit)
	_weapon = weapon
	if _weapon != null:
		_weapon.hit_confirmed.connect(_on_hit)


func _on_hit(_target: Object, info: Dictionary) -> void:
	_hit_left = HIT_TIME
	_hit_color = Weapon.zone_color(int(info.get("hit_zone", Weapon.HitZone.BODY)))
	var pitch := 1.18 if bool(info.get("headshot", false)) else 1.0
	if bool(info.get("assassination", false)):
		_hit_color = Color(1.0, 0.85, 0.2)
		pitch = 1.35
	_play(_marker, HIT_MARKER, -10.0, pitch)
	var health_dealt := float(info.get("health_dealt", 0.0))
	var shield_dealt := float(info.get("shield_dealt", 0.0))
	var at: Variant = info.get("position")
	if at is Vector3 and (health_dealt > 0.0 or shield_dealt > 0.0):
		var impact := HEALTH_HIT if health_dealt > 0.0 else SHIELD_HIT
		_play_world(impact, at as Vector3, -4.0, &"Foley")
	if health_dealt > 0.0:
		_spawn_blood(info)


func _on_damaged(_amount: float, info: Dictionary) -> void:
	var travel: Variant = info.get("dir", Vector3.ZERO)
	if not travel is Vector3 or (travel as Vector3).length_squared() < 0.0001:
		return
	var health_dealt := float(info.get("health_dealt", -1.0))
	var shield_dealt := float(info.get("shield_dealt", -1.0))
	var health_hit := true
	if health_dealt >= 0.0 or shield_dealt >= 0.0:
		health_hit = health_dealt > 0.0
	elif _health_pending > 0.0:
		health_hit = true
	elif _shield_pending > 0.0:
		health_hit = false
	var color := HEALTH_MARK if health_hit else SHIELD_MARK
	var angle := attacker_screen_angle(_player.global_basis, travel as Vector3)
	for mark in _marks:
		if absf(angle_difference(float(mark["angle"]), angle)) > 0.45:
			continue
		mark["angle"] = angle
		mark["age"] = 0.0
		mark["life"] = MARK_TIME
		if health_hit:
			mark["color"] = HEALTH_MARK
		queue_redraw()
		return
	_marks.append({"angle": angle, "age": 0.0, "life": MARK_TIME, "color": color})
	while _marks.size() > MARK_LIMIT:
		_marks.remove_at(0)
	queue_redraw()


func _on_shield_damaged(amount: float) -> void:
	_shield_pending += amount
	_queue_hurt()


func _on_health_damaged(amount: float) -> void:
	_health_pending += amount
	_bled = true
	_add_blood(amount)
	_queue_hurt()


func _on_died(_who: Player, _killer: Node, info: Dictionary) -> void:
	_play(_death, DEATH, -1.0, randf_range(0.96, 1.02))
	if not bool(info.get("kill_volume", false)) and not _bled:
		_add_blood(28.0)
	_marks.clear()


func _queue_hurt() -> void:
	if _hurt_queued:
		return
	_hurt_queued = true
	_flush_hurt.call_deferred()


## One stinger per hit. Health wins over shield when a shot does both. A killing blow
## skips the thud; died already played the death stinger (health is 0 before this runs).
func _flush_hurt() -> void:
	_hurt_queued = false
	var health := _health_pending
	var shield := _shield_pending
	_health_pending = 0.0
	_shield_pending = 0.0
	if health > 0.0:
		_tint_latest(true)
		if _player.health_shield != null and _player.health_shield.health <= 0.0:
			return
		_play(_hurt, HEALTH_HIT, -3.0, randf_range(0.96, 1.05))
	elif shield > 0.0:
		_tint_latest(false)
		_play(_hurt, SHIELD_HIT, -5.0, randf_range(0.94, 1.06))


func _on_gunfire(source: Node3D, position: Vector3) -> void:
	if source == _player or not is_instance_valid(source):
		return
	_play_world(_gun_stream(source), position + Vector3.UP * 1.4)


func _on_remote_shot(id: int, from: Vector3, _tos: PackedVector3Array, _hits: PackedByteArray) -> void:
	if _match == null:
		return
	var entities: Variant = _match.get(&"entities")
	if not entities is Dictionary:
		return
	var body: Variant = (entities as Dictionary).get(id)
	if not is_instance_valid(body) and _match.has_method(&"body_of"):
		body = _match.call(&"body_of", id)  # e.g. a Horde enemy's LAN copy
	if not is_instance_valid(body) or body == _player or not body is Node:
		return
	_play_world(_gun_stream(body as Node), from)


## A net snapshot can arrive in a different message than the damage direction. If the
## newest chevron is still fresh, match it to shield (blue) or health (red).
func _tint_latest(health_hit: bool) -> void:
	if _marks.is_empty():
		return
	var latest: Dictionary = _marks[_marks.size() - 1]
	if float(latest["age"]) > 0.2:
		return
	latest["color"] = HEALTH_MARK if health_hit else SHIELD_MARK


func _add_blood(amount: float) -> void:
	var strength := clampf(amount / 22.0, 0.35, 1.0)
	_vignette = minf(_vignette + 0.55 * strength, 1.0)
	var bounds := size
	if bounds.x < 2.0 or bounds.y < 2.0:
		bounds = get_viewport_rect().size
	var count := 4 + int(strength * 5.0)
	for _n in count:
		var edge := randi() % 4
		var along := randf()
		var depth := randf_range(0.02, 0.2)
		var unit := Vector2(along, depth)
		if edge == 1:
			unit = Vector2(along, 1.0 - depth)
		elif edge == 2:
			unit = Vector2(depth, along)
		elif edge == 3:
			unit = Vector2(1.0 - depth, along)
		_blots.append({
			"at": Vector2(unit.x * bounds.x, unit.y * bounds.y),
			"nudge": Vector2(randf_range(-10.0, 10.0), randf_range(-8.0, 8.0)),
			"radius": randf_range(16.0, 48.0) * strength,
			"alpha": randf_range(0.28, 0.62) * strength,
			"age": 0.0,
			"life": randf_range(0.65, 1.25),
		})
	while _blots.size() > BLOT_LIMIT:
		_blots.remove_at(0)


func _spawn_blood(info: Dictionary) -> void:
	var at: Variant = info.get("position")
	if not at is Vector3:
		return
	var point: Vector3 = at
	var normal: Variant = info.get("normal")
	if normal is Vector3:
		point += (normal as Vector3) * 0.05
	var host := get_tree().current_scene
	if host == null:
		return
	var puff := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.62, 0.02, 0.03, 0.85)
	sphere.material = material
	puff.mesh = sphere
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	puff.top_level = true
	host.add_child(puff)
	puff.global_position = point
	var tween := puff.create_tween()
	tween.tween_property(puff, "scale", Vector3(2.4, 2.4, 2.4), 0.14)
	tween.finished.connect(puff.queue_free)


func _gun_stream(body: Node) -> AudioStream:
	var weapon: Variant = null
	if body.has_method(&"get_active_weapon"):
		weapon = body.call(&"get_active_weapon")
	elif body.has_method(&"get_active"):
		weapon = body.call(&"get_active")
	if not is_instance_valid(weapon):
		return null
	var own := WeaponAudio.fire_sound_of(weapon as Node)
	if own != null:
		return own
	var data: Variant = weapon.get(&"data")
	if data == null:
		return null
	var stream: Variant = GUNS.get(str(data.get(&"display_name")), null)
	return stream as AudioStream


func _voice(bus: StringName) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.max_polyphony = 3
	if AudioServer.get_bus_index(bus) >= 0:
		player.bus = bus
	add_child(player)
	return player


func _play(player: AudioStreamPlayer, stream: AudioStream, db: float, pitch: float) -> void:
	if player == null or stream == null:
		return
	player.stream = stream
	player.volume_db = db
	player.pitch_scale = pitch
	player.play()


func _play_world(
	stream: AudioStream, at: Vector3, db: float = -8.0, bus: StringName = &"Weapons"
) -> void:
	if stream == null:
		return
	var host := get_tree().current_scene
	if host == null:
		return
	var voice := AudioStreamPlayer3D.new()
	voice.stream = stream
	voice.volume_db = db
	voice.unit_size = 7.0 if bus == &"Weapons" else 4.0
	voice.max_distance = 55.0 if bus == &"Weapons" else 28.0
	voice.pitch_scale = randf_range(0.97, 1.03)
	if AudioServer.get_bus_index(bus) >= 0:
		voice.bus = bus
	voice.finished.connect(voice.queue_free)
	host.add_child(voice)
	voice.global_position = at
	voice.play()


func _decay(items: Array[Dictionary], delta: float) -> void:
	for i in range(items.size() - 1, -1, -1):
		var item: Dictionary = items[i]
		item["age"] = float(item["age"]) + delta
		if float(item["age"]) >= float(item["life"]):
			items.remove_at(i)
