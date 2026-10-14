class_name WeaponData
extends Resource
## Tuning for one weapon. Angles in degrees, distances in meters, times in seconds.
## Damage targets HealthShield (Halo-style shield over health). Zone multipliers hit health
## only; shield_damage_multiplier hits shields only.

## Values are stored as ints in .tres files: append, never reorder.
enum FireMode { SEMI, AUTO, BURST }
enum Secondary { NONE, ZOOM, ALT, TOGGLE_MODE }

@export var display_name: String = "Weapon"

@export_group("Damage")
@export var damage: float = 25.0
## Helmet hits (group hitbox_head_armored, or legacy hitbox_head). Health damage only.
@export var headshot_armored_multiplier: float = 2.0
## Face/visor and neck hits (group hitbox_head_unarmored). Health damage only. Defaults to the
## armored value so new weapons get no surprise one-shots; weapons opt in per resource.
@export var headshot_unarmored_multiplier: float = 2.0
## Multiplier on damage dealt to shields (e.g. energy weapons > 1.0).
@export var shield_damage_multiplier: float = 1.0
## If true, the overflow of a shot that breaks a shield spills into health.
@export var bleedthrough: bool = false
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
## A semi-auto or burst press this early before the gun is ready still fires.
@export var trigger_buffer: float = 0.1
## BURST: rounds per trigger press. A started burst always finishes (or runs dry).
@export var burst_count: int = 3
## BURST: seconds between rounds inside a burst.
@export var burst_interval: float = 0.06
## BURST: seconds from a burst's last round to the next burst's first round.
@export var burst_cooldown: float = 0.35

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
## TOGGLE_MODE: the mode secondary switches to. The alt_* fields apply only in that mode.
@export var alt_fire_mode: FireMode = FireMode.BURST
@export var alt_spread_multiplier: float = 1.0
@export var alt_bloom_multiplier: float = 1.0
## Alt-mode falloff. Negative means use the primary falloff_start / falloff_end.
@export var alt_falloff_start: float = -1.0
@export var alt_falloff_end: float = -1.0

@export_group("Melee")
@export var melee_damage: float = 70.0
@export var melee_range: float = 2.0
## Targets out to this range pull the player in with a short lunge.
@export var melee_lunge_range: float = 3.5
@export var melee_lunge_speed: float = 10.0
@export var melee_cooldown: float = 0.8
@export var melee_shield_damage_multiplier: float = 1.0
@export var melee_bleedthrough: bool = false
