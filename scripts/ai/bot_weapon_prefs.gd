class_name BotWeaponPrefs
extends RefCounted
## Bot weapon preferences for the five-gun roster (docs/ai/arena_ai_spec.md, "Weapon roles").
## Static helpers used by BotBrain. The pistol and rifle keep BotBrain's original scoring and
## range bands (role PISTOL / RIFLE return NAN from score() so the brain uses its legacy path).
##
## Roles come from WeaponData.resource_path (the network weapon id) for the shipped guns, and
## from the data's mechanics for anything else (pellets -> SHOTGUN, battery or a shield bonus ->
## ENERGY, AUTO -> RIFLE, otherwise PISTOL).

enum Role { RIFLE, PISTOL, CARBINE, SHOTGUN, ENERGY }

const ROLE_BY_PATH := {
	"res://resources/weapons/standard_issue_rifle.tres": Role.RIFLE,
	"res://resources/weapons/service_pistol.tres": Role.PISTOL,
	"res://resources/weapons/marksman_carbine.tres": Role.CARBINE,
	"res://resources/weapons/combat_shotgun.tres": Role.SHOTGUN,
	"res://resources/weapons/directed_energy_rifle.tres": Role.ENERGY,
}
## Preferred engagement bands (m) for the new roles. Shotgun: inside its 3 m full-damage range,
## so the bot pushes in. Carbine: mid-long, inside its 50 m full-damage range. Energy: inside the
## 20 m bolt falloff start.
const RANGE_CARBINE := Vector2(15.0, 50.0)
const RANGE_SHOTGUN := Vector2(0.0, 4.0)
const RANGE_ENERGY := Vector2(6.0, 20.0)
## Carrying a loaded shotgun and the target is closer than this: close the distance with it.
const SHOTGUN_PUSH_RANGE := 14.0
## Shotgun wins below this (plus hysteresis while held), is a poor choice past SHOTGUN_FAR.
const SHOTGUN_NEAR := 7.0
const SHOTGUN_FAR := 15.0
const CARBINE_NEAR := 12.0
## DER: worth holding on a shielded target inside this range.
const ENERGY_RANGE := 30.0
## Heat at which a bot lets go of the DER trigger, and the heat it waits for before resuming.
const HEAT_STOP := 0.85
const HEAT_RESUME := 0.4
## Charge shot: only on a near-full shield, in range, from a cool gun.
const CHARGE_RANGE := 25.0
const CHARGE_MIN_SHIELD := 0.9
## Pickup distance multipliers (< 1 = more attractive) for guns the bot doesn't carry.
const PICKUP_WEIGHT := {Role.CARBINE: 0.8, Role.SHOTGUN: 0.6, Role.ENERGY: 0.6}
const HYSTERESIS := 3.0


static func role_of(w: Weapon) -> int:
	if w == null or w.data == null:
		return Role.PISTOL
	var data := w.data
	if ROLE_BY_PATH.has(data.resource_path):
		return ROLE_BY_PATH[data.resource_path]
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
	return Vector2.ZERO


## Score for holding w at dist (the brain switches when the other gun beats the active one by
## more than 1). NAN for PISTOL / RIFLE: the brain keeps its original scoring for them, whose
## values are 2.0 in band and 0.5 / -0.5 out of band.
static func score(w: Weapon, dist: float, held: bool, target_shielded: bool) -> float:
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
			if not target_shielded:
				# Shield's down: swap to the precision gun for the finish (DER + pistol combo).
				return -1.5
			return 3.5 if dist < ENERGY_RANGE + margin else 0.0
	return NAN


## True when the gun gives the head no bonus (shotgun, DER): aim centre mass.
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
