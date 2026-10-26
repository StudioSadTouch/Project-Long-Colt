# Hospitaller: player model and modular armor

The player body (`assets/characters/player/player_model.tscn`) is the Hospitaller, built from
the art team's prototype `/mnt/drive3/Modeling/project-long-colt/Hospitaller/protypehos.blend`
and the references in `~/Pictures/Projects/Hospitaller-reference` (Exo sheets, helmets sheet,
soldier concepts, player board). The finished Blender file is saved next to the prototype as
`hospitaller.blend` (the prototype is read, never written).

## Rebuild

```
PYTHONPATH=~/.cache/claude-longcolt/pylibs blender -b --factory-startup \
    --python tools/hospitaller/build_hospitaller.py -- [--previews <dir>] [--no-export]
```
Writes `assets/models/characters/hospitaller.glb` and `hospitaller.blend`, prints triangle counts
per module and the fit checks (`CHECK ...`). Blender's Python needs numpy on `PYTHONPATH` for the
glTF exporter. Then `flatpak run org.godotengine.Godot --headless --path . --import`.

| File | Job |
|---|---|
| `build_hospitaller.py` | entry: opens the prototype, runs everything, saves / exports |
| `hosp_body.py` | base mesh refit onto the PB_* joints, weights, cut hands/feet/head, the baggy BDU |
| `hosp_armor.py` | the slot / variant catalogue and every armor piece |
| `hosp_core.py` | always-on parts: gloves, boots, neck seal |
| `hosp_check.py` | fit checks: BDU pulled under armor, loose pieces seated, clash report |
| `hosp_geo.py`, `hosp_preview.py`, `hosp_render.py` | geometry helpers, Workbench previews |

## How the model works

- **Joints unchanged.** The glb keeps the block-out's joint empties (`BodyMesh/PB_Pelvis/...`,
  same names, pivots and hierarchy, plus `WeaponAttach_R` / `OffHand_L`), and the scene still
  instances it as `Blockout`, so the animation library, weapon props, footsteps and hitboxes
  work untouched.
- **Undersuit = skinned BDU.** The prototype's base body (decodigo's low-poly male base mesh) is
  refit onto the joint pivots (uniform scale, then a per-bone map from its A-pose joints), cut
  at the hands, feet and head, subdivided once and inflated into baggy battle-dress cloth
  (folds, trousers bloused over the boot tops). Bones `B_<x>` follow joints `PB_<x>` at runtime:
  `scripts/player/body_skin_sync.gd` (child `BodySkinSync` of PlayerModel) copies the joint
  poses onto the skeleton after the animation runs.
- **Armor = rigid parts** under the joints, named `AR_<slot>_<variant>_<piece>`; `CORE_*` parts
  always show. `PlayerModel.set_armor_loadout()` shows one variant per slot.

## Slots and variants

Design rules from the art direction: every helmet is the user's helmet shell (its whole front
dome is the visor, like an astronaut helmet; variants mount pieces over it from the helmets
sheet, no new crowns); the chests are the user's two chest pieces and modifications of the
vest; everything follows their language: big flat facets, 45-degree chamfers, rims, flat
shading, chunky, little undersuit showing, big pouches.

| Slot | Variants (first = default) |
|---|---|
| helmet | Hospitaller (shell as drawn), Warden (sheet 1, T-slot faceplate, breath holes), Vanguard (2A/2B: titanium up-armour plate with 4 NVG lenses on the ear hinges; `set_visor_plate_up()` flips it), Sentry (slit faceplate, breather ports), Lancer (sheet row 3, swept brow hood) |
| chest | Hospitaller (the prototype vest), Breastplate (the prototype's hidden chest plate), Exo Harness (vest front half, spine frame, back unit + antenna), Plate Carrier (vest as webbing, mag pouches, radio), Grenadier (vest + collar ring, grenade belt) |
| shoulders | Exo Cans (drawing's drum with the '+' bolt), Pauldrons, Heavy |
| arms | Bracers (flared, elbow cops, wrist display on the left), Struts (exo bars, padded cuffs, arm pouch) |
| legs | Exo Plates (thigh plates with the stepped notch, knee pads, shin guards, hip disc, drop-leg pouch, cod / seat plates, butt pack), Light Kit (knee pads, cargo pockets, shin plates) |

The left shoulder piece and the left helmet pivot take the shoulder accent colour.

## Adding a variant

1. Write a builder in `hosp_armor.py` returning `(piece, Geo[, joint[, pivot]])` tuples and add
   it to `CATALOGUE` (id: lowercase, no `_`).
2. Add the same id to `ArmorLoadout.VARIANTS` (`scripts/player/armor_loadout.gd`).
3. Rebuild; read the `CHECK` lines; run `tests/hospitaller_armor_self_test.gd` (it fails if the
   catalogue and the model disagree) and look at `tests/hospitaller_render.gd`'s PNGs.

## Fit checks (`hosp_check.py`)

Run for every variant of every slot (others at their defaults), on the rest pose:
- BDU poke-through: a cloth edge crossing a plate's outer wall on its own or a neighbouring
  joint; those cloth vertices are pulled toward their bone (at most 2.5 cm).
- Floating: each loose piece (touching pieces grouped, so a pouch moves with its flap) must be
  within 6 mm of its module, the core parts or the BDU; offenders up to 12 mm slide onto the
  nearest surface (`SNAP`), farther ones are reported (`FARFLOAT`) and fixed by hand: pieces
  that sit on a surface are placed by raycasting it (pouches on the vest's deepest point,
  the butt pack on the seat plate, the seat plate on the seat).
- Clashes between modules on related joints are listed (`CLASH`).

State at hand-off: no floating pieces; 16-24 cloth edges still cross plates per loadout (57-63
with pauldrons) and the boot / shin-guard and vest / heavy-pauldron clashes remain in the
report, all at spots the close-up renders show hidden (inside plate thickness, under the
pauldrons and shin guards).

## Animation (v1.8 of tools/character_anims/gen_character_anims.py)

- Rifle held properly shouldered for the bulky kit: grip 36 cm in front of the shoulder line,
  support hand 55 cm out on the handguard, elbows out (`HOLDS["rifle"]`; v1.7 was 22 / 40 cm and
  the hands jammed into the vest). Two-hand pistol pushed out to 48 / 46 cm.
- Crouch keeps its head height (crouch hitbox / eye) with the pelvis 0.38 m up (was 0.30) and a
  38-degree lean (was 22), so the legs are no longer folded flat. Crouch idle is a tactical
  kneel: right knee down sitting back toward the heel, toes tucked, left foot forward.
- Review sheets: `DISPLAY=:0 flatpak run org.godotengine.Godot --path . --script
  res://tests/hospitaller_anim_sheet.gd` writes `.hosp_render/anim_<scenario>.png`.

## Game side

- `ArmorLoadout` (`scripts/player/armor_loadout.gd`): catalogue, defaults, string codec
  (`helmet=hospitaller,chest=exo,...`), `apply(target, loadout)`.
- Settings `[profile] armor`; Net player info `"armor"` (PROTOCOL 17), applied to puppets in
  NetMatch; `Player.set_armor_loadout()`. Bots wear the defaults.
- Main menu, Armor Customization: one `< variant >` row per slot, live on the turntable preview.
- Materials: `player_bdu.tres`, `player_webbing.tres`, `player_frame.tres` (new) plus the
  existing armor / accent / visor shaders. Each tint uniform now has its own `instance_index`
  (a mesh can mix armor, accent and visor surfaces; without it they all shared slot 0 and the
  visor tint overwrote the armor). The visor shader is a flat tint now: the triplanar path made
  the big visor facets bloom into white glare.

## Credits

Base body: "Low-poly Male Base Mesh" by decodigo,
https://sketchfab.com/3d-models/low-poly-male-base-mesh-7b9411ff0c624321baf4caac014bc0bd,
licensed CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/). Refit, cut, subdivided and
dressed for Long Colt. CC-BY requires this credit wherever the game ships (e.g. its credits
screen).
