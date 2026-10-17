extends SceneTree
## Pins gait-clock foot plants and checks the foley clips are short one-shots. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/footstep_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var script := load("res://scripts/characters/character_anim_driver.gd") as GDScript
	_expect(script, 0.2, 0.4, 0.6, true, "crosses the half-cycle plant")
	_expect(script, 0.29, 0.31, 0.6, true, "crosses half from just before it")
	_expect(script, 0.4, 0.55, 0.6, false, "already past half")
	_expect(script, 0.3, 0.45, 0.6, false, "starts on the half plant")
	_expect(script, 0.1, 0.2, 0.6, false, "between plants")
	_expect(script, 0.55, 0.05, 0.6, true, "wrap crosses the cycle start")
	_expect(script, 0.2, 0.2, 0.6, false, "no advance")
	_check_clip("res://assets/audio/foley/step_0.wav", 0.05, 0.2)
	_check_clip("res://assets/audio/foley/step_1.wav", 0.05, 0.2)
	_check_clip("res://assets/audio/foley/step_2.wav", 0.05, 0.2)
	_check_clip("res://assets/audio/foley/step_3.wav", 0.05, 0.2)
	_check_clip("res://assets/audio/foley/step_4.wav", 0.05, 0.2)
	_check_clip("res://assets/audio/foley/step_5.wav", 0.05, 0.2)
	_check_clip("res://assets/audio/foley/land.wav", 0.08, 0.4)
	_check_clip("res://assets/audio/feedback/shield_hit.wav", 0.12, 0.4)
	_check_clip("res://assets/audio/feedback/health_hit.wav", 0.12, 0.45)
	_check_clip("res://assets/audio/feedback/death.wav", 0.3, 0.9)
	if _failed:
		quit(1)
		return
	print("FOOTSTEP_SELF_TEST PASS")
	quit(0)


func _expect(
	script: GDScript, previous: float, now: float, cycle: float, expected: bool, label: String
) -> void:
	var hit: bool = script.call(&"foot_crossed", previous, now, cycle)
	print("%s -> %s" % [label, hit])
	if hit != expected:
		push_error("%s: got %s, expected %s" % [label, hit, expected])
		_failed = true


func _check_clip(path: String, short: float, long: float) -> void:
	var stream := load(path) as AudioStream
	var seconds := stream.get_length() if stream != null else 0.0
	print("%s length=%.3f" % [path.get_file(), seconds])
	if seconds < short or seconds > long:
		push_error("%s length %.3f is outside %.2f..%.2f" % [path, seconds, short, long])
		_failed = true
