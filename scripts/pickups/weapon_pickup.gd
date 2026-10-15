class_name WeaponPickup
extends Node3D
## Halo-style weapon on the ground. Walk over it to top up reserve ammo if you carry the same
## weapon (matched by WeaponData resource_path). Hold interact to take it: fills an empty slot,
## otherwise swaps with your active weapon, which drops here as a new pickup.
##
## Placed pickups (weapon_scene set in the level) respawn after respawn_delay.
## Dropped pickups carry the live Weapon node (magazine and reserve intact), never respawn,
## and despawn after despawn_time.
##
## Walk-over ammo: a placed pickup gives ammo_amount rounds (default one magazine) and is
## consumed only if any ammo was actually added. A dropped pickup hands over its own
## reserve then magazine and disappears only once it's empty (Halo behavior).
##
## The Area3D sits on the Pickup layer (7), masks Player (2) and Enemy (4), and is not
## monitorable. Weapon rays use HIT_MASK (1 | 4 | Hitbox 6), so bullets and melee never see it.
##
## Carriers (public API, not tied to Player or input; bots use the same calls as the player):
## a carrier is whatever holds the weapons. Duck-typed:
##   find_weapon(weapon_id: String) -> Weapon   required (WeaponHolder, Bot)
##   get_weapons() -> Array                     carried Weapons, for AmmoCrate
##   register_pickup(p) / unregister_pickup(p)  optional: told when an available pickup is in
##                                              reach (WeaponHolder's hold-to-take list)
##   take_pickup(p) -> bool                     optional: install p.take(); used by try_pickup
## carrier_of(body) finds the carrier for a body entering the trigger: walking up from the
## body, a node with get_pickup_carrier() (Player -> its WeaponHolder, null while dead) or a
## node in group CARRIER_GROUP (skipped while is_dead()). Carriers in reach get walk-over ammo
## automatically every physics tick; can_take / take / ammo_for / give_ammo / is_useful_to /
## is_in_reach / try_pickup let an AI decide and act without touching privates.
##
## Networking: the host (or offline play: multiplayer.is_server() is true) owns pickups. On a
## net client walk-over ammo, take() and despawn do nothing; the host's NetMatch mirrors
## availability with net_set_available() and spawns / frees dropped pickups.

const SCENE_PATH := "res://scenes/pickups/weapon_pickup.tscn"
const BOB_HEIGHT := 0.08
const BOB_SPEED := 2.0
const SPIN_SPEED := 0.6
const CARRIER_GROUP := &"pickup_carrier"
## How many ancestors carrier_of() climbs from the touching collider.
const CARRIER_SEARCH_DEPTH := 4

## Placed pickups: the weapon scene to spawn. Leave empty for dropped pickups.
@export var weapon_scene: PackedScene
@export var respawn_delay: float = 30.0
## Rounds given on walk-over by a placed pickup. Negative = one magazine of that weapon.
@export var ammo_amount: int = -1
## Dropped pickups only. 0 = never despawn.
@export var despawn_time: float = 45.0

## The live weapon this pickup hands out. Created from weapon_scene, or set by drop().
var weapon: Weapon
var available: bool = true
var dropped: bool = false

var _time: float = 0.0
var _visual: Node3D
## Carrier -> number of its bodies inside the trigger (a Player has a capsule and a Hurtbox).
var _carriers: Dictionary = {}
## Body inside the trigger -> its carrier (exit lookup works even while the owner is dead).
var _bodies: Dictionary = {}

@onready var area: Area3D = $Area
@onready var pivot: Node3D = $Pivot


## Spawns a dropped pickup for weapon at position, parented to parent.
static func drop(dropped_weapon: Weapon, parent: Node, at: Vector3) -> WeaponPickup:
	var pickup := (load(SCENE_PATH) as PackedScene).instantiate() as WeaponPickup
	pickup.weapon = dropped_weapon
	pickup.dropped = true
	parent.add_child(pickup)
	pickup.global_position = at
	return pickup


func _ready() -> void:
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	if weapon == null and weapon_scene != null:
		weapon = weapon_scene.instantiate() as Weapon
	_build_visual()
	if dropped and despawn_time > 0.0:
		get_tree().create_timer(despawn_time, false).timeout.connect(_on_despawn)


func _notification(what: int) -> void:
	# A weapon still held here when the pickup is freed was never taken; it's out of the tree.
	if what == NOTIFICATION_PREDELETE:
		if is_instance_valid(weapon) and weapon.get_parent() == null:
			weapon.free()


func get_display_name() -> String:
	if weapon == null or weapon.data == null:
		return "weapon"
	return weapon.data.display_name


func get_weapon_id() -> String:
	return weapon_id_of(weapon)


static func weapon_id_of(w: Weapon) -> String:
	if w == null:
		return ""
	if w.data != null and w.data.resource_path != "":
		return w.data.resource_path
	return w.scene_file_path


## The carrier for a body touching a pickup trigger, or null. See the class comment.
static func carrier_of(body: Node) -> Object:
	var node := body
	for _i in CARRIER_SEARCH_DEPTH:
		if node == null:
			return null
		if node.has_method(&"get_pickup_carrier"):
			return node.call(&"get_pickup_carrier")
		if node.is_in_group(CARRIER_GROUP):
			if node.has_method(&"is_dead") and node.call(&"is_dead"):
				return null
			return node
		node = node.get_parent()
	return null


## A weapon is here to take.
func can_take() -> bool:
	return available and weapon != null


## Rounds walk-over would add to carrier right now (0: not carried, full, or unavailable).
func ammo_for(carrier: Object) -> int:
	var carried := _carried_match(carrier)
	if carried == null or carried.data == null:
		return 0
	var space := carried.data.reserve_max - carried.reserve
	var offered := _ammo_offered()
	return clampi(mini(offered, space), 0, offered)


## Walk-over ammo (rules in the class comment). Returns rounds added; may consume the pickup.
func give_ammo(carrier: Object) -> int:
	if not is_authority():
		return 0
	var carried := _carried_match(carrier)
	if carried == null:
		return 0
	if dropped:
		var offered := weapon.reserve + weapon.magazine
		var added := carried.add_ammo(offered)
		if added <= 0:
			return 0
		var from_reserve := mini(added, weapon.reserve)
		weapon.reserve -= from_reserve
		weapon.magazine -= added - from_reserve
		if weapon.reserve + weapon.magazine <= 0:
			_consume()
		return added
	var amount := ammo_amount if ammo_amount >= 0 else weapon.data.magazine_size
	var given := carried.add_ammo(amount)
	if given > 0:
		_consume()
	return given


## Worth going for: a weapon the carrier doesn't have, or ammo it can take.
func is_useful_to(carrier: Object) -> bool:
	if not can_take() or carrier == null:
		return false
	return _find(carrier, get_weapon_id()) == null or ammo_for(carrier) > 0


## carrier has a body inside the trigger.
func is_in_reach(carrier: Object) -> bool:
	return carrier != null and _carriers.has(carrier)


## In reach: top up if carried (true if any ammo moved), else hand the weapon to
## carrier.take_pickup(self) when it has one. False otherwise.
func try_pickup(carrier: Object) -> bool:
	if not can_take() or not is_in_reach(carrier):
		return false
	if _find(carrier, get_weapon_id()) != null:
		return give_ammo(carrier) > 0
	if carrier.has_method(&"take_pickup"):
		return bool(carrier.call(&"take_pickup", self))
	return false


## Hands over the weapon (the caller installs it) and consumes the pickup. Used by
## WeaponHolder.take_pickup and by bots.
func take() -> Weapon:
	if not available or weapon == null or not is_authority():
		return null
	var taken := weapon
	weapon = null
	_consume()
	return taken


## Pickup state changes happen here: offline, or on the net host.
func is_authority() -> bool:
	return not is_inside_tree() or multiplayer.is_server()


## Net client: mirror the host's availability (no timers, no weapon changes).
func net_set_available(on: bool) -> void:
	if on == available:
		return
	available = on
	pivot.visible = on
	var method := &"register_pickup" if on else &"unregister_pickup"
	for carrier: Object in _carriers.keys():
		if is_instance_valid(carrier) and carrier.has_method(method):
			carrier.call(method, self)


func _physics_process(delta: float) -> void:
	_time += delta
	pivot.position.y = 0.45 + sin(_time * BOB_SPEED) * BOB_HEIGHT
	pivot.rotation.y += SPIN_SPEED * delta
	if not available or not is_authority():
		return
	for carrier: Object in _carriers.keys():
		if not available:
			return
		if is_instance_valid(carrier):
			give_ammo(carrier)
		else:
			_carriers.erase(carrier)


func _carried_match(carrier: Object) -> Weapon:
	if not available or weapon == null or weapon.data == null:
		return null
	return _find(carrier, get_weapon_id())


static func _find(carrier: Object, weapon_id: String) -> Weapon:
	if carrier == null or not is_instance_valid(carrier) or not carrier.has_method(&"find_weapon"):
		return null
	return carrier.call(&"find_weapon", weapon_id) as Weapon


func _ammo_offered() -> int:
	if dropped:
		return weapon.reserve + weapon.magazine
	return ammo_amount if ammo_amount >= 0 else weapon.data.magazine_size


func _consume() -> void:
	available = false
	pivot.visible = false
	for carrier: Object in _carriers.keys():
		if is_instance_valid(carrier) and carrier.has_method(&"unregister_pickup"):
			carrier.call(&"unregister_pickup", self)
	if dropped or weapon_scene == null:
		queue_free()
		return
	if is_instance_valid(weapon):
		weapon.free()
	weapon = null
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	weapon = weapon_scene.instantiate() as Weapon
	available = true
	pivot.visible = true
	for carrier: Object in _carriers.keys():
		if is_instance_valid(carrier) and carrier.has_method(&"register_pickup"):
			carrier.call(&"register_pickup", self)


func _on_despawn() -> void:
	if available and is_authority():
		_consume()


func _on_body_entered(body: Node3D) -> void:
	var carrier := carrier_of(body)
	if carrier == null or _bodies.has(body):
		return
	_bodies[body] = carrier
	var count: int = _carriers.get(carrier, 0)
	_carriers[carrier] = count + 1
	if count == 0 and available and carrier.has_method(&"register_pickup"):
		carrier.call(&"register_pickup", self)


func _on_body_exited(body: Node3D) -> void:
	if not _bodies.has(body):
		return
	var carrier: Object = _bodies[body]
	_bodies.erase(body)
	var count: int = _carriers.get(carrier, 1) - 1
	if count > 0:
		_carriers[carrier] = count
		return
	_carriers.erase(carrier)
	if is_instance_valid(carrier) and carrier.has_method(&"unregister_pickup"):
		carrier.call(&"unregister_pickup", self)


## Visual-only copy of the weapon scene: the script is stripped, so no weapon logic runs.
func _build_visual() -> void:
	if _visual != null:
		_visual.queue_free()
		_visual = null
	var path := ""
	if weapon != null:
		path = weapon.scene_file_path
	elif weapon_scene != null:
		path = weapon_scene.resource_path
	if path == "":
		return
	var copy := (load(path) as PackedScene).instantiate() as Node3D
	copy.set_script(null)
	# Placeholder hands and the reload rig are first-person only.
	for node in copy.find_children("*", "", true, false):
		if node.is_in_group(&"viewmodel_only"):
			node.get_parent().remove_child(node)
			node.free()
	copy.transform = Transform3D(Basis().scaled(Vector3.ONE * 2.0), Vector3.ZERO)
	pivot.add_child(copy)
	_visual = copy
