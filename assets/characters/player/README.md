# Player model (block-out v1)

- `player_model.tscn`: root `PlayerModel` (Node3D, `player_model.gd`), instancing
  `res://assets/models/characters/player_blockout.glb` as `Blockout`.
- Geometry source: `tools/player_blockout/build_player_blockout.py` (headless Blender 4.2).
  Rebuild with `blender -b --factory-startup --python tools/player_blockout/build_player_blockout.py -- --previews <dir>`.
- Space: metres, +Y up, -Z forward, origin at the feet. Crown 1.81, visor centre ~1.60.
- glb groups match `scenes/ai/dummy_rig.tscn` slots: `BodyMesh` (origin 0), `NeckMesh` (origin 0),
  `HelmetMesh` (origin y 1.64 = `HeadArmored`), `VisorMesh` (origin 0 = `HeadUnarmored`).
  Every `PB_*` origin sits on its joint (neck 1.47, shoulders ±0.25/1.36, elbows ±0.275/1.00,
  wrists ±0.29/0.80, pelvis 0.93, waist 1.00, chest 1.12, hips ±0.11/0.88, knees ±0.11/0.51,
  ankles ±0.11/0.12) and parts are parented along the joint chain. `PB_Helmet` and `PB_Visor`
  share the neck pivot: rotate both together to turn the head.
- Materials (`materials/`): `player_armor_primary.tres` (mat_armor, ShaderMaterial,
  `player_armor.gdshader`, `instance uniform vec3 primary_color`), `player_armor_secondary.tres`
  (mat_undersuit #2e2f31), `player_visor.tres` (mat_visor #a87a1e), `player_accent.tres`
  (mat_accent: shared ShaderMaterial, `player_accent.gdshader`, `instance uniform vec3 accent_color`,
  default stencil red #b3261e; left pauldron + left helmet stripe). All matte, roughness 0.9.
  `player_model.gd` swaps the glb's imported materials for these by name on `_ready`.
- Tint: `set_primary_color(color)` sets the `primary_color` instance uniform on every mat_armor mesh;
  `set_accent_color(color)` sets `accent_color` on the mat_accent meshes (PB_Pauldron_L,
  PB_HelmetStripe_L). Both are safe before `_ready`. The shared .tres files are never duplicated.
- Render layers: `first_person_hidden` (export, default false; setter works at runtime and
  before `_ready`, and is re-applied in `_ready`).
  - false: every mesh `layers = 1` (layer 1 only). Use for remote players, bots, dummies.
  - true: every mesh `layers = 2` (layer 2 only). Set on the LOCAL player only, and clear bit 2
    from that player's first-person camera `cull_mask`.
  - `cast_shadow = SHADOW_CASTING_SETTING_ON` in both states, so the local player keeps its shadow.
- Budget (v2 bulk-up): 49 parts, 1,524 tris (helmet + visor 232).
- v2 bulk-up vs the AD doc limb numbers: thighs 0.18 x 0.20 at the top (doc 0.16 x 0.18), shins
  0.14 x 0.16 at the top (doc 0.12 x 0.14), forearms 0.15 x 0.15 (doc 0.13 x 0.13), hands
  0.10 x 0.11 (doc 0.09 x 0.10), pauldrons 0.18 x 0.23 at y 1.27-1.46 (doc 0.16 x 0.20, 1.30-1.46),
  chest 0.33 deep at the pec line y 1.31 (doc 0.28), collar 0.32 x 0.28 (doc 0.30 x 0.26). Added
  PB_AbPlate (front of the abdomen; the sides stay dark) and PB_NeckSeal (undersuit ring 1.44-1.495).
  Pauldron span 0.66, depth 0.40 and crown 1.81 are unchanged.
- Key heights (m): chest 1.12-1.40 (pec line 1.31), collar top 1.46, pauldron tops 1.46, neck 1.40-1.54,
  helmet shell 1.52-1.81 (chin guard to 1.51, rear flap to 1.49), visor 1.52-1.672,
  visor centre 1.6035 (at x 0).
- Wiring (not done yet): instance `player_model.tscn` as `PlayerModel` directly under the Player
  root; set `first_person_hidden = true` on the local player.
