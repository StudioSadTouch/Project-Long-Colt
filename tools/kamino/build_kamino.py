"""Build the Kamino: Cloning Facility (Star Wars: Battlefront II, 2005) greybox (.glb + .blend), its Godot
scenes and preview renders with headless Blender.

Usage (from the repo root; the glTF exporter needs numpy visible to Blender's Python):
  PYTHONPATH=<dir with numpy> blender -b --factory-startup --python tools/kamino/build_kamino.py -- \
      [--glb assets/models/environment/kamino_greybox.glb] [--blend tools/kamino/kamino_greybox.blend] \
      [--previews tools/kamino/previews] [--no-render]

ALL geometry is ESTIMATED: traced from the in-game overhead map on the Battlefront wiki
(File:Kamino_Cloning_Facility_Map.PNG, 467 x 445 px) at 1 px ~= 0.36 m, then made exactly
point-symmetric about the Central Platform (the trace already is to within ~15 px) so Red and Blue
are mirror images. See kamino_spec.md for sources, callouts and confidence.

All data below is authored in GODOT space: metres, +Y up, +X east, -Z north (north = top of the
overhead). Red base = west (the left D-shaped building), Blue base = east. g2b() converts to Blender
space; the glTF exporter (export_yup) converts back, so the .glb lands in Godot exactly as authored.

Naming for the Godot importer:
  *-col      mesh + StaticBody3D with trimesh collision (World layer 1)
  no suffix  visual only (ocean, platform undersides, stilts, distant Tipoca City)
  Empties    SPAWN_*, WPN_*, CALLOUT_* become Node3D markers; kamino.tscn turns spawns into Marker3Ds.
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


GLB = _arg("--glb", "assets/models/environment/kamino_greybox.glb")
BLEND = _arg("--blend", "tools/kamino/kamino_greybox.blend")
PREVIEWS = _arg("--previews", "tools/kamino/previews")
RENDER = "--no-render" not in argv and PREVIEWS != ""

# Player reference (scripts/player/player.gd): 2.1 m body, jump_height 2.2, stand_speed 7.5,
# gravity 22 -> ~0.89 s airtime, ~6.7 m flat running jump. floor_max_angle 50 deg, step 0.35.
PX = 0.36            # metres per overhead-map pixel
DECK_R = 9.0         # platform deck radius (the overhead's ring is ~30 px = 10.8 m incl. the lip)
DECK_T = 1.0
BRIDGE_W = 4.0
RAIL_H = 1.0
OCEAN = -14.0        # visual sea surface; the KillVolume sits above it at -12
WALL_T = 0.6

# Base (D-shaped Cloning Facility block), local frame: u = toward the platforms, v = along the flat side.
PLAZA_R = 31.0       # open-air "lab plaza" deck, half disc
HALL_R = 13.0        # facility building (half disc against the flat side)
HALL_H = 8.0         # hall roof top = the sniping post over the plaza
LAB_C = (-7.0, 0.0)  # round cloning lab behind the flat side
LAB_R = 7.5
LAB_H = 6.0
DOOR = 3.2


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

# ---- materials: flat matte, one per role (Kaminoan white / grey, greybox ramp orange) -----
MATS = {
    "deck": "#a7b0b8",     # platform and plaza decks
    "floor": "#c9ced2",    # building floors and roofs
    "wall": "#e2e5e7",     # facility walls (Tipoca white)
    "bridge": "#6f7a84",   # level bridges and catwalks
    "ramp": "#c0843a",     # anything sloped you can walk
    "rail": "#4f5961",
    "cover": "#455a64",    # crates, emplacements, blast walls, consoles
    "lamp": "#dfe9f2",
    "tank": "#5fa8c8",     # clone tanks
    "pad": "#2e86c1",      # landing pads (gunship bays)
    "under": "#3b434a",    # platform undersides and stilts (visual)
    "city": "#2a3036",     # distant Tipoca City (visual)
    "sea": "#16324a",
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


def _object(name, me, mat, group, collide):
    full = _unique(name) + ("-col" if collide else "")
    me.name = full
    ob = bpy.data.objects.new(full, me)
    ob.data.materials.append(_mat[mat])
    ob.color = _mat[mat].diffuse_color
    coll(group).objects.link(ob)
    return ob


def _cube_mesh(name, size):
    """Axis-aligned box mesh centred on its origin, size given in GODOT axes (x, y, z)."""
    sx, sy, sz = size
    hx, hy, hz = sx / 2, sz / 2, sy / 2  # blender: x, y(=-godot z), z(=godot y)
    verts = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
             (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return _mesh(name, verts, faces)


def box(name, center, size, mat, group, yaw=0.0, pitch=0.0, collide=True):
    """center/size in Godot space. yaw = degrees about +Y (counter-clockwise seen from above),
    pitch = degrees about the box's local X after yaw (positive raises its -Z end)."""
    ob = _object(name, _cube_mesh(name, size), mat, group, collide)
    rot = Matrix.Rotation(math.radians(yaw), 4, "Z") @ Matrix.Rotation(math.radians(pitch), 4, "X")
    ob.matrix_world = Matrix.Translation(g2b(center)) @ rot
    return ob


def frustum(name, cx, cz, y_top, r_top, y_bot, r_bot, mat, group, n=32, collide=True):
    """Vertical cylinder / cone frustum (closed), axis at (cx, cz)."""
    verts = []
    for y, r in ((y_top, r_top), (y_bot, r_bot)):
        for i in range(n):
            a = 2 * math.pi * i / n
            verts.append(tuple(g2b((cx + r * math.cos(a), y, cz + r * math.sin(a)))))
    faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    return _object(name, _mesh(name, verts, faces), mat, group, collide)


def sector(name, cx, cz, r0, r1, a0, a1, top, thick, mat, group, step=5.0, collide=True):
    """Annular sector slab (r0 may be 0: a pie), angles in degrees from +X toward +Z."""
    r0 = max(r0, 0.02)  # a pie keeps a 2 cm inner face instead of welded (degenerate) quads
    n = max(2, int(math.ceil(abs(a1 - a0) / step)) + 1)
    angs = [math.radians(a0 + (a1 - a0) * i / (n - 1)) for i in range(n)]
    verts = []
    # per station: outer top, outer bottom, inner top, inner bottom
    for a in angs:
        c, s = math.cos(a), math.sin(a)
        for r in (r1, r0):
            for y in (top, top - thick):
                verts.append(tuple(g2b((cx + r * c, y, cz + r * s))))
    faces = []
    for i in range(n - 1):
        a, b = 4 * i, 4 * (i + 1)
        faces += [(a, b, b + 2, a + 2),          # top
                  (a + 1, a + 3, b + 3, b + 1),  # bottom
                  (a, a + 1, b + 1, b),          # outer
                  (a + 2, b + 2, b + 3, a + 3)]  # inner
    e = 4 * (n - 1)
    faces += [(0, 2, 3, 1), (e, e + 1, e + 3, e + 2)]
    return _object(name, _mesh(name, verts, faces), mat, group, collide)


def arc_wall(name, cx, cz, r, a0, a1, y0, y1, openings=(), mat="wall", group="Bases", t=WALL_T, seg=7.5):
    """Curved wall along radius r from a0 to a1 (degrees), built from tangent boxes.
    openings: (oa0, oa1, oy0, oy1) angular door / window spans."""
    cuts = sorted({a0, a1, *[o[0] for o in openings], *[o[1] for o in openings]})
    k = 0
    for i in range(len(cuts) - 1):
        s0, s1 = cuts[i], cuts[i + 1]
        if s1 <= a0 or s0 >= a1:
            continue
        mid = (s0 + s1) / 2
        o = next((o for o in openings if o[0] < mid < o[1]), None)
        spans = [(y0, y1)] if o is None else [(y0, o[2]), (o[3], y1)]
        n = max(1, int(math.ceil((s1 - s0) / seg)))
        for j in range(n):
            b0 = s0 + (s1 - s0) * j / n
            b1 = s0 + (s1 - s0) * (j + 1) / n
            am = math.radians((b0 + b1) / 2)
            chord = 2 * r * math.sin(math.radians(b1 - b0) / 2) + (t * 0.5 if o is None else 0.0)
            for h0, h1 in spans:
                if o is not None and abs(h1 - o[2]) < 0.005:
                    h1 -= 0.02
                eff_h0 = h0 + 0.002 if mat == "rail" else h0
                if h1 - eff_h0 < 0.05:
                    continue
                c = (cx + r * math.cos(am), (eff_h0 + h1) / 2, cz + r * math.sin(am))
                box(f"{name}_{k}", c, (t, h1 - eff_h0, chord), mat, group, yaw=-math.degrees(am))
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
            c = (a + b) / 2 + side * sgn * (width / 2 - 0.15) + normal * (rails / 2 + 0.002)
            box(f"{name}_Rail{tag}", tuple(c), (0.3, rails, length), "rail", group, yaw=yaw, pitch=pitch)
    return math.degrees(math.atan2(d.y, horiz))


def marker(name, pos, group="Markers", yaw=0.0):
    ob = bpy.data.objects.new(_unique(name), None)
    ob.empty_display_type = "ARROWS"
    ob.empty_display_size = 1.0
    ob.matrix_world = Matrix.Translation(g2b(pos)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    coll(group).objects.link(ob)
    return ob


def polar(c, r, a_deg, y):
    a = math.radians(a_deg)
    return (c[0] + r * math.cos(a), y, c[1] + r * math.sin(a))


def angle_to(c0, c1):
    return math.degrees(math.atan2(c1[1] - c0[1], c1[0] - c0[0]))


def wrap(a):
    return (a + 180.0) % 360.0 - 180.0


SLOPES = {}

# =========================================================================================
# 1. LAYOUT  (traced overhead, px relative to the map centre; mirrored through the origin)
# =========================================================================================
# Half the platforms, (px x, px y, deck top y). The other half is the point mirror (MIRROR).
HALF = {
    "Central":    (0.0, 0.0, 0.0),
    "RedMid":     (-11.0, -67.5, 0.0),     # Red's middle exit -> Central
    "RedNorth":   (-26.0, -134.0, 2.5),    # Red's north exit, raised
    "NorthPad":   (38.5, -168.0, 4.0),     # the high landing platform (overhead's ship icon)
    "NorthCross": (53.5, -100.5, 1.0),
    "BlueFlank":  (64.5, -34.0, -1.5),     # Blue's low flank exit
}
MIRROR = {"Central": "Central", "RedMid": "BlueMid", "RedNorth": "BlueSouth", "NorthPad": "SouthPad",
          "NorthCross": "SouthCross", "BlueFlank": "RedFlank", "RedBase": "BlueBase"}
MIRROR.update({v: k for k, v in list(MIRROR.items())})
BASE_PX = (-154.0, -73.0)                  # Red base (D centre on its flat side); Blue mirrored

PLAT = {}
for n, (px, py, y) in HALF.items():
    PLAT[n] = (px * PX, py * PX, y)
    PLAT[MIRROR[n]] = (-px * PX, -py * PX, y)
BASES = {"RedBase": (BASE_PX[0] * PX, BASE_PX[1] * PX, 1), "BlueBase": (-BASE_PX[0] * PX, -BASE_PX[1] * PX, -1)}

HALF_BRIDGES = [("RedNorth", "NorthPad"), ("RedNorth", "RedMid"), ("RedNorth", "RedBase"),
                ("NorthPad", "NorthCross"), ("NorthCross", "RedMid"), ("NorthCross", "BlueFlank"),
                ("RedMid", "Central"), ("RedMid", "RedBase"), ("BlueFlank", "Central"), ("BlueFlank", "BlueBase")]
BRIDGES = list(HALF_BRIDGES) + [(MIRROR[a], MIRROR[b]) for a, b in HALF_BRIDGES]
# Dead-end landing nubs (sniper / trick-jump perches), angle from the platform centre.
HALF_NUBS = [("RedNorth", -146.0), ("NorthPad", 23.0), ("NorthPad", -117.0), ("NorthCross", -36.0),
             ("RedMid", 27.0), ("BlueFlank", 11.0)]
NUBS = list(HALF_NUBS) + [(MIRROR[p], wrap(a + 180.0)) for p, a in HALF_NUBS]
NUB_LEN, NUB_PAD_R, NUB_W = 6.0, 2.2, 2.2


def node_xz(n):
    if n in PLAT:
        return PLAT[n][0], PLAT[n][1]
    return BASES[n][0], BASES[n][1]


def node_y(n):
    return PLAT[n][2] if n in PLAT else 0.0


def base_to_world(base, u, v):
    bx, bz, f = BASES[base]
    return bx + f * u, bz + f * v


def base_angle(base, a_local):
    return a_local if BASES[base][2] > 0 else wrap(a_local + 180.0)


# connection angles per platform (bridges + nubs), for laying out cover clear of the lanes
CONN = {n: [] for n in list(PLAT) + list(BASES)}
for a, b in BRIDGES:
    CONN[a].append(angle_to(node_xz(a), node_xz(b)))
    CONN[b].append(angle_to(node_xz(b), node_xz(a)))
for p, a in NUBS:
    CONN[p].append(a)


def gaps(n):
    """(mid angle, width) of the free arcs between connections, widest first."""
    angs = sorted(wrap(a) for a in CONN[n])
    out = []
    for i, a in enumerate(angs):
        b = angs[(i + 1) % len(angs)] + (360.0 if i == len(angs) - 1 else 0.0)
        out.append((wrap((a + b) / 2), b - a))
    return sorted(out, key=lambda g: (-round(g[1], 3), g[0]))


# =========================================================================================
# 2. PLATFORMS  (round decks on stilts; cap + crates + lamps clear of the lanes)
# =========================================================================================
PLAT_INFO = {}   # name -> {"weapon": pos, "spawn": pos, "roam": pos}
for n, (x, z, y) in PLAT.items():
    g = "Platforms"
    frustum(f"{n}_Deck", x, z, y, DECK_R, y - DECK_T, DECK_R, "deck", g)
    frustum(f"{n}_Underside", x, z, y - DECK_T, DECK_R - 0.3, y - 7.0, 2.4, "under", g, collide=False)
    frustum(f"{n}_Stilt", x, z, y - 7.0, 1.6, OCEAN - 2.0, 1.6, "under", g, n=12, collide=False)
    gp = gaps(n)
    if n == "Central":
        # the most-fought platform: four turret emplacements between the four bridges, DER in the middle
        for i, (a, _w) in enumerate(gp):
            box(f"Central_Emplacement_{i}", polar((x, z), 5.6, a, y + 0.752), (2.4, 1.5, 2.4), "cover", g, yaw=-a)
            box(f"Central_Lamp_{i}", polar((x, z), 8.3, a, y + 2.252), (0.5, 4.5, 0.5), "lamp", g)
        tight = min(gp, key=lambda q: (q[1], q[0]))
        PLAT_INFO[n] = {"weapon": (x, y, z), "spawn": polar((x, z), 3.0, gp[0][0], y),
                        "roam": polar((x, z), 2.5, tight[0], y)}
        continue
    frustum(f"{n}_Cap", x, z, y + 1.1, 2.0, y - 0.1, 2.3, "cover", g)   # dome cap: chest-high cover
    for i, (a, w) in enumerate(gp):
        if w > 50.0:
            box(f"{n}_Lamp_{i}", polar((x, z), 8.3, a, y + 2.252), (0.5, 4.5, 0.5), "lamp", g)
    box(f"{n}_Crate_A", polar((x, z), 5.8, gp[0][0], y + 0.702), (2.4, 1.4, 1.6), "cover", g, yaw=-gp[0][0])
    if len(gp) > 1:
        box(f"{n}_Crate_B", polar((x, z), 5.8, gp[1][0], y + 0.752), (1.8, 1.5, 1.8), "cover", g, yaw=-gp[1][0] + 20)
    PLAT_INFO[n] = {"weapon": polar((x, z), 3.4, gp[0][0], y),
                    "spawn": polar((x, z), 3.6, gp[1][0] if len(gp) > 1 else gp[0][0] + 180, y),
                    "roam": polar((x, z), 4.0, gp[0][0], y)}

# Landing nubs: railed catwalk + small round pad, same height as their platform
for i, (p, a) in enumerate(NUBS):
    x, z, y = PLAT[p]
    ramp(f"Nub_{p}_{i}", polar((x, z), DECK_R, a, y), polar((x, z), DECK_R + NUB_LEN, a, y), NUB_W,
         mat="bridge", group="Nubs", thick=0.4, rails=RAIL_H)
    c = polar((x, z), DECK_R + NUB_LEN + NUB_PAD_R - 0.4, a, y)
    frustum(f"NubPad_{p}_{i}", c[0], c[2], y, NUB_PAD_R, y - 0.6, NUB_PAD_R, "deck", "Nubs")
    frustum(f"NubPost_{p}_{i}", c[0], c[2], y - 0.6, 0.5, OCEAN - 2.0, 0.5, "under", "Nubs", n=8, collide=False)

# =========================================================================================
# 3. BRIDGES  (railed, sloped where the decks differ in height)
# =========================================================================================
for a, b in BRIDGES:
    ca, cb = node_xz(a), node_xz(b)
    ya, yb = node_y(a), node_y(b)
    ra = PLAZA_R if a in BASES else DECK_R
    rb = PLAZA_R if b in BASES else DECK_R
    ang = angle_to(ca, cb)
    p0 = polar(ca, ra, ang, ya)
    p1 = polar(cb, rb, ang + 180.0, yb)
    mat = "ramp" if abs(ya - yb) > 0.2 else "bridge"
    SLOPES[f"Bridge_{a}_{b}"] = ramp(f"Bridge_{a}_{b}", p0, p1, BRIDGE_W, mat=mat, group="Bridges",
                                     thick=0.5, rails=RAIL_H)
    mx, mz = (p0[0] + p1[0]) / 2, (p0[2] + p1[2]) / 2
    frustum(f"BridgePylon_{a}_{b}", mx, mz, min(ya, yb) - 0.6, 0.6, OCEAN - 2.0, 0.6, "under", "Bridges",
            n=8, collide=False)

# =========================================================================================
# 4. BASES  (Red west, Blue east; identical in their local u/v frame)
#    plaza (open deck, r 31) | facility hall (r 13, roof 8 = sniping post) | round cloning lab
#    behind the flat side | two landing pads at the flat side's ends
# =========================================================================================
BASE_INFO = {}
for base in BASES:
    bx, bz, f = BASES[base]
    g = base
    team = "Red" if base == "RedBase" else "Blue"

    def W(u, v, y=0.0):
        x, z = base_to_world(base, u, v)
        return (x, y, z)

    def A(a):
        return base_angle(base, a)

    def lbox(name, u, y, v, su, sy, sv, mat="wall", yaw_local=0.0, collide=True):
        x, z = base_to_world(base, u, v)
        box(name, (x, y, z), (su, sy, sv), mat, g, yaw=-A(yaw_local) if yaw_local else 0.0, collide=collide)

    a0, a1 = A(-90.0), A(90.0)
    if a1 < a0:
        a1 += 360.0
    # decks: plaza + hall floor (one pie), roof, lab, pads, undersides
    sector(f"{base}_Plaza", bx, bz, 0.0, PLAZA_R, a0, a1, 0.0, 1.2, "deck", g)
    sector(f"{base}_Underside", bx, bz, 0.0, PLAZA_R - 0.5, a0, a1, -1.2, 6.0, "under", g, collide=False)
    for i, (r, a) in enumerate(((20.0, -60.0), (20.0, 0.0), (20.0, 60.0), (8.0, 0.0))):
        c = polar((bx, bz), r, A(a), 0)
        frustum(f"{base}_Stilt_{i}", c[0], c[2], -7.0, 2.0, OCEAN - 2.0, 2.0, "under", g, n=12, collide=False)
    lc = W(*LAB_C)
    frustum(f"{base}_LabFloor", lc[0], lc[2], 0.0, LAB_R + 0.4, -1.2, LAB_R + 0.4, "floor", g)
    frustum(f"{base}_LabUnderside", lc[0], lc[2], -1.2, LAB_R, -6.0, 2.5, "under", g, collide=False)
    for s in (1, -1):
        c0, c1 = W(-12.0, s * 17.0), W(0.3, s * 25.0)
        x0, x1 = sorted((c0[0], c1[0]))
        z0, z1 = sorted((c0[2], c1[2]))
        box(f"{base}_LandingPad_{'N' if s * f < 0 else 'S'}", ((x0 + x1) / 2, -0.3, (z0 + z1) / 2),
            (x1 - x0, 0.6, z1 - z0), "pad", g)
        lbox(f"{base}_Gunship_{s}", -7.5, 1.4, s * 23.0, 7.0, 2.8, 2.6, "cover")  # parked LAAT / landing craft
    # facility hall: curved front wall with three doors and firing slits, flat back wall to the lab
    doors = [(-52.0, -40.0), (-6.0, 6.0), (40.0, 52.0)]
    slits = [(-30.0, -20.0), (20.0, 30.0), (-80.0, -68.0), (68.0, 80.0)]
    openings = [(A(d0), A(d1), 0.0, DOOR) for d0, d1 in doors] + [(A(s0), A(s1), 1.3, 2.5) for s0, s1 in slits]
    openings = [(o0 + (360.0 if o0 < a0 - 1e-6 else 0.0), o1 + (360.0 if o1 < a0 - 1e-6 else 0.0), y0, y1)
                for o0, o1, y0, y1 in openings]
    arc_wall(f"{base}_HallWall", bx, bz, HALL_R, a0, a1, 0.0, HALL_H, openings, group=g)
    for v0, v1 in ((-HALL_R, -2.6), (2.6, HALL_R)):
        lbox(f"{base}_BackWall", 0.3, HALL_H / 2, (v0 + v1) / 2, WALL_T, HALL_H, v1 - v0)
    lbox(f"{base}_BackWall_Lintel", 0.3, (DOOR + HALL_H) / 2, 0.0, WALL_T, HALL_H - DOOR, 5.2)
    sector(f"{base}_HallRoof", bx, bz, 0.0, HALL_R + WALL_T / 2, a0, a1, HALL_H, 0.5, "floor", g)
    arc_wall(f"{base}_RoofParapet", bx, bz, HALL_R, a0 + 24.0, a1 - 24.0, HALL_H, HALL_H + 1.05,
             group=g, t=0.3, mat="rail")
    lbox(f"{base}_RoofParapet_Back", 0.15, HALL_H + 0.527, 0.0, 0.3, 1.05, 2 * HALL_R)
    lbox(f"{base}_Roof_Cover", 9.5, HALL_H + 0.552, 0.0, 0.8, 1.1, 4.0, "cover")
    for i, (r, a) in enumerate(((8.5, -35.0), (8.5, 35.0), (9.0, -75.0), (9.0, 75.0))):
        c = polar((bx, bz), r, A(a), HALL_H / 2)
        box(f"{base}_HallColumn_{i}", c, (0.8, HALL_H, 0.8), "wall", g)
    lbox(f"{base}_Hall_Cover_A", 6.5, 0.602, -5.0, 0.6, 1.2, 3.0, "cover")
    lbox(f"{base}_Hall_Cover_B", 6.5, 0.602, 5.0, 0.6, 1.2, 3.0, "cover")
    # cloning lab: round room, open toward the hall, clone tanks as cover
    la0 = A(25.0) + 0.0
    arc_wall(f"{base}_LabWall", lc[0], lc[2], LAB_R, la0, la0 + 310.0, 0.0, LAB_H, group=g)
    frustum(f"{base}_LabRoof", lc[0], lc[2], LAB_H + 0.4, LAB_R + 0.3, LAB_H, LAB_R + 0.3, "floor", g)
    for i, (u, v) in enumerate(((-4.5, 3.5), (-4.5, -3.5), (-10.0, 3.0), (-10.0, -3.0))):
        c = W(u, v)
        frustum(f"{base}_CloneTank_{i}", c[0], c[2], 3.2, 0.8, 0.0, 0.8, "tank", g, n=16)
    frustum(f"{base}_LabConsole", lc[0], lc[2], 1.1, 1.2, 0.0, 1.4, "cover", g, n=16)
    # exterior ramps from the plaza's back corners up to the roof (the sniping post)
    for s in (1, -1):
        SLOPES[f"{base}_RoofRamp_{s}"] = ramp(f"{base}_RoofRamp_{s}", W(3.0, s * 27.5, 0.0),
                                              W(3.0, s * (HALL_R + 0.1), HALL_H), 3.0, group=g, rails=RAIL_H)
    # plaza edge: low parapet with gaps at the bridges, back-edge parapets beside the pads
    bridge_local = [wrap(a - (0.0 if f > 0 else 180.0)) for a in CONN[base]]
    cuts = [-90.0]
    for a in sorted(bridge_local):
        cuts += [a - 5.5, a + 5.5]
    cuts.append(90.0)
    for i in range(0, len(cuts), 2):
        if cuts[i + 1] - cuts[i] > 1.0:
            s0, s1 = A(cuts[i]), A(cuts[i + 1])
            if s1 < s0:
                s1 += 360.0
            arc_wall(f"{base}_PlazaParapet", bx, bz, PLAZA_R - 0.2, s0, s1, 0.0, 1.0, group=g, t=0.4, mat="rail")
    for s in (1, -1):
        for v0, v1 in ((HALL_R + 0.3, 17.0), (25.0, PLAZA_R)):
            lbox(f"{base}_BackParapet", 0.2, 0.502, s * (v0 + v1) / 2, 0.4, 1.0, v1 - v0, "rail")
    # plaza cover: blast walls before the doors, turret emplacements, crates, lamps
    for i, (r, a, size) in enumerate(((17.0, 0.0, (0.6, 1.4, 4.0)), (17.0, -46.0, (0.6, 1.4, 3.0)),
                                       (17.0, 46.0, (0.6, 1.4, 3.0)))):
        c = polar((bx, bz), r, A(a), 0.702)
        box(f"{base}_BlastWall_{i}", c, size, "cover", g, yaw=-A(a))
    for i, (r, a) in enumerate(((23.0, -25.0), (23.0, 25.0))):
        c = polar((bx, bz), r, A(a), 0.752)
        box(f"{base}_Emplacement_{i}", c, (2.4, 1.5, 2.4), "cover", g, yaw=-A(a))
    for i, (r, a) in enumerate(((24.0, -62.0), (24.0, 62.0))):
        c = polar((bx, bz), r, A(a), 0.752)
        box(f"{base}_Crate_{i}", c, (2.0, 1.5, 2.0), "cover", g, yaw=-A(a) + 15.0)
    for i, a in enumerate((-80.0, -55.0, -12.0, 22.0, 75.0)):
        if min(abs(wrap(a - b)) for b in bridge_local) > 9.0:
            c = polar((bx, bz), PLAZA_R - 1.2, A(a), 2.502)
            box(f"{base}_Lamp_{i}", c, (0.5, 5.0, 0.5), "lamp", g)
    BASE_INFO[base] = {
        "team": team,
        "spawns": [W(19.0, -4.0), W(19.0, 4.0), W(14.0, -22.0), W(14.0, 22.0), W(4.0, -8.0), W(4.0, 8.0),
                   W(-12.0, 0.0), W(-6.0, -18.8), W(-6.0, 18.8), W(4.0, -6.0, HALL_H), W(4.0, 6.0, HALL_H)],
        "ffa": [W(25.0, 0.0), W(-12.0, 0.0), W(4.0, 6.0, HALL_H)],
        "carbine": W(6.0, 0.0, HALL_H),
        "pistol": W(-3.5, 0.0),
        "roam": [("Plaza", W(22.0, 0.0), 1.5), ("PlazaN", W(15.0, -20.0), 1.0), ("PlazaS", W(15.0, 20.0), 1.0),
                 ("Hall", W(6.0, 0.0), 1.0), ("Lab", W(-11.5, 0.0), 0.5), ("Roof", W(5.0, -3.0, HALL_H), 1.5),
                 ("PadN", W(-3.0, -18.8), 0.5), ("PadS", W(-3.0, 18.8), 0.5)],
    }

# =========================================================================================
# 5. OCEAN AND DISTANT TIPOCA CITY  (visual only)
# =========================================================================================
box("Ocean", (0.0, OCEAN, 0.0), (700.0, 0.1, 700.0), "sea", "Ocean", collide=False)
for i, (x, z, r, h) in enumerate(((-150.0, -130.0, 40.0, 22.0), (40.0, -190.0, 55.0, 30.0), (190.0, -40.0, 45.0, 18.0),
                                  (150.0, 140.0, 40.0, 22.0), (-40.0, 190.0, 55.0, 30.0), (-190.0, 40.0, 45.0, 18.0))):
    frustum(f"Tipoca_{i}", x, z, h, r, h - 10.0, r * 0.8, "city", "Ocean", n=24, collide=False)
    frustum(f"Tipoca_{i}_Stilt", x, z, h - 10.0, 6.0, OCEAN - 1.0, 6.0, "city", "Ocean", n=12, collide=False)
    frustum(f"Tipoca_{i}_Spire", x, z, h + 18.0, 1.5, h, 4.0, "city", "Ocean", n=12, collide=False)

# =========================================================================================
# 6. MARKERS  (y = floor top; the Godot scene lifts spawns 5 cm)
# =========================================================================================
for base, info in BASE_INFO.items():
    face = 90.0 if info["team"] == "Red" else -90.0   # SpawnManager re-aims at the map centre anyway
    for i, p in enumerate(info["spawns"]):
        marker(f"SPAWN_{info['team']}_{i:02d}", p, yaw=face)
ffa = [PLAT_INFO[n]["spawn"] for n in sorted(PLAT_INFO)]
for base in sorted(BASE_INFO):
    ffa += BASE_INFO[base]["ffa"]
for i, p in enumerate(ffa):
    marker(f"SPAWN_FFA_{i:02d}", p)

WEAPONS = [
    ("WPN_DirectedEnergyRifle_Central", PLAT_INFO["Central"]["weapon"]),   # the one power weapon, mid
    ("WPN_Longsword_NorthPad", PLAT_INFO["NorthPad"]["weapon"]),         # high landing platforms (a longsword each: point symmetric)
    ("WPN_Longsword_SouthPad", PLAT_INFO["SouthPad"]["weapon"]),
    ("WPN_MarksmanCarbine_RedRoof", BASE_INFO["RedBase"]["carbine"]),      # BF2's sniping post
    ("WPN_MarksmanCarbine_BlueRoof", BASE_INFO["BlueBase"]["carbine"]),
    ("WPN_StandardIssueRifle_RedNorth", PLAT_INFO["RedNorth"]["weapon"]),
    ("WPN_StandardIssueRifle_BlueSouth", PLAT_INFO["BlueSouth"]["weapon"]),
    ("WPN_StandardIssueRifle_RedFlank", PLAT_INFO["RedFlank"]["weapon"]),
    ("WPN_StandardIssueRifle_BlueFlank", PLAT_INFO["BlueFlank"]["weapon"]),
    ("WPN_ServicePistol_RedLab", BASE_INFO["RedBase"]["pistol"]),
    ("WPN_ServicePistol_BlueLab", BASE_INFO["BlueBase"]["pistol"]),
]
for n, p in WEAPONS:
    marker(n, p)

ROAM = []
for n in sorted(PLAT_INFO):
    w = 1.5 if n == "Central" else (1.2 if n in ("NorthPad", "SouthPad") else 1.0)
    ROAM.append((n, PLAT_INFO[n]["roam"], w))
for base in sorted(BASE_INFO):
    for tag, p, w in BASE_INFO[base]["roam"]:
        ROAM.append((base + tag, p, w))
for n, p, _w in ROAM:
    marker("CALLOUT_" + n, p, group="Callouts")

# =========================================================================================
# report slopes, save, export
# =========================================================================================
print("\n== Kamino greybox: slopes (deg; floor_max_angle 50, nav max 45) ==")
for n, s in SLOPES.items():
    flag = "  !! too steep" if abs(s) > 45 else ""
    print(f"  {n:40s} {s:6.1f}{flag}")
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
        joined.name = f"Kamino_{mat_name[4:].capitalize()}{'_col' if is_col else '_vis'}{col_suffix}"

        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.remove_doubles(threshold=0.002)
        bpy.ops.mesh.dissolve_degenerate()
        bpy.ops.object.mode_set(mode="OBJECT")

_clean_and_join_by_material()

n_col = sum(1 for o in bpy.data.objects if o.name.endswith("-col"))
n_mark = sum(1 for o in bpy.data.objects if o.type == "EMPTY")
print(f"  objects: {n_col} collision meshes, {n_mark} markers")
xs = [v[0] for v in PLAT.values()] + [b[0] for b in BASES.values()]
zs = [v[1] for v in PLAT.values()] + [b[1] for b in BASES.values()]
print(f"  platform / base centres span x {min(xs):.1f}..{max(xs):.1f}, z {min(zs):.1f}..{max(zs):.1f}")

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
LEVEL_TSCN = _arg("--level-tscn", "scenes/levels/kamino.tscn")
MAIN_TSCN = _arg("--main-tscn", "scenes/main/main_kamino.tscn")
ARENA_TSCN = _arg("--arena-tscn", "scenes/main/arena_kamino.tscn")
KILL_Y = -12.0


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
    '[ext_resource type="PackedScene" path="res://assets/models/environment/kamino_greybox.glb" id="1_glb"]',
    '[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="3_kill"]',
    '[ext_resource type="Script" path="res://scripts/levels/level_materials.gd" id="4_mat"]',
    "",
    '[sub_resource type="BoxShape3D" id="Shape_Kill"]',
    "size = Vector3(400, 2, 400)",
    "",
    "; GENERATED by tools/kamino/build_kamino.py - edit the script, not this file.",
    '[node name="Kamino" type="Node3D"]',
    "",
    '[node name="LevelMaterials" type="Node" parent="."]',
    'script = ExtResource("4_mat")',
    "",
    '[node name="Greybox" parent="." instance=ExtResource("1_glb")]',
    "",
    f"; the ocean: anything that falls off a platform or bridge (decks -1.5 .. 8, sea {OCEAN:g})",
    '[node name="KillVolume" type="Area3D" parent="."]',
    "transform = " + _xf((0.0, KILL_Y, 0.0)),
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
# Point symmetric like the rest of the map: each Red / North spot and its (-x, -z) twin. Frags in
# the base halls and on the flank platforms, stickies on the crossings.
GRENADES = []
for _n, _twin, _kind, (_x, _y, _z) in (("RedHall", "BlueHall", "frag", (-49.5, 0.0, -26.25)),
                                        ("RedFlank", "BlueFlank", "frag", (-26.75, -1.5, 15.75)),
                                        ("NorthCross", "SouthCross", "sticky", (23.0, 1.0, -34.75))):
    _tag = "Frags_" if _kind == "frag" else "Stickies_"
    GRENADES += [(_tag + _n, _kind, (_x, _y, _z)), (_tag + _twin, _kind, (-_x, _y, -_z))]

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
# Stormy Kamino: a cool, dim key light from high in the south-west.
SUN = ["[node name=\"Sun\" type=\"DirectionalLight3D\" parent=\".\"]",
       "transform = Transform3D(0.707107, 0.40558, -0.579228, 0, 0.819152, 0.573576, 0.707107, -0.40558, 0.579228, 0, 40, 0)",
       "light_color = Color(0.78, 0.84, 0.95, 1)", "light_energy = 1.1", "shadow_enabled = true",
       "shadow_bias = 0.04", "shadow_normal_bias = 2.0", "directional_shadow_mode = 2",
       "directional_shadow_split_1 = 0.07", "directional_shadow_split_2 = 0.2", "directional_shadow_split_3 = 0.5",
       "directional_shadow_blend_splits = true", "directional_shadow_fade_start = 0.85",
       "directional_shadow_max_distance = 220.0", "light_bake_mode = 0", ""]
LIGHTMAP = []
first = [sp for sp in _spawn_list() if sp[0].startswith("SPAWN_Red")][0]


def _pickups():
    out = []
    for n, p in WEAPONS:
        f, rid, respawn = GUN[n.split("_")[1]]
        out += [f'[node name="{n[4:]}" parent="." instance=ExtResource("8_pickup")]', "transform = " + _xf(p),
                f'weapon_scene = ExtResource("{rid}")'] + ([f"respawn_delay = {respawn}"] if respawn else []) + [""]
    return out


ml = ["[gd_scene load_steps=10 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/kamino.tscn" id="1_level"]']
for f, rid, _ in GUN.values():
    ml.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
ml += GRENADE_EXT
ml += ['[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
       '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
       '[ext_resource type="Environment" path="res://resources/environments/outdoor_environment.tres" id="9_env"]',
       "", "; GENERATED by tools/kamino/build_kamino.py - offline balance testbed (no bots).",
       '[node name="MainKamino" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', ""]
ml += SUN + ['[node name="Kamino" parent="." instance=ExtResource("1_level")]', ""] + LIGHTMAP
ml += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
ml += _pickups()
_grenade_nodes(ml)
open(MAIN_TSCN, "w").write("\n".join(ml))

# Arena (Bot Arena + LAN): pickups, bots, runtime navmesh, roam points, NetMatch before SpawnManager
# (its _ready configures SpawnManager: mode, bot count), like arena_headlong.tscn.
al = ["[gd_scene load_steps=18 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/kamino.tscn" id="1_level"]',
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
al += ["", "; GENERATED by tools/kamino/build_kamino.py - arena mode (Bot Arena / LAN) on Kamino.",
       '[node name="ArenaKamino" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', ""]
al += SUN + ['[node name="ArenaEvents" type="Node" parent="."]', 'script = ExtResource("11_events")', "",
             '[node name="Kamino" parent="." instance=ExtResource("1_level")]', ""] + LIGHTMAP
al += ['[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
al += _pickups()
_grenade_nodes(al)
al += ['[node name="Navigation" type="NavigationRegion3D" parent="."]', 'script = ExtResource("12_nav")',
       'geometry_root = NodePath("../Kamino")', "",
       '[node name="NavPoints" type="Node3D" parent="."]', ""]
for n, p, w in ROAM:
    al += [f'[node name="{n}" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]',
           "transform = " + _xf((p[0], p[1] + 0.05, p[2])), f"metadata/weight = {w:g}", f'metadata/callout = "{n}"', ""]
al += ['[node name="NetMatch" type="Node" parent="."]', 'script = ExtResource("13_net")', "",
       '[node name="SpawnManager" type="Node" parent="."]', 'script = ExtResource("14_spawns")',
       'bot_scene = ExtResource("10_bot")', "bot_count = 7", 'difficulty = ExtResource("15_diff")',
       'spawn_roots = Array[NodePath]([NodePath("../Kamino/Spawns")])', ""]
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
    roofs = [o for o in bpy.data.objects if any(k in o.name for k in ("HallRoof", "LabRoof", "RoofParapet",
                                                                     "Roof_Cover", "Tipoca"))]

    def shoot(fname, loc, rot, ortho=None, res=(1600, 1600), hidden=()):
        for o in hidden:
            o.hide_render = True
        cam_data = bpy.data.cameras.new(fname)
        if ortho:
            cam_data.type = "ORTHO"
            cam_data.ortho_scale = ortho
        else:
            cam_data.lens = 24
        cam_data.clip_end = 2000
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
    shoot("kamino_overhead", (0, 0, 150), (0, 0, 0), ortho=160)
    shoot("kamino_overhead_interiors", (0, 0, 150), (0, 0, 0), ortho=160, hidden=roofs)
    shoot("kamino_persp_from_red", (-95, 40, 35), (68, 0, -115), res=(1920, 1080))
    shoot("kamino_persp_central", (30, -45, 18), (75, 0, 35), res=(1920, 1080))
    print("  previews in", PREVIEWS)
