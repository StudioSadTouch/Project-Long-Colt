# New Ottoman enemy types (Phase 0, greybox)

Source: `New Ottoman Enemy Board.pdf` (Opposing Force v0.1). This is the in-engine version of
that board: three corps, ten ranks, the orta encounter. Everything is greybox: bodies are
primitives built in code and sounds are synthesised. Each piece is meant to be swapped for art
without touching the AI.

## Files

| What | Where |
|---|---|
| Rank data (one `.tres` per rank) | `resources/enemies/new_ottoman/*.tres` (`EnemyType`, `scripts/enemies/enemy_type.gd`) |
| Enemy body (a `Bot` configured by its type) | `scenes/enemies/enemy.tscn`, `scripts/enemies/enemy.gd` |
| Greybox silhouette, hitboxes, procedural animation | `scripts/enemies/enemy_rig.gd` |
| Janissary damage states | `scripts/enemies/armor_stages.gd` |
| Orders and per-role habits | `scripts/enemies/enemy_brain.gd` (extends `BotBrain`) |
| Squad / encounter phases | `scripts/enemies/orta.gd` |
| Placeholder cues (horn, cymbal, glint, hum) | `scripts/enemies/new_ottoman_sounds.gd` |
| Issue weapons | `resources/weapons/new_ottoman/*.tres`, `scenes/weapons/new_ottoman/*.tscn` (own models: `docs/weapons/new_ottoman_weapons.md`) |
| Encounter test yard | `scenes/enemies/orta_yard.tscn` (`scripts/enemies/orta_yard.gd`) |
| Lineup / black-fill test | `scenes/enemies/new_ottoman_lineup.tscn` |
| Self-test | `tests/new_ottoman_self_test.gd` |

Run the yard or the lineup with F6 in the editor. Run the test with:
`flatpak run org.godotengine.Godot --headless --path . --script res://tests/new_ottoman_self_test.gd`

## Roster

Pools are against the player's weapons (rifle 9/round, pistol 22, the player has 70 shield +
45 health). "Plate" is `HealthShield.shield` with recharge off: it never comes back, headshots
don't multiply on it (zone multipliers only touch health), and the hit that breaks it doesn't
bleed through, the same as a shield.

| Rank | Corps | Role | Height | Plate / Health | Speed | Kit | Tell |
|---|---|---|---|---|---|---|---|
| Nefer | Janissary | HEAVY | 2.6 m | 150 / 100 | 0.82 | tüfek, yatağan | oxblood crest |
| Odabaşı | Janissary | HEAVY | 2.6 m | 180 / 110 | 0.82 | tüfek, yatağan | ochre crest, one gilt band |
| Çorbacı | Janissary | COMMANDER | 2.6 m | 220 / 130 | 0.82 | tüfek, yatağan | white crest, gilt chest |
| Ağa (boss) | Janissary | COMMANDER | 2.75 m | 400 / 250 | 0.82 | tüfek, yatağan | full tombak, plume |
| Azab | Azab | LINE | 1.75 m | 0 / 50 | 0.95 | glaive rifle | red cap |
| Okçu | Azab | GRENADIER | 1.75 m | 0 / 50 | 0.95 | humbara launcher, glaive rifle | cobalt cap |
| Bölükbaşı | Azab | SQUAD_LEADER | 1.75 m | 0 / 75 | 0.95 | glaive rifle | ochre cap, signal horn |
| Akinji | Akinji | RAIDER | 1.8 m | 0 / 65 | 1.12 | raider carbine, kılıç | oxblood coat |
| Akinji marksman | Akinji | MARKSMAN | 1.8 m | 0 / 55 | 1.12 | long rifle, kılıç | cobalt coat, scope glint |
| Akıncı Beyi | Akinji | RAIDER (officer) | 1.8 m | 30 / 95 | 1.12 | raider carbine, kılıç | pale coat, plume, trophies |

Every rank carries the turquoise sensor slit, the faction's only glow. The face hitbox sits on
it: the open face for Azab and Akinji, the slit for Janissaries.

The Azab and Akinji ranks have `hitbox_scale = 1.3` (`EnemyType`, Body group): their hurtbox,
helmet, face and neck boxes are 1.3x wider and deeper than their size alone would give, so a
1.75 m conscript isn't much harder to hit than a Marine (Azab hurtbox 0.65 m across, a Marine's
0.82 m). Heights stay the same, so the hurtbox top stays under the helmet and head shots still
land on the head. Janissaries use 1.0.

### Issue weapons

All seven are real `Weapon` scenes with their own first-person and third-person models
(`docs/weapons/new_ottoman_weapons.md`), so enemies drop them Halo 2 style and the player can
use them. They are also on the Weapon Range's second rack. Bots pick each one's role from its
mechanics (`BotWeaponPrefs`).

| Weapon | Handled like | Numbers |
|---|---|---|
| Tüfek (Janissary heavy rifle) | marksman carbine | semi, 24 dmg, 1.2/s, 8 rounds, zoom |
| Yatağan (vibro-blade) | longsword | melee primary, 95 dmg, lunge 5.5 m; a rising hum when drawn |
| Glaive rifle (Azab) | standard rifle | semi, 10 dmg, 2.5/s, 12 rounds, 95 dmg bayonet with 5 m lunge |
| Humbara launcher (Okçu) | rocket launcher | lobbed shell, 20 m/s with 12 m/s² drop (about 33 m max), 45 dmg / 4.5 m blast |
| Raider carbine (Akinji) | standard rifle | auto, 6 dmg, 9/s, 24 rounds |
| Long rifle (marksman) | marksman carbine | semi, 40 dmg, 0.9/s, 3x zoom |
| Kılıç (sabre) | longsword | melee primary, 75 dmg, lunge 4.5 m |

## Behaviour

`EnemyBrain` keeps BotBrain's perception, aim model, melee and navigation, and adds orders:

- **HOLD**: stays within 4 m of the post, strafing but never off a ledge. This is the
  Janissary gunline.
- **ADVANCE**: the Azab screen. Walks to 15 m from the target in a loose line (2.5 m
  slots), then stands and volleys.
- **PEEL**: the Azab withdrawal to a flank post.
- **FLANK**: the Akinji raider. Runs wide to a flank point and harasses. It withdraws when it
  loses 30 % of its pool in 2 s or the target gets inside 7 m, then circles back from the next
  flank point.
- **OVERWATCH**: the marksman. Stays within 1.2 m of the perch. A scope glint and ping come
  0.55 s before every shot.
- **CHARGE**: the yatağan comes out, then the Janissary closes and cuts.
- **ROUT**: runs to a fallback point and only fires if cornered (under 6 m).

The Azab line, Okçu and Bölükbaşı fire on the orta's volley beat (1.5 s on, 1.5 s off). The
Okçu lob on a high arc (`BotWeaponPrefs.ballistic_direction`). Enemies never detour for
pickups.

### Janissary damage states (`ArmorStages`)

1. **FULL**: plate takes the hits, which throw sparks and an occasional ricochet whine.
2. **SPALLED** (plate at half or less): the crest and pauldrons come off as debris, so the
   silhouette shrinks.
3. **EXPOSED** (no plate): the chest plate and tassets drop, the frame struts and hoses show
   and the hydraulics vent. Speed goes to x1.35, aggression to 1, the blade comes out, and a
   posted Janissary switches to CHARGE.

### The orta (`Orta`)

| Phase | Trigger | Orders | Cue |
|---|---|---|---|
| IDLE | none | everyone HOLDs their post | none |
| SCREEN | first contact (sight or damage, shared with the whole squad) | Azab line and Bölükbaşı ADVANCE; Okçu hold behind; marksman OVERWATCH | advance horn |
| PEEL | 34 % of the Azab line down, or 25 s of SCREEN | Azabs PEEL to the flanks; raiders FLANK | withdraw horn |
| BREAK | Çorbacı killed | Azabs ROUT; Janissaries CHARGE | cymbal |

Killing the Bölükbaşı routs the Azabs early, with a horn, and the Janissaries keep holding.
Points come from `Marker3D` children of `Orta/Points`, matched by name prefix: `Peel*`,
`Flank*`, `Perch*`, `Platform*` and `Fallback*`. Without them the orta works out flank and
peel points around the contact.

## Tuning knobs

- **Lethality**: `EnemyType.fire_rate_scale` (cadence) and `aim_error_scale` (initial and
  minimum aim error). Halo-style: plenty of inaccurate fire. Azab 0.9 / 2.4, Janissary
  0.65 to 0.9 / 1.4 to 0.9, Akinji 0.85 / 1.8, marksman 1.0 / 0.6. A player standing still in
  the open against the full yard orta lasts about 2 to 4 s on Normal. Enemies keep 35 % of the
  preset's strafe error bump and lead moving targets at 0.8 (`Enemy.STRAFE_ERROR_SCALE`,
  `LEAD_SKILL`), so ADAD still helps but doesn't make you untouchable.
- **Fire discipline**: an enemy aims at the part of its target it can see (head or face over
  cover) and holds fire while level geometry or a squadmate blocks the line
  (`EnemyBrain._aim_point`, `_line_clear`).
- **Accuracy and nerve**: `aim_error_scale`, `reaction_scale`, `aggression`,
  `melee_eagerness`, `strafe_scale`. These apply on top of the campaign `BotDifficulty`, so one
  preset scales the whole faction.
- **Survivability**: `armor`, `health`, `spall_fraction`, `exposed_speed_scale`.

## Gunfire

Enemies (and bots) are heard through `CombatFeedback`'s 3D gunfire for other combatants. It
takes each gun's sound from the weapon scene's own `WeaponFx` (`WeaponAudio.fire_sound_of`), so
the New Ottoman guns sound like the guns they inherit from: the tüfek and long rifle like the
marksman carbine, the glaive rifle and raider carbine like the rifle, the humbara launcher
like the rocket launcher. On LAN, a client hears an enemy's copy when the host's shot FX
arrives (`NetMatch.body_of`).

## Shared code touched

- `Bot`: adds `body_scale` (capsule, eye, hurtbox and body aim point scale by type height) and
  `speed_scale`. Both default to 1.0, so arena bots are unchanged.
- `BotBrain`: adds `_shot_direction()` (ballistic aim for lobbed projectiles, straight
  otherwise), plus the `_prefer_high_arc()` and `_fire_allowed()` subclass hooks.
- `BotWeaponPrefs.ballistic_direction()`.
- `WeaponData.projectile_gravity` and `Rocket`, which applies it. It defaults to 0, so the
  rocket launcher is unchanged.

## Horde

The enemies also fight in the Horde mode (`docs/modes/horde.md`). There each squad is an
`Orta` with `assault` on, and `Orta.hunt()` sends the last survivors after a defender. On LAN,
clients see `Enemy.net_copy` copies driven by `NetEnemies`.

## Not done yet (Phase 0 scope)

- Real meshes and animation. The rigs are primitives built in code, and rank is a colour
  swap, as the board's build list plans. The weapons the enemies hold are still the rig's own
  box props; the dropped weapons have their own models.
- Real horn, cymbal and blade audio. `NewOttomanSounds` returns synthesised placeholders, one
  function per cue.
- Forward Outpost 7 itself. `orta_yard` is a stand-in with the same beats (courtyard, command
  platform, catwalks, perch).
- Akıncı Beyi has no squad rule of his own yet; he fights as a tougher raider.
