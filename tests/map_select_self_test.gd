extends SceneTree
## Map select + armor preview smoke test. Checks that every MapList arena loads, that the main
## menu builds (map pickers, 32 swatches, ArmorPreview with a tinted body), and that the
## Headlong arena bakes a navmesh and spawns its bots offline. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/map_select_self_test.gd

const BAKE_TIMEOUT := 90.0

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_maps()
	await _check_menu()
	await _check_arena("lockout")
	await _check_arena("headlong")
	if _failed:
		print("map_select_self_test: FAILED")
		quit(1)
	else:
		print("map_select_self_test: all passed")
		quit(0)


func _check_maps() -> void:
	_expect(MapList.MAPS.size() >= 2, "at least two maps listed")
	for map: Dictionary in MapList.MAPS:
		var scene := load(str(map.arena)) as PackedScene
		_expect(scene != null, "arena loads: %s" % map.arena)
	_expect(MapList.sanitize("nope") == MapList.DEFAULT_ID, "unknown id falls back to default")
	_expect(MapList.arena_of("headlong").ends_with("arena_headlong.tscn"), "headlong arena path")
	_expect(PlayerColor.PRESETS.size() == 32, "32 armor presets")
	_expect(
		PlayerColor.default_color().is_equal_approx(Color(0.290196, 0.313725, 0.223529)),
		"default preset is still Olive"
	)


func _check_menu() -> void:
	var menu := (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	for i in 5:
		await process_frame
	var previews := menu.find_children("*", "SubViewportContainer", true, false)
	_expect(previews.size() == 1, "menu has one ArmorPreview")
	var pickers := menu.find_children("*", "OptionButton", true, false)
	_expect(pickers.size() == 3, "map pickers on Bot Arena, LAN host and lobby (got %d)" % pickers.size())
	for picker: OptionButton in pickers:
		_expect(picker.item_count == MapList.MAPS.size(), "picker lists every map")
	if previews.size() == 1:
		var preview: Node = previews[0]
		var bodies := preview.find_children("PlayerModel", "", true, false)
		_expect(bodies.size() == 1, "preview holds the player body")
		var red: Color = PlayerColor.PRESETS[9].color
		menu.call(&"_set_color", red)
		var settings := root.get_node(^"Settings")
		_expect((settings.get(&"primary_color") as Color).is_equal_approx(red), "swatch colour reaches Settings")
		var cyan: Color = PlayerColor.VISOR_PRESETS[8].color
		menu.call(&"_set_visor", cyan)
		_expect((settings.get(&"visor_color") as Color).is_equal_approx(cyan), "visor colour reaches Settings")
		var model: Node = bodies[0] if bodies.size() == 1 else null
		_expect(model != null and (model.get(&"visor_color") as Color).is_equal_approx(cyan), "preview visor tinted")
	menu.queue_free()
	await process_frame


func _check_arena(map_id: String) -> void:
	var arena := (load(MapList.arena_of(map_id)) as PackedScene).instantiate()
	root.add_child(arena)
	var nav: Node = arena.get_node_or_null(^"Navigation")
	_expect(nav != null, "%s: Navigation present" % map_id)
	var start := Time.get_ticks_msec()
	while nav != null and not nav.get(&"is_baked") and Time.get_ticks_msec() - start < BAKE_TIMEOUT * 1000.0:
		await process_frame
	print("  ..   %s: bake took %.1f s" % [map_id, (Time.get_ticks_msec() - start) / 1000.0])
	_expect(nav != null and nav.get(&"is_baked"), "%s: navmesh baked" % map_id)
	for i in 120:
		await physics_frame
	var spawns: Node = arena.get_node_or_null(^"SpawnManager")
	var bots: Array = spawns.get(&"bots") if spawns != null else []
	_expect(spawns != null and bots.size() == int(spawns.get(&"bot_count")), "%s: bots spawned (%d)" % [map_id, bots.size()])
	var player := arena.get_node_or_null(^"Player") as Node3D
	_expect(player != null and player.global_position.y > -5.0, "%s: player above the kill floor" % map_id)
	arena.queue_free()
	await process_frame


func _expect(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		_failed = true
