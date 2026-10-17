extends SceneTree
## Map select + armor preview smoke test. Checks that every MapList arena loads, that the main
## menu builds (map, player-count and mode pickers, 32 swatches, ArmorPreview with a tinted
## body), and that every arena bakes a navmesh and spawns its bots offline. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/map_select_self_test.gd

const BAKE_TIMEOUT := 90.0

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_maps()
	await _check_menu()
	for map: Dictionary in MapList.MAPS:
		await _check_arena(str(map.id))
	if _failed:
		print("map_select_self_test: FAILED")
		quit(1)
	else:
		print("map_select_self_test: all passed")
		quit(0)


func _check_maps() -> void:
	_expect(MapList.MAPS.size() >= 5, "lockout, headlong, ivory tower, zanzibar, kamino")
	for map: Dictionary in MapList.MAPS:
		var scene := load(str(map.arena)) as PackedScene
		_expect(scene != null, "arena loads: %s" % map.arena)
	_expect(MapList.sanitize("nope") == MapList.DEFAULT_ID, "unknown id falls back to default")
	_expect(MapList.arena_of("headlong").ends_with("arena_headlong.tscn"), "headlong arena path")
	_expect(MapList.arena_of("ivory_tower").ends_with("arena_ivory_tower.tscn"), "ivory tower arena path")
	_expect(MapList.arena_of("zanzibar").ends_with("arena_zanzibar.tscn"), "zanzibar arena path")
	_expect(MapList.arena_of("kamino").ends_with("arena_kamino.tscn"), "kamino arena path")
	_expect(PlayerColor.PRESETS.size() == 32, "32 armor presets")
	_expect(
		PlayerColor.default_color().is_equal_approx(Color(0.290196, 0.313725, 0.223529)),
		"default preset is still Olive"
	)


func _check_menu() -> void:
	var settings := root.get_node(^"Settings")
	var net := root.get_node(^"Net")
	# In memory only. The pickers read these at build; this test must not save over user://.
	settings.set(&"mode_id", "ffa")
	settings.set(&"bot_count", GameMode.MAX_PLAYERS_ANY - 1)
	net.set(&"mode_id", "ffa")
	var menu := (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	for i in 5:
		await process_frame
	var previews := menu.find_children("*", "SubViewportContainer", true, false)
	_expect(previews.size() == 1, "menu has one ArmorPreview")
	var pickers := menu.find_children("MapPicker*", "OptionButton", true, false)
	_expect(pickers.size() == 3, "map pickers on Bot Arena, LAN host and lobby (got %d)" % pickers.size())
	for picker: OptionButton in pickers:
		_expect(picker.item_count == MapList.all_maps().size(), "picker lists every map (custom levels too)")
	var players := menu.find_children("PlayersPicker*", "OptionButton", true, false)
	_expect(players.size() == 3, "player-count pickers (got %d)" % players.size())
	for picker: OptionButton in players:
		_expect(picker.item_count == GameMode.MODES.size(), "picker lists every player count")
		_expect(picker.get_item_text(0).contains("(8)"), "FFA shows its player count")
		_expect(
			picker.get_item_text(1).contains("4V4") and picker.get_item_text(1).contains("(8)"),
			"4v4 is listed at 8 players"
		)
		_expect(picker.get_item_text(2).contains("(16)"), "8v8 stays 16 players")
	var bot_pickers := menu.find_children("BotsPicker*", "OptionButton", true, false)
	_expect(bot_pickers.size() == 3, "bot-count pickers (got %d)" % bot_pickers.size())
	for picker: OptionButton in bot_pickers:
		_expect(picker.item_count == 8, "FFA bot picker is 0 through 7 (got %d)" % picker.item_count)
		_expect(picker.selected == 7, "a full roster shows as 7 bots in FFA")
		_expect(picker.get_item_text(0) == "0 BOTS", "zero bots is selectable")
		_expect(picker.get_item_text(1) == "1 BOT", "one bot is singular")
	_expect(
		int(settings.get(&"bot_count")) == GameMode.MAX_PLAYERS_ANY - 1,
		"showing 7 bots in FFA does not lower the saved count"
	)
	settings.set(&"mode_id", "team_slayer")
	menu.call(&"_sync_bots_pickers")
	_expect(bot_pickers[0].item_count == 16, "8v8 bot picker is 0 through 15")
	_expect(bot_pickers[0].selected == 15, "8v8 shows the saved full count")
	_expect(
		int(settings.get(&"bot_count")) == GameMode.MAX_PLAYERS_ANY - 1,
		"switching player count keeps the saved bot count"
	)
	settings.set(&"mode_id", "team_4v4")
	menu.call(&"_sync_bots_pickers")
	_expect(bot_pickers[1].item_count == 8 and bot_pickers[1].selected == 7, "4v4 bot picker clamps the shown row")
	var modes := menu.find_children("ModePicker*", "OptionButton", true, false)
	_expect(modes.size() == 3, "mode pickers (got %d)" % modes.size())
	# Bot Arena lists every mode; the LAN host and lobby leave out offline-only ones (Horde).
	var counts: Array[int] = []
	for picker: OptionButton in modes:
		counts.append(picker.item_count)
	counts.sort()
	var lan := GameModes.ids(true).size()
	_expect(counts == [lan, lan, GameModes.MODES.size()], "Bot Arena lists every mode, LAN the online ones (%s)" % [counts])
	if previews.size() == 1:
		var preview: Node = previews[0]
		var bodies := preview.find_children("PlayerModel", "", true, false)
		_expect(bodies.size() == 1, "preview holds the player body")
		var red: Color = PlayerColor.PRESETS[9].color
		menu.call(&"_set_color", red)
		_expect((settings.get(&"primary_color") as Color).is_equal_approx(red), "swatch colour reaches Settings")
		var cyan: Color = PlayerColor.VISOR_PRESETS[8].color
		menu.call(&"_set_visor", cyan)
		_expect((settings.get(&"visor_color") as Color).is_equal_approx(cyan), "visor colour reaches Settings")
		var model: Node = bodies[0] if bodies.size() == 1 else null
		_expect(model != null and (model.get(&"visor_color") as Color).is_equal_approx(cyan), "preview visor tinted")
		var gold: Color = PlayerColor.PRESETS[14].color
		menu.call(&"_set_accent", gold)
		_expect((settings.get(&"accent_color") as Color).is_equal_approx(gold), "shoulder colour reaches Settings")
		_expect(model != null and (model.get(&"accent_color") as Color).is_equal_approx(gold), "preview shoulder tinted")
		var tabs := menu.find_children("*", "Button", true, false).filter(
			func(b: Button) -> bool: return b.text == "SHOULDER"
		)
		_expect(tabs.size() == 1, "SHOULDER colour tab")
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
