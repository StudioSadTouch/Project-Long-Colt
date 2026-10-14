class_name DummyCore
extends Node
## Shared target-dummy logic: HealthShield damage, floating numbers, the S/H readout, death
## (hide + disable hitboxes) and timed respawn. Used by TargetDummy (StaticBody3D) and
## MovingDummy (CharacterBody3D), which differ only in their root body type and movement.
## The root keeps take_damage (the Weapon contract) and delegates here.
##
## Expected layout under the root: BodyShape (Enemy layer, on the root), Rig (dummy_rig.tscn:
## meshes, HeadArmored / HeadUnarmored on the Hitbox layer, HPLabel), HealthShield, DummyCore.

## amount is shield plus health actually removed, not the incoming base damage.
signal damaged(amount: float, info: Dictionary)
signal died
signal respawned

const DAMAGE_NUMBER_RISE := 0.8
const DAMAGE_NUMBER_TIME := 0.7
const SHIELD_COLOR := Color(0.35, 0.8, 1.0)

@export var respawn_delay: float = 3.0
## Collision objects disabled while dead, relative to the root.
@export var hitbox_paths: Array[NodePath] = [^".", ^"Rig/HeadArmored", ^"Rig/HeadUnarmored"]

var dead: bool = false

var _layers: Dictionary = {}
var _root: Node3D
var _health: HealthShield
var _label: Label3D


func _ready() -> void:
	_root = get_parent() as Node3D
	_health = _root.get_node_or_null("HealthShield") as HealthShield
	_label = _root.get_node_or_null("Rig/HPLabel") as Label3D
	_root.add_to_group("enemy")
	_root.add_to_group("aim_target")
	for path in hitbox_paths:
		var body := _root.get_node_or_null(path) as CollisionObject3D
		if body != null:
			_layers[body] = body.collision_layer
	if _health == null:
		push_error("%s has no HealthShield" % _root.name)
		return
	_health.changed.connect(_on_health_changed)
	_health.died.connect(_die)
	_on_health_changed(_health.shield, _health.health)


## AimAssist aim points: body centre and helmet centre; empty while dead.
func get_aim_points() -> Dictionary:
	if dead:
		return {}
	var points := {"body": _root.global_position + Vector3.UP * 0.7}
	var head := _root.get_node_or_null("Rig/HeadArmored") as Node3D
	if head != null:
		points["head"] = head.global_position
	return points


func take_damage(amount: float, info: Dictionary) -> void:
	if dead or _health == null:
		return
	var result := _health.apply_damage(amount, info)
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
	_root.visible = false
	for body: CollisionObject3D in _layers:
		body.collision_layer = 0
	died.emit()
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	dead = false
	_health.reset()
	for body: CollisionObject3D in _layers:
		body.collision_layer = _layers[body]
	_root.visible = true
	respawned.emit()


func _on_health_changed(shield: float, health: float) -> void:
	if _label == null:
		return
	_label.text = (
		"S %d / %d\nH %d / %d"
		% [ceili(shield), ceili(_health.max_shield), ceili(health), ceili(_health.max_health)]
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
	var parent := _root.get_parent() if _root.get_parent() != null else _root
	parent.add_child(label)
	var start: Vector3 = info.get("position", _root.global_position + Vector3.UP * 1.5)
	label.global_position = start + Vector3(randf_range(-0.15, 0.15), 0.1, 0.0)
	var tween := label.create_tween().set_parallel()
	tween.tween_property(
		label, "global_position:y", label.global_position.y + DAMAGE_NUMBER_RISE, DAMAGE_NUMBER_TIME
	)
	tween.tween_property(label, "modulate:a", 0.0, DAMAGE_NUMBER_TIME).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)
