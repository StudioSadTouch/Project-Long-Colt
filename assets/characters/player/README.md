# Player model (block-out v4)

- `player_model.tscn`: root `PlayerModel` (Node3D, `player_model.gd`), instancing
  `res://assets/models/characters/player_blockout.glb` as `Blockout`.
- Geometry source: `tools/player_blockout/build_player_blockout.py` (headless Blender 4.2).
  Rebuild (glb + previews + crouch check) with
  `blender -b --factory-startup --python tools/player_blockout/build_player_blockout.py -- --previews <dir>`.
- Space: metres, +Y up, -Z forward, origin at the feet. Crown 1.81, visor centre 1.600.
- Budget: 50 mesh parts, 1,752 tris (helmet + visor 332), four materials. Empties (pivots,
  slot groups, markers) are not counted.

## Node tree (glb; pivot = global joint position, Godot space)
Every `PB_*` origin sits on the joint it moves with (rotation and scale applied, translation =
pivot). Parts that are not joints (plates, pouches, soles) sit on their parent joint's pivot.
```
Blockout (glb root)
└ BodyMesh                         (0, 0, 0)       group
  └ PB_Pelvis                      (0, 0.93, 0)    Hips
    ├ PB_Codpiece, PB_ButtPlate, PB_Pouch_L, PB_Pouch_R, PB_Knife_R
    ├ PB_Abdomen                   (0, 1.00, 0)    Spine
    │ ├ PB_AbPlate
    │ └ PB_Chest                   (0, 1.12, 0)    Chest
    │   ├ PB_Collar, PB_Pack, PB_Antenna
    │   ├ PB_Neck                  (0, 1.49, 0)    Neck     (empty)
    │   │ ├ NeckMesh               (0, 0, 0)       group    -> PB_NeckCore, PB_NeckSeal
    │   │ └ PB_Head                (0, 1.54, 0)    Head     (empty)
    │   │   ├ HelmetMesh           (0, 1.64, 0)    group    (same origin as Rig/HeadArmored)
    │   │   │ └ PB_Helmet          (0, 1.54, 0)
    │   │   │   └ PB_HelmetBrow, PB_HelmetJaw, PB_HelmetEar_L/R, PB_HelmetSensor_R,
    │   │   │     PB_HelmetStripe_L, PB_HelmetFlap
    │   │   └ VisorMesh            (0, 0, 0)       group    (same origin as Rig/HeadUnarmored)
    │   │     └ PB_Visor           (0, 1.54, 0)
    │   ├ PB_UpperArm_L/R          (±0.25, 1.36, 0)  UpperArm  (pauldron + plate ride the arm)
    │   │ ├ PB_Pauldron_L/R, PB_UpperArmPlate_L/R
    │   │ └ PB_Forearm_L/R         (±0.275, 1.00, 0) LowerArm
    │   │   ├ PB_WristDisplay_L (left only)
    │   │   └ PB_Hand_L/R          (±0.29, 0.80, 0)  Hand
    │   │     ├ PB_Thumb_L/R
    │   │     └ OffHand_L (-0.28, 0.745, -0.01) / WeaponAttach_R (0.28, 0.745, -0.01)
    └ PB_Thigh_L/R                 (±0.11, 0.88, 0)  UpperLeg
      └ PB_Shin_L/R                (±0.11, 0.51, 0)  LowerLeg
        ├ PB_KneeJoint_L/R, PB_Knee_L/R
        └ PB_Boot_L/R              (±0.11, 0.12, 0)  Foot
          └ PB_Sole_L/R, PB_Toe_L/R
```
- Head follow is real hierarchy (no RemoteTransform, no runtime reparent): rotating
  PB_Abdomen / PB_Chest / PB_Neck / PB_Head carries the head groups.
- Markers are empties (Node3D after import): `WeaponAttach_R` = right-hand grip, fist centre,
  -Z along the barrel, +Y up; `OffHand_L` = off-hand IK target, same orientation.
  Paths in `player_model.tscn`: `Blockout/BodyMesh/PB_Pelvis/PB_Abdomen/PB_Chest/PB_UpperArm_R/
  PB_Forearm_R/PB_Hand_R/WeaponAttach_R` and `.../PB_UpperArm_L/PB_Forearm_L/PB_Hand_L/OffHand_L`.

## dummy_rig.tscn compatibility (not changed)
`dummy_rig.tscn` has its own MeshInstance3D slots: `BodyMesh` (child of Rig), `HeadArmored/
HelmetMesh`, `HeadUnarmored/VisorMesh`, `HeadUnarmored/NeckMesh`. No script references them by
name (only the scene's node paths). To use the glb there, instance the glb (or
`player_model.tscn`) in place of `BodyMesh` and delete the three head MeshInstance3Ds: the
glb's own `HelmetMesh` / `VisorMesh` / `NeckMesh` groups have the same names and global origins,
but they now live in the body chain (they can't be parented under the hitbox bodies any more).
The head hitboxes (`HeadArmored`, `HeadUnarmored`) must then follow `PB_Head` (e.g. a
RemoteTransform3D on PB_Head driving them, or BoneAttachment3D once skinned) - LC Programmer's
call, as the plan's open question on hitbox parenting.

## Materials and tint
- `materials/`: `player_armor_primary.tres` (mat_armor, ShaderMaterial, `player_armor.gdshader`,
  `instance uniform vec3 primary_color`, default #4a5039), `player_armor_secondary.tres`
  (mat_undersuit #2e2f31), `player_visor.tres` (mat_visor #a87a1e), `player_accent.tres`
  (mat_accent: shared ShaderMaterial, `player_accent.gdshader`, `instance uniform vec3
  accent_color`, default #b3261e; PB_Pauldron_L + PB_HelmetStripe_L). All matte, roughness 0.9.
  `player_model.gd` swaps the glb's imported materials for these by name on `_ready`.
- `set_primary_color(color)` / `set_accent_color(color)` set the instance uniforms on the
  mat_armor / mat_accent meshes. Both are safe before `_ready`. The .tres files stay shared.
- Render layers: `first_person_hidden` (export, default false; setter works at runtime and
  before `_ready`, re-applied in `_ready`). false: every mesh `layers = 1`; true (local player
  only): every mesh `layers = 2`, and clear bit 2 from that camera's `cull_mask`.
  `cast_shadow = SHADOW_CASTING_SETTING_ON` in both states.

## Key heights (m)
Chest 1.12-1.40 (pec line 1.31), collar top 1.46, pauldrons 1.22-1.46, neck 1.40-1.54, helmet
1.48-1.81 (shell 1.51-1.81, jaw to 1.48, rear flap to 1.49), brow 1.655-1.690 (front z -0.190),
visor 1.535-1.665 at the centreline (1.531-1.661 at the ends), centre 1.600, front z -0.185.

## Future skeleton: SkeletonProfileHumanoid map (rest pivots, Godot space)
| Godot bone | PB joint | Position |
|---|---|---|
| Root | (scene origin) | (0, 0, 0) |
| Hips | PB_Pelvis | (0, 0.93, 0) |
| Spine | PB_Abdomen | (0, 1.00, 0) |
| Chest | PB_Chest | (0, 1.12, 0) |
| UpperChest | (none; optional split of PB_Chest) | (0, 1.31, 0) suggested |
| Neck | PB_Neck | (0, 1.49, 0) |
| Head | PB_Head | (0, 1.54, 0) |
| LeftShoulder / RightShoulder | (none; optional clavicle) | (±0.10, 1.40, 0) suggested |
| LeftUpperArm / RightUpperArm | PB_UpperArm_L / _R | (±0.25, 1.36, 0) |
| LeftLowerArm / RightLowerArm | PB_Forearm_L / _R | (±0.275, 1.00, 0) |
| LeftHand / RightHand | PB_Hand_L / _R | (±0.29, 0.80, 0) |
| LeftUpperLeg / RightUpperLeg | PB_Thigh_L / _R | (±0.11, 0.88, 0) |
| LeftLowerLeg / RightLowerLeg | PB_Shin_L / _R | (±0.11, 0.51, 0) |
| LeftFoot / RightFoot | PB_Boot_L / _R | (±0.11, 0.12, 0) |
| LeftToes / RightToes | (none; PB_Toe sits on the foot) | (±0.11, 0.04, -0.12) suggested |
Left = -X (character facing -Z). Finger and eye bones are not modelled (mitten hands). Profile
bones without a joint can be left unmapped in the BoneMap.

## Crouch check (pelvis 0.62, visor centre 0.95; preview only, numbers from the build script)
- Pelvis 0.62 with the eye at 0.95 leaves only 0.33 m between them (0.67 standing), so the spine
  has to fold ~79 deg (head counter-rotated to stay level), hips go 0.44 m behind the face,
  thighs ~79 deg forward. Result: chest into pelvis/thighs (up to 0.25 m), collar/neck seal into
  the helmet (~0.3 m), pack into the chest; hips, arms and pack leave the 1.15 crouched capsule
  by up to 0.26 m and the 0.73 m crouched hurtbox by up to 0.39 m; the head ends up 2-4 cm
  outside the lowered helmet hitbox and the visor 1.8 cm outside the lowered visor box.
- Not a usable pose: the earlier check (pelvis ~0.33, 25 deg lean, deep squat) kept the head
  inside the lowered hitboxes. Either crouch_idle uses a deep squat / kneel with the pelvis
  around 0.30-0.40, or crouch eye height (0.95) / hitbox drop gets revisited.
