"""Build the Zanzibar (Halo 2, 2004) greybox (.glb + .blend), its Godot scenes and preview renders
with headless Blender.

Usage (from the repo root):
  blender -b --factory-startup --python tools/zanzibar/build_zanzibar.py -- \
      [--glb assets/models/environment/zanzibar_greybox.glb] [--blend tools/zanzibar/zanzibar_greybox.blend] \
      [--previews tools/zanzibar/previews] [--no-render]

ALL geometry is ESTIMATED: traced from the MCC Zanzibar loading-screen map (1280x720) and checked
against Bungie's layout sketch and the Halopedia screenshots. Plan positions are authored in MCC-map
PIXELS through px(), at 1 px = 0.22 m, so the trace can be compared to the image directly. Heights
are in metres. See zanzibar_spec.md for sources and confidence.

Godot space: metres, +Y up, +X east, -Z north (north = top of the MCC map; the sea is east).
g2b() converts to Blender space; the glTF exporter (export_yup) converts back.

Naming for the Godot importer:
  *-col      mesh + StaticBody3D with trimesh collision (World layer 1)
  no suffix  visual only (sea, turbine wheel)
  Empties    SPAWN_*, WPN_*, PWR_*, FLAG_*, VEH_*, TURRET_*, GATE_*, CALLOUT_* become Node3D markers;
             zanzibar.tscn turns SPAWN_* into Spawns, the arena turns WPN_* into pickups.
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


GLB = _arg("--glb", "assets/models/environment/zanzibar_greybox.glb")
BLEND = _arg("--blend", "tools/zanzibar/zanzibar_greybox.blend")
PREVIEWS = _arg("--previews", "tools/zanzibar/previews")
RENDER = "--no-render" not in argv and PREVIEWS != ""

# Player reference (scripts/player/player.gd): 2.1 m body, jump_height 2.2, stand_speed 7.5,
# gravity 22 -> ~0.89 s airtime, ~6.7 m flat running jump. floor_max_angle 50 deg, step 0.35.
COURT = 0.0      # courtyard, base ground floor
BEACH = -2.0     # dry sand
SURF = -2.3      # wet sand strip at the waterline (0.3 step, walkable); beyond it you fall to the kill volume
WALL_TOP = 4.0   # sea wall walk, gate deck, bastions
BASE_2F = 6.0
BASE_ROOF = 12.0  # also the wheel bridge and hub deck
WALL_T = 0.5
OOB_H = 25.0

PX_M = 0.22                 # metres per MCC-map pixel
PX_ORIGIN = (355.0, 350.0)  # MCC pixel at the Godot origin (east courtyard, by the round bunker)


def px(sx, sy):
    """MCC loading-screen pixel -> Godot (x, z)."""
    return ((sx - PX_ORIGIN[0]) * PX_M, (sy - PX_ORIGIN[1]) * PX_M)


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
    "ground": "#8a7f6a",   # courtyard dirt
    "sand": "#d2bd8c",     # beach
    "surf": "#a8946a",     # wet sand
    "floor": "#b4b4b4",    # building floors and roofs
    "wall": "#6c6f73",
    "seawall": "#9a8a70",  # old stone sea wall, bastions, ruins
    "ramp": "#c0843a",     # anything sloped you can walk
    "catwalk": "#d1a420",  # bridges, hub deck (construction yellow)
    "cover": "#455a64",    # rocks, blocks
    "oob": "#34363a",      # cliffs / out-of-bounds mass
    "wheel": "#c9ccd1",    # turbine ring and blades (visual)
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


def _link(full, me, mat, group):
    ob = bpy.data.objects.new(full, me)
    ob.data.materials.append(_mat[mat])
    ob.color = _mat[mat].diffuse_color
    coll(group).objects.link(ob)
    return ob


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
    _link(full, _mesh(full, verts, faces), mat, group)
    return max(abs(math.degrees(math.atan2(P[i + 1].y - P[i].y, (P[i + 1] - P[i]).xz.length)))
               for i in range(n - 1))


def box(name, center, size, mat, group, yaw=0.0, pitch=0.0, collide=True):
    """center/size in Godot space. yaw = degrees about +Y (counter-clockwise seen from above),
    pitch = degrees about the box's local X after yaw (positive raises its -Z end)."""
    full = _unique(name) + ("-col" if collide else "")
    ob = _link(full, _cube_mesh(full, size), mat, group)
    # Godot: R = Ry(yaw) * Rx(pitch). Godot->Blender axes: Godot Y = Blender Z, Godot X = Blender X.
    rot = Matrix.Rotation(math.radians(yaw), 4, "Z") @ Matrix.Rotation(math.radians(pitch), 4, "X")
    ob.matrix_world = Matrix.Translation(g2b(center)) @ rot
    return ob


def poly_slab(name, pts, top, thick, mat, group):
    """Vertical prism over a (possibly concave) plan polygon of Godot (x, z) points."""
    n = len(pts)
    verts = [tuple(g2b((x, top, z))) for x, z in pts] + [tuple(g2b((x, top - thick, z))) for x, z in pts]
    faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    full = _unique(name) + "-col"
    return _link(full, _mesh(full, verts, faces), mat, group)


def prism(name, cx, cz, r, y0, y1, mat, group, sides=10, collide=True):
    """Round tower / bunker approximated by an n-sided prism."""
    pts = [(cx + r * math.cos(2 * math.pi * i / sides), cz + r * math.sin(2 * math.pi * i / sides))
           for i in range(sides)]
    if collide:
        return poly_slab(name, pts, y1, y1 - y0, mat, group)
    n = len(pts)
    verts = [tuple(g2b((x, y1, z))) for x, z in pts] + [tuple(g2b((x, y0, z))) for x, z in pts]
    faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    full = _unique(name)
    return _link(full, _mesh(full, verts, faces), mat, group)


def ring_parapet(name, cx, cz, r, top, gaps=(), group="SeaWall", sides=10, h=1.05):
    """Parapet blocks around a round platform; gaps = list of (angle_deg, half_width_deg) left open."""
    for i in range(sides):
        a0, a1 = 360.0 * i / sides, 360.0 * (i + 1) / sides
        mid = (a0 + a1) / 2
        if any(abs((mid - g + 180) % 360 - 180) < w for g, w in gaps):
            continue
        p0 = (cx + r * math.cos(math.radians(a0)), cz + r * math.sin(math.radians(a0)))
        p1 = (cx + r * math.cos(math.radians(a1)), cz + r * math.sin(math.radians(a1)))
        parapet(f"{name}_{i}", p0[0], p0[1], p1[0], p1[1], top, h=h, group=group, mat="seawall")


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
            if o is not None and abs(b1 - o[2]) < 0.005:
                b1 -= 0.02
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
    Ends meet floors cleanly without over-length penetration. rails > 0 adds side rails."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    horiz = math.hypot(d.x, d.z)
    length = d.length
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
            c = (a + b) / 2 + side * sgn * (width / 2 - 0.15) + normal * (rails / 2 + 0.002)
            box(f"{name}_Rail{tag}", tuple(c), (0.3, rails, length), "wall", group, yaw=yaw, pitch=pitch)
    return math.degrees(math.atan2(d.y, horiz))


def parapet(name, x0, z0, x1, z1, top, h=1.05, group="Buildings", mat="wall", t=0.3):
    """Rail/parapet standing on a floor whose top is `top`, along a straight line."""
    d = Vector((x1 - x0, 0, z1 - z0))
    yaw = math.degrees(math.atan2(-d.x, -d.z))
    box(name, ((x0 + x1) / 2, top + 0.002 + h / 2, (z0 + z1) / 2), (t, h, d.length), mat, group, yaw=yaw)


def marker(name, pos, group="Markers", yaw=0.0):
    ob = bpy.data.objects.new(_unique(name), None)
    ob.empty_display_type = "ARROWS"
    ob.empty_display_size = 1.0
    ob.matrix_world = Matrix.Translation(g2b(pos)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    coll(group).objects.link(ob)
    return ob


class Polyline:
    """Plan polyline of Godot (x, z) points with arc-length lookups (the sea wall)."""

    def __init__(self, pts):
        self.p = [Vector(p) for p in pts]
        self.s = [0.0]
        for i in range(1, len(self.p)):
            self.s.append(self.s[-1] + (self.p[i] - self.p[i - 1]).length)
        self.length = self.s[-1]

    def _seg(self, s):
        for i in range(len(self.p) - 1):
            if s <= self.s[i + 1] or i == len(self.p) - 2:
                return i
        return 0

    def at(self, s):
        i = self._seg(s)
        t = (s - self.s[i]) / (self.s[i + 1] - self.s[i])
        return self.p[i].lerp(self.p[i + 1], t)

    def tangent(self, s):
        i = self._seg(s)
        return (self.p[i + 1] - self.p[i]).normalized()

    def section(self, s0, s1):
        """Points from s0 to s1, including the corners in between."""
        out = [self.at(s0)]
        out += [self.p[i] for i in range(len(self.p)) if s0 < self.s[i] < s1]
        return out + [self.at(s1)]

    def nearest_s(self, q, steps=2000):
        q = Vector(q)
        return min((self.length * k / steps for k in range(steps + 1)), key=lambda s: (self.at(s) - q).length)


SLOPES = {}

# =========================================================================================
# 1. PLAN TRACE (MCC pixels) - sea wall line, ground polygons, shoreline
# =========================================================================================
# Sea wall centreline, north bastion -> south end. The wall separates the courtyard (west,
# y 0) from the beach (east, y -2); its walk is at y 4.
NORTH_BASTION = px(356, 213)
SOUTH_BASTION = px(478, 463)
WALL_PTS = [NORTH_BASTION, px(352, 240), px(395, 330), px(440, 425), px(470, 490)]
SEAWALL = Polyline(WALL_PTS)
SEAWALL_W = 3.0

COURT_POLY = [px(*p) for p in (
    (50, 285), (50, 422), (72, 422), (72, 525), (125, 530), (150, 570), (275, 570), (275, 525),
    (290, 517), (305, 520), (355, 517), (380, 480), (400, 478), (447, 490), (470, 490), (440, 425),
    (395, 330), (352, 240), (345, 205), (330, 200), (290, 211), (190, 211), (145, 240), (120, 262),
    (120, 285))]
SHORE = [px(*p) for p in ((532, 133), (520, 200), (510, 255), (482, 320), (487, 385), (525, 430),
                          (565, 470), (600, 540))]
BEACH_POLY = [px(352, 240), px(345, 205), px(385, 165), px(410, 148), px(440, 137)] + SHORE + \
    [px(500, 540), px(500, 502), px(470, 502), px(470, 490), px(440, 425), px(395, 330)]
SURF_W = 8.0
SURF_POLY = SHORE + [(x + SURF_W, z) for x, z in reversed(SHORE)]

# Out-of-bounds chain: cliffs north of the beach, round the courtyard, cliffs south of the beach.
# Walls stand on the outer side of each segment (traversal keeps the playable area on the left).
OOB_CHAIN = [px(*p) for p in (
    (600, 133), (440, 137), (410, 148), (385, 165), (345, 205), (330, 200), (290, 211), (190, 211),
    (145, 240), (120, 262), (120, 285), (50, 285), (50, 422), (72, 422), (72, 525), (125, 530),
    (150, 570), (275, 570), (275, 525), (290, 517), (305, 520), (355, 517), (380, 480), (400, 478),
    (447, 490), (470, 502), (500, 502), (500, 540), (660, 540))]

# =========================================================================================
# 2. GROUND + BOUNDARY
# =========================================================================================
poly_slab("Courtyard_Ground", COURT_POLY, COURT, 3.0, "ground", "Ground")
poly_slab("Beach_Sand", BEACH_POLY, BEACH, 2.0, "sand", "Ground")
poly_slab("Beach_Surf", SURF_POLY, SURF, 1.0, "surf", "Ground")
box("Sea", (110.0, -2.6, 0.0), (160.0, 0.1, 200.0), "sea", "Boundary", collide=False)

for i in range(len(OOB_CHAIN) - 1):
    a, b = Vector(OOB_CHAIN[i]), Vector(OOB_CHAIN[i + 1])
    d = (b - a).normalized()
    out = Vector((-d.y, d.x))  # px traversal is anticlockwise on screen -> outward is (-dz, dx)
    c = (a + b) / 2 + out * 1.0
    yaw = math.degrees(math.atan2(-d.x, -d.y))
    box(f"OOB_{i:02d}", (c.x, OOB_H / 2 - 2.0, c.y), (2.0, OOB_H + 4.0, (b - a).length + 2.0), "oob", "Boundary",
        yaw=yaw)

# =========================================================================================
# 3. SEA WALL - stone wall with a walk at y 4, merlons on the beach side, round bastions at
#    both ends, the Gate where the road passes through, stairs on both faces.
# =========================================================================================
# Gate passage: beach end -> courtyard end (the vehicle road into the courtyard) [E]
GATE_BEACH, GATE_COURT = Vector(px(440, 283)), Vector(px(367, 333))
_gdir = (GATE_COURT - GATE_BEACH).normalized()
GATE_S = SEAWALL.nearest_s(GATE_BEACH.lerp(GATE_COURT, 0.55))
for _ in range(3):  # refine the crossing: nearest wall point to the passage line
    w = SEAWALL.at(GATE_S)
    t = (w - GATE_BEACH).dot(_gdir)
    GATE_S = SEAWALL.nearest_s(GATE_BEACH + _gdir * t)
GATE_X = SEAWALL.at(GATE_S)
GATE_W = 7.0
_sin = abs(_gdir.x * SEAWALL.tangent(GATE_S).y - _gdir.y * SEAWALL.tangent(GATE_S).x)
GATE_HALF = (GATE_W / 2 + 0.5) / max(_sin, 0.5)  # half gap measured along the wall
GAP = (GATE_S - GATE_HALF, GATE_S + GATE_HALF)


def _wall_pts(s0, s1, y):
    return [(p.x, y, p.y) for p in SEAWALL.section(s0, s1)]


def _beach_normal(s):
    t = SEAWALL.tangent(s)
    return Vector((t.y, -t.x))  # left of travel (north -> south) = east = beach


S0 = 3.0  # wall starts inside the north bastion
SLOPES["SeaWall_N"] = strip("SeaWall_N", _wall_pts(S0, GAP[0], WALL_TOP), SEAWALL_W, WALL_TOP + 2.5, "seawall", "SeaWall")
SLOPES["SeaWall_S"] = strip("SeaWall_S", _wall_pts(GAP[1], SEAWALL.length, WALL_TOP), SEAWALL_W, WALL_TOP + 2.5,
                            "seawall", "SeaWall")
# Gate deck spans the passage at wall-walk height (clearance ~3.4 m over the road)
strip("Gate_Deck", _wall_pts(GAP[0] - 0.5, GAP[1] + 0.5, WALL_TOP), SEAWALL_W + 1.0, 0.6, "catwalk", "SeaWall")

# Stairs [E]: (name, s0, s1, side) - side +1 beach face (from y -2), -1 courtyard face (from y 0)
WALL_STAIRS = [("Stairs_Beach_Mid", 30.0, 42.0, 1), ("Stairs_Beach_South", 46.5, 57.5, 1),
               ("Stairs_Court_North", 4.0, 12.0, -1), ("Stairs_Court_Mid", 34.0, 42.0, -1)]
for n, s0, s1, side in WALL_STAIRS:
    off = _beach_normal((s0 + s1) / 2) * side * (SEAWALL_W / 2 + 1.5)
    a, b = SEAWALL.at(s0) + off, SEAWALL.at(s1) + off
    y0 = BEACH if side > 0 else COURT
    SLOPES[n] = ramp(n, (a.x, y0, a.y), (b.x, WALL_TOP, b.y), 3.0, group="SeaWall")

# Merlons along the beach edge, open where beach stairs arrive and over the gate
_open = [GAP, (39.0, 44.0), (54.5, SEAWALL.length + 1)]
s = S0 + 2.0
k = 0
while s < SEAWALL.length - 1.0:
    if not any(o0 - 1.0 < s < o1 + 1.0 for o0, o1 in _open):
        p = SEAWALL.at(s) + _beach_normal(s) * (SEAWALL_W / 2 - 0.3)
        t = SEAWALL.tangent(s)
        box(f"SeaWall_Merlon_{k:02d}", (p.x, WALL_TOP + 0.6, p.y), (0.6, 1.2, 1.6), "seawall", "SeaWall",
            yaw=math.degrees(math.atan2(-t.x, -t.y)))
        k += 1
    s += 3.0

# Bastions: round platforms flush with the walk. North = "Sea Wall" territory end; south one
# overlooks the beach (carbine) [E].
prism("Bastion_North", *NORTH_BASTION, 4.2, -2.5, WALL_TOP, "seawall", "SeaWall")
ring_parapet("Bastion_North_Rail", *NORTH_BASTION, 4.0, WALL_TOP, gaps=[(90, 25)])
prism("Bastion_South", *SOUTH_BASTION, 3.6, -2.5, WALL_TOP, "seawall", "SeaWall")
ring_parapet("Bastion_South_Rail", *SOUTH_BASTION, 3.4, WALL_TOP, gaps=[(200, 40)])

# Gate road: beach (y -2) up to the wall line (y 0), then flat courtyard
_rb = GATE_X + Vector((-_gdir.x, -_gdir.y)) * 10.0
SLOPES["Gate_Road"] = ramp("Gate_Road", (_rb.x, BEACH, _rb.y), (GATE_X.x, COURT, GATE_X.y), GATE_W, group="SeaWall")
# beach-side gate wings (the gatehouse block on the MCC map) [E]
_side = Vector((-_gdir.y, _gdir.x))
for sgn, tag in ((1, "A"), (-1, "B")):
    c = GATE_X - _gdir * 5.0 + _side * sgn * (GATE_W / 2 + 0.75)
    box(f"Gate_Wing_{tag}", (c.x, (BEACH - 0.5 + WALL_TOP - 0.6) / 2, c.y), (1.5, WALL_TOP - 0.6 - (BEACH - 0.5), 7.0), "seawall",
        "SeaWall", yaw=math.degrees(math.atan2(-_gdir.x, -_gdir.y)))
    c2 = GATE_X - _gdir * 5.0 + _side * sgn * (GATE_W / 2 + 0.75)
    box(f"Gate_WingTop_{tag}", (c2.x, WALL_TOP - 0.3, c2.y), (1.5, 0.6, 7.0), "seawall", "SeaWall",
        yaw=math.degrees(math.atan2(-_gdir.x, -_gdir.y)))

# =========================================================================================
# 4. BASE (wind-station facility, defenders) - x -67..-41, z -14..15.5
#    GF y 0: flag room (centre-back) between two generator rooms, front hall.
#    2F y 6: ring around the flag-room atrium, turret windows east.  Roof y 12: wheel bridge.
# =========================================================================================
BX0, BX1, BZ0, BZ1 = -67.0, -41.0, -14.0, 15.5
IX0, IX1, IZ0, IZ1 = BX0 + WALL_T, BX1 - WALL_T, BZ0 + WALL_T, BZ1 - WALL_T
HALL_X = -50.0                       # front hall x -50..-41.5
FLAG = (-63.0, COURT, 0.75)
DOOR = 3.0
ATRIUM = (-63.5, -51.5, -3.5, 5.0)
STAIR1 = (-44.6, -42.0, 3.0, 14.0)   # GF -> 2F along z (south -> north)
STAIR2 = (-44.6, -42.0, -13.5, -2.5)  # 2F -> roof along z (south -> north)

floor_holes("Base_2F", IX0, IX1, IZ0, IZ1, BASE_2F, [ATRIUM, STAIR1], group="Base")
floor_holes("Base_Roof", BX0, BX1, BZ0, BZ1, BASE_ROOF, [STAIR2], group="Base")
WIN2 = (7.2, 9.4)
wall("Base_E", "z", BX1 - WALL_T / 2, BZ0, BZ1, COURT, BASE_ROOF - 0.4,
     [(-11.5, -7.5, 0.0, DOOR), (-1.5, 3.0, 0.0, 4.0), (-12.5, -4.0, *WIN2), (5.0, 13.0, *WIN2)], group="Base")
wall("Base_W", "z", BX0 + WALL_T / 2, BZ0, BZ1, COURT, BASE_ROOF - 0.4, [], group="Base")
wall("Base_N", "x", BZ0 + WALL_T / 2, BX0 + WALL_T, BX1 - WALL_T, COURT, BASE_ROOF - 0.4, [(-48.5, -45.5, 0.0, DOOR), (-62.0, -54.0, *WIN2)],
     group="Base")
wall("Base_S", "x", BZ1 - WALL_T / 2, BX0 + WALL_T, BX1 - WALL_T, COURT, BASE_ROOF - 0.4, [(-48.5, -45.5, 0.0, DOOR), (-62.0, -54.0, *WIN2)],
     group="Base")
# generator rooms (north / south of the flag room), GF only, ceiling = 2F slab
for tag, zw, zr in (("N", -4.0, (IZ0, -4.0)), ("S", 5.5, (5.5, IZ1))):
    wall(f"Gen{tag}_Inner", "x", zw, IX0, HALL_X, COURT, BASE_2F - 0.4, [(-60.0, -56.0, 0.0, DOOR)], group="Base")
    wall(f"Gen{tag}_Front", "z", HALL_X, zr[0], zr[1], COURT, BASE_2F - 0.4, [((zr[0] + zr[1]) / 2 - 1.5,
                                                                             (zr[0] + zr[1]) / 2 + 1.5, 0.0, DOOR)],
         group="Base")
    gz = (zr[0] + zr[1]) / 2
    box(f"Gen{tag}_Generator", (-60.5, 1.5, gz), (5.0, 3.0, 4.0), "cover", "Base")
# flag room: open to the hall between the generator rooms; four chippable columns [S sketch]
for i, (x, z) in enumerate(((-60.0, -1.5), (-60.0, 3.0), (-54.5, -1.5), (-54.5, 3.0))):
    box(f"FlagRoom_Column_{i}", (x, BASE_2F / 2, z), (1.2, BASE_2F, 1.2), "wall", "Base")
SLOPES["Base_Stairs_GF2F"] = ramp("Base_Stairs_GF2F", ((STAIR1[0] + STAIR1[1]) / 2, COURT, STAIR1[3]),
                                  ((STAIR1[0] + STAIR1[1]) / 2, BASE_2F, STAIR1[2]), 2.6, group="Base")
SLOPES["Base_Stairs_2FRoof"] = ramp("Base_Stairs_2FRoof", ((STAIR2[0] + STAIR2[1]) / 2, BASE_2F, STAIR2[3]),
                                    ((STAIR2[0] + STAIR2[1]) / 2, BASE_ROOF, STAIR2[2]), 2.6, group="Base")
for i, (x0, z0, x1, z1) in enumerate(((ATRIUM[0], ATRIUM[2], ATRIUM[1], ATRIUM[2]),
                                      (ATRIUM[0], ATRIUM[3], ATRIUM[1], ATRIUM[3]),
                                      (ATRIUM[1], ATRIUM[2], ATRIUM[1], ATRIUM[3]),
                                      (ATRIUM[0], ATRIUM[2], ATRIUM[0], ATRIUM[3]))):
    parapet(f"Base_AtriumRail_{i}", x0, z0, x1, z1, BASE_2F, group="Base")
parapet("Base_Stair1Rail", STAIR1[0], STAIR1[2], STAIR1[0], STAIR1[3], BASE_2F, group="Base")
# 2F turret nests behind the east windows (shutters in H2) [S]
box("Base_2F_Cover_N", (-44.0, BASE_2F + 0.6, -9.0), (1.0, 1.2, 4.0), "cover", "Base")
box("Base_2F_Cover_S", (-44.0, BASE_2F + 0.6, 9.0), (1.0, 1.2, 4.0), "cover", "Base")
# roof parapets, open where the wheel bridge leaves (z -0.75..2.25)
parapet("Base_Roof_Rail_N", BX0, BZ0, BX1, BZ0, BASE_ROOF, group="Base")
parapet("Base_Roof_Rail_S", BX0, BZ1, BX1, BZ1, BASE_ROOF, group="Base")
parapet("Base_Roof_Rail_W", BX0, BZ0, BX0, BZ1, BASE_ROOF, group="Base")
parapet("Base_Roof_Rail_E1", BX1, BZ0, BX1, -0.75, BASE_ROOF, group="Base")
parapet("Base_Roof_Rail_E2", BX1, 2.25, BX1, BZ1, BASE_ROOF, group="Base")
box("Base_Roof_Vent", (-58.0, BASE_ROOF + 1.0, 8.0), (4.0, 2.0, 3.0), "cover", "Base")

# =========================================================================================
# 5. WIND TURBINE ("the Wheel") - N-S housing slot x -23.5..-14, hub at y 12. The ring and
#    blades are visual (static); the hub deck holds the power weapon. Reached by:
#    (a) the Wheel Bridge from the base roof + a 3 m jump, (b) the Pin Ramp on the east side +
#    a 3.4 m jump (the pin-lowered bridge in H2) [S routes, E geometry]
# =========================================================================================
HUB = (-18.7, BASE_ROOF, 0.75)
WHEEL_R = 13.5
HX_W, HX_E = -23.5, -14.0   # housing wall centres
for tag, x in (("W", HX_W), ("E", HX_E)):
    wall(f"Housing_{tag}", "z", x, -20.5, 20.0, COURT, 3.0, [(-13.0, -9.0, 0.0, 3.0), (9.0, 13.0, 0.0, 3.0)],
         group="Wheel", mat="wall", t=1.0)
# hub deck and its pylons
slab("Hub_Deck", -22.0, -15.4, HUB[2] - 2.0, HUB[2] + 2.0, BASE_ROOF, 1.0, "catwalk", "Wheel")
for tag, x in (("W", HX_W), ("E", HX_E)):
    box(f"Hub_Pylon_{tag}", (x, 5.25, HUB[2]), (1.2, 10.5, 1.2), "wall", "Wheel")
box("Hub_Axle", (HUB[0], BASE_ROOF - 1.5, HUB[2]), (9.5, 1.0, 1.0), "wall", "Wheel", collide=False)
# Wheel Bridge: base roof east edge -> 3 m short of the hub deck (rockets on it) [S]
BRIDGE_END = -25.0
slab("WheelBridge_Deck", BX1, BRIDGE_END, HUB[2] - 1.5, HUB[2] + 1.5, BASE_ROOF, 0.6, "catwalk", "Wheel")
for z in (HUB[2] - 1.35, HUB[2] + 1.35):
    box("WheelBridge_Rail", ((BX1 + BRIDGE_END) / 2, BASE_ROOF + 0.5, z), (BRIDGE_END - BX1, 1.0, 0.3), "wall",
        "Wheel")
for i, x in enumerate((-36.0, -29.5)):
    box(f"WheelBridge_Pillar_{i}", (x, (BASE_ROOF - 0.6) / 2, HUB[2]), (1.2, BASE_ROOF - 0.6, 1.2), "wall", "Wheel")
# Pin Ramp: east courtyard up to the Pin Landing; the lowered bridge would span the gap to the hub
PIN = (-12.0, -9.0, HUB[2] - 4.0, HUB[2] + 0.25)
slab("Pin_Landing", PIN[0], PIN[1], PIN[2], PIN[3], BASE_ROOF, 0.6, "catwalk", "Wheel")
SLOPES["Pin_Ramp"] = ramp("Pin_Ramp", (-10.5, COURT, 21.0), (-10.5, BASE_ROOF, PIN[3]), 3.0, group="Wheel",
                          rails=1.0)
box("Pin_Landing_Pillar", (-10.5, (BASE_ROOF - 0.6) / 2, PIN[2] + 1.0), (1.2, BASE_ROOF - 0.6, 1.2), "wall", "Wheel")
parapet("Pin_Landing_Rail_N", PIN[0], PIN[2], PIN[1], PIN[2], BASE_ROOF, group="Wheel")
parapet("Pin_Landing_Rail_E", PIN[1], PIN[2], PIN[1], PIN[3] - 3.0, BASE_ROOF, group="Wheel")
# ring + three blades (visual only, in the YZ plane through the hub)
SEG = 28
for i in range(SEG):
    th = 2 * math.pi * (i + 0.5) / SEG
    c = (HUB[0], HUB[1] + WHEEL_R * math.sin(th), HUB[2] + WHEEL_R * math.cos(th))
    seg_len = 2 * WHEEL_R * math.sin(math.pi / SEG) + 0.2
    box(f"Wheel_Ring_{i:02d}", c, (1.6, 1.0, seg_len), "wheel", "Wheel", pitch=90.0 - math.degrees(th), collide=False)
for i, phi in enumerate((90.0, 210.0, 330.0)):
    r0, L = 2.2, WHEEL_R - 3.0
    c = (HUB[0], HUB[1] + (r0 + L / 2) * math.sin(math.radians(phi)), HUB[2] + (r0 + L / 2) * math.cos(math.radians(phi)))
    box(f"Wheel_Blade_{i}", c, (0.6, 2.6, L), "wheel", "Wheel", pitch=180.0 - phi, collide=False)

# =========================================================================================
# 6. CONTROL TOWER (north, the sketch's "3 story sniper tower") - GF 0 / 2F 4.5 / roof 9
#    Each stair starts 1.6 m and stops 2.4 m from its end walls, so both ends meet open floor.
# =========================================================================================
TX0, TX1, TZ0, TZ1 = -28.3, -14.3, -30.1, -21.6
JX0, JX1, JZ0, JZ1 = TX0 + WALL_T, TX1 - WALL_T, TZ0 + WALL_T, TZ1 - WALL_T
T_2F, T_ROOF = 4.5, 9.0
T_LAND = 2.4
T_FOOT = 1.6
T_ST1 = (JZ0, JZ0 + 2.6)    # GF -> 2F along x (west -> east), north strip
T_ST2 = (JZ1 - 2.6, JZ1)    # 2F -> roof along x (east -> west), south strip
floor_holes("Tower_2F", JX0, JX1, JZ0, JZ1, T_2F, [(JX0 + T_FOOT, JX1 - T_LAND, *T_ST1)], group="ControlTower")
floor_holes("Tower_Roof", TX0, TX1, TZ0, TZ1, T_ROOF, [(JX0 + T_LAND, JX1 - T_FOOT, *T_ST2)], group="ControlTower")
TWIN = (T_2F + 1.4, T_2F + 3.4)
wall("Tower_W", "z", TX0 + WALL_T / 2, TZ0, TZ1, COURT, T_ROOF - 0.4, [(-26.0, -23.0, 0.0, DOOR), (-29.0, -27.0, *TWIN)],
     group="ControlTower")
wall("Tower_E", "z", TX1 - WALL_T / 2, TZ0, TZ1, COURT, T_ROOF - 0.4, [(-26.5, -23.5, 0.0, DOOR), (-29.0, -27.0, *TWIN)],
     group="ControlTower")
wall("Tower_S", "x", TZ1 - WALL_T / 2, TX0 + WALL_T, TX1 - WALL_T, COURT, T_ROOF - 0.4, [(-21.5, -18.0, 0.0, DOOR), (-27.0, -16.0, *TWIN)],
     group="ControlTower")
wall("Tower_N", "x", TZ0 + WALL_T / 2, TX0 + WALL_T, TX1 - WALL_T, COURT, T_ROOF - 0.4, [], group="ControlTower")
SLOPES["Tower_Stairs_GF2F"] = ramp("Tower_Stairs_GF2F", (JX0 + T_FOOT, COURT, sum(T_ST1) / 2),
                                   (JX1 - T_LAND, T_2F, sum(T_ST1) / 2), 2.6, group="ControlTower")
SLOPES["Tower_Stairs_2FRoof"] = ramp("Tower_Stairs_2FRoof", (JX1 - T_FOOT, T_2F, sum(T_ST2) / 2),
                                      (JX0 + T_LAND, T_ROOF, sum(T_ST2) / 2), 2.6, group="ControlTower")
parapet("Tower_2F_StairRail", JX0 + T_FOOT, T_ST1[1], JX1 - T_LAND, T_ST1[1], T_2F, group="ControlTower")
parapet("Tower_Roof_Rail_N", TX0, TZ0, TX1, TZ0, T_ROOF, group="ControlTower")
parapet("Tower_Roof_Rail_W", TX0, TZ0, TX0, TZ1, T_ROOF, group="ControlTower")
parapet("Tower_Roof_Rail_E", TX1, TZ0, TX1, TZ1, T_ROOF, group="ControlTower")
parapet("Tower_Roof_Rail_S", TX1 - 0.5, TZ1, TX1, TZ1, T_ROOF, group="ControlTower")
parapet("Tower_Roof_StairRail", JX0 + T_LAND, T_ST2[0], JX1 - T_FOOT, T_ST2[0], T_ROOF, group="ControlTower")

# =========================================================================================
# 7. PUMP HOUSE (south building on the MCC map; name mine) - one storey, roof perch at 4.5
# =========================================================================================
PX0, PX1, PZ0, PZ1 = -22.0, -11.0, 25.3, 37.2
slab("PumpHouse_Roof", PX0, PX1, PZ0, PZ1, 4.5, 0.4, "floor", "PumpHouse")
wall("PumpHouse_N", "x", PZ0 + WALL_T / 2, PX0 + WALL_T, PX1 - WALL_T, COURT, 4.5 - 0.4, [(-20.5, -17.5, 0.0, DOOR), (-15.5, -12.5, 0.0, DOOR)],
     group="PumpHouse")
wall("PumpHouse_S", "x", PZ1 - WALL_T / 2, PX0 + WALL_T, PX1 - WALL_T, COURT, 4.5 - 0.4, [], group="PumpHouse")
wall("PumpHouse_W", "z", PX0 + WALL_T / 2, PZ0, PZ1, COURT, 4.5 - 0.4, [(29.0, 32.0, 1.2, 2.6)], group="PumpHouse")
wall("PumpHouse_E", "z", PX1 - WALL_T / 2, PZ0, PZ1, COURT, 4.5 - 0.4, [(29.0, 32.0, 1.2, 2.6)], group="PumpHouse")
box("PumpHouse_Divider", (-16.5, 2.0, 32.0), (0.4, 4.0, 10.0), "wall", "PumpHouse")
SLOPES["PumpHouse_ExtRamp"] = ramp("PumpHouse_ExtRamp", (-9.5, COURT, 26.5), (-9.5, 4.5, 35.0), 3.0, group="PumpHouse")
slab("PumpHouse_RampLanding", PX1, PX1 + 3.0, 35.0, PZ1, 4.5, 0.4, "floor", "PumpHouse")
parapet("PumpHouse_Roof_Rail_N", PX0, PZ0, PX1, PZ0, 4.5, group="PumpHouse")
parapet("PumpHouse_Roof_Rail_W", PX0, PZ0, PX0, PZ1, 4.5, group="PumpHouse")

# =========================================================================================
# 8. BEACH - jetty ruin into the sea, arch ruin by the gate, Camp Froman overhang (south)
# =========================================================================================
JET0, JET1 = px(497, 307), px(565, 307)
box("Jetty_Ruin", ((JET0[0] + JET1[0]) / 2, -1.0, JET0[1]), (JET1[0] - JET0[0], 2.6, 1.6), "seawall", "Beach")
box("Jetty_Pillar", (JET0[0], 1.0, JET0[1]), (2.6, 6.0, 2.6), "seawall", "Beach")
ax, az0 = px(430, 253)
_, az1 = px(430, 288)
wall("Arch_Ruin", "z", ax, az0, az1, BEACH - 0.5, 3.0, [(-19.5, -16.0, BEACH - 0.5, 1.2)], group="Beach",
     mat="seawall", t=2.0)
CF = px(512, 518)  # Camp Froman nook against the south cliff [S name, E place]
slab("CampFroman_Overhang", CF[0] - 4.0, CF[0] + 6.0, CF[1] - 2.0, CF[1] + 6.0, 2.0, 1.5, "oob", "Beach")
box("CampFroman_Rock", (CF[0] + 5.0, 0.0, CF[1] - 1.0), (2.0, 4.0, 2.0), "oob", "Beach", yaw=20.0)
box("CampFroman_Crates", (CF[0] + 2.0, BEACH + 0.5, CF[1] + 3.5), (2.0, 1.0, 1.0), "cover", "Beach")

# =========================================================================================
# 9. COVER - rocks (MCC blobs), base-front blocks, east-courtyard bunker [E]
# =========================================================================================
ROCKS = [  # (MCC px, size m, yaw)
    ((155, 247), (2.4, 1.8, 2.0), 20), ((192, 225), (3.0, 2.2, 2.4), -10), ((215, 239), (2.2, 1.6, 2.2), 35),
    ((233, 258), (2.6, 2.0, 2.0), 0), ((107, 492), (2.4, 1.8, 2.6), 15), ((152, 495), (2.0, 1.6, 2.0), -25),
    ((162, 512), (2.6, 2.2, 2.4), 10), ((205, 465), (2.8, 2.0, 2.4), 30), ((200, 485), (2.2, 1.6, 2.0), -5),
    ((247, 510), (2.4, 2.0, 2.4), 40), ((327, 470), (2.0, 1.4, 2.0), 0), ((338, 480), (1.8, 1.2, 1.8), 25),
    ((320, 260), (2.2, 1.6, 2.0), 15),
]
for i, (p, size, yaw) in enumerate(ROCKS):
    x, z = px(*p)
    box(f"Rock_Court_{i:02d}", (x, size[1] / 2, z), size, "cover", "Cover", yaw=yaw)
BEACH_ROCKS = [((410, 210), 0), ((430, 375), 20), ((443, 392), -15), ((470, 440), 30), ((503, 367), 10),
               ((523, 395), -30), ((498, 470), 5), ((470, 175), 45)]
for i, (p, yaw) in enumerate(BEACH_ROCKS):
    x, z = px(*p)
    box(f"Rock_Beach_{i:02d}", (x, BEACH + 0.8, z), (2.4, 1.6, 2.0), "cover", "Cover", yaw=yaw)
x, z = px(351, 345)
prism("Court_Bunker", x, z, 2.2, COURT - 0.5, 1.4, "cover", "Cover", sides=8)
COVER = [
    ("BaseFront_Block_N", (-37.5, 0.6, -12.5), (6.0, 1.2, 1.0), 0),   # H2: turret blocks
    ("BaseFront_Block_NL", (-34.5, 0.6, -10.5), (1.0, 1.2, 4.0), 0),
    ("BaseFront_Block_S", (-37.5, 0.6, 12.0), (6.0, 1.2, 1.0), 0),
    ("BaseFront_Block_SL", (-34.5, 0.6, 10.0), (1.0, 1.2, 4.0), 0),
    ("BaseFront_Steps_Block", (-38.0, 0.6, -4.0), (2.0, 1.2, 2.0), 0),
    ("Court_Crates_N", (-6.0, 0.8, -20.0), (3.0, 1.6, 2.0), 20),
    ("Court_Crates_S", (-2.0, 0.8, 16.0), (2.0, 1.6, 3.0), -10),
    ("Court_Barrier_Gate", (0.0, 0.6, -9.0), (4.0, 1.2, 1.0), 35),
]
for n, c, size, yaw in COVER:
    box(n, c, size, "cover", "Cover", yaw=yaw)

# =========================================================================================
# 10. MARKERS  (y = floor top; the Godot scenes lift pickups/spawns as needed)
# =========================================================================================
# Red = defenders (base, west, facing east); Blue = attackers (beach, east, facing west) [E]
RED = [((-45.0, COURT, -5.0), -90), ((-45.0, COURT, 6.0), -90), ((-55.0, BASE_2F, -9.0), -90),
       ((-55.0, BASE_2F, 10.0), -90), ((-36.0, COURT, -7.0), -90), ((-36.0, COURT, 7.0), -90)]
BLUE = [(px(470, 200), 90), (px(460, 250), 90), (px(455, 300), 90), (px(450, 370), 90), (px(470, 420), 90),
        (px(500, 485), 90)]
for i, (p, yaw) in enumerate(RED):
    marker(f"SPAWN_Red_{i}", p, yaw=yaw)
for i, (p, yaw) in enumerate(BLUE):
    marker(f"SPAWN_Blue_{i}", (p[0], BEACH, p[1]), yaw=yaw)
_wm = SEAWALL.at(36.0)
FFA = [(-46.0, COURT, 0.5), (-20.0, T_2F, -25.5), (-19.5, COURT, 30.0), (*px(170, 240)[:1], COURT, px(170, 240)[1]),
       (*px(135, 505)[:1], COURT, px(135, 505)[1]), (*px(100, 505)[:1], COURT, px(100, 505)[1]),
       (*px(330, 300)[:1], COURT, px(330, 300)[1]), (*px(330, 440)[:1], COURT, px(330, 440)[1]),
       (_wm.x, WALL_TOP, _wm.y), (*px(450, 180)[:1], BEACH, px(450, 180)[1]),
       (*px(460, 340)[:1], BEACH, px(460, 340)[1]), (-18.7, COURT, -12.0)]
for i, p in enumerate(FFA):
    marker(f"SPAWN_FFA_{i:02d}", p)

TOWER_ROOF_SPOT = (-19.0, T_ROOF, -26.5)
WEAPONS = [  # Long Colt five-gun mapping of Zanzibar's placements (see zanzibar_spec.md section 6)
    ("WPN_DirectedEnergyRifle_WheelBridge", (-31.0, BASE_ROOF, HUB[2])),     # H2: rockets on the bridge [S]
    ("WPN_Longsword_Hub", HUB),                                            # H2: energy sword in the hub [S]
    ("WPN_CombatShotgun_GeneratorN", (-56.0, COURT, -9.0)),                  # H2: shotgun in the base [E]
    ("WPN_MarksmanCarbine_ControlTower", TOWER_ROOF_SPOT),                   # H2: sniper tower [S sketch]
    ("WPN_MarksmanCarbine_SouthBastion", (SOUTH_BASTION[0], WALL_TOP, SOUTH_BASTION[1])),
    ("WPN_StandardIssueRifle_CampFroman", (CF[0] + 1.0, BEACH, CF[1] + 2.0)),  # screenshot shows a BR there [S]
    ("WPN_StandardIssueRifle_BeachNorth", (px(470, 185)[0], BEACH, px(470, 185)[1])),
    ("WPN_StandardIssueRifle_Base2F", (-48.0, BASE_2F, -9.0)),
    ("WPN_StandardIssueRifle_Courtyard", (px(330, 400)[0], COURT, px(330, 400)[1])),
    ("WPN_GravityHammer_PumpHouse", (-19.0, COURT, 33.0)),                    # Long Colt: hammer (no H2 equivalent)
    ("WPN_ServicePistol_FlagRoom", (-57.0, COURT, 4.0)),
    ("WPN_ServicePistol_Gate", (GATE_X.x + _gdir.x * 4.0, COURT, GATE_X.y + _gdir.y * 4.0)),
]
for n, p in WEAPONS:
    marker(n, p)
marker("PWR_Overshield_UnderWheel", (HUB[0], COURT, HUB[2]))  # H2 power-up, no Long Colt equivalent yet
marker("FLAG_Defender_Base", FLAG)                             # 1-Flag CTF / Assault plant: the flag room [S]
marker("GATE_Switch", (GATE_X.x - _gdir.x * 9.0, BEACH, GATE_X.y - _gdir.y * 9.0))  # either team opens it [S]
marker("GATE_Leaf", (GATE_X.x, COURT, GATE_X.y))
marker("TURRET_Base_N", (-42.0, BASE_2F, -8.0), yaw=-90)       # H2 machine-gun turrets [S]
marker("TURRET_Base_S", (-42.0, BASE_2F, 9.0), yaw=-90)
marker("PIN_Bridge", (-13.7, BASE_ROOF, HUB[2]))
for n, p in (("VEH_GaussWarthog_Beach", px(465, 255)), ("VEH_Ghost_Beach", px(470, 280)),
             ("VEH_ChainWarthog_Base", (-33.0, -18.0)), ("VEH_Ghost_Base", (-33.0, 18.0))):
    marker(n, (p[0], BEACH if "Beach" in n else COURT, p[1]))
CALLOUTS = {
    "Base": (-46.0, COURT, 0.5), "FlagRoom": FLAG, "Wheel": HUB, "WheelBridge": (-33.0, BASE_ROOF, HUB[2]),
    "ControlTower": (-19.8, T_ROOF, -26.0), "PumpHouse": (-16.5, COURT, 30.0), "Gate": (GATE_X.x, COURT, GATE_X.y),
    "SeaWall": (_wm.x, WALL_TOP, _wm.y), "Beach": (px(470, 330)[0], BEACH, px(470, 330)[1]),
    "CampFroman": (CF[0], BEACH, CF[1]), "RockGarden": (px(160, 500)[0], COURT, px(160, 500)[1]),
    "Courtyard": (px(330, 400)[0], COURT, px(330, 400)[1]),
}
for n, p in CALLOUTS.items():
    marker("CALLOUT_" + n, p, group="Callouts")

# =========================================================================================
# report slopes, save, export
# =========================================================================================
print("\n== Zanzibar greybox: slopes (deg; floor_max_angle 50) ==")
for n, sl in SLOPES.items():
    flag = "  !! too steep" if sl > 32 else ""
    print(f"  {n:24s} {sl:5.1f}{flag}")
print(f"  gate crossing s={GATE_S:.1f} of {SEAWALL.length:.1f} m at ({GATE_X.x:.1f}, {GATE_X.y:.1f}), gap {GAP[0]:.1f}..{GAP[1]:.1f}")
def _clean_and_join_by_material():
    mesh_obs = [ob for ob in bpy.data.objects if ob.type == "MESH"]
    by_key = {}
    for ob in mesh_obs:
        mat = ob.data.materials[0].name if ob.data.materials else "none"
        is_col = ob.name.endswith("-col")
        by_key.setdefault((mat, is_col), []).append(ob)

    for (mat_name, is_col), obs in by_key.items():
        bpy.ops.object.select_all(action="DESELECT")
        for ob in obs:
            ob.select_set(True)
        bpy.context.view_layer.objects.active = obs[0]
        if len(obs) > 1:
            bpy.ops.object.join()
        joined = bpy.context.view_layer.objects.active
        col_suffix = "-col" if is_col else ""
        joined.name = f"Zanzibar_{mat_name[4:].capitalize()}{'_col' if is_col else '_vis'}{col_suffix}"

        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.remove_doubles(threshold=0.002)
        bpy.ops.mesh.dissolve_degenerate()
        bpy.ops.object.mode_set(mode="OBJECT")

_clean_and_join_by_material()

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
LEVEL_TSCN = _arg("--level-tscn", "scenes/levels/zanzibar.tscn")
MAIN_TSCN = _arg("--main-tscn", "scenes/main/main_zanzibar.tscn")
ARENA_TSCN = _arg("--arena-tscn", "scenes/main/arena_zanzibar.tscn")


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
    "[gd_scene load_steps=5 format=3]",
    "",
    '[ext_resource type="PackedScene" path="res://assets/models/environment/zanzibar_greybox.glb" id="1_glb"]',
    '[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="3_kill"]',
    '[ext_resource type="Script" path="res://scripts/levels/level_materials.gd" id="4_mat"]',
    "",
    '[sub_resource type="BoxShape3D" id="Shape_Kill"]',
    "size = Vector3(400, 2, 400)",
    "",
    "; GENERATED by tools/zanzibar/build_zanzibar.py - edit the script, not this file.",
    '[node name="Zanzibar" type="Node3D"]',
    "",
    '[node name="LevelMaterials" type="Node" parent="."]',
    'script = ExtResource("4_mat")',
    "",
    '[node name="Greybox" parent="." instance=ExtResource("1_glb")]',
    "",
    "; below the beach (-2), the surf (-2.3) and the sea plane (-2.6): walking off the surf drowns you",
    '[node name="KillVolume" type="Area3D" parent="."]',
    "transform = " + _xf((0.0, -10.0, 0.0)),
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

# Grenade pickups (GrenadePickup: 2 each, 30 s respawn) in the main and arena scenes only, no .glb
# marker. Metres. Each sits by a roam point on flat floor with a standing capsule's room, clear of
# weapon pads, spawns and flag bases (tests/grenade_spawns_self_test.gd checks all of that).
# Frags on the attackers' beach and in the base hall, stickies under the wheel, in the courtyard
# and in the control tower.
GRENADES = [
    ("Frags_BeachNorth", "frag", (26.0, BEACH, -34.5)), ("Frags_BeachMid", "frag", (24.5, BEACH, -2.25)),
    ("Frags_BaseHall", "frag", (-44.5, COURT, 0.5)), ("Stickies_UnderWheel", "sticky", (-18.75, COURT, -5.0)),
    ("Stickies_Courtyard", "sticky", (-4.0, COURT, 11.0)), ("Stickies_ControlTower2F", "sticky", (-18.5, T_2F, -25.5)),
]

GRENADE_RES = {"frag": "31_frag", "sticky": "32_sticky"}
GRENADE_EXT = ['[ext_resource type="PackedScene" path="res://scenes/pickups/grenade_pickup.tscn" id="30_grenades"]',
               '[ext_resource type="Resource" path="res://resources/weapons/frag_grenade.tres" id="31_frag"]',
               '[ext_resource type="Resource" path="res://resources/weapons/sticky_grenade.tres" id="32_sticky"]']


def _grenade_nodes(out):
    for n, kind, p in GRENADES:
        out += [f'[node name="{n}" parent="." instance=ExtResource("30_grenades")]', "transform = " + _xf(p),
                f'grenade = ExtResource("{GRENADE_RES[kind]}")', ""]


GUN = {"MarksmanCarbine": ("marksman_carbine", "2_carbine", 0.0), "CombatShotgun": ("combat_shotgun", "3_shotgun", 90.0),
       "DirectedEnergyRifle": ("directed_energy_rifle", "4_energy", 90.0),
       "StandardIssueRifle": ("standard_issue_rifle", "5_rifle", 0.0), "ServicePistol": ("service_pistol", "6_pistol", 0.0),
       "Longsword": ("longsword", "20_sword", 120.0), "GravityHammer": ("gravity_hammer", "21_hammer", 120.0)}
SUN = ["[node name=\"Sun\" type=\"DirectionalLight3D\" parent=\".\"]",
       # late-afternoon sun from over the sea (east-south-east), long shadows across the courtyard
       "transform = Transform3D(-0.5, 0.612372, -0.612372, 0, 0.707107, 0.707107, 0.866025, 0.353553, -0.353553, 0, 40, 0)",
       "light_color = Color(1, 0.9, 0.78, 1)", "light_energy = 1.2", "shadow_enabled = true",
       "shadow_bias = 0.04", "shadow_normal_bias = 2.0", "directional_shadow_mode = 2",
       "directional_shadow_split_1 = 0.07", "directional_shadow_split_2 = 0.2", "directional_shadow_split_3 = 0.5",
       "directional_shadow_blend_splits = true", "directional_shadow_fade_start = 0.85",
       "directional_shadow_max_distance = 220.0", "light_bake_mode = 0", ""]
LIGHTMAP = []


def _pickups():
    out = []
    for n, p in WEAPONS:
        f, rid, respawn = GUN[n.split("_")[1]]
        out += [f'[node name="{n[4:]}" parent="." instance=ExtResource("8_pickup")]', "transform = " + _xf(p),
                f'weapon_scene = ExtResource("{rid}")'] + ([f"respawn_delay = {respawn}"] if respawn else []) + [""]
    return out


first = [sp for sp in _spawn_list() if sp[0].startswith("SPAWN_Blue")][0]
ml = ["[gd_scene load_steps=10 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/zanzibar.tscn" id="1_level"]']
for f, rid, _ in GUN.values():
    ml.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
ml += GRENADE_EXT
ml += ['[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
       '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
       '[ext_resource type="Environment" path="res://resources/environments/outdoor_environment.tres" id="9_env"]',
       "", "; GENERATED by tools/zanzibar/build_zanzibar.py - offline balance testbed (no bots). LightmapGI bakes sun bounce.",
       '[node name="MainZanzibar" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', ""]
ml += SUN + ['[node name="Zanzibar" parent="." instance=ExtResource("1_level")]', ""] + LIGHTMAP
ml += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
ml += _pickups()
_grenade_nodes(ml)
open(MAIN_TSCN, "w").write("\n".join(ml))

# Arena (Bot Arena + LAN): same pickups as main_zanzibar, plus bots, runtime navmesh, roam points,
# NetMatch before SpawnManager (its _ready configures SpawnManager), like arena_headlong.tscn.
# No nav links: bots cannot make the jumps onto the hub deck, so they never reach the Hub shotgun.
ROAM = [
    ("FlagRoom", (-57.0, COURT, 0.75), 1.0), ("BaseHall", (-46.0, COURT, 0.5), 1.0),
    ("GeneratorN", (-56.0, COURT, -9.0), 0.5), ("GeneratorS", (-56.0, COURT, 10.0), 0.5),
    ("Base2F", (-48.0, BASE_2F, -9.0), 1.0), ("BaseRoof", (-55.0, BASE_ROOF, -6.0), 1.0),
    ("WheelBridge", (-33.0, BASE_ROOF, HUB[2]), 1.0), ("UnderWheel", (-18.7, COURT, -5.0), 1.5),
    ("BaseFront", (-35.0, COURT, 0.5), 1.0), ("ControlTowerGF", (-19.8, COURT, -25.0), 0.5),
    ("ControlTower2F", (-20.0, T_2F, -25.5), 1.0), ("ControlTowerRoof", TOWER_ROOF_SPOT, 1.5),
    ("PumpHouse", (-19.0, COURT, 33.0), 0.5), ("PumpHouseRoof", (-16.5, 4.5, 30.0), 1.0),
    ("PinLanding", (-10.5, BASE_ROOF, HUB[2] - 2.0), 1.0),
    ("RockGarden", (px(160, 500)[0], COURT, px(160, 500)[1]), 1.0),
    ("NorthCourt", (px(190, 250)[0], COURT, px(190, 250)[1]), 1.0),
    ("EastCourt", (px(330, 300)[0], COURT, px(330, 300)[1]), 1.0),
    ("Courtyard", (px(330, 400)[0], COURT, px(330, 400)[1]), 1.0),
    ("Gate", (GATE_X.x + _gdir.x * 4.0, COURT, GATE_X.y + _gdir.y * 4.0), 1.5),
    ("SeaWall", (_wm.x, WALL_TOP, _wm.y), 1.0), ("SouthBastion", (SOUTH_BASTION[0], WALL_TOP, SOUTH_BASTION[1]), 1.0),
    ("BeachNorth", (px(470, 190)[0], BEACH, px(470, 190)[1]), 1.0),
    ("BeachMid", (px(460, 340)[0], BEACH, px(460, 340)[1]), 1.0),
    ("CampFroman", (CF[0] + 1.0, BEACH, CF[1] + 2.0), 1.0),
]
al = ["[gd_scene load_steps=18 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/zanzibar.tscn" id="1_level"]',
      '[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
      '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
      '[ext_resource type="Environment" path="res://resources/environments/outdoor_environment.tres" id="9_env"]',
      '[ext_resource type="PackedScene" path="res://scenes/ai/bot.tscn" id="10_bot"]',
      '[ext_resource type="Script" path="res://scripts/ai/arena_events.gd" id="11_events"]',
      '[ext_resource type="Script" path="res://scripts/ai/arena_navigation.gd" id="12_nav"]',
      '[ext_resource type="Script" path="res://scripts/net/net_match.gd" id="13_net"]',
      '[ext_resource type="Script" path="res://scripts/ai/spawn_manager.gd" id="14_spawns"]',
      '[ext_resource type="Resource" path="res://resources/ai/bot_difficulty_normal.tres" id="15_diff"]']
for f, rid, _ in GUN.values():
    al.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
al += GRENADE_EXT
al += ["", "; GENERATED by tools/zanzibar/build_zanzibar.py - arena mode (Bot Arena / LAN) on Zanzibar.",
       '[node name="ArenaZanzibar" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', ""]
al += SUN + ['[node name="ArenaEvents" type="Node" parent="."]', 'script = ExtResource("11_events")', "",
             '[node name="Zanzibar" parent="." instance=ExtResource("1_level")]', ""] + LIGHTMAP
al += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
al += _pickups()
_grenade_nodes(al)
al += ['[node name="Navigation" type="NavigationRegion3D" parent="."]', 'script = ExtResource("12_nav")',
       'geometry_root = NodePath("../Zanzibar")', "",
       '[node name="NavPoints" type="Node3D" parent="."]', ""]
for n, p, w in ROAM:
    al += [f'[node name="{n}" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]',
           "transform = " + _xf((p[0], p[1] + 0.05, p[2])), f"metadata/weight = {w:g}", f'metadata/callout = "{n}"', ""]
al += ['[node name="NetMatch" type="Node" parent="."]', 'script = ExtResource("13_net")', "",
       '[node name="SpawnManager" type="Node" parent="."]', 'script = ExtResource("14_spawns")',
       'bot_scene = ExtResource("10_bot")', "bot_count = 3", 'difficulty = ExtResource("15_diff")',
       'spawn_roots = Array[NodePath]([NodePath("../Zanzibar/Spawns")])', ""]
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
    hide = [o for o in bpy.data.objects if o.name.startswith(("OOB_", "Wheel_", "CampFroman_Overhang"))]

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

    # overhead: north up (Blender +Y = Godot -Z = north); frame centred on the playable area
    shoot("zanzibar_overhead", (0, 0, 150), (0, 0, 0), ortho=145, res=(1600, 1200), hidden=hide)
    # from the sea looking west at the wall, gate and wheel
    shoot("zanzibar_persp_from_sea", (75, 10, 32), (68, 0, 95), res=(1920, 1080))
    # from above the rock garden looking north-east at the base, bridge and wheel
    shoot("zanzibar_persp_from_courtyard", (-30, -50, 35), (62, 0, 15), res=(1920, 1080))
    print("  previews in", PREVIEWS)
