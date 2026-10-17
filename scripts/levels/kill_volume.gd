class_name KillVolume
extends Area3D
## Kills whatever falls in. The victim is the owner of the entering collider: walking up from
## it, the first node with kill(info) or take_damage(amount, info) (Player, Bot via its Hurtbox,
## dummies). Each victim is hit once: skipped while is_dead(), and a second body of the same
## owner entering on the same physics tick (capsule + Hurtbox) is ignored. A respawn reports
## the pre-death shape for one step after the body has moved; that enter is ignored unless the
## body's origin is still in (or below) the slab. info carries kill_volume = true (no weapon
## drop, counted as a fall) and bleedthrough.
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
	# Re-enabling collision on respawn reports the pre-death shape for one physics step,
	# after the node has already moved to the spawn. Trust the node's origin.
	if victim is Node3D and not _covers(victim as Node3D):
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


## True when the victim's origin is inside a kill box, or already below one (fell through).
## An unknown shape trusts the physics signal.
func _covers(victim: Node3D) -> bool:
	var point := victim.global_position
	var saw_box := false
	for child in get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null or shape_node.disabled:
			continue
		if not shape_node.shape is BoxShape3D:
			return true
		saw_box = true
		var half := (shape_node.shape as BoxShape3D).size * 0.5
		var local := shape_node.global_transform.affine_inverse() * point
		if absf(local.x) > half.x or absf(local.z) > half.z:
			continue
		# Above the slab is a spawn. Inside, on the top face, or already below still dies.
		if local.y <= half.y + 0.05:
			return true
	return not saw_box
