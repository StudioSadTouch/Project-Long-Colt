class_name TargetDummy
extends StaticBody3D
## Static greybox shooting target. Damage, readout and respawn live in DummyCore; this root
## only provides the Weapon contract (take_damage). Front faces local -Z.

## amount is shield plus health actually removed, not the incoming base damage.
signal damaged(amount: float, info: Dictionary)
signal died
signal respawned

@onready var core: DummyCore = $DummyCore


func _ready() -> void:
	core.damaged.connect(damaged.emit)
	core.died.connect(died.emit)
	core.respawned.connect(respawned.emit)


## AimAssist target (group "aim_target", added by DummyCore).
func get_aim_points() -> Dictionary:
	return core.get_aim_points()


## Weapon contract. Shield/zone rules live in HealthShield via DummyCore.
func take_damage(amount: float, info: Dictionary) -> void:
	core.take_damage(amount, info)
