class_name SpawnerNode
extends LogicNodeBase
## Spawns enemy squads, reinforcements, or pickups when triggered in a campaign encounter.

signal on_spawned(spawned_nodes: Array)

@export var spawn_item_id: String = "enemy:nefer"
@export var spawn_count: int = 1
@export var spawn_spread: float = 2.0


func _init() -> void:
	super._init()
	display_name = "Dynamic Spawner"


func get_node_color() -> Color:
	return Color(1.0, 0.35, 0.7, 0.85)


func get_input_actions() -> Array[String]:
	return ["spawn", "spawn_wave"]


func get_output_signals() -> Array[String]:
	return ["on_spawned"]


func spawn() -> void:
	spawn_wave()


func spawn_wave() -> void:
	var spawned: Array = []
	var parent := get_parent()
	if parent == null:
		return

	for i in spawn_count:
		var entry := {
			"catalog_id": spawn_item_id,
			"uid": 10000 + randi() % 90000,
		}
		var node := LevelBuilder.build(entry, false)
		if node != null:
			parent.add_child(node)
			var offset := Vector3(randf_range(-spawn_spread, spawn_spread), 0.0, randf_range(-spawn_spread, spawn_spread))
			node.global_position = global_position + offset
			spawned.append(node)

	on_spawned.emit(spawned)
