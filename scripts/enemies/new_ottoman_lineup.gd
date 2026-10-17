class_name NewOttomanLineup
extends Node3D
## Every New Ottoman rank standing in a row at true scale, next to a 1.9 m Marine block: the
## board's lineup page in-engine (scenes/enemies/new_ottoman_lineup.tscn). AI is off.
##   B   black-fill test: every body solid black, as the board's 50 m silhouette rule
##   1-3 damage a Janissary's plate in steps (SPALLED, EXPOSED, dead) to check the stages
##   left / right  orbit the camera

const ORDER := [
	"azab", "okcu", "bolukbasi",
	"akinji", "akinji_marksman", "akinci_beyi",
	"nefer", "odabasi", "corbaci", "aga",
]
const SPACING := 2.2

var enemies: Array[Enemy] = []
var _black := false
var _black_mat: StandardMaterial3D
var _saved: Dictionary = {}
var _yaw: float = 0.0

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	_black_mat = StandardMaterial3D.new()
	_black_mat.albedo_color = Color.BLACK
	_black_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_block(Vector3(40.0, 1.0, 12.0), Vector3(0.0, -0.5, 0.0), Color(0.78, 0.76, 0.72))
	var x0 := -SPACING * (ORDER.size()) * 0.5
	_block(Vector3(0.5, 1.9, 0.3), Vector3(x0, 0.95, 0.0), Color(0.55, 0.53, 0.47))  # Marine
	_label("MARINE 1.9 m", Vector3(x0, -0.0, 0.9))
	for i in ORDER.size():
		var type := load("res://resources/enemies/new_ottoman/%s.tres" % ORDER[i]) as EnemyType
		var e := (load("res://scenes/enemies/enemy.tscn") as PackedScene).instantiate() as Enemy
		e.enemy_type = type
		e.name = String(type.id).to_pascal_case()
		e.drop_weapon_on_death = false
		var at := Vector3(x0 + SPACING * (i + 1), 0.05, 0.0)
		e.transform = Transform3D(Basis.looking_at(Vector3.BACK), at)
		add_child(e)
		e.get_node(^"Brain").process_mode = Node.PROCESS_MODE_DISABLED
		e.set_aim(Vector3.BACK)
		enemies.append(e)
		_label("%s\n%.2f m" % [type.native_name.to_upper(), type.height], at + Vector3(0.0, 0.0, 0.9))
	_place_camera()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_B:
			set_black_fill(not _black)
		KEY_1:
			_hurt_janissaries(0.55)
		KEY_2:
			_hurt_janissaries(1.0)
		KEY_3:
			_hurt_janissaries(10.0)
		KEY_LEFT:
			_yaw -= 0.3
			_place_camera()
		KEY_RIGHT:
			_yaw += 0.3
			_place_camera()


## Black-fill test: every mesh under the enemies drawn solid black (and back).
func set_black_fill(on: bool) -> void:
	_black = on
	for e in enemies:
		for node in e.find_children("*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			if on:
				if not _saved.has(mesh):
					_saved[mesh] = mesh.material_override
				mesh.material_override = _black_mat
			elif _saved.has(mesh):
				mesh.material_override = _saved[mesh]
	if not on:
		_saved.clear()


## Damages each Janissary by `fraction` of its full plate (10 = kill).
func _hurt_janissaries(fraction: float) -> void:
	for e in enemies:
		if e.enemy_type.corps != EnemyType.Corps.JANISSARY or e.dead:
			continue
		var hs := e.health_shield
		var kill := fraction > 1.0
		var amount := (hs.max_shield + hs.max_health) * fraction if kill else hs.max_shield * fraction
		var at := e.global_position + Vector3.UP * 2.0
		e.take_damage(amount, {"bleedthrough": kill, "position": at})


func _place_camera() -> void:
	var pivot := Vector3(0.0, 1.4, 0.0)
	var offset := Vector3(sin(_yaw), 0.0, cos(_yaw)) * 17.0 + Vector3.UP * 2.0
	camera.global_position = pivot + offset
	camera.look_at(pivot, Vector3.UP)


func _block(size: Vector3, at: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	mesh.material_override = m
	body.add_child(mesh)
	body.position = at
	add_child(body)


func _label(text: String, at: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = at + Vector3(0.0, 0.25, 0.3)
	label.pixel_size = 0.004
	label.font_size = 48
	label.modulate = Color(0.15, 0.15, 0.15)
	label.outline_size = 0
	add_child(label)
