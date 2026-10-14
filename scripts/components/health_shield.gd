class_name HealthShield
extends Node
## Halo 2/3-style shield over health. Shared by the player and enemies.
##
## Damage contract (keys read from the info Dictionary passed to take_damage):
##   zone_multiplier   float, default 1.0. Applies to HEALTH damage only, never to shields.
##   shield_multiplier float, default 1.0. Applies to SHIELD damage only.
##   bleedthrough      bool, default false. If false, a hit that breaks the shield is fully
##                     absorbed: its overflow does NOT spill into health (Halo 2/3 default).
##                     If true, the overflow carries into health, with zone_multiplier applied.
## amount is the base damage after range falloff, before zone and shield multipliers.

signal shield_damaged(amount: float)
signal shield_broken
signal shield_recharge_started
signal shield_full
signal health_damaged(amount: float)
signal died
## Any change to shield or health, for HUDs and readouts.
signal changed(shield: float, health: float)

@export var max_shield: float = 70.0
@export var max_health: float = 45.0
## Seconds without damage before the shield starts refilling.
@export var recharge_delay: float = 5.0
## Seconds for an empty shield to refill completely.
@export var recharge_time: float = 2.5
## Off in Phase 0: health only returns on reset(). Kept as a toggle for later tuning.
@export var health_regen: bool = false
@export var health_regen_delay: float = 8.0
@export var health_regen_time: float = 6.0

var shield: float = 0.0
var health: float = 0.0
var dead: bool = false
var recharging: bool = false

var _since_damage: float = 0.0


func _ready() -> void:
	reset()


## Full shield and health, alive. Call on respawn.
func reset() -> void:
	shield = max_shield
	health = max_health
	dead = false
	recharging = false
	_since_damage = 0.0
	changed.emit(shield, health)


## Applies one hit. Returns {"shield": dealt, "health": dealt, "broke": bool, "killed": bool}.
func apply_damage(amount: float, info: Dictionary = {}) -> Dictionary:
	var result := {"shield": 0.0, "health": 0.0, "broke": false, "killed": false}
	if dead or amount <= 0.0:
		return result
	var zone_mult: float = info.get("zone_multiplier", 1.0)
	var shield_mult: float = info.get("shield_multiplier", 1.0)
	var bleedthrough: bool = info.get("bleedthrough", false)
	_since_damage = 0.0
	recharging = false
	var to_health := amount * zone_mult
	if shield > 0.0:
		var to_shield := amount * shield_mult
		var dealt := minf(to_shield, shield)
		shield -= dealt
		result.shield = dealt
		shield_damaged.emit(dealt)
		if shield > 0.0:
			changed.emit(shield, health)
			return result
		result.broke = true
		shield_broken.emit()
		if not bleedthrough or shield_mult <= 0.0:
			changed.emit(shield, health)
			return result
		# Convert leftover shield damage back to base damage, then apply the zone.
		to_health = (to_shield - dealt) / shield_mult * zone_mult
	if to_health > 0.0:
		var hurt := minf(to_health, health)
		health -= hurt
		result.health = hurt
		health_damaged.emit(hurt)
	changed.emit(shield, health)
	if health <= 0.0:
		dead = true
		result.killed = true
		died.emit()
	return result


func is_shield_up() -> bool:
	return shield > 0.0


func _physics_process(delta: float) -> void:
	if dead:
		return
	_since_damage += delta
	if shield < max_shield and _since_damage >= recharge_delay:
		if not recharging:
			recharging = true
			shield_recharge_started.emit()
		shield = minf(shield + max_shield / maxf(recharge_time, 0.001) * delta, max_shield)
		if shield >= max_shield:
			recharging = false
			shield_full.emit()
		changed.emit(shield, health)
	if health_regen and health < max_health and _since_damage >= health_regen_delay:
		health = minf(health + max_health / maxf(health_regen_time, 0.001) * delta, max_health)
		changed.emit(shield, health)
