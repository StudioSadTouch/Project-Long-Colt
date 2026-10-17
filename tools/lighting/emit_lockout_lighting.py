#!/usr/bin/env python3
"""Emit Lockout lighting: fixture materials and scenes, the environment, and the lighting scene.

Writes (all original, procedural; no third-party assets):
  resources/materials/lighting/*.tres         fixture housing + emissive materials
  scenes/props/lighting/fixture_*.tscn        reusable fixtures (mesh + light)
  resources/environments/lockout_environment.tres   sky (lockout_sky.gdshader), fog, tonemap, SSAO/SSIL, glow
  scenes/levels/lockout_lighting.tscn         WorldEnvironment + Sun + placed fixtures
The launchers (arena_lockout / main_lockout) instance lockout_lighting.tscn and own the LightmapGI,
whose bake scope is its parent, i.e. the whole launcher, Lockout geometry included.
Direction: /workspace/lighting/lockout_lighting_direction.md
Run from the repo root:  python3 tools/lighting/emit_lockout_lighting.py
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def fmt(v):
    return ("%.6f" % v).rstrip("0").rstrip(".") if abs(v) > 1e-9 else "0"


def norm(v):
    l = math.sqrt(sum(c * c for c in v))
    return tuple(c / l for c in v)


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def basis_from_z(z, up=(0.0, 1.0, 0.0)):
    """Columns X, Y, Z with local +Z = z (lights shine along -Z)."""
    z = norm(z)
    if abs(z[1]) > 0.999:
        up = (0.0, 0.0, -1.0)
    x = norm(cross(up, z))
    y = cross(z, x)
    return x, y, z


def xform(cols, origin):
    x, y, z = cols  # columns -> Godot text is row-major
    vals = [x[0], y[0], z[0], x[1], y[1], z[1], x[2], y[2], z[2], *origin]
    return "Transform3D(%s)" % ", ".join(fmt(v) for v in vals)


def yaw_cols(face):
    """Fixture faces local -Z; turn it to face horizontal direction `face`."""
    return basis_from_z((-face[0], 0.0, -face[2]))


IDENT = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))
DOWN = basis_from_z((0.0, 1.0, 0.0))  # -Z points down


def color(c):
    return "Color(%s, 1)" % ", ".join(fmt(v) for v in c)


def write(rel, text):
    p = ROOT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


# ---------------------------------------------------------------- palette (board: frozen blue-grey + sodium accent)
SODIUM = (1.0, 0.6, 0.26)      # board accent #c47a2c, pushed toward lamp chromaticity
FLUORO = (0.82, 0.93, 1.0)
HALOGEN = (1.0, 0.88, 0.72)
READOUT = (0.5, 0.92, 0.82)
BEACON = (1.0, 0.12, 0.07)
SUN = (1.0, 0.95, 0.88)

MATS = {
    "fixture_housing": dict(albedo=(0.243, 0.298, 0.353), rough=0.7, metal=0.45),           # #3e4c5a
    "fixture_cage": dict(albedo=(0.12, 0.13, 0.14), rough=0.6, metal=0.6),
    "emissive_sodium": dict(albedo=(0.77, 0.48, 0.17), emit=SODIUM, energy=5.0),
    "emissive_fluoro": dict(albedo=(0.9, 0.95, 1.0), emit=FLUORO, energy=6.0),
    "emissive_halogen": dict(albedo=(1.0, 0.95, 0.85), emit=HALOGEN, energy=10.0),
    "emissive_readout": dict(albedo=(0.1, 0.2, 0.18), emit=READOUT, energy=2.5),
    "emissive_beacon": dict(albedo=(0.5, 0.05, 0.03), emit=BEACON, energy=6.0),
}
for name, m in MATS.items():
    lines = ["[gd_resource type=\"StandardMaterial3D\" format=3]", "", "[resource]",
             f"resource_name = \"{name}\"", f"albedo_color = {color(m['albedo'])}"]
    if "emit" in m:
        lines += ["roughness = 0.4", "emission_enabled = true", f"emission = {color(m['emit'])}",
                  f"emission_energy_multiplier = {fmt(m['energy'])}"]
    else:
        lines += [f"roughness = {fmt(m['rough'])}", f"metallic = {fmt(m['metal'])}"]
    write(f"resources/materials/lighting/{name}.tres", "\n".join(lines) + "\n")


# ---------------------------------------------------------------- fixture scenes
def scene(root_name, ext, subs, nodes):
    head = f"[gd_scene load_steps={len(ext) + len(subs) + 1} format=3]\n\n"
    e = "".join(f'[ext_resource type="{t}" path="{p}" id="{i}"]\n' for t, p, i in ext)
    s = "".join(f"\n{x}" for x in subs)
    n = "".join(f"\n{x}" for x in nodes)
    return head + e + s + f'\n[node name="{root_name}" type="Node3D"]\n' + n


def box(sid, size, uv2=False):
    extra = "add_uv2 = true\n" if uv2 else ""
    return f'[sub_resource type="BoxMesh" id="{sid}"]\n{extra}size = Vector3({", ".join(fmt(v) for v in size)})\n'


def mesh_node(name, sid, mat, origin, static=False, cols=IDENT, parent="."):
    gi = "" if static else "gi_mode = 2\n"
    cs = "cast_shadow = 0\n" if static else ""
    return (f'[node name="{name}" type="MeshInstance3D" parent="{parent}"]\n'
            f"transform = {xform(cols, origin)}\nmesh = SubResource(\"{sid}\")\n"
            f'surface_material_override/0 = ExtResource("{mat}")\n{cs}{gi}')


def spot(cols, origin, col, energy, rng, angle, bake=0, shadow=False, fog=1.0):
    lines = ['[node name="Light" type="SpotLight3D" parent="."]', f"transform = {xform(cols, origin)}",
             f"light_color = {color(col)}", f"light_energy = {fmt(energy)}",
             f"light_volumetric_fog_energy = {fmt(fog)}", f"light_bake_mode = {bake}",
             f"shadow_enabled = {'true' if shadow else 'false'}"]
    if shadow:
        lines += ["shadow_bias = 0.04", "shadow_normal_bias = 2.0"]
    lines += ["distance_fade_enabled = true", "distance_fade_begin = 45.0", "distance_fade_length = 10.0",
              f"spot_range = {fmt(rng)}", "spot_attenuation = 1.2", f"spot_angle = {fmt(angle)}",
              "spot_angle_attenuation = 0.8"]
    return "\n".join(lines) + "\n"


M = "res://resources/materials/lighting/"
HOUSING = ("Material", M + "fixture_housing.tres", "1_housing")
CAGE = ("Material", M + "fixture_cage.tres", "2_cage")

# Fluorescent strip: ceiling mount, origin = ceiling surface, hangs 0.12 m, light straight down.
write("scenes/props/lighting/fixture_fluoro_strip.tscn", scene(
    "FixtureFluoroStrip",
    [HOUSING, ("Material", M + "emissive_fluoro.tres", "3_tube")],
    [box("BoxMesh_housing", (1.4, 0.08, 0.24)), box("BoxMesh_tube", (1.3, 0.04, 0.12), uv2=True)],
    [mesh_node("Housing", "BoxMesh_housing", "1_housing", (0, -0.04, 0)),
     mesh_node("Tube", "BoxMesh_tube", "3_tube", (0, -0.1, 0), static=True),
     spot(DOWN, (0, -0.13, 0), FLUORO, 2.2, 5.5, 65.0)]))

# Long-throw variant (inherited) for ground-floor rooms with nothing below them: range 8 m.
write("scenes/props/lighting/fixture_fluoro_strip_long.tscn",
      '[gd_scene load_steps=2 format=3]\n\n'
      '[ext_resource type="PackedScene" path="res://scenes/props/lighting/fixture_fluoro_strip.tscn" id="1_base"]\n\n'
      '[node name="FixtureFluoroStripLong" instance=ExtResource("1_base")]\n\n'
      '[node name="Light" parent="." index="2"]\nlight_energy = 2.6\nspot_range = 8.0\n')

# Sodium wall lamp: origin = wall surface, faces local -Z, light pitched 40 deg down.
pitch = math.radians(40)
SOD_AIM = basis_from_z((0.0, math.sin(pitch), math.cos(pitch)))
write("scenes/props/lighting/fixture_sodium_wall.tscn", scene(
    "FixtureSodiumWall",
    [HOUSING, ("Material", M + "emissive_sodium.tres", "3_lens")],
    [box("BoxMesh_plate", (0.36, 0.3, 0.06)), box("BoxMesh_hood", (0.4, 0.08, 0.32)),
     box("BoxMesh_lens", (0.3, 0.06, 0.24), uv2=True)],
    [mesh_node("Plate", "BoxMesh_plate", "1_housing", (0, 0, -0.03)),
     mesh_node("Hood", "BoxMesh_hood", "1_housing", (0, 0.06, -0.19)),
     mesh_node("Lens", "BoxMesh_lens", "3_lens", (0, -0.01, -0.19), static=True),
     spot(SOD_AIM, (0, -0.06, -0.2), SODIUM, 2.5, 9.0, 55.0, fog=1.5)]))

# Caged work light: origin = mount point, aims along local -Z. Static (baked), no realtime shadow.
work_nodes = [
    mesh_node("Mount", "BoxMesh_mount", "2_cage", (0, 0, 0.05)),
    mesh_node("Body", "BoxMesh_body", "1_housing", (0, 0, -0.12)),
    mesh_node("Lens", "BoxMesh_lens", "3_lens", (0, 0, -0.27), static=True),
]
for i, (x, y) in enumerate([(-0.13, 0.0), (0.13, 0.0), (0.0, -0.13), (0.0, 0.13)]):
    sid = "BoxMesh_bar_v" if x else "BoxMesh_bar_h"
    work_nodes.append(mesh_node(f"CageBar{i}", sid, "2_cage", (x, y, -0.33)))
write("scenes/props/lighting/fixture_caged_worklight.tscn", scene(
    "FixtureCagedWorklight",
    [HOUSING, CAGE, ("Material", M + "emissive_halogen.tres", "3_lens")],
    [box("BoxMesh_mount", (0.12, 0.12, 0.1)), box("BoxMesh_body", (0.3, 0.26, 0.24)),
     box("BoxMesh_lens", (0.24, 0.2, 0.04), uv2=True), box("BoxMesh_bar_v", (0.025, 0.28, 0.025)),
     box("BoxMesh_bar_h", (0.28, 0.025, 0.025))],
    work_nodes + [spot(IDENT, (0, 0, -0.3), HALOGEN, 3.0, 14.0, 38.0)]))

# Shadowed hero variant (inherited scene): realtime shadows, dynamic bake (indirect only).
write("scenes/props/lighting/fixture_caged_worklight_shadowed.tscn",
      '[gd_scene load_steps=2 format=3]\n\n'
      '[ext_resource type="PackedScene" path="res://scenes/props/lighting/fixture_caged_worklight.tscn" id="1_base"]\n\n'
      '[node name="FixtureCagedWorklightShadowed" instance=ExtResource("1_base")]\n\n'
      '[node name="Light" parent="." index="7"]\nlight_energy = 6.0\nlight_bake_mode = 0\nshadow_enabled = true\n'
      'shadow_bias = 0.04\nshadow_normal_bias = 2.0\nspot_range = 16.0\n')

# Emissive readout panel: wall mount, faces local -Z, soft fill spot.
write("scenes/props/lighting/fixture_emissive_panel.tscn", scene(
    "FixtureEmissivePanel",
    [HOUSING, ("Material", M + "emissive_readout.tres", "3_screen")],
    [box("BoxMesh_frame", (0.7, 0.5, 0.06)), box("BoxMesh_screen", (0.58, 0.38, 0.02), uv2=True)],
    [mesh_node("Frame", "BoxMesh_frame", "1_housing", (0, 0, -0.03)),
     mesh_node("Screen", "BoxMesh_screen", "3_screen", (0, 0, -0.065), static=True),
     spot(IDENT, (0, 0, -0.1), READOUT, 0.6, 3.5, 75.0)]))

# Beacon: emissive only (no light), for tower-top silhouettes.
write("scenes/props/lighting/fixture_beacon.tscn", scene(
    "FixtureBeacon",
    [HOUSING, ("Material", M + "emissive_beacon.tres", "3_lamp")],
    [box("BoxMesh_base", (0.16, 0.08, 0.16)), box("BoxMesh_lamp", (0.1, 0.12, 0.1), uv2=True)],
    [mesh_node("Base", "BoxMesh_base", "1_housing", (0, 0.04, 0)),
     mesh_node("Lamp", "BoxMesh_lamp", "3_lamp", (0, 0.14, 0), static=True)]))

# ---------------------------------------------------------------- environment
write("resources/environments/lockout_environment.tres", """[gd_resource type="Environment" load_steps=4 format=3]

[ext_resource type="Shader" path="res://resources/shaders/lockout_sky.gdshader" id="1_sky"]

[sub_resource type="ShaderMaterial" id="ShaderMaterial_sky"]
shader = ExtResource("1_sky")

[sub_resource type="Sky" id="Sky_lockout"]
sky_material = SubResource("ShaderMaterial_sky")

[resource]
resource_name = "lockout_environment"
background_mode = 2
sky = SubResource("Sky_lockout")
ambient_light_source = 3
ambient_light_color = Color(0.43, 0.506, 0.569, 1)
ambient_light_sky_contribution = 1.0
ambient_light_energy = 0.7
reflected_light_source = 2
tonemap_mode = 3
tonemap_exposure = 1.0
tonemap_white = 6.0
ssao_enabled = true
ssao_radius = 1.0
ssao_intensity = 1.2
ssao_power = 1.5
ssao_detail = 0.0
ssil_enabled = false
ssil_radius = 3.0
ssil_intensity = 0.6
glow_enabled = true
glow_intensity = 0.5
glow_strength = 0.9
glow_bloom = 0.02
glow_hdr_threshold = 1.2
fog_enabled = true
fog_light_color = Color(0.6, 0.68, 0.76, 1)
fog_light_energy = 1.0
fog_sun_scatter = 0.15
fog_density = 0.002
fog_aerial_perspective = 0.5
fog_sky_affect = 0.25
volumetric_fog_enabled = true
volumetric_fog_density = 0.004
volumetric_fog_albedo = Color(0.85, 0.9, 1, 1)
volumetric_fog_anisotropy = 0.35
volumetric_fog_length = 48.0
volumetric_fog_sky_affect = 0.0
""")

# ---------------------------------------------------------------- sun
ELEV, AZ_DEG = 35.0, 225.0   # sun FROM the south-west (azimuth from north, clockwise; -Z = north)
el, az = math.radians(ELEV), math.radians(AZ_DEG)
to_sun = (math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el))
SUN_COLS = basis_from_z(to_sun)

# ---------------------------------------------------------------- placements
# World = Lockout local. Positions are MCC-map pixels like tools/lockout/build_lockout_greybox.py
# (M() converts; heights in metres): B 0, Top Mid 4.5, upper lift room 5.0, S3 8.5, BR3 roof 9.0.
F, FL, S, W, WS, P, B = ("fluoro", "fluoro_long", "sodium", "work", "work_shadowed", "panel", "beacon")
PX, NX, PZ, NZ = (1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)


def M(px, py, y):
    return (round((px - 279) * 0.12, 3), y, round((py - 390) * 0.12, 3))


PLACE = [
    # Bottom Mid (ceiling = Top Mid deck underside, 4.0) and the two bottom halls
    ("BotMid_Fluoro_W", FL, M(268, 400, 4.0), None), ("BotMid_Fluoro_E", FL, M(293, 400, 4.0), None),
    ("BotMid_Fluoro_S", FL, M(280, 425, 4.0), None),
    ("BotMid_Panel_N", P, M(300, 382, 1.6), PZ),
    ("SniperAlley_Fluoro", FL, M(233, 398, 4.0), None),
    ("EastCorridor_Fluoro", FL, M(326, 409, 4.0), None),
    # Lift tower: lower room (ceiling 4.5), lift pad panels, upper room (ceiling 9.5)
    ("LiftLower_Fluoro_NW", FL, M(248, 190, 4.5), None), ("LiftLower_Fluoro_NE", FL, M(310, 190, 4.5), None),
    ("LiftLower_Fluoro_SW", FL, M(248, 255, 4.5), None), ("LiftLower_Fluoro_SE", FL, M(310, 255, 4.5), None),
    ("Lift_Panel_W", P, M(263, 160, 0.12), "up"), ("Lift_Panel_E", P, M(297, 160, 0.12), "up"),
    ("LiftUpper_Fluoro_W", F, M(252, 225, 9.5), None), ("LiftUpper_Fluoro_E", F, M(306, 225, 9.5), None),
    ("LiftUpper_Fluoro_S", F, M(280, 262, 9.5), None),
    ("GreenHall_Sodium_W", S, M(256, 282.5, 3.4), PZ), ("GreenHall_Sodium_E", S, M(304, 282.5, 3.4), PZ),
    # BR tower: BR1 (ceiling 4.0), BR2 (ceiling 8.5)
    ("BR1_Fluoro_A", FL, M(115, 395, 4.0), None), ("BR1_Fluoro_B", FL, M(140, 435, 4.0), None),
    ("BR1_Fluoro_C", FL, M(105, 455, 4.0), None),
    ("BR2_Fluoro_A", F, M(130, 400, 8.5), None), ("BR2_Fluoro_B", F, M(140, 460, 8.5), None),
    ("BR2_Fluoro_C", F, M(188, 452, 8.5), None),
    ("BR2_Sodium_Balcony", S, M(170, 487.5, 7.6), PZ),
    # Sniper stack: S1 (ceiling 4.0), S2 (8.0), S3 (12.0)
    ("S1_Fluoro_A", FL, M(400, 420, 4.0), None), ("S1_Fluoro_B", FL, M(445, 420, 4.0), None),
    ("S1_Fluoro_C", FL, M(490, 420, 4.0), None),
    ("S2_Fluoro_A", F, M(400, 430, 8.0), None), ("S2_Fluoro_B", F, M(450, 425, 8.0), None),
    ("S2_Fluoro_C", F, M(490, 425, 8.0), None),
    ("S3_Fluoro_A", F, M(440, 404, 12.0), None), ("S3_Fluoro_B", F, M(510, 404, 12.0), None),
    ("S3_Sodium_Elbow", S, M(554.5, 393, 11.0), PX),
    # Library (ceiling 8.0) and its basement (floor -3, ceiling 4.0)
    ("Library_Fluoro_W", F, M(330, 520, 8.0), None), ("Library_Fluoro_C", F, M(400, 520, 8.0), None),
    ("Library_Fluoro_E", F, M(468, 520, 8.0), None), ("Library_Fluoro_Bay", F, M(400, 560, 8.0), None),
    ("Library_Panel_Pod", P, M(400, 565.5, 1.6 + 4.5), NZ),
    ("Basement_Fluoro_W", FL, M(360, 511, 4.0), None), ("Basement_Fluoro_C", FL, M(416, 511, 4.0), None),
    ("Basement_Fluoro_E", FL, M(462, 511, 4.0), None),
    ("Basement_Work", WS, M(426, 547, 3.4), M(420, 510, -3.0)),
    # Exterior floods onto Top Mid from the lift tower and the Library
    ("TopMid_Flood_LiftW", W, M(262, 283, 9.0), M(270, 400, 4.5)),
    ("TopMid_Flood_LiftE", W, M(298, 283, 9.0), M(290, 400, 4.5)),
    ("TopMid_Flood_Library", W, M(330, 487, 7.8), M(280, 410, 4.5)),
    # Beacons (emissive only) on the tower tops
    ("LiftTower_Beacon_W", B, M(236, 150, 10.0), None), ("LiftTower_Beacon_E", B, M(319, 150, 10.0), None),
    ("BR3_Beacon", B, M(59, 379, 10.05), None), ("S3_Beacon", B, M(530, 362, 12.5), None),
]
SCENES = {F: "fixture_fluoro_strip", FL: "fixture_fluoro_strip_long", S: "fixture_sodium_wall", W: "fixture_caged_worklight",
          WS: "fixture_caged_worklight_shadowed", P: "fixture_emissive_panel", B: "fixture_beacon"}

ext = [("PackedScene", f"res://scenes/props/lighting/{SCENES[k]}.tscn", f"{i + 2}_{k}") for i, k in enumerate(SCENES)]
ext.insert(0, ("Environment", "res://resources/environments/lockout_environment.tres", "1_env"))
ids = {k: f"{i + 2}_{k}" for i, k in enumerate(SCENES)}
nodes = ['[node name="WorldEnvironment" type="WorldEnvironment" parent="."]\nenvironment = ExtResource("1_env")\n',
         '[node name="Sun" type="DirectionalLight3D" parent="."]\n'
         f"transform = {xform(SUN_COLS, (0, 30, 0))}\nlight_color = {color(SUN)}\nlight_energy = 2.0\n"
         "light_indirect_energy = 1.0\nlight_bake_mode = 0\nshadow_enabled = true\nshadow_bias = 0.04\n"
         "shadow_normal_bias = 2.0\ndirectional_shadow_mode = 2\ndirectional_shadow_split_1 = 0.07\n"
         "directional_shadow_split_2 = 0.2\ndirectional_shadow_split_3 = 0.5\n"
         "directional_shadow_blend_splits = true\ndirectional_shadow_fade_start = 0.85\n"
         "directional_shadow_max_distance = 120.0\n",
         '[node name="Fixtures" type="Node3D" parent="."]\n']
plot = []
for name, kind, pos, aim in PLACE:
    if aim is None:
        cols = IDENT
    elif aim == "up":
        cols = basis_from_z((0.0, -1.0, 0.0))  # -Z points up
    elif kind in (W, WS):
        cols = basis_from_z(tuple(p - a for p, a in zip(pos, aim)))
    else:
        cols = yaw_cols(aim)
    nodes.append(f'[node name="{name}" parent="Fixtures" instance=ExtResource("{ids[kind]}")]\n'
                 f"transform = {xform(cols, pos)}\n")
    plot.append({"name": name, "kind": kind, "pos": pos, "aim": aim if isinstance(aim, (tuple, str)) else None})
write("scenes/levels/lockout_lighting.tscn", scene("LockoutLighting", ext, [], nodes))
(ROOT / "tools/lighting/lockout_fixtures.json").write_text(json.dumps(
    {"sun_to": to_sun, "fixtures": plot}, indent=1) + "\n")
print(f"wrote {len(PLACE)} fixtures; sun dir to light {tuple(round(c, 3) for c in to_sun)}")
