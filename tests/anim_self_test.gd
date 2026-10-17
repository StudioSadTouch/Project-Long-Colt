extends SceneTree
## Animation checks: third-person driver states (turn in place, grenade throw, crouched death,
## per-weapon fire kick), weapon-model props, first-person viewmodel clips (fire / fire_empty,
## reload and melee sets on every weapon) and ViewmodelMotion. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/anim_self_test.gd

const WEAPON_SCENES := [
	"res://scenes/weapons/standard_issue_rifle.tscn",
	"res://scenes/weapons/service_pistol.tscn",
	"res://scenes/weapons/marksman_carbine.tscn",
	"res://scenes/weapons/combat_shotgun.tscn",
	"res://scenes/weapons/directed_energy_rifle.tscn",
]

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_body()
	await _test_viewmodel_clips()
	await _test_viewmodel_motion()
	await _test_run_steady()
	if _failed:
		quit(1)
		return
	print("ANIM_SELF_TEST PASS")
	quit(0)


# ---------------------------------------------------------------- third person
func _test_body() -> void:
	var body := (load("res://scenes/characters/player_body.tscn") as PackedScene).instantiate()
	var source := body.get_node("CharacterAnimSource")
	source.set(&"enabled", false)
	root.add_child(body)
	var driver := body.get_node("CharacterAnimDriver") as CharacterAnimDriver
	var player := driver.animation_player
	for clip: String in [
		"turn_l", "turn_r", "throw_rifle", "throw_pistol", "fire_carbine", "fire_shotgun",
		"fire_heavy", "death_crouch_front", "death_crouch_back", "death_crouch_left",
		"death_crouch_right", "death_front", "idle"
	]:
		_expect(player.has_animation(clip), "library has %s" % clip)

	var state := CharacterAnimState.new()
	state.weapon_type = CharacterAnimState.WeaponType.RIFLE
	state.weapon_model = CharacterAnimState.WeaponModel.RIFLE
	state.holster_type = CharacterAnimState.WeaponType.PISTOL
	state.holster_model = CharacterAnimState.WeaponModel.PISTOL
	driver.reset_baseline()
	await _feed(driver, state, 5)
	var playback := driver.tree.get(&"parameters/Locomotion/playback") as AnimationNodeStateMachinePlayback

	# Turn in place: 2.5 deg per tick standing still -> a left step after 35 deg.
	var seen := {}
	var entries := 0
	var last := &""
	var last_pos := 0.0
	for i in 60:
		state.yaw += deg_to_rad(2.5)
		await _feed(driver, state, 1)
		var node := playback.get_current_node()
		var pos := playback.get_current_play_position()
		seen[node] = true
		# A step starts on entering the state, or when the same state restarts from 0.
		if node == CharacterAnimDriver.ST_TURN_L and (last != node or pos < last_pos):
			entries += 1
		last = node
		last_pos = pos
	_expect(seen.has(CharacterAnimDriver.ST_TURN_L), "idle left turn steps (states seen %s)" % [seen.keys()])
	_expect(not seen.has(CharacterAnimDriver.ST_TURN_R), "left turn never plays the right step")
	_expect(entries >= 2, "continued turning steps again (%d steps in 150 deg)" % entries)
	seen.clear()
	# Turning back first unwinds the leftover left twist, so give it 75 deg.
	for i in 30:
		state.yaw -= deg_to_rad(2.5)
		await _feed(driver, state, 1)
		seen[playback.get_current_node()] = true
	_expect(seen.has(CharacterAnimDriver.ST_TURN_R), "turning back steps right")
	# Moving off ends a step (after any cross-fade into it finishes: travel waits for fades).
	state.velocity = Vector3(0, 0, -3.5)
	await _feed(driver, state, 12)
	_expect(playback.get_current_node() == CharacterAnimDriver.ST_GROUND, "moving off returns to Ground (%s, travel %s)" % [playback.get_current_node(), playback.get_travel_path()])
	state.velocity = Vector3.ZERO
	await _feed(driver, state, 20)

	# Grenade throw: action one-shot with the throw clip.
	state.action = CharacterAnimState.Action.THROW
	state.action_duration = 0.0
	state.action_seq = CharacterAnimState.bump(state.action_seq)
	await _feed(driver, state, 2)
	var action_anim := (driver.tree.tree_root as AnimationNodeBlendTree).get_node(&"action_anim") as AnimationNodeAnimation
	_expect(action_anim.animation == &"throw_rifle", "throw plays throw_rifle (%s)" % action_anim.animation)
	_expect(bool(driver.tree.get(&"parameters/action_shot/active")), "throw one-shot is active")
	await _feed(driver, state, 45)

	# Fire kick follows the weapon model, else the class.
	var fire_anim := (driver.tree.tree_root as AnimationNodeBlendTree).get_node(&"fire_anim") as AnimationNodeAnimation
	for pair: Array in [
		[CharacterAnimState.WeaponModel.SHOTGUN, &"fire_shotgun"],
		[CharacterAnimState.WeaponModel.ROCKET, &"fire_heavy"],
		[CharacterAnimState.WeaponModel.CARBINE, &"fire_carbine"],
		[CharacterAnimState.WeaponModel.RIFLE, &"fire_rifle"],
	]:
		state.weapon_model = pair[0]
		state.fire_seq = CharacterAnimState.bump(state.fire_seq)
		await _feed(driver, state, 2)
		_expect(fire_anim.animation == pair[1], "model %d fires %s (%s)" % [pair[0], pair[1], fire_anim.animation])

	# Props: the shotgun mesh in hand, the pistol on the thigh.
	state.weapon_model = CharacterAnimState.WeaponModel.SHOTGUN
	await _feed(driver, state, 2)
	var hand := body.get_node(
		"Blockout/BodyMesh/PB_Pelvis/PB_Abdomen/PB_Chest/PB_UpperArm_R/PB_Forearm_R/PB_Hand_R/WeaponAttach_R"
	)
	var shotgun := hand.get_node_or_null(^"Prop_Shotgun") as Node3D
	_expect(shotgun != null and shotgun.visible, "shotgun prop shows in the hand")
	var rifle := hand.get_node_or_null(^"Prop_Rifle") as Node3D
	_expect(rifle == null or not rifle.visible, "rifle prop hidden while the shotgun is out")
	if shotgun != null:
		# Grip on the attach point: the scene's Grip mesh sits near the hand origin.
		var grip := shotgun.transform * (shotgun.get_node("Grip") as Node3D).position
		_expect(grip.length() < 0.06, "shotgun grip sits on the hand (%.3f m off)" % grip.length())
	var thigh := body.get_node("Blockout/BodyMesh/PB_Pelvis/PB_Thigh_R")
	var holstered := thigh.get_node_or_null(^"Prop_Pistol") as Node3D
	_expect(holstered != null and holstered.visible, "pistol prop holstered on the thigh")

	# Death: crouched (cleared on the death tick, as Player does) -> crouched clip.
	state.weapon_model = CharacterAnimState.WeaponModel.RIFLE
	state.crouched = true
	await _feed(driver, state, 25)
	state.crouched = false
	state.dead = true
	state.death_dir = CharacterAnimState.HitDir.LEFT
	state.death_seq = CharacterAnimState.bump(state.death_seq)
	await _feed(driver, state, 2)
	var death_anim := (driver.tree.tree_root as AnimationNodeBlendTree).get_node(&"death_anim") as AnimationNodeAnimation
	_expect(death_anim.animation == &"death_crouch_left", "crouched death (%s)" % death_anim.animation)
	state.dead = false
	await _feed(driver, state, 30)
	state.dead = true
	state.death_dir = CharacterAnimState.HitDir.FRONT
	state.death_seq = CharacterAnimState.bump(state.death_seq)
	await _feed(driver, state, 2)
	_expect(death_anim.animation == &"death_front", "standing death (%s)" % death_anim.animation)
	body.queue_free()
	await process_frame


func _feed(driver: CharacterAnimDriver, state: CharacterAnimState, ticks: int) -> void:
	for i in ticks:
		driver.apply_state(state)
		await physics_frame
		await process_frame


# ---------------------------------------------------------------- first person clips
func _test_viewmodel_clips() -> void:
	for path: String in WEAPON_SCENES:
		var weapon := (load(path) as PackedScene).instantiate() as Weapon
		root.add_child(weapon)
		await process_frame
		var name := path.get_file().get_basename()
		var anim := weapon.get_node_or_null(^"AnimationPlayer") as AnimationPlayer
		_expect(anim != null, "%s has an AnimationPlayer" % name)
		if anim == null:
			weapon.queue_free()
			continue
		for clip: String in ["idle", "reload_tactical", "reload_empty", "melee"]:
			_expect(anim.has_animation(clip), "%s has %s" % [name, clip])
		for node: String in ["ViewmodelReload", "ViewmodelMelee", "ViewmodelFire"]:
			_expect(weapon.has_node(node), "%s has %s" % [name, node])
		var reload := anim.get_animation(&"reload_empty")
		if reload != null:
			_expect(
				is_equal_approx(reload.length, weapon.data.reload_time),
				"%s reload_empty is reload_time long (%.2f / %.2f)" % [name, reload.length, weapon.data.reload_time]
			)
			_expect(
				_has_event(reload, &"sfx_mag_seat", weapon.data.reload_insert_fraction * reload.length),
				"%s seats the mag at the insert fraction" % name
			)
		# Last round: fire_empty, then a reload clip is not interrupted by a shot.
		weapon.magazine = 0
		weapon.fired.emit()
		var current := String(anim.current_animation)
		_expect(current.ends_with("fire_empty"), "%s last shot plays fire_empty (%s)" % [name, current])
		weapon.magazine = 3
		weapon.fired.emit()
		current = String(anim.current_animation)
		_expect(current.ends_with("fire") and not current.ends_with("_empty"), "%s shot plays fire (%s)" % [name, current])
		anim.play(&"reload_tactical")
		weapon.fired.emit()
		_expect(anim.current_animation == &"reload_tactical", "%s shot does not cut a reload" % name)
		weapon.queue_free()
		await process_frame


func _has_event(anim: Animation, event: StringName, at: float) -> bool:
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_METHOD:
			continue
		for k in anim.track_get_key_count(t):
			var v: Dictionary = anim.track_get_key_value(t, k)
			var args: Array = v.get("args", [])
			if not args.is_empty() and args[0] == event:
				if absf(anim.track_get_key_time(t, k) - at) < 0.012:
					return true
	return false


# ---------------------------------------------------------------- first person motion
func _test_viewmodel_motion() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0, -0.5, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	shape.shape = box
	floor_body.add_child(shape)
	root.add_child(floor_body)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, 0)
	root.add_child(player)
	var motion := player.get_node("ViewmodelMotion") as ViewmodelMotion
	var holder := player.get_weapon_holder()
	_expect(motion != null and motion.is_processing(), "ViewmodelMotion runs on the local player")
	# Let the spawn equip finish.
	await _frames(70)
	_expect(holder.position.length() < 0.012, "rest pose near zero (%.4f m)" % holder.position.length())

	# Equip from a switch starts low and comes back up.
	holder.switch_weapon()
	await _frames(2)
	_expect(holder.position.y < -0.08, "switch starts the new weapon low (y %.3f)" % holder.position.y)
	await _frames(60)
	_expect(holder.position.length() < 0.012, "equip settles (%.4f m)" % holder.position.length())

	# Fire kick pushes the gun back, then recovers.
	var weapon := holder.get_active()
	weapon.fired.emit()
	var peak := 0.0
	for i in 8:
		await process_frame
		peak = maxf(peak, holder.position.z)
	_expect(peak > 0.003, "fire kick moves the gun back (%.4f m)" % peak)
	await _frames(60)
	_expect(holder.position.length() < 0.012, "fire kick recovers (%.4f m)" % holder.position.length())

	# Grenade throw dips the weapon.
	(player.get_node("GrenadeThrower") as GrenadeThrower).throw_started.emit(0)
	var low := 0.0
	for i in 10:
		await process_frame
		low = minf(low, holder.position.y)
	_expect(low < -0.03, "throw dips the weapon (%.3f m)" % low)
	await _frames(60)

	# Walking bobs inside sane bounds.
	Input.action_press(&"action_move_forward")
	var lo := Vector3.ONE
	var hi := -Vector3.ONE
	for i in 90:
		await physics_frame
		await process_frame
		lo = lo.min(holder.position)
		hi = hi.max(holder.position)
	Input.action_release(&"action_move_forward")
	var span := hi - lo
	_expect(span.x > 0.008 and span.y > 0.004, "running bobs the weapon (span %s)" % span)
	_expect(span.length() < 0.08, "bob stays small (span %.3f m)" % span.length())
	player.queue_free()
	floor_body.queue_free()
	await process_frame


## Running: the weapon on the body stays on the aim line (no dip or stride swing; it inherited
## the run's 8 deg pelvis lean before) and the visible head stays near the head hitbox.
func _test_run_steady() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(0, -0.5, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	floor_body.add_child(shape)
	root.add_child(floor_body)
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, 0)
	root.add_child(player)
	await _frames(60)
	var hand := player.find_child("WeaponAttach_R", true, false) as Node3D
	var head := player.find_child("PB_Head", true, false) as Node3D
	var helmet := player.get_node("Rig/HeadArmored") as Node3D
	var idle_gap := head.global_position - helmet.global_position
	Input.action_press(&"action_move_forward")
	await _frames(60)
	var base_fwd := (-hand.global_basis.z).normalized()
	var base_local := player.global_basis.inverse() * base_fwd
	var run_yaw_base := rad_to_deg(atan2(-base_local.x, -base_local.z))
	var worst_pitch := 0.0
	var worst_yaw := 0.0
	var worst_head := 0.0
	for i in 40:
		await _frames(1)
		var fwd := (-hand.global_basis.z).normalized()
		var local := player.global_basis.inverse() * fwd
		worst_pitch = maxf(worst_pitch, absf(rad_to_deg(asin(local.y))))
		worst_yaw = maxf(worst_yaw, absf(rad_to_deg(atan2(-local.x, -local.z)) - run_yaw_base))
		var gap := head.global_position - helmet.global_position
		worst_head = maxf(worst_head, (gap - idle_gap).length())
	Input.action_release(&"action_move_forward")
	_expect(player.velocity.length() > 6.0, "running (%.1f m/s)" % player.velocity.length())
	_expect(worst_pitch < 1.5, "run: weapon stays level (worst %.2f deg)" % worst_pitch)
	_expect(worst_yaw < 1.5, "run: weapon doesn't swing with the stride (worst %.2f deg)" % worst_yaw)
	_expect(worst_head < 0.05, "run: head stays on its hitbox (worst %.3f m from idle)" % worst_head)
	player.queue_free()
	floor_body.queue_free()
	await process_frame


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
