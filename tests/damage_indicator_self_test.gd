extends SceneTree
## Pins the damage-indicator angle. travel is shooter -> victim. Angle 0 is in front
## (top of the screen), +PI/2 is the body's right. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/damage_indicator_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var script := load("res://scripts/ui/combat_feedback.gd") as GDScript
	var ident := Basis.IDENTITY
	_check(script, ident, Vector3(0, 0, 1), 0.0, "attacker in front")
	_check(script, ident, Vector3(0, 0, -1), PI, "attacker behind")
	_check(script, ident, Vector3(-1, 0, 0), PI * 0.5, "attacker on the right")
	_check(script, ident, Vector3(1, 0, 0), -PI * 0.5, "attacker on the left")
	var yawed := Basis(Vector3.UP, 0.3)
	var fwd := -yawed.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP)
	_check(script, yawed, -fwd, 0.0, "yawed body, attacker in front")
	_check(script, yawed, -right, PI * 0.5, "yawed body, attacker on the right")
	_check_guns()
	_check_shotgun_cone()
	if _failed:
		quit(1)
		return
	print("DAMAGE_INDICATOR_SELF_TEST PASS")
	quit(0)


func _check(script: GDScript, basis: Basis, travel: Vector3, expected: float, label: String) -> void:
	var angle: float = script.call(&"attacker_screen_angle", basis, travel)
	var err := angle_difference(angle, expected)
	print("%s angle=%.4f expected=%.4f" % [label, angle, expected])
	if absf(err) > 0.02:
		push_error("%s is off by %.4f" % [label, err])
		_failed = true


func _check_guns() -> void:
	var expected := {
		"res://scenes/weapons/standard_issue_rifle.tscn": ["fire_sound"],
		"res://scenes/weapons/marksman_carbine.tscn": ["fire_sound"],
		"res://scenes/weapons/combat_shotgun.tscn": ["fire_sound", "cycle_sound"],
		"res://scenes/weapons/service_pistol.tscn": ["fire_sound"],
		"res://scenes/weapons/directed_energy_rifle.tscn": [
			"fire_sound", "charged_fire_sound", "charge_sound", "overheat_sound"
		],
	}
	for path: String in expected:
		var packed := load(path) as PackedScene
		if packed == null:
			push_error("missing scene %s" % path)
			_failed = true
			continue
		var gun := packed.instantiate()
		var fx := gun.get_node_or_null(^"WeaponFx")
		if fx == null:
			push_error("%s has no WeaponFx" % path)
			_failed = true
			gun.free()
			continue
		for prop: String in expected[path]:
			var stream: Variant = fx.get(prop)
			var seconds := 0.0
			if stream is AudioStream:
				seconds = (stream as AudioStream).get_length()
			print("%s %s length=%.3f" % [path.get_file(), prop, seconds])
			if seconds <= 0.05 or seconds > 2.5:
				push_error("%s %s length %.3f is not a one-shot" % [path, prop, seconds])
				_failed = true
		gun.free()


## Every pellet offset stays inside the live half-angle, and some reach the rim.
func _check_shotgun_cone() -> void:
	var data := load("res://resources/weapons/combat_shotgun.tres")
	var weapon := load("res://scripts/weapons/weapon.gd") as GDScript
	if data == null or weapon == null:
		push_error("shotgun cone resources missing")
		_failed = true
		return
	var spread := float(data.get("pellet_spread"))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var max_deg := 0.0
	for _i in 300:
		var offset: Vector2 = weapon.call(&"_cone_offset", spread, rng)
		var dir := Vector3(offset.x, offset.y, -1.0).normalized()
		var deg := rad_to_deg(acos(clampf(dir.dot(Vector3(0.0, 0.0, -1.0)), -1.0, 1.0)))
		if deg > max_deg:
			max_deg = deg
		if deg > spread + 0.05:
			push_error("pellet %.2f deg is outside the %.2f deg cone" % [deg, spread])
			_failed = true
			return
	print("shotgun cone max=%.2f half-angle=%.2f" % [max_deg, spread])
	if max_deg < spread * 0.75:
		push_error("shotgun cone never reaches the rim (max %.2f of %.2f)" % [max_deg, spread])
		_failed = true
