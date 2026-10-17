extends SceneTree
## Weapon Range (map + rules) offline: registered, no bots, kills don't end it, every weapon on
## the rack and pickable, dummies down range, spawns clear of geometry, the navmesh bakes,
## and ammo refills (reserve, the hammer's battery, grenades). Settings changed in memory only.
## Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/range_self_test.gd

const ARENA := "res://scenes/main/arena_range.tscn"
const RACK := [
	"StandardIssueRifle", "ServicePistol", "MarksmanCarbine", "CombatShotgun",
	"DirectedEnergyRifle", "Longsword", "GravityHammer",
	# The New Ottoman rack (the enemies' issue weapons).
	"Tufek", "LongRifle", "GlaiveRifle", "RaiderCarbine", "HumbaraLauncher", "Kilij", "Yatagan"
]

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(MapList.has("range"), "the Weapon Range map is registered")
	_expect(GameModes.has("range") and not GameModes.allows_bots("range"), "Weapon Range rules: no bots")
	_expect(not GameModes.keeps_score("range"), "Weapon Range rules: no score limit")
	var net := root.get_node("Net")
	net.set(&"rules_id", "range")
	net.set(&"mode_id", "ffa")
	net.set(&"map_id", "range")
	net.set(&"match_running", true)
	root.get_node("Settings").set(&"bot_count", 7)  # the rules must override this
	var arena := (load(ARENA) as PackedScene).instantiate()
	root.add_child(arena)
	var nav := arena.get_node("Navigation") as ArenaNavigation
	for i in 600:
		await physics_frame
		if nav.is_baked:
			break
	_expect(nav.is_baked, "the navmesh bakes")
	await _frames(60)
	var spawns := arena.get_node("SpawnManager") as SpawnManager
	_expect(spawns.bots.is_empty() and get_nodes_in_group(&"bot").is_empty(), "no bots (%d)" % spawns.bots.size())
	_expect(not spawns.kill_win, "kills never end the match")
	# Spawns stand clear of geometry (a player capsule fits at each).
	var space := arena.get_viewport().world_3d.direct_space_state
	var capsule := CapsuleShape3D.new()
	capsule.radius = Player.CAPSULE_RADIUS
	capsule.height = Player.STAND_HEIGHT - 0.1
	var blocked := 0
	for marker in arena.get_node("Range/Spawns").get_children():
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = capsule
		q.collision_mask = 1
		q.transform = Transform3D(Basis.IDENTITY, (marker as Node3D).global_position + Vector3.UP * 1.1)
		if not space.intersect_shape(q, 1).is_empty():
			blocked += 1
	_expect(blocked == 0, "spawns are clear (%d blocked)" % blocked)
	var dummies := 0
	for child in arena.get_children():
		if child is TargetDummy or child is MovingDummy:
			dummies += 1
	_expect(dummies >= 15, "dummies placed (%d)" % dummies)
	# Every weapon on the rack, and the player can take each.
	var player := arena.get_node("Player") as Player
	var holder := player.get_weapon_holder()
	var taken: Array[String] = []
	for weapon_name in RACK:
		var pickup := arena.get_node_or_null("%s_Rack" % weapon_name) as WeaponPickup
		if pickup == null:
			continue
		player.global_position = pickup.global_position + Vector3(0, 0, 1.2)
		await _frames(3)
		if holder.take_pickup(pickup):
			taken.append(weapon_name)
		await _frames(2)
	_expect(taken.size() == RACK.size(), "every weapon on the rack can be taken (%s)" % [taken])
	# Infinite ammo: empty the active gun's reserve and the hammer's battery; both come back.
	holder.give_weapon((load("res://scenes/weapons/standard_issue_rifle.tscn") as PackedScene).instantiate(), 0)
	holder.give_weapon((load("res://scenes/weapons/gravity_hammer.tscn") as PackedScene).instantiate(), 1)
	await _frames(5)
	var rifle := holder.slots[0]
	var hammer := holder.slots[1]
	rifle.reserve = 0
	hammer.magazine = 0
	var grenades := player.get_node("GrenadeThrower") as GrenadeThrower
	for i in grenades.counts.size():
		grenades.counts[i] = 0
	await _frames(45)
	_expect(rifle.reserve == rifle.data.reserve_max, "rifle reserve refills (%d)" % rifle.reserve)
	_expect(hammer.magazine == hammer.data.magazine_size, "hammer battery recharges (%d)" % hammer.magazine)
	_expect(grenades.counts.min() > 0, "grenades top up (%s)" % [grenades.counts])
	net.set(&"match_running", false)
	arena.queue_free()
	await _frames(3)
	if _failed:
		print("RANGE_SELF_TEST FAIL")
		quit(1)
		return
	print("RANGE_SELF_TEST PASS")
	quit(0)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("PASS ", message)
		return
	_failed = true
	push_error("FAIL " + message)
