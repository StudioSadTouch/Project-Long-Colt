class_name KillVolume
extends Area3D
## Anything with take_damage that falls in dies (Player respawns via its HealthShield).

@export var damage: float = 10000.0


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if body.has_method("take_damage"):
		body.take_damage(damage, {"bleedthrough": true, "kill_volume": true})
