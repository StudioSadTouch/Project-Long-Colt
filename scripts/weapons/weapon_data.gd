class_name WeaponData
extends Resource
## Tuning for one weapon. Angles in degrees, distances in meters, times in seconds.
## Damage targets HealthShield (Halo-style shield over health). Zone multipliers hit health
## only; shield_damage_multiplier hits shields only.

## Values are stored as ints in .tres files: append, never reorder.
## CHARGE: hold the trigger to charge, release to fire (see the Charge group). A release before
## charge_time fires one normal shot (Halo 2 plasma pistol rules).
enum FireMode { SEMI, AUTO, BURST, CHARGE }
enum Secondary { NONE, ZOOM, ALT, TOGGLE_MODE }

@export var display_name: String = "Weapon"
## Viewmodel / third-person animation set: &"pistol", &"rifle", &"carbine", &"shotgun", &"der".
@export var anim_type: StringName = &"rifle"

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
## Multiplier on damage dealt to health only, applied on top of the zone multiplier (e.g. plasma
## weapons < 1.0: strong vs shields, weak vs flesh). 1.0 = none.
@export var health_damage_multiplier: float = 1.0
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

@export_group("Pellets")
## Rays per shot (shotguns). 1 = the classic single ray (bend and global randf, unchanged).
## > 1: each pellet is its own hit through the shared ray path, so shields and zones resolve per
## pellet. Directions come from Weapon's seedable _spread_rng (see Weapon.set_next_shot_seed).
@export var pellet_count: int = 1
## Pellet cone half-angle in degrees, around the (bloomed) aim ray.
@export var pellet_spread: float = 0.0

@export_group("Ammo")
@export var magazine_size: int = 12
@export var reserve_max: int = 48
@export var reserve_start: int = 48
@export var reload_time: float = 1.2
## Fraction of reload_time at which the new magazine seats and ammo transfers (the mag-insert
## beat). 1.0 refills at the very end. Viewmodel reload animations key their insert at the same
## fraction of their authored length, so keep the two in sync when retiming an animation.
@export_range(0.0, 1.0) var reload_insert_fraction: float = 1.0
@export var equip_time: float = 0.35
## Energy weapons: the magazine is the battery (magazine_size = full charge). No reload, and
## add_ammo refuses (ammo pickups and dropped copies can't refill it). Set reserve to 0.
@export var battery: bool = false

@export_group("Heat")
## Heat (0..1) added per shot. 0 disables heat. Reaching 1.0 overheats: no fire for
## overheat_vent_time while heat drains to 0.
@export var heat_per_shot: float = 0.0
## Seconds after the last shot before heat starts to drop.
@export var heat_cooldown_delay: float = 0.3
## Heat lost per second once cooling.
@export var heat_cooldown_rate: float = 0.8
@export var overheat_vent_time: float = 1.8

@export_group("Charge")
## FireMode.CHARGE (as fire_mode or alt_fire_mode). Seconds of held trigger for a full charge.
@export var charge_time: float = 0.75
## Charged shot damage = damage * this (falloff, zones, shield and health multipliers still apply).
@export var charge_damage_multiplier: float = 5.0
## Magazine/battery spent by a charged shot (at least 1; fires with whatever is left).
@export var charge_ammo_cost: int = 10
## Heat added by a charged shot (1.0 = always overheats). Ignored when heat_per_shot is 0.
@export var charge_heat: float = 1.0
## Magazine/battery drained per second while a full charge is held. 0 = none.
@export var charge_hold_drain: float = 0.0

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
## True optical magnification (e.g. 2.0). > 0 derives the zoom FOV from the player's base FOV
## (2 * atan(tan(base / 2) / magnification)) and overrides zoom_fov; 0 uses zoom_fov as-is.
@export var zoom_magnification: float = 0.0
## Zoom only allowed in this FireMode (e.g. BURST); -1 = any mode. Leaving it de-zooms.
@export var zoom_only_in_mode: int = -1
## Draw the HUD scope overlay (vignette + reticle) while zoomed.
@export var zoom_overlay: bool = false
## action_fire_select toggles between fire_mode and alt_fire_mode (the alt_* fields apply).
## Independent of secondary, so a weapon can fire-select on F and zoom on right-click.
@export var fire_select: bool = false
## TOGGLE_MODE / fire_select: the alternate mode. The alt_* fields apply only in that mode.
@export var alt_fire_mode: FireMode = FireMode.BURST
@export var alt_spread_multiplier: float = 1.0
@export var alt_bloom_multiplier: float = 1.0
## Alt-mode falloff. Negative means use the primary falloff_start / falloff_end.
@export var alt_falloff_start: float = -1.0
@export var alt_falloff_end: float = -1.0
## Alt-mode damage floor. Negative means use min_damage_multiplier.
@export var alt_min_damage_multiplier: float = -1.0

@export_group("Aim Assist")
## See AimAssist. All off by default; strength also depends on input device.
## Fraction of a target's angular motion the view follows while it is inside aim_assist_cone.
@export_range(0.0, 1.0) var aim_magnetism: float = 0.0
## Look sensitivity multiplier while a target is inside aim_assist_cone (1.0 = none).
@export_range(0.0, 1.0) var aim_slowdown: float = 1.0
## Cone half-angle (degrees) for magnetism and slowdown.
@export var aim_assist_cone: float = 0.0
## Cone half-angle (degrees) within which a missing ray bends onto a target's aim point.
@export var aim_bend_angle: float = 0.0
## Halo 2-style (Morgon's choice, default): bend goes to the body, helmet or face point nearest
## the reticle and the bent ray scores whatever it hits, face one-shots included.
## false = body point only, and a bent ray always scores BODY.
@export var aim_bend_allow_head: bool = true
## aim_bend_angle multiplier while firing in AUTO, so bend doesn't cancel full-auto bloom.
@export_range(0.0, 1.0) var aim_bend_auto_scale: float = 0.5
## Max distance for all assists. 0 = unlimited.
@export var aim_assist_range: float = 0.0

@export_group("Melee")
@export var melee_damage: float = 70.0
@export var melee_range: float = 2.0
## Targets out to this range pull the player in with a short lunge.
@export var melee_lunge_range: float = 3.5
@export var melee_lunge_speed: float = 10.0
@export var melee_cooldown: float = 0.8
@export var melee_shield_damage_multiplier: float = 1.0
@export var melee_bleedthrough: bool = false
