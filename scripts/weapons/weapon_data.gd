class_name WeaponData
extends Resource
## Tuning for one weapon. Angles in degrees, distances in meters, times in seconds.
## Damage numbers assume a 100 HP target until a health/shield model exists.

enum FireMode { SEMI, AUTO }
enum Secondary { NONE, ZOOM, ALT }

@export var display_name: String = "Weapon"

@export_group("Damage")
@export var damage: float = 25.0
## Helmet hits (group hitbox_head_armored, or legacy hitbox_head).
@export var headshot_armored_multiplier: float = 2.0
## Face/visor and neck hits (group hitbox_head_unarmored). Defaults to the armored value so
## new weapons get no surprise one-shots. Weapons opt in per resource; the Service Pistol uses
## 5.0 so it one-shots 100 HP even at the falloff floor: 34 * 0.6 * 5.0 = 102 >= 100.
@export var headshot_unarmored_multiplier: float = 2.0
@export var max_range: float = 150.0
## Full damage up to this distance.
@export var falloff_start: float = 30.0
## Damage reaches min_damage_multiplier here and stays there.
@export var falloff_end: float = 60.0
@export_range(0.0, 1.0) var min_damage_multiplier: float = 0.6

@export_group("Fire")
@export var fire_mode: FireMode = FireMode.SEMI
## Rounds per second. Also caps semi-auto spam.
@export var fire_rate: float = 5.0
## A semi-auto press this early before the gun is ready still fires.
@export var trigger_buffer: float = 0.1

@export_group("Ammo")
@export var magazine_size: int = 12
@export var reserve_max: int = 48
@export var reserve_start: int = 48
@export var reload_time: float = 1.2
@export var equip_time: float = 0.35

@export_group("Recoil")
## Camera kick per shot. It recovers on its own, so it disturbs follow-ups rather than drifting aim.
@export var recoil_pitch: float = 1.0
@export var recoil_yaw: float = 0.3
## Exponential return rate per second.
@export var recoil_recovery: float = 12.0

@export_group("Spread")
## Cone half-angle at rest.
@export var spread_base: float = 0.1
@export var bloom_per_shot: float = 0.5
@export var spread_max: float = 2.0
## Degrees per second that bloom drains back to spread_base.
@export var bloom_recovery: float = 6.0
## Extra spread while airborne.
@export var spread_air_add: float = 0.5

@export_group("Secondary")
@export var secondary: Secondary = Secondary.NONE
@export var zoom_fov: float = 37.5
## Mouse sensitivity multiplier while zoomed.
@export var zoom_sensitivity: float = 0.6
## Spread multiplier while zoomed.
@export var zoom_spread_multiplier: float = 0.5
@export var zoom_time: float = 0.1

@export_group("Melee")
@export var melee_damage: float = 70.0
@export var melee_range: float = 2.0
## Targets out to this range pull the player in with a short lunge.
@export var melee_lunge_range: float = 3.5
@export var melee_lunge_speed: float = 10.0
@export var melee_cooldown: float = 0.8
