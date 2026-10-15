class_name NetWeapon
extends RefCounted
## Weapon networking helpers (static). Weapons are identified on the wire by
## WeaponPickup.weapon_id_of(): the WeaponData resource_path (resources/weapons/*.tres, never
## renamed). Instances are spawned from scene_file_path. Any weapon that fires through Weapon's
## shared path (_emit_shots -> _fire_ray) is networked with no per-weapon code: the client
## captures every ray (NetShot, Weapon.ray_fired) and the host re-casts with its own copy.
##
## Host replay (replay()), designed against main-guns 62455c0 and origin/main:
##   * Single-ray shots (rifle, pistol, carbine, DER charge) re-cast the client's final ray
##     direction after checking it lies inside the weapon's spread + bullet-bend cone. This keeps
##     AimAssist bend (the host can't reproduce it: it depends on the client's view of targets)
##     and works on origin/main's weapon.gd, which has no seeding.
##   * Pellet blasts (data.pellet_count > 1) replay the pattern exactly: next_shot_seed = the
##     client's last_shot_seed and next_shot_spread = its spread, then _emit_shots(), which
##     seeds via _seed_shot() / _shot_spread(). Pellets never bend. Whatever damage model the
##     weapon uses (main-guns next: one take_damage per victim per blast, summed after falloff)
##     the host gets it for free, and NetMatch broadcasts whatever damaged signals result.
##   * Charged shots (DER): accepted only when the client-reported charge peaked >= 1.0 since
##     the last charged shot (see NetMatch). _fire_ray(dir, charge_damage_multiplier) when
##     _fire_ray takes a damage scale, else seeded _emit_shots(charge_damage_multiplier).
##   * After any replay or rejection the pending seed / spread are cleared (clear_pending()).
##   * FX: every ray's end point from ray_fired, batched into one message per request. If a
##     weapon's pellets stop going through _fire_ray (no ray_fired), the client's directions
##     stand in (max_range, no impact puffs).
## Heat / charge sync uses weapon.heat_charge.get_net_state() / apply_net_state() when present.
## All newer members are probed with `in` / has_method, so this runs on origin/main unchanged.

## Degrees of slack on top of spread + bend for a client's ray direction.
const DIR_TOLERANCE_DEG := 0.5
## Metres a fire request's origin may be from the host's copy of the shooter's eye.
const ORIGIN_TOLERANCE := 1.25
## Weapon state synced in client state and snapshots (members a weapon lacks read as 0).
## Indices 5..7 are WeaponHeatCharge's vent_left, since_shot, charge_held.
const STATE_KEYS: Array[StringName] = [
	&"magazine",
	&"heat",
	&"overheated",
	&"charging",
	&"charge",
	&"vent_left",
	&"since_shot",
	&"charge_held"
]
const HEAT_CHARGE_KEYS: Array[String] = [
	"heat", "overheated", "vent_left", "since_shot", "charging", "charge_held"
]


static func id_of(weapon: Weapon) -> String:
	return WeaponPickup.weapon_id_of(weapon)


## False on a net client: damage, projectiles and pickups from this weapon are predictions.
static func is_authoritative(node: Node) -> bool:
	return node == null or not node.is_inside_tree() or node.multiplayer.is_server()


## Fire modes the weapon can legitimately be in.
static func valid_mode(data: WeaponData, mode: int) -> bool:
	if mode == data.fire_mode:
		return true
	var can_toggle := data.fire_select or data.secondary == WeaponData.Secondary.TOGGLE_MODE
	return can_toggle and mode == data.alt_fire_mode


## Sustained shots per second the host accepts (fire_rate, or the in-burst rate).
static func max_rate(data: WeaponData) -> float:
	var rate := data.fire_rate
	var bursts := data.fire_mode == WeaponData.FireMode.BURST
	bursts = bursts or data.alt_fire_mode == WeaponData.FireMode.BURST
	if bursts and data.burst_interval > 0.0:
		rate = maxf(rate, 1.0 / data.burst_interval)
	return rate


## Shots allowed back to back (bucket size): a burst plus one buffered press.
static func rate_burst(data: WeaponData) -> float:
	return float(maxi(data.burst_count, 1) + 1)


## Range the host clamps a client's reported spread (degrees) into.
static func spread_bounds(data: WeaponData) -> Vector2:
	var low := data.spread_base * minf(data.zoom_spread_multiplier, 1.0)
	low *= minf(data.alt_spread_multiplier, 1.0)
	var high := (data.spread_max + data.spread_air_add) * maxf(data.alt_spread_multiplier, 1.0)
	return Vector2(low * 0.95, high * 1.05)


static func pellets_of(data: WeaponData) -> int:
	var count: Variant = data.get(&"pellet_count")
	return maxi(int(count), 1) if count != null else 1


static func is_battery(data: WeaponData) -> bool:
	return data.get(&"battery") == true


## Scene to instantiate for a weapon id, from a carried or dropped instance's scene path.
static func scene_of(scene_path: String) -> PackedScene:
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		return null
	return load(scene_path) as PackedScene


## STATE_KEYS values; missing members are 0. Never sent on heat_changed (every tick): only
## in the per-tick client state and the 30 Hz snapshots.
static func state_of(weapon: Weapon) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(STATE_KEYS.size())
	if weapon == null:
		return out
	for i in 5:
		if STATE_KEYS[i] in weapon:
			out[i] = float(weapon.get(STATE_KEYS[i]))
	var net := heat_entry(weapon)
	out[5] = float(net.get("vent_left", 0.0))
	out[6] = float(net.get("since_shot", 0.0))
	out[7] = float(net.get("charge_held", 0.0))
	return out


## Applies a synced state to a copy that isn't simulating it (host copy of a client's weapon,
## remote puppets). Magazine only for battery weapons (the host keeps its own round count).
static func apply_state(weapon: Weapon, state: PackedFloat32Array) -> void:
	if weapon == null or weapon.data == null or state.size() != STATE_KEYS.size():
		return
	if is_battery(weapon.data):
		weapon.magazine = int(state[0])
	var net := {}
	for i in HEAT_CHARGE_KEYS.size():
		net[HEAT_CHARGE_KEYS[i]] = state[[1, 2, 5, 6, 3, 7][i]]
	net["overheated"] = state[2] > 0.5
	net["charging"] = state[3] > 0.5
	if apply_heat(weapon, net):
		return
	if &"heat" in weapon:
		weapon.set(&"heat", state[1])
	if &"overheated" in weapon:
		weapon.set(&"overheated", state[2] > 0.5)
	if &"charging" in weapon:
		weapon.set(&"charging", state[3] > 0.5)
	if &"charge" in weapon:
		weapon.set(&"charge", state[4])


## Heat / charge state for loadouts and drops (a picked-up DER keeps heat and vent time):
## heat_charge.get_net_state() when the weapon has it, else whichever plain members exist.
static func heat_entry(weapon: Weapon) -> Dictionary:
	var helper: Variant = weapon.get(&"heat_charge") if &"heat_charge" in weapon else null
	if helper is Object and (helper as Object).has_method(&"get_net_state"):
		return (helper as Object).call(&"get_net_state")
	var out := {}
	for key: String in ["heat", "overheated", "charging"]:
		if key in weapon:
			out[key] = weapon.get(key)
	return out


## Applies heat_entry() output. True when heat_charge.apply_net_state took it.
static func apply_heat(weapon: Weapon, state: Dictionary) -> bool:
	if weapon == null or state.is_empty():
		return false
	var helper: Variant = weapon.get(&"heat_charge") if &"heat_charge" in weapon else null
	if helper is Object and (helper as Object).has_method(&"apply_net_state"):
		(helper as Object).call(&"apply_net_state", state)
		return true
	for key: String in state:
		if key in weapon:
			weapon.set(key, state[key])
	return false


## Forget a seed / spread set for a replay so it can't leak into the next shot.
static func clear_pending(weapon: Weapon) -> void:
	if weapon == null:
		return
	if &"_has_next_seed" in weapon:
		weapon.set(&"_has_next_seed", false)
	if &"next_shot_spread" in weapon:
		weapon.set(&"next_shot_spread", -1.0)


static func _arg_count(weapon: Weapon, method: StringName) -> int:
	if not weapon.has_method(method):
		return -1
	return weapon.get_method_argument_count(method)


## Host: re-casts a client's request with the host's copy of the weapon, aimed from proxy (a
## Node3D the caller placed at the request origin / basis). charge_ok: the host's copy reached
## full charge. Returns {"ok", "reason", "shots", "from", "tos", "hits"}; tos / hits are every
## ray's end point and hit flag (one batched FX message per request).
static func replay(weapon: Weapon, request: Array, proxy: Node3D, charge_ok: bool) -> Dictionary:
	var result := {"ok": false, "reason": "", "shots": 0}
	var reason := _check(weapon, request, charge_ok)
	if reason != "":
		clear_pending(weapon)
		result.reason = reason
		return result
	var data := weapon.data
	var dirs: PackedVector3Array = request[NetShot.REQ_DIRS]
	var bent: PackedByteArray = request[NetShot.REQ_BENT]
	var charged: bool = request[NetShot.REQ_CHARGED]
	var pellets := pellets_of(data)
	# Arrays, not packed arrays: lambdas capture packed arrays by value.
	var tos: Array[Vector3] = []
	var hits: Array[int] = []
	var collect := func(_from: Vector3, to: Vector3, hit: Dictionary) -> void:
		tos.append(to)
		hits.append(0 if hit.is_empty() else 1)
	var saved_aim := weapon.aim_source
	var saved_alt := weapon.alt_mode
	weapon.aim_source = proxy
	weapon.alt_mode = request[NetShot.REQ_ALT]
	weapon.ray_fired.connect(collect)
	var shots := 1
	var multiplier: Variant = data.get(&"charge_damage_multiplier")
	var scale := float(multiplier) if charged and multiplier != null else 1.0
	if pellets > 1 and &"next_shot_seed" in weapon:
		# One seed + spread per round (a blast); next_shot_seed covers one round only.
		var seeds: PackedInt64Array = request[NetShot.REQ_SEED]
		shots = seeds.size()
		for i in shots:
			_seed(weapon, request, i)
			weapon.call(&"_emit_shots")
	elif charged and _arg_count(weapon, &"_fire_ray") < 2:
		_seed(weapon, request, 0)
		weapon.call(&"_emit_shots", scale)
	else:
		shots = dirs.size()
		for i in dirs.size():
			weapon.set(&"_bent", i < bent.size() and bent[i] != 0)
			if charged:
				weapon.call(&"_fire_ray", dirs[i].normalized(), scale)
			else:
				weapon.call(&"_fire_ray", dirs[i].normalized())
	weapon.ray_fired.disconnect(collect)
	weapon.aim_source = saved_aim
	weapon.alt_mode = saved_alt
	clear_pending(weapon)
	_spend(weapon, shots, charged)
	result.ok = true
	result.shots = shots
	result.from = proxy.global_position
	if tos.is_empty():
		for dir in dirs:
			tos.append(proxy.global_position + dir.normalized() * data.max_range)
			hits.append(0)
	result.tos = PackedVector3Array(tos)
	result.hits = PackedByteArray(hits)
	return result


## Round `index`'s seed and spread (next_shot_seed / next_shot_spread cover one round each).
static func _seed(weapon: Weapon, request: Array, index: int) -> void:
	var seeds: PackedInt64Array = request[NetShot.REQ_SEED]
	var spreads: PackedFloat32Array = request[NetShot.REQ_SPREAD]
	if &"next_shot_seed" in weapon and index < seeds.size():
		weapon.set(&"next_shot_seed", seeds[index])
	if &"next_shot_spread" in weapon and index < spreads.size():
		var bounds := spread_bounds(weapon.data)
		weapon.set(&"next_shot_spread", clampf(spreads[index], bounds.x, bounds.y))


## Why a request is refused ("" = fine). Rate limiting is the caller's (per shooter).
static func _check(weapon: Weapon, request: Array, charge_ok: bool) -> String:
	if weapon == null or weapon.data == null or not NetShot.is_well_formed(request):
		return "malformed"
	if str(request[NetShot.REQ_ID]) != id_of(weapon):
		return "not the active weapon"
	var data := weapon.data
	var dirs: PackedVector3Array = request[NetShot.REQ_DIRS]
	var pellets := pellets_of(data)
	if dirs.is_empty() or dirs.size() > Weapon.MAX_SHOTS_PER_TICK * pellets:
		return "ray count"
	if weapon.reloading:
		return "reloading"
	if weapon.get(&"overheated") == true:
		return "overheated"
	var charged: bool = request[NetShot.REQ_CHARGED]
	if charged and not charge_ok:
		return "not charged"
	if charged and _arg_count(weapon, &"_fire_ray") < 2 and _arg_count(weapon, &"_emit_shots") < 1:
		return "charged shots unsupported"
	var ammo := weapon.magazine if is_battery(data) else weapon.magazine + weapon.reserve
	if ammo <= 0:
		return "no ammo"
	if pellets > 1 and &"next_shot_seed" in weapon:
		var seeds: PackedInt64Array = request[NetShot.REQ_SEED]
		var spreads: PackedFloat32Array = request[NetShot.REQ_SPREAD]
		var too_many := seeds.size() > Weapon.MAX_SHOTS_PER_TICK
		return (
			"round seeds" if seeds.is_empty() or too_many or spreads.size() < seeds.size() else ""
		)
	var quat: Quaternion = request[NetShot.REQ_QUAT]
	var forward := -(Basis(quat.normalized()).z)
	var cone := spread_bounds(data).y + data.aim_bend_angle + DIR_TOLERANCE_DEG
	if pellets > 1:
		cone += float(data.get(&"pellet_spread"))
	for dir in dirs:
		if rad_to_deg(forward.angle_to(dir)) > cone:
			return "ray outside spread cone"
	return ""


## Host ammo bookkeeping for a replayed request (magazine first, then reserve).
static func _spend(weapon: Weapon, shots: int, charged: bool) -> void:
	var cost := shots
	if charged:
		var charge_cost: Variant = weapon.data.get(&"charge_ammo_cost")
		cost = maxi(int(charge_cost), 1) if charge_cost != null else 1
	var from_mag := mini(cost, weapon.magazine)
	weapon.magazine -= from_mag
	if not is_battery(weapon.data):
		weapon.reserve = maxi(weapon.reserve - (cost - from_mag), 0)
	weapon.ammo_changed.emit(weapon.magazine, weapon.reserve)
