#!/usr/bin/env python3
"""Emit the Lockout greybox scenes from build_lockout.py (the single geometry source).

Reads P, W and S from build_lockout.py with ast (no matplotlib needed, nothing executed),
plus the "# sloped a->b" comments for ramp rises. Writes:
  scenes/levels/lockout.tscn      geometry (World layer 1), grav lift, kill volume, spawn markers
  scenes/main/main_lockout.tscn   launcher: environment, level, player, pickups, dummies, paths

Run from the repo root:  python3 tools/lockout/emit_lockout_tscn.py
Only placement choices that build_lockout.py does not express live here (marked CHOICE).
"""
import ast
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).with_name("build_lockout.py")

# ---------------------------------------------------------------- read the source
text = SRC.read_text()
tree = ast.parse(text)
lists = {}
for node in tree.body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
        if name in ("P", "W", "S", "RAMPS"):
            lists[name] = ast.literal_eval(node.value)
P, W, S, RAMPS = lists["P"], lists["W"], lists["S"], lists["RAMPS"]
import sys
WRITE_LAUNCHER = "--launcher" in sys.argv  # main_lockout.tscn is hand-edited on main; regenerate only on request
SLOPES = {}
for line in text.splitlines():
    m = re.search(r'\("(\w+)".*#\s*sloped\s*([\d.]+)\s*->\s*([\d.]+)', line)
    if m:
        SLOPES[m.group(1)] = (float(m.group(2)), float(m.group(3)))
BOX = {p[0]: p for p in P}

# CHOICE: every ramp's high end points north (-Z), matching the arrows in the overhead.
RAMP_HIGH_END_NORTH = True


def floor_top_at(x, z, prefer=None):
    """Highest flat floor whose footprint contains (x, z), or a named one."""
    if prefer:
        return BOX[prefer][5]
    tops = [p[5] for p in P if p[0] not in SLOPES and p[7] not in ("Wall", "Parapet")
            and abs(x - p[1]) <= p[3] / 2 and abs(z - p[2]) <= p[4] / 2]
    return max(tops) if tops else 0.0


def fmt(v):
    return ("%.6f" % v).rstrip("0").rstrip(".") if abs(v) > 1e-9 else "0"


def xform(basis, origin):
    (a, b, c), (d, e, f), (g, h, i) = basis
    vals = [a, b, c, d, e, f, g, h, i, *origin]
    return "Transform3D(%s)" % ", ".join(fmt(v) for v in vals)


IDENT = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


def rot_x(t):
    c, s = math.cos(t), math.sin(t)
    return ((1, 0, 0), (0, c, -s), (0, s, c))


def rot_y(t):
    c, s = math.cos(t), math.sin(t)
    return ((c, 0, s), (0, 1, 0), (-s, 0, c))


def rot_z(t):
    c, s = math.cos(t), math.sin(t)
    return ((c, -s, 0), (s, c, 0), (0, 0, 1))


def level_of(y):
    if y < 1.0:
        return 0
    if y < 5.0:
        return 1
    if y < 8.5:
        return 2
    return 3


LEVEL_COLORS = [(0.28, 0.24, 0.32), (0.26, 0.38, 0.42), (0.3, 0.5, 0.38), (0.62, 0.6, 0.3)]
LEVEL_NAMES = ["Ground", "Mid", "Upper", "Top"]

# ---------------------------------------------------------------- level scene
subs, nodes = [], []
for i, (r, g, b) in enumerate(LEVEL_COLORS):
    subs.append(f'[sub_resource type="StandardMaterial3D" id="Mat_{LEVEL_NAMES[i]}"]\n'
                f'albedo_color = Color({r}, {g}, {b}, 1)\nroughness = 0.85\n')

nodes.append('[node name="Lockout" type="Node3D"]\n')
nodes.append('[node name="Geometry" type="Node3D" parent="."]\n')
for name, cx, cz, sx, sz, top, t, group in P:
    basis = IDENT
    size = [sx, t, sz]
    center_y = top - t / 2
    if name in SLOPES:
        lo, hi = SLOPES[name]
        rise = hi - lo
        along_z = sz >= sx
        run = sz if along_z else sx
        angle = math.atan2(rise, run)
        if along_z:
            size[2] = math.hypot(run, rise)
            basis = rot_x(angle if RAMP_HIGH_END_NORTH else -angle)
        else:
            size[0] = math.hypot(run, rise)
            basis = rot_z(angle)
        # top is the mid-height of the slope; drop the centre along the tilted normal.
        center_y = (lo + hi) / 2 - (t / 2) * math.cos(angle)
    mat = LEVEL_NAMES[level_of(top)]
    sid = f"Box_{name}"
    subs.append(f'[sub_resource type="BoxMesh" id="Mesh_{sid}"]\nmaterial = SubResource("Mat_{mat}")\n'
                f'size = Vector3({fmt(size[0])}, {fmt(size[1])}, {fmt(size[2])})\n')
    subs.append(f'[sub_resource type="BoxShape3D" id="Shape_{sid}"]\n'
                f'size = Vector3({fmt(size[0])}, {fmt(size[1])}, {fmt(size[2])})\n')
    nodes.append(f'[node name="{name}" type="StaticBody3D" parent="Geometry"]\n'
                 f'transform = {xform(basis, (cx, center_y, cz))}\ncollision_layer = 1\ncollision_mask = 0\n'
                 f'metadata/group = "{group}"\n')
    nodes.append(f'[node name="Mesh" type="MeshInstance3D" parent="Geometry/{name}"]\nmesh = SubResource("Mesh_{sid}")\n')
    nodes.append(f'[node name="Shape" type="CollisionShape3D" parent="Geometry/{name}"]\nshape = SubResource("Shape_{sid}")\n')

# Ramps from explicit endpoints (low -> high top-surface centres). Basis columns: X across, Y normal, Z along.
for name, (x0, z0, y0), (x1, z1, y1), w, t, group in RAMPS:
    d = (x1 - x0, y1 - y0, z1 - z0)
    ln = math.sqrt(sum(c * c for c in d))
    f = tuple(c / ln for c in d)
    xa = (f[2], 0.0, -f[0])  # up x f
    xl = math.hypot(xa[0], xa[2])
    xa = (xa[0] / xl, 0.0, xa[2] / xl)
    ya = (f[1] * xa[2] - f[2] * xa[1], f[2] * xa[0] - f[0] * xa[2], f[0] * xa[1] - f[1] * xa[0])
    mid = ((x0 + x1) / 2 - ya[0] * t / 2, (y0 + y1) / 2 - ya[1] * t / 2, (z0 + z1) / 2 - ya[2] * t / 2)
    mat = LEVEL_NAMES[level_of(max(y0, y1))]
    sid = f"Box_{name}"
    for kind in ("BoxMesh", "BoxShape3D"):
        extra = f'material = SubResource("Mat_{mat}")\n' if kind == "BoxMesh" else ""
        subs.append(f'[sub_resource type="{kind}" id="{"Mesh" if kind == "BoxMesh" else "Shape"}_{sid}"]\n{extra}'
                    f'size = Vector3({fmt(w)}, {fmt(t)}, {fmt(ln)})\n')
    nodes.append(f'[node name="{name}" type="StaticBody3D" parent="Geometry"]\n'
                 f'transform = Transform3D({", ".join(fmt(v) for v in (*xa, *ya, *f, *mid))})\ncollision_layer = 1\ncollision_mask = 0\n'
                 f'metadata/group = "{group}"\nmetadata/slope_deg = {fmt(round(math.degrees(math.asin(f[1])), 2))}\n')
    nodes.append(f'[node name="Mesh" type="MeshInstance3D" parent="Geometry/{name}"]\nmesh = SubResource("Mesh_{sid}")\n')
    nodes.append(f'[node name="Shape" type="CollisionShape3D" parent="Geometry/{name}"]\nshape = SubResource("Shape_{sid}")\n')

# Grav lift: pad footprint, from the pad up to Top Blue + 1.0. With lift_speed 12 the player leaves the
# volume at 12 m/s and coasts 12^2/(2*22) = 3.27 m higher; see audit_jumps.py for the arc onto Top Blue.
pad = BOX["BlueLift_Pad"]
lift_h = BOX["TopBlue_Deck"][5] + 1.0 - pad[5]
subs.append(f'[sub_resource type="BoxShape3D" id="Shape_Lift"]\nsize = Vector3({pad[3]}, {fmt(lift_h)}, {pad[4]})\n')
nodes.append(f'[node name="GravLift" type="Area3D" parent="."]\n'
             f'transform = {xform(IDENT, (pad[1], pad[5] + lift_h / 2, pad[2]))}\n'
             'collision_layer = 16\ncollision_mask = 2\nmonitorable = false\nscript = ExtResource("1_lift")\n')
nodes.append('[node name="Shape" type="CollisionShape3D" parent="GravLift"]\nshape = SubResource("Shape_Lift")\n')
# Kill volume at y = -10 (spec section 7).
subs.append('[sub_resource type="BoxShape3D" id="Shape_Kill"]\nsize = Vector3(200, 2, 200)\n')
nodes.append(f'[node name="KillVolume" type="Area3D" parent="."]\ntransform = {xform(IDENT, (0, -10, 0))}\n'
             'collision_layer = 16\ncollision_mask = 6\nmonitorable = false\nscript = ExtResource("2_kill")\n')
nodes.append('[node name="Shape" type="CollisionShape3D" parent="KillVolume"]\nshape = SubResource("Shape_Kill")\n')
# Spawns: S from the source; height = highest flat floor at that x/z.
nodes.append('[node name="Spawns" type="Node3D" parent="."]\n')
SPAWNS = []
for i, (x, z) in enumerate(S):
    y = floor_top_at(x, z) + 0.05
    SPAWNS.append((x, y, z))
    nodes.append(f'[node name="Spawn{i}" type="Marker3D" parent="Spawns"]\ntransform = {xform(IDENT, (x, y, z))}\n')

ext = ('[ext_resource type="Script" path="res://scripts/levels/grav_lift.gd" id="1_lift"]\n'
       '[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="2_kill"]\n')
level = (f"[gd_scene load_steps={len(subs) + 3} format=3]\n\n{ext}\n" + "\n".join(subs) + "\n" + "\n".join(nodes))
(ROOT / "scenes/levels/lockout.tscn").write_text(level)

# ---------------------------------------------------------------- launcher scene
# CHOICE: player starts at spawn 1 (BR1) facing east toward Top Mid; other spawns are markers.
PLAYER_SPAWN = 1
# CHOICE: map the source's weapon spots (W labels) onto floors and the five-gun roster (same
# mapping as emit_arena_tscn.py, see the reasoning there): Shotgun at BotMid, Directed Energy
# Rifle in Green hall (z = 17), Marksman Carbine on the BR tower roof, pistols on S3 and Top
# Blue, rifle on Top Blue; sword spot stays empty. Power weapons respawn after 90 s.
POWER_RESPAWN = 90.0
PICKUPS = []  # (name, kind, x, y, z, respawn_delay or None)
for x, z, label, _marker in W:
    if "Sword" in label:
        continue
    if "Sniper" in label:
        PICKUPS.append(("PistolPickup_S3", "pistol", x, floor_top_at(x, z, "S3_SnipeDeck"), z, None))
    elif "Top Blue" in label:  # BR + 2 Magnums on top of lift
        y = floor_top_at(x, z, "TopBlue_Deck")
        PICKUPS.append(("RiflePickup_TopBlue", "rifle", x, y, z, None))
        PICKUPS.append(("PistolPickup_TopBlueW", "pistol", x - 2, y, z, None))
        PICKUPS.append(("PistolPickup_TopBlueE", "pistol", x + 2, y, z, None))
    elif "BR tower" in label:
        PICKUPS.append(("CarbinePickup_BR3", "carbine", x, floor_top_at(x, z, "BR3_Roof"), z, None))
    elif "BotMid" in label:
        PICKUPS.append(("ShotgunPickup_BotMid", "shotgun", x, floor_top_at(x, z, "BotMid_Floor"), z, POWER_RESPAWN))
    elif "Green" in label:
        PICKUPS.append(("EnergyRiflePickup_Green", "energy", x, floor_top_at(x, 17.0, "GreenHall_Floor"), 17.0,
                        POWER_RESPAWN))
WEAPON_RES = {"rifle": "4_rifle", "pistol": "5_pistol", "carbine": "8_carbine", "shotgun": "9_shotgun",
              "energy": "10_energy"}
SWORD = next((x, z) for x, z, label, _m in W if "Sword" in label)
SWORD_Y = floor_top_at(*SWORD, prefer="Sword_Room")

FACE_SOUTH = rot_y(math.pi)  # dummy front (-Z) toward +Z
FACE_WEST = rot_y(math.pi / 2)  # front toward -X
FACE_NORTH = IDENT


def inset(name, margin_x=0.5, margin_z=0.5):
    _n, cx, cz, sx, sz, _t, _th, _g = BOX[name]
    return (cx - sx / 2 + margin_x, cz - sz / 2 + margin_z, cx + sx / 2 - margin_x, cz + sz / 2 - margin_z)


DUMMIES = []  # name, basis, pos, props
b = inset("BR_Bridge", 0.6, 0.5)
DUMMIES.append(("Strafer_BRBridge", FACE_SOUTH, (BOX["BR_Bridge"][1], BOX["BR_Bridge"][5], BOX["BR_Bridge"][2]),
                {"pattern": 1, "move_seed": 2001, "strafe_speed": 7.5, "strafe_duration": 0.7, "strafe_jitter": 0.3,
                 "bounds": b}))
b = inset("S1_TopMid_Link", 0.6, 0.5)
DUMMIES.append(("Strafer_S1Link", FACE_WEST, (BOX["S1_TopMid_Link"][1], BOX["S1_TopMid_Link"][5], BOX["S1_TopMid_Link"][2]),
                {"pattern": 1, "move_seed": 2002, "strafe_speed": 5.0, "strafe_duration": 0.5, "strafe_jitter": 0.3,
                 "bounds": b}))
b = inset("Elbow_South", 0.6, 0.5)
DUMMIES.append(("Strafer_ElbowSouth", FACE_NORTH, (BOX["Elbow_South"][1], BOX["Elbow_South"][5], BOX["Elbow_South"][2]),
                {"pattern": 1, "move_seed": 2003, "strafe_speed": 7.5, "strafe_duration": 0.9, "strafe_jitter": 0.4,
                 "bounds": b}))
b = inset("TopMid_Deck", 1.0, 1.0)
DUMMIES.append(("Spartan_TopMid", FACE_SOUTH, (2.0, BOX["TopMid_Deck"][5], -3.0),
                {"pattern": 2, "move_seed": 2004, "bounds": b}))
# PATH loops: square loops inset 2 m from the deck/floor edges.
PATHS = []
for pname, floor in (("Path_TopMid", "TopMid_Deck"), ("Path_BotMid", "BotMid_Floor")):
    _n, cx, cz, sx, sz, top, _t, _g = BOX[floor]
    hx, hz = sx / 2 - 2.0, sz / 2 - 2.0
    pts = [(cx - hx, top, cz - hz), (cx + hx, top, cz - hz), (cx + hx, top, cz + hz), (cx - hx, top, cz + hz),
           (cx - hx, top, cz - hz)]
    PATHS.append((pname, pts))
    DUMMIES.append((f"Pather_{floor.split('_')[0]}", FACE_SOUTH if floor.startswith("Top") else FACE_NORTH,
                    pts[0], {"pattern": 3, "move_seed": 0, "path": f"../{pname}", "path_speed": 4.0,
                             "bounds": inset(floor, 1.0, 1.0)}))

ext = ['[ext_resource type="PackedScene" path="res://scenes/levels/lockout.tscn" id="1_level"]',
       '[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="2_player"]',
       '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="3_pickup"]',
       '[ext_resource type="PackedScene" path="res://scenes/weapons/standard_issue_rifle.tscn" id="4_rifle"]',
       '[ext_resource type="PackedScene" path="res://scenes/weapons/service_pistol.tscn" id="5_pistol"]',
       '[ext_resource type="PackedScene" path="res://scenes/ai/moving_dummy.tscn" id="6_moving"]',
       '[ext_resource type="PackedScene" path="res://scenes/weapons/marksman_carbine.tscn" id="8_carbine"]',
       '[ext_resource type="PackedScene" path="res://scenes/weapons/combat_shotgun.tscn" id="9_shotgun"]',
       '[ext_resource type="PackedScene" path="res://scenes/weapons/directed_energy_rifle.tscn" id="10_energy"]']
subs = ['[sub_resource type="Environment" id="Environment_lockout"]\nbackground_mode = 1\n'
        'background_color = Color(0.07, 0.08, 0.09, 1)\nambient_light_source = 2\n'
        'ambient_light_color = Color(0.18, 0.19, 0.2, 1)\nambient_light_energy = 0.45\ntonemap_mode = 3\n']
for pname, pts in PATHS:
    flat = ", ".join(f"0, 0, 0, 0, 0, 0, {fmt(x)}, {fmt(y + 0.05)}, {fmt(z)}" for x, y, z in pts)
    subs.append(f'[sub_resource type="Curve3D" id="Curve_{pname}"]\n_data = {{\n"points": PackedVector3Array({flat}),\n'
                f'"tilts": PackedFloat32Array({", ".join("0" for _ in pts)})\n}}\npoint_count = {len(pts)}\n')
nodes = ['[node name="MainLockout" type="Node3D"]\n',
         '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]\nenvironment = SubResource("Environment_lockout")\n',
         '[node name="Sun" type="DirectionalLight3D" parent="."]\ntransform = Transform3D(0.866025, -0.353553, 0.353553, 0, '
         '0.707107, 0.707107, -0.5, -0.612372, 0.612372, 0, 20, 0)\nlight_color = Color(0.85, 0.88, 0.95, 1)\n'
         'light_energy = 1.1\nshadow_enabled = true\n',
         '[node name="Lockout" parent="." instance=ExtResource("1_level")]\n']
px, py, pz = SPAWNS[PLAYER_SPAWN]
nodes.append(f'[node name="Player" parent="." instance=ExtResource("2_player")]\n'
             f'transform = {xform(rot_y(-math.pi / 2), (px, py, pz))}\n')
for name, kind, x, y, z, delay in PICKUPS:
    nodes.append(f'[node name="{name}" parent="." instance=ExtResource("3_pickup")]\n'
                 f'transform = {xform(IDENT, (x, y, z))}\nweapon_scene = ExtResource("{WEAPON_RES[kind]}")\n'
                 + (f"respawn_delay = {delay}\n" if delay is not None else ""))
nodes.append(f'[node name="SwordSpot" type="Marker3D" parent="."]\ntransform = {xform(IDENT, (SWORD[0], SWORD_Y, SWORD[1]))}\n')
nodes.append('[node name="Label" type="Label3D" parent="SwordSpot"]\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.2, 0)\n'
             'billboard = 1\nfont_size = 48\noutline_size = 8\nmodulate = Color(1, 0.3, 1, 1)\n'
             'text = "ENERGY SWORD (empty spot)"\n')
for pname, _pts in PATHS:
    nodes.append(f'[node name="{pname}" type="Path3D" parent="."]\ncurve = SubResource("Curve_{pname}")\n')
for name, basis, pos, props in DUMMIES:
    x0, z0, x1, z1 = props.pop("bounds")
    lines = [f'[node name="{name}" parent="." instance=ExtResource("6_moving")]',
             f'transform = {xform(basis, (pos[0], pos[1] + 0.05, pos[2]))}']
    for k, v in props.items():
        lines.append(f'{k} = NodePath("{v}")' if k == "path" else f"{k} = {v}")
    lines.append(f"bounds_min = Vector2({fmt(x0)}, {fmt(z0)})")
    lines.append(f"bounds_max = Vector2({fmt(x1)}, {fmt(z1)})")
    nodes.append("\n".join(lines) + "\n")
launcher = (f"[gd_scene load_steps={len(ext) + len(subs) + 1} format=3]\n\n" + "\n".join(ext) + "\n\n"
            + "\n".join(subs) + "\n" + "\n".join(nodes))
if WRITE_LAUNCHER:
    (ROOT / "scenes/main/main_lockout.tscn").write_text(launcher)
else:
    print("main_lockout.tscn NOT written (pass --launcher to regenerate it; it is hand-edited on main)")
print(f"wrote {len(P)} boxes, {len(SPAWNS)} spawns, {len(PICKUPS)} pickups, {len(DUMMIES)} dummies")
for i, s in enumerate(SPAWNS):
    print("spawn", i, s)
for p in PICKUPS:
    print("pickup", p)
print("sword", SWORD, SWORD_Y)
for d in DUMMIES:
    print("dummy", d[0], d[2])
