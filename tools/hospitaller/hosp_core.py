"""Core parts every loadout shows: armoured gloves, boots and the neck seal.

Gloves replace the base mesh's open hands (the guns need a fist on WeaponAttach_R), boots
replace its feet. Boot soles keep the block-out's contact box (heel z +0.115, toe z -0.175,
sole at y 0) that tools/character_anims checks foot planting against.
"""
from hosp_armor import SIDES, Part
from hosp_geo import box, cyl, disc, facet_box, facet_ring


def glove(s):
    """Armoured glove (fist), faceted like the prototype pieces: a chamfered fist, a back-of-
    hand plate, a knuckle plate with steel studs, the thumb, a webbing cuff."""
    x = s * 0.283
    g = facet_box((x, 0.745, -0.012), (0.075, 0.1, 0.105), 0.022, "U")
    g.extend(facet_box((x + s * 0.042, 0.756, -0.012), (0.016, 0.078, 0.092), 0.006, "A"))
    g.extend(facet_box((x, 0.717, -0.065), (0.082, 0.036, 0.02), 0.007, "A"))
    for k in range(3):
        g.extend(box((x - s * 0.024 + s * k * 0.024, 0.703, -0.075), (0.016, 0.012, 0.01), "M"))
    g.extend(facet_box((x - s * 0.033, 0.758, -0.05), (0.028, 0.056, 0.032), 0.009, "U",
                       (1, 0, 0), (0, 1, 0.35)))
    g.extend(facet_ring((s * 0.29, 0.797, -0.003), 0.102, 0.102, 0.03, 0.046, 0.012, "W"))
    return g


def boot(s):
    """Chunky faceted boot: rubber sole, toe cap and heel counter in armour plate, a shaft wide
    enough for the bloused BDU with a strap, a plated front and a top lip, the drawing's ankle
    disc outside. The sole keeps the block-out's contact box (heel z +0.115, toe z -0.175)."""
    x = s * 0.11
    g = facet_box((x, 0.02, -0.03), (0.13, 0.04, 0.30), 0.03, "U")
    g.extend(facet_box((x, 0.075, -0.02), (0.12, 0.07, 0.26), 0.035, "U"))
    g.extend(facet_box((x, 0.072, -0.125), (0.128, 0.066, 0.1), 0.034, "A"))
    g.extend(facet_box((x, 0.072, 0.095), (0.124, 0.07, 0.052), 0.024, "A"))
    g.extend(facet_box((x, 0.18, 0.003), (0.136, 0.17, 0.152), 0.04, "U"))
    g.extend(facet_ring((x, 0.15, 0.003), 0.15, 0.166, 0.045, 0.03, 0.01, "W"))
    g.extend(facet_ring((x, 0.257, 0.003), 0.15, 0.166, 0.045, 0.024, 0.012, "A"))
    g.extend(facet_box((x, 0.185, -0.082), (0.1, 0.15, 0.02), 0.008, "A"))
    # The drawing's ankle disc on the outer side.
    g.extend(disc((x + s * 0.075, 0.12, 0.0), (s, 0, 0), 0.032, 0.014, 8, "M"))
    g.extend(disc((x + s * 0.083, 0.12, 0.0), (s, 0, 0), 0.013, 0.008, 8, "U"))
    return g


def build_core(ctx):
    parts = []
    for s, L in SIDES:
        parts.append(Part(f"CORE_glove_{L}", f"PB_Hand_{L}", glove(s)))
        parts.append(Part(f"CORE_boot_{L}", f"PB_Boot_{L}", boot(s)))
    parts.append(Part("CORE_neckseal", "PB_Neck",
                      cyl((0, 1.455, 0.0), (0, 1.505, 0.0), 0.088, 10, "U", r1=0.08)))
    return parts
