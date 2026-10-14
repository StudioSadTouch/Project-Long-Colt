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
## The Area3D sits on the Pickup layer (7), masks only Player (2), and is not monitorable.
## Weapon rays use HIT_MASK (1 | 4 | Hitbox 6), so bullets and the melee sweep never see it.

const SCENE_PATH := "res://scenes/pickups/weapon_pickup.tscn"
const BOB_HEIGHT := 0.08
const BOB_SPEED := 2.0
const SPIN_SPEED := 0.6

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
var _holders: Array[WeaponHolder] = []

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


## Called by WeaponHolder when interact is held long enough. Returns the weapon to equip.
func take() -> Weapon:
	if not available or weapon == null:
		return null
	var taken := weapon
	weapon = null
	_consume()
	return taken


func _physics_process(delta: float) -> void:
	_time += delta
	pivot.position.y = 0.45 + sin(_time * BOB_SPEED) * BOB_HEIGHT
	pivot.rotation.y += SPIN_SPEED * delta
	if available:
		for holder in _holders:
			if is_instance_valid(holder):
				_try_ammo(holder)


func _try_ammo(holder: WeaponHolder) -> void:
	if weapon == null or weapon.data == null:
		return
	var carried := holder.find_weapon(get_weapon_id())
	if carried == null:
		return
	if dropped:
		var offered := weapon.reserve + weapon.magazine
		var added := carried.add_ammo(offered)
		if added <= 0:
			return
		var from_reserve := mini(added, weapon.reserve)
		weapon.reserve -= from_reserve
		weapon.magazine -= added - from_reserve
		if weapon.reserve + weapon.magazine <= 0:
			_consume()
		return
	var amount := ammo_amount if ammo_amount >= 0 else weapon.data.magazine_size
	if carried.add_ammo(amount) > 0:
		_consume()


func _consume() -> void:
	available = false
	pivot.visible = false
	for holder in _holders:
		if is_instance_valid(holder):
			holder.unregister_pickup(self)
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
	for holder in _holders:
		if is_instance_valid(holder):
			holder.register_pickup(self)


func _on_despawn() -> void:
	if available:
		_consume()


func _on_body_entered(body: Node3D) -> void:
	var holder := _holder_of(body)
	if holder == null or _holders.has(holder):
		return
	_holders.append(holder)
	if available:
		holder.register_pickup(self)


func _on_body_exited(body: Node3D) -> void:
	var holder := _holder_of(body)
	if holder == null:
		return
	_holders.erase(holder)
	holder.unregister_pickup(self)


func _holder_of(body: Node3D) -> WeaponHolder:
	if not body is Player:
		return null
	return body.find_child("WeaponHolder", true, false) as WeaponHolder


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
