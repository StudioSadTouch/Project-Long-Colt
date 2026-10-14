class_name TargetDummy
extends StaticBody3D
## Greybox shooting target. The body collider is this node; the head is a child StaticBody3D in
## group "hitbox_head" with no script, so Weapon walks up from it to take_damage here.

signal damaged(amount: float, info: Dictionary)
signal died
signal respawned

const DAMAGE_NUMBER_RISE := 0.8
const DAMAGE_NUMBER_TIME := 0.7

@export var max_health: float = 100.0
@export var respawn_delay: float = 3.0

var health: float = 0.0
var dead: bool = false

var _layers: Dictionary = {}

@onready var hp_label: Label3D = $HPLabel


func _ready() -> void:
	add_to_group("enemy")
	for body: CollisionObject3D in [self, $Head as CollisionObject3D]:
		_layers[body] = body.collision_layer
	health = max_health
	_update_label()


func take_damage(amount: float, info: Dictionary) -> void:
	if dead or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	_spawn_number(amount, info)
	_update_label()
	damaged.emit(amount, info)
	if health <= 0.0:
		_die()


func _die() -> void:
	dead = true
	visible = false
	for body: CollisionObject3D in _layers:
		body.collision_layer = 0
	died.emit()
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	dead = false
	health = max_health
	for body: CollisionObject3D in _layers:
		body.collision_layer = _layers[body]
	visible = true
	_update_label()
	respawned.emit()


func _update_label() -> void:
	hp_label.text = "%d / %d" % [ceili(health), ceili(max_health)]


func _spawn_number(amount: float, info: Dictionary) -> void:
	var headshot: bool = info.get("headshot", false)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0015
	label.font_size = 48 if headshot else 36
	label.outline_size = 8
	label.modulate = Color(1.0, 0.85, 0.2) if headshot else Color(1.0, 1.0, 1.0)
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
