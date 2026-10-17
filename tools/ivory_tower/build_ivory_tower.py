"""Build the Ivory Tower (Halo 2, 2004) greybox (.glb + .blend), its Godot scenes and preview
renders with headless Blender.

Usage (from the repo root):
  blender -b --factory-startup --python tools/ivory_tower/build_ivory_tower.py -- \
      [--glb assets/models/environment/ivory_tower_greybox.glb] [--blend tools/ivory_tower/ivory_tower_greybox.blend] \
      [--previews tools/ivory_tower/previews] [--no-render]

ALL geometry is ESTIMATED: read from the MCC Ivory Tower loading-screen plans, the Bungie
"Cyclotron" design doc and in-game screenshots (see ivory_tower_spec.md for sources/confidence).

Authored in GODOT space: metres, +Y up, +X east, -Z north. North = the elevator / stone-steps end
(top of the MCC plan); the sunken palm plaza is the origin. g2b() converts to Blender space; the
glTF exporter (export_yup) converts back.

Three floors: L0 y 0 (plaza, canyon alley, lower halls), L1 y 4.5 (catwalk ring, top of the
stone steps, Dark Room / Light Room), L2 y 9 (north walkway with the sniper, side galleries).

Naming for the Godot importer:
  *-col      mesh + StaticBody3D with trimesh collision (World layer 1)
  *-colonly  collision only, no mesh (the atrium skylight, so the sun still gets in)
  no suffix  visual only (water)
  Empties    SPAWN_*, WPN_*, PWR_*, FLAG_*, LIFT_*, CALLOUT_* become Node3D markers.
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


GLB = _arg("--glb", "assets/models/environment/ivory_tower_greybox.glb")
BLEND = _arg("--blend", "tools/ivory_tower/ivory_tower_greybox.blend")
PREVIEWS = _arg("--previews", "tools/ivory_tower/previews")
RENDER = "--no-render" not in argv and PREVIEWS != ""

# Player reference (scripts/player/player.gd): 2.1 m body, jump_height 2.2, stand_speed 7.5,
# gravity 22 -> ~0.89 s airtime, ~6.7 m flat running jump. floor_max_angle 50 deg, step 0.35.
L0, L1, L2 = 0.0, 4.5, 9.0
ROOF = 13.5          # wings + north block ceiling
ATRIUM_ROOF = 17.0   # skylight over the main room
SLAB_T = 0.4
WALL_T = 0.5
PLAZA_R = 10.0       # sunken plaza radius (inner face of the retaining wall)
DOOR = 3.0           # door height above its floor

# footprint
FX0, FX1, FZ0, FZ1 = -30.0, 30.0, -40.0, 18.0
AX = 16.0            # atrium walls at x = +-16
AZN = -29.0          # atrium north edge (L2 balcony)
TX = 11.0            # inner walls of the lower side halls / terrace edges (x = +-11)
CANYON = 1.5         # central alley half-width
TERR_S = -6.0        # terraces start here (y 0) and climb north
TERR_N = -28.0       # top of the stone steps (y 4.5) ends here, Lower North Hall beyond
LIFT = (0.0, -34.0)  # elevator shaft centre


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
    "ground": "#9a9284",   # L0 stone floors
    "plaza": "#b9b1a0",    # plaza flagstones
    "grass": "#5f7a3c",    # stone-step terraces
    "floor": "#b4b4b4",    # L1 / L2 floors
    "wood": "#a0703c",     # catwalk ring (wooden in H2)
    "wall": "#c8bfa8",     # ivory walls
    "trim": "#6c6f73",     # rails, pillars, lintels
    "ramp": "#c0843a",     # anything sloped you can walk (other than grass)
    "cover": "#455a64",    # crates, benches, partitions
    "rock": "#5b5550",     # terrace boulders
    "palm": "#6b4f2a",
    "lift": "#2e86c1",
    "water": "#3d87b5",
    "dark": "#2b2b33",     # Dark Room floor
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


def _cube_mesh(name, size):
    """Axis-aligned box mesh centred on its origin, size given in GODOT axes (x, y, z)."""
    sx, sy, sz = size
    hx, hy, hz = sx / 2, sz / 2, sy / 2  # blender: x, y(=-godot z), z(=godot y)
    verts = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
             (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return _mesh(name, verts, faces)


def _link(full, me, mat, group):
    ob = bpy.data.objects.new(full, me)
    if mat:
        ob.data.materials.append(_mat[mat])
        ob.color = _mat[mat].diffuse_color
    coll(group).objects.link(ob)
    return ob


def box(name, center, size, mat, group, yaw=0.0, pitch=0.0, suffix="-col"):
    """center/size in Godot space. yaw = degrees about +Y (counter-clockwise seen from above),
    pitch = degrees about the box's local X after yaw (positive raises its -Z end).
    suffix: "-col" (mesh + collision), "-colonly" (collision only), "" (visual only)."""
    full = _unique(name) + suffix
    ob = _link(full, _cube_mesh(full, size), mat, group)
    rot = Matrix.Rotation(math.radians(yaw), 4, "Z") @ Matrix.Rotation(math.radians(pitch), 4, "X")
    ob.matrix_world = Matrix.Translation(g2b(center)) @ rot
    return ob


def slab(name, x0, x1, z0, z1, top, thick, mat, group, suffix="-col"):
    box(name, ((x0 + x1) / 2, top - thick / 2, (z0 + z1) / 2), (x1 - x0, thick, z1 - z0), mat, group, suffix=suffix)


def prism(name, pts, top, thick, mat, group):
    """Vertical prism over a CONVEX (x, z) polygon, top face at `top`."""
    clean = []
    for p in pts:
        if not clean or (Vector(p) - Vector(clean[-1])).length > 1e-4:
            clean.append(p)
    if (Vector(clean[0]) - Vector(clean[-1])).length < 1e-4:
        clean.pop()
    n = len(clean)
    verts = [tuple(g2b((x, top, z))) for x, z in clean] + [tuple(g2b((x, top - thick, z))) for x, z in clean]
    faces = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    full = _unique(name) + "-col"
    _link(full, _mesh(full, verts, faces), mat, group)


def wedge(name, x0, x1, z_lo, z_hi, y_lo, y_hi, mat, group, base=L0):
    """Solid stepped-terrace block: floor at `base`, top sloping from y_lo at z_lo to y_hi at
    z_hi (both z's given; z_hi is the high end). Returns the slope in degrees."""
    verts = []
    for z, y in ((z_lo, y_lo), (z_hi, y_hi)):
        for x in (x0, x1):
            verts.append(tuple(g2b((x, base, z))))
            verts.append(tuple(g2b((x, max(y, base + 0.02), z))))
    # 0 lo-x0-bot 1 lo-x0-top 2 lo-x1-bot 3 lo-x1-top 4 hi-x0-bot 5 hi-x0-top 6 hi-x1-bot 7 hi-x1-top
    faces = [(1, 3, 7, 5), (0, 4, 6, 2), (0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3)]
    full = _unique(name) + "-col"
    _link(full, _mesh(full, verts, faces), mat, group)
    return math.degrees(math.atan2(abs(y_hi - y_lo), abs(z_hi - z_lo)))


def floor_holes(name, x0, x1, z0, z1, top, holes, mat="floor", group="Floors", thick=SLAB_T):
    """Floor slab with rectangular holes (stairwells, shafts). Splits into strips along X then Z."""
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
    merged = []
    for c in sorted(cells):
        if merged and merged[-1][0] == c[0] and merged[-1][1] == c[1] and abs(merged[-1][3] - c[2]) < 1e-6:
            merged[-1][3] = c[3]
        else:
            merged.append(c)
    for k, (a, b, c, d) in enumerate(merged):
        slab(f"{name}_{k}", a, b, c, d, top, thick, mat, group)


def wall(name, axis, fixed, a0, a1, y0, y1, openings=(), group="Walls", mat="wall", t=WALL_T):
    """Straight wall. axis 'x': runs along X at z=fixed; 'z': runs along Z at x=fixed.
    openings: (a, b, oy0, oy1) door/window spans along the wall (non-overlapping)."""
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


def mirror_wall(name, fixed, a0, a1, y0, y1, openings=(), group="Walls", mat="wall"):
    """Pair of 'z' walls at x = -fixed (W) and +fixed (E)."""
    wall(name + "_W", "z", -fixed, a0, a1, y0, y1, openings, group, mat)
    wall(name + "_E", "z", fixed, a0, a1, y0, y1, openings, group, mat)


def ramp(name, p0, p1, width, mat="ramp", group="Ramps", thick=0.4):
    """Sloped slab whose TOP surface runs from p0 to p1 (Godot x, y, z of the centreline).
    Ends meet floors cleanly without over-length penetration."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    horiz = math.hypot(d.x, d.z)
    length = d.length
    yaw = math.degrees(math.atan2(-d.x, -d.z))
    pitch = math.degrees(math.atan2(d.y, horiz))
    fwd = d.normalized()
    side = fwd.cross(Vector((0, 1, 0))).normalized()
    normal = side.cross(fwd).normalized()
    mid = (a + b) / 2 - normal * (thick / 2)
    box(name, tuple(mid), (width, thick, length), mat, group, yaw=yaw, pitch=pitch)
    return math.degrees(math.atan2(d.y, horiz))


def parapet(name, x0, z0, x1, z1, top, h=1.05, group="Rails"):
    """1.05 m rail standing on a floor whose top is `top`, along a straight line."""
    d = Vector((x1 - x0, 0, z1 - z0))
    yaw = math.degrees(math.atan2(-d.x, -d.z))
    box(name, ((x0 + x1) / 2, top + 0.002 + h / 2, (z0 + z1) / 2), (0.3, h, d.length), "trim", group, yaw=yaw)


def arc_pt(r, deg):
    """Point on a circle round the plaza centre; 0 deg = east, 90 deg = south (+Z)."""
    return (r * math.cos(math.radians(deg)), r * math.sin(math.radians(deg)))


def arc_angles(a0, a1, step=10.0, extra=()):
    n = max(1, int(math.ceil((a1 - a0) / step)))
    return sorted({*[a0 + (a1 - a0) * i / n for i in range(n + 1)], *[e for e in extra if a0 < e < a1]})


def marker(name, pos, group="Markers", yaw=0.0):
    ob = bpy.data.objects.new(_unique(name), None)
    ob.empty_display_type = "ARROWS"
    ob.empty_display_size = 1.0
    ob.matrix_world = Matrix.Translation(g2b(pos)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    coll(group).objects.link(ob)
    return ob


SLOPES = {}

# =========================================================================================
# 1. SHELL: ground slab, outer walls, roofs
# =========================================================================================
slab("Ground", FX0, FX1, FZ0, FZ1, L0, 1.0, "ground", "Shell")
wall("Shell_N", "x", FZ0 - WALL_T / 2, FX0 - WALL_T, FX1 + WALL_T, L0, ROOF, group="Shell")
wall("Shell_S_Wings_W", "x", FZ1 + WALL_T / 2, FX0 - WALL_T, -AX, L0, ROOF, group="Shell")
wall("Shell_S_Wings_E", "x", FZ1 + WALL_T / 2, AX, FX1 + WALL_T, L0, ROOF, group="Shell")
wall("Shell_S_Atrium", "x", FZ1 + WALL_T / 2, -AX, AX, L0, ATRIUM_ROOF, group="Shell")
mirror_wall("Shell_Side", FX1 + WALL_T / 2, FZ0, FZ1, L0, ROOF, group="Shell")
# roofs: wings + north block at 13.5; the atrium gets a collision-only skylight at 17
slab("Roof_North", FX0, FX1, FZ0, AZN, ROOF + SLAB_T, SLAB_T, "trim", "Roof")
slab("Roof_Wing_W", FX0, -AX - WALL_T / 2, AZN, FZ1, ROOF + SLAB_T, SLAB_T, "trim", "Roof")
slab("Roof_Wing_E", AX + WALL_T / 2, FX1, AZN, FZ1, ROOF + SLAB_T, SLAB_T, "trim", "Roof")
slab("Skylight", -AX, AX, AZN, FZ1, ATRIUM_ROOF + SLAB_T, SLAB_T, None, "Roof", suffix="-colonly")
# the atrium is taller than the north block: close the gap above the north walkway
wall("Atrium_N_Upper", "x", AZN, -AX, AX, ROOF, ATRIUM_ROOF, group="Shell")

# =========================================================================================
# 2. MAIN ROOM: sunken palm plaza (L0), retaining wall, catwalk ring (L1)
# =========================================================================================
prism("Plaza_Floor", [arc_pt(PLAZA_R, a) for a in range(0, 360, 15)], L0 + 0.05, 0.3, "plaza", "MainRoom")
# Retaining wall from the NE terrace edge round the south to the NW terrace edge (the north
# arc is where the stone steps climb out). Doors at plaza level: S, SE, SW.
A_E = math.degrees(math.asin(TERR_S / PLAZA_R))   # -36.9: wall meets the terrace line z = -6
A_W = 180.0 - A_E                                 # 216.9
DOORS_DEG = [(80.0, 100.0), (17.0, 35.0), (145.0, 163.0)]
RING_ANG = arc_angles(A_E, A_W, 9.0, [d for pair in DOORS_DEG for d in pair])
WR = PLAZA_R + WALL_T / 2
for i in range(len(RING_ANG) - 1):
    a, b = RING_ANG[i], RING_ANG[i + 1]
    pa, pb = Vector(arc_pt(WR, a)), Vector(arc_pt(WR, b))
    mid, d = (pa + pb) / 2, pb - pa
    yaw = math.degrees(math.atan2(-d.x, -d.y))
    is_door = any(d0 <= (a + b) / 2 <= d1 for d0, d1 in DOORS_DEG)
    y0 = L0 + DOOR if is_door else L0
    h = (L1 - SLAB_T) - y0
    box(f"Plaza_RetainingWall_{i}", (mid.x, y0 + h / 2, mid.y), (WALL_T, h, d.length + 0.15),
        "trim" if is_door else "wall", "MainRoom", yaw=yaw)
# short L0 walls closing the ring from the arc ends to the lower side halls
for sgn, tag in ((-1, "W"), (1, "E")):
    x_end = sgn * PLAZA_R * math.cos(math.radians(A_E))
    wall(f"Plaza_EndWall_{tag}", "x", TERR_S, min(x_end, sgn * (TX + WALL_T / 2)), max(x_end, sgn * (TX + WALL_T / 2)),
         L0, L1 - SLAB_T, group="MainRoom")

# Catwalk ring (L1): rectangle x +-16, z -6..18 minus the plaza disc, built as radial pieces.


def _ray_rect(deg, x0=-AX, x1=AX, z0=TERR_S, z1=FZ1):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    ts = []
    if c > 1e-9:
        ts.append(x1 / c)
    if c < -1e-9:
        ts.append(x0 / c)
    if s > 1e-9:
        ts.append(z1 / s)
    if s < -1e-9:
        ts.append(z0 / s)
    t = min(ts)
    return (t * c, t * s)


CORNERS = [math.degrees(math.atan2(z, x)) % 360 for x, z in ((AX, TERR_S), (AX, FZ1), (-AX, FZ1), (-AX, TERR_S))]
CORNERS = [c - 360 if c > 270 else c for c in CORNERS]
CW_ANG = arc_angles(A_E, A_W, 12.0, CORNERS)
for i in range(len(CW_ANG) - 1):
    a, b = CW_ANG[i], CW_ANG[i + 1]
    prism(f"Catwalk_Ring_{i}", [arc_pt(PLAZA_R, a), arc_pt(PLAZA_R, b), _ray_rect(b), _ray_rect(a)], L1, SLAB_T,
          "wood", "Catwalk")
    parapet(f"Catwalk_Rail_{i}", *arc_pt(PLAZA_R + 0.15, a), *arc_pt(PLAZA_R + 0.15, b), L1)
# side catwalks over the lower side halls, up to the top of the stone steps
for sgn, tag in ((-1, "W"), (1, "E")):
    xa, xb = sorted((sgn * (TX - WALL_T / 2), sgn * AX))
    slab(f"Catwalk_Side_{tag}", xa, xb, TERR_N, TERR_S, L1, SLAB_T, "wood", "Catwalk")
    parapet(f"Catwalk_SideRail_{tag}", sgn * (TX - WALL_T / 2 + 0.15), -22.0, sgn * (TX - WALL_T / 2 + 0.15), TERR_S, L1)
# steel pillars at the catwalk's outer edge (screenshot: big riveted columns), ceiling-high
for x, z in ((-14.5, -24.0), (14.5, -24.0), (-14.5, -12.0), (14.5, -12.0), (-14.5, 2.0), (14.5, 2.0),
             (-8.0, 16.5), (8.0, 16.5)):
    box("Catwalk_Pillar", (x, (L1 + ATRIUM_ROOF) / 2, z), (1.2, ATRIUM_ROOF - L1, 1.2), "trim", "Catwalk")
# Lower ring (under the catwalk): a few support columns
for deg in (5.0, 60.0, 120.0, 175.0):
    x, z = arc_pt(13.5, deg)
    box("LowerRing_Column", (x, (L1 - SLAB_T) / 2, z), (0.8, L1 - SLAB_T, 0.8), "trim", "LowerRing")

# Plaza centre: flagstone ring + palms (trunks are cover; the canopy is above jump height)
for k in range(8):
    a0, a1 = k * 45.0 + 6.0, k * 45.0 + 39.0
    p0, p1 = Vector(arc_pt(2.6, a0)), Vector(arc_pt(2.6, a1))
    d = p1 - p0
    box("Plaza_StoneRing", ((p0.x + p1.x) / 2, 0.3, (p0.y + p1.y) / 2), (0.8, 0.6, d.length), "rock", "MainRoom",
        yaw=math.degrees(math.atan2(-d.x, -d.y)))
for k, deg in enumerate((200.0, 250.0, 300.0, 20.0, 110.0)):
    x, z = arc_pt(5.5, deg)
    box(f"Palm_{k}", (x, 6.0, z), (0.8, 12.0, 0.8), "palm", "MainRoom")
box("Plaza_Bench", (-4.0, 0.45, 7.0), (2.4, 0.9, 0.7), "cover", "MainRoom", yaw=20.0)

# =========================================================================================
# 3. STONE STEPS (grass terraces) + CANYON (central alley, rocket behind the grate)
# =========================================================================================
for sgn, tag in ((-1, "W"), (1, "E")):
    xa, xb = sorted((sgn * CANYON, sgn * (TX - WALL_T / 2)))
    SLOPES[f"Terrace_Low_{tag}"] = wedge(f"Terrace_Low_{tag}", xa, xb, TERR_S, -14.0, 0.0, 2.25, "grass", "Terraces")
    wedge(f"Terrace_Mid_{tag}", xa, xb, -14.0, -16.0, 2.25, 2.25, "grass", "Terraces")
    SLOPES[f"Terrace_High_{tag}"] = wedge(f"Terrace_High_{tag}", xa, xb, -16.0, -22.0, 2.25, L1, "grass", "Terraces")
    wedge(f"Terrace_Top_{tag}", xa, xb, -22.0, TERR_N, L1, L1, "floor", "Terraces")
# bridge over the canyon at the top of the steps (ceiling of the rocket alcove)
slab("Canyon_Bridge", -CANYON, CANYON, TERR_N, -22.0, L1, 0.5, "floor", "Terraces")
box("Canyon_Water", (0.0, 0.03, (TERR_S + TERR_N) / 2), (2 * CANYON - 0.1, 0.06, TERR_S - TERR_N), "water", "Terraces",
    suffix="")
# drainage grate between the canyon and the Lower North Hall: bars, 0.5 m gaps (see-through,
# not walk-through; you come round by the side halls). Rocket alcove sits behind it.
for k in range(5):
    x = -CANYON + 0.25 + k * 0.625
    box("Canyon_Grate", (x, (L1 - 0.5) / 2, TERR_N - 0.1), (0.12, L1 - 0.5, 0.2), "trim", "Terraces")
# boulders on the terraces (screenshot: two big rocks either side of the stream)
box("Terrace_Boulder_W", (-6.5, 1.4 + 0.6, -11.0), (3.4, 2.4, 3.0), "rock", "Terraces", yaw=15.0)
box("Terrace_Boulder_E", (6.5, 3.3 + 0.6, -19.0), (3.4, 2.4, 3.0), "rock", "Terraces", yaw=-20.0)
box("Terrace_Bench", (-8.0, 2.25 + 0.45, -15.0), (2.4, 0.9, 0.7), "cover", "Terraces")
# inner walls of the lower side halls (terrace edge below the side catwalks)
mirror_wall("SideHall_Inner", TX, TERR_N, TERR_S, L0, L1 - SLAB_T, group="LowerHalls")

# =========================================================================================
# 4. ATRIUM SIDE WALLS (x = +-16) per floor band
# =========================================================================================
# L0: lower side hall / lower ring -> corner stair rooms
mirror_wall("Atrium_Side_L0", AX, AZN, FZ1, L0, L1 - SLAB_T, [(9.0, 13.0, L0, L0 + DOOR)])
# L1: catwalk -> Dark Room (W) / Light Room (E) and -> corner stair landings
mirror_wall("Atrium_Side_L1", AX, AZN, FZ1, L1, L2 - SLAB_T, [(-13.0, -9.0, L1, L1 + DOOR), (3.0, 6.5, L1, L1 + DOOR)])
# L2: gallery windows over the main room (sill 1.1 m)
mirror_wall("Atrium_Side_L2", AX, AZN, FZ1, L2, ATRIUM_ROOF, [(-27.0, -7.0, L2 + 1.1, ROOF - 0.4)])

# =========================================================================================
# 5. NORTH BLOCK: Lower North Hall (L0, elevator bottom, magnum cul-de-sacs), L1 hall, L2 walkway
# =========================================================================================
SHAFT = (LIFT[0] - 1.5, LIFT[0] + 1.5, LIFT[1] - 1.5, LIFT[1] + 1.5)
RAMP_HOLE_W = (-25.5, -22.5, FZ0, AZN)
RAMP_HOLE_E = (22.5, 25.5, FZ0, AZN)
floor_holes("L1_NorthHall", FX0, FX1, FZ0, TERR_N, L1, [SHAFT])
floor_holes("L2_NorthWalk", FX0, FX1, FZ0, AZN, L2, [SHAFT, RAMP_HOLE_W, RAMP_HOLE_E])
# Lower North Hall walls (x = +-16) with doors into the magnum cul-de-sacs
mirror_wall("LowerNorth_Side", AX, FZ0, TERR_N, L0, L1 - SLAB_T, [(-37.0, -33.0, L0, L0 + DOOR)], group="NorthBlock")
for sgn, tag in ((-1, "W"), (1, "E")):
    xa, xb = sorted((sgn * AX, sgn * 23.0))
    wall(f"Magnum_{tag}_S", "x", -30.0, xa, xb, L0, L1 - SLAB_T, group="NorthBlock")
    wall(f"Magnum_{tag}_Back", "z", sgn * 23.0, FZ0, -30.0, L0, L1 - SLAB_T, group="NorthBlock")
    box(f"Magnum_{tag}_Crate", (sgn * 21.5, 0.602, -38.5), (1.6, 1.2, 1.6), "cover", "NorthBlock")
    # L1 -> L2 stairs in the north corners (H2 plan: stair icons top-left / top-right)
    SLOPES[f"North_Stairs_{tag}"] = ramp(f"North_Stairs_{tag}", (sgn * 24.0, L1, FZ0 + 0.6), (sgn * 24.0, L2, AZN - 0.3), 3.0)
    parapet(f"North_StairRail_{tag}", sgn * 22.35, FZ0 + 2.0, sgn * 22.35, AZN, L2)
# L2 north walkway balcony over the main room ("commanding view of the entire space")
parapet("NorthWalk_Balcony", -AX + WALL_T / 2, AZN + 0.15, AX - WALL_T / 2, AZN + 0.15, L2)
for x in (-6.0, 6.0):
    box("LowerNorth_Pillar", (x, (L1 - SLAB_T) / 2, -35.0), (1.0, L1 - SLAB_T, 1.0), "trim", "NorthBlock")
box("LowerNorth_Crates", (9.5, 0.75, -38.5), (3.0, 1.5, 2.0), "cover", "NorthBlock")
box("Lift_Pad", (LIFT[0], 0.05, LIFT[1]), (3.0, 0.1, 3.0), "lift", "NorthBlock")
box("L1_North_Cover", (-8.0, L1 + 0.6, -36.0), (4.0, 1.2, 1.0), "cover", "NorthBlock")
box("L1_North_Cover", (8.0, L1 + 0.6, -36.0), (4.0, 1.2, 1.0), "cover", "NorthBlock")

# =========================================================================================
# 6. WINGS: Dark Room (W, L1), Light Room + overshield ramp room (E, L1), galleries (L2),
#    corner stair rooms (L0 -> L1)
# =========================================================================================
VENTS = [(-27.5, -20.0), (-27.5, -8.0)]
VENT_HOLES = [(x - 1.25, x + 1.25, z - 1.25, z + 1.25) for x, z in VENTS]
RAMPROOM_HOLE = (26.5, 29.5, -12.5, -6.0)
GALLERY_S = -6.0
floor_holes("L1_DarkRoom", FX0, -AX, TERR_N, 2.0, L1, [], mat="dark", group="DarkRoom")
floor_holes("L1_LightRoom", AX, FX1, TERR_N, 2.0, L1, [], group="LightRoom")
floor_holes("L2_Gallery_W", FX0, -AX, AZN, GALLERY_S, L2, VENT_HOLES, group="DarkRoom")
floor_holes("L2_Gallery_E", AX, FX1, AZN, GALLERY_S, L2, [RAMPROOM_HOLE], group="LightRoom")
for sgn, tag in ((-1, "W"), (1, "E")):
    xa, xb = sorted((sgn * AX, sgn * FX1))
    g = "DarkRoom" if sgn < 0 else "LightRoom"
    # wing <-> L1 north hall
    wall(f"Wing_{tag}_N_L1", "x", TERR_N, xa, xb, L1, L2, [(min(sgn * 19.0, sgn * 23.0), max(sgn * 19.0, sgn * 23.0), L1, L1 + DOOR)], group=g)
    # gallery south edge rail (look down into the room below)
    parapet(f"Gallery_{tag}_Rail", xa, GALLERY_S - 0.15, xb, GALLERY_S - 0.15, L2, group=g)
    # Corner stair room: L0 door from the lower ring, ramp up the outer side to an L1 landing
    ca, cb = sorted((sgn * (AX + WALL_T / 2), sgn * (24.0 - WALL_T / 2)))
    wall(f"Corner_{tag}_Outer", "z", sgn * 24.0, 2.0, FZ1, L0, ROOF, group="CornerRooms")
    wall(f"Corner_{tag}_N_L0", "x", 2.0, ca, cb, L0, L1 - SLAB_T, group="CornerRooms")
    wall(f"Corner_{tag}_N_L1", "x", 2.0, ca, cb, L1, ROOF, [(min(sgn * 17.5, sgn * 21.0), max(sgn * 17.5, sgn * 21.0), L1, L1 + DOOR)], group="CornerRooms")
    slab(f"Corner_{tag}_Landing", ca, cb, 2.0, 7.5, L1, SLAB_T, "floor", "CornerRooms")
    SLOPES[f"Corner_Stairs_{tag}"] = ramp(f"Corner_Stairs_{tag}", (sgn * 22.25, L0, 17.5), (sgn * 22.25, L1, 7.5), 3.0, group="CornerRooms")
    # wing south strip beyond the corner rooms (x 24..30) is sealed off, full height
    wall(f"Wing_{tag}_S_Closure", "x", 2.0, min(sgn * 24.0, sgn * FX1), max(sgn * 24.0, sgn * FX1), L0, ROOF, group=g)

# Dark Room: back section (flag) behind a partition, two air-vent lifters to the W gallery,
# low cover. Light Room: overshield, partition wall forming the ramp room up to the E gallery.
wall("DarkRoom_Partition", "z", -25.0, -24.0, -4.0, L1, L2 - SLAB_T, group="DarkRoom")
box("DarkRoom_Cover_A", (-20.0, L1 + 0.6, -12.0), (1.0, 1.2, 4.0), "cover", "DarkRoom")
box("DarkRoom_Cover_B", (-19.0, L1 + 0.6, -24.0), (4.0, 1.2, 1.0), "cover", "DarkRoom")
for x, z in VENTS:
    box("DarkRoom_VentPad", (x, L1 + 0.05, z), (2.4, 0.1, 2.4), "lift", "DarkRoom")
# partition stops short of the south wall: you walk round its end onto the ramp foot
wall("LightRoom_Partition", "z", 25.5, -12.5, -1.5, L1, L2 - SLAB_T, group="LightRoom")
SLOPES["RampRoom_Ramp"] = ramp("RampRoom_Ramp", (28.0, L1, 1.0), (28.0, L2, -12.5), 3.0, group="LightRoom")
box("LightRoom_Cover", (20.0, L1 + 0.6, -20.0), (4.0, 1.2, 1.0), "cover", "LightRoom")
# planter boxes on the upper level: H2's (destructible) sniper posts
for z in (-25.0, -17.0):
    box("Gallery_E_Planter", (19.0, L2 + 0.6, z), (1.6, 1.2, 1.6), "grass", "LightRoom")
    box("Gallery_W_Planter", (-19.0, L2 + 0.6, z), (1.6, 1.2, 1.6), "grass", "DarkRoom")

# Lower ring cover
for name, c, s, yaw in (("LowerRing_Crates_SW", (-12.5, 0.75, 14.5), (2.0, 1.5, 2.0), 10),
                        ("LowerRing_Crates_SE", (12.5, 0.75, 14.5), (2.0, 1.5, 2.0), -10),
                        ("SideHall_Crate_W", (-13.5, 0.6, -18.0), (1.5, 1.2, 1.5), 0),
                        ("SideHall_Crate_E", (13.5, 0.6, -10.0), (1.5, 1.2, 1.5), 0)):
    box(name, c, s, "cover", "LowerRing", yaw=yaw)

# =========================================================================================
# 7. MARKERS  (y = floor top)
# =========================================================================================
# Team spawns: Red = north (elevator / offensive end), Blue = south + west (Dark Room flag) [E].
# yaw: 0 faces north (-Z), 180 faces south.
RED = [((-8.0, L0, -37.5), 180), ((8.0, L0, -37.5), 180), ((-19.0, L1, -36.0), 180),
       ((19.0, L1, -36.0), 180), ((-10.0, L2, -37.0), 180), ((10.0, L2, -37.0), 180)]
BLUE = [((-18.5, L0, 16.0), 0), ((18.5, L0, 16.0), 0), ((-8.0, L1, 15.5), 0),
        ((8.0, L1, 15.5), 0), ((-12.0, L0, 11.5), 0), ((12.0, L0, 11.5), 0)]
for i, (p, yaw) in enumerate(RED):
    marker(f"SPAWN_Red_{i}", p, yaw=yaw)
for i, (p, yaw) in enumerate(BLUE):
    marker(f"SPAWN_Blue_{i}", p, yaw=yaw)
FFA = [(-6.0, L0, 4.0), (6.0, L0, 4.0), (-6.0, 2.25, -15.0), (5.0, 2.25, -15.0), (-6.0, L1, -25.0),
       (0.0, L0, -38.5), (-19.5, L0, -36.0), (-20.0, L1, -20.0), (21.0, L1, -24.0), (-22.0, L2, -14.0),
       (22.0, L2, -21.0), (-13.5, L1, -16.0), (13.5, L1, -2.0), (13.5, L0, -20.0)]
for i, p in enumerate(FFA):
    marker(f"SPAWN_FFA_{i:02d}", p)

# Long Colt five-gun mapping of the H2 layout [S positions / E mapping] (spec section 6)
WEAPONS = [
    ("WPN_MarksmanCarbine_NorthWalk", (5.0, L2, -37.0)),           # H2 sniper: 3rd floor by the elevator
    ("WPN_DirectedEnergyRifle_Canyon", (0.0, L0, -25.5)),          # H2 rockets: alley behind the grate
    ("WPN_CombatShotgun_DarkRoom", (-21.0, L1, -18.0)),            # H2 shotgun: dark room, upper level
    ("WPN_Longsword_LowerNorth", (-4.0, L0, -30.5)),             # H2 energy sword: under the grate
    ("WPN_ServicePistol_MagnumW", (-19.5, L0, -36.0)),             # H2 magnums: lower cul-de-sacs
    ("WPN_GravityHammer_MagnumE", (19.5, L0, -36.0)),             # Long Colt: hammer in the east cul-de-sac
    ("WPN_StandardIssueRifle_Plaza", (0.0, L0, 6.0)),
    ("WPN_StandardIssueRifle_CatwalkS", (0.0, L1, 14.0)),
    ("WPN_StandardIssueRifle_GalleryE", (22.0, L2, -26.0)),
]
for n, p in WEAPONS:
    marker(n, p)
marker("PWR_Overshield_LightRoom", (21.0, L1, -12.0))     # H2 power-ups, no Long Colt equivalent yet
marker("PWR_Overshield_RampTop", (28.0, L2, -16.0))
marker("FLAG_Blue_BackSection", (-28.0, L1, -14.0))      # One Flag: defenders' flag
marker("FLAG_Alt_TJunction", (6.0, L0, -30.5))           # alternate flag spot by the sword
marker("LIFT_Elevator", (LIFT[0], L0, LIFT[1]))          # Area3D 0 -> 7 m, ~10.3 m apex
for i, (x, z) in enumerate(VENTS):
    marker(f"LIFT_Vent_{i}", (x, L1, z))                 # Area3D 4.5 -> 7.5 m, ~10.8 m apex
CALLOUTS = {
    "Plaza": (0.0, L0, 0.0), "StoneSteps": (-6.0, 2.25, -15.0), "Canyon": (0.0, L0, -15.0),
    "Elevator": (LIFT[0], L0, LIFT[1]), "LowerNorthHall": (0.0, L0, -37.0), "MagnumWest": (-19.5, L0, -36.0),
    "MagnumEast": (19.5, L0, -36.0), "LowerRing": (0.0, L0, 14.0), "Catwalk": (0.0, L1, 14.0),
    "DarkRoom": (-21.0, L1, -14.0), "BackSection": (-28.0, L1, -14.0), "LightRoom": (21.0, L1, -14.0),
    "RampRoom": (28.0, L1, -4.0), "NorthWalk": (0.0, L2, -35.0), "GalleryWest": (-23.0, L2, -18.0),
    "GalleryEast": (23.0, L2, -18.0), "CornerWest": (-20.0, L0, 12.0), "CornerEast": (20.0, L0, 12.0),
}
for n, p in CALLOUTS.items():
    marker("CALLOUT_" + n, p, group="Callouts")

# =========================================================================================
# report slopes, save, export
# =========================================================================================
print("\n== Ivory Tower greybox: slopes (deg; floor_max_angle 50, nav max 45) ==")
for n, s in SLOPES.items():
    flag = "  !! too steep" if s > 45 else ""
    print(f"  {n:24s} {s:5.1f}{flag}")
def _clean_and_join_by_material():
    mesh_obs = [ob for ob in bpy.data.objects if ob.type == "MESH"]
    by_key = {}
    for ob in mesh_obs:
        mat = ob.data.materials[0].name if ob.data.materials else "none"
        col_type = "-colonly" if "-colonly" in ob.name else ("-col" if ob.name.endswith("-col") else "")
        by_key.setdefault((mat, col_type), []).append(ob)

    for (mat_name, col_type), obs in by_key.items():
        bpy.ops.object.select_all(action="DESELECT")
        for ob in obs:
            ob.select_set(True)
        bpy.context.view_layer.objects.active = obs[0]
        if len(obs) > 1:
            bpy.ops.object.join()
        joined = bpy.context.view_layer.objects.active
        tag = mat_name[4:].capitalize() if mat_name.startswith("mat_") else mat_name.capitalize()
        joined.name = f"IvoryTower_{tag}{col_type}"

        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.remove_doubles(threshold=0.002)
        bpy.ops.mesh.dissolve_degenerate()
        bpy.ops.object.mode_set(mode="OBJECT")

_clean_and_join_by_material()

n_col = sum(1 for o in bpy.data.objects if "-col" in o.name)
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
LEVEL_TSCN = _arg("--level-tscn", "scenes/levels/ivory_tower.tscn")
MAIN_TSCN = _arg("--main-tscn", "scenes/main/main_ivory_tower.tscn")
ARENA_TSCN = _arg("--arena-tscn", "scenes/main/arena_ivory_tower.tscn")
GEN = "; GENERATED by tools/ivory_tower/build_ivory_tower.py - edit the script, not this file."


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


# Lifts: (node, centre on the floor, volume height, box xz size). Riders leave the volume top at
# 12 m/s and coast ~3.3 m higher (gravity 22): elevator 7 -> 10.3 (L2 at 9), vents 3 -> 10.8.
LIFTS = [("GravLift_Elevator", (LIFT[0], L0, LIFT[1]), 7.0, 3.0)] + \
        [(f"GravLift_Vent_{i}", (x, L1, z), 3.0, 2.4) for i, (x, z) in enumerate(VENTS)]
# Interior fill lights (the sun only reaches the main room through the skylight).
# (name, position, energy, range)
LIGHTS = [
    ("LowerNorthHall", (0.0, 3.6, -34.0), 1.2, 14.0), ("MagnumW", (-19.5, 3.6, -35.0), 0.8, 8.0),
    ("MagnumE", (19.5, 3.6, -35.0), 0.8, 8.0), ("LowerRingS", (0.0, 3.6, 14.0), 1.0, 12.0),
    ("LowerRingSW", (-12.5, 3.6, 6.0), 0.8, 10.0), ("LowerRingSE", (12.5, 3.6, 6.0), 0.8, 10.0),
    ("SideHallW", (-13.5, 3.6, -18.0), 0.8, 10.0), ("SideHallE", (13.5, 3.6, -18.0), 0.8, 10.0),
    ("CanyonAlcove", (0.0, 3.4, -25.0), 0.6, 6.0), ("CornerW", (-20.0, 8.5, 10.0), 1.0, 12.0),
    ("CornerE", (20.0, 8.5, 10.0), 1.0, 12.0), ("DarkRoom", (-21.0, 8.0, -14.0), 0.25, 10.0),
    ("LightRoom", (21.0, 8.0, -14.0), 1.6, 14.0), ("RampRoom", (28.0, 12.5, -4.0), 1.0, 10.0),
    ("L1NorthW", (-14.0, 8.0, -34.0), 1.0, 14.0), ("L1NorthE", (14.0, 8.0, -34.0), 1.0, 14.0),
    ("NorthWalk", (0.0, 12.8, -35.0), 1.2, 16.0), ("GalleryW", (-23.0, 12.8, -18.0), 0.9, 12.0),
    ("GalleryE", (23.0, 12.8, -18.0), 1.2, 12.0),
]

lines = [
    f"[gd_scene load_steps={6 + len(LIFTS)} format=3]",
    "",
    '[ext_resource type="PackedScene" path="res://assets/models/environment/ivory_tower_greybox.glb" id="1_glb"]',
    '[ext_resource type="Script" path="res://scripts/levels/grav_lift.gd" id="2_lift"]',
    '[ext_resource type="Script" path="res://scripts/levels/kill_volume.gd" id="3_kill"]',
    '[ext_resource type="Script" path="res://scripts/levels/level_materials.gd" id="4_mat"]',
    "",
]
for name, _, h, w in LIFTS:
    lines += [f'[sub_resource type="BoxShape3D" id="Shape_{name}"]', f"size = Vector3({w:g}, {h:g}, {w:g})", ""]
lines += [
    '[sub_resource type="BoxShape3D" id="Shape_Kill"]',
    "size = Vector3(200, 2, 200)",
    "",
    GEN,
    '[node name="IvoryTower" type="Node3D"]',
    "",
    '[node name="LevelMaterials" type="Node" parent="."]',
    'script = ExtResource("4_mat")',
    "",
    '[node name="Greybox" parent="." instance=ExtResource("1_glb")]',
    "",
]
for name, (x, y, z), h, _ in LIFTS:
    lines += [f'[node name="{name}" type="Area3D" parent="."]', "transform = " + _xf((x, y + h / 2, z)),
              "collision_layer = 16", "collision_mask = 2", "monitorable = false", 'script = ExtResource("2_lift")', "",
              f'[node name="Shape" type="CollisionShape3D" parent="{name}"]', f'shape = SubResource("Shape_{name}")', ""]
lines += [
    "; safety net under the ground slab",
    '[node name="KillVolume" type="Area3D" parent="."]',
    "transform = " + _xf((0.0, -8.0, -11.0)),
    "collision_layer = 16",
    "collision_mask = 6",
    "monitorable = false",
    'script = ExtResource("3_kill")',
    "",
    '[node name="Shape" type="CollisionShape3D" parent="KillVolume"]',
    'shape = SubResource("Shape_Kill")',
    "",
    '[node name="Lights" type="Node3D" parent="."]',
    "",
]
for name, p, energy, rng in LIGHTS:
    lines += [f'[node name="{name}" type="OmniLight3D" parent="Lights"]', "transform = " + _xf(p),
              "light_color = Color(1, 0.94, 0.84, 1)", f"light_energy = {energy:g}", f"omni_range = {rng:g}", ""]
lines += ['[node name="Spawns" type="Node3D" parent="."]', ""]
for name, p, yaw in _spawn_list():
    lines += [f'[node name="{name}" type="Marker3D" parent="Spawns"]', "transform = " + _xf(p, yaw), ""]
os.makedirs(os.path.dirname(os.path.abspath(LEVEL_TSCN)), exist_ok=True)
open(LEVEL_TSCN, "w").write("\n".join(lines))

# Grenade pickups (GrenadePickup: 2 each, 30 s respawn) in the main and arena scenes only, no .glb
# marker. Metres. Each sits by a roam point on flat floor with a standing capsule's room, clear of
# weapon pads, spawns and flag bases (tests/grenade_spawns_self_test.gd checks all of that).
# Frags in the lower corners and the L1 north hall, stickies in the plaza (its paving is 5 cm up)
# and the two L1 side rooms.
GRENADES = [
    ("Frags_CornerWest", "frag", (-18.5, L0, 12.0)), ("Frags_CornerEast", "frag", (18.5, L0, 12.0)),
    ("Frags_L1NorthHall", "frag", (-12.0, L1, -33.0)), ("Stickies_Plaza", "sticky", (4.0, L0 + 0.05, 4.0)),
    ("Stickies_BackSection", "sticky", (-28.0, L1, -11.5)), ("Stickies_LightRoom", "sticky", (21.0, L1, -14.0)),
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
       # steep sun so it reaches the plaza floor through the skylight
       "transform = Transform3D(0.866025, 0.383022, -0.321394, 0, 0.642788, 0.766044, 0.5, -0.663414, 0.556670, 0, 40, 0)",
       "light_color = Color(1, 0.93, 0.8, 1)", "light_energy = 1.2", "shadow_enabled = true",
       "directional_shadow_max_distance = 120.0", ""]
first = [sp for sp in _spawn_list() if sp[0].startswith("SPAWN_Blue")][0]


def _pickups():
    out = []
    for n, p in WEAPONS:
        f, rid, respawn = GUN[n.split("_")[1]]
        out += [f'[node name="{n[4:]}" parent="." instance=ExtResource("8_pickup")]', "transform = " + _xf(p),
                f'weapon_scene = ExtResource("{rid}")'] + ([f"respawn_delay = {respawn}"] if respawn else []) + [""]
    return out


ml = ["[gd_scene load_steps=10 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/ivory_tower.tscn" id="1_level"]']
for f, rid, _ in GUN.values():
    ml.append(f'[ext_resource type="PackedScene" path="res://scenes/weapons/{f}.tscn" id="{rid}"]')
ml += GRENADE_EXT
ml += ['[ext_resource type="PackedScene" path="res://scenes/player/player.tscn" id="7_player"]',
       '[ext_resource type="PackedScene" path="res://scenes/pickups/weapon_pickup.tscn" id="8_pickup"]',
       '[ext_resource type="Environment" path="res://resources/environments/outdoor_environment.tres" id="9_env"]',
       "", GEN + " Offline balance testbed (no bots).",
       '[node name="MainIvoryTower" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', ""]
ml += SUN
ml += ['[node name="IvoryTower" parent="." instance=ExtResource("1_level")]', "",
       '[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
ml += _pickups()
_grenade_nodes(ml)
open(MAIN_TSCN, "w").write("\n".join(ml))

# Arena (Bot Arena + LAN): same pickups, bots, runtime navmesh, lift links, roam points,
# NetMatch before SpawnManager (its _ready configures SpawnManager), like arena_headlong.tscn.
ROAM = [
    ("Plaza", (4.0, L0, 4.0), 1.5), ("StoneSteps", (-6.0, 2.25, -15.0), 1.0), ("Canyon", (0.0, L0, -18.0), 0.5),
    ("CanyonAlcove", (0.0, L0, -25.5), 0.5), ("TopOfSteps", (6.0, L1, -25.0), 1.0),
    ("LowerNorthHall", (-3.0, L0, -37.5), 1.0), ("MagnumWest", (-19.5, L0, -37.0), 0.5),
    ("MagnumEast", (19.5, L0, -37.0), 0.5), ("SideHallWest", (-13.5, L0, -14.0), 0.7),
    ("SideHallEast", (13.5, L0, -22.0), 0.7), ("LowerRing", (0.0, L0, 14.5), 1.0),
    ("CornerWest", (-18.5, L0, 12.0), 0.5), ("CornerEast", (18.5, L0, 12.0), 0.5),
    ("CatwalkSouth", (-5.0, L1, 14.5), 1.0), ("CatwalkWest", (-13.5, L1, -20.0), 0.7),
    ("CatwalkEast", (13.5, L1, -16.0), 0.7), ("L1NorthHall", (-12.0, L1, -33.0), 1.0),
    ("DarkRoom", (-20.0, L1, -16.0), 1.0), ("BackSection", (-28.0, L1, -14.0), 0.7),
    ("LightRoom", (21.0, L1, -14.0), 1.0), ("RampRoom", (28.0, L1, 0.5), 0.5),
    ("NorthWalk", (-6.0, L2, -36.0), 1.0), ("GalleryWest", (-22.0, L2, -24.0), 0.7),
    ("GalleryEast", (22.0, L2, -14.0), 0.7),
]
# (name, start, end, release_y): hold over the pad, then step off at release_y
LINKS = [("Link_Elevator", (LIFT[0], L0, LIFT[1]), (LIFT[0], L2, LIFT[1] - 3.5), L2 + 0.5)] + \
        [(f"Link_Vent_{i}", (x, L1, z), (x + 3.0, L2, z), L2 + 0.5) for i, (x, z) in enumerate(VENTS)]
al = ["[gd_scene load_steps=18 format=3]", "",
      '[ext_resource type="PackedScene" path="res://scenes/levels/ivory_tower.tscn" id="1_level"]',
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
al += ["", GEN + " Arena mode (Bot Arena / LAN).",
       '[node name="ArenaIvoryTower" type="Node3D"]', "",
       '[node name="WorldEnvironment" type="WorldEnvironment" parent="."]', 'environment = ExtResource("9_env")', ""]
al += SUN
al += ['[node name="ArenaEvents" type="Node" parent="."]', 'script = ExtResource("11_events")', "",
       '[node name="IvoryTower" parent="." instance=ExtResource("1_level")]', "",
       '[node name="Player" parent="." instance=ExtResource("7_player")]', "transform = " + _xf(first[1], first[2]), ""]
al += _pickups()
_grenade_nodes(al)
al += ['[node name="Navigation" type="NavigationRegion3D" parent="."]', 'script = ExtResource("12_nav")',
       'geometry_root = NodePath("../IvoryTower")', ""]
for name, s, e, rel in LINKS:
    al += [f'[node name="{name}" type="NavigationLink3D" parent="Navigation"]', "bidirectional = false",
           "navigation_layers = 1", f"start_position = Vector3({s[0]:g}, {s[1]:g}, {s[2]:g})",
           f"end_position = Vector3({e[0]:g}, {e[1]:g}, {e[2]:g})", 'metadata/traversal = "lift"',
           f"metadata/release_y = {rel:g}", ""]
al += ['[node name="NavPoints" type="Node3D" parent="."]', ""]
for n, p, w in ROAM:
    al += [f'[node name="{n}" type="Marker3D" parent="NavPoints" groups=["ai_roam_point"]]',
           "transform = " + _xf((p[0], p[1] + 0.05, p[2])), f"metadata/weight = {w:g}", f'metadata/callout = "{n}"', ""]
al += ['[node name="NetMatch" type="Node" parent="."]', 'script = ExtResource("13_net")', "",
       '[node name="SpawnManager" type="Node" parent="."]', 'script = ExtResource("14_spawns")',
       'bot_scene = ExtResource("10_bot")', "bot_count = 3", 'difficulty = ExtResource("15_diff")',
       'spawn_roots = Array[NodePath]([NodePath("../IvoryTower/Spawns")])', ""]
open(ARENA_TSCN, "w").write("\n".join(al))
print("  wrote", LEVEL_TSCN, MAIN_TSCN, "and", ARENA_TSCN)

# =========================================================================================
# previews: overhead per floor (everything above that floor hidden) + two perspectives
# =========================================================================================
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
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]

    def _min_y(o):  # Godot y of the object's lowest vertex
        return min((o.matrix_world @ v.co).z for v in o.data.vertices)

    def shoot(fname, loc, rot, ortho=None, res=(1600, 1600), cut=None):
        hidden = [o for o in meshes if o.name.startswith(("Roof_", "Shell_N", "Shell_S", "Atrium_N_Upper"))
                  or (cut is not None and _min_y(o) > cut)]
        for o in hidden:
            o.hide_render = True
        cam_data = bpy.data.cameras.new(fname)
        if ortho:
            cam_data.type = "ORTHO"
            cam_data.ortho_scale = ortho
        else:
            cam_data.lens = 20
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

    # overheads: north up (Blender +Y = Godot -Z); camera centred on the footprint (z -11)
    centre = (0.0, 11.0)
    for tag, cut in (("L0", L1 - SLAB_T - 0.05), ("L1", L2 - SLAB_T - 0.05), ("L2", ROOF - 0.05)):
        shoot(f"ivory_tower_overhead_{tag}", (centre[0], centre[1], 80), (0, 0, 0), ortho=66, cut=cut)
    # from the north walkway looking south over the stone steps (the classic screenshot angle)
    shoot("ivory_tower_persp_from_north", (0, 30.0, 12.0), (68, 0, 180), res=(1920, 1080))
    # cutaway from above the south-east, roofs off
    shoot("ivory_tower_persp_cutaway", (46, -42, 50), (52, 0, 43), res=(1920, 1080), cut=ROOF - 0.05)
    print("  previews in", PREVIEWS)
