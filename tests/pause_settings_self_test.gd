extends SceneTree
## Pause menu Settings page: opens from the pause panel, Esc goes back to the pause panel (not
## back into the match), and slider changes reach the local Player while the match runs.
## Leaves user://settings.cfg as it found it. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/pause_settings_self_test.gd

const CFG := "user://settings.cfg"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var saved_cfg: Variant = null
	if FileAccess.file_exists(CFG):
		saved_cfg = FileAccess.get_file_as_bytes(CFG)
	var settings := root.get_node("Settings")
	var old_mouse: float = settings.mouse_sensitivity_scale
	var old_fov: float = settings.fov
	var old_assist: bool = settings.mouse_aim_assist

	# Loaded at runtime: in --script mode autoloads aren't compile-time identifiers, so the
	# MatchUI / NetMatch class names can't be referenced from this file.
	var player = (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	root.add_child(player)
	var net_match = load("res://scripts/net/net_match.gd").new()
	net_match.local_player = player
	var ui = load("res://scripts/ui/match_ui.gd").new()
	ui.net_match = net_match
	root.add_child(ui)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await process_frame
	await process_frame

	_check(ui._pause.visible, "pause panel shows while the mouse is free")
	_check(not ui._settings.visible, "settings page starts hidden")

	ui._open_settings()
	await process_frame
	_check(ui._settings.visible and not ui._pause.visible, "Settings swaps to the settings page")

	var base_sens: float = player.mouse_sensitivity
	var sliders: Array[Node] = ui._settings.find_children("*", "HSlider", true, false)
	_check(sliders.size() == 3, "three sliders (%d)" % sliders.size())
	(sliders[0] as HSlider).value = 2.0
	_check(
		is_equal_approx(player.mouse_sensitivity, base_sens / old_mouse * 2.0),
		"mouse sensitivity applies live (%f)" % player.mouse_sensitivity
	)
	(sliders[2] as HSlider).value = 100.0
	_check(is_equal_approx(player.fov, 100.0), "FOV applies live (%f)" % player.fov)

	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	await process_frame
	await process_frame
	_check(not ui._settings.visible, "Esc closes the settings page")
	_check(ui._pause.visible, "Esc returns to the pause panel, not the match")
	_check(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED, "mouse still free after Esc")

	settings.mouse_sensitivity_scale = old_mouse
	settings.fov = old_fov
	settings.mouse_aim_assist = old_assist
	if saved_cfg == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))
	else:
		var file := FileAccess.open(CFG, FileAccess.WRITE)
		file.store_buffer(saved_cfg)
		file.close()
	net_match.free()

	if _failed:
		print("PAUSE_SETTINGS_SELF_TEST FAIL")
		quit(1)
		return
	print("PAUSE_SETTINGS_SELF_TEST PASS")
	quit(0)


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failed = true
