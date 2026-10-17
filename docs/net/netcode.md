# Project Long Colt — LAN netcode

Status: first pass. It is written against origin/main 38a5b77 and designed to drop onto
main-guns 62455c0 (LC Engineer), LC Modeler's PlayerModel (ffe2ca7+) and LC Animator's
CharacterAnimState / CharacterAnimDriver (ee83135). All newer APIs are probed with `in` or
`has_method`. Nothing here has been run in Godot yet; see "Testing" below.

## Shape

* **Topology:** listen server over ENet (`ENetMultiplayerPeer`). There are at most 4 humans, and
  the host plays. Free-for-all on `arena_lockout`, first to 25 kills. The host can fill empty
  slots with bots, and separately choose to refill slots that humans leave (see Bot slots).
* **Ports:** game on UDP 7777. LAN discovery on UDP 7778: 1 Hz JSON beacons to 255.255.255.255
  `{game:"PLC", v, name, map, players, max, port, refill}`.
* **Authority:** the host owns all of these:
  * damage and HealthShield;
  * deaths, kills and scores;
  * respawns (SpawnManager);
  * pickups, drops and ammo crates;
  * the win.

  Clients own their own movement and aim, but the host validates both.
* **Offline is unchanged.** With no peer, `multiplayer` is the default `OfflineMultiplayerPeer`:
  unique id 1 and `is_server()` true. Every host-only guard therefore passes, no RPC is sent,
  and NetMatch only does the following:
  * applies Settings when the match came from the menu (`Net.match_running`);
  * shows MatchUI (pause, scoreboard, win banner).

  Running `arena_lockout.tscn` straight from the editor leaves the scene's own tuning untouched.

## Files

| File | Role |
|---|---|
| `scripts/core/settings.gd` | `Settings` autoload: `user://settings.cfg` (name, colour, look scales, mouse aim assist, FOV, last IP, difficulty, bot fill). |
| `scripts/net/net.gd` | `Net` autoload: host / host_dedicated / join / leave, peer registry, protocol, password and capacity checks, scene loading. |
| `scripts/net/dedicated_server.gd` | Headless dedicated server (`-- --server`): config, match rotation, time limits, idle when empty. See `docs/net/servers.md`. |
| `scripts/net/server_config.gd` | Dedicated server config file (`tools/server/server.cfg.example`). |
| `scripts/net/net_upnp.gd` | UPnP port forwarding for listen and dedicated hosts (threaded). |
| `scripts/net/net_address.gd` | Typed addresses: IP or domain, `:port`, `[IPv6]:port`. |
| `scripts/net/lan_discovery.gd` | Beacon and listener. |
| `scripts/net/net_match.gd` | In-match node at `/root/ArenaLockout/NetMatch`. It sits before SpawnManager so its `_ready` runs first. Every in-match RPC lives here. |
| `scripts/net/net_host.gd` | Host checks for client-owned bodies: movement budget, inputs, shot replay, melee, loadout diffs. |
| `scripts/net/net_shot.gd` | Client shot capture from `Weapon.ray_fired`. |
| `scripts/net/net_weapon.gd` | Weapon ids, bounds, host replay, weapon / heat state sync. |
| `scripts/net/net_lag.gd` | 0.25 s collider history; rewind through PhysicsServer3D. |
| `scripts/net/net_anim.gd` | CharacterAnimState packing (10 bytes) and driver feed. |
| `scripts/net/net_fx.gd` | Remote tracers, muzzle flash, charge glow, overheat vent. |
| `scripts/net/net_pickups.gd` | Pickup keys, availability mirror, drops. |
| `scripts/ui/main_menu.gd`, `scenes/ui/main_menu.tscn` | Main menu (`run/main_scene`). |
| `scripts/ui/match_ui.gd`, `scripts/ui/menu_theme.gd` | In-match overlay and shared Halo 2-style theme. |

## Session flow

1. **Host:** Menu → LAN → pick a map, a player count and a mode → Host. `Net.host()` creates
   the server and starts the beacon, and the lobby opens. The host can still change them in the
   lobby (`Net.set_map`, `Net.set_mode`, `Net.set_rules`). Maps are listed in
   `scripts/core/map_list.gd` (`MapList`); `Net.map_id` is the session map. Player counts are
   `GameMode` (`ffa` is 8, `team_slayer` is 16). Rules are `GameModes` (`slayer`, `swat`).
2. **Join:** a client picks a listed game or types an IP. `Net.join()` connects, then the
   client sends `_rpc_register(name, colour, PROTOCOL)`.
3. **Registration:** the host checks the protocol and the current mode's player cap, makes names
   unique, and broadcasts the registry with `_rpc_players(registry, map_id, mode_id, rules_id)`
   (also re-sent when the host changes map, player count or mode).
4. **Start:** the host presses Start Match and `_rpc_load_match(map_id, mode_id, rules_id)` loads
   that map's arena on every peer.
   A join during a match loads the arena straight away (late join).
5. **Client ready:** in the arena, each client's NetMatch sends `_rpc_client_ready`. The host
   then does the following:
   1. Removes a bot if the slots are full (a bot from the initial fill or a refill).
   2. Sends the roster, scores, pickup state and live drops.
   3. Spawns a host-side puppet, registers it with `SpawnManager.register_player` and respawns
      it. The respawn goes to everyone with a teleport seq.
6. **End:** at the mode's score limit (25 FFA, 50 team), `SpawnManager.match_won` fires (`end_on_win` is set online), and
   `_rpc_game_over` shows the game-over screen on every peer. The host can choose Play Again
   (reloads the arena for everyone); anyone can choose Quit to Menu.
7. **Disconnects:** a client that drops is unregistered and its puppet is freed. If the host
   drops, every client returns to the menu with the reason shown.

### Bot slots (host only; offline Bot Arena unchanged)

Two independent Host-menu options, both saved in `user://settings.cfg` (`[game]`):

* **Fill empty slots with bots** (`bot_fill`, default on): at match start the host spawns
  `max_players() - humans` bots. The cap is the mode's (`ffa` 8, `team_slayer` 16).
* **Refill empty slots with bots** (`bot_refill`, default **off**; Morgon's decision):
  * On: a human who leaves mid-match is replaced by a bot (`SpawnManager.add_bot()`), so
    humans + bots stay at the mode's cap. A joiner then bumps a bot (`remove_bot()`).
  * Off: a leaver's slot stays empty until the next human joins it.
  * In both cases a joiner bumps a bot only if every slot is taken. That only happens with
    bot fill, or after a refill.
  * `Net.bot_refill` is host-side. The beacon advertises it as `refill`, and LanDiscovery
    exposes it as `bot_refill`.

## Entities

* **Ids:** peer id for humans (host = 1); `-n` for the host's bots.
* **Local player:** the arena's `Player` node on each peer.
* **Remote bodies:** every remote body, humans and bots, is a `player.tscn` instance with
  `net_puppet = true`. A puppet has:
  * no camera, HUD, AimAssist or input;
  * a hidden WeaponHolder;
  * membership of `aim_target`, so bend and bots see it.
* **Host-side human puppets:** `net_damage_authority = true` and they drop weapons on death.
  They are what the host's weapons, bots, kill volumes and pickups interact with.
* **Client-side puppets:** never take damage locally.
* **Clients' own player:** `net_damage_authority = false` (KillVolume and predicted hits do
  nothing locally), `auto_respawn = false`, no death drops, and pickups go through
  `pickup_request_hook`.

## Messages

| RPC | Dir | Channel | Content |
|---|---|---|---|
| `_rpc_state` | C→H | unreliable ordered, every physics tick | teleport seq, position, yaw, pitch, flags (crouch / reloading / zoomed), slot, 10-byte anim, weapon state |
| `_rpc_fire` | C→H | reliable | render tick, one request per frame of shots (see Shots) |
| `_rpc_melee` | C→H | reliable | — (puppet camera already posed) |
| `_rpc_pickup` | C→H | reliable | pickup key |
| `_rpc_client_ready` | C→H | reliable | — |
| `_rpc_snapshot` | H→C | unreliable ordered, 30 Hz | host tick; per entity: id, position, yaw, pitch, (shield, health), anim bytes, weapon state |
| `_rpc_correct` | H→C | reliable | accepted position, seq |
| `_rpc_shot_fx` | H→C | reliable | shooter id, origin, every ray end, hit flags (one per trigger pull / blast) |
| `_rpc_died` / `_rpc_respawned` / `_rpc_damaged` | H→C | reliable / reliable / unreliable | id, killer id, weapon, headshot, melee, quantised dir / position, yaw, seq / amount, dir |
| `_rpc_roster` / `_rpc_scores` / `_rpc_feed` / `_rpc_game_over` | H→C | reliable | host-authored match state |
| `_rpc_loadout` / `_rpc_ammo` | H→owner | reliable | slot entries (id, scene, magazine, reserve, heat state) and active slot / reserve gains |
| `_rpc_pickup_state` / `_rpc_drop` | H→C | reliable | key → available (sent on change, polled every 0.2 s) / drop spawn |
| `_rpc_grenade` | C→H | reliable | grenade type, release point, velocity (host checks count + cooldown on the puppet, and that the release is near its eye) |
| `_rpc_grenade_spawn` / `_rpc_grenade_boom` | H→C | reliable | grenade id, type, origin, velocity, thrower id / grenade id, type, detonation point |
| `_rpc_grenades` | H→owner | reliable | grenade counts per type (sent when the host's count changes, or to undo a refused throw) |

* **Quantised dir:** yaw byte | pitch byte << 8, or -1 for none.
* **Heat:** heat never gets its own RPC (`heat_changed` fires every tick). It rides the state
  and snapshot streams instead.
* **Bump `Net.PROTOCOL`** on any change to this table.

## Shoulder colour (protocol 14)

Players pick a third colour, the shoulder accent (left pauldron + helmet stripe, the model's
`accent_color` slot), on the Settings page's SHOULDER tab (armor palette). It is saved as
`[profile] accent`, travels like the visor colour (trailing `accent_html` on `_rpc_register` /
`_rpc_update_info`, `"accent"` in `Net.players` and the NetMatch roster) and is applied with
`PlayerColor.apply_accent`. Team modes replace only the primary colour; the accent stays the
player's own. Bots have no `"accent"` and keep the model's default red.

## New Ottoman weapon models (protocol 13)

`CharacterAnimState.WeaponModel` gained the seven New Ottoman weapons (`TUFEK` .. `YATAGAN`),
so a player carrying a weapon picked up from an enemy shows its own third-person mesh on every
peer. An older peer would get model ids it can't draw, hence the bump. Models:
`docs/weapons/new_ottoman_weapons.md`.

## Servers (protocol 12)

Besides the listen host, there are now dedicated servers (`-- --server`) and internet play.
Peer 1 on a dedicated server is the server itself: it has no entry in `Net.players`, no roster
entry and no body. `NetMatch` frees the arena's built-in Player there and skips MatchUI.
`_rpc_register` carries a password and `_rpc_players` the session name. Listen hosts can open
their port through UPnP. Players join by address, an IP or a domain. Hosting and joining:
`docs/net/servers.md`.

## Horde (protocol 11)

Horde's enemies are host-only and reach clients as visual copies through
`NetMatch/Horde/Enemies` (`NetEnemies`): spawn, a 20 Hz snapshot, death and despawn. Match
state, banners and the enemy kill feed go through `NetMatch/Horde`. Enemies join the lag
compensation through `NetMatch.lag_extra`. Details: `docs/modes/horde.md`.

Clients also resend `_rpc_client_ready` every `READY_RETRY` seconds until the roster lists them.
A client that loaded the arena before the host used to lose that message and never spawn.

## Movement: prediction and reconciliation

* Clients run their own Player physics (StepUp included) and stream state every tick.
* **Host checks.** The host checks each state against token buckets:
  * horizontal: 14 m/s, 3 m burst;
  * rise: 16 m/s, 2.5 m burst (GravLift is 12 m/s);
  * falling: free.

  If a state exceeds the budget, the host poses the puppet at the clamped position and sends
  `_rpc_correct`.
* **Client correction.** An error over 1 m snaps, and the camera absorbs the jump through
  `Player.absorb_view_offset`. A smaller error blends in at 12/s.
* **Teleport seq.** Host respawns bump a per-client seq. State packets carrying an older seq
  are ignored, so a client can't drag its puppet back from a respawn.
* **Remote bodies.** They interpolate 0.1 s (6 ticks) behind the newest snapshot in host-tick
  time. The client's estimate of host time tracks the fastest snapshot seen.

## Shots (server-authoritative hits)

The only weapon.gd hook is `signal ray_fired(from, to, hit)`, emitted in `_fire_ray` for every
ray (4 lines). The rest uses the shared Weapon path, so every weapon that fires through
`_emit_shots` → `_fire_ray` is networked generically.

**Client (`NetShot`).** Each frame's rays from one weapon become one request:

* weapon id (WeaponData `resource_path`);
* aim origin and basis (Quaternion);
* `last_shot_seed` after each round (from `fired`; bursts and AUTO can fire several rounds per
  tick);
* each round's spread;
* charged flag;
* alt_mode and zoomed;
* every ray's final direction, plus the `_bent` flag per ray.

The client's own hits, hit markers and FX stay local predictions; no damage is applied there.

**Host (`NetHost.fire` → `NetWeapon.replay`).** Steps in order:

1. **Type-check** every field (`NetShot.is_well_formed`).
2. **Basic checks:** the id must match the puppet's active weapon; the origin must be within
   1.25 m of the puppet's eye; ray / round counts must be within `MAX_SHOTS_PER_TICK` ×
   pellets.
3. **Weapon state:** reject if reloading or overheated; reject if out of ammo (magazine +
   reserve, or the battery).
4. **Rate:** a token bucket at `max_rate`, with `burst_count + 1` capacity.
5. **Charged shots:** accepted only if the client-reported `charge` peaked at ≥ 1.0 since the
   last charged shot. The host never simulates the trigger, so it uses the streamed weapon
   state.
   * The charge is therefore client-trusted: a modified client could report a full charge
     early. **Morgon accepted this for LAN play;** don't add host-side charge simulation
     unless that changes.
   * Hit zones are unchanged (Morgon): the rig's neck box (`NeckShape`, y 1.40-1.47) is part
     of `HeadUnarmored`. The hurtbox covers most of it, but the ~1 cm band just above the
     1.46 m hurtbox top counts as an unarmored head hit, by design. A shotgun blast centred
     there takes the head multiplier.
6. **Rewind:** NetLag rewinds every other body's colliders to the client's render tick (at most
   0.25 s back).
7. **Re-cast** through the host's own weapon, aimed from a proxy node at the request origin and
   basis:
   * **Single rays (rifle, pistol, carbine, DER charge):** the client's direction, if it lies
     within spread bounds + `aim_bend_angle` + 0.5°. The host can't reproduce AimAssist bend,
     because bend depends on the client's view of targets. `_fire_ray(dir, scale)` carries the
     charge multiplier.
   * **Pellet blasts:** `next_shot_seed` and `next_shot_spread` are set per round, then
     `_emit_shots()` is called. Same seed + aim gives the same pellets. The host then gets
     whatever damage model the weapon has; main-guns next makes that one `take_damage` per
     victim per blast. If the weapon has `aim_bend_angle > 0`, pellet 0's client direction
     (inside spread + bend) is set as `next_shot_centre` so the host blast follows the client's
     bend; the RNG still draws pellet 0's 2 values, so pellets 1.. match. Bendless pellet guns
     (the shotgun) skip this and replay exactly as before.
8. **Restore and clean up:** colliders are restored, ammo is spent, and `next_shot_seed` /
   `next_shot_spread` / `next_shot_centre` are cleared after a replay or a refusal so nothing leaks into the next
   shot.
9. **Effects:** damage → `damaged` / `died` signals → broadcasts. One `_rpc_shot_fx` with
   every ray end goes to everyone but the shooter.

Bots and the host's own shots go out as FX only.

**Projectiles.** None exist today (the DER charge is hitscan). If one is added, its
`_spawn_projectile` should check `NetWeapon.is_authoritative(self)` and spawn only a cosmetic
copy on clients.

## Weapon state, loadouts, pickups

* **Weapon state** (`NetWeapon.STATE_KEYS`): magazine, heat, overheated, charging, charge,
  vent_left, since_shot, charge_held.
  * The host applies it to its copy of a client's weapon through
    `heat_charge.apply_net_state()` when present, else through the plain members.
  * The magazine is applied only for battery weapons.
  * Remote peers use it for the charge glow and the overheat vent (NetFx; WeaponFx is
    first-person only).
* **Loadouts:**
  * Only the host changes inventories (pickups, crates, respawn).
  * It polls its copy of each client's holder at 5 Hz. When weapon ids or instances change,
    the owner gets `_rpc_loadout`. Instances matter because a battery swap keeps the id.
  * The client runs `WeaponHolder.apply_loadout()`. A slot that keeps the same id keeps the
    client's instance, but a battery weapon takes the host's magazine. Heat state comes from
    `heat_charge.get_net_state()`.
  * Reserve increases with no loadout change go out as `_rpc_ammo`.
* **Pickups:**
  * Placed pickups are keyed by node path; host drops are keyed `drop/<n>` and rebuilt on
    clients.
  * Clients only mirror availability (`net_set_available`). `WeaponPickup` / `AmmoCrate`
    change state only when `is_authority()`.

## Third-person animation (LC Animator contract)

* **What travels.** `CharacterAnimState.to_dict()` (animator-main e1cc52e) for every body, sent
  as a value array in `NetAnim.keys()` order (`scripts/net/net_anim.gd`). It covers:
  * velocity, on floor, crouch, slide and dead;
  * the active and holstered weapon types;
  * the fire, action, action-cancel, death and flinch counters;
  * action and action duration;
  * death dir and death impulse, and flinch dir.

  Yaw and pitch are not in the array; they ride the snapshot pose. Receivers coerce each value
  to its `to_dict()` default type, and drop a malformed array.
* **Authority** (its `CharacterAnimSource` stays enabled):
  * the client, for its own player (in `_rpc_state`);
  * the host, for its own player and its bots (in the snapshot).
* **Host override.** For a client's player, the host replaces the death and flinch fields
  (`d ds dd di fl fd`) with the ones its own puppet's source recorded from the authoritative
  `died` / `damaged` signals.
* **Remote copies** (every puppet): `NetAnim.make_remote()` disables the source, and each
  packet calls `driver.apply_state(CharacterAnimState.from_dict(...))`.
* **Baseline.** `reset_baseline()` runs on puppet spawn (including a late join) and on every
  respawn. The next applied state becomes the baseline without firing one-shots. A late joiner
  therefore sees an already-dead body posed dead, but the death clip doesn't replay. That is
  the driver's API; replaying it would need a "play death on baseline" option in the driver.
* **Damage info.** `damaged` / `died` info carries world `dir` (shooter → victim) and an
  optional `impulse`, on Player and Bot:
  * Weapon hit info sets `dir`;
  * `Player.take_damage` and `Bot.take_damage` fill it when missing.

  Clients get `dir` through `_rpc_died` / `_rpc_damaged`; the impulse reaches them only via
  the host's death fields.
* **Not synced:**
  * Head hitboxes stay stance-driven.
  * Ragdoll is client-local (`death_started(dir, impulse)`).
* **Rate.** Remote drivers are fed at the packet rate: snapshot rate for the host's bodies,
  and the client send rate on the host. `Net.PROTOCOL` is 7 (2: the anim wire format changed; 3: map id on `_rpc_players` / `_rpc_load_match`; 4: visor colour on `_rpc_register` / `_rpc_update_info`; 5: grenade RPCs; 6 was used on unmerged branches; 7: mode id and rules id on the player and load RPCs, and the weapon id on shot fx for rockets).

## Settings and colour

* **Look and aim:** sensitivities are multipliers of the scene tuning (1.0 = unchanged). FOV
  -1 means the scene default. Mouse aim assist maps to `AimAssist.mouse_enabled`.
* **Armor colour:**
  * 32 presets plus a custom picker, with a live 3D preview (`ArmorPreview`). The colour itself travels in the registry, not a preset
    index.
  * It is applied through the PlayerModel contract (`PlayerColor.apply`):
    1. `set_primary_color`;
    2. else the `primary_color` instance uniform;
    3. else the StandardMaterial albedo.
  * Colours are sRGB, passed as-is.
* **Visor colour:** Settings → VISOR tab (16 presets + custom), saved as `[profile] visor`. It
  travels in the registry as `"visor"` next to `"color"` (`_rpc_register` / `_rpc_update_info`,
  PROTOCOL 4), is copied into the NetMatch roster, and is applied with `PlayerColor.apply_visor`
  (`PlayerModel.set_visor_color`, the `visor_color` instance uniform). Bots keep the gold default.
* **Shoulder colour:** Settings → SHOULDER tab (the 32 armor presets + custom), saved as
  `[profile] accent`, default Red. Travels as `"accent"` exactly like the visor (PROTOCOL 14) and
  is applied with `PlayerColor.apply_accent` (`PlayerModel.set_accent_color`, the `accent_color`
  instance uniform on the left pauldron and helmet stripe). Team modes keep it; bots keep the
  model's default red.
* **Grenades:** host-authoritative. The host's `Grenade` deals the damage (`Grenade.apply_blast`);
  every client gets a visual copy (`authoritative = false`, the thrower's own included, so only
  the count is predicted) and the host's detonation point. A client copy whose fuse runs out
  waits up to 0.75 s for the boom before going off on its own (visual only).
* **Keybinds:** Settings → Keybinds rebinds keyboard / mouse (two slots per action, controller
  bindings untouched) through `Keybinds` (`scripts/core/keybinds.gd`). Only changes from the
  project.godot defaults are saved, in `settings.cfg` `[keybinds]`. Binding an input already in
  use removes it from the other action. Pause and the stick look actions aren't rebindable.
* **Local body:** the local model sets `first_person_hidden = true` (render layer 2), and every
  gameplay camera culls layer 2.
* **Custom Maps (Level Editor Replication):**
  * When a host selects a Level Editor custom map (`custom:<level_name>`), the level layout is serialized into JSON and transferred via reliable RPC to joining clients (`CustomLevels.cache`).
  * Clients do not require the map file on disk: `CustomArena` (`scenes/main/arena_custom.tscn`) dynamically reconstructs all geometry blocks, custom materials, collision hulls, spawns, lifts, weapon racks, grenade spawns, and enemy squads via `LevelBuilder`.
  * Dedicated servers seamlessly support custom map rotations through `--server-config` specifying `levels_dir`.
* **Grenade Pickups & Death Drops:**
  * Placed `GrenadePickup` nodes are indexed and tracked by `NetPickups` alongside weapons.
  * Pickups sync visibility, remaining grenade counts, and refill timers.
  * On non-kill-volume deaths, carried grenades drop as loot pickups (`_rpc_drop_pickup`) with raycast collision clamping to prevent falling through floor or clipping into walls.
  * Untouched drops despawn on a timer, while emptied drops free themselves immediately on all peers.
* **Assassinations & Melee Netcode:**
  * Melee damage and assassinations are calculated host-authoritatively in `_apply_melee`.
  * An attack satisfying `Weapon.is_back_assassination` deals lethal 500 damage, sets `info["assassination"] = true`, and propagates `info["dir"] = forward`.
  * Every client's `CharacterAnimSource` maps `info.dir` to `HitDir.BACK`, animating the victim's back-collapse death (`death_back` / `death_crouch_back`) identically across all proxies.
  * Kill feed broadcasts announce `"<Killer> assassinated <Victim>"` across the match.

## Testing (not done: no Godot binary on the build box)

1. **Offline:** run `arena_lockout.tscn` directly. It must behave exactly as before.
   Menu → Bot Arena at each difficulty.
2. **Two instances on one machine:** Host, then Join `127.0.0.1`. Check:
   * movement, shots and kills on both sides;
   * respawn teleports;
   * pickups and weapon swaps;
   * DER heat and charge;
   * shotgun blasts;
   * game over and Play Again.
3. **Four peers on a LAN with bot fill;** a late join; a client quitting mid-match, with
   refill off (the slot stays empty) and on (a bot takes the slot).
4. **Lag compensation:** add artificial latency (e.g. `tc netem` on Linux) and check moving
   targets.
