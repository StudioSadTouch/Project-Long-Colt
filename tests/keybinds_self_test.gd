extends SceneTree
## Keybinds: binding, conflict removal, controller events kept, save / load round trip and reset.
## Never writes user://settings.cfg. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/keybinds_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	Keybinds.capture_defaults()
	Keybinds.reset_all()
	var key_f := "key:%d" % KEY_F
	var key_g := "key:%d" % KEY_G
	_check(Keybinds.get_codes("action_fire_select")[0] == key_f, "fire select defaults to F")
	var pads_before := _pad_count("action_jump")

	var taken := Keybinds.bind("action_jump", 0, key_f)
	_check(Keybinds.get_codes("action_jump")[0] == key_f, "jump rebound to F")
	_check(taken == ["Fire select"], "F taken from fire select (%s)" % [taken])
	_check(Keybinds.get_codes("action_fire_select") == ["", ""], "fire select now unbound")
	_check(_pad_count("action_jump") == pads_before, "jump keeps its controller binding")

	Keybinds.bind("action_jump", 1, "mouse:%d" % MOUSE_BUTTON_XBUTTON1)
	_check(Keybinds.get_codes("action_jump")[1] == "mouse:8", "mouse 4 as secondary jump")
	_check(Keybinds.code_label("mouse:8") == "Mouse 4", "mouse 4 label")

	var saved := Keybinds.overrides()
	_check(saved.has("action_jump") and saved.has("action_fire_select"), "overrides list changes")
	_check(not saved.has("action_fire"), "unchanged actions are not saved")

	Keybinds.reset_all()
	_check(Keybinds.get_codes("action_fire_select")[0] == key_f, "reset restores fire select")
	_check(Keybinds.overrides().is_empty(), "no overrides after reset")

	Keybinds.apply(saved)
	_check(Keybinds.get_codes("action_jump")[0] == key_f, "apply restores saved jump")
	_check(Keybinds.get_codes("action_fire_select")[0] == "", "apply restores cleared slot")

	Keybinds.bind("action_reload", 0, "")
	_check(Keybinds.get_codes("action_reload") == ["", ""], "clearing a slot unbinds it")
	Keybinds.bind("action_reload", 0, key_g)
	var press := InputEventKey.new()
	press.physical_keycode = KEY_G
	press.pressed = true
	_check(press.is_action_pressed(&"action_reload"), "a physical G press now reloads")

	Keybinds.reset_all()
	if _failed:
		print("KEYBINDS_SELF_TEST FAIL")
		quit(1)
		return
	print("KEYBINDS_SELF_TEST PASS")
	quit(0)


func _pad_count(action: String) -> int:
	var n := 0
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			n += 1
	return n


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failed = true
