extends SceneTree
## Grenade pickups: walk-over takes as many as fit (4 per type) and leaves the rest on the
## ground, a full player takes none, the type goes to the right count, a placed pickup refills
## after respawn_delay, a dead player's grenades drop as pickups (not for kill-volume deaths or
## with drop_on_death off), a drop empties and frees itself or despawns, the net state / drop
## message round trip (NetPickups), and the custom-level catalog item. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/grenade_pickup_self_test.gd

const PLAYER := preload("res://scenes/player/player.tscn")
const PICKUP := preload("res://scenes/pickups/grenade_pickup.tscn")
const FRAG := preload("res://resources/weapons/frag_grenade.tres")
const STICKY := preload("res://resources/weapons/sticky_grenade.tres")
const FRAG_PATH := "res://resources/weapons/frag_grenade.tres"
## Where players wait out of every trigger.
const PARKED := Vector3(0, 0, 40)

var _failed: bool = false
var _world: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = Node3D.new()
	_world.name = "World"
	root.add_child(_world)
	_add_box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))  # floor
	_add_box(Vector3(40, 1.5, -0.6), Vector3(6, 3, 0.3))  # wall 0.45 m in front of x = 40
	await _settle()

	await _test_take_and_cap()
	await _test_sticky_type()
	await _test_death_drop()
	await _test_drop_against_wall()
	await _test_no_drop()
	await _test_despawn()
	await _test_net_round_trip()
	_test_catalog()

	if _failed:
		print("GRENADE_PICKUP_SELF_TEST FAIL")
		quit(1)
		return
	print("GRENADE_PICKUP_SELF_TEST PASS")
	quit(0)


func _add_box(pos: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)


func _spawn_player(pos: Vector3) -> Player:
	var player := PLAYER.instantiate() as Player
	player.auto_respawn = false
	# Placed before it enters the tree: added at the origin, it would already touch a pickup there.
	player.position = pos
	_world.add_child(player)
	return player


func _spawn_pickup(parent: Node, pos: Vector3, data: GrenadeData, amount: int, respawn: float = 30.0) -> GrenadePickup:
	var pickup := PICKUP.instantiate() as GrenadePickup
	pickup.grenade = data
	pickup.amount = amount
	pickup.respawn_delay = respawn
	parent.add_child(pickup)
	pickup.global_position = pos
	return pickup


func _thrower(player: Player) -> GrenadeThrower:
	return player.get_node(^"GrenadeThrower") as GrenadeThrower


func _set_counts(grenades: GrenadeThrower, frags: int, stickies: int) -> void:
	grenades.counts[0] = frags
	grenades.counts[1] = stickies


func _visible_meshes(pickup: GrenadePickup) -> int:
	var shown := 0
	for child in pickup.visual.get_children():
		shown += 1 if (child as Node3D).visible else 0
	return shown


## Dropped grenade pickups under the world, nearest first, within reach of at.
func _drops_near(at: Vector3, reach: float) -> Array[GrenadePickup]:
	var out: Array[GrenadePickup] = []
	for child in _world.get_children():
		var pickup := child as GrenadePickup
		if pickup != null and pickup.dropped and not pickup.is_queued_for_deletion():
			if pickup.global_position.distance_to(at) <= reach:
				out.append(pickup)
	return out


func _settle(frames: int = 6) -> void:
	for _i in frames:
		await physics_frame


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout
	await _settle(2)


## 3 frags + a pickup of 2: takes 1 (cap 4), one stays. Full: takes none. Room again: takes the
## last, the pickup empties, then refills after respawn_delay.
func _test_take_and_cap() -> void:
	var pickup := _spawn_pickup(_world, Vector3(0, 0, 0), FRAG, 2, 0.4)
	var player := _spawn_player(PARKED)
	await _settle()
	var grenades := _thrower(player)
	_check(_visible_meshes(pickup) == 2, "a pickup of 2 shows 2 grenades")
	_set_counts(grenades, 3, 2)
	player.global_position = pickup.global_position
	await _settle()
	_check(grenades.counts[0] == 4, "walk-over tops frags up to the cap (frags %d)" % grenades.counts[0])
	_check(pickup.available and pickup.remaining == 1, "the frag that didn't fit stays (left %d)" % pickup.remaining)
	_check(_visible_meshes(pickup) == 1, "one grenade mesh left")
	await _settle()
	_check(pickup.remaining == 1 and grenades.counts[0] == 4, "a full player takes none")
	grenades.counts[0] = 2
	await _settle()
	_check(grenades.counts[0] == 3, "room again: takes the last frag")
	_check(not pickup.available and _visible_meshes(pickup) == 0, "an empty placed pickup hides")
	_check(is_instance_valid(pickup), "a placed pickup is not freed")
	player.global_position = PARKED
	await _wait(0.6)
	_check(pickup.available and pickup.remaining == 2, "refills to 2 after respawn_delay")
	_check(_visible_meshes(pickup) == 2, "both grenades shown again")
	player.queue_free()
	pickup.queue_free()
	await _settle(2)


## A sticky pickup fills the sticky count, not the frag count.
func _test_sticky_type() -> void:
	var pickup := _spawn_pickup(_world, Vector3(6, 0, 0), STICKY, 1)
	var player := _spawn_player(PARKED)
	await _settle()
	var grenades := _thrower(player)
	_set_counts(grenades, 0, 2)
	_check(grenades.index_of(STICKY) == 1 and grenades.index_of(FRAG) == 0, "index_of matches types")
	player.global_position = pickup.global_position
	await _settle()
	_check(grenades.counts[1] == 3 and grenades.counts[0] == 0, "sticky pickup adds a sticky (%s)" % [grenades.counts])
	_check(not pickup.available, "the single sticky is taken")
	player.queue_free()
	pickup.queue_free()
	await _settle(2)


## Death: one pickup per type with what was carried, on the floor near the body; the dead body
## takes none back. A looter takes what fits; an emptied drop frees itself.
func _test_death_drop() -> void:
	var player := _spawn_player(Vector3(30, 0, 0))
	await _settle()
	var grenades := _thrower(player)
	_set_counts(grenades, 3, 1)
	player.take_damage(1000.0, {"bleedthrough": true})
	_check(player.dead, "the player died")
	await _settle()
	var drops := _drops_near(player.global_position, 2.0)
	_check(drops.size() == 2, "two drops, one per type (%d)" % drops.size())
	_check(grenades.counts[0] == 0 and grenades.counts[1] == 0, "the dead body kept none (%s)" % [grenades.counts])
	var frag_drop: GrenadePickup = null
	var sticky_drop: GrenadePickup = null
	for drop in drops:
		if drop.grenade == FRAG:
			frag_drop = drop
		elif drop.grenade == STICKY:
			sticky_drop = drop
	_check(frag_drop != null and frag_drop.remaining == 3, "frag drop holds the 3 carried frags")
	_check(sticky_drop != null and sticky_drop.remaining == 1, "sticky drop holds the 1 carried sticky")
	if frag_drop == null or sticky_drop == null:
		return
	for drop in drops:
		_check(absf(drop.global_position.y) < 0.05, "drop lies on the floor (y %.2f)" % drop.global_position.y)
	var gap := frag_drop.global_position.distance_to(sticky_drop.global_position)
	_check(absf(gap - GrenadeThrower.DEATH_DROP_SPREAD) < 0.05, "drops spread apart (%.2f m)" % gap)

	var looter := _spawn_player(PARKED)
	await _settle()
	var loot := _thrower(looter)
	_set_counts(loot, 2, 2)
	looter.global_position = Vector3(30, 0, 0)
	await _settle()
	_check(loot.counts[0] == 4, "looter takes 2 of the 3 dropped frags (frags %d)" % loot.counts[0])
	_check(loot.counts[1] == 3, "looter takes the dropped sticky (stickies %d)" % loot.counts[1])
	_check(is_instance_valid(frag_drop) and frag_drop.remaining == 1, "the frag that didn't fit stays dropped")
	_check(not is_instance_valid(sticky_drop), "an emptied drop frees itself")
	player.respawn_at(Transform3D(Basis(), Vector3(30, 0, 20)))  # clear of the frag left behind
	await _settle()
	_check(grenades.counts == [2, 2], "respawn refills the counts (%s)" % [grenades.counts])
	for node in [player, looter, frag_drop]:
		if is_instance_valid(node):
			node.queue_free()
	await _settle(2)


## Three types spread wider (-0.8 / 0 / +0.8 m along the facing): the one heading into the wall
## 0.45 m in front of the body stops short of it instead of landing behind it.
func _test_drop_against_wall() -> void:
	var player := _spawn_player(Vector3(40, 0, 0))
	await _settle()
	var grenades := _thrower(player)
	grenades.types.append(FRAG)
	grenades.counts.append(1)
	_set_counts(grenades, 1, 1)
	player.take_damage(1000.0, {"bleedthrough": true})
	await _settle()
	var drops := _drops_near(player.global_position, 2.0)
	_check(drops.size() == 3, "three types drop three pickups (%d)" % drops.size())
	var front_z := 0.0
	var back_z := 0.0
	for drop in drops:
		front_z = minf(front_z, drop.global_position.z)
		back_z = maxf(back_z, drop.global_position.z)
	_check(front_z > -0.45, "a wall keeps the drop on this side of it (z %.2f)" % front_z)
	_check(absf(back_z - GrenadeThrower.DEATH_DROP_SPREAD) < 0.05, "open side drops the full spread (z %.2f)" % back_z)
	player.queue_free()
	for drop in drops:
		drop.queue_free()
	await _settle(2)


## Kill volumes take the grenades with the body; drop_on_death off (net clients) drops nothing.
func _test_no_drop() -> void:
	var fallen := _spawn_player(Vector3(50, 0, 0))
	var client := _spawn_player(Vector3(60, 0, 0))
	await _settle()
	_thrower(client).drop_on_death = false
	fallen.take_damage(1000.0, {"bleedthrough": true, "kill_volume": true})
	client.take_damage(1000.0, {"bleedthrough": true})
	await _settle()
	_check(fallen.dead and _drops_near(fallen.global_position, 3.0).is_empty(), "no drop for a kill-volume death")
	_check(client.dead and _drops_near(client.global_position, 3.0).is_empty(), "no drop with drop_on_death off")
	fallen.queue_free()
	client.queue_free()
	await _settle(2)


## A drop nobody takes despawns after despawn_time.
func _test_despawn() -> void:
	var drop := PICKUP.instantiate() as GrenadePickup
	drop.grenade = FRAG
	drop.amount = 2
	drop.dropped = true
	drop.despawn_time = 0.3
	_world.add_child(drop)
	drop.global_position = Vector3(70, 0, 0)
	await _wait(0.5)
	_check(not is_instance_valid(drop), "an untouched drop despawns")


## Host state carries the count; a client mirror follows it (meshes too). Drops round-trip
## through the "grenade:" drop message and leave when the host forgets them.
func _test_net_round_trip() -> void:
	var host_root := Node3D.new()
	host_root.name = "HostArena"
	_world.add_child(host_root)
	var client_root := Node3D.new()
	client_root.name = "ClientArena"
	_world.add_child(client_root)
	var placed := _spawn_pickup(host_root, Vector3(80, 0, 0), FRAG, 2)
	placed.name = "Frags"
	var mirror := _spawn_pickup(client_root, Vector3(90, 0, 0), FRAG, 2)
	mirror.name = "Frags"
	await _settle()
	var host := NetPickups.new(host_root)
	var client := NetPickups.new(client_root)
	host.scan()
	client.scan()
	_check(host.nodes.has("Frags") and client.nodes.has("Frags"), "placed grenade pickups are scanned")
	_check(int(host.state().get("Frags", -1)) == 2, "state carries the grenade count")

	var player := _spawn_player(PARKED)
	await _settle()
	_set_counts(_thrower(player), 3, 0)
	player.global_position = placed.global_position
	await _settle()
	var state := host.state()
	_check(int(state.get("Frags", -1)) == 1, "state follows a take (%s)" % [state.get("Frags")])
	client.apply_state(state)
	_check(mirror.remaining == 1 and mirror.available and _visible_meshes(mirror) == 1, "client mirrors the count")
	client.apply_state({"Frags": 0})
	_check(not mirror.available and _visible_meshes(mirror) == 0, "client mirrors an empty pickup")
	client.apply_state({"Frags": 2})
	_check(mirror.available and _visible_meshes(mirror) == 2, "client mirrors the respawn")
	player.global_position = PARKED

	var dropped := GrenadePickup.drop(STICKY, 3, host_root, Vector3(84, 0, 0))
	var message := host.register_drop(dropped)
	_check(message.size() == 4 and str(message[1]) == NetPickups.GRENADE_TAG + STICKY.resource_path, "grenade drop message (%s)" % [message])
	_check(host.drops().size() == 1, "late joiners get the live grenade drop")
	client.spawn_drop(message)
	var copy := client.find(str(message[0])) as GrenadePickup
	_check(copy != null and copy.dropped and copy.grenade == STICKY and copy.remaining == 3, "client builds the dropped stickies")
	_check(int(host.state().get(str(message[0]), -1)) == 3, "the drop's count is in the state")
	await _settle()
	client.apply_state({"Frags": 2})
	await _settle(2)
	_check(not is_instance_valid(copy), "a drop the host forgot is removed on the client")
	host_root.queue_free()
	client_root.queue_free()
	player.queue_free()
	await _settle(2)


func _test_catalog() -> void:
	var id := "grenade:" + FRAG_PATH
	var item := LevelCatalog.get_item(id)
	_check(not item.is_empty() and str(item.get("kind", "")) == "grenade", "custom levels list frag grenades")
	_check(LevelCatalog.has_item("grenade:" + STICKY.resource_path), "custom levels list sticky grenades")
	var built := LevelBuilder.build({"catalog_id": id, "uid": 7, "props": {"amount": 3.0}}, false)
	var pickup := built as GrenadePickup
	_check(pickup != null and pickup.grenade == FRAG and pickup.amount == 3, "the builder makes a 3-frag pickup")
	if built != null:
		built.free()


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ok   ", label)
	else:
		print("  FAIL ", label)
		_failed = true
