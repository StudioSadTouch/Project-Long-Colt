# Horde

Co-op survival against waves of New Ottoman enemies (`docs/enemies/new_ottoman.md`), in the
style of Halo's Firefight. Pick **Horde** as the mode in **Bot Arena**, on any map. The Bot
Arena bots fight on your side.

Horde also works on **LAN** (protocol 11): host it from the LAN menu like any other mode. Every
human and bot is on one side. The host runs the enemies; clients see replicated copies (see
"LAN" below).

## Files

| What | Where |
|---|---|
| Match logic (waves, lives, scoring, game over) | `scripts/core/horde_match.gd` (`HordeMatch`, added by NetMatch as `NetMatch/Horde`) |
| Wave composition and points | `scripts/core/horde_waves.gd` (`HordeWaves`) |
| HUD | `scripts/ui/horde_hud.gd` (`HordeHud`) |
| LAN replication | `scripts/net/net_enemies.gd` (`NetEnemies`, `NetMatch/Horde/Enemies`) |
| Tests | `tests/horde_self_test.gd`; two-process LAN check `tests/horde_lan_check.gd` |

## Rules

- **Waves** come in rounds of 5. Each wave is a list of squads, and each squad is one `Orta` in
  assault mode.

  | Wave | Name | Squads |
  |---|---|---|
  | 1 | Screen | Bölükbaşı + 4 Azab |
  | 2 | Raiders | Bölükbaşı + 3 Azab + 2 Okçu; 2 Akinji |
  | 3 | Gunline | Bölükbaşı + 4 Azab; 2 Nefer |
  | 4 | Overwatch | Bölükbaşı + 3 Azab + Okçu; Akinji + marksman; Odabaşı + Nefer |
  | 5 | The Orta | the board's full Phase 0 orta, Çorbacı included |
  | every 10th | The Ağa | Ağa + Odabaşı + 2 Nefer; Akıncı Beyi + 2 Akinji; an Azab line |

  Each later round adds:
  - up to +3 Azabs to every line;
  - an extra Azab squad on waves 1–4;
  - from round 3, a Nefer in every Janissary squad.

  At most 20 enemies are alive at once; squads past that wait for room.
- **Spawning**: each squad appears at the map spawn point farthest from (and out of sight of)
  every defender, 10 m or more from the wave's other squads. Members stand in rings snapped to
  the navmesh.
- **Contact**: every 4 s each squad is told where its nearest defender is (Firefight enemies
  always come looking). They still have to see you before they shoot.
- **Assault orta**:
  - On first contact the Janissaries and Okçu advance with the Azab line. The Okçu stop at
    24 m to lob.
  - Raiders flank at once, and keep circling flank points around the contact.
  - The PEEL and BREAK phases work as in the encounter: kill the Çorbacı and his orta breaks.
- **Stall breaker**: once a wave is down to 3 enemies, or has run 75 s, the survivors hunt the
  nearest defender every 6 s (Janissaries charge, routed Azabs rally). The HUD then marks every
  remaining enemy in turquoise.
- **Lives**:
  - You start with 7, shared by the whole team.
  - Every player death spends one. With none left, a dead player stays down.
  - Each round ends with +3 lives (up to 12), and downed players come back first.
  - Bots respawn for free.
- **Game over**: every player down with no lives left. The game-over screen says "The Porte
  wins", the banner shows the waves survived, and Play Again restarts the same map offline.
- **Between waves** (12 s, 8 s before wave 1): everyone's reserves, batteries and grenades are
  refilled.
- **Score**: each kill adds Kills and Points to the killer's scoreboard row (ranked by points).
  Kills by enemies add no scoreboard rows.

  | Enemy | Points | Enemy | Points |
  |---|---|---|---|
  | Azab | 10 | Akinji | 20 |
  | Okçu | 15 | Marksman | 30 |
  | Bölükbaşı | 30 | Akıncı Beyi | 80 |
  | Nefer | 50 | Çorbacı | 120 |
  | Odabaşı | 60 | Ağa | 500 |

## Difficulty

The menu's bot difficulty sets both the enemies and your allies. Enemies apply each rank's
temperament on top of it.

One Normal arena bot outfights several enemies, the way a Spartan outfights Grunts. In a
headless run, 4 Normal allies cleared round 1 with no deaths. So **the ally count is the main
difficulty dial**:
- 0–1 bots for a real fight;
- 3 or more for a relaxed one.

A player standing still in the open against a whole orta lasts about 2–4 s on Normal.

## Shared code touched

- **`GameModes`**:
  - Horde entry;
  - `is_horde`;
  - `allows_online`;
  - `ids(online)`.
- **`SpawnManager`**:
  - `coop_team` (bots join the player's team);
  - `respawn_gate` and `respawn_now`;
  - `THREAT_GROUP`: spawns avoid Ottomans, and enemy killers get no scoreboard row;
  - `pick_spawn_for`, `get_spawn_points`, `get_players`.
- **`NetMatch`**: adds `HordeMatch`; `end_match()` shows game over offline too.
- **`MatchUI`**: Play Again offline; a Points column when scores carry points.
- **Main menu**: the LAN host and lobby rules pickers skip offline-only rules.
- **`Net`**: `host` and `set_rules` refuse offline-only rules.
- **`BotBrain`**: `_aim_point()` hook.
- **Enemies** (beyond the encounter version):
  - `Orta.assault` and `Orta.hunt()`;
  - forced alerts;
  - aiming at the visible part of a target and holding fire when the line is blocked by
    geometry or a squadmate;
  - better lead on moving targets.

## LAN

The host owns the match: enemies think, shoot and take damage only there. Clients mirror it.

- **Enemies** (`NetEnemies`): the host announces each spawn (net id, rank, position). Each
  client builds a visual copy: an `Enemy` with no Brain, physics off, `net_copy` set, and
  `take_damage` doing nothing. 20 snapshots a second carry position, yaw, head pitch, plate
  and health, crouch, aiming and the active weapon slot. Copies are drawn at
  `NetMatch.render_tick()`, the same delay as remote players. Plate spalling, the exposed frame,
  the blade and the weapon pose all follow from that. Deaths and despawns are sent reliably; a
  corpse leaving the host's tree for any reason despawns its copies.
- **Shots**: enemy shots reach clients as NetMatch shot FX under the enemy's net id (tracers,
  lobbed humbara shells). A client's shot at a copy shows a hit marker locally and resolves on
  the host against the real enemy. Enemies are in NetMatch's lag compensation
  (`NetMatch.lag_extra`), so the host rewinds them to what the client saw. Kill credit, points
  and the kill feed follow.
- **Match state** (`HordeMatch._rpc_state`, twice a second and on every change): wave, phase,
  countdown, lives, enemies left, the hunt flag and who is down. Banners and the enemy kill feed
  have their own RPCs, and game over uses `NetMatch.end_match`.
- **Joining**: a client says hello when its Horde node is ready. The host answers with every
  enemy in the arena and the current state, so late joiners see the wave in progress. Clients
  retry until the host welcomes them, in case they loaded the arena first. `NetMatch`'s
  client-ready message now retries the same way; before, a client that loaded first was never
  registered, in any mode.
- **Teams**: in Horde, `NetMatch` puts the host and every joining human on
  `SpawnManager.PLAYER_TEAM` with the bots.
- **Lives** are shared across all humans. Remote players are hooked as they join, and game over
  waits until every human is down.

`tests/horde_lan_check.gd` runs a real host and client on this machine and checks the whole
path. Start the host, then the client, within a few seconds of each other.
