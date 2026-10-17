class_name GameRules
extends Node
## Applies a GameModes entry to the arena it is added under (NetMatch adds it first thing in its
## _ready, on every peer, so host and clients agree on loadouts and on which pickups exist).
##
## Combatants are patched by component, not by body: every WeaponHolder (players, net puppets)
## and Bot gets the mode's starting weapons, every HealthShield loses its shield when the mode
## has none. Bodies already in the arena are patched and reset; anything added later (bots from
## SpawnManager, puppets, respawned bots) is caught on SceneTree.node_added, which fires before
## the node's _ready, so it spawns with the mode's loadout and shield from its first frame.
## Respawns need nothing: WeaponHolder.reset_loadout / Bot._give_starting_weapons read the
## patched starting_weapons and HealthShield.reset the patched max_shield.

var mode_id: String = GameModes.DEFAULT_ID

var _start_weapons: Array[PackedScene] = []
var _override_weapons: bool = false
var _shields: bool = true
var _power_weapons: bool = true
var _infinite_ammo: bool = false
var _refill_left: float = 0.0


static func create(id: String) -> GameRules:
	var rules := GameRules.new()
	rules.name = "GameRules"
	rules.mode_id = GameModes.sanitize(id)
	return rules


func _enter_tree() -> void:
	var mode := GameModes.get_mode(mode_id)
	_override_weapons = mode.has("start_weapons")
	_start_weapons.clear()
	for path: String in mode.get("start_weapons", []):
		var scene := load(path) as PackedScene
		if scene != null:
			_start_weapons.append(scene)
	_shields = bool(mode.get("shields", true))
	_power_weapons = bool(mode.get("power_weapons", true))
	_infinite_ammo = bool(mode.get("infinite_ammo", false))
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	var arena := get_parent().get_parent() if get_parent() != null else null
	if arena != null:
		_apply_existing(arena)


## Here, not in _enter_tree: Godot switches physics processing on just before _ready for any
## script with a _physics_process, which undid an earlier set_physics_process(false) and gave
## every mode the Weapon Range refill.
func _ready() -> void:
	set_physics_process(_infinite_ammo)


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


## infinite_ammo (Weapon Range): every half second, on every peer, carried reserves go back to
## full, an emptied battery (the hammer) recharges, and grenades top up. The host's copy is
## the real one; clients do the same so their HUD never shows a dry gun in between.
func _physics_process(delta: float) -> void:
	_refill_left -= delta
	if _refill_left > 0.0:
		return
	_refill_left = 0.5
	for group: StringName in [&"player", &"bot"]:
		for body in get_tree().get_nodes_in_group(group):
			var carrier: Node = body
			if body is Player:
				carrier = (body as Player).get_weapon_holder()
			if carrier != null and carrier.has_method(&"get_weapons"):
				for weapon: Weapon in carrier.call(&"get_weapons"):
					_refill(weapon)
			var thrower := body.get_node_or_null(^"GrenadeThrower") as GrenadeThrower
			if thrower != null:
				for i in thrower.counts.size():
					thrower.add(i, thrower.max_count)


static func _refill(weapon: Weapon) -> void:
	if weapon == null or weapon.data == null:
		return
	var data := weapon.data
	if data.battery:
		if weapon.magazine <= 0:
			weapon.magazine = data.magazine_size
			weapon.ammo_changed.emit(weapon.magazine, weapon.reserve)
	elif weapon.reserve < data.reserve_max:
		weapon.add_ammo(data.reserve_max - weapon.reserve)


func is_default() -> bool:
	return not _override_weapons and _shields and _power_weapons


## True if weapon_scene's WeaponData is flagged as a power weapon.
static func is_power_weapon(weapon_scene: PackedScene) -> bool:
	var data := WeaponData.of_scene(weapon_scene)
	return data != null and data.power_weapon


func _apply_existing(arena: Node) -> void:
	if is_default():
		return
	for node in arena.find_children("*", "", true, false):
		if not _power_weapons and _is_placed_power_pickup(node):
			# Deferred: the arena is mid-_ready and refuses remove_child. Queued before
			# NetMatch's deferred pickup scan, so NetPickups never keys it.
			_remove.call_deferred(node)
			continue
		_patch(node, node.is_node_ready())


func _on_node_added(node: Node) -> void:
	if is_default():
		return
	if not _power_weapons and _is_placed_power_pickup(node):
		# A placed pickup appearing mid-match (none today).
		_remove.call_deferred(node)
		return
	_patch(node, false)


## reset: the node already ran _ready, so re-run its spawn setup with the new values.
func _patch(node: Node, reset: bool) -> void:
	if node is WeaponHolder and _override_weapons:
		var holder := node as WeaponHolder
		holder.starting_weapons = _start_weapons.duplicate()
		if reset:
			holder.reset_loadout()
	elif node is Bot and _override_weapons:
		var bot := node as Bot
		bot.starting_weapons = _start_weapons.duplicate()
		if reset:
			bot.reset_starting_weapons()
	elif node is HealthShield and not _shields:
		var health := node as HealthShield
		health.max_shield = 0.0
		if reset:
			health.reset()


## Out of the tree at once (not just queued), so tree scans never see it again.
func _remove(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.queue_free()


static func _is_placed_power_pickup(node: Node) -> bool:
	if not node is WeaponPickup:
		return false
	var pickup := node as WeaponPickup
	return not pickup.dropped and is_power_weapon(pickup.weapon_scene)
