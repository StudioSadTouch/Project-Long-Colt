class_name NetHost
extends RefCounted
## Host-side checks for client-owned bodies (NetMatch delegates here): movement budget, input
## mirroring (slot, zoom, reload, weapon state), shot replay with lag compensation, melee
## cooldown and loadout / ammo change detection. One `remote` record per client peer.

## Movement budget (token buckets, m/s and m). Falling is free; GravLift rises at 12 m/s.
const MOVE_SPEED := 14.0
const MOVE_BURST := 3.0
const RISE_SPEED := 16.0
const RISE_BURST := 2.5
const MOVE_SLACK := 0.05
## Client state flags.
const FLAG_CROUCH := 1
const FLAG_RELOADING := 2
const FLAG_ZOOMED := 4

var lag := NetLag.new()
var proxy: Node3D
## peer -> {seq, time, h, v, rate, rate_time, peak, melee, sig, reserves}
var remote: Dictionary = {}


func _init(aim_proxy: Node3D) -> void:
	proxy = aim_proxy


func add_client(peer: int) -> void:
	remote[peer] = {
		"seq": 0,
		"time": 0.0,
		"h": MOVE_BURST,
		"v": RISE_BURST,
		"rate": 0.0,
		"rate_time": 0.0,
		"peak": 0.0,
		"melee": 0.0,
		"sig": "",
		"reserves": {},
	}


func has_client(peer: int) -> bool:
	return remote.has(peer)


## A host teleport (respawn): newer seq, fresh movement budget, loadout re-sent. Returns seq.
func on_respawn(peer: int) -> int:
	var r: Dictionary = remote[peer]
	r.seq = int(r.seq) + 1
	r.time = 0.0
	r.h = MOVE_BURST
	r.v = RISE_BURST
	r.sig = ""
	return r.seq


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Validates a client's claimed position against the budget and poses the puppet. Returns the
## position the host accepted; it differs from pos when the client must be corrected.
func accept_state(
	peer: int, puppet: Player, pos: Vector3, yaw: float, pitch: float, flags: int
) -> Vector3:
	var r: Dictionary = remote[peer]
	var now := _now()
	var dt := clampf(now - float(r.time), 0.0, 0.5) if float(r.time) > 0.0 else 0.0
	r.time = now
	r.h = minf(float(r.h) + MOVE_SPEED * dt, MOVE_BURST)
	r.v = minf(float(r.v) + RISE_SPEED * dt, RISE_BURST)
	var from := puppet.global_position
	var move := pos - from
	var flat := Vector3(move.x, 0.0, move.z)
	var allowed := pos
	if flat.length() > float(r.h) + MOVE_SLACK or move.y > float(r.v) + MOVE_SLACK:
		flat = flat.limit_length(float(r.h))
		move.y = minf(move.y, float(r.v))
		allowed = from + flat + Vector3.UP * move.y
	r.h = maxf(float(r.h) - flat.length(), 0.0)
	r.v = maxf(float(r.v) - maxf(move.y, 0.0), 0.0)
	if dt > 0.0:
		puppet.velocity = (allowed - from) / dt
	puppet.apply_net_pose(allowed, yaw, pitch, (flags & FLAG_CROUCH) != 0)
	return allowed


## Mirrors the client's weapon slot, zoom, reload start and heat / charge onto the puppet.
func accept_inputs(
	peer: int, puppet: Player, flags: int, slot: int, wstate: PackedFloat32Array
) -> void:
	var holder := puppet.get_weapon_holder()
	if holder != null:
		holder.select_slot(slot)
	var weapon := puppet.get_active_weapon()
	if weapon == null:
		return
	weapon.set_zoom((flags & FLAG_ZOOMED) != 0)
	if (flags & FLAG_RELOADING) != 0 and not weapon.reloading:
		weapon.reload()
	NetWeapon.apply_state(weapon, wstate)
	if wstate.size() == NetWeapon.STATE_KEYS.size():
		remote[peer].peak = maxf(float(remote[peer].peak), wstate[4])


## Rate-limits, rewinds and replays one fire request. Returns NetWeapon.replay's result
## ({"ok": false} when refused).
func fire(peer: int, puppet: Player, render_tick: int, request: Array) -> Dictionary:
	var refused := {"ok": false}
	var r: Dictionary = remote[peer]
	var weapon := puppet.get_active_weapon()
	if weapon == null or weapon.data == null or request.size() != NetShot.REQ_SIZE:
		NetWeapon.clear_pending(weapon)
		return refused
	var origin: Vector3 = request[NetShot.REQ_ORIGIN]
	if origin.distance_to(puppet.camera.global_position) > NetWeapon.ORIGIN_TOLERANCE:
		NetWeapon.clear_pending(weapon)
		return refused
	var now := _now()
	var since := now - float(r.rate_time) if float(r.rate_time) > 0.0 else 1000.0
	var burst := NetWeapon.rate_burst(weapon.data)
	r.rate = minf(float(r.rate) + since * NetWeapon.max_rate(weapon.data), burst)
	r.rate_time = now
	if float(r.rate) < 0.999:
		NetWeapon.clear_pending(weapon)
		return refused
	var quat: Quaternion = request[NetShot.REQ_QUAT]
	proxy.global_transform = Transform3D(Basis(quat.normalized()), origin)
	weapon.hit_mask_override = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
	lag.rewind(render_tick, puppet)
	var result := NetWeapon.replay(weapon, request, proxy, float(r.peak) >= 1.0)
	lag.restore()
	if result.ok:
		if request[NetShot.REQ_CHARGED]:
			r.peak = 0.0
		r.rate = maxf(float(r.rate) - float(result.shots), 0.0)
	return result


## Melee on the puppet's weapon (aimed by its synced camera) if off cooldown.
func melee(peer: int, puppet: Player) -> void:
	var weapon := puppet.get_active_weapon()
	var now := _now()
	if weapon == null or weapon.data == null:
		return
	if now - float(remote[peer].melee) < weapon.data.melee_cooldown * 0.8:
		return
	remote[peer].melee = now
	weapon.hit_mask_override = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
	weapon.melee()


## Loadout / ammo changes the host made to a client's puppet (pickups, crates, respawn).
## Returns {"loadout": [entries, active]} when the weapon set changed, else {"ammo": [[id, n]]}
## for reserve the host added.
func poll_loadout(peer: int, puppet: Player) -> Dictionary:
	var holder := puppet.get_weapon_holder()
	if holder == null or puppet.dead:
		return {}
	var r: Dictionary = remote[peer]
	var ids: Array[String] = []
	var entries: Array = []
	for weapon in holder.slots:
		var tag := NetWeapon.id_of(weapon) if weapon != null else ""
		# Instance ids too: a battery swap keeps the weapon id but installs another instance.
		if weapon != null:
			tag += "#%d" % weapon.get_instance_id()
		ids.append(tag)
		if weapon == null:
			entries.append({})
			continue
		(
			entries
			. append(
				{
					"id": NetWeapon.id_of(weapon),
					"scene": weapon.scene_file_path,
					"magazine": weapon.magazine,
					"reserve": weapon.reserve,
					"heat_state": NetWeapon.heat_entry(weapon),
				}
			)
		)
	var sig := ",".join(ids)
	var reserves: Dictionary = r.reserves
	var out := {}
	if sig != str(r.sig):
		out["loadout"] = [entries, holder.active_index]
		reserves.clear()
	else:
		var gains: Array = []
		for weapon in holder.slots:
			if weapon == null:
				continue
			var id := NetWeapon.id_of(weapon)
			var gained := weapon.reserve - int(reserves.get(id, weapon.reserve))
			if gained > 0:
				gains.append([id, gained])
		if not gains.is_empty():
			out["ammo"] = gains
	r.sig = sig
	for weapon in holder.slots:
		if weapon != null:
			reserves[NetWeapon.id_of(weapon)] = weapon.reserve
	return out
