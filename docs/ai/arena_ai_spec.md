# Arena AI: first-pass combat bot (Lockout) — spec

Scope: a Bungie-era (CE through Reach) style arena opponent for Lockout. Same HealthShield
(70 shield / 45 health), same armored/unarmored head hitboxes (dummy_rig.tscn), and the same
WeaponData `.tres` (Service Pistol, Standard Issue Rifle) as the player, so the TTK math is
identical in both directions. Bungie shipped no multiplayer bots in CE–Reach, so behavior and
difficulty scaling are modeled on Bungie *campaign* AI (reaction delay, inaccuracy that converges,
Legendary = faster, more accurate, more aggressive). Every Halo-derived number is **approximate**.

## Architecture (composition only; no edits to weapon.gd, weapon_holder.gd, player.gd, hud.gd)

```
Bot (CharacterBody3D, bot.gd)       movement = duplicated player.gd constants, lunge, crouch, jump
├─ CollisionShape3D  capsule r0.35 h1.8   layer 0, mask World|Player|Enemy (movement only)
├─ Hurtbox (AnimatableBody3D)        Enemy layer (4), box 0.7x1.4x0.4 like the dummies
├─ Rig (dummy_rig.tscn)              HeadArmored / HeadUnarmored on Hitbox layer (32)
│  └─ AimHeadPoint (Marker3D)        get_aim_points().head (movable; not hard-coded)
├─ Head/Eye (Node3D)                 Weapon.aim_source: ray origin + aim basis
│  └─ WeaponMount → BotWeapon x2     subclass of Weapon, data = existing .tres
├─ HealthShield, NavigationAgent3D
└─ Brain (bot_brain.gd)              state machine + perception + aim model
```

Why the capsule is not on the Enemy layer: a 0.35 m capsule covering 0–1.8 m sits in front of the
visor (z −0.22) at head height, so every head shot would hit "body". The capsule therefore only
moves the bot; the Enemy-layer hurtbox and the Hitbox-layer head colliders take hits exactly like
the dummies, so zone multipliers and TTK match.

**BotWeapon** (`extends Weapon`) is thin and uses the AI hooks on origin/main (47b876f):
`aim_source` = Eye, `hit_mask_override` = `HIT_MASK | LAYER_PLAYER` (bots hit the player, other
bots, dummies), `exclude_bodies` = own capsule, hurtbox, `Rig/HeadArmored`, `Rig/HeadUnarmored`,
`shooter` = the bot (info.source, kill credit). `aim_assist` stays null (bots never go through
WeaponHolder, so the player's AimAssist is never copied in). Overrides only `get_spread` (air
spread; Weapon reads airborne from `player`, which is null) and `holster` (cancel bot lunge). It
never overrides `_melee`; the Bot lunges itself and calls `melee()` once inside `melee_range`.

Bots join groups `bot` and `aim_target` and implement `get_aim_points()` in DummyCore's format:
`body` (rig + up x 0.7), `head` (`Rig/AimHeadPoint` marker, editable, not hard-coded) and `face`
(`Rig/HeadUnarmored/VisorShape`). Free-for-all: every bot is hostile to everyone; a `team` field
(and SpawnManager's `free_for_all` flag) is in place for team modes.

## States (Brain)

| State | Enter | Behavior | Exit |
|---|---|---|---|
| PATROL | default | roam between `ai_roam_point` markers (power positions weighted x2) | sees/hears/damaged |
| SEARCH | heard gunfire, lost target < 4 s, or hit from unseen | path to last known position, look around 1.5 s | sees target / timeout |
| ENGAGE | hostile visible | hold preferred range per weapon; ADAD strafe, crouch, jump; fire with aim model; melee | lost target / retreat / low ammo |
| RETREAT | shield <= `retreat_threshold` and roll < `retreat_chance` (once per shield pop) | path to nearest point with no LOS from the threat; backpedal-fire if seen | shield >= `reengage_shield_fraction`, or cornered (threat < 5 m) |
| SEEK_PICKUP | out of ammo, or low and a pickup is near | path to nearest useful WeaponPickup; take or top up | done / pickup gone |

## Perception
10 Hz. FOV cone (`fov_deg`) to `sight_range`, plus a 3 m "feel" radius; LOS = World-layer ray
from the eye to the target's body or head aim point. Hearing: `ArenaEvents.gunfire` (every player
and bot shot) inside `hearing_radius`. Damage from an unseen attacker reveals its position.
Memory 4 s; a target lost for > 1 s costs a new reaction delay on reacquire.

## Aim model (Halo-style, never perfect)
1. **Reaction**: first shot only `reaction_time` (±20%) after acquiring.
2. **Tracking lag**: aim direction chases the target with time constant `tracking_lag` and a
   turn-rate cap (`max_turn_rate_deg`). **Lead**: aims `lead_skill x tracking_lag x velocity` ahead
   (cancels some of the lag; hitscan needs no ballistic lead).
3. **Error**: angular offset of magnitude `aim_error_deg` at acquisition, converging
   exponentially (`convergence`/s) to `min_error_deg`, resampled ~4x/s; a target reversing its
   strafe bumps it back up (`strafe_error_bump`), which is what makes ADAD work against bots.
4. **Discipline**: fires only when tracking is within the target's angular size plus
   `fire_tolerance_deg`. Pistol: paced at `semi_cadence` x max rate. Rifle: AUTO in short sprays
   (`spray_time`, shorter with range) with `burst_pause` to let bloom recover; toggles to BURST past
   `burst_switch_range` (via `toggle_fire_mode()`). Pistol zooms past 25 m
   on Heroic+ (spread x0.5 like the player). Aims for the head only when the target's shield is
   down, with probability `headshot_bias` (zone multipliers only touch health).
5. Recoil from `Weapon.get_recoil()` is applied to the bot's eye like the player's view kick.

## Difficulty presets (`BotDifficulty` resource; values approximate)

| | Easy | Normal | Heroic | Legendary |
|---|---|---|---|---|
| reaction_time (s) | 0.65 | 0.45 | 0.30 | 0.20 |
| aim_error / min (deg) | 9 / 2.5 | 6 / 1.5 | 4 / 0.8 | 2.5 / 0.4 |
| convergence (/s) | 0.8 | 1.2 | 1.8 | 2.5 |
| tracking_lag (s) | 0.35 | 0.22 | 0.14 | 0.09 |
| strafe_frequency | 0.25 | 0.45 | 0.65 | 0.8 |
| aggression | 0.2 | 0.4 | 0.6 | 0.8 |
| retreat thr / chance | 0.25 / 0.9 | 0.1 / 0.7 | 0 / 0.5 | 0 / 0.35 |
| melee_eagerness | 0.2 | 0.4 | 0.6 | 0.8 |
| skill jumps (Elbow, Open Ramp) | no | no | yes | yes |

## Navigation plan
`ArenaNavigation` (NavigationRegion3D) bakes at runtime in `_ready` from the instanced
`lockout.tscn` collision geometry (`parse_source_geometry_data` + `bake_from_source_geometry_data_async`,
static colliders, World mask): agent radius 0.35, height 1.8, max climb 0.25, max slope 45; cell
size taken from the navigation map. No prebaked mesh (Godot can't be run here). One-way
`NavigationLink3D`s, generated by `tools/lockout/emit_arena_tscn.py` from `build_lockout.py`:
grav lift (Green Hall pad → Top Blue), drops (Top Blue → Top Mid, Library window → Top Mid,
Left/Right Mag → Bottom Blue), the BR2 ledge hop, and the skill jumps (Elbow, Open Ramp) on nav
layer 2 (only Heroic/Legendary agents use layer 2). Link metadata `traversal` = lift / drop /
jump drives the traversal; the jump fires at the `lip` point (or on coyote time if the bot runs
off). `BotGravLift` (Area3D, Enemy mask) mirrors the level GravLift for bots, because GravLift
only pushes `Player` bodies.

## Arena mode
`scenes/main/arena_lockout.tscn` (generated): Lockout + player + the same pickups as
main_lockout + Navigation + links + BotGravLift + roam points + extra spawns + `ArenaEvents` bus +
`SpawnManager` (`bot_count`, `difficulty`, `respawn_delay` 5 s ≈ Halo 2 default, FFA by default,
`score_limit` 25). Spawn choice: maximize distance to living enemies, heavy penalty for enemy LOS
or < 8 m. Bots drop their active weapon on death (Halo). Kill feed and K/D tally go to stdout and a
debug Label (top left). The player still respawns via player.gd's placeholder; SpawnManager then
moves them to a safe spawn (deferred).

## Files
- `scripts/ai/bot.gd`, `bot_brain.gd`, `bot_weapon.gd`, `bot_difficulty.gd`,
  `bot_grav_lift.gd`, `arena_navigation.gd`, `arena_events.gd`, `spawn_manager.gd`
- `scenes/ai/bot.tscn`; `resources/ai/bot_difficulty_{easy,normal,heroic,legendary}.tres`
- `scenes/main/arena_lockout.tscn`, generated by `tools/lockout/emit_arena_tscn.py`

## Remaining asks for LC Programmer (not blocking; bots work without them)
1. Player head hitboxes. The player has no zone colliders, so every bot hit on the player scores
   `body` (no headshots, and no pistol headshot kills on the player). Bots do aim at the head once
   the player's shield is down, so this only changes the zone multiplier. The player's own rays
   would need to exclude the new head bodies.
2. `Player.died(info)` and `respawn_at(transform)`, so SpawnManager can own the player respawn
   delay. Today player.gd respawns the player instantly and SpawnManager moves them afterwards
   (deferred).
3. A public "give to this taker" API on `WeaponPickup` / `AmmoCrate` for non-Player bodies. Bots
   use WeaponPickup's public `take()` / `available` today and ignore ammo crates (`_consume` is
   private).
4. GravLift accepting any CharacterBody3D in group `lift_rider`; then `BotGravLift` can go.
5. KillVolume only damages the body it touches, and the bot's hurtbox has no `take_damage`, so bots
   kill themselves below y = -9 (`Bot.FALL_KILL_Y`). A KillVolume that resolves the owner would
   remove that.
