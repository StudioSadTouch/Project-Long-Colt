class_name BotGravLift
extends Area3D
## Bot-side twin of the level GravLift, which only pushes Player bodies (mask 2, `is Player`).
## Same volume, Enemy mask (4) so it sees bot hurtboxes; pushes the owning Bot up at the level
## lift's lift_speed. Placed by emit_arena_tscn.py. Proposed follow-up: let GravLift accept any
## CharacterBody3D in a "lift_rider" group and delete this.

@export var level_lift: NodePath
@export var lift_speed: float = 12.0

var _bots: Array[Bot] = []


func _ready() -> void:
	var lift := get_node_or_null(level_lift) as GravLift
	if lift != null:
		lift_speed = lift.lift_speed
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
