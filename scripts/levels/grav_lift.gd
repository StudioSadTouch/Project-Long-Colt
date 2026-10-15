class_name GravLift
extends Area3D
## Halo-style gravity lift: every rider inside is pushed upward at lift_speed. Leaving the top
## of the volume hands the rider back to normal gravity. Area on the Interactable layer (5), not
## monitorable; weapon rays don't include layer 5.
## Riders: the CharacterBody3D that owns the entering collider, found by walking up from it to a
## node in group rider_group ("lift_rider"). Player and Bot join that group; a bot's capsule is on
## no layer, so its Hurtbox (Enemy, 4) is what enters, and its parent Bot is the rider.
## collision_mask gets rider_mask (Player 2 | Enemy 4) OR'ed in at _ready. Dead riders
## (is_dead()) aren't pushed. Overlaps are counted per rider (a Player has capsule + Hurtbox).

const RIDER_SEARCH_DEPTH := 4

@export var lift_speed: float = 12.0
## Layers rider bodies may be on; OR'ed into collision_mask in _ready.
@export_flags_3d_physics var rider_mask: int = 2 | 4

## Group a CharacterBody3D joins to ride. BotGravLift reads this and switches itself off.
var rider_group: StringName = &"lift_rider"

## Rider -> number of its bodies inside.
var _riders: Dictionary = {}
## Body inside -> its rider.
var _bodies: Dictionary = {}


func _ready() -> void:
	collision_mask |= rider_mask
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


## The rider owning body (body itself or an ancestor in rider_group), or null.
func rider_of(body: Node) -> CharacterBody3D:
	var node := body
	for _i in RIDER_SEARCH_DEPTH:
		if node == null:
			return null
		if node is CharacterBody3D and node.is_in_group(rider_group):
			return node as CharacterBody3D
		node = node.get_parent()
	return null


func _physics_process(_delta: float) -> void:
	for key: Variant in _riders.keys():
		if not is_instance_valid(key):
			_riders.erase(key)
			continue
		var rider := key as CharacterBody3D
		if rider.has_method(&"is_dead") and rider.call(&"is_dead"):
			continue
		rider.velocity.y = maxf(rider.velocity.y, lift_speed)


func _on_body_entered(body: Node3D) -> void:
	var rider := rider_of(body)
	if rider == null or _bodies.has(body):
		return
	_bodies[body] = rider
	_riders[rider] = int(_riders.get(rider, 0)) + 1


func _on_body_exited(body: Node3D) -> void:
	if not _bodies.has(body):
		return
	var rider: Variant = _bodies[body]
	_bodies.erase(body)
	var count := int(_riders.get(rider, 1)) - 1
	if count > 0:
		_riders[rider] = count
	else:
		_riders.erase(rider)
