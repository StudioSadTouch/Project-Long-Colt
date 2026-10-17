#!/usr/bin/env python3
"""Generate the Weapon Range: a test map for every weapon (offline and LAN).

    python3 tools/range/build_range.py

Writes scenes/levels/range.tscn (geometry: plain box StaticBodies, no Blender) and
scenes/main/arena_range.tscn (the match scene MapList loads). Edit this script, not them.

Layout (metres; the firing line faces -Z):
  * Armory (z 2..14): spawns, a rack with one of every weapon (3 s respawn), a second rack in
    front of it with the New Ottoman issue weapons the enemies drop, and ammo crates.
  * Firing lane (x -14..14, z 0..-125): static dummies at 10 / 25 / 50 / 75 / 100 m with
    distance boards, strafing dummies at 15 / 35 m (walk and ADAD pace), a Spartan-pattern one
    at 60 m, a berm at the far end.
  * Melee pit (x 20..36, z -4..-22): low walls, static and moving dummies at sword / hammer
    reach.
  * Blast pad (x -36..-20, z -8..-30): a dummy cluster with half cover, for rocket and grenade
    splash and the hammer's smash radius.
Dummies are local on every peer (each player sees their own hits); weapons, pickups and
players are networked as on any map. Pair it with the "Weapon Range" rules (no bots, no score,
ammo refills), or any other rules.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
LEVEL = "scenes/levels/range.tscn"
ARENA = "scenes/main/arena_range.tscn"

EXT_MATS = {
    "floor": ("res://resources/materials/prototype/mat_grid_dark_1m.tres", "mat_floor"),
    "lane": ("res://resources/materials/prototype/mat_concrete_dark.tres", "mat_lane"),
    "wall": ("res://resources/materials/prototype/mat_scifi_panel.tres", "mat_wall"),
    "berm": ("res://resources/materials/prototype/mat_concrete_dark.tres", "mat_berm"),
    "board": ("res://resources/materials/prototype/mat_grid_light_1m.tres", "mat_board"),
    "pit": ("res://resources/materials/prototype/mat_metal_deck.tres", "mat_pit"),
    "pad": ("res://resources/materials/prototype/mat_grid_orange_1m.tres", "mat_pad"),
    "cover": ("res://resources/materials/prototype/mat_hazard_orange_dark.tres", "mat_cover"),
    "rack": ("res://resources/materials/prototype/mat_scifi_trim.tres", "mat_rack"),
    "line": ("res://resources/materials/prototype/mat_hazard_yellow_black.tres", "mat_line"),
}
RACK_Z = 9.5
NOE_RACK_Z = 4.5
WEAPONS = [  # (node, scene file under scenes/weapons, rack x, rack z)
    ("StandardIssueRifle", "standard_issue_rifle", -12.0, RACK_Z),
    ("ServicePistol", "service_pistol", -8.0, RACK_Z),
    ("MarksmanCarbine", "marksman_carbine", -4.0, RACK_Z),
    ("CombatShotgun", "combat_shotgun", 0.0, RACK_Z),
    ("DirectedEnergyRifle", "directed_energy_rifle", 4.0, RACK_Z),
    ("Longsword", "longsword", 8.0, RACK_Z),
    ("GravityHammer", "gravity_hammer", 12.0, RACK_Z),
    ("Tufek", "new_ottoman/tufek", -12.0, NOE_RACK_Z),
    ("LongRifle", "new_ottoman/long_rifle", -8.0, NOE_RACK_Z),
    ("GlaiveRifle", "new_ottoman/glaive_rifle", -4.0, NOE_RACK_Z),
    ("RaiderCarbine", "new_ottoman/raider_carbine", 0.0, NOE_RACK_Z),
    ("HumbaraLauncher", "new_ottoman/humbara_launcher", 4.0, NOE_RACK_Z),
    ("Kilij", "new_ottoman/kilij", 8.0, NOE_RACK_Z),
    ("Yatagan", "new_ottoman/yatagan", 12.0, NOE_RACK_Z),
]


def f(x):
    s = "%.4g" % x
    return "0" if s in ("-0", "0") else s


def xf(pos, yaw180=False):
    b = "-1, 0, 0, 0, 1, 0, 0, 0, -1" if yaw180 else "1, 0, 0, 0, 1, 0, 0, 0, 1"
    return "Transform3D(%s, %s, %s, %s)" % (b, f(pos[0]), f(pos[1]), f(pos[2]))


class Level:
    def __init__(self):
        self.subs = []
        self.nodes = []
        self.shapes = {}

    def box(self, name, center, size, mat, parent="Geometry"):
        key = "%s_%s_%s" % tuple(f(v) for v in size)
        if key not in self.shapes:
            sid = "Box_%d" % len(self.shapes)
            self.shapes[key] = sid
            self.subs.append('[sub_resource type="BoxShape3D" id="Shape_%s"]\nsize = Vector3(%s, %s, %s)'
                             % (sid, f(size[0]), f(size[1]), f(size[2])))
            self.subs.append('[sub_resource type="BoxMesh" id="Mesh_%s"]\nsize = Vector3(%s, %s, %s)'
                             % (sid, f(size[0]), f(size[1]), f(size[2])))
        sid = self.shapes[key]
        mat_id = EXT_MATS[mat][1]
        self.nodes += ['[node name="%s" type="StaticBody3D" parent="%s"]' % (name, parent),
                       "transform = " + xf(center), "",
                       '[node name="Mesh" type="MeshInstance3D" parent="%s/%s"]' % (parent, name),
                       'mesh = SubResource("Mesh_%s")' % sid,
                       'surface_material_override/0 = ExtResource("%s")' % mat_id, "",
                       '[node name="Shape" type="CollisionShape3D" parent="%s/%s"]' % (parent, name),
                       'shape = SubResource("Shape_%s")' % sid, ""]


def build_level():
    L = Level()
    # Ground: armory + lane + side areas, one slab (top at y=0.0).
    L.box("Ground", (0, -0.5, -55), (84, 1, 150), "floor")
    # Overlays are elevated slightly so bottom faces do not touch or fight with Ground y=0.0.
    L.box("LaneFloor", (0, 0.02, -62), (28, 0.03, 124), "lane")
    L.box("FiringLine", (0, 0.045, 0), (28, 0.015, 0.3), "line")
    # Perimeter.
    for name, c, s in (("WallWest", (-42, 4, -54.75), (1, 8, 148.5)), ("WallEast", (42, 4, -54.75), (1, 8, 148.5)),
                       ("WallSouth", (0, 4, 19.5), (83, 8, 1))):
        L.box(name, c, s, "wall")
    L.box("Berm", (0, 5, -132), (84, 10, 6), "berm")
    # Lane sides (waist high) so the side areas don't catch lane fire.
    L.box("LaneRailWest", (-14.5, 0.6, -62), (1, 1.2, 124), "wall")
    L.box("LaneRailEast", (14.5, 0.6, -62), (1, 1.2, 124), "wall")
    for d in (10, 25, 50, 75, 100):
        L.box("Board%dm" % d, (-12.5, 1.2, -d), (2.4, 1.2, 0.2), "board")
    # Armory racks: the player's weapons, and the New Ottoman ones in front.
    L.box("Rack", (0, 0.45, RACK_Z), (30, 0.9, 1.2), "rack")
    L.box("RackNewOttoman", (0, 0.45, NOE_RACK_Z), (28, 0.9, 1.2), "rack")
    # Melee pit.
    L.box("PitFloor", (28, 0.02, -13), (16, 0.03, 18), "pit")
    for name, c, s in (("PitWallN", (28, 0.5, -22.5), (16, 1, 0.6)), ("PitWallE", (36.3, 0.5, -13), (0.6, 1, 18)),
                       ("PitWallWS", (19.7, 0.5, -18), (0.6, 1, 9))):
        L.box(name, c, s, "wall")
    # Blast pad: a cluster spot with half cover (splash behind cover, hammer radius).
    L.box("PadFloor", (-28, 0.02, -19), (16, 0.03, 22), "pad")
    L.box("PadCoverA", (-31, 0.6, -14), (3, 1.2, 0.6), "cover")
    L.box("PadCoverB", (-25, 0.9, -24), (0.6, 1.8, 3), "cover")
    
    ext_lines = []
    for path, eid in EXT_MATS.values():
        ext_lines.append('[ext_resource type="Material" path="%s" id="%s"]' % (path, eid))
    ext_lines.append('[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="1_kill"]')
    
    out = ["[gd_scene load_steps=%d format=3]" % (len(L.subs) + len(ext_lines) + 1), ""]
    out += ext_lines
    out += ["", "; GENERATED by tools/range/build_range.py - edit the script, not this file.", ""]
    for sub in L.subs:
        out += [sub, ""]
    out += ['[sub_resource type="BoxShape3D" id="Shape_Kill"]', "size = Vector3(300, 2, 300)", ""]
    out += ['[node name="Range" type="Node3D"]', "", '[node name="Geometry" type="Node3D" parent="."]', ""]
    out += L.nodes
    out += ['[node name="KillVolume" type="Area3D" parent="."]', "transform = " + xf((0, -8, 0)),
            "collision_layer = 16", "collision_mask = 6", "monitorable = false", 'script = ExtResource("1_kill")', "",
            '[node name="Shape" type="CollisionShape3D" parent="KillVolume"]', 'shape = SubResource("Shape_Kill")', "",
            '[node name="Spawns" type="Node3D" parent="."]', ""]
    # Free-for-all spawns along the armory, facing down range; Red / Blue halves for team rules.
    for i in range(8):
        x = -14 + i * 4
        for prefix in ("SPAWN_FFA", "SPAWN_Red" if x < 0 else "SPAWN_Blue"):
            out += ['[node name="%s_%d" type="Marker3D" parent="Spawns"]' % (prefix, i), "transform = " + xf((x, 0.05, 12)), ""]
    write(LEVEL, out)



def build_arena():
    ext = ['[ext_resource type="PackedScene" path="res://scenes/levels/range.tscn" id="1_level"]',
           '[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="2_player"]',
           '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="3_pickup"]',
           '[ext_resource type="PackedScene" path="res://scenes/pickups/ammo_crate.tscn" id="4_crate"]',
           '[ext_resource type="PackedScene" path="res://scenes/ai/target_dummy.tscn" id="5_dummy"]',
           '[ext_resource type="PackedScene" path="res://scenes/ai/moving_dummy.tscn" id="6_moving"]',
           '[ext_resource type="Environment" path="res://resources/environments/outdoor_environment.tres" id="7_env"]',
           '[ext_resource type="PackedScene" path="res://scenes/ai/bot.tscn" id="8_bot"]',
           '[ext_resource type="Script" path="res://scripts/ai/arena_events.gd" id="9_events"]',
           '[ext_resource type="Script" path="res://scripts/ai/arena_navigation.gd" id="10_nav"]',
           '[ext_resource type="Script" path="res://scripts/net/net_match.gd" id="11_net"]',
           '[ext_resource type="Script" path="res://scripts/ai/spawn_manager.gd" id="12_spawns"]',
           '[ext_resource type="Resource" path="res://resources/ai/bot_difficulty_normal.tres" id="13_diff"]']
    for i, (_, scene, _, _) in enumerate(WEAPONS):
        ext.append('[ext_resource type="PackedScene" path="res://scenes/weapons/%s.tscn" id="w%d"]' % (scene, i))
    out = ["[gd_scene load_steps=%d format=3]" % (len(ext) + 1), ""] + ext + [""]
    out += ["; GENERATED by tools/range/build_range.py - the Weapon Range (Bot Arena / LAN).",
            '[node name="ArenaRange" type="Node3D"]', "",
            '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("7_env")', "",
            '[node name="Sun" type="DirectionalLight3D" parent="."]',
            "transform = Transform3D(0.707107, 0.40558, -0.579228, 0, 0.819152, 0.573576, 0.707107, -0.40558, 0.579228, 0, 40, 0)",
            "light_color = Color(1, 0.94, 0.85, 1)", "light_energy = 1.2", "shadow_enabled = true",
            "shadow_bias = 0.04", "shadow_normal_bias = 2.0", "directional_shadow_mode = 2",
            "directional_shadow_split_1 = 0.07", "directional_shadow_split_2 = 0.2", "directional_shadow_split_3 = 0.5",
            "directional_shadow_blend_splits = true", "directional_shadow_fade_start = 0.85",
            "directional_shadow_max_distance = 160.0", "light_bake_mode = 0", "",
            '[node name="ArenaEvents" type="Node" parent="."]', 'script = ExtResource("9_events")', "",
            '[node name="Range" parent="." instance=ExtResource("1_level")]', "",
            '[node name="Player" parent="." instance=ExtResource("2_player")]', "transform = " + xf((0, 0.05, 12)), ""]
    for i, (node, _, x, z) in enumerate(WEAPONS):
        out += ['[node name="%s_Rack" parent="." instance=ExtResource("3_pickup")]' % node,
                "transform = " + xf((x, 0.9, z)), 'weapon_scene = ExtResource("w%d")' % i, "respawn_delay = 3.0", ""]
    for name, pos in (("AmmoCrateWest", (-16, 0, 6)), ("AmmoCrateEast", (16, 0, 6))):
        out += ['[node name="%s" parent="." instance=ExtResource("4_crate")]' % name, "transform = " + xf(pos),
                "respawn_delay = 3.0", ""]
    # Static dummies face the firing line (+Z).
    for d in (10, 25, 50, 75, 100):
        out += ['[node name="Dummy%dm" parent="." instance=ExtResource("5_dummy")]' % d,
                "transform = " + xf((-6, 0, -d), True), "",
                '[node name="DummyHead%dm" parent="." instance=ExtResource("5_dummy")]' % d,
                "transform = " + xf((6, 0, -d), True), ""]
    for name, x, z, pattern, extra in (
            ("MovingWalk15m", 0, -15, 1, ["strafe_speed = 3.0", "strafe_duration = 1.0", "strafe_jitter = 0.3"]),
            ("MovingADAD35m", 0, -35, 1, ["strafe_speed = 7.5", "strafe_duration = 0.55", "strafe_jitter = 0.35"]),
            ("MovingSpartan60m", 0, -60, 2, [])):
        out += ['[node name="%s" parent="." instance=ExtResource("6_moving")]' % name, "transform = " + xf((x, 0, z), True),
                "pattern = %d" % pattern, "move_seed = %d" % (1000 - z),
                "bounds_min = Vector2(%s, %s)" % (f(x - 4), f(z - 0.5)), "bounds_max = Vector2(%s, %s)" % (f(x + 4), f(z + 0.5))]
        out += extra + [""]
    # Melee pit: two static, one strafing, one Spartan (the sword's lunge and hammer's swing).
    for name, pos in (("PitDummyA", (25, 0, -8)), ("PitDummyB", (31, 0, -12))):
        out += ['[node name="%s" parent="." instance=ExtResource("5_dummy")]' % name, "transform = " + xf(pos, True), ""]
    out += ['[node name="PitStrafer" parent="." instance=ExtResource("6_moving")]', "transform = " + xf((28, 0, -17), True),
            "pattern = 1", "move_seed = 2001", "bounds_min = Vector2(23, -17.5)", "bounds_max = Vector2(33, -16.5)",
            "strafe_speed = 7.5", "strafe_duration = 0.6", "strafe_jitter = 0.35", "",
            '[node name="PitSpartan" parent="." instance=ExtResource("6_moving")]', "transform = " + xf((30, 0, -20), True),
            "pattern = 2", "move_seed = 2002", "bounds_min = Vector2(22, -21)", "bounds_max = Vector2(35, -19)", ""]
    # Blast pad cluster (one behind each cover piece).
    for i, pos in enumerate(((-28, 0, -19), (-26.5, 0, -18), (-29.5, 0, -17.5), (-31, 0, -12.5), (-23.5, 0, -24))):
        out += ['[node name="PadDummy%d" parent="." instance=ExtResource("5_dummy")]' % i, "transform = " + xf(pos, True), ""]
    out += ['[node name="Navigation" type="NavigationRegion3D" parent="."]', 'script = ExtResource("10_nav")',
            'geometry_root = NodePath("../Range")', "",
            '[node name="NavPoints" type="Node3D" parent="."]', ""]
    for name, pos in (("Armory", (0, 0.05, 6)), ("Lane25", (0, 0.05, -25)), ("Lane60", (0, 0.05, -60)),
                      ("MeleePit", (28, 0.05, -13)), ("BlastPad", (-28, 0.05, -19))):
        out += ['[node name="%s" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]' % name,
                "transform = " + xf(pos), ""]
    out += ['[node name="NetMatch" type="Node" parent="."]', 'script = ExtResource("11_net")', "",
            '[node name="SpawnManager" type="Node" parent="."]', 'script = ExtResource("12_spawns")',
            'bot_scene = ExtResource("8_bot")', "bot_count = 0", 'difficulty = ExtResource("13_diff")',
            'spawn_roots = Array[NodePath]([NodePath("../Range/Spawns")])', ""]
    write(ARENA, out)


def write(rel, lines):
    path = os.path.join(REPO, rel)
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
    print("wrote", rel)


if __name__ == "__main__":
    build_level()
    build_arena()
