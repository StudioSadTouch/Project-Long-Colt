class_name NetPickups
extends RefCounted
## Keys and state for weapon pickups, ammo crates and grenade pickups across peers. Placed
## pickups are keyed by their path from the arena root (identical on every peer). Weapons and
## grenades dropped at runtime exist only where the host spawned them, so the host names them
## "drop/<n>" and NetMatch tells the clients to build a matching pickup (spawn_drop). Clients
## never change pickup state themselves (is_authority() on each pickup); they mirror the host's
## availability. A grenade pickup's state is its grenade count (0 = gone) instead of a bool.

const DROP_PREFIX := "drop/"
## Drop messages for grenades carry this before the GrenadeData path where weapons carry a scene.
const GRENADE_TAG := "grenade:"

var root: Node
## key -> WeaponPickup / AmmoCrate / GrenadePickup
var nodes: Dictionary = {}

var _next_drop: int = 1


func _init(arena_root: Node) -> void:
	root = arena_root


## Placed pickups and crates now in the scene.
func scan() -> void:
	for node in root.find_children("*", "Node3D", true, false):
		if (
			(node is WeaponPickup and not (node as WeaponPickup).dropped)
			or (node is GrenadePickup and not (node as GrenadePickup).dropped)
			or node is AmmoCrate
		):
			nodes[str(root.get_path_to(node))] = node


func key_of(node: Node) -> String:
	if node == null:
		return ""
	return str(
		node.get_meta(&"net_key", root.get_path_to(node) if root.is_ancestor_of(node) else "")
	)


func find(key: String) -> Node3D:
	# A taken or despawned drop is freed in place. `is` on a freed object errors, so the
	# validity check has to come first (same rule as NetMatch entity lookups).
	var node: Variant = nodes.get(key)
	if is_instance_valid(node) and node is Node3D:
		return node
	nodes.erase(key)
	return null


## Host: name a fresh drop (WeaponPickup or GrenadePickup). Returns its spawn message: weapons
## [key, scene, pos, magazine, reserve, heat], grenades [key, GRENADE_TAG + data, pos, count].
func register_drop(pickup: Node3D) -> Array:
	var key := "%s%d" % [DROP_PREFIX, _next_drop]
	_next_drop += 1
	pickup.set_meta(&"net_key", key)
	nodes[key] = pickup
	return describe_drop(pickup)


func describe_drop(pickup: Node3D) -> Array:
	if pickup is GrenadePickup:
		var grenades := pickup as GrenadePickup
		if grenades.grenade == null or grenades.remaining <= 0:
			return []
		return [
			key_of(grenades),
			GRENADE_TAG + grenades.grenade.resource_path,
			grenades.global_position,
			grenades.remaining,
		]
	if not pickup is WeaponPickup:
		return []
	var weapon := (pickup as WeaponPickup).weapon
	if weapon == null:
		return []
	return [
		key_of(pickup),
		weapon.scene_file_path,
		pickup.global_position,
		weapon.magazine,
		weapon.reserve,
		NetWeapon.heat_entry(weapon),
	]


## Host: key -> available (grenade pickups: grenades left), for every live pickup (drops
## included).
func state() -> Dictionary:
	var out := {}
	for key: String in nodes.keys():
		var node := find(key)
		if node is GrenadePickup:
			var grenades := node as GrenadePickup
			out[key] = grenades.remaining if grenades.available else 0
		elif node != null:
			out[key] = bool(node.get(&"available"))
	return out


## Host: every live drop's spawn message (late join).
func drops() -> Array:
	var out: Array = []
	for key: String in nodes.keys():
		var node := find(key)
		if (node is WeaponPickup or node is GrenadePickup) and key.begins_with(DROP_PREFIX):
			var message := describe_drop(node)
			if not message.is_empty():
				out.append(message)
	return out


## Client: mirror availability; a live drop the host no longer has is removed.
func apply_state(available: Dictionary) -> void:
	for key: String in available:
		var node := find(key)
		if node is GrenadePickup:
			(node as GrenadePickup).net_set_remaining(int(available[key]))
		elif node != null and node.has_method(&"net_set_available"):
			node.call(&"net_set_available", bool(available[key]))
	for key: String in nodes.keys():
		if key.begins_with(DROP_PREFIX) and not available.has(key):
			remove(key)


## Client: build the host's drop locally.
func spawn_drop(message: Array) -> void:
	if message.size() < 4 or not message[2] is Vector3 or find(str(message[0])) != null:
		return
	if str(message[1]).begins_with(GRENADE_TAG):
		_spawn_grenade_drop(message)
		return
	if message.size() < 6:
		return
	var scene := NetWeapon.scene_of(str(message[1]))
	var weapon := scene.instantiate() as Weapon if scene != null else null
	if weapon == null:
		return
	# For prompts only: this weapon never entered a tree, so its _ready would refill it if
	# installed. Clients never install it; the host's loadout message carries the real ammo.
	weapon.magazine = int(message[3])
	weapon.reserve = int(message[4])
	if message[5] is Dictionary:
		NetWeapon.apply_heat(weapon, message[5])
	var pickup := WeaponPickup.drop(weapon, root, message[2])
	pickup.set_meta(&"net_key", str(message[0]))
	nodes[str(message[0])] = pickup


func _spawn_grenade_drop(message: Array) -> void:
	var path := str(message[1]).trim_prefix(GRENADE_TAG)
	var data: GrenadeData = load(path) as GrenadeData if ResourceLoader.exists(path) else null
	var count := int(message[3])
	if data == null or count <= 0:
		return
	var pickup := GrenadePickup.drop(data, count, root, message[2])
	pickup.set_meta(&"net_key", str(message[0]))
	nodes[str(message[0])] = pickup


func remove(key: String) -> void:
	var node := find(key)
	nodes.erase(key)
	if node == null:
		return
	if key.begins_with(DROP_PREFIX):
		node.queue_free()
	elif node is GrenadePickup:
		(node as GrenadePickup).net_set_remaining(0)
	elif node.has_method(&"net_set_available"):
		node.call(&"net_set_available", false)
