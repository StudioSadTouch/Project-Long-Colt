# Ivory Tower (Halo 2, 2004): Greybox Blockout Spec for Project Long Colt

> **Read this first:** No published measurements of Ivory Tower exist in the sources I found. **Every dimension is ESTIMATED.** I read the plan from the two MCC loading-screen floor plans, the Bungie "Cyclotron" design doc sketch and the Halopedia in-game overview screenshot. I then scaled it so the plaza, catwalk and halls read right next to a 2.1 m Spartan. Use it as a balance-test map *in the spirit of* Ivory Tower, not as a copy. Tags: **[S]** = sourced, **[E]** = estimated by me.

Build: `blender -b --factory-startup --python tools/ivory_tower/build_ivory_tower.py` (from the repo root). Headless runs need numpy visible to Blender's Python for the glTF exporter. Use `pip install --target <dir> numpy` and run with `PYTHONPATH=<dir>`.

The script regenerates all of these (edit the script, never the outputs):

| Output | What it is |
|---|---|
| `assets/models/environment/ivory_tower_greybox.glb` | Geometry. Meshes are `*-col` (trimesh StaticBodies on World layer 1). The atrium skylight is `-colonly`, so the sun gets in. Empties are markers. |
| `tools/ivory_tower/ivory_tower_greybox.blend` | The same scene, grouped into collections per area. |
| `scenes/levels/ivory_tower.tscn` | Level: glb + `Spawns` (26 Marker3D) + 3 GravLifts (elevator, 2 vents) + 19 OmniLights + KillVolume at y -8. |
| `scenes/main/main_ivory_tower.tscn` | Offline testbed: Player + 9 weapon pickups + sun/environment, no bots. |
| `scenes/main/arena_ivory_tower.tscn` | Arena (Bot Arena / LAN via `MapList`): pickups, 3 bots, runtime navmesh, 3 lift nav links, 24 roam points, NetMatch. |
| `tools/ivory_tower/previews/*.png` | Overheads per floor (north up, 66 m frame, upper floors cut away), a view from the north walkway and a south-east cutaway. |

## 1. Scale and levels
- Player 2.1 m, jump 2.2 m, 7.5 m/s, gravity 22 (`scripts/player/player.gd`).
- **Footprint 60 × 58 m** (x -30..30, z -40..18) [E]. That is mid-sized: smaller than Headlong and bigger than Lockout. H2 lists 2–12 players [S]; the design doc says "slightly larger than Wizard" [S] (an early draft).
- Indoor top floor of a New Mombasa tower [S]. Wings and north block have a ceiling at **13.5 m**. The main room rises to a **17 m skylight**.
- **L0 = 0** (plaza, canyon, lower halls), **L1 = 4.5** (catwalk ring, top of the stone steps, Dark/Light rooms), **L2 = 9** (north walkway, galleries) [E].

## 2. Coordinates
Godot axes: +Y up, **+X east, -Z north**. North is the top of the MCC plan: the elevator and stone-steps end. The origin is the centre of the sunken palm plaza.

## 3. Callouts
| Callout | Where (x, z) | Floor y | Notes |
|---|---|---|---|
| Plaza | r 10 round (0, 0) | 0 | Sunken circle with a flagstone ring and 5 palm trunks [S screenshot]. Doors S / SE / SW to the Lower Ring. |
| Stone Steps | x ±1.5..10.75, z -6..-28 | 0 → 2.25 → 4.5 | Grass terraces (15.7° / 20.6°) with a mid landing and two boulders [S screenshot, design doc]. |
| Canyon | x -1.5..1.5, z -6..-28 | 0 | Central alley with the stream. Rocket stand-in in the alcove under the top-of-steps bridge, behind the drainage grate [S]. |
| Elevator | (0, -34) | 0 → 9 | Grav lift, 7 m volume, ~10.5 m apex. Rises through an L1 hole, so L1 can drop in too [S "serves upper and lower halves"]. |
| Lower North Hall | x -16..16, z -40..-28 | 0 | Elevator bottom, sword stand-in by the grate, offensive spawns [S]. |
| Magnum West / East | x ±16..23, z -40..-30 | 0 | Cul-de-sacs off the lower hall [S]. |
| Lower Side Halls / Lower Ring | under the catwalk | 0 | Long halls curving back to the plaza [S]. |
| Catwalk | ring over the plaza wall | 4.5 | Wooden ring with steel pillars [S screenshot]. Joins the top of the steps. |
| Corner West / East | x ±16..24, z 2..18 | 0 → 4.5 | Stair rooms, Lower Ring → catwalk / wing [E, H2 plan stair icons]. |
| Dark Room | x -30..-16, z -28..2 | 4.5 | Shotgun, two air-vent lifters to the West Gallery [S]. Back Section (x < -25) holds the flag [S]. Dim light. |
| Light Room | x 16..30, z -28..2 | 4.5 | Overshield [S]. Ramp Room lane (x 25.5..30) climbs to the East Gallery. Second overshield at the top [S "ramp with an overshield"]. |
| North Walkway | x -30..30, z -40..-29 | 9 | Commanding view south over the whole room [S design doc]. Sniper stand-in by the elevator [S "third floor near the elevator"]. Corner stairs down to L1. |
| Gallery West / East | x ±16..30, z -29..-6 | 9 | Windows over the main room. Planters as sniper posts [S]. |

## 4. Connections to test [E]
| Check | Geometry | Expected |
|---|---|---|
| Elevator ride | 7 m volume, 12 m/s | Peaks at 10.47 m (headless test). Strafe off onto L2 (9). |
| Vent ride | 3 m volume from L1 | Peaks at 10.91 m. Pops up through 2.5 m holes into the West Gallery. |
| Canyon jump | 3 m gap | Easy running jump across the stream. |
| Catwalk → plaza | 4.5 m drop | Check fall damage. |
| North Walkway ↔ plaza centre | ~35 m, 9 m above | Main long sightline (carbine). Watch whether it dominates. |
| Gallery windows ↔ opposite gallery | 32 m across the atrium | "Battling an opponent on the walkway opposite yours" [S design doc]. |

## 5. Weapons (Long Colt five-gun mapping [E] of the H2 positions [S])
- **Marksman Carbine** (sniper): North Walkway by the elevator.
- **Directed Energy Rifle** (rockets, 90 s): canyon alcove behind the grate.
- **Combat Shotgun** (90 s): Dark Room (H2 shotgun), and Lower North Hall by the grate (H2 energy sword).
- **Service Pistol**: both magnum cul-de-sacs.
- **Standard Issue Rifle**: plaza, south catwalk, East Gallery.
- `PWR_Overshield_LightRoom` / `PWR_Overshield_RampTop`: markers only. `FLAG_Blue_BackSection` / `FLAG_Alt_TJunction` are One Flag markers.

Spawns: 6 Red (north, the elevator / offensive end), 6 Blue (south + catwalk), 14 FFA across all floors.

## 6. Checked headless (Godot 4.7, `tests/ivory_tower_self_test.gd`, `tests/map_select_self_test.gd`)
- Every spawn and pickup has a floor and 2.2 m of headroom.
- The elevator and both vents lift a player above L2.
- The navmesh (862 polygons) reaches all 24 roam points from the plaza, with lift links included.
- Bots spawn. **Nobody has played it yet.**

## 7. Not done / next steps
- Wall-mounted lifts, moving doors, the coconuts and destructible planters [S] are not modelled.
- No overshield / camo pickups exist in Long Colt yet.
- Lighting is a steep sun through the skylight plus fill omnis, not baked.
- The Dark Room only has a ramp-free route up (the vents). Bots use the vent links. Players can also take the north stairs.

## 8. Confidence
| Category | Confidence | Why |
|---|---|---|
| Overall structure (plaza, steps, canyon, catwalk, north elevator) | **Medium-High** | The MCC plans, design doc and screenshot agree. |
| Wing rooms (Dark / Light / galleries) | **Low-Medium** | Halopedia describes them; the plans are hard to read. Simplified. |
| Dimensions and heights | **Low** | Scaled by eye. |
| Weapons and spawns | **Medium** | Positions are from the Halopedia text. The mapping to Long Colt guns is mine. |

## Sources
- https://www.halopedia.org/Ivory_Tower (text). Images from its MediaWiki API: `HMCC_H2_Ivory_Tower_Map.png` (MCC floor plans, main trace), `H2_IvoryTower_DesignDoc.png` (Bungie "Cyclotron" doc), `Itowerlayout.jpg` (in-game overview), `H2_IvoryTower_Perspective_Concept.jpg`
- https://www.halopedia.org/Reflection (Reach remake, said to have identical geometry): `HMCC_HR_Reflection_Map.png`

The reference images are copyrighted and not committed. Fetch them from the URLs above.
