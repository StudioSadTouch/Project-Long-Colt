extends SceneTree
## New Ottoman enemy types (docs/enemies/new_ottoman.md): the ten ranks load with the board's
## heights, kit and pools; plate never recharges and spalls in the board's three stages; the
## Janissary goes reckless with the blade out when exposed; lobbed shots solve their arc; the
## orta runs SCREEN -> PEEL -> BREAK with the right orders and cues; the test yard bakes a
## navmesh that reaches the platform and catwalks, and its orta finds and fights the player. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/new_ottoman_self_test.gd

const TYPES := "res://resources/enemies/new_ottoman/%s.tres"
const ENEMY := "res://scenes/enemies/enemy.tscn"
const ALL := [
	"nefer", "odabasi", "corbaci", "aga",
	"azab", "okcu", "bolukbasi",
	"akinji", "akinji_marksman", "akinci_beyi",
]
const HEIGHTS := {
	EnemyType.Corps.JANISSARY: 2.6, EnemyType.Corps.AZAB: 1.75, EnemyType.Corps.AKINJI: 1.8
}

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_types()
	_test_ballistics()
	# The yard first, on a fresh navigation map as when a level loads. Run after the other
	# sections, Godot 4.7's map stopped syncing the yard's region (iteration id stuck) in this
	# headless harness; not seen when the yard runs first.
	await _test_yard()
	var floor_body := _box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	await _test_bodies()
	await _test_plate()
	await _test_lob()
	await _test_orta()
	await _test_rotated_squad_aim()
	await _test_gunfire_sound()
	floor_body.queue_free()
	await _frames(2)
	if _failed:
		print("NEW_OTTOMAN_SELF_TEST FAIL")
		quit(1)
		return
	print("NEW_OTTOMAN_SELF_TEST PASS")
	quit(0)


func _type(id: String) -> EnemyType:
	return load(TYPES % id) as EnemyType


func _test_types() -> void:
	var rank_colours := {}
	for id: String in ALL:
		var t := _type(id)
		_expect(t != null and t.id == StringName(id), "%s loads" % id)
		if t == null:
			continue
		if not t.boss:
			_expect(is_equal_approx(t.height, HEIGHTS[t.corps]), "%s is %.2f m" % [id, t.height])
		_expect(not t.starting_weapons.is_empty(), "%s carries a weapon" % id)
		for scene in t.starting_weapons:
			_expect(WeaponData.of_scene(scene) != null, "%s: %s has WeaponData" % [id, scene.resource_path])
		_expect(t.health > 0.0, "%s has health" % id)
		var key := "%d|%s" % [t.corps, t.rank_color.to_html()]
		_expect(not rank_colours.has(key), "%s: rank colour unique in its corps" % id)
		rank_colours[key] = true
	_expect(_type("nefer").armor > 0.0 and _type("azab").armor == 0.0, "plate on Janissaries only")
	_expect(_type("corbaci").role == EnemyType.Role.COMMANDER, "Corbaci commands the orta")
	_expect(_type("aga").boss, "Aga is boss tier")


func _test_ballistics() -> void:
	var from := Vector3(0, 1.5, 0)
	var to := Vector3(3, 0.5, -22)
	for high: bool in [false, true]:
		var dir := BotWeaponPrefs.ballistic_direction(from, to, 20.0, 12.0, high)
		# Integrate the flight; the closest pass must be on the target.
		var p := from
		var v := dir * 20.0
		var best := INF
		for i in 600:
			v.y -= 12.0 / 120.0
			p += v / 120.0
			best = minf(best, p.distance_to(to))
		_expect(best < 0.3, "%s arc lands on target (miss %.2f m)" % ["high" if high else "flat", best])
	var low := BotWeaponPrefs.ballistic_direction(from, to, 20.0, 12.0, false)
	var lob := BotWeaponPrefs.ballistic_direction(from, to, 20.0, 12.0, true)
	_expect(lob.y > low.y + 0.3, "the lob climbs steeper than the flat shot")


func _spawn(id: String, at: Vector3) -> Enemy:
	var e := (load(ENEMY) as PackedScene).instantiate() as Enemy
	e.enemy_type = _type(id)
	e.position = at
	root.add_child(e)
	return e


func _test_bodies() -> void:
	var x := -20.0
	var spawned: Array[Enemy] = []
	for id: String in ALL:
		var e := _spawn(id, Vector3(x, 0.05, -30))
		x += 4.0
		spawned.append(e)
	await _frames(10)
	for e in spawned:
		var t := e.enemy_type
		var capsule := e.collision_shape.shape as CapsuleShape3D
		_expect(absf(capsule.height - t.height) < 0.01, "%s capsule %.2f m" % [t.id, capsule.height])
		_expect(e.team == Enemy.FACTION_TEAM and e.is_in_group(Enemy.GROUP), "%s on the faction team" % t.id)
		var points := e.get_aim_points()
		_expect(points.has("head") and points.has("face"), "%s has head and face aim points" % t.id)
		if points.has("head"):
			var head_y: float = points.head.y - e.global_position.y
			_expect(head_y > t.height * 0.8 and head_y < t.height, "%s head at %.2f m" % [t.id, head_y])
		var helmet := e.get_node_or_null(^"Rig/HeadArmored")
		var face := e.get_node_or_null(^"Rig/HeadUnarmored")
		_expect(helmet != null and helmet.is_in_group(&"hitbox_head_armored"), "%s helmet hitbox" % t.id)
		_expect(face != null and face.is_in_group(&"hitbox_head_unarmored"), "%s face hitbox" % t.id)
		_check_hit_volumes(e)
		_expect(e.health_shield.max_shield == t.armor and e.health_shield.health == t.health, "%s pools" % t.id)
		_expect(e.get_active() != null, "%s armed" % t.id)
		var sensor := e.find_child("SensorSlit", true, false)
		_expect(sensor != null, "%s carries the turquoise sensor slit" % t.id)
		var brain := e.get_node("Brain") as EnemyBrain
		_expect(brain.order == EnemyBrain.default_order(t), "%s default order" % t.id)
	for e in spawned:
		e.queue_free()
	await _frames(2)


func _test_plate() -> void:
	var e := _spawn("nefer", Vector3(0, 0.05, -10))
	await _frames(5)
	var hs := e.health_shield
	var rig := e.get_rig()
	_expect(e.find_child("Crest", true, false) != null, "Nefer wears a crest")
	e.take_damage(40.0, {"position": e.global_position + Vector3.UP * 2.0})
	_expect(hs.shield == hs.max_shield - 40.0, "plate absorbs the hit")
	_expect(e.get_stage() == ArmorStages.Stage.FULL, "still FULL")
	await _frames(int(7.0 * 60))
	_expect(hs.shield == hs.max_shield - 40.0, "plate never recharges (%.1f)" % hs.shield)
	e.take_damage(hs.max_shield * 0.5, {})
	_expect(e.get_stage() == ArmorStages.Stage.SPALLED, "SPALLED at half plate")
	await _frames(2)
	_expect(rig.find_child("Crest", true, false) == null, "crest spalled off")
	_expect(e.get_active().data.melee_primary == false, "rifle still up while plated")
	var speed := e.speed_scale
	e.take_damage(hs.shield + 5.0, {})
	_expect(e.get_stage() == ArmorStages.Stage.EXPOSED, "EXPOSED with no plate left")
	_expect(hs.health == hs.max_health, "the breaking hit doesn't bleed into health")
	_expect(e.speed_scale > speed, "exposed frame runs faster")
	_expect(e.difficulty.aggression >= 1.0, "exposed frame is reckless")
	await _frames(15)
	_expect(e.get_active().data.melee_primary, "blade out once exposed")
	var vent := rig.find_child("Vent", true, false) as CPUParticles3D
	_expect(vent != null and vent.emitting, "hydraulics vent")
	# Respawn restores the plate and the crest.
	e.respawn_at(Transform3D(Basis.IDENTITY, Vector3(0, 0.05, -10)))
	await _frames(3)
	_expect(e.get_stage() == ArmorStages.Stage.FULL and hs.shield == hs.max_shield, "respawn re-plates")
	_expect(rig.find_child("Crest", true, false) != null, "respawn restores the crest")
	e.queue_free()
	await _frames(2)


func _test_lob() -> void:
	var data := load("res://resources/weapons/new_ottoman/humbara_launcher.tres") as WeaponData
	_expect(data.projectile_gravity > 0.0, "humbara lobs")
	var rocket := Rocket.spawn(root, data, Vector3(0, 10, 40), Vector3.FORWARD, null)
	var y0 := rocket.global_position.y
	await _frames(30)
	_expect(is_instance_valid(rocket) and rocket.global_position.y < y0 - 0.5, "the shell drops")
	if is_instance_valid(rocket):
		rocket.queue_free()


func _test_orta() -> void:
	var orta := Orta.new()
	root.add_child(orta)
	var cues: Array[StringName] = []
	orta.cue.connect(func(c: StringName) -> void: cues.append(c))
	var azabs: Array[Enemy] = []
	for i in 4:
		azabs.append(orta.spawn(_type("azab"), Transform3D(Basis.IDENTITY, Vector3(-6 + i * 4, 0.05, 0))))
	var leader := orta.spawn(_type("bolukbasi"), Transform3D(Basis.IDENTITY, Vector3(0, 0.05, -3)))
	var raider := orta.spawn(_type("akinji"), Transform3D(Basis.IDENTITY, Vector3(-15, 0.05, -5)))
	var nefer := orta.spawn(_type("nefer"), Transform3D(Basis.IDENTITY, Vector3(5, 0.05, -8)))
	var corbaci := orta.spawn(_type("corbaci"), Transform3D(Basis.IDENTITY, Vector3(-5, 0.05, -8)))
	await _frames(5)
	var slots := azabs.map(func(a: Enemy) -> float: return Orta.brain_of(a).line_slot)
	_expect(slots == [-1.5, -0.5, 0.5, 1.5], "Azab line slots spread (%s)" % [slots])
	_expect(Orta.brain_of(raider).order == EnemyBrain.Order.HOLD, "raider waits for the peel")
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, 40)
	root.add_child(player)
	await _frames(5)
	orta.report_contact(azabs[0], player, player.global_position)
	_expect(orta.phase == Orta.Phase.SCREEN, "contact starts the SCREEN")
	_expect(Orta.brain_of(azabs[1]).order == EnemyBrain.Order.ADVANCE, "Azabs advance")
	_expect(Orta.brain_of(nefer).order == EnemyBrain.Order.HOLD, "Janissaries hold")
	_expect(Orta.brain_of(azabs[2]).target == player, "contact shared with the squad")
	_expect(cues.has(&"horn_advance"), "advance horn (%s)" % [cues])
	_expect(not cues.has(&"drum") and orta.find_child("Mehter", false, false) == null, "no drum loop")
	var open := 0
	for i in 60:
		orta._since_phase = i * 0.1
		open += 1 if orta.volley_open() else 0
	_expect(open > 20 and open < 40, "volleys are a beat, not a stream (%d/60 open)" % open)
	azabs[0].take_damage(500.0, {"source": player})
	azabs[1].take_damage(500.0, {"source": player})
	await _frames(20)
	_expect(orta.phase == Orta.Phase.PEEL, "losses peel the line (%s)" % orta.get_phase_name())
	_expect(Orta.brain_of(azabs[2]).order == EnemyBrain.Order.PEEL, "survivors peel to the flanks")
	_expect(Orta.brain_of(raider).order == EnemyBrain.Order.FLANK, "raider runs the flank")
	_expect(Orta.brain_of(raider).flank_point != Vector3.INF, "raider has a flank point")
	_expect(cues.has(&"horn_withdraw"), "withdraw horn")
	leader.take_damage(500.0, {"source": player})
	await _frames(3)
	_expect(Orta.brain_of(azabs[3]).order == EnemyBrain.Order.ROUT, "Bolukbasi down: Azabs rout")
	_expect(Orta.brain_of(nefer).order == EnemyBrain.Order.HOLD, "...but the Janissaries hold")
	corbaci.take_damage(5000.0, {"source": player, "bleedthrough": true})
	await _frames(3)
	_expect(orta.phase == Orta.Phase.BREAK, "Corbaci down: BREAK")
	_expect(Orta.brain_of(nefer).order == EnemyBrain.Order.CHARGE, "Janissaries charge")
	_expect(nefer.get_active().data.melee_primary, "blades drawn")
	_expect(cues.has(&"cymbal"), "cymbal on the break")
	await _frames(50)
	_expect(not cues.has(&"zurna"), "no zurna melody over the game's music")
	player.queue_free()
	orta.queue_free()
	await _frames(3)


## Other combatants' gunfire (CombatFeedback) comes from each weapon scene's own WeaponFx: every
## enemy gun resolves to a sound (they used to be missing from a by-name table), blades don't,
## and the renamed rocket launcher does too.
func _test_gunfire_sound() -> void:
	var e := _spawn("nefer", Vector3(40, 0.05, 40))
	await _frames(3)
	for w: BotWeapon in e.slots:
		var sound := WeaponAudio.fire_sound_of(w)
		if w.data.melee_primary:
			_expect(sound == null, "%s: a blade has no gunfire" % w.data.display_name)
		else:
			_expect(sound != null, "%s: an enemy's gun has gunfire" % w.data.display_name)
	for file in DirAccess.get_files_at("res://scenes/weapons/new_ottoman"):
		if not file.ends_with(".tscn"):
			continue
		var scene := load("res://scenes/weapons/new_ottoman/" + file) as PackedScene
		var has_sound := WeaponAudio.fire_sound_of_scene(scene) != null
		var blade := WeaponData.of_scene(scene).melee_primary
		_expect(has_sound != blade, "%s: gunfire %s" % [file, "yes" if has_sound else "none (blade)"])
	var rocket := load("res://scenes/weapons/directed_energy_rifle.tscn") as PackedScene
	_expect(WeaponAudio.fire_sound_of_scene(rocket) != null, "the rocket launcher has gunfire")
	e.queue_free()
	await _frames(2)


## An enemy's gun points where it looks even inside a rotated squad (Horde turns each Orta
## to face the defenders; Bot.set_aim used to write world yaw into local rotation).
func _test_rotated_squad_aim() -> void:
	var orta := Orta.new()
	root.add_child(orta)
	orta.global_transform = Transform3D(Basis(Vector3.UP, 1.3), Vector3(30, 0, 30))
	var e := orta.spawn(_type("azab"), Transform3D(Basis.IDENTITY, Vector3(30, 0.05, 30)))
	(e.get_node("Brain") as Node).process_mode = Node.PROCESS_MODE_DISABLED
	await _frames(3)
	for dir: Vector3 in [Vector3(1, 0, 0), Vector3(0, -0.2, 1).normalized(), Vector3(-1, 0.1, -1).normalized()]:
		e.set_aim(dir)
		var gun := -e.eye.global_basis.z
		var off := rad_to_deg(gun.angle_to(dir))
		_expect(off < 1.0, "gun follows the aim inside a rotated squad (%.1f deg off)" % off)
	orta.queue_free()
	await _frames(2)


func _test_yard() -> void:
	var yard := (load("res://scenes/enemies/orta_yard.tscn") as PackedScene).instantiate() as OrtaYard
	root.add_child(yard)
	current_scene = yard
	var nav := yard.navigation
	for i in 600:
		if nav.is_baked:
			break
		await _frames(1)
	_expect(nav.is_baked and nav.navigation_mesh.get_polygon_count() > 0, "yard navmesh baked")
	var map := yard.get_world_3d().navigation_map
	var from := Vector3.ZERO
	for i in 300:  # the region syncs into the map on a later server iteration
		await _frames(1)
		from = NavigationServer3D.map_get_closest_point(map, Vector3(0, 0, 26))
		if from != Vector3.ZERO:
			break
	var goals := {
		"platform": Vector3(0, OrtaYard.PLATFORM_Y, -17),
		"west catwalk": Vector3(-28, OrtaYard.CATWALK_Y, 0),
		"east catwalk": Vector3(28, OrtaYard.CATWALK_Y, 0),
	}
	for key: String in goals:
		var goal: Vector3 = goals[key]
		var to := NavigationServer3D.map_get_closest_point(map, goal)
		var path := NavigationServer3D.map_get_path(map, from, to, true)
		var reached := not path.is_empty() and path[path.size() - 1].distance_to(goal) < 1.0
		var end: Vector3 = path[path.size() - 1] if not path.is_empty() else Vector3.INF
		_expect(reached, "path from the player spawn to the %s (%s -> %s, ends %s)" % [key, from, to, end])
	_expect(yard.orta.members.size() == 11, "the Phase 0 orta (+Okcu) spawned (%d)" % yard.orta.members.size())
	var player := yard.get_node("Player") as Player
	var hurt := [0.0]
	player.get_node("HealthShield").changed.connect(
		func(s: float, h: float) -> void: hurt[0] = maxf(hurt[0], 115.0 - s - h)
	)
	var phase_seen := {yard.orta.phase: true}
	yard.orta.phase_changed.connect(func(p: Orta.Phase) -> void: phase_seen[p] = true)
	for i in 20 * 60:
		await _frames(1)
		if player.get_node("HealthShield").dead:
			break
	_expect(phase_seen.has(Orta.Phase.SCREEN), "the orta spots the player and screens")
	_expect(hurt[0] > 0.0, "the orta hurts the player (%.0f)" % hurt[0])
	var marksman: Enemy = null
	for e in yard.orta.members:
		if e.enemy_type.role == EnemyType.Role.MARKSMAN:
			marksman = e
	_expect(marksman != null and marksman.global_position.y > OrtaYard.PERCH_Y - 0.5, "marksman stays on the perch")
	yard.queue_free()
	await _frames(3)


## Hit volumes (EnemyType.hitbox_scale): a chest shot 0.3 m off centre lands on every rank, even
## a 1.75 m Azab; a shot into the face still scores the face; the hurtbox stays under the helmet.
func _check_hit_volumes(e: Enemy) -> void:
	var t := e.enemy_type
	var hurt_top := (e.hurtbox_shape.shape as BoxShape3D).size.y
	var helmet := e.get_node(^"Rig/HeadArmored/HelmetShape") as CollisionShape3D
	var helmet_bottom := (
		helmet.global_position.y - e.global_position.y - (helmet.shape as BoxShape3D).size.y * 0.5
	)
	_expect(
		hurt_top <= helmet_bottom,
		"%s hurtbox top %.2f m under the helmet (%.2f m)" % [t.id, hurt_top, helmet_bottom]
	)
	var forward := -e.global_basis.z
	var chest := e.global_position + Vector3.UP * t.height * 0.6 + e.global_basis.x * 0.3
	var hit := _ray(chest + forward * 5.0, chest - forward * 5.0)
	_expect(hit == e.hurtbox, "%s: a chest shot 0.3 m off centre hits" % t.id)
	var visor := e.get_node(^"Rig/HeadUnarmored/VisorShape") as Node3D
	var face := Vector3(e.global_position.x, visor.global_position.y, e.global_position.z)
	hit = _ray(face + forward * 5.0, face)
	var scored := hit != null and hit.is_in_group(&"hitbox_head_unarmored")
	_expect(scored, "%s: a shot into the face scores the face" % t.id)


## First thing a shot along from -> to would hit (Weapon's hit layers), or null.
func _ray(from: Vector3, to: Vector3) -> Node:
	var query := PhysicsRayQueryParameters3D.create(from, to, Weapon.HIT_MASK)
	return root.get_world_3d().direct_space_state.intersect_ray(query).get("collider") as Node


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
