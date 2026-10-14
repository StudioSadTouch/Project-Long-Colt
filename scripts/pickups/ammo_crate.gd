class_name AmmoCrate
extends Node3D
## Walk-over ammo for every carried weapon: each gets magazines_per_weapon magazines of reserve
## (capped by its reserve_max). Consumed only if any weapon actually took ammo; respawns.
## Area3D on the Pickup layer (7), masks Player (2) only, not monitorable.

@export var magazines_per_weapon: int = 1
@export var respawn_delay: float = 30.0

var available: bool = true

var _holders: Array[WeaponHolder] = []

@onready var area: Area3D = $Area
@onready var visual: Node3D = $Visual


func _ready() -> void:
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)


func _physics_process(_delta: float) -> void:
	if not available:
		return
	for holder in _holders:
		if is_instance_valid(holder) and _give(holder):
			_consume()
			return


func _give(holder: WeaponHolder) -> bool:
	var added := 0
	for w in holder.slots:
		if w != null and w.data != null:
			added += w.add_ammo(w.data.magazine_size * magazines_per_weapon)
	return added > 0


func _consume() -> void:
	available = false
	visual.visible = false
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	available = true
	visual.visible = true


func _on_body_entered(body: Node3D) -> void:
	if body is Player:
		var holder := body.find_child("WeaponHolder", true, false) as WeaponHolder
		if holder != null and not _holders.has(holder):
			_holders.append(holder)


func _on_body_exited(body: Node3D) -> void:
	if body is Player:
		var holder := body.find_child("WeaponHolder", true, false) as WeaponHolder
		_holders.erase(holder)
