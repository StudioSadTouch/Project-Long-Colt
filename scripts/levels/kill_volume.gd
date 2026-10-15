class_name KillVolume
extends Area3D
## Kills whatever falls in. The victim is the owner of the entering collider: walking up from
## it, the first node with kill(info) or take_damage(amount, info) (Player, Bot via its Hurtbox,
## dummies). Each victim is hit once: skipped while is_dead(), and a second body of the same
## owner entering on the same physics tick (capsule + Hurtbox) is ignored. info carries
## kill_volume = true (no weapon drop, counted as a fall) and bleedthrough.
## Masks Player (2) and Enemy (4) in lockout.tscn.

const OWNER_SEARCH_DEPTH := 4

@export var damage: float = 10000.0

## Victim instance id -> physics frame it was last hit.
var _hit_frame: Dictionary = {}


func _ready() -> void:
	body_entered.connect(_on_body_entered)


## The node that should die for body, or null.
static func victim_of(body: Node) -> Node:
	var node := body
	for _i in OWNER_SEARCH_DEPTH:
		if node == null:
			return null
		if node.has_method(&"kill") or node.has_method(&"take_damage"):
			return node
		node = node.get_parent()
	return null


func _on_body_entered(body: Node3D) -> void:
	var victim := victim_of(body)
	if victim == null:
		return
	if victim.has_method(&"is_dead") and victim.call(&"is_dead"):
		return
	var id := victim.get_instance_id()
	var frame := Engine.get_physics_frames()
	if int(_hit_frame.get(id, -1)) == frame:
		return
	_hit_frame[id] = frame
	var info := {"bleedthrough": true, "kill_volume": true}
	if victim.has_method(&"kill"):
		victim.call(&"kill", info)
	else:
		victim.call(&"take_damage", damage, info)
