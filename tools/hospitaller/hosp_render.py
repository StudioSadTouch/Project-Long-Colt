"""Preview renders: full loadouts in four views and per-slot variant line-ups."""
import os


import hosp_armor
import hosp_preview

LOADOUTS = {
    # name: {slot: variant}; missing slots use the slot's first (default) variant
    "default": {},
    "templar": {"helmet": "warden", "chest": "breastplate", "shoulders": "pauldron"},
    "grenadier": {"helmet": "sentry", "chest": "grenadier", "shoulders": "heavy"},
    "recon": {"helmet": "vanguard", "chest": "carrier", "arms": "strut", "legs": "light"},
    "lancer": {"helmet": "lancer", "chest": "exo", "shoulders": "pauldron", "arms": "strut", "legs": "light"},
    "heavy": {"shoulders": "heavy"},
}


def _show(part_objs, loadout):
    for o in part_objs:
        bits = o.name.split("_")
        if bits[0] == "CORE":
            vis = True
        else:
            slot, var = bits[1], bits[2]
            want = loadout.get(slot, hosp_armor.CATALOGUE[slot][0][0])
            vis = var == want
        o.hide_render = not vis


def render_all(scene, col, part_objs, undersuit, out_dir, loadouts=None, views=("front", "q34", "left", "back", "q34b")):
    os.makedirs(out_dir, exist_ok=True)
    import os as _os
    hosp_preview.setup(scene, "MATERIAL", int(_os.environ.get("HOSP_W", 600)), int(_os.environ.get("HOSP_H", 900)))
    for name, lo in (loadouts or LOADOUTS).items():
        _show(part_objs, lo)
        for v in views:
            hosp_preview.shoot(scene, os.path.join(out_dir, f"{name}_{v}.png"), v, (0, 0.91, 0), 2.0)
    # Variant line-ups per slot (close-ups where it helps).
    focus = {"helmet": ((0, 1.64, 0), 0.5), "chest": ((0, 1.15, 0), 0.9),
             "shoulders": ((0, 1.25, 0), 0.9), "arms": ((0, 1.05, 0), 1.0),
             "legs": ((0, 0.5, 0), 1.1)}
    hosp_preview.setup(scene, "MATERIAL", 500, 500)
    for slot, variants in hosp_armor.CATALOGUE.items():
        for vid, _n, _f in variants:
            _show(part_objs, {slot: vid})
            for v in ("front", "q34", "left"):
                tgt, size = focus.get(slot, ((0, 0.9, 0), 2.0))
                hosp_preview.shoot(scene, os.path.join(out_dir, f"slot_{slot}_{vid}_{v}.png"), v, tgt, size)
    # Vanguard's up-armour plate flipped up (helmets.png 2A).
    plates = [o for o in part_objs if "visorplate" in o.name]
    if plates:
        import math
        _show(part_objs, {"helmet": "vanguard"})
        for o in plates:
            o.rotation_euler.x = math.radians(hosp_armor.PLATE_UP_DEG)
        for v in ("front", "q34", "left"):
            hosp_preview.shoot(scene, os.path.join(out_dir, f"slot_helmet_vanguardup_{v}.png"), v,
                               focus["helmet"][0], focus["helmet"][1])
        for o in plates:
            o.rotation_euler.x = 0.0
    _show(part_objs, {})
