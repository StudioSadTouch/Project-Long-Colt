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
  (mat_accent #9c3b2a, left pauldron + left helmet stripe). All matte, roughness 0.9.
  `player_model.gd` swaps the glb's imported materials for these by name on `_ready`.
- Tint: `set_primary_color(color)` sets the `primary_color` instance uniform on every mat_armor mesh.
- Render layers: all meshes `layers = 2` (layer 2 only).
- Wiring (not done yet): instance `player_model.tscn` as `PlayerModel` directly under the Player
  root, and clear layer 2 from the local first-person camera's `cull_mask`.
