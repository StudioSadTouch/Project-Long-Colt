class_name OrtaTracker
extends LogicNodeBase
## Monitors New Ottoman enemy squads for campaign encounters (casualties, leader status, wipe).

signal on_squad_wiped()
signal on_half_casualties()
signal on_leader_killed()

@export var squad_id: String = ""

var _initial_count: int = 0
var _tracked_enemies: Array[Node] = []
var _half_emitted: bool = false
var _wiped_emitted: bool = false


func _init() -> void:
	super._init()
	display_name = "Orta Tracker"


func _ready() -> void:
	super._ready()
	if not has_meta(&"editor_mode") or not bool(get_meta(&"editor_mode")):
		# Wait for scene nodes to finish spawning
		call_deferred(&"_find_and_track_squad")


func get_node_color() -> Color:
	return Color(0.95, 0.25, 0.15, 0.85)


func get_input_actions() -> Array[String]:
	return ["check_status", "alert_squad"]


func get_output_signals() -> Array[String]:
	return ["on_squad_wiped", "on_half_casualties", "on_leader_killed"]


func _find_and_track_squad() -> void:
	_tracked_enemies.clear()
	var all_enemies := get_tree().get_nodes_in_group(&"enemies")
	for e in all_enemies:
		if squad_id.is_empty() or (e.has_meta(&"squad_id") and str(e.get_meta(&"squad_id")) == squad_id):
			_tracked_enemies.append(e)
			if e.has_signal(&"died"):
				e.connect(&"died", _on_enemy_died.bind(e))

	_initial_count = _tracked_enemies.size()


func _on_enemy_died(enemy: Node) -> void:
	_tracked_enemies.erase(enemy)
	var remaining := _tracked_enemies.size()

	# Check leader death (Aga, Corbaci, Bolukbasi)
	if enemy.has_meta(&"is_leader") and bool(enemy.get_meta(&"is_leader")):
		on_leader_killed.emit()
	elif enemy.name.to_lower().contains("aga") or enemy.name.to_lower().contains("corbaci"):
		on_leader_killed.emit()

	# Half casualties
	if not _half_emitted and _initial_count > 1 and remaining <= (_initial_count / 2):
		_half_emitted = true
		on_half_casualties.emit()

	# Squad wiped
	if not _wiped_emitted and remaining == 0:
		_wiped_emitted = true
		on_squad_wiped.emit()


func check_status() -> void:
	var living := 0
	for e in _tracked_enemies:
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			living += 1
	if living == 0 and not _wiped_emitted:
		_wiped_emitted = true
		on_squad_wiped.emit()


func alert_squad() -> void:
	for e in _tracked_enemies:
		if is_instance_valid(e) and e.has_method(&"alert"):
			e.call(&"alert")
