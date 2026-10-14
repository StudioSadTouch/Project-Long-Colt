class_name BotGravLift
extends Area3D
## Bot-side twin of the level GravLift, which only pushes Player bodies (mask 2, `is Player`).
## Same volume, Enemy mask (4) so it sees bot hurtboxes; pushes the owning Bot up at the level
## lift's lift_speed. Placed by emit_arena_tscn.py.
##
## TODO(lift_rider): delete this file (and the BotGravLift node emit_arena_tscn.py writes) once
## the level GravLift pushes the "lift_rider" group. Bots already join that group. GravLift needs:
##   1. collision_mask 2 | 4 (bot capsules are on no layer; their Hurtbox is on Enemy, 4),
##   2. treat the entering body, or its parent, as the rider when it is in group "lift_rider"
##      (a bot's Hurtbox is a direct child of the Bot), and push rider.velocity.y as for Player,
##   3. declare `var rider_group: StringName = &"lift_rider"` so this node switches itself off
##      until it is deleted.
## Both lifts writing at once is harmless anyway: each applies maxf(velocity.y, lift_speed).

@export var level_lift: NodePath
@export var lift_speed: float = 12.0

var _bots: Array[Bot] = []


func _ready() -> void:
	var lift := get_node_or_null(level_lift) as GravLift
	if lift != null:
		lift_speed = lift.lift_speed
		if str(lift.get(&"rider_group")) == "lift_rider":
			# The level lift handles bots itself.
			monitoring = false
			set_physics_process(false)
			return
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(_delta: float) -> void:
	for bot in _bots:
		if is_instance_valid(bot) and not bot.dead:
			bot.velocity.y = maxf(bot.velocity.y, lift_speed)


func _bot_of(body: Node3D) -> Bot:
	if body is Bot:
		return body
	return body.get_parent() as Bot


func _on_body_entered(body: Node3D) -> void:
	var bot := _bot_of(body)
	if bot != null and not _bots.has(bot):
		_bots.append(bot)


func _on_body_exited(body: Node3D) -> void:
	var bot := _bot_of(body)
	if bot != null:
		_bots.erase(bot)
