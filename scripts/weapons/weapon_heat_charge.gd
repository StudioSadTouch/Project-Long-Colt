class_name WeaponHeatCharge
extends RefCounted
## Heat / overheat, battery drain and the FireMode.CHARGE state machine for one Weapon
## (Weapon.heat_charge, created in Weapon._init). The public state (Weapon.heat, overheated,
## charging, charge) and the signals (heat_changed, charge_started, charge_released) stay on
## Weapon; this object owns the timers and the transitions. All of it is off unless the
## WeaponData asks for it (heat_per_shot > 0, FireMode.CHARGE).
## Netcode: get_net_state() / apply_net_state(state). A correction during a vent also sets
## vent_left (given, or derived from heat), so the next vent tick doesn't overwrite it.

## Seconds of overheat lockout left (heat = vent_left / overheat_vent_time while venting).
var vent_left: float = 0.0
## Seconds since the last shot (cooling starts after data.heat_cooldown_delay).
var since_shot: float = 0.0
## Seconds the current charge has been held.
var charge_held: float = 0.0
var charge_drain_carry: float = 0.0
## Set by a press; the charge starts once the gun is ready, while the trigger stays down.
var charge_armed: bool = false

var _w: Weapon


func _init(weapon: Weapon) -> void:
	_w = weapon


func tick_heat(delta: float) -> void:
	var data := _w.data
	if data.heat_per_shot <= 0.0:
		return
	if _w.overheated:
		vent_left -= delta
		_w.heat = clampf(vent_left / maxf(data.overheat_vent_time, 0.001), 0.0, 1.0)
		if vent_left <= 0.0:
			_w.overheated = false
			_w.heat = 0.0
		_w.heat_changed.emit(_w.heat, _w.overheated)
		return
	if _w.heat <= 0.0:
		return
	since_shot += delta
	if since_shot >= data.heat_cooldown_delay:
		_w.heat = maxf(_w.heat - data.heat_cooldown_rate * delta, 0.0)
		_w.heat_changed.emit(_w.heat, _w.overheated)


func add_heat(amount: float) -> void:
	var data := _w.data
	if data.heat_per_shot <= 0.0 or amount <= 0.0:
		return
	since_shot = 0.0
	_w.heat = minf(_w.heat + amount, 1.0)
	if _w.heat >= 1.0:
		_w.overheated = true
		vent_left = data.overheat_vent_time
		_w._burst_left = 0
		_w._trigger_buffer_left = 0.0
		_w.set_zoom(false)
	_w.heat_changed.emit(_w.heat, _w.overheated)


## Weapon.trigger in FireMode.CHARGE.
func trigger(pressed: bool, held: bool) -> void:
	if pressed:
		charge_armed = true
	if held and charge_armed and not _w.charging:
		_begin()


func _begin() -> void:
	if _w.reloading or not _w._can_fire():
		return
	if _w.magazine <= 0:
		charge_armed = false
		_w.dry_fired.emit()
		return
	_w.charging = true
	charge_held = 0.0
	charge_drain_carry = 0.0
	_w.charge_started.emit()


func tick_charge(delta: float) -> void:
	var data := _w.data
	if _w.reloading:
		release(false)
		return
	charge_held += delta
	_w.charge = clampf(charge_held / maxf(data.charge_time, 0.001), 0.0, 1.0)
	if charge_held < data.charge_time or data.charge_hold_drain <= 0.0:
		return
	# A held full charge bleeds the battery and fires itself before running dry.
	charge_drain_carry += data.charge_hold_drain * delta
	var drained := int(charge_drain_carry)
	if drained <= 0:
		return
	charge_drain_carry -= drained
	if drained >= _w.magazine:
		charge_armed = false
		fire_charged()
		return
	_w.magazine -= drained
	_w.ammo_changed.emit(_w.magazine, _w.reserve)


## Trigger up: a full charge fires the charged shot, a short hold one tap shot (Weapon._try_fire,
## so it obeys fire_rate). fire = false drops the charge unfired (holster, melee, mode switch,
## lost target).
func release(fire: bool = true) -> void:
	charge_armed = false
	if not _w.charging:
		return
	if fire and charge_held >= _w.data.charge_time:
		fire_charged()
		return
	_w.charging = false
	_w.charge = 0.0
	_w.charge_released.emit(false)
	if fire:
		_w._try_fire()


## The one path for charged shots: Weapon._emit_shots(charge_damage_multiplier), seeded like
## every shot; costs charge_ammo_cost, adds charge_heat. Refused while reloading.
func fire_charged() -> void:
	var data := _w.data
	_w.charging = false
	_w.charge = 0.0
	if _w.reloading or _w.magazine <= 0 or _w._aim() == null:
		_w.charge_released.emit(false)
		return
	_w.magazine -= mini(maxi(data.charge_ammo_cost, 1), _w.magazine)
	_w._cooldown = maxf(_w._cooldown, 0.0) + 1.0 / data.fire_rate
	_w._emit_shots(data.charge_damage_multiplier)
	add_heat(data.charge_heat)
	_w._bloom = minf(_w._bloom + data.bloom_per_shot, data.spread_max - data.spread_base)
	_w._kick()
	_w.fired.emit()
	_w.charge_released.emit(true)
	_w.ammo_changed.emit(_w.magazine, _w.reserve)


func get_net_state() -> Dictionary:
	return {
		"heat": _w.heat,
		"overheated": _w.overheated,
		"vent_left": vent_left,
		"since_shot": since_shot,
		"charging": _w.charging,
		"charge_held": charge_held,
	}


## Applies any subset of get_net_state()'s keys. Overheated without vent_left derives it from
## heat, so the vent continues from the corrected value.
func apply_net_state(state: Dictionary) -> void:
	var data := _w.data
	_w.heat = clampf(float(state.get("heat", _w.heat)), 0.0, 1.0)
	_w.overheated = bool(state.get("overheated", _w.overheated))
	since_shot = float(state.get("since_shot", since_shot))
	if _w.overheated:
		var derived := _w.heat * (data.overheat_vent_time if data != null else 0.0)
		vent_left = float(state.get("vent_left", derived))
	else:
		vent_left = 0.0
	if state.has("charging") and not bool(state.charging) and _w.charging:
		release(false)
	charge_held = float(state.get("charge_held", charge_held))
	if _w.charging and data != null:
		_w.charge = clampf(charge_held / maxf(data.charge_time, 0.001), 0.0, 1.0)
	_w.heat_changed.emit(_w.heat, _w.overheated)
