# Headlong (Halo 2, 2004): Greybox Blockout Spec for Project Long Colt

> **Read this first:** No published measurements of Headlong exist in the sources I found. **Every dimension is ESTIMATED.** I traced the plan from the MCC Headlong loading-screen map and checked it against the Breakneck overhead (Breakneck is the Halo: Reach remake, file `cex_headlong`). I then scaled it so lane widths and the parked bus read right next to a 2.1 m Spartan. Use it as a balance-test map *in the spirit of* Headlong, not as a copy. Tags: **[S]** = sourced, **[E]** = estimated by me.

Build: `blender -b --factory-startup --python tools/headlong/build_headlong.py` (from the repo root). Headless runs need numpy visible to Blender's Python for the glTF exporter. Use `sudo apt install python3-numpy`, or `pip install --target <dir> numpy` and run with `PYTHONPATH=<dir>`.

The script regenerates all of these (edit the script, never the outputs):

| Output | What it is |
|---|---|
| `assets/models/environment/headlong_greybox.glb` | Geometry. Every mesh is `*-col`, so Godot builds trimesh StaticBodies on World layer 1. Empties are markers. |
| `tools/headlong/headlong_greybox.blend` | The same scene, grouped into collections per area, for hand edits and inspection. |
| `scenes/levels/headlong.tscn` | Level: glb + `Spawns` (24 Marker3D) + Hotel GravLift + KillVolume at y -8. |
| `scenes/main/main_headlong.tscn` | Offline testbed: Player + 11 weapon pickups + sun/environment, no bots. |
| `scenes/main/arena_headlong.tscn` | Arena (Bot Arena / LAN, picked from the menu via `MapList`): pickups, 3 bots, runtime navmesh, hotel lift nav link, 23 roam points, NetMatch. |
| `tools/headlong/previews/*.png` | Overhead (north up, 124 m frame) and two perspective renders. |

## 1. Scale assumption
- Player 2.1 m, `jump_height` 2.2 m, `stand_speed` 7.5 m/s, gravity 22 (scripts/player/player.gd). That gives ~0.89 s of airtime and a ~6.7 m flat running jump. `floor_max_angle` is 50°; every slope in the build is 32° or less.
- **Footprint ~117 × 112 m** (x -57.5..57.5 playable, z -55..55). Out-of-bounds walls are 25 m high [E]. That is about 2.5× Lockout per side. Headlong was a 6–16 player vehicle map [S MCC loading text]. The design doc's "slightly larger than Hang 'Em High" [S] describes an earlier, smaller draft.
- Levels: street/plaza **0**, Construction Pit **-3**, building floors at **4.5–5 m** and roofs at **9–10 m**. The Gate Bridge peaks at **8 m** and the Crane Platform sits at **7 m** [E].

## 2. Coordinates
Godot axes: +Y up, **+X east, -Z north**. North is the top of the MCC map, and the **sea is south** [S Breakneck: the sea front holds the monument]. The origin is about the centre of the playable square at street level.

## 3. Callouts
Halopedia names six Headlong territories without placing them [S]: **Gate Bridge, Statue, Alley, Building Site, Corner Building, Construction Pit**. Which area each name goes with is my best reading [E]. The rest are descriptive names of mine, or Breakneck names [S Breakneck callout list: Hotel, Underpass, Steel Beam…].

| Callout | Where (x, z) | Floor y | Notes |
|---|---|---|---|
| Construction Pit | -46..8, -45..10 | -3 | Sunken dirt square with debris and barriers. Exits: north vehicle ramp, south-east ramp, Pit Stairs, Alley Stairs. "No cover in the centre" [S]. |
| Building Site | -39..-19, -31..-6 | 1 / 5 / 9 | Half-built 3-level frame in the pit [S design doc: building inside the race loop]. Open sides, half walls. Roof = carbine perch. |
| Steel Beam | Site F2 → Crane | 5 → 7 | 1.2 m wide and 32 m long with no rails. A risky shortcut [S Breakneck name]. |
| Crane Platform | (16, -22) | 7 | Suspended container [S "two floating cranes"]. Holds the power weapon. |
| Gate Bridge | north end (10, -11) → SE street (46, 41) | 8 → 0 | Half-built elevated road [S "half-assembled bridge"]. It just ends: Warthog launch in H2, skill jump to the Crane here. |
| Underpass | under the Gate Bridge | 0 | 7.4 m clearance [S Breakneck name]. |
| Hotel (East Building) | 19..49, 4..23 | 0 / 5 / 10 | CTF base with a bottom route (doors), a top route (outside ramp → 2F balcony) and a lift in the atrium [S "bottom route and top route", "takes a lift out"]. |
| Corner Building | -46..-18, 12..31 | 0 / 4.5 / 9 | 2F windows overlook the pit [S design doc: "hiding in the shadows, looking out a window"]. |
| Alley | -57..-46, -29..12 | 0 / 5 | West strip building: west catwalk (to Site F2), teleporter B, ground-floor window. |
| North Lot / North Building | -46..8, -55..-45 | 0 | Teleporter A room. |
| Statue | (5, 50) on a 1.2 m plinth | 1.2 | Seventh Column monument on the sea front [S]. |
| South Street / East Lane / Central Plaza | | 0 | Vehicle loop [S design doc: one-way race loop, banked roads]. |

## 4. Connections and tricks to test [E]
| Check | Geometry | Expected with current movement |
|---|---|---|
| Crane → Gate Bridge jump | 4.8 m gap, +1 m up | Needs a running jump (reach ~5.8 m). Walking off should fail. |
| Gate Bridge → Crane | 4.8 m gap, 1 m down | Easy (~7.4 m reach). |
| Steel Beam crossing | 1.2 m wide, 30 m over a 3–6 m drop | Doable when focused, punishing under fire. |
| Gate Bridge north end → pit | 11 m drop to -3 | Check fall damage. |
| Hotel lift | 4 m volume at 12 m/s → ~7.3 m apex under a 9.6 m ceiling | You should be able to air-strafe 4 m onto the 2F ring (rail top 6.05). |
| Site roof ↔ Hotel roof | 70.7 m | At the edge of carbine falloff (50 → 90 m). Sets the long-range ceiling. |
| Gate Bridge end ↔ Site roof | 30 m | Rifle-burst range (35 m falloff start). |
| Corner 2F windows → pit centre | ~31 m, 8 m above | Main mid-range overwatch. Watch whether it dominates. |

## 5. Teleporters (2 systems [S], endpoints [E])
- **A:** North Building (-23.75, -51.25) ↔ South Street (52, 48)
- **B:** Alley (-54.5, -12) ↔ East Lane (48, -10)

Pads and `TELE_*` markers are in the glb. **There is no teleporter script in the project yet**, so these are not functional.

## 6. Weapons (Long Colt five-gun mapping [E])
Halopedia confirms shotguns that don't respawn, Overshield and Active Camo, but gives no positions [S]. Placements follow H2 power-role logic:
- **Marksman Carbine** (sniper role): Building Site roof, Hotel roof
- **Combat Shotgun** (90 s): Alley ground floor, Corner Building ground floor
- **Directed Energy Rifle** (90 s, rocket-launcher tier): Crane Platform
- **Standard Issue Rifle**: Gate Bridge north end, Statue, pit north
- **Service Pistol**: North Building, Building Site F1, Hotel 2F
- `PWR_Overshield_Pit` and `PWR_ActiveCamo_Alley2F` are markers only, with no Long Colt equivalent yet.
- `FLAG_Red_Hotel` / `FLAG_Blue_Corner` are markers for future CTF.

Spawns: 6 Red (Hotel side), 6 Blue (Corner side) and 12 FFA spread over all heights. All 24 sit under `Headlong/Spawns`.

## 7. Not done / next steps
- **Vehicles:** Headlong is built around Warthogs, Ghosts, a Banshee and a Scorpion/Wraith [S]. On foot it plays big and open. If infantry balance feels too spread out, consider scaling the plan to ~0.8×.
- **Bots:** they path on the runtime navmesh (917 polygons in the headless test) and ride the Hotel lift. There are no jump links yet (the Crane ↔ Gate Bridge jump), so bots reach the Crane only by the Steel Beam.
- **Lighting:** a sun only, with no lightmap and no fixtures.
- **Checked headless only** (Godot 4.7.2, `tests/map_select_self_test.gd`): the scenes import, the navmesh bakes and bots spawn. Nobody has played it yet.

## 8. Confidence
| Category | Confidence | Why |
|---|---|---|
| Plan layout (which area is where) | **Medium** | The MCC map and Breakneck overhead agree. Interiors are simplified. |
| Callout names → areas | **Low-Medium** | Halopedia lists the names but doesn't place them. |
| Footprint and distances | **Low** | Scaled from lane widths and a parked vehicle. |
| Heights | **Low** | Read from the panorama and profile shots. No measurements exist. |
| Weapons, spawns, teleporter pairs | **Low** | Not sourced. |

## Sources
- https://www.halopedia.org/Headlong (text). Images from its MediaWiki API: `H2_Headlong_DesignDoc.jpg` (Bungie design doc, overhead sketch), `HMCC_Headlong.PNG` (MCC loading-screen map, the main trace), `H2_Headlong_profile.jpg`
- https://www.halopedia.org/Breakneck (callout list). `HR_Breakneck_Overhead.png`, `HMCC_HR_Breakneck_Map.png`, `HR_Breakneck_Panorama.png` (heights)

The reference images are copyrighted and not committed. Fetch them from the URLs above.
