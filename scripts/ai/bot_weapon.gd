class_name BotWeapon
extends Weapon
## Weapon driven by a Bot instead of WeaponHolder/Player. Same WeaponData, damage, falloff,
## zone, spread, bloom, recoil and fire-rate code as the player's weapon, so TTK is identical.
##
## Uses the Weapon AI hooks on origin/main (47b876f):
##   aim_source         the bot's Eye (Node3D): ray origin, aim direction, spread basis, melee.
##   hit_mask_override  HIT_MASK | LAYER_PLAYER, so bot shots and melee can hit the player.
##   exclude_bodies     the bot's capsule, hurtbox and head hitboxes (the eye sits in the helmet).
##   shooter            the bot, reported as info.source for kill credit.
## camera, player and aim_assist stay null: no lunge (Bot lunges itself, then calls melee()
## once in melee_range), no recoil-to-view (Bot applies get_recoil() to its eye), no bend.
## Overrides only get_spread (airborne spread, which Weapon reads from `player`) and holster
## (also cancels the bot's lunge).

## Owning bot. Untyped so this file doesn't depend on Bot at parse time.
var bot: Node3D
## Player weapon scene this weapon mirrors (drops need a real Weapon scene for the pickup).
var source_scene: PackedScene


## Wires the AI hooks. Call before add_child (exclude_bodies may be refreshed later).
func configure(owner_bot: Node3D, aim: Node3D, own_bodies: Array[CollisionObject3D]) -> void:
	bot = owner_bot
	shooter = owner_bot
	aim_source = aim
	exclude_bodies = own_bodies
	hit_mask_override = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
	aim_assist = null


func holster() -> void:
	super()
	if bot != null and bot.has_method("cancel_lunge"):
		bot.cancel_lunge()


func get_spread() -> float:
	var spread := super()
	var body := bot as CharacterBody3D
	if data == null or body == null or body.is_on_floor():
		return spread
	var add := data.spread_air_add
	if zoomed:
		add *= data.zoom_spread_multiplier
	if alt_mode:
		add *= data.alt_spread_multiplier
	return spread + add
