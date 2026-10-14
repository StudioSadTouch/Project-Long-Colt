class_name TargetDummy
extends StaticBody3D
## Greybox shooting target. The body collider is this node. HeadArmored (helmet, group
## hitbox_head_armored) and HeadUnarmored (visor + neck, group hitbox_head_unarmored) are
## script-less child StaticBody3Ds, so Weapon walks up from them to take_damage here.
## Front faces local -Z.

## amount is shield plus health actually removed, not the incoming base damage.
signal damaged(amount: float, info: Dictionary)
signal died
signal respawned

const DAMAGE_NUMBER_RISE := 0.8
const DAMAGE_NUMBER_TIME := 0.7
const SHIELD_COLOR := Color(0.35, 0.8, 1.0)

@export var respawn_delay: float = 3.0

var dead: bool = false

var _layers: Dictionary = {}

@onready var hp_label: Label3D = $HPLabel
@onready var health_shield: HealthShield = $HealthShield


func _ready() -> void:
	add_to_group("enemy")
	for path: String in [".", "HeadArmored", "HeadUnarmored"]:
		var body := get_node_or_null(path) as CollisionObject3D
		if body != null:
			_layers[body] = body.collision_layer
	health_shield.changed.connect(_on_health_changed)
	health_shield.died.connect(_die)
	_on_health_changed(health_shield.shield, health_shield.health)


## Weapon contract. Shield/zone rules live in HealthShield.
func take_damage(amount: float, info: Dictionary) -> void:
	if dead:
		return
	var result := health_shield.apply_damage(amount, info)
	if result.shield > 0.0:
		_spawn_number(result.shield, info, SHIELD_COLOR, 36)
	if result.health > 0.0:
		var zone: int = info.get("hit_zone", Weapon.HitZone.BODY)
		var size := 56 if zone == Weapon.HitZone.HEAD_UNARMORED else (46 if zone != 0 else 36)
		_spawn_number(result.health, info, Weapon.zone_color(zone), size)
	# Report what was actually removed; fully absorbed or zero hits emit nothing.
	var applied: float = result.shield + result.health
	if applied > 0.0:
		damaged.emit(applied, info)


func _die() -> void:
	dead = true
	visible = false
	for body: CollisionObject3D in _layers:
		body.collision_layer = 0
	died.emit()
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	dead = false
	health_shield.reset()
	for body: CollisionObject3D in _layers:
		body.collision_layer = _layers[body]
	visible = true
	respawned.emit()


func _on_health_changed(shield: float, health: float) -> void:
	hp_label.text = (
		"S %d / %d\nH %d / %d"
		% [
			ceili(shield),
			ceili(health_shield.max_shield),
			ceili(health),
			ceili(health_shield.max_health)
		]
	)


func _spawn_number(amount: float, info: Dictionary, color: Color, size: int) -> void:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0015
	label.font_size = size
	label.outline_size = 8
	label.modulate = color
	label.text = "%d" % roundi(amount)
	# Parent to the level so the number survives the dummy hiding on death.
	var parent := get_parent() if get_parent() != null else self
	parent.add_child(label)
	var start: Vector3 = info.get("position", global_position + Vector3.UP * 1.5)
	label.global_position = start + Vector3(randf_range(-0.15, 0.15), 0.1, 0.0)
	var tween := label.create_tween().set_parallel()
	tween.tween_property(
		label, "global_position:y", label.global_position.y + DAMAGE_NUMBER_RISE, DAMAGE_NUMBER_TIME
	)
	tween.tween_property(label, "modulate:a", 0.0, DAMAGE_NUMBER_TIME).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)
