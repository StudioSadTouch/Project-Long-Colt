extends SceneTree
## Pins the v2 shots-to-kill targets (docs/weapons/roster_balance.md) against the real
## WeaponData resources, Weapon's own zone / falloff code and a real HealthShield (70 / 45).
## Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/ttk_self_test.gd

const BODY := 0
const HELMET := 1
const FACE := 2

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Marksman Carbine: 3 body, 2 when the second is a headshot; 2 body never kills.
	_expect("carbine body", "marksman_carbine", 10.0, [BODY, BODY, BODY, BODY], 3)
	_expect("carbine body x2 survives", "marksman_carbine", 10.0, [BODY, BODY], -1)
	_expect("carbine 2 helmet", "marksman_carbine", 10.0, [HELMET, HELMET], 2)
	_expect("carbine 2 face", "marksman_carbine", 10.0, [FACE, FACE], 2)
	_expect("carbine 2 helmet at 55 m", "marksman_carbine", 55.0, [HELMET, HELMET], 2)
	_expect("carbine bare-health body no one-shot", "marksman_carbine", 10.0, [BODY], -1, true)
	# Combat Shotgun: 2 full blasts; 8 pellets still strip, 5 still finish.
	_expect("shotgun 2 blasts", "combat_shotgun", 3.0, [BODY, BODY, BODY], 2, false, 10)
	_expect("shotgun 8 then 5 pellets", "combat_shotgun", 3.0, [BODY, BODY], 2, false, [8, 5])
	_expect("shotgun 1 blast survives", "combat_shotgun", 3.0, [BODY], -1, false, 10)
	# Rocket launcher (the old DER slot): a projectile, so no hitscan TTK here; its blast is
	# pinned by tests/rocket_self_test.gd.
	_check_launcher()
	# Service Pistol: 7 body.
	_expect("pistol body", "service_pistol", 10.0, [BODY, BODY, BODY, BODY, BODY, BODY, BODY, BODY], 7)
	# Standard Issue Rifle (BURST, 3 rounds): 5 bursts body, 4 with the 4th burst on the helmet.
	var body_bursts: Array = []
	var head_bursts: Array = []
	for b in 6:
		for r in 3:
			body_bursts.append(BODY)
			head_bursts.append(HELMET if b == 3 else BODY)
	_expect_bursts("rifle 5 bursts body", body_bursts, 5)
	_expect_bursts("rifle 4 bursts, last on helmet", head_bursts, 4)
	if _failed:
		print("TTK_SELF_TEST FAIL")
		quit(1)
		return
	print("TTK_SELF_TEST PASS")
	quit(0)


## pellets: null = 1 per shot; int = that many on every shot; Array = per shot.
## Returns the 1-based shot that killed, or -1.
func _shots_to_kill(
	gun: String, distance: float, zones: Array, bare: bool = false, pellets: Variant = null
) -> int:
	var data := load("res://resources/weapons/%s.tres" % gun) as WeaponData
	var weapon := (load("res://scripts/weapons/weapon.gd") as GDScript).new() as Node
	weapon.set(&"data", data)
	var hs := HealthShield.new()
	hs.reset()
	if bare:
		hs.shield = 0.0
	var killed := -1
	for i in zones.size():
		var count := 1
		if pellets is int:
			count = pellets
		elif pellets is Array:
			count = int(pellets[i])
		var info := {}
		weapon.call(&"_set_zone", info, zones[i])
		info["shield_multiplier"] = data.shield_damage_multiplier
		info["bleedthrough"] = data.bleedthrough
		var amount: float = data.damage * float(weapon.call(&"_falloff", distance)) * count
		if hs.apply_damage(amount, info).killed:
			killed = i + 1
			break
	weapon.free()
	hs.free()
	return killed


func _expect(
	label: String,
	gun: String,
	distance: float,
	zones: Array,
	want: int,
	bare: bool = false,
	pellets: Variant = null
) -> void:
	var got := _shots_to_kill(gun, distance, zones, bare, pellets)
	_report(label, got, want)


func _expect_bursts(label: String, zones: Array, want_bursts: int) -> void:
	var bullet := _shots_to_kill("standard_issue_rifle", 10.0, zones)
	var got := -1 if bullet < 0 else int(ceil(bullet / 3.0))
	_report(label, got, want_bursts)


func _check_launcher() -> void:
	var data := load("res://resources/weapons/directed_energy_rifle.tres") as WeaponData
	_report("launcher is semi-auto", data.fire_mode, WeaponData.FireMode.SEMI)
	_report("launcher fires projectiles", int(data.projectile_speed > 0.0 and data.blast != null), 1)
	_report("launcher has no fire select", int(data.fire_select), 0)
	_report("launcher has no heat", int(data.heat_per_shot > 0.0), 0)
	# Full blast one-shots (70 shield + 45 health = 115), the old one-shot beam is gone.
	_report("launcher blast one-shots", int(data.blast.damage >= 115.0), 1)


func _report(label: String, got: int, want: int) -> void:
	var ok := got == want
	print("%s %s: got %d, want %d" % ["PASS" if ok else "FAIL", label, got, want])
	if not ok:
		_failed = true
