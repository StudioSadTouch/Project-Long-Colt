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
| RETREAT | shield <= `retreat_threshold` and roll < `retreat_chance` (once per shield pop: re-armed by `HealthShield.shield_full` and on respawn) | path to nearest point with no LOS from the threat; backpedal-fire if seen | shield >= `reengage_shield_fraction`, or cornered (threat < 5 m) |
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
6. **Weapon choice and range**: rifle under 28 m, pistol over, with a +/-3 m hysteresis on the
   held weapon (rifle → pistol past 31 m, pistol → rifle under 25 m). The rifle covers close
   (AUTO) and mid (BURST past `burst_switch_range`, 16-25 m) range inside its 15-40 m falloff.
   The pistol covers long range, where it has no falloff until 35 m. Preferred bands: rifle
   6-24 m, pistol 12-40 m. Each AUTO engagement opens with a full `spray_time` spray.
   The roster pickups (below) override this for their roles; pistol and rifle are unchanged.
6a. **Weapon roles (five-gun roster, `scripts/ai/bot_weapon_prefs.gd`)**. Role comes from
   `WeaponData.resource_path`, else from mechanics (pellets → shotgun, battery / shield bonus →
   energy, AUTO → rifle, else pistol). The brain switches when the other gun scores > 1 more.
   Pistol/rifle scores stay 2.0 in band, 0.5 / -0.5 out of band.
   | Role | Score | Band (m) | Fire / aim |
   |---|---|---|---|
   | Combat Shotgun | 4.0 under 7 m (+3 m held), 1.0 under 15 m, else -1.0 | 0-4: carrying a loaded shotgun with the target under 14 m, the bot pushes in | paced pumps; body while shielded, head blast (centre pellet on the head, x4 health) once the shield is down |
   | Marksman Carbine | 3.5 from 12 m (-3 m held), else 0.5 (rifle wins close) | 15-50 | paced semi at `semi_cadence`; zooms past 25 m when `uses_zoom`; head on bare health |
   | Directed Energy Rifle | 3.5 on a shielded target under 30 m (+3 m held); -1.5 once the shield is down (swap to the precision gun: the DER + pistol combo); -2.0 at heat >= 0.85 or overheated; -100 with a flat battery | 6-20 | AUTO sprays; lets go at heat 0.85, resumes at 0.4; body only |
   DER charge shots: rolled per engagement with `weapon_switch_skill`. If on, a cool DER with
   >= 10 battery switches to CHARGE mode on a target with >= 90% shield inside 25 m, holds
   the trigger (still holding while off target), and releases once fully charged and on
   target. The charge overheats the gun, which makes its score -2 and forces the swap to the
   other gun for the finish. Pickup choice: distance x 0.6 for shotgun / DER, x 0.8 for
   the carbine when not carried. `Bot.take_pickup` replaces a dry weapon (e.g. a flat DER) before
   the active one. A DER can't take ammo from pickups (battery).
7. **Melee**: Halo-style, aimed at the target's body point with no aim error, both in reach and
   at the end of a lunge.

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
off). Bots ride the level GravLift directly: they join group `lift_rider`, and GravLift resolves
the entering Hurtbox (Enemy layer) to its parent Bot.

## Arena mode
`scenes/main/arena_lockout.tscn` (generated; the project's main scene): Lockout + player + the
same pickups as main_lockout + Navigation + links + roam points + extra spawns +
`ArenaEvents` bus + `SpawnManager` (`bot_count` 3, so the default match is a 4-player FFA;
`difficulty`, `respawn_delay` 5 s ≈ Halo 2 default, `score_limit` 25). Spawn choice: maximize
distance to living enemies, heavy penalty for enemy LOS or < 8 m. Bots drop **both** weapons on
death (Halo 2), 2.2 m apart across the bot's facing (pickup triggers have radius 1 m; a wall in
the way shortens the offset), each with its own magazine and reserve; empty weapons are not
dropped. Kill feed and K/D tally go to stdout and a debug Label (top left). The per-bot
name / state / S / H label (the rig's Label3D, drawn through walls) is off by default
(`Bot.show_debug_label`).

Player respawn: SpawnManager owns it through player.gd's API. In `_hook_player` it sets
`player.auto_respawn = false` and `player.respawn_delay = respawn_delay`, so player.gd runs the
only timer, and answers `respawn_requested(player)` with `respawn_at(safe spawn)`. Kill credit is
the `killer` argument of `died(player, killer, info)`. Bots use SpawnManager's own timer and
`Bot.respawn_at`.

Shared level and pickup APIs bots use (LC Programmer, prog/ai-player):
- **KillVolume** resolves the entering Hurtbox to the Bot (`take_damage`, `is_dead`) and kills it
  once (`kill_volume = true`: no weapon drop, counted as a fall).
- **GravLift** pushes CharacterBody3Ds in group `lift_rider` (Player and Bot).
- **Pickups**: Bot is a carrier (group `pickup_carrier`, `find_weapon`, `get_weapons`,
  `take_pickup`). The brain picks targets with `pickup.is_useful_to(bot)` and takes them with
  `is_in_reach(bot)` + `try_pickup(bot)`. Walk-over ammo from weapon pickups is applied by the
  pickup itself, like the player's. **Ammo crates are ignored** (Morgon): AmmoCrate fills
  whatever `get_weapons()` returns, and Bot returns an empty list unless
  `Bot.use_ammo_crates` (default false) is set.

## Files
- `scripts/ai/bot.gd`, `bot_brain.gd`, `bot_weapon.gd`, `bot_weapon_prefs.gd`, `bot_difficulty.gd`,
  `arena_navigation.gd`, `arena_events.gd`, `spawn_manager.gd`
- `scenes/ai/bot.tscn`; `resources/ai/bot_difficulty_{easy,normal,heroic,legendary}.tres`
- `scenes/main/arena_lockout.tscn`, generated by `tools/lockout/emit_arena_tscn.py`

## Decisions (Morgon, 2026-10-14)
1. Default match: 4-player FFA, the player plus 3 bots (`SpawnManager.bot_count` default and
   `emit_arena_tscn.py` `BOT_COUNT`).
2. A dead bot drops both weapons, spread apart, each keeping its ammo.
3. Bots don't slide (Bot has no slide; only the player does).
4. Pit deaths from failed Elbow / Open Ramp skill jumps are fine and stay.
5. Bots ignore ammo crates (`Bot.use_ammo_crates = false`; see Arena mode). They top up from
   weapon pickups only.
6. `arena_lockout.tscn` is `run/main_scene`.
7. Bots ride the level GravLift via group `lift_rider`; the bot-side BotGravLift is deleted.
8. Player head hitboxes and the 5 s player respawn come from LC Programmer (prog/ai-player);
   SpawnManager drives the player respawn as described under Arena mode.

## Remaining asks for LC Programmer
None blocking. Everything the first pass asked for (player hitboxes, died / respawn API,
pickup carrier API, `lift_rider` GravLift, owner-resolving KillVolume) landed in prog/ai-player
and is integrated on main-ai.
