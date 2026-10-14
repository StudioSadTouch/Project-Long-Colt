class_name GravLift
extends Area3D
## Halo-style gravity lift: any Player inside is pushed upward at lift_speed. Leaving the top
## of the volume hands the player back to normal gravity. Area on the Interactable layer (5),
## masks Player (2) only, not monitorable; weapon rays don't include layer 5.

@export var lift_speed: float = 12.0

var _bodies: Array[Player] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(_delta: float) -> void:
	for body in _bodies:
		if is_instance_valid(body):
			body.velocity.y = maxf(body.velocity.y, lift_speed)


func _on_body_entered(body: Node3D) -> void:
	if body is Player and not _bodies.has(body):
		_bodies.append(body)


func _on_body_exited(body: Node3D) -> void:
	_bodies.erase(body)
