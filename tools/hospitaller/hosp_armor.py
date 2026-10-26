"""Hospitaller armour modules: the slot / variant catalogue and every part's geometry.

Each builder returns Parts. A part is one rigid mesh parented to one PB_* joint and named
  AR_<slot>_<variant>_<piece>   (an armour module; PlayerModel shows one variant per slot)
  CORE_<piece>                  (always shown: gloves, boots, collar)
Slots and variants here must match scripts/player/armor_loadout.gd (ArmorLoadout.SLOTS).

Sources: Exo-W-helm / Exo-no-helm (exo frame, thigh plates with the stepped notch, forearm
bracers, ankle and shoulder discs), helmets.png (1, 2A, 2A band, 2B NVG, 3), soldier
concepts.png (plate carrier, heavy cuirass), player board synthesis (palette, chunky plates,
functional silhouette breaks). The user's prototype pieces (helmet shell, cuirass) are the
bases of the Hospitaller helmet and the Cuirass chest.

Godot space throughout; s = -1 is the character's left (-X), +1 the right.
"""
import math

from mathutils import Matrix, Vector

from hosp_geo import (Geo, box, cyl, disc, facet_box, facet_ring, facet_tube, lerp, obox, octagon,
                      poly_prism, radial_plate, solidify)

SIDES = ((-1, "L"), (1, "R"))


class Part:
    def __init__(self, name, joint, geo, pivot=None):
        self.name = name
        self.joint = joint
        self.geo = geo
        self.pivot = pivot  # own origin (e.g. a hinge); None = the joint's pivot


class Ctx:
    """Inputs shared by the builders: the fitted body surface and the user's proto pieces."""

    def __init__(self, body_surface, proto):
        self.body = body_surface
        self.proto = proto  # name -> Geo in Godot space (fitted)


# ---- small shared pieces ------------------------------------------------------------------
def dot_disc(center, normal, r, depth=0.006, mat="U"):
    return disc(center, normal, r, depth, 6, mat, bevel=0.0)


# ==== HELMETS (PB_Head) ======================================================================
HEAD = "PB_Head"


def _helmet_surface(g):
    from hosp_geo import Surface
    return Surface(g.v, g.f)


_FLIP_Z = Matrix.Scale(-1, 4, (0, 0, 1))  # mirror front/back: _front_z on it reads the back


def _front_z(surf, x, y):
    hit = surf.ray((x, y, -1.0), (0, 0, 1))
    return hit[0].z if hit[0] is not None else -0.19


AXIS = (0, -0.01)  # helmet's vertical axis (x, z) for radial projection


# Hinge axis of the octagonal ear pivots (the up-armour plate swings about it, along X).
HINGE = Vector((0.0, 1.62, 0.0))
PLATE_UP_DEG = 100.0  # plate flipped up over the crown (helmets.png 2A); 0 = down (2B)


def _shell(ctx, crown_armor=False):
    """The prototype shell. crown_armor: the visor strip that runs back over the crown and the
    visor's far sides (> 70 deg off the front) become armour, for variants whose faceplate
    covers the face and ends short of the ear pivots."""
    g = Geo()
    g.extend(ctx.proto["helmet"])
    g.sharp = 35.0
    if crown_armor:
        for i, f in enumerate(g.f):
            if g.m[i] != "V":
                continue
            c = sum((g.v[k] for k in f), Vector()) / len(f)
            side = math.degrees(math.atan2(abs(c.x), -(c.z - AXIS[1])))
            if (c.y > 1.735 and c.z > -0.07) or side > 70.0:
                g.m[i] = "A"
    return g


def _ears(octo=True, r=0.044, y=1.62):
    """The sketches' octagonal ear piece on the side strips: the visor's pivot. The left one
    carries the shoulder-accent tint (the helmet's squad colour)."""
    g = Geo()
    for s in (-1, 1):
        g.extend(poly_prism(octagon(r), (s * 0.138, y, 0.0), (s, 0, 0), (0, 1, 0), 0.018,
                            "X" if s < 0 else "A", 0.004))
        g.extend(disc((s * 0.158, y, 0.0), (s, 0, 0), r * 0.4, 0.008, 8, "M"))
    return g


def _plate(hs, rows, cols=10, off=0.008, th=0.012, mat="A", bevel=0.0):
    """A face plate laid over the shell / visor (rows: y, angle from, angle to). The rows are
    resampled every ~12 mm and the columns every ~5 deg so the plate's flat quads follow the
    shell's facets instead of cutting through their creases."""
    dense = []
    for (y0, a0, b0), (y1, a1, b1) in zip(rows, rows[1:]):
        n = max(1, int(abs(y1 - y0) / 0.016))
        for k in range(n):
            t = k / n
            dense.append((lerp(y0, y1, t), lerp(a0, a1, t), lerp(b0, b1, t)))
    dense.append(rows[-1])
    span = max(abs(b - a) for _y, a, b in rows)
    cols = max(cols, int(span / 7))
    return radial_plate(hs, AXIS, dense, cols, off, th, mat, bevel=bevel, smooth=0)


def _holes(surf, pts, r=0.0065):
    """Breath holes: dark ports where rays at (angle deg, y) meet surf."""
    g = Geo()
    for a, y in pts:
        ar = math.radians(a)
        d = Vector((math.sin(ar), 0.0, -math.cos(ar)))
        c = Vector((AXIS[0], y, AXIS[1]))
        hit = surf.ray(c + d * 1.0, -d)
        if hit[0] is not None:
            g.extend(dot_disc(hit[0] + hit[1] * 0.001, hit[1], r, 0.004))
    return g


def helmet_hospitaller(ctx):
    """The prototype as drawn: full-face visor, octagonal pivots."""
    shell = _shell(ctx)
    hs = _helmet_surface(shell)
    return [("shell", shell), ("ears", _ears())]


def helmet_warden(ctx):
    """helmets.png 1 (and the Templar great helm): a faceplate over the visor that leaves a
    T open, perforated cheeks."""
    shell = _shell(ctx, crown_armor=True)
    hs = _helmet_surface(shell)
    face = Geo()
    face.extend(_plate(hs, [(1.752, -76, 76), (1.735, -88, 88), (1.668, -88, 88)], 12))
    for s in (-1, 1):
        face.extend(_plate(hs, [(1.626, s * 9, s * 88), (1.58, s * 9, s * 88), (1.538, s * 8, s * 86)], 6))
    fs = _helmet_surface(face)
    holes = Geo()
    for s in (-1, 1):
        holes.extend(_holes(fs, [(s * a, y) for a, y in ((24, 1.60), (32, 1.60), (40, 1.60), (28, 1.58),
                                                         (36, 1.58), (32, 1.56))]))
    return [("shell", shell), ("face", face), ("breaths", holes), ("ears", _ears())]


def helmet_sentry(ctx):
    """helmets.png (right column, lower) and the great helm's sight: a faceplate over the visor
    with one horizontal slit on side rails, four breath ports low on the left."""
    shell = _shell(ctx, crown_armor=True)
    hs = _helmet_surface(shell)
    face = _plate(hs, [(1.752, -76, 76), (1.735, -88, 88), (1.664, -88, 88)], 12)
    face.extend(_plate(hs, [(1.636, -88, 88), (1.59, -88, 88), (1.538, -86, 86)], 12))
    fs = _helmet_surface(face)
    rails = Geo()
    for s in (-1, 1):
        rails.extend(obox((s * 0.142, 1.65, -0.01), (0, 0, 1), (0, 1, 0), (0.05, 0.03, 0.022), "M", 0.004))
    ports = Geo()
    for a, y in ((-34, 1.585), (-22, 1.585), (-34, 1.56), (-22, 1.56)):
        ar = math.radians(a)
        d = Vector((math.sin(ar), 0.0, -math.cos(ar)))
        hit = fs.ray(Vector((AXIS[0], y, AXIS[1])) + d, -d)
        if hit[0] is not None:
            ports.extend(cyl(hit[0] - d * 0.004, hit[0] + d * 0.009, 0.0105, 8, "M"))
            ports.extend(dot_disc(hit[0] + d * 0.0095, d, 0.007, 0.003))
    return [("shell", shell), ("face", face), ("rails", rails), ("ports", ports), ("ears", _ears())]


def nvg_plate(ctx, hs):
    """The 2A / 2B up-armour plate in its DOWN pose: titanium, laid over the visor, hinge lugs
    on the ear pivots, four NVG lenses (three across, one below)."""
    plate = _plate(hs, [(1.738, -66, 66), (1.70, -84, 84), (1.63, -88, 88), (1.585, -86, 86),
                        (1.555, -66, 66)], 12, 0.014, 0.014, "M")
    ps = _helmet_surface(plate)
    for s in (-1, 1):
        plate.extend(obox((s * 0.142, 1.632, -0.02), (0, 0, 1), (0, 1, 0), (0.05, 0.032, 0.02), "M", 0.003))
    for a, y, r in ((-20, 1.648, 0.019), (0, 1.652, 0.019), (20, 1.648, 0.019), (0, 1.605, 0.016)):
        ar = math.radians(a)
        d = Vector((math.sin(ar), 0.0, -math.cos(ar)))
        hit = ps.ray(Vector((AXIS[0], y, AXIS[1])) + d, -d)
        if hit[0] is None:
            continue
        n = hit[1]
        p0 = hit[0] - n * 0.004
        plate.extend(cyl(p0, p0 + n * 0.05, r, 8, "M"))
        plate.extend(cyl(p0 + n * 0.049, p0 + n * 0.056, r * 0.72, 8, "U"))
    return plate


def helmet_vanguard(ctx):
    """helmets.png 2A / 2B (one helmet): the full visor with a V chin guard and the titanium
    up-armour plate on the ear pivots. The plate is its own node pivoting on HINGE (its
    rotation about X: 0 = down over the visor with the NVG lenses in front, PLATE_UP_DEG =
    flipped up over the crown); PlayerModel.set_visor_plate_up() swings it."""
    shell = _shell(ctx)
    hs = _helmet_surface(shell)
    chin = Geo()
    for s in (-1, 1):
        chin.extend(_plate(hs, [(1.585, s * 52, s * 88), (1.56, s * 22, s * 88), (1.538, s * 0, s * 86)], 4))
    return [("shell", shell), ("chin", chin), ("ears", _ears()),
            ("visorplate", nvg_plate(ctx, hs), HEAD, HINGE)]


def helmet_lancer(ctx):
    """helmets.png row 3: a swept, beaked brow plate hooding the top of the visor and a V chin
    plate; the visor shows as a band between them."""
    shell = _shell(ctx, crown_armor=True)
    hs = _helmet_surface(shell)
    brow = Geo()
    for s in (-1, 1):
        brow.extend(_plate(hs, [(1.752, s * 0, s * 76), (1.735, s * 0, s * 88),
                                (1.676, s * 0, s * 88)], 6, 0.008, 0.016))
    beak = obox((0, 1.682, _front_z(hs, 0, 1.68) - 0.012), (1, 0, 0), (0, 0.3, -1), (0.05, 0.03, 0.03), "A", 0.006)
    chin = Geo()
    for s in (-1, 1):
        chin.extend(_plate(hs, [(1.612, s * 30, s * 88), (1.575, s * 6, s * 88), (1.538, s * 0, s * 86)], 4))
    return [("shell", shell), ("brow", brow), ("beak", beak), ("chin", chin),
            ("ears", _ears())]


# ==== CHEST (PB_Chest, PB_Abdomen, PB_Pelvis) ================================================
# The user's two prototype chest pieces are separate designs: the vest ("Cube", the base
# chest) and the breastplate ("Chestplate"). The other chest variants modify the vest, and every
# other piece here borrows their language: a few big flat facets, 45-degree chamfers, visible
# rims, flat shading.
CHEST, ABDO, PELVIS = "PB_Chest", "PB_Abdomen", "PB_Pelvis"


def _proto_piece(ctx, key, mat="A", front_only=False):
    """A prototype chest piece; front_only keeps the faces ahead of the torso's mid plane."""
    src = ctx.proto[key]
    g = Geo()
    if front_only:
        keep = [i for i, f in enumerate(src.f) if sum(src.v[k].z for k in f) / len(f) < -0.02]
        used = sorted({k for i in keep for k in src.f[i]})
        remap = {k: n for n, k in enumerate(used)}
        g.add([src.v[k] for k in used], [tuple(remap[k] for k in src.f[i]) for i in keep], mat)
        g = solidify(g, 0.012)
    else:
        g.extend(src, mat)
    g.sharp = 15.0
    return g


def _cuirass(ctx, shell_mat="A"):
    return _proto_piece(ctx, "chest_vest", shell_mat)


def _belt(mat="W", y=0.965, buckle=True, pouches=True):
    """Waist belt over the BDU: a wide chamfered band round the pelvis with big kidney and
    hip pouches and a canteen (PB_Pelvis)."""
    g = facet_ring((0, y, -0.005), 0.45, 0.36, 0.085, 0.06, 0.016, mat)
    if buckle:
        g.extend(facet_box((0, y, -0.188), (0.06, 0.05, 0.018), 0.006, "M"))
    if pouches:
        for x in (-1, 1):
            g.extend(_pouch((x * 0.215, y + 0.005, -0.07), (0.075, 0.1, 0.06), normal=(x, 0, -0.5)))
            g.extend(_pouch((x * 0.2, y - 0.02, 0.1), (0.07, 0.12, 0.07), normal=(x, 0, 0.6)))
        g.extend(cyl((-0.11, y - 0.04, 0.18), (-0.11, y + 0.05, 0.18), 0.04, 8, "W"))
    return g


def _midriff(mat="A", lames=2):
    """Segmented ab and kidney wrap filling the gap between the vest hem and the belt
    (PB_Abdomen): overlapping chamfered bands, each a little wider than the one above."""
    g = Geo()
    top, bottom = 1.15, 0.995
    step = (top - bottom) / lames
    for k in range(lames):
        y0 = top - k * step
        y1 = y0 - step - 0.012
        w = 0.36 + 0.012 * k
        d = 0.3 + 0.01 * k
        g.extend(facet_tube((0, y0, -0.022), (0, y1, -0.022), [(0, w, d, 0.075), (1, w + 0.006, d + 0.006, 0.075)],
                            (0, 0, -1), None, 0.014, mat))
    return g


def _ab_plates(n=2, top=1.11, step=0.055, w=0.2, z=-0.15):
    """Stepped abdominal plates under the cuirass (PB_Abdomen), each a chamfered slab."""
    g = Geo()
    for k in range(n):
        y = top - k * step
        g.extend(facet_box((0, y, z + k * 0.004), (w - k * 0.02, step * 0.95, 0.03), 0.012, "A"))
    return g


def _pouch(c, size, mat="W", flap="W", normal=(0, 0, -1)):
    """Chamfered pouch with a flap (webbing)."""
    n = Vector(normal).normalized()
    side = Vector((0, 1, 0)).cross(n).normalized()
    g = facet_box(c, (size[0], size[1], size[2]), min(size) * 0.25, mat, side, (0, 1, 0))
    top = Vector(c) + Vector((0, size[1] * 0.3, 0)) + n * (size[2] * 0.5 + 0.004)
    g.extend(facet_box(top, (size[0] * 1.04, size[1] * 0.42, 0.01), 0.003, flap, side, (0, 1, 0)))
    # Closure strap down the flap and a steel buckle.
    strap = Vector(c) + Vector((0, size[1] * 0.12, 0)) + n * (size[2] * 0.5 + 0.009)
    g.extend(obox(strap, side, (0, 1, 0), (min(0.018, size[0] * 0.3), size[1] * 0.55, 0.004), "U"))
    g.extend(obox(strap + Vector((0, -size[1] * 0.12, 0)) + n * 0.003, side, (0, 1, 0),
                  (min(0.024, size[0] * 0.4), 0.014, 0.004), "M"))
    return g


def chest_hospitaller(ctx):
    """The user's vest as modelled, a stepped ab guard and the belt."""
    return [("vest", _cuirass(ctx), CHEST), ("abs", _midriff(), ABDO), ("belt", _belt(), PELVIS)]


def chest_breastplate(ctx):
    """The user's breastplate as modelled (sternum ridge, neck rim, V-cut hem) and the belt."""
    return [("plate", _proto_piece(ctx, "chest_plate"), CHEST), ("abs", _midriff(), ABDO),
            ("belt", _belt(), PELVIS)]


def chest_exo(ctx):
    """Exo-W-helm torso: the vest cut down to its front half, on a harness, with the exo spine
    frame and a back power unit with its antenna."""
    frame = Geo()
    frame.extend(facet_box((0, 1.22, 0.11), (0.04, 0.26, 0.03), 0.01, "M"))
    for x in (-1, 1):
        frame.extend(facet_box((x * 0.105, 1.462, -0.01), (0.05, 0.016, 0.24), 0.005, "W"))
        frame.extend(facet_box((x * 0.105, 1.36, 0.13), (0.05, 0.2, 0.014), 0.005, "W", (1, 0, 0), (0, 1, 0.35)))
        frame.extend(facet_box((x * 0.168, 1.17, 0.0), (0.016, 0.15, 0.05), 0.005, "W"))
    pack = facet_box((0, 1.27, 0.17), (0.18, 0.21, 0.065), 0.02, "A")
    pack.extend(facet_box((0, 1.27, 0.206), (0.13, 0.15, 0.012), 0.004, "M"))
    for k in range(3):
        pack.extend(box((0, 1.225 + k * 0.03, 0.214), (0.1, 0.012, 0.006), "U"))
    pack.extend(cyl((0.07, 1.37, 0.19), (0.078, 1.64, 0.22), 0.005, 5, "M", r1=0.003))
    pack.extend(cyl((0.07, 1.35, 0.19), (0.07, 1.38, 0.19), 0.012, 6, "U"))
    return [("plate", _proto_piece(ctx, "chest_vest", front_only=True), CHEST), ("frame", frame, CHEST),
            ("pack", pack, CHEST),
            ("abs", _midriff(lames=1), ABDO), ("belt", _belt(), PELVIS)]


def chest_carrier(ctx):
    """The vest as a plate carrier (soldier concepts 2/6/7): webbing instead of plate, with
    mag pouches, a radio and its antenna."""
    vest = _cuirass(ctx, shell_mat="W")
    vs = _helmet_surface(vest)

    def seat(x, y, depth, half=0.035):
        """z of a pouch centre sitting on the vest's front: against the deepest point under
        the pouch, so it never hangs off a dip (the sternum notch)."""
        z = max(_front_z(vs, x + dx, y + dy) for dx in (-half, 0.0, half) for dy in (-0.03, 0.0, 0.03))
        return z - depth / 2 + 0.002

    kit = Geo()
    for x in (-0.085, 0.0, 0.085):
        kit.extend(_pouch((x, 1.17, seat(x, 1.17, 0.055)), (0.08, 0.13, 0.055)))
    kit.extend(_pouch((-0.1, 1.33, seat(-0.1, 1.33, 0.05)), (0.075, 0.1, 0.05)))
    kit.extend(_pouch((0.1, 1.31, seat(0.1, 1.31, 0.04)), (0.08, 0.07, 0.04)))
    za = seat(-0.105, 1.37, 0.0)
    kit.extend(cyl((-0.105, 1.37, za - 0.03), (-0.11, 1.5, za - 0.01), 0.006, 6, "U"))
    kit.extend(box((0.08, 1.33, seat(0.08, 1.33, 0.006)), (0.09, 0.04, 0.006), "U"))
    belt = _belt("W")
    # Hydration carrier on the back: against the most forward point of the back's curve under
    # it, so it never stands off the vest at its top or bottom.
    back = _helmet_surface(vest.transformed(_FLIP_Z))
    zb = min(-_front_z(back, dx, 1.27 + dy) for dx in (-0.06, 0.0, 0.06) for dy in (-0.11, 0.0, 0.11))
    kit.extend(box((0.0, 1.27, zb + 0.034), (0.17, 0.26, 0.07), "W", 0.012))
    return [("vest", vest, CHEST), ("pouches", kit, CHEST), ("cummerbund", _midriff("W"), ABDO),
            ("belt", belt, PELVIS)]


def chest_grenadier(ctx):
    """The vest up-armoured (soldier concepts 3/5): a raised collar ring, a deeper ab stack
    and a grenade belt."""
    up = facet_ring((0, 1.51, -0.01), 0.32, 0.3, 0.08, 0.045, 0.016, "A")
    belt = _belt("W")
    for x in (-0.13, -0.065, 0.065, 0.13):
        belt.extend(_pouch((x, 0.955, -0.215 + abs(x) * 0.25), (0.06, 0.08, 0.05), normal=(x * 3.0, 0, -1)))
    belt.extend(cyl((0.0, 0.925, -0.22), (0.0, 0.99, -0.22), 0.024, 8, "M"))
    return [("vest", _cuirass(ctx), CHEST), ("uparmor", up, CHEST), ("abs", _midriff(lames=3), ABDO),
            ("belt", belt, PELVIS)]


# ==== SHOULDERS (PB_UpperArm_*) ===============================================================
# Built for the right side (+X) and mirrored; the left piece takes the accent tint. Sizes clear
# the baggy BDU sleeve (upper arm ~0.07 m radius with the cloth).
def _arm_axis():
    return Vector((0.25, 1.36, 0.0)), Vector((0.275, 1.0, 0.0))


def _forearm_axis():
    return Vector((0.275, 1.0, 0.0)), Vector((0.29, 0.80, 0.0))


def _thigh_axis():
    return Vector((0.11, 0.88, 0.0)), Vector((0.11, 0.51, 0.0))


def _shin_axis():
    return Vector((0.11, 0.51, 0.0)), Vector((0.11, 0.12, 0.0))


def _sides(name, joint_fmt, right, accent=False):
    """Right-side geometry + its mirror on the left (accent: left armour plates -> X)."""
    left = right.mirrored_x()
    if accent:
        left.m = ["X" if m == "A" else m for m in left.m]
    return [(f"{name}_L", left, joint_fmt.format("L")), (f"{name}_R", right, joint_fmt.format("R"))]


def _plus_end(c, r):
    """The drawing's '+' bolt on an octagonal end plate (normal +X)."""
    g = poly_prism(octagon(r), c, (1, 0, 0), (0, 1, 0), 0.016, "M")
    g.extend(obox(Vector(c) + Vector((0.018, 0, 0)), (0, 0, 1), (0, 1, 0), (r * 1.1, r * 0.24, 0.008), "A"))
    g.extend(obox(Vector(c) + Vector((0.018, 0, 0)), (0, 0, 1), (0, 1, 0), (r * 0.24, r * 1.1, 0.008), "A"))
    return g


def shoulders_exo(ctx):
    """The drawing's shoulder can: a big octagonal drum across the joint with a '+' end bolt,
    over a deltoid plate wrapping the upper arm."""
    # Open at its inner end (the shoulder runs into it), capped by the bolt plate outside.
    g = facet_tube((0.225, 1.43, 0.0), (0.37, 1.427, 0.0), [(0, 0.19, 0.19, 0.055), (1, 0.19, 0.19, 0.055)],
                   (0, 0, -1), None, 0.018, "A")
    g.extend(_plus_end((0.37, 1.427, 0.0), 0.09))  # caps the open drum
    g.extend(facet_tube(*_arm_axis(), [(0.05, 0.172, 0.178, 0.05), (0.33, 0.165, 0.17, 0.048)],
                        (0, 0, -1), [0, 1, 2, 3, 4, 5, 7], 0.016, "A"))
    return _sides("can", "PB_UpperArm_{}", g, accent=True)


def _over_vest(p0, p1):
    """The arm axis nudged out and up so a pauldron rides over the vest's shoulder."""
    lift = Vector((0.058, 0.042, 0.0))
    return p0 + lift, p1 + lift


def shoulders_pauldron(ctx):
    """A big faceted pauldron capping the deltoid, a lip and two lames."""
    p0, p1 = _over_vest(*_arm_axis())
    g = facet_tube(p0, p1, [(-0.3, 0.13, 0.15, 0.035, 0.0), (-0.14, 0.215, 0.23, 0.06), (0.16, 0.22, 0.235, 0.06),
                            (0.3, 0.212, 0.226, 0.058)], (0, 0, -1), None, 0.02, "A", cap0=True)
    g.extend(facet_tube(p0, p1, [(0.27, 0.232, 0.246, 0.064), (0.31, 0.232, 0.246, 0.064)], (0, 0, -1), None,
                        0.014, "A"))
    for t0, sc in ((0.32, 0.95), (0.45, 0.9)):
        g.extend(facet_tube(p0, p1, [(t0, 0.205 * sc, 0.22 * sc, 0.055), (t0 + 0.14, 0.198 * sc, 0.212 * sc, 0.053)],
                            (0, 0, -1), None, 0.014, "A"))
    return _sides("pauldron", "PB_UpperArm_{}", g, accent=True)


def shoulders_heavy(ctx):
    """Concept 5: a huge boxy pauldron, three stepped lames and a steel ridge."""
    p0, p1 = _over_vest(*_arm_axis())
    g = facet_tube(p0, p1, [(-0.36, 0.16, 0.18, 0.035, 0.0), (-0.18, 0.27, 0.28, 0.06), (0.2, 0.275, 0.285, 0.06)],
                   (0, 0, -1), None, 0.024, "A", cap0=True)
    for t0, sc in ((0.18, 1.0), (0.33, 0.95), (0.48, 0.9)):
        g.extend(facet_tube(p0, p1, [(t0, 0.262 * sc, 0.272 * sc, 0.058), (t0 + 0.16, 0.252 * sc, 0.262 * sc, 0.056)],
                            (0, 0, -1), None, 0.016, "A"))
    g.extend(facet_box((0.352, 1.542, 0.0), (0.036, 0.03, 0.23), 0.01, "M", (1, 0, 0), (-0.35, 1, 0)))
    return _sides("pauldron", "PB_UpperArm_{}", g, accent=True)


# ==== ARMS (PB_UpperArm_*, PB_Forearm_*) ======================================================
def _wrist_display():
    """Left forearm readout (built on the right, mirrored): steel frame, amber screen."""
    c = Vector((0.37, 0.9, -0.012))
    g = facet_box(c, (0.026, 0.08, 0.085), 0.007, "M")
    g.extend(box(c + Vector((0.014, 0.004, 0)), (0.004, 0.052, 0.064), "V"))
    return g


def _elbow_pad():
    """Elbow cop on the back-outer corner of the elbow (PB_Forearm)."""
    g = facet_box((0.315, 1.0, 0.075), (0.085, 0.1, 0.04), 0.014, "A", (0.6, 0, 0.8), (0, 1, 0))
    g.extend(poly_prism(octagon(0.034), (0.355, 1.0, 0.0), (1, 0, 0), (0, 1, 0), 0.018, "M"))
    return g


def arms_bracer(ctx):
    """Exo drawing forearms: big boxy flared bracers with a cuff lip, elbow cops, a banded
    upper-arm plate; the wrist display rides the left bracer."""
    f0, f1 = _forearm_axis()
    br = facet_tube(f0, f1, [(0.16, 0.155, 0.155, 0.045), (0.6, 0.155, 0.15, 0.045), (1.0, 0.168, 0.158, 0.048)],
                    (0, 0, -1), None, 0.016, "A")
    br.extend(facet_tube(f0, f1, [(0.9, 0.18, 0.17, 0.05), (1.03, 0.18, 0.17, 0.05)], (0, 0, -1), None, 0.014, "A"))
    br.extend(_elbow_pad())
    # Raised outer panel along the bracer.
    br.extend(facet_box((0.372, 0.9, 0.0), (0.016, 0.13, 0.09), 0.006, "A", (1, 0, 0), (0.07, 1, 0)))
    u0, u1 = _arm_axis()
    sl = facet_tube(u0, u1, [(0.62, 0.15, 0.152, 0.042), (0.92, 0.142, 0.145, 0.04)], (0, 0, -1), None, 0.016, "A")
    sl.extend(facet_tube(u0, u1, [(0.88, 0.154, 0.157, 0.043), (0.92, 0.154, 0.157, 0.043)], (0, 0, -1), None,
                         0.012, "A"))
    for t in (0.68, 0.82):
        sl.extend(facet_tube(u0, u1, [(t, 0.158, 0.16, 0.044), (t + 0.06, 0.158, 0.16, 0.044)], (0, 0, -1),
                             None, 0.008, "W"))
    left_br = br.mirrored_x()
    left_br.extend(_wrist_display().mirrored_x())
    return [("bracer_L", left_br, "PB_Forearm_L"), ("bracer_R", br, "PB_Forearm_R")] + \
        _sides("sleeve", "PB_UpperArm_{}", sl)


def arms_strut(ctx):
    """Exo drawing's arm study: outer strut bars on octagonal joints, a padded cuff, elbow
    cops and a strapped arm pouch."""
    f0, f1 = _forearm_axis()
    g = facet_tube(f0, f1, [(0.5, 0.14, 0.14, 0.04), (1.0, 0.152, 0.148, 0.044)], (0, 0, -1), None, 0.016, "A")
    g.extend(cyl((0.355, 0.995, 0.0), (0.355, 0.86, 0.0), 0.013, 6, "M"))
    g.extend(_elbow_pad())
    u = Geo()
    u.extend(cyl((0.338, 1.26, 0.0), (0.352, 1.02, 0.0), 0.014, 6, "M"))
    u.extend(poly_prism(octagon(0.032), (0.334, 1.26, 0.0), (1, 0, 0), (0, 1, 0), 0.016, "M"))
    u.extend(_pouch((0.33, 1.17, -0.035), (0.05, 0.1, 0.075), normal=(1, 0, 0)))
    u0, u1 = _arm_axis()
    u.extend(facet_tube(u0, u1, [(0.5, 0.13, 0.13, 0.036), (0.62, 0.128, 0.128, 0.036)], (0, 0, -1), None, 0.01, "W"))
    left = g.mirrored_x()
    left.extend(_wrist_display().mirrored_x())
    return [("cuff_L", left, "PB_Forearm_L"), ("cuff_R", g, "PB_Forearm_R")] + _sides("strut", "PB_UpperArm_{}", u)


# ==== LEGS (PB_Pelvis, PB_Thigh_*, PB_Shin_*) =================================================
# Section sides kept for shells on the right leg (ref = front): 2 = outer (+X), 3 front-outer
# corner, 4 front, 5 front-inner corner, 6 inner, 0 back, 1 / 7 back corners.
FRONT_OUTER = [0, 1, 2, 3, 4, 5]


def _hip_kit(ctx, heavy=True):
    """Pelvis armour shared by the leg kits: cod plate, seat plate, and a big butt pack."""
    g = facet_box((0, 0.83, -0.13), (0.15, 0.12, 0.03), 0.02, "A" if heavy else "W", (1, 0, 0), (0, 1, 0.25))
    hit = ctx.body.ray((0.0, 0.84, 2.0), (0, 0, -1))
    rear = hit[0].z if hit[0] is not None else 0.13
    seat = facet_box((0, 0.84, rear + 0.016), (0.26, 0.12, 0.03), 0.02, "A", (1, 0, 0), (0, 1, -0.3))
    g.extend(seat)
    # Butt pack strapped to the seat plate: against its rear face.
    back = _front_z(_helmet_surface(seat.transformed(_FLIP_Z)), 0.07, 0.83)
    g.extend(_pouch((0.07, 0.83, -back + 0.0375 - 0.002), (0.16, 0.08, 0.075), normal=(0, 0, 1)))
    return g


def legs_exo(ctx):
    """Exo drawing legs: huge faceted thigh plates with the stepped notch (the inner-front
    corner stops short), the hip '+' disc, big knee pads, full shin guards with calf plates,
    calf struts, a drop-leg pouch on the right, cod and seat plates, a butt pack."""
    t0, t1 = _thigh_axis()
    g = facet_tube(t0, t1, [(-0.02, 0.29, 0.33, 0.08, -0.02), (0.52, 0.275, 0.31, 0.076, -0.016)],
                   (0, 0, -1), [1, 2, 3, 4, 5], 0.02, "A")
    g.extend(facet_tube(t0, t1, [(0.52, 0.275, 0.31, 0.076, -0.016), (0.8, 0.24, 0.27, 0.066, -0.008)],
                        (0, 0, -1), [1, 2, 3, 4], 0.02, "A"))
    # Hem lip (the prototype helmet's rim): a slightly proud band along the plate's lower edge.
    g.extend(facet_tube(t0, t1, [(0.76, 0.252, 0.282, 0.068, -0.009), (0.8, 0.25, 0.28, 0.068, -0.008)],
                        (0, 0, -1), [1, 2, 3, 4], 0.014, "A"))
    # Raised front panel with two bolts (the drawing's plates read as stacked slabs).
    panel = facet_tube(t0, t1, [(0.1, 0.17, 0.33, 0.05, -0.024), (0.44, 0.16, 0.318, 0.048, -0.022)],
                       (0, 0, -1), [3, 4, 5], 0.014, "A")
    g.extend(panel)
    ps = _helmet_surface(panel)
    for t in (0.17, 0.37):
        for dx in (-0.05, 0.05):
            y = 0.88 - 0.37 * t
            g.extend(disc((0.11 + dx, y, _front_z(ps, 0.11 + dx, y) - 0.003), (0, 0, -1), 0.008, 0.008, 6, "M"))
    g.extend(poly_prism(octagon(0.055), (0.255, 0.86, 0.0), (1, 0, 0), (0, 1, 0), 0.018, "M"))
    g.extend(_plus_end((0.273, 0.86, 0.0), 0.04))
    k0, k1 = _shin_axis()
    sh = facet_box((0.11, 0.505, -0.1), (0.15, 0.15, 0.06), 0.022, "A", (1, 0, 0), (0, 1, 0))
    sh.extend(poly_prism(octagon(0.036), (0.198, 0.505, 0.0), (1, 0, 0), (0, 1, 0), 0.018, "M"))
    sh.extend(facet_tube(k0, k1, [(0.12, 0.19, 0.22, 0.054, -0.007), (0.8, 0.2, 0.25, 0.055, -0.008)],
                         (0, 0, -1), None, 0.018, "A"))
    sh.extend(facet_tube(k0, k1, [(0.12, 0.202, 0.232, 0.056, -0.007), (0.165, 0.202, 0.232, 0.056, -0.007)],
                         (0, 0, -1), None, 0.012, "A"))
    sh.extend(cyl((0.198, 0.49, 0.01), (0.19, 0.16, 0.0), 0.012, 6, "M"))
    # Greave keel down the front of the guard.
    sh.extend(facet_box((0.11, 0.34, -0.131), (0.03, 0.2, 0.02), 0.008, "A", (1, 0, 0), (0, 1, 0.03)))
    right_thigh = Geo().extend(g)
    right_thigh.extend(_pouch((0.24, 0.69, 0.0), (0.06, 0.15, 0.13), normal=(1, 0, 0)))
    left_thigh = g.mirrored_x()
    return [("thigh_L", left_thigh, "PB_Thigh_L"), ("thigh_R", right_thigh, "PB_Thigh_R"),
            ("hips", _hip_kit(ctx), "PB_Pelvis")] + _sides("shin", "PB_Shin_{}", sh)


def legs_light(ctx):
    """GWOT kit over baggy BDU trousers: big knee pads on straps, cargo pockets, faceted shin
    plates, a drop-leg holster panel and a butt pack."""
    t0, t1 = _thigh_axis()
    g = _pouch((0.258, 0.7, 0.01), (0.05, 0.16, 0.14), normal=(1, 0, 0))
    g.extend(_pouch((0.11, 0.66, -0.145), (0.12, 0.12, 0.045)))
    g.extend(facet_tube(t0, t1, [(0.2, 0.225, 0.245, 0.065), (0.25, 0.225, 0.245, 0.065)], (0, 0, -1), None, 0.008, "W"))
    k0, k1 = _shin_axis()
    sh = facet_box((0.11, 0.505, -0.098), (0.14, 0.14, 0.055), 0.022, "W", (1, 0, 0), (0, 1, 0))
    sh.extend(facet_box((0.11, 0.51, -0.128), (0.1, 0.09, 0.014), 0.012, "A", (1, 0, 0), (0, 1, 0)))
    sh.extend(facet_tube(k0, k1, [(0.03, 0.17, 0.185, 0.05), (0.08, 0.17, 0.185, 0.05)], (0, 0, -1), None, 0.008, "W"))
    sh.extend(facet_tube(k0, k1, [(0.16, 0.16, 0.18, 0.046, -0.006), (0.6, 0.15, 0.165, 0.044, -0.004)],
                         (0, 0, -1), [2, 3, 4, 5, 6], 0.018, "A"))
    return _sides("pouch", "PB_Thigh_{}", g) + _sides("knee", "PB_Shin_{}", sh) + \
        [("hips", _hip_kit(ctx, heavy=False), "PB_Pelvis")]


# ==== catalogue ===============================================================================
# slot -> [(variant id, display name, builder)]. First entry = default. Ids: lowercase, no "_".
CATALOGUE = {
    "helmet": [
        ("hospitaller", "Hospitaller", helmet_hospitaller),
        ("warden", "Warden", helmet_warden),
        ("vanguard", "Vanguard", helmet_vanguard),
        ("sentry", "Sentry", helmet_sentry),
        ("lancer", "Lancer", helmet_lancer),
    ],
    "chest": [
        ("hospitaller", "Hospitaller", chest_hospitaller),
        ("breastplate", "Breastplate", chest_breastplate),
        ("exo", "Exo Harness", chest_exo),
        ("carrier", "Plate Carrier", chest_carrier),
        ("grenadier", "Grenadier", chest_grenadier),
    ],
    "shoulders": [
        ("exo", "Exo Cans", shoulders_exo),
        ("pauldron", "Pauldrons", shoulders_pauldron),
        ("heavy", "Heavy", shoulders_heavy),
    ],
    "arms": [
        ("bracer", "Bracers", arms_bracer),
        ("strut", "Struts", arms_strut),
    ],
    "legs": [
        ("exo", "Exo Plates", legs_exo),
        ("light", "Light Kit", legs_light),
    ],
}

SLOT_JOINT = {"helmet": HEAD}


def build_all(ctx, only=None):
    """-> list of Part for every slot / variant (+ core)."""
    out = []
    for slot, variants in CATALOGUE.items():
        for vid, _name, fn in variants:
            if only and (slot, vid) not in only:
                continue
            for piece in fn(ctx):
                joint = SLOT_JOINT.get(slot)
                name, geo = piece[0], piece[1]
                if len(piece) > 2:
                    joint = piece[2]
                pivot = piece[3] if len(piece) > 3 else None
                out.append(Part(f"AR_{slot}_{vid}_{name}", joint, geo, pivot))
    return out
