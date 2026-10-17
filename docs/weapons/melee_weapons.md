# Melee weapons: Longsword and Gravity Hammer

Both are ordinary `Weapon`s whose trigger swings (`WeaponData.melee_primary`). Everything goes
through `Weapon.melee()`, so the network (client swing -> host replays it on the puppet), the
first-person `ViewmodelMelee` clip and the third-person melee action all work unchanged, and
bots (which build a `BotWeapon` from the data) get the same behaviour.

| | Longsword | Gravity Hammer |
|---|---|---|
| data | `resources/weapons/longsword.tres` | `resources/weapons/gravity_hammer.tres` |
| hit | lunge from 6.5 m (18 m/s), 200 damage + bleedthrough: one hit kills | smash 0.25 s after the swing: 160 inside 2 m, falling to 0 at 4.5 m, knockback, blocked by walls, never hurts you |
| uses | unlimited (steel: `swing_cost` 0, no HUD ammo) | 10 swings (battery, one per swing) |
| pace | `melee_cooldown` 0.65 s | 1.1 s |
| held | side guard (own `sword` class), alternating forehand / backhand; hangs at the hip | port arms (own `hammer` class), overhead slam; on the back |

- Scenes: `tools/melee_weapons/gen_melee_weapon_scenes.py` writes
  `scenes/weapons/longsword.tscn` (cruciform: blade, point, crossguard, grip, pommel) and
  `gravity_hammer.tscn`. First-person swing clips: `tools/viewmodel_anims/gen_viewmodel_anims.py`.
- The hammer shockwave (`MeleeFx`) is spawned by `CharacterWeaponProps` from the synced
  animation state, so every player sees every smash without an extra network message.
- Bots: `BotWeaponPrefs.Role.MELEE` - the best weapon once a target is inside lunge reach,
  pursued as a pickup; the brain swings whenever in reach and never presses the trigger at range.
- Maps (generators' `GUN` table, 120 s respawn): Lockout Library (sword) / S1 (hammer);
  Zanzibar hub (sword, H2's sword spot) / pump house (hammer); Ivory Tower under the grate
  (sword, H2) / east cul-de-sac (hammer); Headlong site F1 (sword) / north (hammer); Kamino a
  sword on each landing pad (point symmetric), no hammer.
- Tests: `tests/melee_weapons_self_test.gd`, `tests/assassination_self_test.gd`.

## Melee & Explosion Knockback

Project Long Colt features physics knockback impulses for melee strikes, weapon smashes, and explosive blasts:
- **Melee Shove (`Knockback.melee`)**: Every standard melee strike and sword/hammer hit imparts a 10 m/s horizontal push along the strike direction combined with a 3 m/s vertical hop. Survivors are knocked into a brief loose-ground-friction state (`LOOSE_TIME` = 0.3s) preventing ground braking from absorbing the impulse instantly.
- **Explosion Shove (`Knockback.blast`)**: Frag grenades, sticky grenades, rocket impacts, and gravity hammer smashes impart radial impulses proportional to damage dealt (falloff-scaled up to `BLAST_SPEED` = 12 m/s and `BLAST_MIN_HOP` = 3 m/s, clamped to `MAX_HORIZONTAL` 13 m/s and `MAX_UP` 12 m/s). Mounted vehicle occupants are exempt from physical ejection.

## Back Assassination Mechanic

Sneaking up behind any combatant (players, bots, and New Ottoman enemies) allows for an instant lethal back assassination:
- **Assassination Geometry (`Weapon.is_back_assassination`)**:
  1. Attacker is positioned in the victim's rear hemisphere: `(attacker_pos - victim_pos).dot(victim_fwd) < -0.2`
  2. Attacker is facing roughly the same direction as the victim: `forward.dot(victim_fwd) > 0.4` (~65° cone).
- **Lethal Execution**:
  - Overrides standard melee damage to 500.0 with shield bleedthrough enabled (`bleedthrough = true`, `shield_multiplier = 2.0`), guaranteeing a clean one-hit kill through full shields and health.
  - Tags damage metadata with `info["assassination"] = true`, `info["backstab"] = true`, and `info["hit_zone_name"] = "assassination"`.
  - Emits `Weapon.assassinated(victim, attacker)`.
- **Animations & Feedback**:
  - Sets attack direction `info["dir"] = forward`, causing `CharacterAnimState.hit_dir_from_world()` to resolve to `HitDir.BACK`.
  - `CharacterAnimDriver` triggers the custom back-collapse animation: `death_back` for standing targets and `death_crouch_back` for crouching/sliding targets.
  - Kill feeds in match overlay (`MatchUI`), dedicated servers, and Horde mode (`HordeMatch`) announce `"<Killer> assassinated <Victim>"`.
  - Local combat feedback (`CombatFeedback`) displays a distinctive gold hitmarker with an elevated-pitch confirmation stinger.

