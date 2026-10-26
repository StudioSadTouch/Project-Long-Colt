"""Workbench preview renders for the Hospitaller generator (orthographic, Godot-space aim)."""
import math
import os

import bpy
from mathutils import Vector

from hosp_geo import g2b

VIEWS = {
    # name: direction FROM the model TO the camera, Godot space (-Z is the character's front)
    "front": (0, 0, -1),
    "back": (0, 0, 1),
    "left": (-1, 0, 0),
    "right": (1, 0, 0),
    "q34": (-0.62, 0.18, -0.76),
    "q34b": (0.62, 0.18, 0.76),
}


def setup(scene, color_type="MATERIAL", w=700, h=900):
    scene.render.engine = "BLENDER_WORKBENCH"
    sh = scene.display.shading
    sh.light = "STUDIO"
    sh.color_type = color_type
    sh.show_cavity = True
    sh.cavity_type = "BOTH"
    sh.show_object_outline = True
    sh.object_outline_color = (0.05, 0.05, 0.05)
    sh.show_specular_highlight = False
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    scene.render.film_transparent = False
    scene.display.render_aa = "8"
    scene.view_settings.view_transform = "Standard"
    world = scene.world or bpy.data.worlds.new("W")
    scene.world = world
    world.color = (0.28, 0.29, 0.3)


def camera(scene, target_g, size):
    cam = scene.camera
    if cam is None or cam.name != "PreviewCam":
        data = bpy.data.cameras.new("PreviewCam")
        data.type = "ORTHO"
        cam = bpy.data.objects.new("PreviewCam", data)
        scene.collection.objects.link(cam)
        scene.camera = cam
    cam.data.ortho_scale = size
    return cam


def shoot(scene, path, view, target_g=(0, 0.9, 0), size=2.1):
    cam = camera(scene, target_g, size)
    d = Vector(VIEWS[view]).normalized() if isinstance(view, str) else Vector(view).normalized()
    t = g2b(target_g)
    db = g2b(d)
    cam.location = t + db * 6.0
    cam.rotation_euler = (-db).to_track_quat("-Z", "Y").to_euler()
    cam.data.clip_end = 20
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def sheet(paths, out, cols=None):
    """Paste renders side by side (Blender's own image API; no PIL inside Blender)."""
    imgs = [bpy.data.images.load(p) for p in paths]
    w, h = imgs[0].size
    cols = cols or len(imgs)
    rows = math.ceil(len(imgs) / cols)
    W, H = w * cols, h * rows
    px = [0.0] * (W * H * 4)
    for k, im in enumerate(imgs):
        src = list(im.pixels)
        ox, oy = (k % cols) * w, (rows - 1 - k // cols) * h
        for y in range(h):
            row = src[y * w * 4:(y + 1) * w * 4]
            o = ((oy + y) * W + ox) * 4
            px[o:o + w * 4] = row
    out_img = bpy.data.images.new("sheet", W, H)
    out_img.pixels = px
    out_img.filepath_raw = out
    out_img.file_format = "PNG"
    out_img.save()
    for im in imgs:
        bpy.data.images.remove(im)
    bpy.data.images.remove(out_img)
    for p in paths:
        os.remove(p)
