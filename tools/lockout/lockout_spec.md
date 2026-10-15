# Lockout (Halo 2, 2004): greybox v2 for Project Long Colt

> **Read this first:** No published measurements of Lockout exist. **Every dimension is ESTIMATED.**
> v2 traces the plan from the MCC Lockout loading-screen map and takes its levels and connections
> from Bungie's own design doc. It replaces the v1 box blockout, which is kept in `archive_v1/`
> together with its spec. Tags: **[S]** = sourced, **[E]** = estimated by me.

## Files
| File | What it is |
|---|---|
| `build_lockout_greybox.py` | Headless Blender generator, the single source for everything below. |
| `lockout_greybox.blend` | Blender scene (collections: Floors, Walls, Ramps, Rails, Cover, Catwalks, Lift, Boundary, Markers, Callouts). |
| `previews/*.png` | Overhead (with and without roofs) and two perspectives. |
| `assets/models/environment/lockout_greybox.glb` | Imported by Godot. `*-col` meshes get trimesh collision on World layer 1. |
| `scenes/levels/lockout.tscn` | Greybox, GravLift, KillVolume (y −15), 16 FFA spawns. |
| `scenes/main/arena_lockout.tscn` | Bot Arena / LAN: pickups, 3 bots, runtime navmesh, 5 nav links, 21 roam points. |
| `scenes/main/main_lockout.tscn` | Offline testbed: pickups, target dummies, strafers, a Top Mid path runner. |
| `tests/lockout_layout_self_test.gd` | Walk reachability, spawns, pickups, link ends, plus a real Player riding the lift and making the gap jumps. |

Rebuild (from the repo root; Blender's Python needs numpy for the glTF exporter):
```
blender -b --factory-startup --python tools/lockout/build_lockout_greybox.py
flatpak run org.godotengine.Godot --headless --path . --import
flatpak run org.godotengine.Godot --headless --path . --script res://tests/lockout_layout_self_test.gd
python3 tools/lighting/emit_lockout_lighting.py     # only if fixtures need to move
```

## 1. How the MCC map was read
- The MCC loading-screen map draws **two floors side by side** [S, by alignment]. The left
  drawing is the Top Mid level. The right drawing is the floor below it, shifted **541 px** to the
  right. At that offset the grav lift circles coincide, the north-west ramp lines up (it is in
  both drawings because it climbs between them), and the south-east block lines up.
- **Black areas are voids** [E, confirmed by the design doc]. The black gap between the lift
  tower and Top Mid is the north jump gap; the black gap west of Top Mid is the west jump gap.
- **Leader lines link a piece drawn out of place to where it sits.** The rounded room drawn top
  right is S3: it sits on top of S2, with its rounded end at the Elbow landing.
- **Scale: 1 px = 0.12 m**, so the Top Mid deck (133 px) is 16 m [E]. The origin is the Top Mid
  centre light, at (279, 390) px. Godot +X = east, −Z = north (the top of the map).

## 2. Levels and connections
Bungie design doc [S]: *"3 main areas attached to a double decker center platform. The area to
the north is attached by a bridge down below, but it can also be reached on top by jumping…
The area to the west is similarly attached on the bottom level, but can be reached by jumping
across. The area to the southeast is by far the largest… 3 different levels, and this area has
access to the center both top and bottom."*

| Level | y (m) | Areas |
|---|---|---|
| Basement | −3.0 | Library basement + south alcove |
| Bottom | 0.0 | Bottom Mid, Green Hall bridge, lower lift room, Sniper Alley, BR1, East Corridor, S1 |
| Top | 4.5 | Top Mid deck, BR2 + balcony, East Bridge, S2, NE annex, Library, both passages |
| Upper lift | 5.0 | Upper lift room, NW landing, grate bridge (0.5 m above Top Mid, so the gap jumps work both ways) |
| Elbow corners | 6.0 | Elbow loop corners |
| S3 | 8.5 | S3 sniper room, S2 roof terrace, Elbow landing |
| BR3 | 9.0 | BR tower roof |

| Connection | Type | Notes |
|---|---|---|
| Top Mid ↔ upper lift room | **Jump**, 5.4 m gap, ±0.5 m | Design doc "reached on top by jumping". Reach 6.65 m up / 7.42 m down. Full-height opening, so you don't hit a lintel mid-arc. |
| Bottom Mid ↔ lower lift room | Green Hall bridge, open to the sky | The "bridge down below". A short gap jump lands here. |
| Lower → upper lift room | Grav lift | Volume 0–4 m, 12 m/s exit, apex 7.3 m, up through a 2.9 × 2.6 m floor hole. |
| Top Mid ↔ BR2 | **Jump**, 5.6 m gap, level | Design doc "reached by jumping across". Reach 7.06 m. A short jump lands in Sniper Alley. |
| Bottom Mid ↔ BR1 | Sniper Alley (bottom hall) | Roofed under the deck, open under the gap. |
| BR1 → BR2 → BR3 | Ramps, 24° and 27° | BR ramp out through the south wall to the balcony, then the roof ramp. |
| BR1 → upper lift room | NW ramp, 15°, then the grate bridge | The long ramp in both MCC drawings. |
| Top Mid ↔ S2 | East Bridge | The only bridge on the top level. |
| Top Mid ↔ Library | South passage | |
| Bottom Mid → basement | East Corridor + open ramp, 19° | "Access to the centre bottom". |
| Basement → S1 → S2 | Ramp 27°, then a ramp along S1's north wall, 27° | S2 floor has a railed stairwell. |
| S2 → NE annex → Elbow → S3 → Elbow → Library | Loop: 6°, 25°, landing, 19°, 12° | The U in the top MCC drawing. |
| S3 → S2 roof terrace | Door | A balcony overlooking Top Mid. |

## 3. Callouts [names S, positions E]
Top Mid, Bottom Mid, Green Hall (stasis hall), Lift (lower / Top Lift), NW Ramp, Grate Bridge,
Sniper Alley, BR1 / BR2 / BR3, BR Balcony, East Bridge, East Corridor, S1 / S2 / S3, S2 Terrace,
NE Annex, Elbow, Library, Basement. Each is a `CALLOUT_*` empty in the .blend and a roam point
in the arena (except NW Ramp, which is mid-slope).

## 4. Weapons (Long Colt five-gun mapping)
H2 Lockout [S, Halopedia / Durinsbane]: shotgun in the green stasis hallway at the bottom of the
lift, sniper on top of the sniper tower, a BR and two magnums on top of the lift, a BR on the BR
tower.

| Pickup | Where | Respawn | H2 analogue |
|---|---|---|---|
| Combat Shotgun | Green Hall bridge | 90 s | Shotgun |
| Directed Energy Rifle | S3 | 90 s | Sniper Rifle (the DER is now the scoped one-shot) |
| Marksman Carbine | BR3 roof | default | BR on the BR tower |
| Standard Issue Rifle ×3 | Upper lift room, Library, basement | default | BR top of lift + fillers |
| Service Pistol ×3 | Upper lift room ×2, S1 | default | 2 magnums top of lift + filler |

**Changed from v1:** the DER moved from the Green Hall to S3, and the shotgun moved from Bottom
Mid to the Green Hall, both to match the H2 spots.

## 5. Confidence
| Category | Confidence | Why |
|---|---|---|
| Plan shape (rooms, halls, loop) | **Medium-High** | A direct trace of the MCC map; the two drawings cross-check at the 541 px offset. |
| Which floor each piece is on | **Medium** | Design doc + MCC drawing membership + ramp treads; S3's position comes from a leader line. |
| Absolute heights | **Low-Medium** | Chosen to fit doors (3 m), the 2.1 m Spartan and the jumps the design doc calls for. |
| Scale (0.12 m/px) | **Low-Medium** | From Top Mid ≈ 16 m and the jump gaps being crossable. |
| Spawns | **Low** | Not sourced; 16 spread over every level, facing Top Mid. |

## Gaps / not done
- No superbounce spots, no secret room. The lower MCC drawing shows a small room with a narrow ramp
  (≈ px 194–226, 247–380) linked by a leader to the lift room. It is probably the design doc's
  "secret room" and was left out.
- Stasis pods, the Library desk and the bastions are plain blocks. There are no cables, antennas
  or curved forms.
- The lightmap still has to be baked in the editor (LightmapGI in both launchers).

## Sources
- https://www.halopedia.org/Lockout (text). Images from its MediaWiki API: `HMCC_H2_Lockout_Map.png` (the main trace),
  `H2_Lockout_DesignDoc.jpg` (levels and connections), `H2_Lockout_Concept_Overhead.jpg`, `H2_Lockout_Blockout_1/2.jpg`,
  `H2_Lockout.jpg`, `H2_Lockout_Overview.png`, `HTMCC-H2_Lockout_Elbow.jpg`, `HTMCC-H2_Lockout_Lift.jpg`
- Weapon spots: Halopedia; https://durinsbane.home.blog/2020/05/19/halo-2-maps-lockout/
- Reference images are copyrighted, so they are not in the repo.
