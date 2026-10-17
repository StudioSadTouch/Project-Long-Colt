extends SceneTree
## The combat HUD names your side under the shield meter in team modes, and stays blank in
## free-for-all. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/hud_team_self_test.gd

const PLAYER := preload("res://scenes/player/player.tscn")

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var player := PLAYER.instantiate() as Player
	player.auto_respawn = false
	world.add_child(player)
	var label := player.get_node(^"HUD/Team") as Label
	await process_frame
	_check(not label.visible, "free-for-all hides the team line")
	player.set_meta(&"team", GameMode.TEAM_RED)
	await process_frame
	_check(label.visible and label.text == "RED TEAM", "red team reads RED TEAM (%s)" % label.text)
	var red := label.get_theme_color(&"font_color")
	player.set_meta(&"team", GameMode.TEAM_BLUE)
	await process_frame
	_check(label.visible and label.text == "BLUE TEAM", "blue team reads BLUE TEAM (%s)" % label.text)
	var blue := label.get_theme_color(&"font_color")
	_check(red.r > red.b and blue.b > blue.r, "the line is tinted for the side")
	player.set_meta(&"team", 0)
	await process_frame
	_check(not label.visible, "clearing the team hides the line again")
	if _failed:
		print("HUD_TEAM_SELF_TEST FAIL")
		quit(1)
		return
	print("HUD_TEAM_SELF_TEST PASS")
	quit(0)


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failed = true
