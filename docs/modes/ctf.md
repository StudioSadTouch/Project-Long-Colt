# Capture the Flag

Rules entry `ctf` in `scripts/core/game_modes.gd` (objective `ctf`, teams only, first to 3).
Picking it with Free for All switches the player count to Team 4v4 (menu, `Net.set_rules`,
`Net.start_offline` / `host` all go through `GameModes.fit_mode`); picking Free for All while
CTF is selected puts the rules back to Slayer.

## Pieces
- `scripts/core/ctf_match.gd` (`CtfMatch`, node `NetMatch/Ctf` on every peer). The host runs
  the rules; clients mirror a small state message (captures, each flag's state, carrier net id,
  position) sent on every change and once a second, plus feed / banner text.
  - take: touch the enemy flag (home or dropped). Carriers keep their weapons.
  - drop: the carrier dies or leaves; the flag goes home after 25 s, or at once if it fell off
    the map. return: touch your own dropped flag.
  - capture: carry it onto your base ring while your own flag is home.
  - Kills never end a CTF match (`SpawnManager.kill_win = false`); `declare_winner` does.
    Offline, scores and captures reset and play goes on (like Slayer offline).
- Bases: `FLAG_Red*` / `FLAG_Blue*` nodes in the arena if a map has them; else the team spawn
  nearest the middle of that team's spawns; else (Lockout, no team spawns) the two spawns
  farthest apart, with every other spawn handed to the nearer base
  (`SpawnManager.team_spawn_override`).
- `scripts/ui/ctf_hud.gd` (`CtfHud`, local player): score under the team label, a marker per
  flag (pinned to the screen edge when off screen), "YOU HAVE THE FLAG" prompt + base marker.
  Works with the first-person and over-the-shoulder cameras.
- Scoreboard: team headers show captures and rows gain a Caps column (`MatchUI`).
- Bots (`BotBrain._objective` -> `CtfMatch.goal_for`): a third defend (guard the flag, chase
  a thief, return a dropped flag), the rest attack (take the flag, escort a carrier). A carrier
  runs home even while fighting, and skips searching and pickup detours.

## Tests
`tests/ctf_self_test.gd`: bases and spawn split on Lockout, take / capture / home rule / return
by touch / drop / timer / win and offline reset, payload round trip, bots taking a flag.
Checked once over a real host + client on localhost (flag state and captures reach the
client; carrier resolved by net id).
