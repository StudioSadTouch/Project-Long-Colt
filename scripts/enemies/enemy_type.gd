class_name EnemyType
extends Resource
## One New Ottoman enemy: corps, rank, body, durability, kit and temperament. Enemy reads it in
## _ready; EnemyRig builds the greybox silhouette from it; EnemyBrain and Orta read the role.
## The ten ranks on the enemy board live in resources/enemies/new_ottoman/*.tres. Rank variants
## of one corps share a mesh and differ in colours (crest / cap / coat), gilt and numbers,
## as the board's Phase 0 build list asks (docs/enemies/new_ottoman.md).

## The three body plans. Append, never reorder.
enum Corps { JANISSARY, AZAB, AKINJI }
## What the unit does in the orta encounter. Append, never reorder.
##   LINE          Azab: advance in a loose line, volley, peel to the flanks.
##   GRENADIER     Okcu: lobs grenades from behind the line.
##   SQUAD_LEADER  Bolukbasi: horn calls; the Azabs rout when he dies.
##   RAIDER        Akinji / Akinci Beyi: flank in pairs, withdraw under pressure, circle back.
##   MARKSMAN      Akinji marksman: takes the overwatch perch and stays there.
##   HEAVY         Nefer / Odabasi: hold the command platform, charge on the break.
##   COMMANDER     Corbaci / Aga: as HEAVY; his death breaks the orta.
enum Role { LINE, GRENADIER, SQUAD_LEADER, RAIDER, MARKSMAN, HEAVY, COMMANDER }

@export var id: StringName = &"enemy"
@export var display_name: String = "Enemy"
## The historical term, with diacritics (labels, docs, kill feed).
@export var native_name: String = ""
@export var corps: Corps = Corps.AZAB
@export var role: Role = Role.LINE
## Officers (Bolukbasi, Corbaci, Aga, Akinci Beyi) carry gilt and, on death, change the orta.
@export var officer: bool = false
## Boss tier: campaign only (the Aga). Never spawned by an orta's default roster.
@export var boss: bool = false

@export_group("Body")
## Standing height (m). The Bot's constants are a 2.1 m Marine capsule; Enemy scales them.
@export var height: float = 1.75
## Hurtbox width (x) and depth (z) at body_scale 1.0; height follows Bot.HURTBOX_HEIGHT.
@export var hurtbox_size: Vector2 = Vector2(0.62, 0.4)
## Hit volumes (hurtbox, helmet, face, neck) x this across (x and z), on top of body_scale. The
## small ranks pad theirs so they aren't much harder to hit than a Marine. Heights don't grow:
## the hurtbox top stays under the helmet, so head shots still land on the head.
@export var hitbox_scale: float = 1.0
## Run speed against the Marine's 7.5 m/s.
@export var speed_scale: float = 1.0

@export_group("Durability")
## Plate armour, carried by HealthShield's shield pool with recharge disabled: no energy
## shield on any New Ottoman. Headshots don't multiply on plate (zone multipliers only touch
## health), so plate must come off before the sensor slit is worth aiming at. 0 = no plate.
@export var armor: float = 0.0
@export var health: float = 50.0
## Fraction of plate left when the crest and pauldrons spall (Janissary damage state 2).
@export_range(0.0, 1.0) var spall_fraction: float = 0.5
## Damage state 3 (plate gone, frame exposed): run speed and aggression go up, melee eagerness
## spikes and the blade comes out.
@export var exposed_speed_scale: float = 1.3

@export_group("Kit")
## Weapon scenes for the two slots (data on the scene root, the scene is the dropped pickup).
@export var starting_weapons: Array[PackedScene] = []
## Drop carried weapons on death, Halo 2 style.
@export var drops_weapons: bool = true

@export_group("Temperament")
## Applied on top of the campaign difficulty preset (BotDifficulty), so one preset scales the
## whole faction and each rank keeps its character.
@export_range(0.0, 1.0) var aggression: float = 0.4
@export_range(0.0, 1.0) var melee_eagerness: float = 0.3
## x the preset's aim_error_deg and min_error_deg (< 1 = steadier).
@export var aim_error_scale: float = 1.0
## x the preset's reaction_time.
@export var reaction_scale: float = 1.0
@export var sight_range: float = 50.0
@export var uses_zoom: bool = false
## x the preset's fire cadence (semi pacing, auto spray length; pauses grow to match). Halo AI
## fires well under its weapon's maximum rate; this is the main lethality dial per rank.
@export var fire_rate_scale: float = 1.0
## Strafe and dodge (x the preset): drilled Janissaries stand, raiders never stop moving.
@export var strafe_scale: float = 1.0

@export_group("Look")
## The rank tell: Janissary crest, Azab cap, Akinji coat.
@export var rank_color: Color = Color("6e1f22")
## Base gunmetal, the faction's plate colour.
@export var plate_color: Color = Color("3a3f46")
## Cloth under the plate (quilted coat, mail shirt, frame).
@export var cloth_color: Color = Color("5a616b")
## Gilt bands on the rank surface (Odabasi 1).
@export var gilt_bands: int = 0
## Tombak-gilt chest plate (Corbaci, Aga).
@export var gilt_chest: bool = false
## Full tombak plate (Aga).
@export var full_tombak: bool = false
## Tall plume above the crest or cap (Aga, Akinci Beyi).
@export var plume: bool = false
## Bolukbasi's signal horn on the chest.
@export var horn: bool = false
## Akinci Beyi's trophy kit on the belt (looted Long Colt webbing).
@export var trophies: bool = false


## Bot.body_scale for this type: the Bot capsule is 2.1 m tall.
func body_scale() -> float:
	return height / Bot.STAND_HEIGHT


func role_name() -> String:
	return Role.keys()[role]
