"""Build the Headlong (Halo 2, 2004) greybox (.glb + .blend) and preview renders with headless Blender.

Usage (from the repo root):
  blender -b --factory-startup --python tools/headlong/build_headlong.py -- \
      [--glb assets/models/environment/headlong_greybox.glb] [--blend tools/headlong/headlong_greybox.blend] \
      [--previews tools/headlong/previews] [--no-render]

ALL geometry is ESTIMATED: traced from the MCC Headlong loading-screen map and the Breakneck (Reach
remake) overhead, at 1 MCC-map pixel ~= 0.25 m. See headlong_spec.md for sources and confidence.

All data below is authored in GODOT space: metres, +Y up, +X east, -Z north (north = top of the MCC
map; the sea is south). g2b() converts to Blender space; the glTF exporter (export_yup) converts
back, so the .glb lands in Godot exactly as authored here.

Naming for the Godot importer:
  *-col      mesh + StaticBody3D with trimesh collision (World layer 1)
  no suffix  visual only (sea, lift / teleporter pads are -col too, so you can stand on them)
  Empties    SPAWN_*, WPN_*, PWR_*, FLAG_*, LIFT_*, TELE_*, CALLOUT_* become Node3D markers;
             headlong_greybox.tscn turns them into the real Spawns / pickups / lifts.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def _arg(name, default):
    return argv[argv.index(name) + 1] if name in argv else default


GLB = _arg("--glb", "assets/models/environment/headlong_greybox.glb")
BLEND = _arg("--blend", "tools/headlong/headlong_greybox.blend")
PREVIEWS = _arg("--previews", "tools/headlong/previews")
RENDER = "--no-render" not in argv and PREVIEWS != ""

# Player reference (scripts/player/player.gd): 2.1 m body, jump_height 2.2, stand_speed 7.5,
# gravity 22 -> ~0.89 s airtime, ~6.7 m flat running jump. floor_max_angle 50 deg, step 0.35.
STREET = 0.0     # road / plaza level
PIT = -3.0       # Construction Pit floor
SLAB = 3.5       # street slabs reach down to y -3.5, so their faces are the pit walls
WALL_T = 0.5
OOB_H = 25.0     # out-of-bounds boundary height


def g2b(v):
    return Vector((v[0], -v[2], v[1]))


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    h = h.lstrip("#")
    return tuple(srgb_to_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


# ---- reset scene -------------------------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---- materials: flat matte, one per role -------------------------------------------------
MATS = {
    "ground": "#8c8c8c",   # street / plaza
    "pit": "#8a7556",      # construction pit dirt
    "floor": "#b4b4b4",    # building floors and roofs
    "wall": "#6c6f73",
    "ramp": "#c0843a",     # anything sloped you can walk
    "catwalk": "#d1a420",  # beams, catwalks, crane platform (construction yellow)
    "road": "#4c4f55",     # elevated road deck
    "cover": "#455a64",    # debris, barriers, vehicles
    "oob": "#34363a",      # boundary / out-of-bounds mass
    "lift": "#2e86c1",
    "tele": "#27ae60",
    "statue": "#7b5e57",
    "sea": "#1f4e79",
}
_mat = {}
for key, hx in MATS.items():
    m = bpy.data.materials.new("mat_" + key)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = hexcol(hx)
    bsdf.inputs["Roughness"].default_value = 0.9
    m.diffuse_color = hexcol(hx)
    _mat[key] = m

_collections = {}


def coll(name):
    if name not in _collections:
        c = bpy.data.collections.new(name)
        scene.collection.children.link(c)
        _collections[name] = c
    return _collections[name]


_names = set()


def _unique(name):
    base, i = name, 2
    while name in _names:
        name = f"{base}_{i}"
        i += 1
    _names.add(name)
    return name


def _cube_mesh(name, size):
    """Axis-aligned box mesh centred on its origin, size given in GODOT axes (x, y, z)."""
    sx, sy, sz = size
    hx, hy, hz = sx / 2, sz / 2, sy / 2  # blender: x, y(=-godot z), z(=godot y)
    verts = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
             (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return _mesh(name, verts, faces)


def _mesh(name, verts, faces):
    """Closed mesh with outward normals (Godot trimesh collision is one-sided)."""
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()
    return me


def strip(name, pts, width, thick, mat, group, offset=0.0, lift=0.0):
    """One solid ribbon along a polyline of TOP-surface centre points (Godot x, y, z), with
    mitred joints so bends have no gaps. offset shifts it sideways (+ = right of travel),
    lift raises it (rails). Returns the steepest segment slope in degrees."""
    P = [Vector(p) for p in pts]
    n = len(P)
    sides = []
    for i in range(n):
        dirs = []
        if i > 0:
            dirs.append((P[i] - P[i - 1]).xz.normalized())  # Vector.xz -> (x, z)
        if i < n - 1:
            dirs.append((P[i + 1] - P[i]).xz.normalized())
        per = [Vector((-d.y, d.x)) for d in dirs]  # right-hand perpendicular in (x, z)
        m = (per[0] + per[-1]).normalized()
        sides.append(m / max(m.dot(per[0]), 0.5))
    verts = []
    for i in range(n):
        s = sides[i]
        for k, off in enumerate((offset - width / 2, offset + width / 2)):
            x, z = P[i].x + s.x * off, P[i].z + s.y * off
            top = P[i].y + lift
            verts.append(tuple(g2b((x, top, z))))
            verts.append(tuple(g2b((x, top - thick, z))))
    # per station: 0 = left top, 1 = left bottom, 2 = right top, 3 = right bottom
    faces = []
    for i in range(n - 1):
        a, b = 4 * i, 4 * (i + 1)
        faces += [(a, a + 2, b + 2, b), (a + 1, b + 1, b + 3, a + 3),
                  (a, b, b + 1, a + 1), (a + 2, a + 3, b + 3, b + 2)]
    e = 4 * (n - 1)
    faces += [(0, 1, 3, 2), (e, e + 2, e + 3, e + 1)]
    full = _unique(name) + "-col"
    ob = bpy.data.objects.new(full, _mesh(full, verts, faces))
    ob.data.materials.append(_mat[mat])
    ob.color = _mat[mat].diffuse_color
    coll(group).objects.link(ob)
    return max(abs(math.degrees(math.atan2(P[i + 1].y - P[i].y, (P[i + 1] - P[i]).xz.length)))
               for i in range(n - 1))


def box(name, center, size, mat, group, yaw=0.0, pitch=0.0, collide=True):
    """center/size in Godot space. yaw = degrees about +Y (counter-clockwise seen from above),
    pitch = degrees about the box's local X after yaw (positive raises its -Z end)."""
    full = _unique(name) + ("-col" if collide else "")
    ob = bpy.data.objects.new(full, _cube_mesh(full, size))
    ob.data.materials.append(_mat[mat])
    ob.color = _mat[mat].diffuse_color
    # Godot: R = Ry(yaw) * Rx(pitch). Godot->Blender axes: Godot Y = Blender Z, Godot X = Blender X.
    rot = Matrix.Rotation(math.radians(yaw), 4, "Z") @ Matrix.Rotation(math.radians(pitch), 4, "X")
    ob.matrix_world = Matrix.Translation(g2b(center)) @ rot
    coll(group).objects.link(ob)
    return ob


def slab(name, x0, x1, z0, z1, top, thick, mat, group):
    box(name, ((x0 + x1) / 2, top - thick / 2, (z0 + z1) / 2), (x1 - x0, thick, z1 - z0), mat, group)


def floor_holes(name, x0, x1, z0, z1, top, holes, mat="floor", group="Buildings", thick=0.4):
    """Floor slab with rectangular holes (stairwells). Splits into strips along X then Z."""
    xs = sorted({x0, x1, *[h[0] for h in holes], *[h[1] for h in holes]})
    zs = sorted({z0, z1, *[h[2] for h in holes], *[h[3] for h in holes]})
    cells = []
    for i in range(len(xs) - 1):
        for j in range(len(zs) - 1):
            cx, cz = (xs[i] + xs[i + 1]) / 2, (zs[j] + zs[j + 1]) / 2
            if not (x0 <= cx <= x1 and z0 <= cz <= z1):
                continue
            if any(h[0] < cx < h[1] and h[2] < cz < h[3] for h in holes):
                continue
            cells.append([xs[i], xs[i + 1], zs[j], zs[j + 1]])
    # merge cells in the same X column that touch in Z (fewer objects)
    merged = []
    for c in sorted(cells):
        if merged and merged[-1][0] == c[0] and merged[-1][1] == c[1] and abs(merged[-1][3] - c[2]) < 1e-6:
            merged[-1][3] = c[3]
        else:
            merged.append(c)
    for k, (a, b, c, d) in enumerate(merged):
        slab(f"{name}_{k}", a, b, c, d, top, thick, mat, group)


def wall(name, axis, fixed, a0, a1, y0, y1, openings=(), group="Buildings", mat="wall", t=WALL_T):
    """Straight wall. axis 'x': runs along X at z=fixed; 'z': runs along Z at x=fixed.
    openings: (a, b, oy0, oy1) door/window spans along the wall."""
    cuts = sorted({a0, a1, *[o[0] for o in openings], *[o[1] for o in openings]})
    k = 0
    for i in range(len(cuts) - 1):
        s0, s1 = cuts[i], cuts[i + 1]
        if s1 <= a0 or s0 >= a1:
            continue
        mid = (s0 + s1) / 2
        o = next((o for o in openings if o[0] < mid < o[1]), None)
        spans = [(y0, y1)] if o is None else [(y0, o[2]), (o[3], y1)]
        for b0, b1 in spans:
            if b1 - b0 < 0.05:
                continue
            L = s1 - s0
            if axis == "x":
                c, s = (mid, (b0 + b1) / 2, fixed), (L, b1 - b0, t)
            else:
                c, s = (fixed, (b0 + b1) / 2, mid), (t, b1 - b0, L)
            box(f"{name}_{k}", c, s, mat, group)
            k += 1


def ramp(name, p0, p1, width, mat="ramp", group="Ramps", thick=0.4, rails=0.0):
    """Sloped slab whose TOP surface runs from p0 to p1 (Godot x, y, z of the centreline).
    Slightly over-length so the ends tuck into the floors they join. rails > 0 adds side rails."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    horiz = math.hypot(d.x, d.z)
    length = d.length + 0.3
    yaw = math.degrees(math.atan2(-d.x, -d.z))           # box local -Z points p0 -> p1
    pitch = math.degrees(math.atan2(d.y, horiz))         # raise the -Z (p1) end
    up = Vector((0, 1, 0))
    fwd = d.normalized()
    side = fwd.cross(up).normalized()
    normal = side.cross(fwd).normalized()
    mid = (a + b) / 2 - normal * (thick / 2)
    box(name, tuple(mid), (width, thick, length), mat, group, yaw=yaw, pitch=pitch)
    if rails:
        for sgn, tag in ((1, "R"), (-1, "L")):
            c = (a + b) / 2 + side * sgn * (width / 2 - 0.15) + normal * (rails / 2)
            box(f"{name}_Rail{tag}", tuple(c), (0.3, rails, length), "wall", group, yaw=yaw, pitch=pitch)
    return math.degrees(math.atan2(d.y, horiz))


def parapet(name, x0, z0, x1, z1, top, h=1.05, group="Buildings"):
    """1.05 m rail/parapet standing on a floor whose top is `top`, along a straight line."""
    d = Vector((x1 - x0, 0, z1 - z0))
    yaw = math.degrees(math.atan2(-d.x, -d.z))
    box(name, ((x0 + x1) / 2, top + h / 2, (z0 + z1) / 2), (0.3, h, d.length), "wall", group, yaw=yaw)


def marker(name, pos, group="Markers", yaw=0.0):
    ob = bpy.data.objects.new(_unique(name), None)
    ob.empty_display_type = "ARROWS"
    ob.empty_display_size = 1.0
    ob.matrix_world = Matrix.Translation(g2b(pos)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    coll(group).objects.link(ob)
    return ob


SLOPES = {}

# =========================================================================================
# 1. GROUND  (street slabs top 0, 3.5 thick -> their faces wall in the pit)
# =========================================================================================
slab("Pit_Floor", -46.25, 8.0, -45.0, 10.0, PIT, 0.5, "pit", "Ground")
slab("North_Lot", -46.25, 8.0, -55.0, -45.0, STREET, SLAB, "ground", "Ground")
slab("East_Lane", 8.0, 57.5, -55.0, 3.75, STREET, SLAB, "ground", "Ground")
slab("Central_Plaza", -17.5, 8.0, 10.0, 38.75, STREET, SLAB, "ground", "Ground")
slab("SE_Plaza", 8.0, 57.5, 3.75, 38.75, STREET, SLAB, "ground", "Ground")
slab("South_Street", -17.5, 57.5, 38.75, 55.0, STREET, SLAB, "ground", "Ground")
slab("Alley_Ground", -57.5, -46.25, -28.75, 12.5, STREET, SLAB, "ground", "Ground")
slab("Corner_Ground", -46.25, -17.5, 10.0, 31.25, STREET, SLAB, "ground", "Ground")

# Pit exits [E]: north vehicle ramp, south-east vehicle ramp (the race-track exit), pit stairs,
# Alley stairs up to the west building.
SLOPES["Pit_NorthRamp"] = ramp("Pit_NorthRamp", (2.0, PIT, -36.0), (2.0, STREET, -45.0), 11.0)
SLOPES["Pit_SERamp"] = ramp("Pit_SERamp", (-3.0, PIT, -2.0), (-3.0, STREET, 10.0), 10.0)
SLOPES["Pit_Stairs"] = ramp("Pit_Stairs", (-15.0, PIT, 3.0), (-15.0, STREET, 10.0), 3.0)
SLOPES["Alley_Stairs"] = ramp("Alley_Stairs", (-40.0, PIT, 1.5), (-46.25, STREET, 1.5), 3.0)

# =========================================================================================
# 2. BOUNDARY  (tall out-of-bounds masses, sea wall)
# =========================================================================================
slab("OOB_NW_Block", -58.75, -46.25, -55.0, -28.75, OOB_H, OOB_H + 3.5, "oob", "Boundary")
slab("OOB_North", -46.25, 17.5, -56.5, -55.0, OOB_H, OOB_H + 3.5, "oob", "Boundary")
box("OOB_NE_Diagonal", (37.6, OOB_H / 2 - 1.75, -35.9), (2.0, OOB_H + 3.5, 56.5), "oob", "Boundary", yaw=45.5)
slab("OOB_East", 57.5, 59.0, -17.0, 55.6, OOB_H, OOB_H + 3.5, "oob", "Boundary")
slab("OOB_West", -59.5, -57.5, -28.75, 12.5, OOB_H, OOB_H + 3.5, "oob", "Boundary")
slab("OOB_SW_Block", -46.25, -17.5, 31.25, 55.6, OOB_H, OOB_H + 3.5, "oob", "Boundary")
slab("OOB_SW_Corner", -59.5, -46.25, 12.5, 55.6, OOB_H, OOB_H + 3.5, "oob", "Boundary")
slab("SeaWall", -17.5, 57.5, 55.0, 55.6, 1.2, 1.2 + SLAB, "wall", "Boundary")
box("Sea", (20.0, -4.0, 85.0), (160.0, 0.1, 60.0), "sea", "Boundary", collide=False)

# =========================================================================================
# 3. BUILDING SITE (half-built frame in the Construction Pit) - floors y 1 / 5 / roof 9
#    footprint x -39.4..-19.4, z -30.6..-6.25
# =========================================================================================
BX0, BX1, BZ0, BZ1 = -39.4, -19.4, -30.6, -6.25
slab("Site_Plinth", BX0, BX1, BZ0, BZ1, 1.0, 4.0, "floor", "BuildingSite")
floor_holes("Site_F2", BX0, BX1, BZ0, BZ1, 5.0, [(BX0, BX0 + 3.0, -20.0, BZ1)], group="BuildingSite")
floor_holes("Site_Roof", BX0, BX1, BZ0, BZ1, 9.0, [(BX1 - 3.0, BX1, -20.0, BZ1)], group="BuildingSite")
# columns at corners, N/S mid-points and centre (mid-W / mid-E would stand in the stairwells)
for i, (x, z) in enumerate([(x, z) for x in (BX0 + 0.4, -29.4, BX1 - 0.4) for z in (BZ0 + 0.4, BZ1 - 0.4)]
                           + [(-29.4, -18.4)]):
    box(f"Site_Column_{i}", (x, 5.0, z), (0.8, 8.0, 0.8), "wall", "BuildingSite")
SLOPES["Site_Stairs_Pit"] = ramp("Site_Stairs_Pit", (-29.4, PIT, 0.75), (-29.4, 1.0, BZ1), 3.0, group="BuildingSite")
SLOPES["Site_Stairs_F1F2"] = ramp("Site_Stairs_F1F2", (BX0 + 1.5, 1.0, -13.0), (BX0 + 1.5, 5.0, -20.0), 3.0, group="BuildingSite")
SLOPES["Site_Stairs_F2Roof"] = ramp("Site_Stairs_F2Roof", (BX1 - 1.5, 5.0, -13.0), (BX1 - 1.5, 9.0, -20.0), 3.0, group="BuildingSite")
# half-height partitions on F1 / F2 for cover (partly built interior)
for y, tag in ((1.0, "F1"), (5.0, "F2")):
    box(f"Site_{tag}_Partition_A", (-29.4, y + 0.6, -24.0), (8.0, 1.2, 0.4), "cover", "BuildingSite")
    box(f"Site_{tag}_Partition_B", (-25.0, y + 0.6, -12.0), (0.4, 1.2, 6.0), "cover", "BuildingSite")
parapet("Site_Roof_Rail_N", BX0, BZ0, BX1, BZ0, 9.0, group="BuildingSite")
parapet("Site_Roof_Rail_W", BX0, BZ0, BX0, BZ1, 9.0, group="BuildingSite")
parapet("Site_Roof_Rail_S", BX0, BZ1, BX1 - 3.0, BZ1, 9.0, group="BuildingSite")
parapet("Site_Roof_Rail_E", BX1, BZ0, BX1, -20.0, 9.0, group="BuildingSite")

# West catwalk: Alley 2F (y 5) -> Building Site F2
slab("Catwalk_West", -46.25, BX0, -25.25, -22.75, 5.0, 0.3, "catwalk", "Catwalks")
# Steel Beam: Building Site F2 east edge -> Crane Platform (y 5 -> 7), 1.2 m wide, no rails
SLOPES["Steel_Beam"] = ramp("Steel_Beam", (BX1, 5.0, -10.0), (10.6, 7.0, -21.0), 1.2, mat="catwalk", group="Catwalks", thick=0.3)

# Crane Platform: suspended container over the East Lane, top y 7 (Directed Energy Rifle)
CRANE = (16.25, 7.0, -21.9)
box("Crane_Platform", (CRANE[0], CRANE[1] - 0.5, CRANE[2]), (12.0, 1.0, 12.0), "catwalk", "Catwalks", yaw=-20.0)
box("Crane_Cable", (CRANE[0], 18.0, CRANE[2]), (0.3, 21.0, 0.3), "wall", "Catwalks")
box("Crane_Mast", (24.0, 12.0, -44.0), (2.0, 24.0, 2.0), "oob", "Catwalks")

# =========================================================================================
# 4. GATE BRIDGE / ELEVATED ROAD - half-built road, ground at the south-east, ends 8 m up
#    over the plaza at its north end (vehicle launch / infantry high ground)
# =========================================================================================
ROAD = [(10.0, 8.0, -11.25), (10.0, 8.0, 3.0), (11.5, 7.0, 15.0), (16.25, 5.5, 25.0),
        (26.25, 3.0, 33.5), (38.75, 0.6, 38.5), (46.0, 0.0, 41.0)]
SLOPES["GateBridge_Deck"] = strip("GateBridge_Deck", ROAD, 7.5, 0.6, "road", "GateBridge")
for sgn, tag in ((-1, "L"), (1, "R")):
    strip(f"GateBridge_Rail{tag}", ROAD, 0.3, 0.9, "wall", "GateBridge", offset=sgn * 3.6, lift=0.9)
for i, (x, y, z) in enumerate(ROAD[1:5]):
    box(f"GateBridge_Pillar_{i}", (x, (y - 0.6) / 2, z), (1.5, y - 0.6, 1.5), "wall", "GateBridge")
# no end barrier: the road just stops (Warthog launch; infantry jump to/from the Crane Platform)

# =========================================================================================
# 5. EAST BUILDING ("Hotel" in Breakneck) - CTF base, top + bottom routes, lift in atrium
#    x 18.75..48.75, z 3.75..22.5; 2F y 5, roof y 10
# =========================================================================================
HX0, HX1, HZ0, HZ1 = 18.75, 48.75, 3.75, 22.5
IX0, IX1, IZ0, IZ1 = HX0 + WALL_T, HX1 - WALL_T, HZ0 + WALL_T, HZ1 - WALL_T
ATRIUM = (28.0, 40.0, 9.0, 17.0)
floor_holes("Hotel_2F", IX0, IX1, IZ0, IZ1, 5.0, [ATRIUM, (IX0, 28.0, IZ0, 7.0)], group="Hotel")
floor_holes("Hotel_Roof", HX0, HX1, HZ0, HZ1, 10.0, [(40.0, IX1, 19.5, IZ1)], group="Hotel")
DOOR = 3.0
WIN = (6.2, 8.6)
wall("Hotel_W", "z", HX0 + WALL_T / 2, HZ0, HZ1, 0.0, 10.0,
     [(11.0, 15.0, 0.0, DOOR), (7.5, 10.0, *WIN), (16.0, 20.5, *WIN)], group="Hotel")
wall("Hotel_E", "z", HX1 - WALL_T / 2, HZ0, HZ1, 0.0, 10.0,
     [(11.0, 15.0, 0.0, DOOR), (6.0, 10.0, *WIN), (16.5, 19.0, 5.0, 8.0)], group="Hotel")
wall("Hotel_N", "x", HZ0 + WALL_T / 2, HX0, HX1, 0.0, 10.0,
     [(31.0, 35.0, 0.0, DOOR), (37.0, 46.0, *WIN)], group="Hotel")
wall("Hotel_S", "x", HZ1 - WALL_T / 2, HX0, HX1, 0.0, 10.0,
     [(31.0, 35.0, 0.0, DOOR), (21.0, 29.0, *WIN), (37.0, 39.0, *WIN)], group="Hotel")
SLOPES["Hotel_Stairs_GF2F"] = ramp("Hotel_Stairs_GF2F", (IX0 + 0.3, 0.0, 5.6), (28.0, 5.0, 5.6), 2.6, group="Hotel")
SLOPES["Hotel_Stairs_2FRoof"] = ramp("Hotel_Stairs_2FRoof", (40.0, 5.0, 20.75), (IX1 - 0.3, 10.0, 20.75), 2.5, group="Hotel")
# exterior "top route": ramp on the east side up to a 2F balcony door
slab("Hotel_Balcony", HX1, HX1 + 3.0, 14.0, 21.0, 5.0, 0.4, "catwalk", "Hotel")
SLOPES["Hotel_ExtRamp"] = ramp("Hotel_ExtRamp", (HX1 + 1.5, 0.0, 0.0), (HX1 + 1.5, 5.0, 14.0), 3.0, group="Hotel")
# north side (z 9) left open: lift riders step off onto the 2F north band there
for x0, z0, x1, z1 in ((ATRIUM[0], ATRIUM[3], ATRIUM[1], ATRIUM[3]), (ATRIUM[1], ATRIUM[2], ATRIUM[1], ATRIUM[3])):
    parapet("Hotel_AtriumRail", x0, z0, x1, z1, 5.0, group="Hotel")
parapet("Hotel_Roof_Rail_N", HX0, HZ0, HX1, HZ0, 10.0, group="Hotel")
parapet("Hotel_Roof_Rail_S", HX0, HZ1, 40.0, HZ1, 10.0, group="Hotel")
parapet("Hotel_Roof_Rail_W", HX0, HZ0, HX0, HZ1, 10.0, group="Hotel")
parapet("Hotel_Roof_Rail_E", HX1, HZ0, HX1, 19.5, 10.0, group="Hotel")
box("Hotel_LiftPad", (34.0, 0.05, 13.0), (3.0, 0.1, 3.0), "lift", "Hotel")
box("Hotel_GF_Cover_A", (24.0, 0.6, 13.0), (1.0, 1.2, 4.0), "cover", "Hotel")
box("Hotel_GF_Cover_B", (44.0, 0.6, 13.0), (1.0, 1.2, 4.0), "cover", "Hotel")

# =========================================================================================
# 6. CORNER BUILDING (south-west) - 3 levels, windows over the pit. 2F y 4.5, roof y 9
#    x -46.25..-17.5, z 11.9..31.25
# =========================================================================================
CX0, CX1, CZ0, CZ1 = -46.25, -17.5, 11.9, 31.25
JX0, JX1, JZ0, JZ1 = CX0 + WALL_T, CX1 - WALL_T, CZ0 + WALL_T, CZ1 - WALL_T
floor_holes("Corner_2F", JX0, JX1, JZ0, JZ1, 4.5, [(JX0, JX0 + 3.0, 21.0, JZ1)], group="CornerBuilding")
floor_holes("Corner_Roof", CX0, CX1, CZ0, CZ1, 9.0, [(JX1 - 3.0, JX1, 22.75, JZ1)], group="CornerBuilding")
wall("Corner_N", "x", CZ0 + WALL_T / 2, CX0, CX1, 0.0, 9.0,
     [(-44.0, -36.0, 5.6, 7.6), (-33.0, -25.0, 5.6, 7.6), (-23.0, -20.0, 0.0, DOOR)], group="CornerBuilding")
wall("Corner_E", "z", CX1 - WALL_T / 2, CZ0, CZ1, 0.0, 9.0,
     [(20.0, 24.0, 0.0, DOOR), (14.0, 18.0, 5.6, 7.6), (26.0, 30.0, 5.6, 7.6)], group="CornerBuilding")
wall("Corner_S", "x", CZ1 - WALL_T / 2, CX0, CX1, 0.0, 9.0, [], group="CornerBuilding")
wall("Corner_W", "z", CX0 + WALL_T / 2, CZ0, CZ1, 0.0, 9.0, [], group="CornerBuilding")
SLOPES["Corner_Stairs_GF2F"] = ramp("Corner_Stairs_GF2F", (JX0 + 1.5, 0.0, 29.5), (JX0 + 1.5, 4.5, 21.0), 3.0, group="CornerBuilding")
SLOPES["Corner_Stairs_2FRoof"] = ramp("Corner_Stairs_2FRoof", (JX1 - 1.5, 4.5, JZ1 - 0.3), (JX1 - 1.5, 9.0, 22.75), 3.0, group="CornerBuilding")
box("Corner_GF_Wall_A", (-32.0, 1.5, 21.5), (0.4, 3.0, 9.0), "wall", "CornerBuilding")
box("Corner_GF_Cover", (-25.0, 0.6, 26.0), (4.0, 1.2, 1.0), "cover", "CornerBuilding")
box("Corner_2F_Wall_A", (-30.0, 6.0, 19.0), (6.0, 3.0, 0.4), "wall", "CornerBuilding")
parapet("Corner_Roof_Rail_N", CX0, CZ0, CX1, CZ0, 9.0, group="CornerBuilding")
parapet("Corner_Roof_Rail_E", CX1, CZ0, CX1, 22.75, 9.0, group="CornerBuilding")
parapet("Corner_Roof_Rail_W", CX0, CZ0, CX0, CZ1, 9.0, group="CornerBuilding")
parapet("Corner_Roof_Rail_S", CX0, CZ1, CX1 - 3.5, CZ1, 9.0, group="CornerBuilding")

# =========================================================================================
# 7. ALLEY (west building strip) - GF y 0, 2F y 5 (west catwalk), ceiling 9, teleporter
#    x -57.5..-46.25, z -28.75..12.5
# =========================================================================================
AX0, AX1, AZ0, AZ1 = -57.5, -46.25, -28.75, 12.5
floor_holes("Alley_2F", AX0 + WALL_T, AX1 - WALL_T, AZ0 + WALL_T, AZ1 - WALL_T, 5.0,
            [(AX0 + WALL_T, AX0 + 3.5, 0.0, 8.0)], group="Alley")
slab("Alley_Ceiling", AX0, AX1, AZ0, AZ1, 9.4, 0.4, "wall", "Alley")
wall("Alley_E", "z", AX1 - WALL_T / 2, AZ0, AZ1, 0.0, 9.0,
     [(-0.5, 3.5, 0.0, DOOR), (-25.5, -22.5, 5.0, 8.0), (-18.0, -8.0, 6.2, 8.2), (-6.0, -2.0, 0.8, 2.2)], group="Alley")
wall("Alley_W", "z", AX0 + WALL_T / 2, AZ0, AZ1, 0.0, 9.0, [], group="Alley")
wall("Alley_N", "x", AZ0 + WALL_T / 2, AX0, AX1, 0.0, 9.0, [], group="Alley")
wall("Alley_S", "x", AZ1 - WALL_T / 2, AX0, AX1, 0.0, 9.0, [], group="Alley")
SLOPES["Alley_Stairs_GF2F"] = ramp("Alley_Stairs_GF2F", (AX0 + 2.0, 0.0, 8.0), (AX0 + 2.0, 5.0, 0.0), 3.0, group="Alley")
box("Alley_TelePad", (-54.5, 0.05, -12.0), (2.5, 0.1, 2.5), "tele", "Alley")
box("Alley_GF_Crates", (-50.0, 0.75, -20.0), (2.0, 1.5, 3.0), "cover", "Alley")

# =========================================================================================
# 8. NORTH BUILDING (single room off the North Lot, teleporter)
# =========================================================================================
NX0, NX1, NZ0, NZ1 = -33.75, -20.0, -55.0, -47.5
slab("North_Roof", NX0, NX1, NZ0, NZ1, 5.4, 0.4, "wall", "NorthBuilding")
wall("North_S", "x", NZ1 - WALL_T / 2, NX0, NX1, 0.0, 5.0, [(-29.0, -25.0, 0.0, DOOR)], group="NorthBuilding")
wall("North_W", "z", NX0 + WALL_T / 2, NZ0, NZ1, 0.0, 5.0, [], group="NorthBuilding")
wall("North_E", "z", NX1 - WALL_T / 2, NZ0, NZ1, 0.0, 5.0, [], group="NorthBuilding")
box("North_TelePad", (-23.75, 0.05, -51.25), (2.5, 0.1, 2.5), "tele", "NorthBuilding")

# =========================================================================================
# 9. STATUE (Seventh Column monument on the sea front) + South Street cover
# =========================================================================================
slab("Statue_Plinth", -1.0, 11.0, 44.0, 54.0, 1.2, 1.2 + 0.5, "floor", "Statue")
SLOPES["Statue_Steps"] = ramp("Statue_Steps", (5.0, 0.0, 41.5), (5.0, 1.2, 44.0), 8.0, group="Statue")
box("Statue_Column", (5.0, 1.2 + 11.0, 50.0), (3.0, 22.0, 3.0), "statue", "Statue")

# =========================================================================================
# 10. COVER (debris piles, barriers, parked vehicles) [E]
# =========================================================================================
COVER = [
    # in the pit
    ("Pit_Barrier_A", (-35.0, PIT + 0.6, 3.75), (4.0, 1.2, 1.0), 0),
    ("Pit_Barrier_B", (-27.0, PIT + 0.6, 3.75), (4.0, 1.2, 1.0), 0),
    ("Pit_Barrier_C", (-19.0, PIT + 0.6, 3.75), (4.0, 1.2, 1.0), 0),
    ("Pit_Debris_N", (-8.0, PIT + 1.0, -32.0), (6.0, 2.0, 4.0), 25),
    ("Pit_Debris_E", (0.0, PIT + 0.8, -18.0), (4.0, 1.6, 6.0), -15),
    ("Pit_Debris_SW", (-42.0, PIT + 0.9, -2.0), (3.0, 1.8, 5.0), 10),
    ("Pit_Debris_Mid", (-12.0, PIT + 0.7, -12.0), (5.0, 1.4, 3.0), 40),
    # plazas and street
    ("Plaza_Truck", (-6.0, 1.5, 28.0), (2.6, 3.0, 7.0), 5),
    ("Plaza_Barrier_A", (2.0, 0.6, 20.0), (4.0, 1.2, 1.0), 20),
    ("Underpass_Crates", (12.0, 0.8, -4.0), (3.0, 1.6, 2.0), 0),
    ("East_Debris", (30.0, 1.0, -12.0), (5.0, 2.0, 4.0), -30),
    ("East_Barrier", (40.0, 0.6, -2.0), (4.0, 1.2, 1.0), 45),
    ("Street_Bus", (-10.0, 1.6, 45.5), (7.5, 3.2, 2.6), 15),
    ("Street_Planter_A", (20.0, 0.6, 51.0), (2.0, 1.2, 2.0), 0),
    ("Street_Planter_B", (28.0, 0.6, 51.0), (2.0, 1.2, 2.0), 0),
    ("Street_Planter_C", (36.0, 0.6, 51.0), (2.0, 1.2, 2.0), 0),
    ("Street_Planter_D", (44.0, 0.6, 51.0), (2.0, 1.2, 2.0), 0),
    ("SE_Debris", (50.0, 1.0, 30.0), (4.0, 2.0, 5.0), 10),
]
for n, c, s, yaw in COVER:
    box(n, c, s, "cover", "Cover", yaw=yaw)

# =========================================================================================
# 11. MARKERS  (y = floor top; the Godot scene lifts pickups/spawns as needed)
# =========================================================================================
# Team spawns: Red = Hotel side (east), Blue = Corner Building side (west) [E]
for i, (p, yaw) in enumerate((((30.0, 0.0, 26.0), 90), ((44.0, 0.0, 26.0), 90), ((54.0, 0.0, 8.0), 90),
                              ((24.0, 5.0, 19.0), 90), ((44.0, 5.0, 7.0), 90), ((36.0, 0.0, -6.0), 135))):
    marker(f"SPAWN_Red_{i}", p, yaw=yaw)
for i, (p, yaw) in enumerate((((-40.0, 0.0, 25.0), -90), ((-24.0, 0.0, 16.0), -90), ((-40.0, 4.5, 16.0), -90),
                              ((-52.0, 0.0, 6.0), -90), ((-52.0, 5.0, -18.0), -90), ((-12.0, 0.0, 34.0), -45))):
    marker(f"SPAWN_Blue_{i}", p, yaw=yaw)
FFA = [(-29.4, 9.0, -27.0), (-29.4, 1.0, -10.0), (-10.0, PIT, -25.0), (-38.0, 0.0, -51.0), (4.0, 0.0, -50.0),
       (20.0, 0.0, -30.0), (12.0, 0.0, 5.0), (34.0, 5.0, 20.0), (25.0, 0.0, 46.0), (5.0, 1.2, 47.0),
       (-30.0, 4.5, 28.0), (-52.0, 0.0, -24.0)]
for i, p in enumerate(FFA):
    marker(f"SPAWN_FFA_{i:02d}", p)

# Long Colt five-gun mapping of Headlong's power positions [E] (see headlong_spec.md section 6)
WEAPONS = [
    ("WPN_MarksmanCarbine_SiteRoof", (-25.0, 9.0, -27.0)),       # H2: sniper-rifle perch
    ("WPN_MarksmanCarbine_HotelRoof", (24.0, 10.0, 8.0)),         # H2: second sniper
    ("WPN_CombatShotgun_Alley", (-50.0, 0.0, -8.0)),              # H2: shotgun building
    ("WPN_CombatShotgun_Corner", (-36.0, 0.0, 16.0)),
    ("WPN_DirectedEnergyRifle_Crane", (CRANE[0], CRANE[1], CRANE[2])),  # H2: rocket-launcher tier
    ("WPN_StandardIssueRifle_GateBridge", (10.0, 8.0, -7.0)),
    ("WPN_StandardIssueRifle_Statue", (5.0, 1.2, 48.0)),
    ("WPN_StandardIssueRifle_Pit", (-20.0, PIT, -38.0)),
    ("WPN_ServicePistol_North", (-27.0, 0.0, -51.0)),
    ("WPN_ServicePistol_SiteF1", (-34.0, 1.0, -9.0)),
    ("WPN_ServicePistol_Hotel2F", (36.0, 5.0, 19.5)),
]
for n, p in WEAPONS:
    marker(n, p)
marker("PWR_Overshield_Pit", (-14.0, PIT, -22.0))       # H2 power-up, no Long Colt equivalent yet
marker("PWR_ActiveCamo_Alley2F", (-50.0, 5.0, -4.0))
marker("FLAG_Red_Hotel", (34.0, 0.0, 19.0))
marker("FLAG_Blue_Corner", (-28.0, 0.0, 28.0))
marker("LIFT_Hotel_Atrium", (34.0, 0.0, 13.0))          # Area3D: 0 -> 6.0 m (2F rail top 6.05)
marker("TELE_A_North", (-23.75, 0.0, -51.25))           # pair A -> TELE_A_SouthStreet
marker("TELE_A_SouthStreet", (52.0, 0.0, 48.0))
marker("TELE_B_Alley", (-54.5, 0.0, -12.0))             # pair B -> TELE_B_EastLane
marker("TELE_B_EastLane", (48.0, 0.0, -10.0))
box("TelePad_SouthStreet", (52.0, 0.05, 48.0), (2.5, 0.1, 2.5), "tele", "Markers")
box("TelePad_EastLane", (48.0, 0.05, -10.0), (2.5, 0.1, 2.5), "tele", "Markers")
CALLOUTS = {
    "ConstructionPit": (-10.0, PIT, -10.0), "BuildingSite": (-29.4, 5.0, -18.4),
    "GateBridge": (10.0, 8.0, -4.0), "CranePlatform": CRANE, "SteelBeam": (-4.0, 6.0, -15.5),
    "Hotel": (34.0, 5.0, 13.0), "CornerBuilding": (-32.0, 4.5, 21.0), "Alley": (-52.0, 0.0, -8.0),
    "Statue": (5.0, 1.2, 49.0), "SouthStreet": (25.0, 0.0, 46.0), "EastLane": (25.0, 0.0, -25.0),
    "Underpass": (10.0, 0.0, 9.0), "NorthLot": (-10.0, 0.0, -50.0), "CentralPlaza": (-5.0, 0.0, 18.0),
}
for n, p in CALLOUTS.items():
    marker("CALLOUT_" + n, p, group="Callouts")

# =========================================================================================
# report slopes, save, export, render
# =========================================================================================
print("\n== Headlong greybox: slopes (deg; floor_max_angle 50) ==")
for n, s in SLOPES.items():
    flag = "  !! too steep" if s > 50 else ""
    print(f"  {n:24s} {s:5.1f}{flag}")
n_col = sum(1 for o in bpy.data.objects if o.name.endswith("-col"))
n_mark = sum(1 for o in bpy.data.objects if o.type == "EMPTY")
print(f"  objects: {n_col} collision meshes, {n_mark} markers")

os.makedirs(os.path.dirname(os.path.abspath(BLEND)), exist_ok=True)
bpy.context.preferences.filepaths.save_version = 0  # no .blend1 backups
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(BLEND))
os.makedirs(os.path.dirname(os.path.abspath(GLB)), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=os.path.abspath(GLB), export_format="GLB", export_yup=True,
                          export_apply=True, export_cameras=False, export_lights=False,
                          export_materials="EXPORT", export_extras=False, export_normals=True,
                          export_texcoords=True, use_selection=False)
print("  wrote", GLB, "and", BLEND)

# ---- Godot scenes (written as text; markers above are the single source of truth) ----------
LEVEL_TSCN = _arg("--level-tscn", "scenes/levels/headlong.tscn")
MAIN_TSCN = _arg("--main-tscn", "scenes/main/main_headlong.tscn")
ARENA_TSCN = _arg("--arena-tscn", "scenes/main/arena_headlong.tscn")


def _xf(p, yaw=0.0):
    c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    return f"Transform3D({c:.6g}, 0, {s_:.6g}, 0, 1, 0, {-s_:.6g}, 0, {c:.6g}, {p[0]:.6g}, {p[1]:.6g}, {p[2]:.6g})"


def _spawn_list():
    out = []
    for o in bpy.data.objects:
        if o.type == "EMPTY" and o.name.startswith("SPAWN_"):
            loc = o.matrix_world.translation
            yaw = math.degrees(o.matrix_world.to_euler().z)
            out.append((o.name, (loc.x, loc.z + 0.05, -loc.y), yaw))
    return sorted(out)


lines = [
    "[gd_scene load_steps=6 format=3]",
    "",
    '[ext_resource type="PackedScene" path="res://assets/models/environment/headlong_greybox.glb" id="1_glb"]',
    '[ext_resource type="Script" path="res://scripts/levels/grav_lift.gd" id="2_lift"]',
    '[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="3_kill"]',
    "",
    '[sub_resource type="BoxShape3D" id="Shape_Lift"]',
    "size = Vector3(3, 4, 3)",
    "",
    '[sub_resource type="BoxShape3D" id="Shape_Kill"]',
    "size = Vector3(300, 2, 300)",
    "",
    "; GENERATED by tools/headlong/build_headlong.py - edit the script, not this file.",
    '[node name="Headlong" type="Node3D"]',
    "",
    '[node name="Greybox" parent="." instance=ExtResource("1_glb")]',
    "",
    "; Hotel atrium lift: 0 -> 4 m volume, exits at 12 m/s -> ~7.3 m apex, step onto the 2F ring",
    '[node name="GravLift_Hotel" type="Area3D" parent="."]',
    "transform = " + _xf((34.0, 2.0, 13.0)),
    "collision_layer = 16",
    "collision_mask = 2",
    "monitorable = false",
    'script = ExtResource("2_lift")',
    "",
    '[node name="Shape" type="CollisionShape3D" parent="GravLift_Hotel"]',
    'shape = SubResource("Shape_Lift")',
    "",
    "; below the pit floor (-3) and the sea (-4)",
    '[node name="KillVolume" type="Area3D" parent="."]',
    "transform = " + _xf((0.0, -8.0, 0.0)),
    "collision_layer = 16",
    "collision_mask = 6",
    "monitorable = false",
    'script = ExtResource("3_kill")',
    "",
    '[node name="Shape" type="CollisionShape3D" parent="KillVolume"]',
    'shape = SubResource("Shape_Kill")',
    "",
    '[node name="Spawns" type="Node3D" parent="."]',
    "",
]
for name, p, yaw in _spawn_list():
    lines += [f'[node name="{name}" type="Marker3D" parent="Spawns"]', "transform = " + _xf(p, yaw), ""]
os.makedirs(os.path.dirname(os.path.abspath(LEVEL_TSCN)), exist_ok=True)
open(LEVEL_TSCN, "w").write("\n".join(lines))

GUN = {"MarksmanCarbine": ("marksman_carbine", "2_carbine", 0.0), "CombatShotgun": ("combat_shotgun", "3_shotgun", 90.0),
       "DirectedEnergyRifle": ("directed_energy_rifle", "4_energy", 90.0),
       "StandardIssueRifle": ("standard_issue_rifle", "5_rifle", 0.0), "ServicePistol": ("service_pistol", "6_pistol", 0.0)}
ml = ["[gd_scene load_steps=11 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/headlong.tscn" id="1_level"]']
for f, rid, _ in GUN.values():
    ml.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
ml += ['[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
       '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
       '[ext_resource type="Environment" path="res://resources/environments/lockout_environment.tres" id="9_env"]',
       '[ext_resource type="PackedScene" path="res://scenes/vehicles/humvee.tscn" id="16_humvee"]',
       "", "; GENERATED by tools/headlong/build_headlong.py - offline balance testbed (no bots). LightmapGI bakes sun bounce.",
       '[node name="MainHeadlong" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', "",
       '[node name="Sun" type="DirectionalLight3D" parent="."]',
       "transform = Transform3D(0.707107, 0.40558, -0.579228, 0, 0.819152, 0.573576, 0.707107, -0.40558, 0.579228, 0, 40, 0)",
       "light_color = Color(1, 0.9, 0.78, 1)", "light_energy = 2.0", "shadow_enabled = true",
       "directional_shadow_max_distance = 200.0", "light_bake_mode = 2", "",
       '[node name="Headlong" parent="." instance=ExtResource("1_level")]', "",
       '[node name="LightmapGI" type="LightmapGI" parent="."]',
       "quality = 2", "bounces = 3", "use_denoiser = true", "interior = false",
       "environment_mode = 1", "generate_probes_subdiv = 2", "",
       '[node name="Humvee_EastLane" parent="." instance=ExtResource("16_humvee")]',
       "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 34, 0, -34)",
       '[node name="Humvee_SouthStreet" parent="." instance=ExtResource("16_humvee")]',
       "transform = Transform3D(0, 0, -1, 0, 1, 0, 1, 0, 0, 42, 0, 46)", ""]
first = [sp for sp in _spawn_list() if sp[0].startswith("SPAWN_Blue")][0]
ml += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
for n, p in WEAPONS:
    key = n.split("_")[1]
    f, rid, respawn = GUN[key]
    ml += [f'[node name="{n[4:]}" parent="." instance=ExtResource("8_pickup")]', "transform = " + _xf(p),
           f'weapon_scene = ExtResource("{rid}")'] + ([f"respawn_delay = {respawn}"] if respawn else []) + [""]
open(MAIN_TSCN, "w").write("\n".join(ml))

# Arena (Bot Arena + LAN): same pickups as main_headlong, plus bots, runtime navmesh, roam points,
# NetMatch before SpawnManager (its _ready configures SpawnManager), like arena_lockout.tscn.
# Roam points sit on open floor (not the 1.2 m Steel Beam, not stairwells / columns / the atrium).
ROAM = [
    ("ConstructionPit", (-10.0, PIT, -10.0), 1.5), ("PitNorth", (-20.0, PIT, -38.0), 1.0),
    ("SiteF1", (-32.0, 1.0, -15.0), 1.0), ("SiteF2", (-32.0, 5.0, -15.0), 1.0),
    ("SiteRoof", (-29.4, 9.0, -27.0), 1.5), ("CranePlatform", CRANE, 1.5),
    ("GateBridge", (10.0, 8.0, -4.0), 1.5), ("Underpass", (10.0, 0.0, 9.0), 1.0),
    ("HotelGF", (24.0, 0.0, 18.0), 1.0), ("Hotel2F", (34.0, 5.0, 6.5), 1.5),
    ("HotelRoof", (30.0, 10.0, 14.0), 1.0), ("HotelBalcony", (50.25, 5.0, 17.5), 0.5),
    ("CornerGF", (-36.0, 0.0, 24.0), 1.0), ("Corner2F", (-32.0, 4.5, 23.0), 1.5),
    ("CornerRoof", (-30.0, 9.0, 18.0), 1.0), ("Alley", (-52.0, 0.0, -8.0), 1.0),
    ("Alley2F", (-52.0, 5.0, -18.0), 1.0), ("NorthLot", (-10.0, 0.0, -50.0), 0.5),
    ("NorthBuilding", (-27.0, 0.0, -51.0), 0.5), ("EastLane", (25.0, 0.0, -25.0), 1.0),
    ("CentralPlaza", (-5.0, 0.0, 18.0), 1.0), ("SouthStreet", (25.0, 0.0, 46.0), 1.0),
    ("Statue", (5.0, 1.2, 46.0), 1.0),
]
al = ["[gd_scene load_steps=19 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/headlong.tscn" id="1_level"]',
      '[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
      '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
      '[ext_resource type="Environment" path="res://resources/environments/lockout_environment.tres" id="9_env"]',
      '[ext_resource type="PackedScene" path="res://scenes/vehicles/humvee.tscn" id="16_humvee"]',
      '[ext_resource type="PackedScene" path="res://scenes/ai/bot.tscn" id="10_bot"]',
      '[ext_resource type="Script" path="res://scripts/ai/arena_events.gd" id="11_events"]',
      '[ext_resource type="Script" path="res://scripts/ai/arena_navigation.gd" id="12_nav"]',
      '[ext_resource type="Script" path="res://scripts/net/net_match.gd" id="13_net"]',
      '[ext_resource type="Script" path="res://scripts/ai/spawn_manager.gd" id="14_spawns"]',
      '[ext_resource type="Resource" path="res://resources/ai/bot_difficulty_normal.tres" id="15_diff"]']
for f, rid, _ in GUN.values():
    al.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
al += ["", "; GENERATED by tools/headlong/build_headlong.py - arena mode (Bot Arena / LAN) on Headlong.",
       '[node name="ArenaHeadlong" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', "",
       '[node name="Sun" type="DirectionalLight3D" parent="."]',
       "transform = Transform3D(0.707107, 0.40558, -0.579228, 0, 0.819152, 0.573576, 0.707107, -0.40558, 0.579228, 0, 40, 0)",
       "light_color = Color(1, 0.9, 0.78, 1)", "light_energy = 2.0", "shadow_enabled = true",
       "directional_shadow_max_distance = 200.0", "light_bake_mode = 2", "",
       '[node name="ArenaEvents" type="Node" parent="."]', 'script = ExtResource("11_events")', "",
       '[node name="Headlong" parent="." instance=ExtResource("1_level")]', "",
       '[node name="LightmapGI" type="LightmapGI" parent="."]',
       "quality = 2", "bounces = 3", "use_denoiser = true", "interior = false",
       "environment_mode = 1", "generate_probes_subdiv = 2", "",
       '[node name="Humvee_EastLane" parent="." instance=ExtResource("16_humvee")]',
       "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 34, 0, -34)",
       '[node name="Humvee_SouthStreet" parent="." instance=ExtResource("16_humvee")]',
       "transform = Transform3D(0, 0, -1, 0, 1, 0, 1, 0, 0, 42, 0, 46)", "",
       '[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
for n, p in WEAPONS:
    f, rid, respawn = GUN[n.split("_")[1]]
    al += [f'[node name="{n[4:]}" parent="." instance=ExtResource("8_pickup")]', "transform = " + _xf(p),
           f'weapon_scene = ExtResource("{rid}")'] + ([f"respawn_delay = {respawn}"] if respawn else []) + [""]
al += ['[node name="Navigation" type="NavigationRegion3D" parent="."]', 'script = ExtResource("12_nav")',
       'geometry_root = NodePath("../Headlong")', "",
       "; Hotel atrium lift (GravLift_Hotel in headlong.tscn): hold over the pad, step north at 5.5 m",
       '[node name="Link_HotelLift" type="NavigationLink3D" parent="Navigation"]', "bidirectional = false",
       "navigation_layers = 1", "start_position = Vector3(34, 0, 13)", "end_position = Vector3(34, 5, 7)",
       'metadata/traversal = "lift"', "metadata/release_y = 5.5", "",
       '[node name="NavPoints" type="Node3D" parent="."]', ""]
for n, p, w in ROAM:
    al += [f'[node name="{n}" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]',
           "transform = " + _xf((p[0], p[1] + 0.05, p[2])), f"metadata/weight = {w:g}", f'metadata/callout = "{n}"', ""]
al += ['[node name="NetMatch" type="Node" parent="."]', 'script = ExtResource("13_net")', "",
       '[node name="SpawnManager" type="Node" parent="."]', 'script = ExtResource("14_spawns")',
       'bot_scene = ExtResource("10_bot")', "bot_count = 3", 'difficulty = ExtResource("15_diff")',
       'spawn_roots = Array[NodePath]([NodePath("../Headlong/Spawns")])', ""]
open(ARENA_TSCN, "w").write("\n".join(al))
print("  wrote", LEVEL_TSCN, MAIN_TSCN, "and", ARENA_TSCN)

if RENDER:
    os.makedirs(PREVIEWS, exist_ok=True)
    scene.render.engine = "BLENDER_WORKBENCH"
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.color_type = "OBJECT"
    shading.show_cavity = True
    shading.show_object_outline = True
    shading.show_shadows = True
    scene.render.film_transparent = False
    world = bpy.data.worlds.new("w")
    scene.world = world
    world.color = (0.05, 0.05, 0.06)
    hide = [o for o in bpy.data.objects if o.name.startswith(("OOB_North", "OOB_NE", "OOB_East", "Crane_Cable",
                                                              "Crane_Mast", "Statue_Column", "Alley_Ceiling", "North_Roof"))]

    def shoot(fname, loc, rot, ortho=None, res=(1600, 1600), hidden=()):
        for o in hidden:
            o.hide_render = True
        cam_data = bpy.data.cameras.new(fname)
        if ortho:
            cam_data.type = "ORTHO"
            cam_data.ortho_scale = ortho
        else:
            cam_data.lens = 24
        cam_data.clip_end = 1000
        cam = bpy.data.objects.new(fname, cam_data)
        scene.collection.objects.link(cam)
        cam.location = loc
        cam.rotation_euler = Euler([math.radians(a) for a in rot])
        scene.camera = cam
        scene.render.resolution_x, scene.render.resolution_y = res
        scene.render.filepath = os.path.join(os.path.abspath(PREVIEWS), fname + ".png")
        bpy.ops.render.render(write_still=True)
        bpy.data.objects.remove(cam)
        for o in hidden:
            o.hide_render = False

    # overhead: north up (Blender +Y = Godot -Z = north)
    shoot("headlong_overhead", (0, 0, 150), (0, 0, 0), ortho=124, hidden=hide)
    shoot("headlong_persp_from_sea", (45, -95, 45), (62, 0, 20), res=(1920, 1080))
    shoot("headlong_persp_from_hotel", (60, 10, 30), (68, 0, 102), res=(1920, 1080), hidden=hide)
    print("  previews in", PREVIEWS)
