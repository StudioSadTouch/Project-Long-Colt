extends SceneTree
## Game mode smoke test. Loads each arena offline in SWAT and checks GameRules: the player and
## every bot carry only the Service Pistol and no shield (also after a respawn), placed power
## weapon pickups (shotgun, DER) are gone while the rest stay, and the HUD has no low-shield
## warning. Then Slayer on Lockout keeps the scene's rifle + pistol, shields and power weapons.
## Only infinite_ammo modes (Weapon Range) refill: an emptied reserve stays empty elsewhere.
## Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/game_rules_self_test.gd

const BAKE_TIMEOUT := 90.0
const PISTOL := "Service Pistol"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_registry()
	await _check_refill_switch()
	await _check_arena("lockout", "swat")
	await _check_arena("headlong", "swat")
	await _check_arena("lockout", "slayer")
	if _failed:
		print("game_rules_self_test: FAILED")
		quit(1)
	else:
		print("game_rules_self_test: all passed")
		quit(0)


func _check_registry() -> void:
	_expect(GameModes.has("swat") and GameModes.has("slayer"), "slayer and swat listed")
	_expect(GameModes.sanitize("nope") == GameModes.DEFAULT_ID, "unknown mode falls back")
	_expect(GameModes.name_of("swat") == "SWAT", "swat display name")
	var shotgun := load("res://scenes/weapons/combat_shotgun.tscn") as PackedScene
	var der := load("res://scenes/weapons/directed_energy_rifle.tscn") as PackedScene
	var rifle := load("res://scenes/weapons/standard_issue_rifle.tscn") as PackedScene
	var carbine := load("res://scenes/weapons/marksman_carbine.tscn") as PackedScene
	var pistol := load("res://scenes/weapons/service_pistol.tscn") as PackedScene
	_expect(GameRules.is_power_weapon(shotgun), "shotgun is a power weapon")
	_expect(GameRules.is_power_weapon(der), "DER is a power weapon")
	for scene: PackedScene in [rifle, carbine, pistol]:
		_expect(not GameRules.is_power_weapon(scene), "%s is not a power weapon" % scene.resource_path)


## The refill loop runs only for infinite_ammo modes, checked after _ready (Godot re-enables
## physics processing there for any script with a _physics_process).
func _check_refill_switch() -> void:
	var arena := Node.new()
	var parent := Node.new()
	arena.add_child(parent)
	root.add_child(arena)
	for id in GameModes.ids():
		var rules := GameRules.create(id)
		parent.add_child(rules)
		await process_frame
		var want := bool(GameModes.get_mode(id).get("infinite_ammo", false))
		_expect(rules.is_physics_processing() == want, "%s: ammo refill %s" % [id, "on" if want else "off"])
		parent.remove_child(rules)
		rules.free()
	arena.queue_free()
	await process_frame


func _check_arena(map_id: String, mode_id: String) -> void:
	var tag := "%s/%s" % [mode_id, map_id]
	var net := root.get_node(^"Net")
	net.set(&"rules_id", mode_id)
	var arena := (load(MapList.arena_of(map_id)) as PackedScene).instantiate()
	root.add_child(arena)
	var nav: Node = arena.get_node_or_null(^"Navigation")
	var start := Time.get_ticks_msec()
	while nav != null and not nav.get(&"is_baked") and Time.get_ticks_msec() - start < BAKE_TIMEOUT * 1000.0:
		await process_frame
	for i in 60:
		await physics_frame
	var swat := mode_id == "swat"

	var player := arena.get_node(^"Player") as Player
	var holder := player.get_weapon_holder()
	var names := _names(holder.get_weapons())
	if swat:
		_expect(names == [PISTOL], "%s: player spawns with pistol only (got %s)" % [tag, names])
	else:
		_expect(names.size() == 2 and names.has(PISTOL), "%s: player keeps two weapons (got %s)" % [tag, names])
	var hs := player.health_shield
	_expect((hs.max_shield == 0.0 and hs.shield == 0.0) == swat, "%s: shields %s" % [tag, "off" if swat else "on"])

	# An emptied reserve stays empty (GameRules refills every 0.5 s in infinite_ammo modes only).
	var held := holder.get_weapons()[0] as Weapon
	held.reserve = 0
	for i in Engine.physics_ticks_per_second:
		await physics_frame
	_expect(held.reserve == 0, "%s: ammo is finite (reserve %d after 1 s)" % [tag, held.reserve])

	var power := 0
	var other := 0
	for pickup: WeaponPickup in arena.find_children("*", "WeaponPickup", true, false):
		if pickup.dropped:
			continue
		if GameRules.is_power_weapon(pickup.weapon_scene):
			power += 1
		else:
			other += 1
	if swat:
		_expect(power == 0, "%s: no power weapon pickups (got %d)" % [tag, power])
	else:
		_expect(power > 0, "%s: power weapon pickups present (%d)" % [tag, power])
	_expect(other > 0, "%s: other pickups kept (%d)" % [tag, other])

	var spawns := arena.get_node(^"SpawnManager") as SpawnManager
	_expect(spawns.bots.size() > 0, "%s: bots spawned (%d)" % [tag, spawns.bots.size()])
	for bot: Bot in spawns.bots:
		var bot_names := _names(bot.slots)
		var ok := bot_names == [PISTOL] if swat else bot_names.size() == 2
		_expect(ok, "%s: %s loadout %s" % [tag, bot.display_name, bot_names])
		_expect((bot.health_shield.shield == 0.0) == swat, "%s: %s shield %.0f" % [tag, bot.display_name, bot.health_shield.shield])

	if swat:
		var hud := player.find_children("*", "HUD", true, false)
		var hud_node: Node = hud[0] if hud.size() > 0 else player.get_node_or_null(^"HUD")
		if hud_node != null:
			_expect(not bool(hud_node.get(&"_low_shield")), "%s: no low-shield warning" % tag)
		# Respawns keep the mode: pistol only, no shield.
		player.respawn_at(player.global_transform)
		_expect(_names(holder.get_weapons()) == [PISTOL], "%s: player respawns with pistol" % tag)
		_expect(player.health_shield.shield == 0.0, "%s: player respawns without shield" % tag)
		if spawns.bots.size() > 0:
			var bot: Bot = spawns.bots[0]
			bot.respawn_at(bot.global_transform)
			_expect(_names(bot.slots) == [PISTOL], "%s: bot respawns with pistol" % tag)
			_expect(bot.health_shield.shield == 0.0, "%s: bot respawns without shield" % tag)
		# A pistol body shot now goes straight to health.
		var before := player.health_shield.health
		player.health_shield.apply_damage(22.0)
		_expect(player.health_shield.health < before, "%s: damage hits health directly" % tag)

	arena.queue_free()
	await process_frame
	await process_frame
	net.set(&"rules_id", GameModes.DEFAULT_ID)


func _names(weapons: Array) -> Array[String]:
	var out: Array[String] = []
	for w: Variant in weapons:
		if is_instance_valid(w) and w.get(&"data") != null:
			out.append(str((w.get(&"data") as WeaponData).display_name))
	return out


func _expect(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		_failed = true
