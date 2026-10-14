#!/usr/bin/env python3
"""Emit scenes/main/arena_lockout.tscn (arena mode on Lockout) from build_lockout.py.

Does NOT touch scenes/levels/lockout.tscn or main_lockout.tscn (emit_lockout_tscn.py owns
those). Reads P, RAMPS, W, S from build_lockout.py with ast (nothing executed) and writes:
  Lockout instance, Player, the same weapon pickups as main_lockout, ArenaEvents,
  Navigation (runtime-baked NavigationRegion3D) + NavigationLink3D lift / drops / jumps,
  BotGravLift, NavPoints (roam markers), ArenaSpawns (extra spawns), SpawnManager.
Every link endpoint, roam point and spawn is checked to sit on a walkable floor top at least
one agent radius from the floor's edge and clear of walls/parapets; the script fails otherwise.

Run from the repo root:  python3 tools/lockout/emit_arena_tscn.py
"""
import ast
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).with_name("build_lockout.py")
OUT = ROOT / "scenes/main/arena_lockout.tscn"
AGENT_R = 0.35
AGENT_H = 1.8
# Default match: 4-player FFA (the player plus 3 bots). Keep in sync with SpawnManager.bot_count.
BOT_COUNT = 3

lists = {}
for node in ast.parse(SRC.read_text()).body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
        if node.targets[0].id in ("P", "RAMPS", "W", "S"):
            lists[node.targets[0].id] = ast.literal_eval(node.value)
P, RAMPS, W, S = lists["P"], lists["RAMPS"], lists["W"], lists["S"]
BOX = {p[0]: p for p in P}
RAMP = {r[0]: r for r in RAMPS}
FLOORS = [p for p in P if p[7] not in ("Wall", "Parapet")]
SOLIDS = [p for p in P if p[7] in ("Wall", "Parapet")]


def top(name):
    return BOX[name][5]


def edges(name):
    _n, cx, cz, sx, sz, _t, _th, _g = BOX[name]
    return cx - sx / 2, cx + sx / 2, cz - sz / 2, cz + sz / 2


def floor_height(x, z, margin=AGENT_R):
    """Walkable surfaces (flat boxes and ramps) under (x, z) with `margin` from the edge."""
    out = []
    for name, cx, cz, sx, sz, ty, _t, _g in FLOORS:
        if abs(x - cx) <= sx / 2 - margin and abs(z - cz) <= sz / 2 - margin:
            out.append((ty, name))
    for name, (x0, z0, y0), (x1, z1, y1), w, _t, _g in RAMPS:
        dx, dz = x1 - x0, z1 - z0
        ln2 = dx * dx + dz * dz
        t = ((x - x0) * dx + (z - z0) * dz) / ln2
        lat = abs((x - x0) * dz - (z - z0) * dx) / math.sqrt(ln2)
        if 0.0 <= t <= 1.0 and lat <= w / 2 - margin:
            out.append((y0 + t * (y1 - y0), name))
    return out


def check_point(label, x, y, z, margin=AGENT_R):
    """Point must be on a floor top (+-0.1) and its standing capsule clear of walls/parapets."""
    hits = [n for ty, n in floor_height(x, z, margin) if abs(ty - y) <= 0.1]
    if not hits:
        sys.exit(f"FAIL {label} ({x}, {y}, {z}): not on a floor top with {margin} m margin; "
                 f"floors here: {floor_height(x, z, 0.0)}")
    for name, cx, cz, sx, sz, ty, th, _g in SOLIDS:
        if abs(x - cx) < sx / 2 + AGENT_R and abs(z - cz) < sz / 2 + AGENT_R and ty - th < y + AGENT_H and ty > y:
            sys.exit(f"FAIL {label} ({x}, {y}, {z}) overlaps {name}")
    # Headroom: no floor slab between y and y + agent height.
    for name, cx, cz, sx, sz, ty, th, _g in FLOORS:
        if abs(x - cx) < sx / 2 and abs(z - cz) < sz / 2 and y + 0.05 < ty - th < y + AGENT_H:
            sys.exit(f"FAIL {label} ({x}, {y}, {z}): {name} underside at {ty - th} blocks headroom")
    return hits[0]


def fmt(v):
    return ("%.4f" % v).rstrip("0").rstrip(".") if abs(v) > 1e-9 else "0"


def v3(p):
    return "Vector3(%s)" % ", ".join(fmt(c) for c in p)


# ------------------------------------------------------------------ navigation links
# (name, traversal, start, end, lip or None, nav layer, release_y). Layer 2 = skill jumps.
LINKS = []
pad = BOX["BlueLift_Pad"]
tb_x0, tb_x1, tb_z0, tb_z1 = edges("TopBlue_Deck")
# Grav lift: pad centre -> 1 m inside Top Blue's open south edge. Steer off at deck + 0.5.
LINKS.append(("Link_GravLift", "lift", (pad[1], pad[5], pad[2]), (0.0, top("TopBlue_Deck"), tb_z1 - 1.0),
              None, 1, top("TopBlue_Deck") + 0.5))
# Top Blue -> Top Mid: through the north parapet gap (x -2..2), land past the Blue Ramp top.
tm_x0, tm_x1, tm_z0, tm_z1 = edges("TopMid_Deck")
LINKS.append(("Link_Drop_TopBlue_TopMid", "drop", (0.0, top("TopBlue_Deck"), tb_z0 + 0.6),
              (0.0, top("TopMid_Deck"), tm_z1 - 2.0), None, 1, 0.0))
# Library window -> Top Mid: parapet gap x -4..2, clears Top Mid's north parapet (audit: +2.3 m).
lib_x0, lib_x1, lib_z0, lib_z1 = edges("Library_Floor")
LINKS.append(("Link_Drop_Library_TopMid", "drop", (-1.0, top("Library_Floor"), lib_z1 - 0.6),
              (-1.0, top("TopMid_Deck"), tm_z0 + 2.5), None, 1, 0.0))
# Mags -> Bottom Blue: the mags overhang Bottom Blue (z 14..16); walk off the south edge.
for side, name in ((-1, "LeftMag"), (1, "RightMag")):
    mx0, mx1, mz0, mz1 = edges(name)
    x = side * 4.5
    LINKS.append((f"Link_Drop_{name}_BottomBlue", "drop", (x, top(name), mz1 - 0.5),
                  (x, top("BottomBlue_Ledge"), mz1 + 1.5), None, 1, 0.0))
# Elbow Jump: Elbow North lip (z 10.75, y 2.7) -> S1 (south edge z 6). Skill jump, layer 2.
_n, (ex0, ez0, ey0), (ex1, ez1, ey1), _w, _t, _g = RAMP["Elbow_North"]
s1_x0, s1_x1, s1_z0, s1_z1 = edges("S1_Floor")
LINKS.append(("Link_Jump_Elbow", "jump", (ex0, ey0 + (ey1 - ey0) * 0.6 / (ez1 - ez0), ez0 + 0.6),
              (ex0, top("S1_Floor"), s1_z1 - 1.0), (ex0, ey0, ez0 + 0.1), 2, 0.0))
# Open Ramp Jump: Open Ramp top (z -4..-2, y 4.5) -> BR2 west ledge (z -10.3..-8.3, y 6.5).
or_x0, or_x1, or_z0, or_z1 = edges("OpenRamp_Top")
wl_x0, wl_x1, wl_z0, wl_z1 = edges("BR2_WestLedge")
orx = BOX["OpenRamp_Top"][1]
LINKS.append(("Link_Jump_OpenRamp", "jump", (orx, top("OpenRamp_Top"), or_z1 - 0.6),
              (orx, top("BR2_WestLedge"), (wl_z0 + wl_z1) / 2), (orx, top("OpenRamp_Top"), or_z0 + 0.1), 2, 0.0))
# BR2 west ledge -> BR2 bridge link: 1 m hop over a 0.3 m gap (audit: easy jump).
bl_x0, bl_x1, bl_z0, bl_z1 = edges("BR2_BridgeLink")
wz = BOX["BR2_WestLedge"][2]
LINKS.append(("Link_Hop_BR2Ledge", "jump", (wl_x1 - 0.8, top("BR2_WestLedge"), wz),
              (bl_x0 + 1.0, top("BR2_BridgeLink"), wz), (wl_x1 - 0.05, top("BR2_WestLedge"), wz), 1, 0.0))

# ------------------------------------------------------------------ roam points and spawns
# (callout, x, z, floor box or ramp, weight). Power positions weigh 2.
ROAM = [
    ("TopMid", 0, 0, "TopMid_Deck", 2.0), ("BottomMid", -4, -4, "BotMid_Floor", 1.0),
    ("GreenHall", 0, 11, "GreenHall_Floor", 1.0), ("BottomBlue", -3.5, 17.5, "BottomBlue_Ledge", 1.0),
    ("LeftMag", -5.5, 13.5, "LeftMag", 1.0), ("RightMag", 5.5, 13.5, "RightMag", 1.0),
    ("TopBlue", 0, 15, "TopBlue_Deck", 2.0), ("ElbowSouth", 12, 19, "Elbow_South", 1.0),
    ("S1", 17, 1, "S1_Floor", 1.0), ("S2", 18, -5, "S2_Floor", 1.0), ("S3", 16, -6, "S3_SnipeDeck", 2.0),
    ("BR1", -17, 2, "BR1_Floor", 1.0), ("BR2", -18, -2, "BR2_Floor", 1.0), ("BR3", -17, -3, "BR3_Roof", 2.0),
    ("Courtyard", -17, 9, "BR_Courtyard", 1.0), ("BRBridge", -10, -10, "BR_Bridge", 1.0),
    ("Library", -1, -14, "Library_Floor", 1.5), ("Sword", -11, -12, "Sword_Room", 1.0),
    ("SwordHall", -9, 1, "Sword_Hall_Floor", 1.0),
]
EXTRA_SPAWNS = [
    ("BotMidNW", -5.5, -5.5, "BotMid_Floor"), ("BotMidSE", 5.5, 5, "BotMid_Floor"),
    ("GreenHallN", 0, 9.5, "GreenHall_Floor"), ("Courtyard", -14, 9, "BR_Courtyard"),
    ("S2", 19, -5, "S2_Floor"), ("BR2", -18, 1, "BR2_Floor"), ("Library", 3, -15, "Library_Floor"),
    ("ElbowSouthW", 9, 19, "Elbow_South"),
]


def on_floor(label, x, z, name):
    y = top(name) if name in BOX else None
    if y is None:
        sys.exit(f"FAIL {label}: unknown floor {name}")
    check_point(label, x, y, z)
    return (x, y, z)


for name, kind, a, b, lip, layer, _ry in LINKS:
    check_point(f"{name} start", *a)
    check_point(f"{name} end", *b)
    if lip is not None:
        # The lip itself sits on the floor edge (0.05-0.1 m in), so check without the margin.
        check_point(f"{name} lip", *lip, margin=0.0)
ROAM_PTS = [(c, on_floor(f"roam {c}", x, z, f), wgt) for c, x, z, f, wgt in ROAM]
SPAWN_PTS = [(c, on_floor(f"spawn {c}", x, z, f)) for c, x, z, f in EXTRA_SPAWNS]

# Pickups: same mapping as emit_lockout_tscn.py (rifle for BR/SMG/Shotgun, pistol for Magnum
# and Sniper, sword spot empty), so arena and main_lockout match.
PICKUPS = []
for x, z, label, _m in W:
    if "Sword" in label:
        continue
    if "Sniper" in label:
        PICKUPS.append(("PistolPickup_S3", "pistol", x, top("S3_SnipeDeck"), z))
    elif "Top Blue" in label:
        y = top("TopBlue_Deck")
        PICKUPS += [("RiflePickup_TopBlue", "rifle", x, y, z), ("PistolPickup_TopBlueW", "pistol", x - 2, y, z),
                    ("PistolPickup_TopBlueE", "pistol", x + 2, y, z)]
    elif "BR tower" in label:
        PICKUPS.append(("RiflePickup_BR3", "rifle", x, top("BR3_Roof"), z))
    elif "BotMid" in label:
        PICKUPS.append(("RiflePickup_BotMid", "rifle", x, top("BotMid_Floor"), z))
    elif "Green" in label:
        PICKUPS.append(("RiflePickup_Green", "rifle", x, top("GreenHall_Floor"), z))

# ------------------------------------------------------------------ scene text
ext = [
    ("PackedScene", "res://scenes/levels/lockout.tscn", "1_level"),
    ("PackedScene", "res://scenes/player/player.tscn", "2_player"),
    ("PackedScene", "res://scenes/pickups/weapon_pickup.tscn", "3_pickup"),
    ("PackedScene", "res://scenes/weapons/standard_issue_rifle.tscn", "4_rifle"),
    ("PackedScene", "res://scenes/weapons/service_pistol.tscn", "5_pistol"),
    ("PackedScene", "res://scenes/ai/bot.tscn", "6_bot"),
    ("Script", "res://scripts/ai/arena_events.gd", "7_events"),
    ("Script", "res://scripts/ai/arena_navigation.gd", "8_nav"),
    ("Script", "res://scripts/ai/bot_grav_lift.gd", "9_botlift"),
    ("Script", "res://scripts/ai/spawn_manager.gd", "10_spawns"),
    ("Resource", "res://resources/ai/bot_difficulty_normal.tres", "11_diff"),
]
lift_h = top("TopBlue_Deck") + 1.0 - pad[5]  # same volume as the level GravLift
subs = [
    '[sub_resource type="Environment" id="Environment_arena"]\nbackground_mode = 1\n'
    'background_color = Color(0.07, 0.08, 0.09, 1)\nambient_light_source = 2\n'
    'ambient_light_color = Color(0.18, 0.19, 0.2, 1)\nambient_light_energy = 0.45\ntonemap_mode = 3\n',
    f'[sub_resource type="BoxShape3D" id="Shape_BotLift"]\nsize = Vector3({fmt(pad[3])}, {fmt(lift_h)}, {fmt(pad[4])})\n',
]
nodes = [
    '[node name="ArenaLockout" type="Node3D"]\n',
    '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]\nenvironment = SubResource("Environment_arena")\n',
    '[node name="Sun" type="DirectionalLight3D" parent="."]\ntransform = Transform3D(0.866025, -0.353553, 0.353553, 0, '
    '0.707107, 0.707107, -0.5, -0.612372, 0.612372, 0, 20, 0)\nlight_color = Color(0.85, 0.88, 0.95, 1)\n'
    'light_energy = 1.1\nshadow_enabled = true\n',
    # ArenaEvents first so bots and the SpawnManager find it in _ready.
    '[node name="ArenaEvents" type="Node" parent="."]\nscript = ExtResource("7_events")\n',
    '[node name="Lockout" parent="." instance=ExtResource("1_level")]\n',
]
# CHOICE: player starts at level spawn 1 (BR1) facing east, as in main_lockout.
sx, sz = S[1]
nodes.append('[node name="Player" parent="." instance=ExtResource("2_player")]\n'
             f'transform = Transform3D(0, 0, -1, 0, 1, 0, 1, 0, 0, {fmt(sx)}, {fmt(top("BR1_Floor") + 0.05)}, {fmt(sz)})\n')
for name, kind, x, y, z in PICKUPS:
    res = "4_rifle" if kind == "rifle" else "5_pistol"
    nodes.append(f'[node name="{name}" parent="." instance=ExtResource("3_pickup")]\n'
                 f'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {fmt(x)}, {fmt(y)}, {fmt(z)})\n'
                 f'weapon_scene = ExtResource("{res}")\n')
nodes.append('[node name="Navigation" type="NavigationRegion3D" parent="."]\nscript = ExtResource("8_nav")\n'
             'geometry_root = NodePath("../Lockout")\n')
for name, kind, a, b, lip, layer, release_y in LINKS:
    lines = [f'[node name="{name}" type="NavigationLink3D" parent="Navigation"]',
             "bidirectional = false", f"navigation_layers = {layer}",
             f"start_position = {v3(a)}", f"end_position = {v3(b)}",
             f'metadata/traversal = "{kind}"']
    if lip is not None:
        lines.append(f"metadata/lip = {v3(lip)}")
    if kind == "lift":
        lines.append(f"metadata/release_y = {fmt(release_y)}")
    nodes.append("\n".join(lines) + "\n")
# TODO(lift_rider): drop BotGravLift (and Shape_BotLift / 9_botlift) once the level GravLift
# pushes group "lift_rider"; see scripts/ai/bot_grav_lift.gd.
nodes.append('[node name="BotGravLift" type="Area3D" parent="."]\n'
             f'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {fmt(pad[1])}, {fmt(pad[5] + lift_h / 2)}, {fmt(pad[2])})\n'
             'collision_layer = 16\ncollision_mask = 4\nmonitorable = false\nscript = ExtResource("9_botlift")\n'
             'level_lift = NodePath("../Lockout/GravLift")\n')
nodes.append('[node name="Shape" type="CollisionShape3D" parent="BotGravLift"]\nshape = SubResource("Shape_BotLift")\n')
nodes.append('[node name="NavPoints" type="Node3D" parent="."]\n')
for callout, (x, y, z), weight in ROAM_PTS:
    nodes.append(f'[node name="{callout}" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]\n'
                 f'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {fmt(x)}, {fmt(y + 0.05)}, {fmt(z)})\n'
                 f'metadata/weight = {fmt(weight)}\nmetadata/callout = "{callout}"\n')
nodes.append('[node name="ArenaSpawns" type="Node3D" parent="."]\n')
for callout, (x, y, z) in SPAWN_PTS:
    nodes.append(f'[node name="Spawn_{callout}" type="Marker3D" parent="ArenaSpawns"]\n'
                 f'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {fmt(x)}, {fmt(y + 0.05)}, {fmt(z)})\n')
nodes.append('[node name="SpawnManager" type="Node" parent="."]\nscript = ExtResource("10_spawns")\n'
             'bot_scene = ExtResource("6_bot")\n'
             f'bot_count = {BOT_COUNT}\ndifficulty = ExtResource("11_diff")\n')

head = f"[gd_scene load_steps={len(ext) + len(subs) + 1} format=3]\n\n"
head += "\n".join(f'[ext_resource type="{t}" path="{p}" id="{i}"]' for t, p, i in ext) + "\n\n"
OUT.write_text(head + "\n".join(subs) + "\n" + "\n".join(nodes))
print(f"wrote {OUT.relative_to(ROOT)}: {len(LINKS)} links, {len(ROAM_PTS)} roam points, "
      f"{len(SPAWN_PTS)} extra spawns, {len(PICKUPS)} pickups")
for name, kind, a, b, lip, layer, _ry in LINKS:
    dy = b[1] - a[1]
    gap = math.hypot(b[0] - a[0], b[2] - a[2])
    print(f"  {name:28s} {kind:5s} layer {layer}  {a} -> {b}  dY {dy:+.2f}  horiz {gap:.2f}")
