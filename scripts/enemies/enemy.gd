class_name Enemy
extends Bot
## A New Ottoman soldier: a Bot (movement, perception, aim model, weapons, nav) configured by an
## EnemyType. Before Bot._ready runs it sets the body size and speed, the plate and health pools,
## the weapons, the per-rank temperament on a copy of the campaign difficulty, and builds the
## greybox body (EnemyRig, child "Rig", which also owns the head hitboxes Bot expects).
## The Brain child is an EnemyBrain; an Orta (squad) gives it orders.
##
## Plate: HealthShield's shield pool with recharge off. Bot and BotBrain already treat "shield
## up" as "body shots only", which is exactly how plate should play. ArmorStages (child, added
## when the type has plate) turns it into the board's three damage states.

## Enemies of every corps share this team; the player is team 0.
## x the preset's strafe_error_bump. Arena bots lose their aim on every ADAD reversal so humans
## can out-strafe them; against the allied bots (who strafe constantly) that left a whole orta
## landing about one hit a wave. Drilled soldiers keep more of their aim.
const STRAFE_ERROR_SCALE := 0.35
const LEAD_SKILL := 0.8
const FACTION_TEAM := 7
const GROUP := &"new_ottoman"
## HealthShield never starts its recharge: plate does not grow back.
const NO_RECHARGE := 1.0e9

@export var enemy_type: EnemyType

var armor_stages: ArmorStages
## LAN client copy (NetEnemies): drawn from host snapshots, never thinks or takes damage
## here (the host owns its health), never drops weapons. Set before add_child.
var net_copy: bool = false
## Copies: the host's enemy is fighting (the rig raises its weapon).
var net_aiming: bool = false


func _ready() -> void:
	if enemy_type == null:
		push_error("%s: Enemy without an EnemyType" % name)
		enemy_type = EnemyType.new()
	_apply_type()
	super()
	add_to_group(GROUP)
	add_to_group(SpawnManager.THREAT_GROUP)
	# Bot starts looking down -Z; face the way the enemy was placed instead.
	var facing := -global_transform.basis.z
	set_aim(Vector3(facing.x, 0.0, facing.z))
	respawned.connect(_on_respawned)


func get_rig() -> EnemyRig:
	return rig as EnemyRig


func get_stage() -> int:
	return armor_stages.stage if armor_stages != null else ArmorStages.Stage.EXPOSED


func _apply_type() -> void:
	var t := enemy_type
	display_name = t.display_name
	team = FACTION_TEAM
	body_scale = t.body_scale()
	speed_scale = t.speed_scale
	starting_weapons = t.starting_weapons.duplicate()
	drop_weapon_on_death = t.drops_weapons and not net_copy
	var box := hurtbox_shape.shape as BoxShape3D
	var across := body_scale * t.hitbox_scale
	box.size = Vector3(t.hurtbox_size.x * across, box.size.y, t.hurtbox_size.y * across)
	health_shield.max_shield = t.armor
	health_shield.max_health = t.health
	health_shield.recharge_delay = NO_RECHARGE
	health_shield.health_regen = false
	health_shield.reset()
	difficulty = _tuned_difficulty(difficulty, t)
	if t.armor > 0.0:
		armor_stages = ArmorStages.new()
		armor_stages.name = "ArmorStages"
		add_child(armor_stages)
		armor_stages.setup(health_shield, t.spall_fraction)
		armor_stages.stage_changed.connect(_on_stage_changed)
	(rig as EnemyRig).build(self, t)
	# The rig made the label; Bot's @onready lookup ran before it existed.
	label = get_node_or_null(^"Rig/HPLabel") as Label3D


## A per-enemy copy of the campaign preset with the rank's temperament applied.
static func _tuned_difficulty(preset: BotDifficulty, t: EnemyType) -> BotDifficulty:
	var d: BotDifficulty = preset.duplicate() if preset != null else BotDifficulty.new()
	d.aggression = t.aggression
	d.melee_eagerness = t.melee_eagerness
	d.aim_error_deg *= t.aim_error_scale
	d.min_error_deg *= t.aim_error_scale
	d.reaction_time *= t.reaction_scale
	d.strafe_error_bump *= STRAFE_ERROR_SCALE
	# Lead moving targets well: wide error decides lethality, not tracking lag.
	d.lead_skill = maxf(d.lead_skill, LEAD_SKILL)
	d.semi_cadence = clampf(d.semi_cadence * t.fire_rate_scale, 0.1, 1.0)
	d.spray_time *= t.fire_rate_scale
	d.burst_pause /= maxf(t.fire_rate_scale, 0.1)
	d.sight_range = t.sight_range
	d.uses_zoom = t.uses_zoom
	d.strafe_frequency = clampf(d.strafe_frequency * t.strafe_scale, 0.0, 1.0)
	d.jump_chance *= t.strafe_scale
	d.crouch_chance *= t.strafe_scale
	# No shield to wait for: plate never recharges, so the arena retreat rule never applies.
	d.retreat_chance = 0.0
	d.use_skill_jumps = false
	return d


## A client copy's health comes from the host; local hits only show hit markers.
func take_damage(amount: float, info: Dictionary) -> void:
	if net_copy:
		return
	super(amount, info)


## The rig carries the visible weapon props; drop the Bot's placeholder box.
func _make_weapon(data: WeaponData, scene: PackedScene) -> BotWeapon:
	var w := super(data, scene)
	for child in w.get_children():
		if child is MeshInstance3D:
			w.remove_child(child)
			child.free()
	return w


func _on_stage_changed(stage: ArmorStages.Stage) -> void:
	if stage == ArmorStages.Stage.EXPOSED:
		speed_scale = enemy_type.speed_scale * enemy_type.exposed_speed_scale
		difficulty.aggression = 1.0
		difficulty.melee_eagerness = maxf(difficulty.melee_eagerness, 0.9)


func _on_respawned(_bot: Bot) -> void:
	speed_scale = enemy_type.speed_scale
	difficulty.aggression = enemy_type.aggression
	difficulty.melee_eagerness = enemy_type.melee_eagerness
	if armor_stages != null:
		armor_stages.reset()
	(rig as EnemyRig).reset_armor()
