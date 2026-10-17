"""Build the Lockout (Halo 2, 2004) greybox (.glb + .blend), its Godot scenes and preview renders
with headless Blender. Replaces the v1 box blockout (tools/lockout/archive_v1/).

Usage (from the repo root):
  blender -b --factory-startup --python tools/lockout/build_lockout_greybox.py -- [--no-render]

ALL geometry is ESTIMATED. The plan is traced from the MCC Lockout loading-screen map, which draws
two floors side by side: the left drawing is the Top Mid level, the right drawing is the floor
below it, offset 541 px to the right (the lift, the north-west ramp and the south-east block line
up exactly at that offset). Heights come from Bungie's design doc ("north area attached by a bridge
down below, reached on top by jumping; west area attached on the bottom level, reached by jumping
across; south-east area three levels, access to the centre top and bottom") and the screenshots.
See lockout_spec.md for sources, callouts and confidence.

Every plan coordinate below is in MCC-map PIXELS of the left (Top Mid level) drawing; the right
drawing's pixels were shifted by -541 first. px() turns them into Godot metres:
  x = (px - 279) * 0.12   (east)      z = (py - 390) * 0.12   (south; north = -Z = top of the map)
so the Top Mid centre light (279, 390) is the origin. Heights are metres, Godot +Y up.

Naming for the Godot importer (same as the Headlong greybox):
  *-col      mesh + StaticBody3D with trimesh collision (World layer 1)
  no suffix  visual only (snow far below, Top Mid light panel)
  Empties    SPAWN_*, WPN_*, LIFT_*, CALLOUT_* markers; the .tscn files below are written from them.
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


GLB = _arg("--glb", "assets/models/environment/lockout_greybox.glb")
BLEND = _arg("--blend", "tools/lockout/lockout_greybox.blend")
PREVIEWS = _arg("--previews", "tools/lockout/previews")
RENDER = "--no-render" not in argv and PREVIEWS != ""

# Player reference (scripts/player/player.gd): 2.1 m body, capsule r 0.35, jump_height 2.2,
# stand_speed 7.5, gravity 22 -> ~0.89 s airtime, ~6.7 m flat running jump. floor_max_angle 50.
PX_M = 0.12          # metres per MCC-map pixel (Top Mid deck 133 px -> 16 m)
OX, OY = 279, 390    # Top Mid centre light, in MCC pixels
LO = -3.0            # Library basement
B = 0.0              # bottom level: Bottom Mid, Green Hall, Sniper Alley, BR1, S1, lower lift
T = 4.5              # Top Mid level: Top Mid, BR2, S2, Library, NE annex
TOPLIFT = 5.0        # upper lift room (0.5 m above Top Mid, so the north gap jump works both ways)
ARM = 6.0            # Elbow loop corners
S3F = 8.5            # S3 (sniper room) and the S2 roof terrace
BR3 = 9.0            # BR tower roof
DOOR = 3.0
WALL_T = 0.5
ABYSS = -60.0        # snow floor far below (visual)
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


# ---- materials: flat matte, one per role (same language as the Headlong greybox) ----------
MATS = {
    "floor": "#b4b4b4",    # walkable floors and roofs
    "deck": "#9aa7b0",     # Top Mid deck (cold Forerunner grey-blue)
    "wall": "#6c6f73",
    "ramp": "#c0843a",     # anything sloped you can walk
    "catwalk": "#d1a420",  # grate bridge
    "cover": "#455a64",    # stasis pods, pillars, half walls
    "oob": "#4a4f57",      # cliff face and support pylons
    "lift": "#2e86c1",
    "light": "#e8f4ff",    # Top Mid centre light (emissive)
    "snow": "#e6ecf2",
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
        # every opening over this span is cut (a door and a window can stack in one wall)
        spans = [(y0, y1)]
        for o in sorted((o for o in openings if o[0] < mid < o[1]), key=lambda o: o[2]):
            last = spans.pop()
            spans += [(last[0], o[2]), (o[3], last[1])]
        for b0, b1 in spans:
            if any(abs(b1 - o[2]) < 0.005 for o in openings):
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
    Ends meet floors cleanly without over-length knife-edge penetration. rails > 0 adds side rails."""
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
            c = (a + b) / 2 + side * sgn * (width / 2 - 0.15) + normal * (rails / 2)
            box(f"{name}_Rail{tag}", tuple(c), (0.3, rails, length), "wall", group, yaw=yaw, pitch=pitch)
    return math.degrees(math.atan2(d.y, horiz))


def parapet(name, x0, z0, x1, z1, top, h=1.05, group="Buildings"):
    """1.05 m rail/parapet standing on a floor whose top is `top`, along a straight line."""
    d = Vector((x1 - x0, 0, z1 - z0))
    yaw = math.degrees(math.atan2(-d.x, -d.z))
    box(name, ((x0 + x1) / 2, top + 0.002 + h / 2, (z0 + z1) / 2), (0.3, h, d.length), "wall", group, yaw=yaw)


def marker(name, pos, group="Markers", yaw=0.0):
    ob = bpy.data.objects.new(_unique(name), None)
    ob.empty_display_type = "ARROWS"
    ob.empty_display_size = 1.0
    ob.matrix_world = Matrix.Translation(g2b(pos)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    coll(group).objects.link(ob)
    return ob

_glow = _mat["light"].node_tree.nodes["Principled BSDF"]
_glow.inputs["Emission Color"].default_value = hexcol(MATS["light"])
_glow.inputs["Emission Strength"].default_value = 3.0


# ---- MCC-pixel wrappers -------------------------------------------------------------------
def X(px):
    return (px - OX) * PX_M


def Z(py):
    return (py - OY) * PX_M


def P(px, py, y=0.0):
    return (X(px), y, Z(py))


def pslab(name, x0, x1, y0, y1, top, thick=0.5, mat="floor", group="Floors"):
    slab(name, X(x0), X(x1), Z(y0), Z(y1), top, thick, mat, group)


def pfloor(name, x0, x1, y0, y1, top, holes=(), thick=0.5, mat="floor", group="Floors"):
    """Floor with rectangular holes (stairwells, the lift shaft); everything in MCC pixels."""
    floor_holes(name, X(x0), X(x1), Z(y0), Z(y1), top,
                [(X(h[0]), X(h[1]), Z(h[2]), Z(h[3])) for h in holes], mat=mat, group=group, thick=thick)


def pwall(name, axis, fixed, a0, a1, y0, y1, openings=(), group="Walls", mat="wall"):
    """Straight wall centred on an outline. axis 'x' runs along X at py=fixed, 'z' runs along Z
    at px=fixed. openings: (a0, a1, y_bottom, y_top) with a0/a1 in pixels along the wall."""
    if axis == "x":
        conv, f = X, Z(fixed)
    else:
        conv, f = Z, X(fixed)
    wall(name, axis, f, conv(a0), conv(a1), y0, y1,
         [(conv(o[0]), conv(o[1]), o[2], o[3]) for o in openings], group=group, mat=mat)


def shell(name, x0, x1, y0, y1, bot, top, n=(), s=(), w=(), e=(), group="Walls"):
    """Four walls on the outline of a rectangle (pixels), bot..top metres, with openings per side."""
    pw = (WALL_T / 2) / PX_M
    pwall(name + "_N", "x", y0, x0 - pw, x1 + pw, bot, top, n, group)
    pwall(name + "_S", "x", y1, x0 - pw, x1 + pw, bot, top, s, group)
    pwall(name + "_W", "z", x0, y0 + pw, y1 - pw, bot, top, w, group)
    pwall(name + "_E", "z", x1, y0 + pw, y1 - pw, bot, top, e, group)


def seg(name, a, b, y0, y1, t=WALL_T, mat="wall", group="Walls"):
    """Wall box from pixel point a to b (any angle)."""
    ax, az, bx, bz = X(a[0]), Z(a[1]), X(b[0]), Z(b[1])
    L = math.hypot(bx - ax, bz - az)
    yaw = math.degrees(math.atan2(-(bx - ax), -(bz - az)))
    box(name, ((ax + bx) / 2, (y0 + y1) / 2, (az + bz) / 2), (t, y1 - y0, L), mat, group, yaw=yaw)


def seg_open(name, a, b, y0, y1, openings=(), group="Walls"):
    """Angled wall with openings given as (fraction0, fraction1, y_bottom, y_top) along a->b."""
    cuts = sorted({0.0, 1.0, *[o[0] for o in openings], *[o[1] for o in openings]})
    for i in range(len(cuts) - 1):
        f0, f1 = cuts[i], cuts[i + 1]
        mid = (f0 + f1) / 2
        o = next((o for o in openings if o[0] < mid < o[1]), None)
        pa = (a[0] + (b[0] - a[0]) * f0, a[1] + (b[1] - a[1]) * f0)
        pb = (a[0] + (b[0] - a[0]) * f1, a[1] + (b[1] - a[1]) * f1)
        for k, (s0, s1) in enumerate([(y0, y1)] if o is None else [(y0, o[2]), (o[3], y1)]):
            if s1 - s0 > 0.05:
                seg(f"{name}_{i}{k}", pa, pb, s0, s1, group=group)


def prism(name, pts, y0, y1, mat="floor", group="Floors", collide=True):
    """Vertical prism over a polygon of pixel points (any winding, may be concave)."""
    full = _unique(name) + ("-col" if collide else "")
    ring = [(X(p[0]), Z(p[1])) for p in pts]
    n = len(ring)
    verts = [tuple(g2b((x, y0, z))) for x, z in ring] + [tuple(g2b((x, y1, z))) for x, z in ring]
    faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    ob = bpy.data.objects.new(full, _mesh(full, verts, faces))
    ob.data.materials.append(_mat[mat])
    ob.color = _mat[mat].diffuse_color
    coll(group).objects.link(ob)
    return ob


def prail(name, x0, y0, x1, y1, top, h=1.05, group="Rails"):
    parapet(name, X(x0), Z(y0), X(x1), Z(y1), top, h=h, group=group)


def pbox(name, x0, x1, y0, y1, bot, top, mat="cover", group="Cover"):
    box(name, ((X(x0) + X(x1)) / 2, (bot + top) / 2, (Z(y0) + Z(y1)) / 2),
        (X(x1) - X(x0), top - bot, Z(y1) - Z(y0)), mat, group)


def post(name, px, py, top, h=2.2, w=0.9):
    box(name, (X(px), top + 0.002 + h / 2, Z(py)), (w, h, w), "cover", "Cover")


def pramp(name, a, b, width, rails=1.05, mat="ramp", group="Ramps"):
    """Ramp whose top surface runs from pixel point a=(px, py, y) to b."""
    SLOPES[name] = ramp(name, P(*a[:2], a[2]), P(*b[:2], b[2]), width, mat=mat, group=group, rails=rails)


def pmark(name, px, py, y, group="Markers", face=None):
    """Marker; face=(px, py) turns its -Z toward that pixel point (spawns face the action)."""
    yaw = 0.0
    if face is not None:
        dx, dz = X(face[0]) - X(px), Z(face[1]) - Z(py)
        yaw = math.degrees(math.atan2(-dx, -dz))
    return marker(name, P(px, py, y), group=group, yaw=yaw)


SLOPES = {}

# =========================================================================================
# 1. NORTH: LIFT TOWER (2 levels). Lower lift room on B, the grav lift up through the floor
#    into the upper lift room (TOPLIFT). Plan: x 233-322, y 147-280 (both drawings).
# =========================================================================================
pfloor("LiftLower_Floor", 233, 322, 147, 280, B, thick=1.0)
pfloor("LiftUpper_Floor", 233, 322, 147, 280, TOPLIFT, holes=[(268, 292, 149, 171)])
pfloor("LiftTower_Roof", 233, 322, 147, 280, 10.0)
shell("LiftTower", 233, 322, 147, 280, B - 1.0, 9.5,
      s=[(266, 291, B, B + DOOR), (268, 293, TOPLIFT, 9.5)],   # Green Hall / north gap (full height: jump arc)
      w=[(200, 222, TOPLIFT, TOPLIFT + DOOR)],                            # grate bridge
      e=[(194, 214, TOPLIFT, TOPLIFT + DOOR)],                            # east balcony
      n=[(250, 262, 6.4, 8.0), (298, 310, 6.4, 8.0)])                     # windows onto the cliff
# Stasis pods in the lower room (the two U shapes in the lower drawing): you round them to the lift.
pbox("StasisPod_LiftN", 260, 295, 172, 196, B, B + 2.6)
pbox("StasisPod_LiftS", 260, 295, 224, 250, B, B + 2.6)
box("Lift_Pad", (X(280), B + 0.05, Z(160)), (2.4, 0.1, 2.4), "lift", "Lift")
pfloor("Lift_EastBalcony", 322, 342, 192, 216, TOPLIFT, thick=0.4)
prail("Lift_EastBalcony_RailE", 341, 192, 341, 216, TOPLIFT)
prail("Lift_EastBalcony_RailN", 322, 193, 342, 193, TOPLIFT)
prail("Lift_EastBalcony_RailS", 322, 215, 342, 215, TOPLIFT)
pmark("LIFT_Main", 280, 160, B, group="Lift")

# Green Hall: the "bridge down below" from the lift to Bottom Mid, open to the sky (the top
# drawing shows the north gap as void), so a failed gap jump lands here instead of killing you.
pfloor("GreenHall_Bridge", 265, 294, 280, 382, B, thick=0.6)
prail("GreenHall_RailW", 266, 280, 266, 380, B)
prail("GreenHall_RailE", 293, 280, 293, 380, B)

# =========================================================================================
# 2. CENTRE: TOP MID deck (4.5) over BOTTOM MID. Deck x 212-345, y 325-452.
# =========================================================================================
pfloor("TopMid_Deck", 212, 345, 325, 452, T, mat="deck")
prail("TopMid_RailN_W", 212, 326, 268, 326, T)
prail("TopMid_RailN_E", 293, 326, 345, 326, T)
prail("TopMid_RailW_N", 213, 325, 213, 385, T)
prail("TopMid_RailW_S", 213, 415, 213, 452, T)
prail("TopMid_RailE_N", 344, 325, 344, 390, T)
prail("TopMid_RailE_S", 344, 420, 344, 452, T)
prail("TopMid_RailS_W", 212, 451, 305, 451, T)
for i, (px, py) in enumerate([(265, 327), (296, 327), (214, 382), (214, 418), (343, 387), (343, 423),
                              (302, 450), (214, 327), (343, 327), (214, 450), (343, 450)]):
    post(f"TopMid_Post_{i}", px, py, T)
box("TopMid_Light", (X(279), T + 0.02, Z(390)), (32 * PX_M, 0.02, 30 * PX_M), "light", "Floors", collide=False)

pfloor("BotMid_Floor", 254, 307, 380, 442, B, thick=1.0)
shell("BotMid", 254, 307, 380, 442, B - 1.0, T - 0.5,
      n=[(266, 291, B, B + DOOR)], w=[(385, 411, B, B + DOOR)], e=[(399, 419, B, B + DOOR)])
pbox("StasisPod_BotMid", 266, 290, 432, 440, B, B + 2.6)

# Sniper Alley: long bottom hall Bottom Mid -> BR1, roofed by the deck, open under the west gap.
pfloor("SniperAlley_Floor", 160, 254, 383, 413, B, thick=0.6)
pwall("SniperAlley_WallN", "x", 383, 212, 254, B - 0.6, T - 0.5)
pwall("SniperAlley_WallS", "x", 413, 212, 254, B - 0.6, T - 0.5)
prail("SniperAlley_RailN", 165, 384, 212, 384, B)
prail("SniperAlley_RailS", 165, 412, 212, 412, B)

# =========================================================================================
# 3. WEST: BR TOWER (3 levels). BR1 on B, BR2 on T (jump gap to Top Mid), BR3 roof (9.0).
# =========================================================================================
pfloor("BR1_Floor", 57, 160, 377, 472, B, thick=1.0)
shell("BR1", 57, 165, 377, 472, B - 1.0, T - 0.5,
      e=[(385, 411, B, B + DOOR)],           # Sniper Alley
      n=[(124, 158, B, B + DOOR)],           # north-west ramp
      s=[(64, 94, B - 1.0, T - 0.5)])        # BR ramp climbs out through the south wall
# BR ramp (west strip of both drawings): BR1 -> BR2 balcony.
pramp("BR_Ramp", (79, 402, B), (79, 487, T), 3.4, rails=0.0)
pfloor("BR2_Floor", 57, 165, 377, 517, T, holes=[(64, 94, 398, 487)])
pfloor("BR2_Floor_E", 165, 210, 420, 517, T)
prail("BR2_RampHole_RailE", 95, 398, 95, 485, T)
prail("BR2_RampHole_RailN", 64, 397, 95, 397, T)
pwall("BR2_WallN", "x", 377, 57, 165, T - 0.5, BR3 - 0.5)
pwall("BR2_WallW", "z", 57, 377, 485, T - 0.5, BR3 - 0.5)
pwall("BR2_WallE", "z", 165, 377, 420, T - 0.5, BR3 - 0.5, [(385, 415, T, BR3)])   # west gap, full height (jump arc)
pwall("BR2_WallN2", "x", 420, 165, 210, T - 0.5, BR3 - 0.5)
pwall("BR2_WallE2", "z", 210, 420, 485, T - 0.5, BR3 - 0.5)
pwall("BR2_WallS", "x", 485, 57, 210, T - 0.5, BR3 - 0.5,
      [(64, 94, T - 0.5, T + DOOR), (96, 118, T, T + DOOR)])     # ramp top, balcony door
pbox("BR2_Pillar", 115, 119, 425, 480, T, T + 2.5)
# South balcony (T) carries the second ramp up to the roof.
prail("BR2_Balcony_RailS", 57, 516, 210, 516, T)
prail("BR2_Balcony_RailW", 58, 485, 58, 517, T)
pramp("BR_RoofRamp", (120, 501, T), (194, 501, BR3), 2.9, rails=0.0)
pfloor("BR3_Landing", 192, 210, 484, 516, BR3)
prail("BR3_Landing_RailE", 209, 484, 209, 516, BR3)
prail("BR3_Landing_RailS", 192, 515, 210, 515, BR3)
pfloor("BR3_Roof", 57, 165, 377, 485, BR3)
pfloor("BR3_Roof_E", 165, 210, 420, 485, BR3)
prail("BR3_RailN", 57, 378, 165, 378, BR3)
prail("BR3_RailW", 58, 377, 58, 485, BR3)
prail("BR3_RailE", 164, 377, 164, 420, BR3)
prail("BR3_RailN2", 165, 421, 210, 421, BR3)
prail("BR3_RailE2", 209, 420, 209, 485, BR3)
prail("BR3_RailS", 57, 484, 192, 484, BR3)
pbox("BR3_Cover", 100, 125, 425, 431, BR3, BR3 + 1.1)

# North-west ramp (in BOTH drawings: it climbs between them): BR1 door -> landing at TOPLIFT,
# then the grate bridge east into the upper lift room.
pfloor("NWRamp_Landing", 122, 165, 182, 228, TOPLIFT)
prail("NWRamp_Landing_RailN", 122, 183, 165, 183, TOPLIFT)
prail("NWRamp_Landing_RailW", 123, 182, 123, 228, TOPLIFT)
prail("NWRamp_Landing_RailE", 164, 182, 164, 200, TOPLIFT)
pramp("NW_Ramp", (141, 228, TOPLIFT), (141, 379, B), 4.0)
pfloor("GrateBridge", 165, 233, 200, 222, TOPLIFT, thick=0.3, mat="catwalk", group="Catwalks")
prail("GrateBridge_RailN", 165, 201, 233, 201, TOPLIFT, group="Catwalks")
prail("GrateBridge_RailS", 165, 221, 233, 221, TOPLIFT, group="Catwalks")

# =========================================================================================
# 4. SOUTH-EAST (3+ levels): S1 (B) / S2 (T) / S3 (8.5) sniper stack, the Library (T) and its
#    basement (-3), the bottom corridor from Bottom Mid, and the Elbow loop up to S3.
# =========================================================================================
# Bridge Top Mid -> S2 (the only bridge on the top level).
pfloor("EastBridge", 345, 381, 390, 420, T)
prail("EastBridge_RailN", 345, 391, 381, 391, T)
prail("EastBridge_RailS", 345, 419, 381, 419, T)

# Bottom corridor east from Bottom Mid, then the open ramp down to the basement.
pfloor("EastCorridor_Floor", 307, 365, 398, 420, B, thick=0.6)
pwall("EastCorridor_WallN", "x", 398, 307, 365, B - 0.6, T - 0.5)
pwall("EastCorridor_WallS", "x", 420, 307, 343, B - 0.6, T - 0.5)
pwall("EastCorridor_WallE", "z", 365, 398, 420, B - 0.6, T - 0.5)
pramp("Basement_RampW", (354, 420, B), (354, 492, LO), 2.6, rails=0.0)
pwall("Basement_RampW_WallW", "z", 343, 420, 490, LO - 0.6, T - 0.5)
pwall("Basement_RampW_WallE", "z", 365, 420, 490, LO - 0.6, T - 0.5)

# Library basement (lower drawing, south-east room) + its south alcove.
pfloor("Basement_Floor", 340, 482, 490, 532, LO, thick=1.0)
pfloor("Basement_Alcove_Floor", 412, 440, 532, 550, LO, thick=1.0)
shell("Basement", 340, 482, 490, 532, LO - 1.0, T - 0.5,
      n=[(343, 365, LO, B), (458, 480, LO, B)], s=[(412, 440, LO, B)])
pwall("Basement_Alcove_W", "z", 412, 532, 550, LO - 1.0, T - 0.5)
pwall("Basement_Alcove_E", "z", 440, 532, 550, LO - 1.0, T - 0.5)
pwall("Basement_Alcove_S", "x", 550, 412, 440, LO - 1.0, T - 0.5)
for i, (px, py) in enumerate([(392, 511), (440, 511)]):
    pbox(f"Basement_Pillar_{i}", px - 3.5, px + 3.5, py - 3.5, py + 3.5, LO, T - 0.5)
pramp("Basement_RampE", (469, 492, LO), (469, 442, B), 2.6, rails=0.0)
pwall("Basement_RampE_WallW", "z", 457, 442, 490, LO - 0.6, T - 0.5)
pwall("Basement_RampE_WallE", "z", 481, 442, 490, LO - 0.6, T - 0.5)

# S1 (B) with the ramp up along its north wall into S2.
pfloor("S1_Floor", 381, 505, 372, 440, B, thick=1.0)
shell("S1", 381, 505, 372, 440, B - 1.0, T - 0.5, s=[(458, 480, B, B + DOOR)])
pramp("S1_Ramp", (497, 384, B), (422, 384, T), 2.4, rails=0.0)

# S2 (T): bridge in from Top Mid, annex north to the Elbow, passage south to the Library.
pfloor("S2_Floor", 381, 505, 368, 448, T, holes=[(424, 499, 374, 395)])
prail("S2_RampHole_RailS", 424, 396, 499, 396, T)
shell("S2", 381, 505, 368, 448, T, S3F - 0.5,
      w=[(390, 420, T, T + DOOR)], n=[(386, 428, T, T + DOOR)], s=[(452, 478, T, T + DOOR)],
      e=[(390, 430, 5.6, 6.9)])
pfloor("NE_Annex", 383, 430, 335, 368, T)
prail("NE_Annex_RailN", 383, 336, 430, 336, T)
prail("NE_Annex_RailW", 384, 335, 384, 368, T)
prail("NE_Annex_RailE", 429, 353, 429, 368, T)

# Elbow loop (the U in the top drawing): annex -> NE corner -> S3 landing -> SE corner -> Library.
pramp("Elbow_TopArm", (430, 343, T), (557, 343, ARM), 2.4)
pfloor("Elbow_NE", 557, 587, 333, 355, ARM)
prail("Elbow_NE_RailN", 557, 334, 587, 334, ARM)
prail("Elbow_NE_RailE", 586, 333, 586, 355, ARM)
pramp("Elbow_RampUp", (572, 355, ARM), (572, 400, S3F), 3.4)
pfloor("Elbow_S3Landing", 552, 587, 400, 440, S3F)
prail("Elbow_S3Landing_RailE", 586, 400, 586, 440, S3F)
pramp("Elbow_RampDown", (572, 440, S3F), (572, 500, ARM), 3.4)
pfloor("Elbow_SE", 557, 587, 500, 532, ARM)
prail("Elbow_SE_RailE", 586, 500, 586, 532, ARM)
prail("Elbow_SE_RailS", 557, 531, 587, 531, ARM)
pramp("Elbow_BottomArm", (557, 516, ARM), (500, 516, T), 3.4)

# S3: the rounded room on top of S2 (drawn displaced in the top drawing; its leader points at the
# Elbow landing). Sniper perch: windows onto Top Mid, a door out to the S2 roof terrace.
S3_PTS = [(418, 360), (530, 360), (552, 382), (552, 426), (530, 448), (418, 448)]
prism("S3_Floor", S3_PTS, S3F - 0.5, S3F)
prism("S3_Roof", S3_PTS, 12.0, 12.5)
pfloor("S2_RoofTerrace", 381, 418, 368, 448, S3F)
prail("S2_RoofTerrace_RailW", 382, 368, 382, 448, S3F)
prail("S2_RoofTerrace_RailN", 381, 369, 418, 369, S3F)
prail("S2_RoofTerrace_RailS", 381, 447, 418, 447, S3F)
W_WIN = (S3F + 1.0, S3F + 2.3)
seg_open("S3_WallW", (418, 448), (418, 360), S3F, 12.0,
         [(0.06, 0.30, *W_WIN), (0.32, 0.6, S3F, S3F + DOOR), (0.64, 0.9, *W_WIN)])
seg_open("S3_WallN", (418, 360), (530, 360), S3F, 12.0, [(0.15, 0.85, *W_WIN)])
seg("S3_WallNE", (530, 360), (552, 382), S3F, 12.0)
seg_open("S3_WallE", (552, 382), (552, 426), S3F, 12.0, [(0.2, 0.8, S3F, S3F + DOOR)])
seg("S3_WallSE", (552, 426), (530, 448), S3F, 12.0)
seg_open("S3_WallS", (530, 448), (418, 448), S3F, 12.0, [(0.15, 0.85, *W_WIN)])
pbox("S3_HalfWall_N", 465, 470, 366, 388, S3F, S3F + 1.2)
pbox("S3_HalfWall_S", 465, 470, 420, 442, S3F, S3F + 1.2)

# Library (T): three bays, pointed bastions at the south corners, a window over Top Mid.
# Floor and roof are the main rectangle minus the two south corners, which the bastion prisms fill
# (no coplanar overlap, so no z-fighting).
LIB_RECTS = [(297, 500, 490, 548), (347, 449, 548, 578)]
for i, r in enumerate(LIB_RECTS):
    pfloor(f"Library_Floor_{i}", *r, T)
    pfloor(f"Library_Roof_{i}", *r, 8.5)
BAST_W = [(297, 548), (289, 557), (318, 587), (347, 566), (347, 578)]   # wall line
BAST_E = [(796 - x, y) for x, y in BAST_W]
for tag, pts in (("W", BAST_W), ("E", BAST_E)):
    slab_pts = pts[:4] + [(pts[4][0], 548)]
    prism(f"Library_Bastion{tag}_Floor", slab_pts, T - 0.5, T)
    prism(f"Library_Bastion{tag}_Roof", slab_pts, 8.0, 8.5)
    for i in range(len(pts) - 1):
        seg(f"Library_Bastion{tag}_Wall{i}", pts[i], pts[i + 1], T - 0.5, 8.0)
pwall("Library_WallN", "x", 490, 297, 500, T - 0.5, 8.0,
      [(305, 340, T, T + DOOR), (372, 428, T + 1.1, T + 2.4), (452, 478, T, T + DOOR)])
pwall("Library_WallW", "z", 297, 490, 548, T - 0.5, 8.0)
pwall("Library_WallE", "z", 500, 490, 548, T - 0.5, 8.0, [(502, 530, T, T + DOOR)])
pwall("Library_WallS", "x", 578, 347, 449, T - 0.5, 8.0)
pwall("Library_Bay_W", "z", 370, 540, 578, T, 8.0)
pwall("Library_Bay_E", "z", 430, 540, 578, T, 8.0)
pbox("Library_Pod", 390, 410, 566, 576, T, T + 2.6)
pbox("Library_Pillar_W", 362, 372, 492, 506, T, 8.0)
pbox("Library_Pillar_E", 425, 433, 492, 506, T, 8.0)
pbox("Library_Desk", 318, 345, 525, 531, T, T + 1.1)

# Top-level passages into the Library: from Top Mid (south gap) and from S2.
pfloor("Passage_TopMid_Library", 305, 340, 452, 490, T)
prail("Passage_TopMid_Library_RailW", 306, 452, 306, 490, T)
prail("Passage_TopMid_Library_RailE", 339, 452, 339, 490, T)
pfloor("Passage_S2_Library", 452, 478, 448, 490, T)
prail("Passage_S2_Library_RailW", 453, 448, 453, 490, T)
prail("Passage_S2_Library_RailE", 477, 448, 477, 490, T)

# =========================================================================================
# 5. SETTING: the facility hangs off a cliff face over a snow-filled drop.
# =========================================================================================
pbox("Cliff_Face", -40, 640, 40, 128, ABYSS, 38.0, mat="oob", group="Boundary")
for name, (x0, x1, y0, y1), top in (
        ("Pylon_TopMid", (258, 303, 384, 438), B - 1.0), ("Pylon_LiftTower", (245, 310, 160, 265), B - 1.0),
        ("Pylon_BR", (80, 150, 390, 460), B - 1.0), ("Pylon_Library", (360, 460, 495, 570), LO - 1.0),
        ("Pylon_S1", (400, 490, 380, 430), B - 1.0)):
    pbox(name, x0, x1, y0, y1, ABYSS, top, mat="oob", group="Boundary")
box("Snow", (X(300), ABYSS, Z(380)), (240.0, 0.1, 200.0), "snow", "Boundary", collide=False)

# =========================================================================================
# 6. MARKERS: spawns (face Top Mid), Long Colt weapons on Lockout's H2 power spots, callouts.
# =========================================================================================
MID = (279, 390)
FFA = [
    (300, 262, B), (300, 250, TOPLIFT), (140, 205, TOPLIFT), (120, 430, B), (135, 400, T),
    (100, 440, BR3), (281, 400, B), (225, 340, T), (332, 440, T), (470, 420, B),
    (440, 425, T), (480, 404, S3F), (325, 510, T), (470, 555, T), (370, 512, LO), (405, 350, T),
]
for i, (px, py, y) in enumerate(FFA):
    pmark(f"SPAWN_FFA_{i:02d}", px, py, y, face=MID)

# H2 Lockout: shotgun in the green stasis hall, sniper on S3, BR + 2 magnums on top of the lift,
# BR on the BR tower. Long Colt five-gun mapping (docs/weapons/roster_balance.md): the scoped
# one-shot Directed Energy Rifle takes the sniper's spot.
WEAPONS = [
    ("WPN_CombatShotgun_GreenHall", (280, 330, B)),
    ("WPN_DirectedEnergyRifle_S3", (500, 404, S3F)),
    ("WPN_MarksmanCarbine_BR3", (130, 440, BR3)),
    ("WPN_StandardIssueRifle_TopLift", (280, 200, TOPLIFT)),
    ("WPN_ServicePistol_TopLiftW", (250, 240, TOPLIFT)),
    ("WPN_ServicePistol_TopLiftE", (310, 240, TOPLIFT)),
    ("WPN_Longsword_Library", (398, 530, T)),
    ("WPN_StandardIssueRifle_Basement", (420, 520, LO)),
    ("WPN_GravityHammer_S1", (440, 425, B)),
]
for n, (px, py, y) in WEAPONS:
    pmark(n, px, py, y)
CALLOUTS = {
    "TopMid": (279, 390, T), "BottomMid": (281, 400, B), "GreenHall": (280, 330, B),
    "LiftLower": (300, 262, B), "TopLift": (290, 230, TOPLIFT), "NWRamp": (141, 300, 2.5),
    "GrateBridge": (200, 211, TOPLIFT), "SniperAlley": (230, 398, B), "BR1": (120, 420, B),
    "BR2": (135, 400, T), "BR3": (135, 455, BR3), "BRBalcony": (80, 500, T),
    "EastBridge": (363, 405, T), "S1": (450, 425, B), "S2": (440, 425, T), "S3": (480, 404, S3F),
    "S2Terrace": (400, 408, S3F), "NEAnnex": (405, 350, T), "Elbow": (572, 420, S3F),
    "Library": (330, 520, T), "Basement": (370, 512, LO), "EastCorridor": (330, 409, B),
}
for n, (px, py, y) in CALLOUTS.items():
    pmark("CALLOUT_" + n, px, py, y, group="Callouts")

# ---- jump audit (the two gaps the design doc says you cross "by jumping") ------------------
G_, H_, RUN_, R_ = 22.0, 2.2, 7.5, 0.35
V0_ = math.sqrt(2 * G_ * H_)


def _reach(rise):
    d = V0_ * V0_ - 2 * G_ * rise
    return None if d < 0 else RUN_ * (V0_ + math.sqrt(d)) / G_ + R_


JUMPS = {
    "North gap, Top Mid -> top lift": ((325 - 280) * PX_M, TOPLIFT - T),
    "North gap, top lift -> Top Mid": ((325 - 280) * PX_M, T - TOPLIFT),
    "West gap, Top Mid <-> BR2": ((212 - 165) * PX_M, 0.0),
}

# =========================================================================================
# report, save, export
# =========================================================================================
print("\n== Lockout greybox: slopes (deg; floor_max_angle 50, design limit 40) ==")
for n, s in SLOPES.items():
    flag = "  !! too steep" if abs(s) > 40 else ""
    print(f"  {n:24s} {abs(s):5.1f}{flag}")
print("== jumps (running jump reach incl. capsule radius vs gap) ==")
for n, (gap, rise) in JUMPS.items():
    r = _reach(rise)
    margin = (r - gap) / gap * 100 if r else -100
    print(f"  {n:34s} gap {gap:4.2f} m  rise {rise:+.1f}  reach {r:4.2f} m  margin {margin:+.0f}%")
def _clean_and_join_by_material():
    mesh_obs = [ob for ob in bpy.data.objects if ob.type == "MESH"]
    by_mat = {}
    for ob in mesh_obs:
        mat = ob.data.materials[0].name if ob.data.materials else "none"
        by_mat.setdefault(mat, []).append(ob)

    for mat_name, obs in by_mat.items():
        bpy.ops.object.select_all(action="DESELECT")
        for ob in obs:
            ob.select_set(True)
        bpy.context.view_layer.objects.active = obs[0]
        if len(obs) > 1:
            bpy.ops.object.join()
        joined = bpy.context.view_layer.objects.active
        col_suffix = "-col" if mat_name not in ("mat_light", "mat_snow") else ""
        joined.name = f"Lockout_{mat_name[4:].capitalize()}{col_suffix}"
        
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
LEVEL_TSCN = _arg("--level-tscn", "scenes/levels/lockout.tscn")
MAIN_TSCN = _arg("--main-tscn", "scenes/main/main_lockout.tscn")
ARENA_TSCN = _arg("--arena-tscn", "scenes/main/arena_lockout.tscn")


def _xf(p, yaw=0.0):
    c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    return f"Transform3D({c:.6g}, 0, {s_:.6g}, 0, 1, 0, {-s_:.6g}, 0, {c:.6g}, {p[0]:.6g}, {p[1]:.6g}, {p[2]:.6g})"


def _v3(p):
    return f"Vector3({p[0]:.6g}, {p[1]:.6g}, {p[2]:.6g})"


def _spawn_list():
    out = []
    for o in bpy.data.objects:
        if o.type == "EMPTY" and o.name.startswith("SPAWN_"):
            loc = o.matrix_world.translation
            yaw = math.degrees(o.matrix_world.to_euler().z)
            out.append((o.name, (loc.x, loc.z + 0.05, -loc.y), yaw))
    return sorted(out)


LIFT = P(280, 160, B)
lines = [
    "[gd_scene load_steps=7 format=3]",
    "",
    '[ext_resource type="PackedScene" path="res://assets/models/environment/lockout_greybox.glb" id="1_glb"]',
    '[ext_resource type="Script" path="res://scripts/levels/grav_lift.gd" id="2_lift"]',
    '[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="3_kill"]',
    '[ext_resource type="Script" path="res://scripts/levels/level_materials.gd" id="4_mat"]',
    "",
    '[sub_resource type="BoxShape3D" id="Shape_Lift"]',
    "size = Vector3(2.6, 4, 2.6)",
    "",
    '[sub_resource type="BoxShape3D" id="Shape_Kill"]',
    "size = Vector3(300, 2, 300)",
    "",
    "; GENERATED by tools/lockout/build_lockout_greybox.py - edit the script, not this file.",
    '[node name="Lockout" type="Node3D"]',
    "",
    '[node name="LevelMaterials" type="Node" parent="."]',
    'script = ExtResource("4_mat")',
    "",
    '[node name="Greybox" parent="." instance=ExtResource("1_glb")]',
    "",
    "; Lift: 0 -> 4 m volume, exits at 12 m/s -> ~7.3 m apex, up through the floor hole into the",
    "; upper lift room (floor 5.0); drift forward (south) to land.",
    '[node name="GravLift" type="Area3D" parent="."]',
    "transform = " + _xf((LIFT[0], 2.0, LIFT[2])),
    "collision_layer = 16",
    "collision_mask = 2",
    "monitorable = false",
    'script = ExtResource("2_lift")',
    "",
    '[node name="Shape" type="CollisionShape3D" parent="GravLift"]',
    'shape = SubResource("Shape_Lift")',
    "",
    "; below the basement floor (-3); falling off the facility kills",
    '[node name="KillVolume" type="Area3D" parent="."]',
    "transform = " + _xf((0.0, -15.0, 0.0)),
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
open(LEVEL_TSCN, "w").write("\n".join(lines))

# Grenade pickups (GrenadePickup: 2 each, 30 s respawn) in the main and arena scenes only, no .glb
# marker. Metres. Each sits by a roam point on flat floor with a standing capsule's room, clear of
# weapon pads, spawns and flag bases (tests/grenade_spawns_self_test.gd checks all of that).
# Frags on the bottom floor, stickies up top.
GRENADES = [
    ("Frags_BR1", "frag", (-19.0, B, 3.5)), ("Frags_BottomMid", "frag", (1.75, B, 1.25)),
    ("Frags_S1", "frag", (21.5, B, 4.25)), ("Stickies_EastBridge", "sticky", (10.0, T, 1.75)),
    ("Stickies_Library", "sticky", (6.0, T, 15.5)), ("Stickies_Elbow", "sticky", (35.25, S3F, 3.5)),
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
PICKUPS = [(n[4:], P(px, py, y), GUN[n.split("_")[1]]) for n, (px, py, y) in WEAPONS]
first = _spawn_list()[7]  # Top Mid north-west corner
LIGHTMAP = []


def _pickup_nodes(out):
    for n, p, (f, rid, respawn) in PICKUPS:
        out += [f'[node name="{n}" parent="." instance=ExtResource("8_pickup")]', "transform = " + _xf(p),
                f'weapon_scene = ExtResource("{rid}")'] + ([f"respawn_delay = {respawn}"] if respawn else []) + [""]


# Offline testbed: Player, pickups, and the target dummies for balance checks.
TOP_SQ = [(-6, T + 0.05, -6), (6, T + 0.05, -6), (6, T + 0.05, 6), (-6, T + 0.05, 6), (-6, T + 0.05, -6)]
ml = ["[gd_scene load_steps=14 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/lockout.tscn" id="1_level"]']
for f, rid, _ in GUN.values():
    ml.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
ml += GRENADE_EXT
ml += ['[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
       '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
       '[ext_resource type="PackedScene" path="res://scenes/levels/lockout_lighting.tscn" id="9_lighting"]',
       '[ext_resource type="PackedScene" path="res://scenes/ai/moving_dummy.tscn" id="10_moving"]',
       '[ext_resource type="PackedScene" path="res://scenes/ai/target_dummy.tscn" id="11_dummy"]', "",
       '[sub_resource type="Curve3D" id="Curve_Path_TopMid"]', "_data = {",
       '"points": PackedVector3Array(' + ", ".join(f"0, 0, 0, 0, 0, 0, {p[0]:g}, {p[1]:g}, {p[2]:g}" for p in TOP_SQ) + "),",
       '"tilts": PackedFloat32Array(0, 0, 0, 0, 0)', "}", "point_count = 5", "",
       "; GENERATED by tools/lockout/build_lockout_greybox.py - offline testbed (no bots).",
       '[node name="MainLockout" type="Node3D"]', "",
       '[node name="LockoutLighting" parent="." instance=ExtResource("9_lighting")]', "",
       '[node name="Lockout" parent="." instance=ExtResource("1_level")]', ""] + LIGHTMAP
ml += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
_pickup_nodes(ml)
_grenade_nodes(ml)
bx = lambda a, b: f"Vector2({a[0]:.4g}, {a[2]:.4g})"  # noqa: E731  (x, z) bounds
ml += ['[node name="Path_TopMid" type="Path3D" parent="."]', 'curve = SubResource("Curve_Path_TopMid")', "",
       '[node name="Spartan_TopMid" parent="." instance=ExtResource("10_moving")]', "transform = " + _xf((2, T + 0.05, -3), 180),
       "pattern = 2", "move_seed = 2004", "bounds_min = Vector2(-7, -7)", "bounds_max = Vector2(7, 7)", "",
       '[node name="Pather_TopMid" parent="." instance=ExtResource("10_moving")]', "transform = " + _xf(TOP_SQ[0], 180),
       "pattern = 3", "move_seed = 0", 'path = NodePath("../Path_TopMid")', "path_speed = 4.0",
       "bounds_min = Vector2(-7, -7)", "bounds_max = Vector2(7, 7)", "",
       '[node name="Strafer_EastBridge" parent="." instance=ExtResource("10_moving")]',
       "transform = " + _xf(P(363, 405, T + 0.05), 90), "pattern = 1", "move_seed = 2001", "strafe_speed = 7.5",
       "strafe_duration = 0.7", "strafe_jitter = 0.3",
       f"bounds_min = {bx(P(349, 394), None)}", f"bounds_max = {bx(P(377, 416), None)}", "",
       '[node name="Strafer_GrateBridge" parent="." instance=ExtResource("10_moving")]',
       "transform = " + _xf(P(200, 211, TOPLIFT + 0.05)), "pattern = 1", "move_seed = 2002", "strafe_speed = 7.5",
       "strafe_duration = 0.9", "strafe_jitter = 0.4",
       f"bounds_min = {bx(P(170, 205), None)}", f"bounds_max = {bx(P(228, 217), None)}", ""]
for n, (px, py, y), yaw in (("Dummy_S2", (440, 425, T), 90), ("Dummy_Library", (330, 520, T), 0),
                            ("Dummy_GreenHall", (280, 350, B), 180), ("Dummy_BR2", (130, 400, T), -90)):
    ml += [f'[node name="{n}" parent="." instance=ExtResource("11_dummy")]', "transform = " + _xf(P(px, py, y), yaw), ""]
open(MAIN_TSCN, "w").write("\n".join(ml))

# Arena (Bot Arena + LAN): same pickups, bots, runtime navmesh, nav links, roam points; NetMatch
# before SpawnManager (its _ready configures SpawnManager), like arena_headlong.tscn.
ROAM_W = {"TopMid": 2.0, "TopLift": 1.5, "S3": 1.5, "Library": 1.5, "NWRamp": 0.5, "GrateBridge": 0.5,
          "BRBalcony": 0.5, "EastBridge": 0.5, "NEAnnex": 0.5, "Elbow": 0.5, "S2Terrace": 0.5, "LiftLower": 0.5}
al = ["[gd_scene load_steps=18 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/lockout.tscn" id="1_level"]',
      '[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
      '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
      '[ext_resource type="PackedScene" path="res://scenes/levels/lockout_lighting.tscn" id="9_lighting"]',
      '[ext_resource type="PackedScene" path="res://scenes/ai/bot.tscn" id="10_bot"]',
      '[ext_resource type="Script" path="res://scripts/ai/arena_events.gd" id="11_events"]',
      '[ext_resource type="Script" path="res://scripts/ai/arena_navigation.gd" id="12_nav"]',
      '[ext_resource type="Script" path="res://scripts/net/net_match.gd" id="13_net"]',
      '[ext_resource type="Script" path="res://scripts/ai/spawn_manager.gd" id="14_spawns"]',
      '[ext_resource type="Resource" path="res://resources/ai/bot_difficulty_normal.tres" id="15_diff"]']
for f, rid, _ in GUN.values():
    al.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
al += GRENADE_EXT
al += ["", "; GENERATED by tools/lockout/build_lockout_greybox.py - arena mode (Bot Arena / LAN) on Lockout.",
       '[node name="ArenaLockout" type="Node3D"]', "",
       '[node name="LockoutLighting" parent="." instance=ExtResource("9_lighting")]', "",
       '[node name="ArenaEvents" type="Node" parent="."]', 'script = ExtResource("11_events")', "",
       '[node name="Lockout" parent="." instance=ExtResource("1_level")]', ""] + LIGHTMAP
al += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
_pickup_nodes(al)
_grenade_nodes(al)
al += ['[node name="Navigation" type="NavigationRegion3D" parent="."]', 'script = ExtResource("12_nav")',
       'geometry_root = NodePath("../Lockout")', "",
       "; Lift (GravLift in lockout.tscn): hold over the pad, step south once above the upper floor",
       '[node name="Link_GravLift" type="NavigationLink3D" parent="Navigation"]', "bidirectional = false",
       "navigation_layers = 1", f"start_position = {_v3(LIFT)}", f"end_position = {_v3(P(280, 190, TOPLIFT))}",
       'metadata/traversal = "lift"', f"metadata/release_y = {TOPLIFT + 0.6:g}", ""]
# The two gaps of the design doc (easy running jumps, every bot uses them): start 0.5 m before
# the takeoff edge, lip on the edge, end 1 m past the landing edge.
for n, a, lip, b in (("Jump_NorthGap_Up", (280, 330, T), (280, 325, T), (280, 270, TOPLIFT)),
                     ("Jump_NorthGap_Down", (280, 275, TOPLIFT), (280, 280, TOPLIFT), (280, 334, T))
                     , ("Jump_WestGap_ToBR", (216, 400, T), (212, 400, T), (157, 400, T)),
                     ("Jump_WestGap_ToMid", (161, 400, T), (165, 400, T), (220, 400, T))):
    al += [f'[node name="Link_{n}" type="NavigationLink3D" parent="Navigation"]', "bidirectional = false",
           "navigation_layers = 1", f"start_position = {_v3(P(*a))}", f"end_position = {_v3(P(*b))}",
           'metadata/traversal = "jump"', f"metadata/lip = {_v3(P(*lip))}", ""]
al += ['[node name="NavPoints" type="Node3D" parent="."]', ""]
for n, (px, py, y) in CALLOUTS.items():
    if n == "NWRamp":
        continue  # mid-ramp, not a place to stand
    p = P(px, py, y)
    al += [f'[node name="{n}" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]',
           "transform = " + _xf((p[0], p[1] + 0.05, p[2])), f"metadata/weight = {ROAM_W.get(n, 1.0):g}",
           f'metadata/callout = "{n}"', ""]
al += ['[node name="NetMatch" type="Node" parent="."]', 'script = ExtResource("13_net")', "",
       '[node name="SpawnManager" type="Node" parent="."]', 'script = ExtResource("14_spawns")',
       'bot_scene = ExtResource("10_bot")', "bot_count = 3", 'difficulty = ExtResource("15_diff")',
       'spawn_roots = Array[NodePath]([NodePath("../Lockout/Spawns")])', ""]
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
    world = bpy.data.worlds.new("w")
    scene.world = world
    world.color = (0.05, 0.05, 0.06)
    roofs = [o for o in bpy.data.objects if any(k in o.name for k in ("Roof", "Cliff", "Pylon", "Snow"))
             and "Ramp" not in o.name and "Terrace" not in o.name and "Landing" not in o.name]
    boundary = [o for o in bpy.data.objects if any(k in o.name for k in ("Cliff", "Snow"))]

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

    # overhead: north up (Blender +Y = Godot -Z = north); roofs hidden so the floors read
    cx, cy = X(320), -Z(370)
    shoot("lockout_overhead", (cx, cy, 120), (0, 0, 0), ortho=72, hidden=boundary)
    shoot("lockout_overhead_noroofs", (cx, cy, 120), (0, 0, 0), ortho=72, hidden=roofs)
    shoot("lockout_persp_sw", (cx - 38, cy - 42, 30), (62, 0, -40), res=(1920, 1080))
    shoot("lockout_persp_ne", (cx + 40, cy + 30, 28), (64, 0, 128), res=(1920, 1080), hidden=boundary)
    print("  previews in", PREVIEWS)
