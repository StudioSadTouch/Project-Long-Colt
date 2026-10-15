class_name AmmoCrate
extends Node3D
## Walk-over ammo for every carried weapon: each gets magazines_per_weapon magazines of reserve
## (capped by its reserve_max). Consumed only if any weapon actually took ammo; respawns.
## Area3D on the Pickup layer (7), masks Player (2) and Enemy (4), not monitorable.
## Serves any pickup carrier (see WeaponPickup: WeaponPickup.carrier_of, which needs
## get_weapons() here) automatically while in reach; AIs can also ask can_give / is_in_reach and
## call give / try_pickup themselves.

@export var magazines_per_weapon: int = 1
@export var respawn_delay: float = 30.0

var available: bool = true

## Carrier -> number of its bodies inside the trigger.
var _carriers: Dictionary = {}
## Body inside the trigger -> its carrier.
var _bodies: Dictionary = {}

@onready var area: Area3D = $Area
@onready var visual: Node3D = $Visual


func _ready() -> void:
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)


## Available and at least one of carrier's weapons has reserve room.
func can_give(carrier: Object) -> bool:
	if not available:
		return false
	for w in _weapons_of(carrier):
		if w.data != null and w.reserve < w.data.reserve_max:
			return true
	return false


## Gives every carried weapon its share. True (and consumed) if any ammo moved. No reach check.
func give(carrier: Object) -> bool:
	if not available:
		return false
	var added := 0
	for w in _weapons_of(carrier):
		if w.data != null:
			added += w.add_ammo(w.data.magazine_size * magazines_per_weapon)
	if added <= 0:
		return false
	_consume()
	return true


## carrier has a body inside the trigger.
func is_in_reach(carrier: Object) -> bool:
	return carrier != null and _carriers.has(carrier)


## give(), but only in reach.
func try_pickup(carrier: Object) -> bool:
	return is_in_reach(carrier) and give(carrier)


func _physics_process(_delta: float) -> void:
	if not available:
		return
	for carrier in _carriers.keys():  # untyped: a freed carrier fails a typed cast
		if is_instance_valid(carrier) and give(carrier):
			return


static func _weapons_of(carrier: Object) -> Array[Weapon]:
	var out: Array[Weapon] = []
	if carrier == null or not is_instance_valid(carrier) or not carrier.has_method(&"get_weapons"):
		return out
	for item: Variant in carrier.call(&"get_weapons"):
		var w := item as Weapon
		if w != null:
			out.append(w)
	return out


func _consume() -> void:
	available = false
	visual.visible = false
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	available = true
	visual.visible = true


func _on_body_entered(body: Node3D) -> void:
	var carrier := WeaponPickup.carrier_of(body)
	if carrier == null or _bodies.has(body):
		return
	_bodies[body] = carrier
	_carriers[carrier] = int(_carriers.get(carrier, 0)) + 1


func _on_body_exited(body: Node3D) -> void:
	if not _bodies.has(body):
		return
	var carrier: Object = _bodies[body]
	_bodies.erase(body)
	var count := int(_carriers.get(carrier, 1)) - 1
	if count > 0:
		_carriers[carrier] = count
	else:
		_carriers.erase(carrier)
