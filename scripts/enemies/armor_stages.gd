class_name ArmorStages
extends Node
## Janissary damage states from the enemy board. No energy shield: the plate is HealthShield's
## shield pool with recharge turned off (Enemy sets that up), and this node turns how much plate
## is left into the three readable stages:
##   1 FULL     full plate. Rounds spark and whine off it.
##   2 SPALLED  plate <= EnemyType.spall_fraction: crest and pauldrons come off, the silhouette
##              shrinks, so the player sees progress.
##   3 EXPOSED  plate gone: the frame shows, hydraulics vent; faster, reckless, closes for melee.
## Stages only go up until reset() (respawn). EnemyRig shows them; EnemyBrain reacts to EXPOSED.

signal stage_changed(stage: Stage)

enum Stage { FULL = 1, SPALLED = 2, EXPOSED = 3 }

var stage: Stage = Stage.FULL
var spall_fraction: float = 0.5

var _health: HealthShield


func setup(health_shield: HealthShield, spall_at: float) -> void:
	_health = health_shield
	spall_fraction = spall_at
	_health.changed.connect(_on_changed)


func reset() -> void:
	stage = Stage.FULL


## Stage for a plate value; pure, so the self-test can check thresholds directly.
static func stage_for(plate: float, max_plate: float, spall_at: float) -> Stage:
	if max_plate <= 0.0 or plate <= 0.0:
		return Stage.EXPOSED
	if plate <= max_plate * spall_at:
		return Stage.SPALLED
	return Stage.FULL


func _on_changed(shield: float, _health_left: float) -> void:
	if _health.dead:
		return
	var next := stage_for(shield, _health.max_shield, spall_fraction)
	# A single heavy hit can skip SPALLED; still show both stages in order.
	while next > stage:
		stage = (stage + 1) as Stage
		stage_changed.emit(stage)
