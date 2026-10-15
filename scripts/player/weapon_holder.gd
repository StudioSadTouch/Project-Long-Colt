class_name WeaponHolder
extends Node3D
## Two weapon slots, Halo style. No dual-wield.
## Lives under the player camera so view models follow aim.

signal active_weapon_changed(weapon: Weapon)

const SLOT_COUNT := 2
## Drop placement probes World only.
const DROP_WORLD_MASK := 1
const DROP_CHEST_HEIGHT := 1.2
const DROP_WALL_MARGIN := 0.4
const DROP_MIN_DISTANCE := 0.3
## How far below chest height to look for floor (covers short ledges, not cliffs).
const DROP_FLOOR_SEARCH := 2.5
## Death drops: each weapon lands this far to either side of the body (pickup triggers have a
## 1 m radius, same spacing as Bot.DROP_SPREAD); a wall in the way shortens it.
const DEATH_DROP_SPREAD := 1.1
## Xbox face-button names for pad prompts (JoyButton index -> label).
const PAD_BUTTON_NAMES := {0: "A", 1: "B", 2: "X", 3: "Y", 4: "Back", 6: "Start"}

@export var starting_weapons: Array[PackedScene] = []
## Seconds interact must be held to take a weapon pickup.
@export var pickup_hold_time: float = 0.4
## Dropped weapons land this far in front of the player.
@export var drop_distance: float = 1.2
## Hand the Player's AimAssist to weapons. Off for bots (weapons then get aim_assist = null).
@export var use_aim_assist: bool = true
## Pickup choice score = view dot - distance * this. Higher favors the nearest over the aimed-at.
@export var pickup_distance_weight: float = 0.25
## Halo: on death, carried weapons with ammo drop as pickups (both, side by side, each with its
## own magazine and reserve). Never for kill-volume deaths.
@export var drop_weapons_on_death: bool = true

var slots: Array[Weapon] = []
var active_index: int = 0
## Net client hook: when valid, take_pickup(p) calls this with p and returns false instead of
## taking it locally (the host decides and sends the new loadout; see apply_loadout).
var pickup_request_hook: Callable

var _player: Player
var _melee_left: float = 0.0
var _camera: Camera3D
var _pickups: Array[WeaponPickup] = []
var _hold: float = 0.0
var _hold_target: WeaponPickup
## Set after a swap until interact is released, so the dropped weapon isn't grabbed right back.
var _hold_lock: bool = false
## Pad X is both reload (tap) and interact (hold). While a pickup is in range, a shared press
## defers reload to the release, and only reloads if the hold didn't take a pickup.
var _reload_on_release: bool = false
## Scope overlay fade-in, 0..1 over data.zoom_time; 0 at once on unzoom (HUD: get_zoom_blend).
var _zoom_blend: float = 0.0
## Viewmodel hidden while scoped: the weapon, and each GeometryInstance3D's original layers.
## Keys stay untyped (Variant) so a freed mesh can be skipped with is_instance_valid.
var _hidden_viewmodel: Weapon
var _hidden_layers: Dictionary = {}


func _ready() -> void:
	_camera = get_parent() as Camera3D
	_player = owner as Player
	slots.resize(SLOT_COUNT)
	for i in mini(starting_weapons.size(), SLOT_COUNT):
		if starting_weapons[i] != null:
			_install(starting_weapons[i].instantiate() as Weapon, i)
	# Equip exactly once at startup.
	_equip(_first_filled(0))
	# Halo: taking damage knocks you out of zoom. HealthShield is a sibling under the player,
	# whose @onready vars aren't set yet, so look it up directly.
	var health := _player.get_node_or_null("HealthShield") as HealthShield if _player else null
	if health != null:
		health.shield_damaged.connect(_on_owner_damaged)
		health.health_damaged.connect(_on_owner_damaged)


func get_active() -> Weapon:
	if slots.is_empty():
		return null
	return slots[active_index]


## Owner died: trigger up, everything holstered, and (drop) carried weapons with ammo dropped
## as pickups. Called by Player._on_died. The drop is deferred (death can happen during a
## physics flush); until respawn the slots hold whatever wasn't dropped.
func on_owner_died(drop: bool) -> void:
	_hold = 0.0
	_hold_target = null
	_reload_on_release = false
	for w in slots:
		if w != null:
			w.release_trigger()
			w.holster()
	_zoom_blend = 0.0
	_restore_viewmodel()
	if drop and drop_weapons_on_death:
		_drop_all_on_death.call_deferred()


## Respawn: frees whatever is carried and installs starting_weapons fresh (full ammo), then
## equips the first. Called by Player.respawn_at.
func reset_loadout() -> void:
	for i in SLOT_COUNT:
		var w := slots[i]
		if w == null:
			continue
		w.holster()
		slots[i] = null
		if w.get_parent() == self:
			remove_child(w)
		w.queue_free()
	_zoom_blend = 0.0
	_restore_viewmodel()
	active_index = 0
	_melee_left = 0.0
	_hold = 0.0
	_hold_target = null
	_hold_lock = false
	_reload_on_release = false
	for i in mini(starting_weapons.size(), SLOT_COUNT):
		if starting_weapons[i] != null:
			_install(starting_weapons[i].instantiate() as Weapon, i)
	if _player != null:
		_player.look_sensitivity_scale = 1.0
	if _camera != null and _player != null:
		_camera.fov = _player.fov
	var first := _first_filled(0)
	if first >= 0:
		_equip(first)
	else:
		active_weapon_changed.emit(null)


## Puts weapon in slot (or the active slot) and returns whatever it replaced, already detached.
func give_weapon(weapon: Weapon, slot: int = -1) -> Weapon:
	if weapon == null:
		return null
	if slot < 0:
		slot = active_index if slots[active_index] != null else _first_empty()
	var old := _install(weapon, slot)
	if slot == active_index:
		_equip(slot)
	return old


## Carried weapons (non-empty slots). Pickup-carrier API, used by AmmoCrate.
func get_weapons() -> Array[Weapon]:
	var out: Array[Weapon] = []
	for w in slots:
		if w != null:
			out.append(w)
	return out


## Carried weapon with this id (WeaponPickup.weapon_id_of), or null.
func find_weapon(weapon_id: String) -> Weapon:
	if weapon_id == "":
		return null
	for w in slots:
		if w != null and WeaponPickup.weapon_id_of(w) == weapon_id:
			return w
	return null


func register_pickup(pickup: WeaponPickup) -> void:
	if not _pickups.has(pickup):
		_pickups.append(pickup)


func unregister_pickup(pickup: WeaponPickup) -> void:
	_pickups.erase(pickup)


## Best available pickup of a weapon type not already carried, or null. Halo style: favors
## what the camera looks at, weighted against distance.
func get_pickup_candidate() -> WeaponPickup:
	var best: WeaponPickup = null
	var best_score := -INF
	var origin := _camera.global_position if _camera != null else global_position
	var forward := -_camera.global_transform.basis.z if _camera != null else Vector3.ZERO
	for pickup in _pickups:
		if not is_instance_valid(pickup) or not pickup.available:
			continue
		if find_weapon(pickup.get_weapon_id()) != null and not pickup.is_battery_upgrade_for(self):
			continue
		var target := (
			pickup.pivot.global_position if pickup.pivot != null else pickup.global_position
		)
		var offset := target - origin
		var distance := offset.length()
		var facing := forward.dot(offset / distance) if distance > 0.001 else 1.0
		var score := facing - distance * pickup_distance_weight
		if score > best_score:
			best_score = score
			best = pickup
	return best


## HUD prompt text, empty when nothing can be picked up.
func get_pickup_prompt() -> String:
	var pickup := get_pickup_candidate()
	if pickup == null:
		return ""
	return "Hold %s to pick up %s" % [get_interact_label(), pickup.get_display_name()]


## Readable name of the first binding on action_interact, e.g. "E" or "Mouse 4".
func get_interact_label() -> String:
	var aim := _player.get_node_or_null("AimAssist") as AimAssist if _player else null
	if aim != null and aim.using_controller:
		for event in InputMap.action_get_events("action_interact"):
			var pad := event as InputEventJoypadButton
			if pad != null:
				return PAD_BUTTON_NAMES.get(pad.button_index, "Button %d" % pad.button_index)
	for event in InputMap.action_get_events("action_interact"):
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			continue
		var key := event as InputEventKey
		if key != null:
			var code := key.keycode
			if code == KEY_NONE:
				code = DisplayServer.keyboard_get_keycode_from_physical(key.physical_keycode)
			if code != KEY_NONE:
				return OS.get_keycode_string(code)
		var text := event.as_text().replace(" (Physical)", "")
		if text != "":
			return text
	return "Interact"


## 0..1 hold progress toward taking the current candidate.
func get_pickup_progress() -> float:
	return clampf(_hold / maxf(pickup_hold_time, 0.001), 0.0, 1.0)


func switch_weapon() -> void:
	var other := (active_index + 1) % SLOT_COUNT
	if slots[other] != null:
		_equip(other)


func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled():
		return
	var weapon := get_active()
	if (
		event.is_action_pressed("action_weapon_switch")
		or event.is_action_pressed("action_weapon_next")
		or event.is_action_pressed("action_weapon_prev")
	):
		switch_weapon()
	elif event.is_action_pressed("action_weapon_1") and slots[0] != null:
		_equip(0)
	elif event.is_action_pressed("action_weapon_2") and slots[1] != null:
		_equip(1)
	elif weapon == null:
		return
	elif event.is_action_pressed("action_fire"):
		weapon.trigger(true, true)
	elif event.is_action_released("action_fire"):
		weapon.release_trigger()
	elif event.is_action_pressed("action_alt_fire"):
		weapon.secondary_pressed()
	elif event.is_action_pressed("action_fire_select"):
		weapon.fire_select()
	elif event.is_action_pressed("action_reload"):
		if event.is_action("action_interact") and get_pickup_candidate() != null:
			_reload_on_release = true
		else:
			weapon.reload()
	elif event.is_action_released("action_reload") and _reload_on_release:
		_reload_on_release = false
		# _hold_lock is still set (cleared next physics tick) if this hold took a pickup.
		if not _hold_lock:
			weapon.reload()
	elif event.is_action_pressed("action_melee") and _melee_left <= 0.0 and weapon.data != null:
		_melee_left = weapon.data.melee_cooldown
		weapon.melee()


func _physics_process(delta: float) -> void:
	_melee_left = maxf(_melee_left - delta, 0.0)
	var weapon := get_active()
	if weapon != null:
		if _input_enabled() and Input.is_action_pressed("action_fire"):
			weapon.trigger(false, true)
		else:
			weapon.release_trigger()
	if _player != null:
		_player.view_kick = weapon.get_recoil() if weapon != null else Vector2.ZERO
	_update_zoom_fov(delta)
	_update_pickup_hold(delta)


func _update_pickup_hold(delta: float) -> void:
	var live: Array[WeaponPickup] = []
	for pickup in _pickups:
		if is_instance_valid(pickup):
			live.append(pickup)
	_pickups = live
	var held := _input_enabled() and Input.is_action_pressed("action_interact")
	if not held:
		_hold = 0.0
		_hold_lock = false
		return
	var candidate := get_pickup_candidate()
	if _hold_lock or candidate == null:
		_hold = 0.0
		return
	if candidate != _hold_target:
		_hold_target = candidate
		_hold = 0.0
	_hold += delta
	if _hold >= pickup_hold_time:
		_hold = 0.0
		_hold_lock = true
		take_pickup(candidate)


## Same weapon carried (battery swap): replace that copy. Else an empty slot: fill it and
## switch to it. Otherwise swap with the active weapon and drop it.
## Pickup-carrier API (WeaponPickup.try_pickup); also the hold-to-take path. True if taken.
func take_pickup(pickup: WeaponPickup) -> bool:
	var blocked := pickup == null or (_player != null and _player.is_dead())
	if not blocked and pickup_request_hook.is_valid():
		pickup_request_hook.call(pickup)
	if blocked or pickup_request_hook.is_valid():
		return false
	var weapon := pickup.take()
	if weapon == null:
		return false
	var same := find_weapon(WeaponPickup.weapon_id_of(weapon))
	var slot := slots.find(same) if same != null else -1
	if slot < 0:
		var empty := slots.find(null)
		if empty >= 0:
			_install(weapon, empty)
			_equip(empty)
			return true
		slot = active_index
	var old := _install(weapon, slot)
	_equip(slot)
	if old == null:
		return true
	var parent: Node = get_tree().current_scene if is_inside_tree() else null
	if parent == null and is_inside_tree():
		parent = get_tree().root
	if _player == null or parent == null:
		# Nowhere to drop it: free it rather than leak an orphan Weapon.
		old.queue_free()
		return true
	WeaponPickup.drop(old, parent, _drop_position())
	return true


## In front of the player, short of walls, on the floor. Falls back to the player's feet when
## the space ahead is blocked or there's no floor below.
func _drop_position() -> Vector3:
	var feet := _player.global_position
	var forward := -_player.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return feet
	forward = forward.normalized()
	var space := _player.get_world_3d().direct_space_state
	var chest := feet + Vector3.UP * DROP_CHEST_HEIGHT
	var ahead := PhysicsRayQueryParameters3D.create(
		chest, chest + forward * drop_distance, DROP_WORLD_MASK, [_player.get_rid()]
	)
	var distance := drop_distance
	var wall := space.intersect_ray(ahead)
	if not wall.is_empty():
		distance = chest.distance_to(wall.position) - DROP_WALL_MARGIN
	if distance < DROP_MIN_DISTANCE:
		return feet
	var point := chest + forward * distance
	var down := PhysicsRayQueryParameters3D.create(
		point, point + Vector3.DOWN * DROP_FLOOR_SEARCH, DROP_WORLD_MASK, [_player.get_rid()]
	)
	var floor_hit := space.intersect_ray(down)
	if floor_hit.is_empty() or (floor_hit.normal as Vector3).y < 0.7:
		return feet
	return floor_hit.position


## Equip slot index if it holds a weapon (net: remote weapon switches).
func select_slot(index: int) -> void:
	if index >= 0 and index < SLOT_COUNT and index != active_index:
		_equip(index)


## Net: adopt the host's loadout after a pickup. entries[i] is {} for an empty slot or
## {"id": weapon id, "scene": PackedScene, "magazine": int, "reserve": int}. A slot already
## holding that weapon id keeps its local instance (and the client's own magazine split);
## anything else is replaced with a fresh instance carrying the host's ammo. Equips active.
func apply_loadout(entries: Array, active: int) -> void:
	for i in SLOT_COUNT:
		var entry: Dictionary = entries[i] if i < entries.size() else {}
		var w := slots[i]
		if w != null and entry.get("id", "") == WeaponPickup.weapon_id_of(w):
			continue
		if w != null:
			w.holster()
			if w.zoom_changed.is_connected(_on_zoom_changed):
				w.zoom_changed.disconnect(_on_zoom_changed)
			slots[i] = null
			if w.get_parent() == self:
				remove_child(w)
			w.queue_free()
		var scene := entry.get("scene") as PackedScene
		var fresh := scene.instantiate() as Weapon if scene != null else null
		if fresh == null:
			continue
		_install(fresh, i)
		# _install's add_child ran _ready (full magazine); the host's ammo goes on after.
		fresh.magazine = int(entry.get("magazine", fresh.magazine))
		fresh.reserve = int(entry.get("reserve", fresh.reserve))
	active_index = clampi(active, 0, SLOT_COUNT - 1)
	var first := _first_filled(active_index)
	if first >= 0:
		_equip(first)
	else:
		active_weapon_changed.emit(null)


func _input_enabled() -> bool:
	if _player != null and (_player.is_dead() or _player.net_puppet):
		return false
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or DisplayServer.get_name() == "headless"


func _drop_all_on_death() -> void:
	if _player == null or not _player.is_dead() or not is_inside_tree():
		return
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	var carried: Array[Weapon] = []
	for i in SLOT_COUNT:
		var index := (active_index + i) % SLOT_COUNT
		var w := slots[index]
		if w == null or w.magazine + w.reserve <= 0:
			continue
		slots[index] = null
		if w.zoom_changed.is_connected(_on_zoom_changed):
			w.zoom_changed.disconnect(_on_zoom_changed)
		remove_child(w)
		carried.append(w)
	if carried.is_empty():
		return
	for i in carried.size():
		# One weapon drops at the feet. Two drop to either side. A typed array literal in a
		# ternary is an untyped Array, which Godot refuses to assign to Array[float].
		var side := 0.0 if carried.size() == 1 else (1.0 if i == 0 else -1.0)
		WeaponPickup.drop(carried[i], parent, _death_drop_position(side))
	if get_active() == null:
		active_weapon_changed.emit(null)


## Floor under the body, offset side x DEATH_DROP_SPREAD along its right (short of walls).
func _death_drop_position(side: float) -> Vector3:
	var feet := _player.global_position
	var space := _player.get_world_3d().direct_space_state
	var chest := feet + Vector3.UP * DROP_CHEST_HEIGHT
	var from := chest
	if side != 0.0:
		var right := _player.global_transform.basis.x
		right.y = 0.0
		right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
		var target := chest + right * side * DEATH_DROP_SPREAD
		var wall := space.intersect_ray(
			PhysicsRayQueryParameters3D.create(chest, target, DROP_WORLD_MASK)
		)
		if wall.is_empty():
			from = target
		else:
			var reach := maxf(chest.distance_to(wall.position) - DROP_WALL_MARGIN, 0.0)
			from = chest + right * side * reach
	var down := PhysicsRayQueryParameters3D.create(
		from, from + Vector3.DOWN * DROP_FLOOR_SEARCH, DROP_WORLD_MASK
	)
	var floor_hit := space.intersect_ray(down)
	if floor_hit.is_empty():
		return Vector3(from.x, feet.y, from.z)
	return floor_hit.position


## Swaps weapon into slot without equipping. Returns the detached previous weapon.
func _install(weapon: Weapon, slot: int) -> Weapon:
	var old := slots[slot]
	if old != null:
		old.holster()
		if old.zoom_changed.is_connected(_on_zoom_changed):
			old.zoom_changed.disconnect(_on_zoom_changed)
		remove_child(old)
	weapon.camera = _camera
	weapon.player = _player
	weapon.aim_assist = null
	if use_aim_assist and _player != null:
		weapon.aim_assist = _player.get_node_or_null("AimAssist") as AimAssist
	add_child(weapon)
	weapon.zoom_changed.connect(_on_zoom_changed)
	slots[slot] = weapon
	weapon.holster()
	return old


func _equip(index: int) -> void:
	if index < 0 or slots[index] == null:
		return
	var current := get_active()
	if current != null and index != active_index:
		current.holster()
	active_index = index
	# A new weapon never inherits the previous one's overlay fade.
	_zoom_blend = 0.0
	_restore_viewmodel()
	slots[index].equip()
	active_weapon_changed.emit(slots[index])


func _on_owner_damaged(_amount: float) -> void:
	var weapon := get_active()
	if weapon != null:
		weapon.set_zoom(false)


func _on_zoom_changed(zoomed_now: bool) -> void:
	# Unzoom shows the viewmodel at once. Every detach path (switch, pickup swap, loadout,
	# death drop, respawn) holsters first, so this runs before a weapon leaves the holder.
	if not zoomed_now:
		_zoom_blend = 0.0
		_restore_viewmodel()
	if _player == null:
		return
	var weapon := get_active()
	var zoomed := weapon != null and weapon.data != null and weapon.zoomed
	# A scale, not a write to mouse_sensitivity, so runtime settings changes survive zoom.
	_player.look_sensitivity_scale = weapon.data.zoom_sensitivity if zoomed else 1.0


func _update_zoom_fov(delta: float) -> void:
	if _camera == null or _player == null:
		return
	var weapon := get_active()
	var target := _player.fov
	var blend_time := 0.1
	if weapon != null and weapon.data == null:
		weapon = null
	if weapon != null:
		blend_time = maxf(weapon.data.zoom_time, 0.001)
		if weapon.zoomed:
			target = weapon.get_zoom_fov(_player.fov)
	var zoom_fov := weapon.get_zoom_fov(_player.fov) if weapon != null else _player.fov
	var step := absf(_player.fov - zoom_fov)
	_camera.fov = move_toward(_camera.fov, target, maxf(step, 1.0) / blend_time * delta)
	var scoped := (
		weapon != null
		and weapon.zoomed
		and weapon.data.scope_style != WeaponData.ScopeStyle.NONE
	)
	# Fade in over zoom_time; snap off on unzoom (the viewmodel is already back).
	_zoom_blend = move_toward(_zoom_blend, 1.0, delta / blend_time) if scoped else 0.0
	# Local player only: puppets have no HUD and their holder is hidden anyway.
	if scoped and _zoom_blend >= 0.5 and not _player.net_puppet:
		_hide_viewmodel(weapon)
	elif _hidden_viewmodel != null:
		_restore_viewmodel()


## Scope overlay opacity, 0 (hip) to 1 (fully scoped). Rises with the FOV blend (zoom_time),
## drops to 0 the frame zoom ends.
func get_zoom_blend() -> float:
	return _zoom_blend


## Hide the scoped weapon's viewmodel by moving its meshes onto Player.HIDDEN_BODY_LAYER,
## which the local camera culls. Never touches weapon.visible (it gates Weapon physics) or
## holder.visible (puppet state). Lights and particles that aren't GeometryInstance3D are left.
func _hide_viewmodel(weapon: Weapon) -> void:
	if _hidden_viewmodel == weapon:
		return
	_restore_viewmodel()
	_hidden_viewmodel = weapon
	_collect_hidden(weapon)


func _collect_hidden(node: Node) -> void:
	for child in node.get_children():
		var geo := child as GeometryInstance3D
		if geo != null:
			_hidden_layers[geo] = geo.layers
			geo.layers = Player.HIDDEN_BODY_LAYER
		_collect_hidden(child)


func _restore_viewmodel() -> void:
	for key: Variant in _hidden_layers.keys():
		if is_instance_valid(key):
			var geo := key as GeometryInstance3D
			if geo != null:
				geo.layers = int(_hidden_layers[key])
	_hidden_layers.clear()
	_hidden_viewmodel = null


func _first_filled(start: int) -> int:
	for i in SLOT_COUNT:
		var index := (start + i) % SLOT_COUNT
		if slots[index] != null:
			return index
	return -1


func _first_empty() -> int:
	for i in SLOT_COUNT:
		if slots[i] == null:
			return i
	return active_index
