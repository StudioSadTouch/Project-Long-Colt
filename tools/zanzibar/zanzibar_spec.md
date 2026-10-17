# Zanzibar (Halo 2, 2004): Greybox Blockout Spec for Project Long Colt

> **Read this first:** No published measurements of Zanzibar exist in the sources I found. **Every dimension is ESTIMATED.** I traced the plan from the MCC Zanzibar loading-screen map, checked it against Bungie's layout sketch (`H2_Zanzibar_Layout.jpg`) and the Halopedia screenshots, and scaled it so lane widths read right next to a 2.1 m Spartan. Use it as a balance-test map *in the spirit of* Zanzibar, not as a copy. Tags: **[S]** = sourced, **[E]** = estimated by me.

Build: `blender -b --factory-startup --python tools/zanzibar/build_zanzibar.py` (from the repo root). The glTF exporter needs numpy visible to Blender's Python, e.g. `PYTHONPATH=<dir with numpy>`. Add `-- --no-render` to skip the previews.

The script regenerates all of these (edit the script, never the outputs):

| Output | What it is |
|---|---|
| `assets/models/environment/zanzibar_greybox.glb` | Geometry. Every collidable mesh is `*-col` (trimesh StaticBodies on World layer 1). The sea and the turbine ring and blades are visual only. Empties are markers. |
| `tools/zanzibar/zanzibar_greybox.blend` | The same scene, grouped into collections per area. |
| `scenes/levels/zanzibar.tscn` | Level: glb + `Spawns` (24 Marker3D) + KillVolume at y -10. |
| `scenes/main/main_zanzibar.tscn` | Offline testbed: Player + 12 weapon pickups + sun/environment, no bots. |
| `scenes/main/arena_zanzibar.tscn` | Arena (Bot Arena / LAN, picked from the menu via `MapList`): pickups, 3 bots, runtime navmesh, 25 roam points, NetMatch. |
| `tools/zanzibar/previews/*.png` | Overhead (north up, 145 m frame), a view from the sea and one over the base. |

## 1. Scale and coordinates
- Plan positions are authored in **MCC-map pixels** via `px(sx, sy)` at **1 px = 0.22 m**, origin pixel (355, 350). That way you can check any feature against the 1280×720 loading screen.
- Godot axes: +Y up, **+X east, -Z north** (north = top of the MCC map). **The sea is east** [S MCC map].
- Footprint ~**134 × 96 m** (x -67..+56 to the surf, z -48..+48). That is a little bigger than Headlong per side. Zanzibar is a 2–16 player vehicle map [S].
- Levels: courtyard and base GF **0**, beach **-2** (surf -2.3). Sea wall walk, gate deck and bastions **4**. Base 2F **6**, base roof, Wheel Bridge and hub deck **12**. Control Tower 2F **4.5** / roof **9**. Pump House roof **4.5**.
- Player: 2.1 m, ~6.7 m flat running jump. Every slope is 32° or less (the build prints them).

## 2. Callouts
Halopedia's Territories zones are **Control Tower, Camp Froman, Base, Sea Wall, Gate** [S]. The sketch labels a "3 story sniper tower", a "2 story windmill facility with courtyard", a "Havok bridge", "Havok gate device", "destructible columns", "rock garden" and "second story turret"s [S].

| Callout | Where (x, z) | Floor y | Notes |
|---|---|---|---|
| Base | -67..-41, -14..15.5 | 0 / 6 / 12 | Defenders. Front hall with 3 east doors (centre one 4 m tall), N/S side doors. Stairs GF→2F→roof along the east wall. |
| Flag Room | (-63, 0.75) | 0 | Between the two generator rooms, under a 2F atrium. Four columns [S "destructible columns"; not destructible here]. 1-Flag / Assault objective. |
| Generator Rooms N / S | x -66.5..-50 | 0 | One door to the flag room and one to the hall each. |
| Base 2F | | 6 | Ring around the atrium. East windows at 7.2–9.4 with turret markers [S "second story turret"]. |
| Wheel Bridge | x -41 → -25, z 0.75 | 12 | From the base roof. Holds the DER (rockets in H2) [S]. Ends **3 m short** of the hub deck, so you jump [S "the bridge does not connect… players must jump"]. |
| Wheel / Hub | hub (-18.7, 12, 0.75) | 12 | Turbine ring r 13.5 in the N-S housing slot. Hub deck 6.6 × 4 m holds the shotgun (energy sword in H2) [S]. The ring and blades are visual only. |
| Pin Ramp / Pin Landing | x -10.5, z 21 → 0.25 | 0 → 12 | The east route. In H2 shooting a pin lowers a bridge to the hub [S]. Here that is a **3.4 m jump** from the landing (`PIN_Bridge` marker). |
| Under the Wheel | slot x -23..-14.5 | 0 | 3 m housing walls with doors at z ±11. Overshield marker. |
| Control Tower | -28.3..-14.3, -30.1..-21.6 | 0 / 4.5 / 9 | North end of the slot. Doors W/E/S, windows on 2F, carbine on the roof [S sketch: sniper tower]. |
| Pump House | -22..-11, 25.3..37.2 | 0 / 4.5 | South building on the MCC map (my name). Two rooms, exterior ramp to a roof perch. |
| Rock Garden | SW courtyard | 0 | Boulders traced from the MCC blobs [S sketch]. |
| Courtyard | between the slot and the sea wall | 0 | Round bunker, crates, gate barrier. |
| Gate | crossing (7.5, -7.1) | -2 → 0 | 7 m road through the sea wall under the gate deck (3.4 m clearance). Wing walls on the beach side. **Always open** in the greybox (`GATE_Leaf`, `GATE_Switch` markers) [S "either team can open it, not close it"]. |
| Sea Wall | north bastion → south end | 4 | 3 m walk with merlons on the beach side. Two beach-side and two courtyard-side stairs [S screenshots]. Round bastions at both ends; the south one has a carbine. |
| Beach | east of the wall | -2 | Attackers. Rocks, the arch ruin by the gate, a jetty ruin into the sea [S screenshots]. Past the 8 m surf strip you fall into the kill volume ("no swimming"). |
| Camp Froman | south end of the beach | -2 | Rock overhang with crates and a rifle [S screenshot: "CAMP FROMAN" sign with a BR]. |

## 3. Routes and checks to test [E]
| Check | Geometry | Expected |
|---|---|---|
| Wheel Bridge → hub | 3 m gap, level | Easy running jump. Walking off should fall 12 m. |
| Pin Landing → hub | 3.4 m gap, level | Running jump. Riskier because it is exposed to the base roof. |
| Beach → courtyard | gate road (11°) or wall stairs | The gate is the only vehicle route. Infantry go over the wall. |
| Base roof ↔ Control Tower roof | ~36 m, base 3 m higher | Rifle-burst range. |
| South Bastion ↔ base roof | ~80 m | Carbine duel across the whole map. Watch whether the defenders' roof dominates. |
| Hub deck sightlines | 12 m up, open on all sides | Grabbing the power weapon should be a real gamble. |

## 4. Weapons (Long Colt five-gun mapping [E])
Halopedia places only the rocket launcher (on the bridge) and the energy sword (in the hub) [S]. It also mentions a shotgun, grenades and an overshield without saying where.
- **Directed Energy Rifle** (90 s): Wheel Bridge
- **Combat Shotgun** (90 s): Hub (sword stand-in), North Generator Room
- **Marksman Carbine**: Control Tower roof, South Bastion
- **Standard Issue Rifle**: Camp Froman, north beach, base 2F, courtyard
- **Service Pistol**: Pump House, Flag Room, just inside the gate
- Markers only: `PWR_Overshield_UnderWheel`, `FLAG_Defender_Base`, `TURRET_Base_N/S`, `VEH_GaussWarthog_Beach`, `VEH_Ghost_Beach`, `VEH_ChainWarthog_Base`, `VEH_Ghost_Base` [S vehicle list].

Spawns: 6 Red (defenders, base and base front), 6 Blue (attackers, beach) and 12 FFA over all heights, all under `Zanzibar/Spawns`. Both test scenes start the player at `SPAWN_Blue_0` on the beach.

## 5. Not done / next steps
- **No moving parts:** the wheel doesn't turn (in H2 you can ride the blades), the gate doesn't close, the pin bridge doesn't lower, and the shutters, turrets and destructible columns are missing. Each one has a marker where it matters.
- **Bots:** they path on the runtime navmesh, but there are no jump links, so they never reach the hub deck.
- **Terrain is flat:** the MCC map shows rolling dunes and courtyard paths. Here each area is one flat level with rocks as cover.
- **Lighting:** a sun from the sea only. No lightmap bake yet.

## 6. Confidence
| Category | Confidence | Why |
|---|---|---|
| Plan layout | **Medium-High** | Traced directly from the MCC map. The sketch and screenshots agree. |
| Callouts → areas | **Medium** | Gate, Sea Wall, Base, Beach, Wheel and Camp Froman are clear. The Control Tower is the sketch's sniper tower. "Pump House" is my name. |
| Footprint and distances | **Low-Medium** | One scale factor, chosen from lane widths and vehicle sizes in the screenshots. |
| Heights | **Low** | Read from screenshots. |
| Weapons (beyond rockets and sword), spawns | **Low** | Not sourced. |

## Sources
- https://www.halopedia.org/Zanzibar (text). Images from its MediaWiki API: `HMCC_Zanzibar.PNG` (MCC loading-screen map, the main trace), `H2_Zanzibar_Layout.jpg` (Bungie layout sketch), `H2_Zanzibar_Overview.png`, `H2_Zanzibar_Wheel.png`, `H2_Zanzibar_BaseExterior.png`, `H2_Zanzibar_Wall.png`, `H2_Zanzibar_Beach.png`, `H2_Zanzibar_CampFroman.png`, `HTMCC_H2_Zanzibar.png`

The reference images are copyrighted and not committed. Fetch them from the URLs above.
