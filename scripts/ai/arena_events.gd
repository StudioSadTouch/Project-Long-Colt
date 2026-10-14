class_name ArenaEvents
extends Node
## Arena event bus and shared helpers. One per arena scene (group "arena_events").
##   gunfire   every player and bot shot; bots hear it inside BotDifficulty.hearing_radius.
##   kill      emitted by SpawnManager when a kill is resolved.
## Also tracks live WeaponPickups (placed and dropped) for bots, and the last hit on each victim
## so SpawnManager can credit player deaths (Player resets its HealthShield inside the died
## signal, before Weapon emits hit_confirmed, so credit is resolved deferred).

signal gunfire(source: Node3D, position: Vector3)
signal kill(killer: Node, victim: Node, info: Dictionary)

const GROUP := &"arena_events"
const PLAYER_HOLDER_PATH := ^"Head/Camera3D/WeaponHolder"
const PLAYER_EYE_PATH := ^"Head/Camera3D"
const BODY_HEIGHT := 0.9

## victim instance id -> {"source": Node, "frame": int, "info": Dictionary}
var _last_hit: Dictionary = {}
var _pickups: Array[WeaponPickup] = []
## Instance ids already connected (bound callables make is_connected unreliable).
var _watched: Dictionary = {}


static func find(tree: SceneTree) -> ArenaEvents:
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as ArenaEvents


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_scan.call_deferred(get_tree().current_scene)


## Hooks the player's weapons (current and future) into gunfire and hit tracking.
func track_player(player: Player) -> void:
	var holder := player.get_node_or_null(PLAYER_HOLDER_PATH) as WeaponHolder
	if holder == null:
		push_warning("ArenaEvents: player has no WeaponHolder")
		return
	for w in holder.slots:
		watch_weapon(w, player)
	if not _watched.has(holder.get_instance_id()):
		_watched[holder.get_instance_id()] = true
		holder.active_weapon_changed.connect(_on_player_weapon_changed.bind(player))


## Connect a weapon's fired / hit_confirmed signals. Safe to call repeatedly.
func watch_weapon(weapon: Weapon, shooter: Node3D) -> void:
	if weapon == null or _watched.has(weapon.get_instance_id()):
		return
	_watched[weapon.get_instance_id()] = true
	weapon.fired.connect(_on_weapon_fired.bind(shooter))
	weapon.hit_confirmed.connect(record_hit)


func report_gunfire(source: Node3D) -> void:
	if source != null and source.is_inside_tree():
		gunfire.emit(source, source.global_position)


func record_hit(target: Object, info: Dictionary) -> void:
	var node := target as Node
	if node == null:
		return
	_last_hit[node.get_instance_id()] = {
		"source": info.get("source"),
		"frame": Engine.get_physics_frames(),
		"info": info,
	}


## The shooter whose hit landed on victim during this or the previous physics frame, or null.
func recent_attacker(victim: Node) -> Node:
	var entry: Dictionary = _last_hit.get(victim.get_instance_id(), {})
	if entry.is_empty() or Engine.get_physics_frames() - int(entry.frame) > 1:
		return null
	var source: Variant = entry.source
	if source is Node and is_instance_valid(source):
		return source
	return null


func recent_hit_info(victim: Node) -> Dictionary:
	var entry: Dictionary = _last_hit.get(victim.get_instance_id(), {})
	return entry.get("info", {})


func get_pickups() -> Array[WeaponPickup]:
	_pickups = _pickups.filter(func(p: WeaponPickup) -> bool: return is_instance_valid(p))
	return _pickups


# ------------------------------------------------------------------ shared static helpers


static func team_of(node: Node) -> int:
	if node == null:
		return -1
	if "team" in node:
		return int(node.get("team"))
	return int(node.get_meta(&"team", 0))


static func is_hostile(a: Node, b: Node) -> bool:
	return a != null and b != null and a != b and team_of(a) != team_of(b)


static func is_alive(node: Node) -> bool:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return false
	if node.has_method("is_dead"):
		return not node.call("is_dead")
	var health := node.get_node_or_null(^"HealthShield") as HealthShield
	return (health == null or not health.dead) and (node as Node3D).is_visible_in_tree()


## {"body": Vector3, "head"?: Vector3} in world space. Uses get_aim_points() when present
## (bots, dummies), otherwise the capsule centre.
static func aim_points_of(node: Node3D) -> Dictionary:
	if node.has_method("get_aim_points"):
		var points: Dictionary = node.call("get_aim_points")
		if not points.is_empty():
			return points
		return {}
	return {"body": node.global_position + Vector3.UP * BODY_HEIGHT}


static func eye_of(node: Node3D) -> Vector3:
	if node.has_method("get_eye_position"):
		return node.call("get_eye_position")
	var cam := node.get_node_or_null(PLAYER_EYE_PATH) as Node3D
	if cam != null:
		return cam.global_position
	return node.global_position + Vector3.UP * 1.6


static func velocity_of(node: Node3D) -> Vector3:
	var body := node as CharacterBody3D
	return body.velocity if body != null else Vector3.ZERO


# ------------------------------------------------------------------ internals


func _on_player_weapon_changed(weapon: Weapon, player: Player) -> void:
	watch_weapon(weapon, player)


func _on_weapon_fired(shooter: Node3D) -> void:
	report_gunfire(shooter)


func _scan(root: Node) -> void:
	if root == null:
		return
	if root is WeaponPickup and not _pickups.has(root):
		_pickups.append(root)
	for child in root.get_children():
		_scan(child)


func _on_node_added(node: Node) -> void:
	if node is WeaponPickup and not _pickups.has(node):
		_pickups.append(node)
