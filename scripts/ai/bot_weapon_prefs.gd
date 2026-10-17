class_name BotWeaponPrefs
extends RefCounted
## Bot weapon preferences for the five-gun roster (docs/ai/arena_ai_spec.md, "Weapon roles").
## Static helpers used by BotBrain: weapon scoring, range bands, fire-mode management and ammo
## totals. The pistol and rifle keep BotBrain's original scoring and range bands.
##
## Roles come from WeaponData.resource_path (the network weapon id) for the shipped guns, and
## from the data's mechanics for anything else (projectile -> LAUNCHER, pellets -> SHOTGUN,
## battery or a shield bonus -> ENERGY, AUTO -> RIFLE, otherwise PISTOL). Melee weapons
## (WeaponData.melee_primary: sword, hammer) are MELEE whatever their path.

## Append, never reorder.
enum Role { RIFLE, PISTOL, CARBINE, SHOTGUN, ENERGY, LAUNCHER, MELEE }

const ROLE_BY_PATH := {
	"res://resources/weapons/standard_issue_rifle.tres": Role.RIFLE,
	"res://resources/weapons/service_pistol.tres": Role.PISTOL,
	"res://resources/weapons/marksman_carbine.tres": Role.CARBINE,
	"res://resources/weapons/combat_shotgun.tres": Role.SHOTGUN,
	# The id outlived the DER: it is the rocket launcher now.
	"res://resources/weapons/directed_energy_rifle.tres": Role.LAUNCHER,
}
## Preferred engagement bands (m) for the new roles. Shotgun: well inside its 6 m full-damage range,
## so the bot pushes in. Carbine: mid-long, inside its 50 m full-damage range. Energy (the DER, a
## scoped one-shot since the v2 TTK pass): mid-long, inside its 40 m one-shot range.
const RANGE_CARBINE := Vector2(15.0, 50.0)
const RANGE_SHOTGUN := Vector2(0.0, 4.0)
const RANGE_ENERGY := Vector2(12.0, 40.0)
## Launcher: far enough out that the bot stays clear of its own 6 m blast, close enough that
## a 35 m/s rocket is hard to sidestep.
const RANGE_LAUNCHER := Vector2(10.0, 30.0)
## Melee weapons: always close in (the brain swings whenever the target is in lunge reach).
const RANGE_MELEE := Vector2(0.0, 3.0)
## Charged melee weapon: the best thing to hold once the target is inside its lunge reach plus
## this, a fair one while closing in to MELEE_CHASE, a poor one beyond.
const MELEE_MARGIN := 2.0
const MELEE_CHASE := 15.0
## Below this (minus hysteresis while held) a rocket would splash the bot itself: swap off it.
const LAUNCHER_NEAR := 8.0
const LAUNCHER_FAR := 30.0
## Carrying a loaded shotgun and the target is closer than this: close the distance with it.
const SHOTGUN_PUSH_RANGE := 14.0
## Shotgun wins below this (plus hysteresis while held), is a poor choice past SHOTGUN_FAR.
const SHOTGUN_NEAR := 7.0
const SHOTGUN_FAR := 15.0
const CARBINE_NEAR := 12.0
## DER: one-shots anything inside this range (falloff starts at 40 m), shield up or down.
const ENERGY_RANGE := 40.0
## Heat at which a bot lets go of the DER trigger, and the heat it waits for before resuming.
const HEAT_STOP := 0.85
const HEAT_RESUME := 0.4
## Charge shot: only on a near-full shield, in range, from a cool gun.
const CHARGE_RANGE := 25.0
const CHARGE_MIN_SHIELD := 0.9
## Pickup distance multipliers (< 1 = more attractive) for guns the bot doesn't carry.
const PICKUP_WEIGHT := {
	Role.CARBINE: 0.8, Role.SHOTGUN: 0.6, Role.ENERGY: 0.6, Role.LAUNCHER: 0.6, Role.MELEE: 0.5
}
const HYSTERESIS := 3.0
## Bots only detour for a same-id battery-weapon swap (flat DER) gaining at least this much.
const MIN_BATTERY_GAIN := 25
## Pistol / rifle: rifle below WEAPON_SPLIT, pistol above, with +/- WEAPON_SWITCH_HYSTERESIS so a
## bot near the split doesn't swap back and forth: holding the rifle it switches past 31 m,
## holding the pistol it switches back under 25 m.
const WEAPON_SPLIT := 28.0
const WEAPON_SWITCH_HYSTERESIS := 3.0
## Rifle AUTO <-> BURST hysteresis past BotDifficulty.burst_switch_range, and pistol zoom range.
const BURST_HYSTERESIS := 3.0
const ZOOM_RANGE := 25.0


static func role_of(w: Weapon) -> int:
	if w == null or w.data == null:
		return Role.PISTOL
	var data := w.data
	if data.melee_primary:
		return Role.MELEE
	if ROLE_BY_PATH.has(data.resource_path):
		return ROLE_BY_PATH[data.resource_path]
	if data.projectile_speed > 0.0:
		return Role.LAUNCHER
	if data.pellet_count > 1:
		return Role.SHOTGUN
	if data.battery or data.shield_damage_multiplier > 1.0:
		return Role.ENERGY
	if data.fire_mode == WeaponData.FireMode.AUTO:
		return Role.RIFLE
	return Role.PISTOL


## Preferred band for the new roles; Vector2.ZERO for PISTOL / RIFLE (use the brain's bands).
static func band(role: int) -> Vector2:
	match role:
		Role.CARBINE:
			return RANGE_CARBINE
		Role.SHOTGUN:
			return RANGE_SHOTGUN
		Role.ENERGY:
			return RANGE_ENERGY
		Role.LAUNCHER:
			return RANGE_LAUNCHER
		Role.MELEE:
			return RANGE_MELEE
	return Vector2.ZERO


## Score for holding w at dist (the brain switches when the other gun beats the active one by
## more than 1). `held`: the active weapon gets the hysteresis margin. total_ammo <= 0: -100.
## PISTOL / RIFLE keep the brain's original scoring: 2.0 in band and 0.5 / -0.5 out of band.
static func score(
	w: Weapon, dist: float, held: bool, _target_shielded: bool, total_ammo: int
) -> float:
	if w == null or w.data == null or total_ammo <= 0:
		return -100.0
	var margin := HYSTERESIS if held else 0.0
	match role_of(w):
		Role.SHOTGUN:
			if dist < SHOTGUN_NEAR + margin:
				return 4.0
			return 1.0 if dist < SHOTGUN_FAR else -1.0
		Role.CARBINE:
			return 3.5 if dist >= CARBINE_NEAR - margin else 0.5
		Role.ENERGY:
			if w.overheated or w.heat >= HEAT_STOP:
				return -2.0
			# One-shot kill whatever the shield: the best gun in its range, still decent past it
			# (two shots). Close in, the 1.67 s cycle loses to anything automatic.
			if dist < CARBINE_NEAR - margin:
				return 1.0
			return 4.0 if dist < ENERGY_RANGE + margin else 2.5
		Role.LAUNCHER:
			if dist < LAUNCHER_NEAR - margin:
				return -1.0
			return 4.0 if dist < LAUNCHER_FAR + margin else 1.5
		Role.MELEE:
			if w.magazine <= 0:
				return -100.0  # an empty sword / hammer only bashes: anything else is better
			if dist < w.data.melee_lunge_range + MELEE_MARGIN + margin:
				return 6.0
			return 2.2 if dist < MELEE_CHASE + margin else -1.0
	var auto := w.data.fire_mode == WeaponData.FireMode.AUTO
	var split := WEAPON_SPLIT
	if held:
		split += WEAPON_SWITCH_HYSTERESIS if auto else -WEAPON_SWITCH_HYSTERESIS
	if auto:
		return 2.0 if dist < split else -0.5
	return 2.0 if dist >= split else 0.5


## True when the gun gives the head no bonus (DER): aim centre mass. The shotgun has one (a head
## blast: the centre pellet on the head), so a bot goes for it once the shield is down.
static func body_only(w: Weapon) -> bool:
	return (
		w != null
		and w.data != null
		and w.data.headshot_armored_multiplier <= 1.0
		and w.data.headshot_unarmored_multiplier <= 1.0
	)


## A loaded shotgun-role weapon in either slot.
static func has_loaded_shotgun(slots: Array) -> bool:
	for w in slots:
		var weapon := w as Weapon
		if (
			weapon != null
			and role_of(weapon) == Role.SHOTGUN
			and weapon.magazine + weapon.reserve > 0
		):
			return true
	return false


## A battery swap (WeaponPickup.is_battery_upgrade_for) gaining < MIN_BATTERY_GAIN: not worth
## a bot's detour. Players take any gain.
static func small_battery_gain(pickup: WeaponPickup, bot: Bot) -> bool:
	return pickup.is_battery_upgrade_for(bot) and pickup.battery_gain_for(bot) < MIN_BATTERY_GAIN


static func pickup_weight(pickup: WeaponPickup) -> float:
	if pickup == null or pickup.weapon == null:
		return 1.0
	return PICKUP_WEIGHT.get(role_of(pickup.weapon), 1.0)


## A charge shot is worth it: the gun can charge, is cool, has the battery for it, and the
## target's shield is near full and in range.
static func want_charge(w: Weapon, dist: float, target_shield_fraction: float) -> bool:
	var data := w.data
	if data == null or data.alt_fire_mode != WeaponData.FireMode.CHARGE:
		return false
	return (
		dist <= CHARGE_RANGE
		and target_shield_fraction >= CHARGE_MIN_SHIELD
		and w.heat <= 0.1
		and not w.overheated
		and w.magazine >= data.charge_ammo_cost
	)


## DER heat discipline (false for guns without heat): let go near overheat, resume once cooled.
static func keep_cooling(w: Weapon, cooling: bool) -> bool:
	if w.data == null or w.data.heat_per_shot <= 0.0:
		return false
	if w.overheated or w.heat >= HEAT_STOP:
		return true
	if w.heat <= HEAT_RESUME:
		return false
	return cooling


## Range band for the active weapon. Pistol / rifle: the brain's original bands, passed in.
## Carrying a loaded shotgun with the target inside SHOTGUN_PUSH_RANGE: the shotgun band, so
## the bot closes the distance (it switches to the shotgun once inside SHOTGUN_NEAR).
static func band_for(
	w: Weapon, slots: Array, dist: float, rifle_band: Vector2, pistol_band: Vector2
) -> Vector2:
	if dist < SHOTGUN_PUSH_RANGE and has_loaded_shotgun(slots):
		return RANGE_SHOTGUN
	var roster := band(role_of(w))
	if roster != Vector2.ZERO:
		return roster
	if w != null and w.data != null and w.data.fire_mode != WeaponData.FireMode.AUTO:
		return pistol_band
	return rifle_band


## Target shield 0..1 (1.0 when it has no HealthShield).
static func shield_fraction(target: Node) -> float:
	var hs := target.get_node_or_null(^"HealthShield") as HealthShield if target != null else null
	return hs.shield / maxf(hs.max_shield, 0.001) if hs != null else 1.0


## Puts a CHARGE-capable gun in or out of CHARGE mode for want_charge (never mid-charge).
## Returns true if it toggled.
static func sync_charge_mode(w: Weapon, use_charge: bool, dist: float, target: Node) -> bool:
	if w.data.alt_fire_mode != WeaponData.FireMode.CHARGE or w.charging:
		return false
	var want := use_charge and want_charge(w, dist, shield_fraction(target))
	if want == w.alt_mode:
		return false
	w.toggle_fire_mode()
	return true


## Rifle AUTO <-> BURST by range, DER CHARGE mode (sync_charge_mode), pistol zoom.
## Returns true if a fire mode toggled (the brain then forgets its held press).
static func manage_modes(
	w: Weapon, dist: float, diff: BotDifficulty, use_charge: bool, target: Node
) -> bool:
	var data := w.data
	var toggled := false
	var can_burst := (
		data.fire_mode == WeaponData.FireMode.AUTO
		and data.alt_fire_mode == WeaponData.FireMode.BURST
	)
	if can_burst:
		var want_alt := dist > diff.burst_switch_range + (0.0 if w.alt_mode else BURST_HYSTERESIS)
		if not w.alt_mode and want_alt or w.alt_mode and dist < diff.burst_switch_range:
			w.toggle_fire_mode()
			toggled = true
	if sync_charge_mode(w, use_charge, dist, target):
		toggled = true
	if data.secondary == WeaponData.Secondary.ZOOM:
		var want_zoom := diff.uses_zoom and dist > ZOOM_RANGE and not w.reloading
		if want_zoom != w.zoomed:
			w.set_zoom(want_zoom)
	return toggled


## Rounds carried across all of a bot's slots (Bot.total_ammo per slot).
static func all_ammo(bot: Bot) -> int:
	var total := 0
	for w in bot.slots:
		total += bot.total_ammo(w)
	return total


## Carried rounds / carry capacity across slots (0 with nothing carried).
static func ammo_fraction(slots: Array) -> float:
	var have := 0.0
	var cap := 0.0
	for slot in slots:
		var w := slot as Weapon
		if w != null and w.data != null:
			have += w.magazine + w.reserve
			cap += w.data.magazine_size + w.data.reserve_max
	return have / cap if cap > 0.0 else 0.0


## Launch direction for a projectile at `speed` under `gravity` from `from` to hit `to`: the
## flat or the high (lob) solution. Out of range: a 45 degree shot toward the target, the
## longest throw there is.
static func ballistic_direction(
	from: Vector3, to: Vector3, speed: float, gravity: float, high: bool
) -> Vector3:
	var delta := to - from
	var flat := Vector3(delta.x, 0.0, delta.z)
	var x := flat.length()
	if x < 0.01 or gravity <= 0.0:
		return delta.normalized()
	var dir := flat / x
	var v2 := speed * speed
	var root := v2 * v2 - gravity * (gravity * x * x + 2.0 * delta.y * v2)
	var angle := PI * 0.25
	if root >= 0.0:
		var s := sqrt(root)
		angle = atan((v2 + s) / (gravity * x)) if high else atan((v2 - s) / (gravity * x))
	return (dir * cos(angle) + Vector3.UP * sin(angle)).normalized()
