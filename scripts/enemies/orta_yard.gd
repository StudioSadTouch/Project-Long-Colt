class_name OrtaYard
extends Node3D
## Greybox test yard for the New Ottoman orta encounter (scenes/enemies/orta_yard.tscn). Not
## Forward Outpost 7: a stand-in with the pieces the board's encounter needs, built in code at
## load so it can be changed without Blender:
##   courtyard with cover   the Azab SCREEN pushes across it toward the player (south end)
##   command platform       north end, 2.5 m up, ramps from the courtyard: the Janissary gunline
##   catwalks               3 m up along both walls, ramps at the north end: the Akinji flank
##   perch                  6 m tower, north-east corner: the marksman's overwatch (he
##                          starts on it; there is no way up)
## Then it bakes the navmesh and spawns the Phase 0 orta from the board (4 Azab + Bolukbasi,
## 1 Akinji raider + 1 marksman, 2 Nefer + Corbaci) plus one Okcu behind the line.
## Run it directly (F6 on the scene, or `--path . res://scenes/enemies/orta_yard.tscn`).

const TYPES := "res://resources/enemies/new_ottoman/%s.tres"
const WALL := 6.0
const HALF := 30.0
const PLATFORM_Y := 2.5
const CATWALK_Y := 3.0
const PERCH_Y := 6.0

@export var difficulty: BotDifficulty
## Spawn the orta. Off: geometry only (layout checks).
@export var spawn_orta: bool = true

var level: Node3D
var orta: Orta
var navigation: ArenaNavigation

var _ground_mat: StandardMaterial3D
var _wall_mat: StandardMaterial3D
var _cover_mat: StandardMaterial3D


func _ready() -> void:
	_ground_mat = _mat(Color(0.32, 0.31, 0.29))
	_wall_mat = _mat(Color(0.45, 0.43, 0.4))
	_cover_mat = _mat(Color(0.5, 0.42, 0.3))
	level = Node3D.new()
	level.name = "Yard"
	add_child(level)
	_build_level()
	navigation = ArenaNavigation.new()
	navigation.name = "Navigation"
	navigation.geometry_root = ^"../Yard"
	add_child(navigation)
	if spawn_orta:
		_spawn_orta()


func _build_level() -> void:
	# Ground and perimeter.
	_block(Vector3(HALF * 2.0 + 2.0, 1.0, HALF * 2.0 + 2.0), Vector3(0.0, -0.5, 0.0), _ground_mat)
	for side: float in [-1.0, 1.0]:
		_block(Vector3(1.0, WALL, HALF * 2.0), Vector3(side * HALF, WALL * 0.5, 0.0), _wall_mat)
		_block(Vector3(HALF * 2.0, WALL, 1.0), Vector3(0.0, WALL * 0.5, side * HALF), _wall_mat)
	# Command platform (north) with a ramp at each end.
	_block(Vector3(16.0, PLATFORM_Y, 6.0), Vector3(0.0, PLATFORM_Y * 0.5, -17.0), _wall_mat)
	_block(Vector3(8.0, 1.0, 0.4), Vector3(0.0, PLATFORM_Y + 0.5, -14.2), _wall_mat)  # parapet
	for side: float in [-1.0, 1.0]:
		_ramp(Vector3(side * 6.5, 0.0, -6.0), Vector3(side * 6.5, PLATFORM_Y, -14.0), 3.0)
	# Catwalks along east and west walls, ramps up from the north-west / north-east corners.
	for side: float in [-1.0, 1.0]:
		var x := side * (HALF - 2.0)
		_block(Vector3(3.0, 0.4, 34.0), Vector3(x, CATWALK_Y - 0.2, 0.0), _wall_mat)
		_block(Vector3(0.3, 1.0, 34.0), Vector3(x - side * 1.35, CATWALK_Y + 0.5, 0.0), _wall_mat)
		_ramp(Vector3(x, 0.0, -24.0), Vector3(x, CATWALK_Y, -17.0), 3.0)
	# Perch: a tower in the north-east corner. No way up: the marksman starts on it and stays.
	_block(Vector3(5.0, PERCH_Y, 5.0), Vector3(20.0, PERCH_Y * 0.5, -25.0), _wall_mat)
	# Courtyard cover: low (crouch) and high (stand) blocks.
	for spec: Array in [
		[Vector3(3.0, 1.1, 1.0), Vector3(-7.0, 0.55, 4.0)],
		[Vector3(3.0, 1.1, 1.0), Vector3(7.0, 0.55, 4.0)],
		[Vector3(1.5, 2.2, 1.5), Vector3(0.0, 1.1, 10.0)],
		[Vector3(2.0, 1.1, 2.0), Vector3(-12.0, 0.55, -4.0)],
		[Vector3(2.0, 1.1, 2.0), Vector3(12.0, 0.55, -4.0)],
		[Vector3(1.5, 2.2, 1.5), Vector3(-5.0, 1.1, 16.0)],
		[Vector3(1.5, 2.2, 1.5), Vector3(5.0, 1.1, 16.0)],
		[Vector3(4.0, 1.1, 1.0), Vector3(0.0, 0.55, -8.0)],
	]:
		_block(spec[0], spec[1], _cover_mat)
	var spawns := Node3D.new()
	spawns.name = "Spawns"
	level.add_child(spawns)
	var spawn := Marker3D.new()
	spawn.name = "SPAWN_FFA_0"
	spawn.position = Vector3(0.0, 0.05, 26.0)
	spawns.add_child(spawn)


func _spawn_orta() -> void:
	orta = Orta.new()
	orta.name = "Orta"
	orta.difficulty = difficulty
	add_child(orta)
	orta.position = Vector3(0.0, 0.0, -10.0)
	var points := Node3D.new()
	points.name = "Points"
	orta.add_child(points)
	var markers := {
		"PeelWest": Vector3(-17.0, 0.0, -2.0),
		"PeelEast": Vector3(17.0, 0.0, -2.0),
		"FlankWest": Vector3(-(HALF - 2.0), CATWALK_Y, 12.0),
		"FlankEast": Vector3(HALF - 2.0, CATWALK_Y, 12.0),
		"FlankWestMid": Vector3(-(HALF - 2.0), CATWALK_Y, -2.0),
		"FlankEastMid": Vector3(HALF - 2.0, CATWALK_Y, -2.0),
		"Perch": Vector3(20.0, PERCH_Y, -25.0),
		"PlatformWest": Vector3(-5.0, PLATFORM_Y, -16.0),
		"PlatformCentre": Vector3(0.0, PLATFORM_Y, -17.0),
		"PlatformEast": Vector3(5.0, PLATFORM_Y, -16.0),
		"FallbackWest": Vector3(-24.0, 0.0, -26.0),
		"FallbackEast": Vector3(14.0, 0.0, -26.0),
	}
	for key: String in markers:
		var m := Marker3D.new()
		m.name = key
		points.add_child(m)
		m.global_position = markers[key]
	var face := Basis.looking_at(Vector3.BACK)  # facing south, toward the player
	var roster := [
		["azab", Vector3(-6.0, 0.05, -4.0)],
		["azab", Vector3(-2.0, 0.05, -4.0)],
		["azab", Vector3(2.0, 0.05, -4.0)],
		["azab", Vector3(6.0, 0.05, -4.0)],
		["bolukbasi", Vector3(0.0, 0.05, -6.0)],
		["okcu", Vector3(-3.0, 0.05, -10.0)],
		["akinji", Vector3(-20.0, 0.05, -20.0)],
		["akinji_marksman", Vector3(20.0, PERCH_Y + 0.05, -25.0)],
		["nefer", Vector3(-5.0, PLATFORM_Y + 0.05, -16.0)],
		["nefer", Vector3(5.0, PLATFORM_Y + 0.05, -16.0)],
		["corbaci", Vector3(0.0, PLATFORM_Y + 0.05, -17.0)],
	]
	for entry: Array in roster:
		var type := load(TYPES % entry[0]) as EnemyType
		orta.spawn(type, Transform3D(face, entry[1]))


func _block(size: Vector3, at: Vector3, material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	mesh.material_override = material
	body.add_child(mesh)
	body.position = at
	level.add_child(body)
	return body


## A walkable slab from foot (on the floor) to top (on the upper deck), `width` m wide.
func _ramp(foot: Vector3, top: Vector3, width: float) -> void:
	var run := top - foot
	var length := run.length()
	var body := _block(Vector3(width, 0.3, length), Vector3.ZERO, _wall_mat)
	var mid := (foot + top) * 0.5 + Vector3.DOWN * 0.15
	body.transform = Transform3D(Basis.looking_at(run.normalized(), Vector3.UP), mid)


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	return m
