#!/usr/bin/env python3
"""
===============================================================================
Project Long Colt — CC0 Prototype Texture & PBR Material Pipeline
===============================================================================
Generates high-resolution (1024x1024) seamless developer grid textures,
industrial concrete, metal deck tread plates, sci-fi bulkhead panels,
trim sheets, hazard stripes, and corresponding Godot 4.7 StandardMaterial3D
resources configured with world-space triplanar mapping.

Author: Material & Texture Pipeline Specialist
Engine: Godot 4.7.2 Forward+
===============================================================================
"""

import os
import sys
import math
import random
import argparse
from typing import Dict, Tuple, List, Optional
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps, ImageChops

# ---------------------------------------------------------------------------
# Color & Palette Utilities
# ---------------------------------------------------------------------------

def hex_to_rgb(hex_str: str) -> Tuple[int, int, int]:
    hex_str = hex_str.lstrip('#')
    return tuple(int(hex_str[i:i+2], 16) for i in (0, 2, 4))

def blend_color(c1: Tuple[int, ...], c2: Tuple[int, ...], factor: float) -> Tuple[int, ...]:
    return tuple(int(c1[i] * (1.0 - factor) + c2[i] * factor) for i in range(len(c1)))

PALETTES = {
    "dark": {
        "name": "dark",
        "bg": hex_to_rgb("#1c1f24"),
        "line_minor": hex_to_rgb("#292e37"),
        "line_mid": hex_to_rgb("#3d4655"),
        "line_major": hex_to_rgb("#5e6c82"),
        "accent": hex_to_rgb("#8f9eb6"),
        "tick_highlight": hex_to_rgb("#ff9d00"),
        "vignette_depth": 0.08,
    },
    "light": {
        "name": "light",
        "bg": hex_to_rgb("#d6dae0"),
        "line_minor": hex_to_rgb("#c0c6d0"),
        "line_mid": hex_to_rgb("#a1abbb"),
        "line_major": hex_to_rgb("#6c778c"),
        "accent": hex_to_rgb("#3d4554"),
        "tick_highlight": hex_to_rgb("#0077cc"),
        "vignette_depth": 0.05,
    },
    "orange": {
        "name": "orange",
        "bg": hex_to_rgb("#b84800"),
        "line_minor": hex_to_rgb("#a03d00"),
        "line_mid": hex_to_rgb("#d65a0b"),
        "line_major": hex_to_rgb("#ff8533"),
        "accent": hex_to_rgb("#ffffff"),
        "tick_highlight": hex_to_rgb("#ffffff"),
        "vignette_depth": 0.08,
    },
    "green": {
        "name": "green",
        "bg": hex_to_rgb("#1e3322"),
        "line_minor": hex_to_rgb("#29442e"),
        "line_mid": hex_to_rgb("#3c6143"),
        "line_major": hex_to_rgb("#588f63"),
        "accent": hex_to_rgb("#a4cca9"),
        "tick_highlight": hex_to_rgb("#ffc107"),
        "vignette_depth": 0.07,
    },
    "blue": {
        "name": "blue",
        "bg": hex_to_rgb("#14253d"),
        "line_minor": hex_to_rgb("#1c3352"),
        "line_mid": hex_to_rgb("#2a4c78"),
        "line_major": hex_to_rgb("#4576b2"),
        "accent": hex_to_rgb("#9cc5f8"),
        "tick_highlight": hex_to_rgb("#00e5ff"),
        "vignette_depth": 0.07,
    },
    "red": {
        "name": "red",
        "bg": hex_to_rgb("#3d1515"),
        "line_minor": hex_to_rgb("#521c1c"),
        "line_mid": hex_to_rgb("#752828"),
        "line_major": hex_to_rgb("#a83c3c"),
        "accent": hex_to_rgb("#f5aaaa"),
        "tick_highlight": hex_to_rgb("#ffdd00"),
        "vignette_depth": 0.08,
    },
}

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Bold.ttf",
    "/usr/share/fonts/truetype/roboto/unhinted/RobotoCondensed-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
]

def get_font(size: int, bold: bool = True) -> ImageFont.ImageFont:
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()

# ---------------------------------------------------------------------------
# Seamless Image Processing Helpers
# ---------------------------------------------------------------------------

def make_periodic(img: Image.Image, pad: int = 8) -> Image.Image:
    """Pad an image with opposite edge wraps to ensure boundary filter continuity."""
    w, h = img.size
    padded = Image.new(img.mode, (w + 2 * pad, h + 2 * pad))
    padded.paste(img, (pad, pad))
    padded.paste(img.crop((0, h - pad, w, h)), (pad, 0))
    padded.paste(img.crop((0, 0, w, pad)), (pad, h + pad))
    padded.paste(img.crop((w - pad, 0, w, h)), (0, pad))
    padded.paste(img.crop((0, 0, pad, h)), (w + pad, pad))
    padded.paste(img.crop((w - pad, h - pad, w, h)), (0, 0))
    padded.paste(img.crop((0, h - pad, pad, h)), (w + pad, 0))
    padded.paste(img.crop((w - pad, 0, w, pad)), (0, h + pad))
    padded.paste(img.crop((0, 0, pad, pad)), (w + pad, h + pad))
    return padded

def periodic_filter(img: Image.Image, filt: ImageFilter.Filter, pad: int = 8) -> Image.Image:
    """Filter an image with periodic boundary wrap-around."""
    w, h = img.size
    padded = make_periodic(img, pad)
    filtered = padded.filter(filt)
    return filtered.crop((pad, pad, pad + w, pad + h))

def height_to_normal(height_img: Image.Image, strength: float = 2.0) -> Image.Image:
    """
    Converts an 8-bit heightmap to a seamless OpenGL tangent-space normal map.
    R = X+ (right), G = Y+ (up), B = Z+ (outward).
    """
    w, h = height_img.size
    pad = 4
    padded = make_periodic(height_img, pad)
    scale = max(1, int(8.0 / max(0.1, strength)))
    # Sobel X: dz/dx (right - left)
    kx = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
    # Sobel Y: In OpenGL normal maps, +Y points upward. In image space row 0 is top.
    # Therefore, upward slope = top - bottom:
    ky = [1, 2, 1, 0, 0, 0, -1, -2, -1]
    dx = padded.filter(ImageFilter.Kernel((3, 3), kx, scale=scale, offset=128)).crop((pad, pad, pad + w, pad + h))
    dy = padded.filter(ImageFilter.Kernel((3, 3), ky, scale=scale, offset=128)).crop((pad, pad, pad + w, pad + h))
    bz = Image.new('L', (w, h), 250)
    return Image.merge('RGB', (dx, dy, bz))

def generate_seamless_noise(size: int, octaves: int = 3, base_res: int = 16, seed: int = 42) -> Image.Image:
    """Generates multi-octave seamless value noise."""
    rng = random.Random(seed)
    total = Image.new('L', (size, size), 128)
    for i in range(octaves):
        res = base_res * (2 ** i)
        small = Image.new('L', (res, res))
        pixels = [rng.randint(0, 255) for _ in range(res * res)]
        small.putdata(pixels)
        tiled = Image.new('L', (res * 3, res * 3))
        for tx in range(3):
            for ty in range(3):
                tiled.paste(small, (tx * res, ty * res))
        scaled = tiled.resize((size * 3, size * 3), Image.Resampling.BICUBIC)
        cropped = scaled.crop((size, size, size * 2, size * 2))
        weight = 0.5 ** i
        total = Image.blend(total, cropped, weight / (1.0 + weight))
    return total

def draw_hex_bolt(draw: ImageDraw.ImageDraw, center: Tuple[int, int], radius: int,
                  color_head: Tuple[int, int, int], color_recess: Tuple[int, int, int],
                  color_spec: Tuple[int, int, int]) -> None:
    """Draws a mechanical countersunk hex bolt."""
    cx, cy = center
    # Outer recessed circular socket
    draw.ellipse([cx - radius - 2, cy - radius - 2, cx + radius + 2, cy + radius + 2], fill=color_recess)
    # Hexagon head
    points = []
    for i in range(6):
        angle = math.radians(60 * i + 30)
        px = cx + radius * math.cos(angle)
        py = cy + radius * math.sin(angle)
        points.append((px, py))
    draw.polygon(points, fill=color_head)
    # Center hex indentation / allen socket or highlight
    inner_rad = max(1, radius // 2)
    draw.ellipse([cx - inner_rad, cy - inner_rad, cx + inner_rad, cy + inner_rad], fill=color_recess)
    draw.point((cx - 1, cy - 1), fill=color_spec)

# ---------------------------------------------------------------------------
# 1. Metric Grid Generator (1.0m)
# ---------------------------------------------------------------------------

def generate_metric_grid_1m(palette: Dict, size: int = 1024) -> Image.Image:
    """
    Generates a 1.0m metric grid with sub-meter coordinate lines, center crosshairs,
    corner alignment brackets, and clear measure typography.
    Seamlessly tiles in world-space.
    """
    img = Image.new('RGB', (size, size), palette["bg"])
    
    # 1. Subtle surface noise for matte industrial finish
    noise = generate_seamless_noise(size, octaves=3, base_res=32, seed=101)
    noise_rgb = Image.merge('RGB', (noise, noise, noise))
    img = Image.blend(img, noise_rgb, 0.04)
    
    draw = ImageDraw.Draw(img)
    
    # 2. Subtle quadrant background modulation
    half = size // 2
    quad_shade = Image.new('L', (size, size), 0)
    qdraw = ImageDraw.Draw(quad_shade)
    pad = 4
    for qx, qy in [(0, 0), (half, 0), (0, half), (half, half)]:
        qdraw.rectangle([qx + pad, qy + pad, qx + half - pad, qy + half - pad], fill=12)
    quad_shade = periodic_filter(quad_shade, ImageFilter.GaussianBlur(radius=8), pad=16)
    quad_rgb = Image.new('RGB', (size, size), palette["line_minor"])
    img.paste(quad_rgb, (0, 0), mask=quad_shade)
    draw = ImageDraw.Draw(img)
    
    # 3. Minor 0.1m subdivision lines (10 grid cells per meter)
    for i in range(1, 10):
        pos = int(round(i * size / 10.0))
        if pos == half:
            continue
        draw.line([(pos, 0), (pos, size - 1)], fill=palette["line_minor"], width=1)
        draw.line([(0, pos), (size - 1, pos)], fill=palette["line_minor"], width=1)
        
    # 4. Center 0.5m subdivision lines
    draw.line([(half, 0), (half, size - 1)], fill=palette["line_mid"], width=3)
    draw.line([(0, half), (size - 1, half)], fill=palette["line_mid"], width=3)
    
    # 5. Outer 1.0m seamless border (2px on each border = 4px combined when tiled)
    draw.line([(0, 0), (size - 1, 0)], fill=palette["line_major"], width=2)
    draw.line([(0, size - 1), (size - 1, size - 1)], fill=palette["line_major"], width=2)
    draw.line([(0, 0), (0, size - 1)], fill=palette["line_major"], width=2)
    draw.line([(size - 1, 0), (size - 1, size - 1)], fill=palette["line_major"], width=2)
    
    # 6. Center crosshair at (half, half)
    ch_len = 28
    ch_w = 3
    draw.line([(half - ch_len, half), (half + ch_len, half)], fill=palette["accent"], width=ch_w)
    draw.line([(half, half - ch_len), (half, half + ch_len)], fill=palette["accent"], width=ch_w)
    draw.ellipse([half - 7, half - 7, half + 7, half + 7], outline=palette["accent"], width=2)
    
    # 7. Axis ticks along center axes (every 0.1m)
    tick_len = 10
    for i in range(1, 10):
        pos = int(round(i * size / 10.0))
        if pos == half:
            continue
        # Horizontal axis ticks
        col = palette["tick_highlight"] if i in (2, 5, 8) else palette["accent"]
        draw.line([(pos, half - tick_len), (pos, half + tick_len)], fill=col, width=2)
        # Vertical axis ticks
        draw.line([(half - tick_len, pos), (half + tick_len, pos)], fill=col, width=2)
        
    # 8. Corner L-brackets in the 4 corners
    bk_len = 44
    bk_w = 3
    bk_off = 28
    # Top-Left
    draw.line([(bk_off, bk_off), (bk_off + bk_len, bk_off)], fill=palette["accent"], width=bk_w)
    draw.line([(bk_off, bk_off), (bk_off, bk_off + bk_len)], fill=palette["accent"], width=bk_w)
    draw.rectangle([bk_off - 1, bk_off - 1, bk_off + 3, bk_off + 3], fill=palette["tick_highlight"])
    # Top-Right
    draw.line([(size - bk_off, bk_off), (size - bk_off - bk_len, bk_off)], fill=palette["accent"], width=bk_w)
    draw.line([(size - bk_off, bk_off), (size - bk_off, bk_off + bk_len)], fill=palette["accent"], width=bk_w)
    draw.rectangle([size - bk_off - 3, bk_off - 1, size - bk_off + 1, bk_off + 3], fill=palette["tick_highlight"])
    # Bottom-Left
    draw.line([(bk_off, size - bk_off), (bk_off + bk_len, size - bk_off)], fill=palette["accent"], width=bk_w)
    draw.line([(bk_off, size - bk_off), (bk_off, size - bk_off - bk_len)], fill=palette["accent"], width=bk_w)
    draw.rectangle([bk_off - 1, size - bk_off - 3, bk_off + 3, size - bk_off + 1], fill=palette["tick_highlight"])
    # Bottom-Right
    draw.line([(size - bk_off, size - bk_off), (size - bk_off - bk_len, size - bk_off)], fill=palette["accent"], width=bk_w)
    draw.line([(size - bk_off, size - bk_off), (size - bk_off, size - bk_off - bk_len)], fill=palette["accent"], width=bk_w)
    draw.rectangle([size - bk_off - 3, size - bk_off - 3, size - bk_off + 1, size - bk_off + 1], fill=palette["tick_highlight"])

    # 9. Clean typography / metric markings
    f_title = get_font(34, bold=True)
    f_sub = get_font(18, bold=False)
    f_small = get_font(14, bold=False)
    
    # Top-left quadrant label
    draw.text((44, 40), "1.0m", fill=palette["accent"], font=f_title)
    draw.text((46, 78), "[0.0 , 0.0]", fill=palette["line_major"], font=f_sub)
    draw.text((46, 98), "SCALE: 1 UNIT = 1m", fill=palette["line_mid"], font=f_small)

    # Bottom-right quadrant label
    draw.text((size - 170, size - 110), "1.0m", fill=palette["accent"], font=f_title)
    draw.text((size - 220, size - 72), "LONG COLT // PROTO", fill=palette["line_major"], font=f_sub)
    draw.text((size - 220, size - 52), "[1.0 , 1.0]", fill=palette["line_mid"], font=f_small)

    # Center axis indicator
    draw.text((half + 12, half + 12), "+ 0.5m", fill=palette["line_major"], font=f_sub)
    
    return img

# ---------------------------------------------------------------------------
# 2. Metric Grid Generator (0.5m)
# ---------------------------------------------------------------------------

def generate_metric_grid_05m(palette: Dict, size: int = 1024) -> Image.Image:
    """
    Generates a 0.5m metric grid composed of 4 detailed 0.5m quadrants.
    Provides tighter measurement marks and high-density grid lines for detail blockouts.
    """
    img = Image.new('RGB', (size, size), palette["bg"])
    noise = generate_seamless_noise(size, octaves=3, base_res=32, seed=202)
    noise_rgb = Image.merge('RGB', (noise, noise, noise))
    img = Image.blend(img, noise_rgb, 0.04)
    draw = ImageDraw.Draw(img)
    
    half = size // 2
    quad_size = half
    
    # 0.1m minor subdivision lines (10 per meter = 5 per quadrant)
    for i in range(1, 10):
        pos = int(round(i * size / 10.0))
        if pos == half:
            continue
        draw.line([(pos, 0), (pos, size - 1)], fill=palette["line_minor"], width=1)
        draw.line([(0, pos), (size - 1, pos)], fill=palette["line_minor"], width=1)

    # 0.25m mid subdivision lines (256, 768)
    for pos in [256, 768]:
        draw.line([(pos, 0), (pos, size - 1)], fill=palette["line_minor"], width=2)
        draw.line([(0, pos), (size - 1, pos)], fill=palette["line_minor"], width=2)

    # 0.5m quadrant divider lines (at 512)
    draw.line([(half, 0), (half, size - 1)], fill=palette["line_major"], width=3)
    draw.line([(0, half), (size - 1, half)], fill=palette["line_major"], width=3)

    # Outer seamless 1m border (2px)
    draw.line([(0, 0), (size - 1, 0)], fill=palette["line_major"], width=2)
    draw.line([(0, size - 1), (size - 1, size - 1)], fill=palette["line_major"], width=2)
    draw.line([(0, 0), (0, size - 1)], fill=palette["line_major"], width=2)
    draw.line([(size - 1, 0), (size - 1, size - 1)], fill=palette["line_major"], width=2)

    # Typography & quadrant details
    f_qtitle = get_font(26, bold=True)
    f_qsub = get_font(15, bold=False)
    
    quadrants = [
        ("SEC-A1", 0, 0),
        ("SEC-A2", half, 0),
        ("SEC-B1", 0, half),
        ("SEC-B2", half, half),
    ]
    
    for qlabel, qx, qy in quadrants:
        # Corner brackets inside each quadrant
        qbk = 24
        qoff = 16
        # Top-left of quadrant
        draw.line([(qx + qoff, qy + qoff), (qx + qoff + qbk, qy + qoff)], fill=palette["accent"], width=2)
        draw.line([(qx + qoff, qy + qoff), (qx + qoff, qy + qoff + qbk)], fill=palette["accent"], width=2)
        # Quadrant crosshair at center of quadrant
        cqx, cqy = qx + quad_size // 2, qy + quad_size // 2
        draw.line([(cqx - 12, cqy), (cqx + 12, cqy)], fill=palette["line_mid"], width=2)
        draw.line([(cqx, cqy - 12), (cqx, cqy + 12)], fill=palette["line_mid"], width=2)
        # Quadrant labels
        draw.text((qx + 24, qy + 22), "0.5m", fill=palette["accent"], font=f_qtitle)
        draw.text((qx + 26, qy + 54), qlabel, fill=palette["line_mid"], font=f_qsub)

    return img

# ---------------------------------------------------------------------------
# 3. Hazard Stripe Generator (Seamless 45-degree)
# ---------------------------------------------------------------------------

def generate_hazard_stripes(color_a: Tuple[int, int, int], color_b: Tuple[int, int, int],
                            size: int = 1024, stripe_width: int = 64) -> Image.Image:
    """
    Generates seamless 45-degree diagonal hazard warning stripes.
    Guaranteed periodic tiling: period P = 2 * stripe_width = 128 (1024 % 128 == 0).
    Includes mechanical mounting border and bolt studs for grounded industrial realism.
    """
    period = stripe_width * 2
    # 1. 45-degree diagonal stripe fill using fast tiled pattern
    tile_pat = Image.new('L', (period, period), 0)
    for ty in range(period):
        for tx in range(period):
            if (tx + ty) % period < stripe_width:
                tile_pat.putpixel((tx, ty), 255)

    stripe_mask = Image.new('L', (size, size))
    for tx in range(0, size, period):
        for ty in range(0, size, period):
            stripe_mask.paste(tile_pat, (tx, ty))

    img = Image.new('RGB', (size, size), color_b)
    img_a = Image.new('RGB', (size, size), color_a)
    img.paste(img_a, (0, 0), mask=stripe_mask)
                
    # 2. Add subtle edge bevel on stripe boundaries
    height = Image.new('L', (size, size), 100)
    h_a = Image.new('L', (size, size), 200)
    height.paste(h_a, (0, 0), mask=stripe_mask)
                
    # Bevel shading
    bevel_norm = height_to_normal(height, strength=1.5)
    bevel_gray = ImageOps.grayscale(bevel_norm)
    img = ImageChops.multiply(img, ImageOps.colorize(bevel_gray, "#a0a0a0", "#ffffff"))

    # 3. Micro surface grunge
    grunge = generate_seamless_noise(size, octaves=4, base_res=64, seed=303)
    grunge_rgb = Image.merge('RGB', (grunge, grunge, grunge))
    img = Image.blend(img, grunge_rgb, 0.05)
    
    # 4. Seamless perimeter frame with mounting hex bolts
    draw = ImageDraw.Draw(img)
    frame_w = 14
    frame_col = hex_to_rgb("#23262a")
    frame_highlight = hex_to_rgb("#555c66")
    
    # Outer frame borders
    draw.rectangle([0, 0, size - 1, frame_w], fill=frame_col)
    draw.rectangle([0, size - 1 - frame_w, size - 1, size - 1], fill=frame_col)
    draw.rectangle([0, 0, frame_w, size - 1], fill=frame_col)
    draw.rectangle([size - 1 - frame_w, 0, size - 1, size - 1], fill=frame_col)
    
    # Frame edge lines
    draw.line([(frame_w, frame_w), (size - 1 - frame_w, frame_w)], fill=frame_highlight, width=1)
    draw.line([(frame_w, size - 1 - frame_w), (size - 1 - frame_w, size - 1 - frame_w)], fill=frame_highlight, width=1)
    draw.line([(frame_w, frame_w), (frame_w, size - 1 - frame_w)], fill=frame_highlight, width=1)
    draw.line([(size - 1 - frame_w, frame_w), (size - 1 - frame_w, size - 1 - frame_w)], fill=frame_highlight, width=1)

    # Rivets every 128px along the frame (seamless!)
    bolt_c_head = hex_to_rgb("#4a5059")
    bolt_c_recess = hex_to_rgb("#121417")
    bolt_c_spec = hex_to_rgb("#8f99a8")
    half_fw = frame_w // 2
    
    for i in range(0, size, 128):
        # Top & Bottom frames
        draw_hex_bolt(draw, (i + 64, half_fw), 4, bolt_c_head, bolt_c_recess, bolt_c_spec)
        draw_hex_bolt(draw, (i + 64, size - 1 - half_fw), 4, bolt_c_head, bolt_c_recess, bolt_c_spec)
        # Left & Right frames
        draw_hex_bolt(draw, (half_fw, i + 64), 4, bolt_c_head, bolt_c_recess, bolt_c_spec)
        draw_hex_bolt(draw, (size - 1 - half_fw, i + 64), 4, bolt_c_head, bolt_c_recess, bolt_c_spec)

    return img

# ---------------------------------------------------------------------------
# 4. Dark Industrial Concrete PBR Set
# ---------------------------------------------------------------------------

def generate_concrete_dark(size: int = 1024) -> Tuple[Image.Image, Image.Image, Image.Image]:
    """
    Generates a full PBR texture set for dark reinforced industrial concrete:
    - Albedo: Dark slate aggregate with formwork panel seams and tie-rod holes.
    - Roughness: High matte roughness with aggregate micro-variations.
    - Normal: Tangent-space normal map capturing formwork seams, tie-rod recesses, and aggregate grain.
    """
    # 1. Base multi-scale noise for concrete aggregate & curing variation
    macro_noise = generate_seamless_noise(size, octaves=4, base_res=16, seed=401)
    micro_noise = generate_seamless_noise(size, octaves=4, base_res=128, seed=402)
    
    # 2. Concrete heightmap
    height = Image.blend(macro_noise, micro_noise, 0.45)
    h_draw = ImageDraw.Draw(height)
    
    # Formwork seams: 4 precast panels (seams at 0, 512)
    seam_depth = 80
    h_draw.line([(512, 0), (512, size - 1)], fill=seam_depth, width=4)
    h_draw.line([(0, 512), (size - 1, 512)], fill=seam_depth, width=4)
    # Edge seams for seamless tiling
    h_draw.line([(0, 0), (size - 1, 0)], fill=seam_depth, width=2)
    h_draw.line([(0, size - 1), (size - 1, size - 1)], fill=seam_depth, width=2)
    h_draw.line([(0, 0), (0, size - 1)], fill=seam_depth, width=2)
    h_draw.line([(size - 1, 0), (size - 1, size - 1)], fill=seam_depth, width=2)
    
    # Tie rod plug depressions in panel corners
    half = size // 2
    tie_offset = 64
    tie_positions = []
    for qx, qy in [(0, 0), (half, 0), (0, half), (half, half)]:
        tie_positions.extend([
            (qx + tie_offset, qy + tie_offset),
            (qx + half - tie_offset, qy + tie_offset),
            (qx + tie_offset, qy + half - tie_offset),
            (qx + half - tie_offset, qy + half - tie_offset),
        ])
        
    for cx, cy in tie_positions:
        # Outer depression
        h_draw.ellipse([cx - 12, cy - 12, cx + 12, cy + 12], fill=60)
        # Inner tie pin
        h_draw.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], fill=110)

    height = periodic_filter(height, ImageFilter.GaussianBlur(radius=1.2), pad=8)
    
    # 3. Albedo generation
    base_color = hex_to_rgb("#2c2f35")
    dark_tone = hex_to_rgb("#1c1e22")
    light_fleck = hex_to_rgb("#484e56")
    
    albedo = Image.new('RGB', (size, size), base_color)
    albedo_draw = ImageDraw.Draw(albedo)
    
    # Blend aggregate tone
    albedo = ImageChops.multiply(albedo, ImageOps.colorize(macro_noise, "#9098a5", "#ffffff"))
    # Add mineral flecks
    albedo = ImageChops.screen(albedo, ImageOps.colorize(micro_noise, "#000000", "#181a1f"))
    
    # Darken formwork seams
    albedo_draw = ImageDraw.Draw(albedo)
    albedo_draw.line([(512, 0), (512, size - 1)], fill=dark_tone, width=4)
    albedo_draw.line([(0, 512), (size - 1, 512)], fill=dark_tone, width=4)
    albedo_draw.line([(0, 0), (size - 1, 0)], fill=dark_tone, width=2)
    albedo_draw.line([(0, size - 1), (size - 1, size - 1)], fill=dark_tone, width=2)
    albedo_draw.line([(0, 0), (0, size - 1)], fill=dark_tone, width=2)
    albedo_draw.line([(size - 1, 0), (size - 1, size - 1)], fill=dark_tone, width=2)
    
    # Tie rod holes in albedo
    for cx, cy in tie_positions:
        albedo_draw.ellipse([cx - 12, cy - 12, cx + 12, cy + 12], fill=dark_tone)
        albedo_draw.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], fill=base_color)

    # 4. Roughness generation
    # Concrete is high roughness ~0.82 to 0.96 (210 - 245)
    roughness = Image.new('L', (size, size), 225)
    roughness = ImageChops.add(roughness, micro_noise.point(lambda p: int(p * 0.1)))
    r_draw = ImageDraw.Draw(roughness)
    # Seams are rougher
    r_draw.line([(512, 0), (512, size - 1)], fill=250, width=4)
    r_draw.line([(0, 512), (size - 1, 512)], fill=250, width=4)
    for cx, cy in tie_positions:
        r_draw.ellipse([cx - 12, cy - 12, cx + 12, cy + 12], fill=255)

    # 5. Normal map generation
    normal = height_to_normal(height, strength=2.2)

    return albedo, roughness, normal

# ---------------------------------------------------------------------------
# 5. Metal Deck Floor / Tread Grate PBR Set
# ---------------------------------------------------------------------------

def generate_metal_deck(size: int = 1024) -> Tuple[Image.Image, Image.Image, Image.Image, Image.Image]:
    """
    Generates a full PBR set for heavy industrial diamond tread plate:
    - Albedo: Steel deck with polished diamond tread highlights.
    - Roughness: Low on tread peaks (smooth foot traffic), high in valleys.
    - Metallic: High metallic steel finish.
    - Normal: Raised diamond lugs and plate perimeter seams.
    """
    # 1. Heightmap generation with dual diagonal diamond lugs
    height = Image.new('L', (size, size), 110)
    h_draw = ImageDraw.Draw(height)
    
    cell = 64
    for gy in range(0, size, cell):
        for gx in range(0, size, cell):
            # Alternating herringbone diamond pattern
            cx = gx + cell // 2
            cy = gy + cell // 2
            is_diag_a = ((gx // cell) + (gy // cell)) % 2 == 0
            
            w_lug = 22
            h_lug = 8
            if is_diag_a:
                # Pair of 45-degree lugs
                for ox, oy in [(-8, -8), (8, 8)]:
                    lx, ly = cx + ox, cy + oy
                    poly = [
                        (lx - w_lug // 2, ly - w_lug // 2),
                        (lx + h_lug, ly - h_lug),
                        (lx + w_lug // 2, ly + w_lug // 2),
                        (lx - h_lug, ly + h_lug)
                    ]
                    h_draw.polygon(poly, fill=220)
            else:
                # Pair of -45-degree lugs
                for ox, oy in [(-8, 8), (8, -8)]:
                    lx, ly = cx + ox, cy + oy
                    poly = [
                        (lx - w_lug // 2, ly + w_lug // 2),
                        (lx - h_lug, ly - h_lug),
                        (lx + w_lug // 2, ly - w_lug // 2),
                        (lx + h_lug, ly + h_lug)
                    ]
                    h_draw.polygon(poly, fill=220)

    # Smooth the diamond lugs for rounded realistic tread profile
    height = periodic_filter(height, ImageFilter.GaussianBlur(radius=2.5), pad=8)
    h_draw = ImageDraw.Draw(height)

    # Panel perimeter seams (512x512 panel sheets)
    seam_val = 50
    h_draw.line([(512, 0), (512, size - 1)], fill=seam_val, width=5)
    h_draw.line([(0, 512), (size - 1, 512)], fill=seam_val, width=5)
    h_draw.line([(0, 0), (size - 1, 0)], fill=seam_val, width=2)
    h_draw.line([(0, size - 1), (size - 1, size - 1)], fill=seam_val, width=2)
    h_draw.line([(0, 0), (0, size - 1)], fill=seam_val, width=2)
    h_draw.line([(size - 1, 0), (size - 1, size - 1)], fill=seam_val, width=2)
    
    # 2. Albedo map
    albedo = Image.new('RGB', (size, size), hex_to_rgb("#343940"))
    # Highlight tread peaks based on height
    height_mask = ImageOps.invert(height)
    albedo_highlight = Image.new('RGB', (size, size), hex_to_rgb("#5c6572"))
    albedo = Image.composite(albedo_highlight, albedo, height)
    
    # Darken seam valleys
    a_draw = ImageDraw.Draw(albedo)
    seam_col = hex_to_rgb("#181b1f")
    a_draw.line([(512, 0), (512, size - 1)], fill=seam_col, width=5)
    a_draw.line([(0, 512), (size - 1, 512)], fill=seam_col, width=5)
    
    # Countersunk corner bolts in plate panels
    bolt_c_head = hex_to_rgb("#555d68")
    bolt_c_recess = hex_to_rgb("#111316")
    bolt_c_spec = hex_to_rgb("#9ba6b5")
    bolt_pos = [
        (32, 32), (480, 32), (32, 480), (480, 480),
        (544, 32), (992, 32), (544, 480), (992, 480),
        (32, 544), (480, 544), (32, 992), (480, 992),
        (544, 544), (992, 544), (544, 992), (992, 992),
    ]
    for bx, by in bolt_pos:
        draw_hex_bolt(a_draw, (bx, by), 5, bolt_c_head, bolt_c_recess, bolt_c_spec)

    # 3. Roughness: Treads polished (0.35 = 90), recesses rough (0.75 = 190)
    roughness = ImageOps.invert(height)
    # Remap roughness from [110..220] to [90..195]
    roughness = ImageOps.autocontrast(roughness)
    roughness = ImageOps.colorize(roughness, "#585858", "#c0c0c0")
    roughness = ImageOps.grayscale(roughness)

    # 4. Metallic: High uniform steel metallic (0.92 = 235), seams (0.70 = 180)
    metallic = Image.new('L', (size, size), 235)
    m_draw = ImageDraw.Draw(metallic)
    m_draw.line([(512, 0), (512, size - 1)], fill=175, width=5)
    m_draw.line([(0, 512), (size - 1, 512)], fill=175, width=5)

    # 5. Normal map
    normal = height_to_normal(height, strength=3.0)

    return albedo, roughness, metallic, normal

# ---------------------------------------------------------------------------
# 6. Sci-Fi Bulkhead Wall Panel PBR Set
# ---------------------------------------------------------------------------

def generate_scifi_panel(size: int = 1024) -> Tuple[Image.Image, Image.Image, Image.Image, Image.Image]:
    """
    Generates a full PBR set for a modular sci-fi armor bulkhead wall panel:
    - Upper & lower beveled composite armor plates.
    - Recessed central maintenance bay with horizontal cooling louvers.
    - Outer structural frame with countersunk hex bolts.
    - Tactical stencils: 'LONG COLT // SEC-04', caution chevrons, LED indicator dots.
    """
    # 1. Heightmap
    height = Image.new('L', (size, size), 80)
    h_draw = ImageDraw.Draw(height)

    # Outer frame
    frame_w = 28
    h_draw.rectangle([0, 0, size - 1, size - 1], fill=140)
    h_draw.rectangle([frame_w, frame_w, size - 1 - frame_w, size - 1 - frame_w], fill=90)

    # Two heavy armor plates
    chamfer = 24
    plate_gap = 48
    mid_y = size // 2

    # Upper plate
    uy0, uy1 = frame_w + 12, mid_y - plate_gap // 2
    ux0, ux1 = frame_w + 12, size - 1 - frame_w - 12
    h_draw.rectangle([ux0, uy0, ux1, uy1], fill=210)

    # Lower plate
    ly0, ly1 = mid_y + plate_gap // 2, size - 1 - frame_w - 12
    h_draw.rectangle([ux0, ly0, ux1, ly1], fill=210)

    # Recessed maintenance bay in upper plate center
    mw0, mw1 = size // 2 - 200, size // 2 + 200
    mh0, mh1 = uy0 + 40, uy1 - 40
    h_draw.rectangle([mw0, mh0, mw1, mh1], fill=120)

    # Angled cooling louvers inside maintenance bay
    louver_h = 10
    louver_gap = 18
    for ly in range(mh0 + 20, mh1 - 20, louver_gap):
        h_draw.rectangle([mw0 + 24, ly, mw1 - 24, ly + louver_h], fill=180)

    # Reinforcement ribs in lower plate
    rib_w = 28
    for rx in [size // 2 - 160, size // 2, size // 2 + 160]:
        h_draw.rectangle([rx - rib_w // 2, ly0 + 32, rx + rib_w // 2, ly1 - 32], fill=230)

    # Bevel the heightmap
    height = periodic_filter(height, ImageFilter.GaussianBlur(radius=2.0), pad=8)
    
    # 2. Albedo map
    albedo = Image.new('RGB', (size, size), hex_to_rgb("#23272e"))
    a_draw = ImageDraw.Draw(albedo)

    # Outer frame color
    a_draw.rectangle([0, 0, size - 1, size - 1], fill=hex_to_rgb("#2a2e36"))
    a_draw.rectangle([frame_w, frame_w, size - 1 - frame_w, size - 1 - frame_w], fill=hex_to_rgb("#1a1d22"))

    # Armor plates
    plate_col = hex_to_rgb("#323740")
    a_draw.rectangle([ux0, uy0, ux1, uy1], fill=plate_col)
    a_draw.rectangle([ux0, ly0, ux1, ly1], fill=plate_col)

    # Maintenance hatch
    a_draw.rectangle([mw0, mh0, mw1, mh1], fill=hex_to_rgb("#1e2127"))
    # Louver slats
    for ly in range(mh0 + 20, mh1 - 20, louver_gap):
        a_draw.rectangle([mw0 + 24, ly, mw1 - 24, ly + louver_h], fill=hex_to_rgb("#131519"))

    # Lower reinforcement ribs
    rib_col = hex_to_rgb("#3d434e")
    for rx in [size // 2 - 160, size // 2, size // 2 + 160]:
        a_draw.rectangle([rx - rib_w // 2, ly0 + 32, rx + rib_w // 2, ly1 - 32], fill=rib_col)

    # Stencil lettering & markings
    f_st_title = get_font(22, bold=True)
    f_st_sub = get_font(14, bold=False)
    stencil_col = hex_to_rgb("#8d97a5")
    
    a_draw.text((ux0 + 32, uy0 + 20), "LONG COLT // SEC-04", fill=stencil_col, font=f_st_title)
    a_draw.text((ux0 + 34, uy0 + 46), "ARMOR BULKHEAD CLASS-III", fill=hex_to_rgb("#636c7a"), font=f_st_sub)
    a_draw.text((ux0 + 32, ly0 + 20), "INSPECTION: NOMINAL", fill=stencil_col, font=f_st_title)

    # Status LEDs (Green & Amber)
    a_draw.ellipse([ux1 - 50, uy0 + 24, ux1 - 38, uy0 + 36], fill=hex_to_rgb("#00e676"))
    a_draw.ellipse([ux1 - 32, uy0 + 24, ux1 - 20, uy0 + 36], fill=hex_to_rgb("#ffab00"))

    # Corner mounting bolts along frame
    bolt_c_head = hex_to_rgb("#5a626e")
    bolt_c_recess = hex_to_rgb("#121417")
    bolt_c_spec = hex_to_rgb("#a0abb8")
    for pos_x in [14, size // 4, size // 2, 3 * size // 4, size - 15]:
        draw_hex_bolt(a_draw, (pos_x, 14), 5, bolt_c_head, bolt_c_recess, bolt_c_spec)
        draw_hex_bolt(a_draw, (pos_x, size - 15), 5, bolt_c_head, bolt_c_recess, bolt_c_spec)
    for pos_y in [size // 4, size // 2, 3 * size // 4]:
        draw_hex_bolt(a_draw, (14, pos_y), 5, bolt_c_head, bolt_c_recess, bolt_c_spec)
        draw_hex_bolt(a_draw, (size - 15, pos_y), 5, bolt_c_head, bolt_c_recess, bolt_c_spec)

    # 3. Roughness
    # Painted plates: 0.48 (122), recessed cavities: 0.78 (200)
    roughness = Image.new('L', (size, size), 190)
    r_draw = ImageDraw.Draw(roughness)
    r_draw.rectangle([ux0, uy0, ux1, uy1], fill=120)
    r_draw.rectangle([ux0, ly0, ux1, ly1], fill=120)
    r_draw.rectangle([mw0, mh0, mw1, mh1], fill=195)

    # 4. Metallic
    # Painted plates: 0.65 (165), frame & bolts: 0.90 (230), recess: 0.35 (90)
    metallic = Image.new('L', (size, size), 100)
    m_draw = ImageDraw.Draw(metallic)
    m_draw.rectangle([0, 0, size - 1, size - 1], fill=220)
    m_draw.rectangle([frame_w, frame_w, size - 1 - frame_w, size - 1 - frame_w], fill=90)
    m_draw.rectangle([ux0, uy0, ux1, uy1], fill=170)
    m_draw.rectangle([ux0, ly0, ux1, ly1], fill=170)

    # 5. Normal map
    normal = height_to_normal(height, strength=2.8)

    return albedo, roughness, metallic, normal

# ---------------------------------------------------------------------------
# 7. Sci-Fi Trim Sheet PBR Set (7 Horizontally Seamless Bands)
# ---------------------------------------------------------------------------

def generate_scifi_trim(size: int = 1024) -> Tuple[Image.Image, Image.Image, Image.Image, Image.Image, Image.Image]:
    """
    Generates a modular CC0 Sci-Fi Trim Sheet (1024x1024, horizontally seamless):
    - Band 0 (Y: 0-144): Insulated conduit / pipe runner with bracket flanges.
    - Band 1 (Y: 144-288): Bolted structural armor strip.
    - Band 2 (Y: 288-432): Warning hazard runner (45-degree yellow/black).
    - Band 3 (Y: 432-576): Heat dissipation ventilation grille.
    - Band 4 (Y: 576-720): Optical data channel with glowing cyan/amber LED strips.
    - Band 5 (Y: 720-864): Flexible cable bundle tray / wire harness.
    - Band 6 (Y: 864-1024): Heavy floor kickplate / baseboard anchor plate.
    """
    height = Image.new('L', (size, size), 100)
    h_draw = ImageDraw.Draw(height)

    # Define band boundaries
    bands = [
        (0, 144),    # Pipe
        (144, 288),  # Armor strip
        (288, 432),  # Hazard runner
        (432, 576),  # Vent grille
        (576, 720),  # Optical LED track
        (720, 864),  # Cable tray
        (864, 1024), # Kickplate
    ]

    # Deep grooves between bands
    for b_start, b_end in bands:
        h_draw.line([(0, b_start), (size - 1, b_start)], fill=30, width=4)
        h_draw.line([(0, b_end - 1), (size - 1, b_end - 1)], fill=30, width=4)

    # Band 0: Pipe (sinusoidal cylindrical height)
    for y in range(16, 128):
        norm_y = (y - 16) / (128 - 16)
        cyl_h = int(100 + 130 * math.sin(norm_y * math.pi))
        h_draw.line([(0, y), (size - 1, y)], fill=cyl_h, width=1)
    # Pipe brackets every 256px
    for bx in range(0, size, 256):
        h_draw.rectangle([bx + 116, 8, bx + 140, 136], fill=240)

    # Band 1: Armor strip
    h_draw.rectangle([0, 150, size - 1, 282], fill=190)

    # Band 2: Hazard runner rails
    h_draw.rectangle([0, 294, size - 1, 426], fill=150)
    h_draw.line([(0, 296), (size - 1, 296)], fill=230, width=4)
    h_draw.line([(0, 424), (size - 1, 424)], fill=230, width=4)

    # Band 3: Vent louvers (vertical slots every 16px)
    h_draw.rectangle([0, 438, size - 1, 570], fill=60)
    for vx in range(0, size, 16):
        h_draw.rectangle([vx + 2, 444, vx + 10, 564], fill=180)

    # Band 4: Optical channel
    h_draw.rectangle([0, 582, size - 1, 714], fill=90)
    h_draw.rectangle([0, 638, size - 1, 658], fill=220)  # Center light channel

    # Band 5: Multi-strand cables
    cable_ys = [740, 770, 804, 836]
    cable_rads = [10, 14, 12, 10]
    for cy, crad in zip(cable_ys, cable_rads):
        for y in range(cy - crad, cy + crad + 1):
            dy = (y - cy) / crad
            if abs(dy) <= 1.0:
                ch = int(90 + 90 * math.sqrt(max(0.0, 1.0 - dy * dy)))
                h_draw.line([(0, y), (size - 1, y)], fill=ch, width=1)
    # Cable tie brackets every 128px
    for tx in range(0, size, 128):
        h_draw.rectangle([tx + 56, 726, tx + 72, 858], fill=210)

    # Band 6: Heavy floor kickplate
    h_draw.rectangle([0, 870, size - 1, 1018], fill=190)
    # Beveled drainage notches along bottom edge
    for sx in range(0, size, 128):
        h_draw.polygon([(sx + 40, 1018), (sx + 52, 980), (sx + 76, 980), (sx + 88, 1018)], fill=50)

    # Smooth heightmap
    height = periodic_filter(height, ImageFilter.GaussianBlur(radius=1.5), pad=8)

    # 2. Albedo map
    albedo = Image.new('RGB', (size, size), hex_to_rgb("#1b1e23"))
    a_draw = ImageDraw.Draw(albedo)

    # Band 0: Pipe albedo (industrial olive green with bronze brackets)
    pipe_col = hex_to_rgb("#2d3832")
    a_draw.rectangle([0, 16, size - 1, 128], fill=pipe_col)
    bracket_col = hex_to_rgb("#7a6042")
    for bx in range(0, size, 256):
        a_draw.rectangle([bx + 116, 8, bx + 140, 136], fill=bracket_col)
        draw_hex_bolt(a_draw, (bx + 128, 20), 4, hex_to_rgb("#555c68"), hex_to_rgb("#1c1e22"), hex_to_rgb("#9ba6b5"))
        draw_hex_bolt(a_draw, (bx + 128, 124), 4, hex_to_rgb("#555c68"), hex_to_rgb("#1c1e22"), hex_to_rgb("#9ba6b5"))

    # Band 1: Armor strip (slate alloy with hex bolts)
    a_draw.rectangle([0, 150, size - 1, 282], fill=hex_to_rgb("#373d47"))
    for hx in range(0, size, 128):
        draw_hex_bolt(a_draw, (hx + 64, 216), 5, hex_to_rgb("#555c68"), hex_to_rgb("#1a1c20"), hex_to_rgb("#a1abb8"))

    # Band 2: Hazard stripes
    y_hz_start, y_hz_end = 294, 426
    hz_h = y_hz_end - y_hz_start
    hz_period = 64
    hz_pat = Image.new('L', (hz_period, hz_period), 0)
    for ty in range(hz_period):
        for tx in range(hz_period):
            if (tx + ty) % hz_period < (hz_period // 2):
                hz_pat.putpixel((tx, ty), 255)
    hz_mask = Image.new('L', (size, hz_h))
    for tx in range(0, size, hz_period):
        for ty in range(0, hz_h, hz_period):
            hz_mask.paste(hz_pat, (tx, ty))
    hz_yellow = Image.new('RGB', (size, hz_h), hex_to_rgb("#f1b80d"))
    hz_black = Image.new('RGB', (size, hz_h), hex_to_rgb("#1e2024"))
    hz_band = Image.new('RGB', (size, hz_h), hex_to_rgb("#1e2024"))
    hz_band.paste(hz_yellow, (0, 0), mask=hz_mask)
    albedo.paste(hz_band, (0, y_hz_start))
    a_draw = ImageDraw.Draw(albedo)
    # Retaining rails
    a_draw.line([(0, 296), (size - 1, 296)], fill=hex_to_rgb("#4a525f"), width=4)
    a_draw.line([(0, 424), (size - 1, 424)], fill=hex_to_rgb("#4a525f"), width=4)

    # Band 3: Vent grill
    a_draw.rectangle([0, 438, size - 1, 570], fill=hex_to_rgb("#101215"))
    for vx in range(0, size, 16):
        a_draw.rectangle([vx + 2, 444, vx + 10, 564], fill=hex_to_rgb("#3d434c"))

    # Band 4: Optical LED channel
    a_draw.rectangle([0, 582, size - 1, 714], fill=hex_to_rgb("#1a1d22"))
    a_draw.rectangle([0, 638, size - 1, 658], fill=hex_to_rgb("#00d4ff"))  # glowing cyan core
    # Amber indicator lamps every 256px
    for lx in range(0, size, 256):
        a_draw.ellipse([lx + 120, 600, lx + 136, 616], fill=hex_to_rgb("#ff9100"))

    # Band 5: Cables
    cable_cols = [hex_to_rgb("#18191c"), hex_to_rgb("#272b30"), hex_to_rgb("#1e2227"), hex_to_rgb("#2a2d33")]
    for cy, crad, col in zip(cable_ys, cable_rads, cable_cols):
        a_draw.rectangle([0, cy - crad, size - 1, cy + crad], fill=col)
    for tx in range(0, size, 128):
        a_draw.rectangle([tx + 56, 726, tx + 72, 858], fill=hex_to_rgb("#c24900"))  # Orange zip-ties

    # Band 6: Heavy kickplate
    a_draw.rectangle([0, 870, size - 1, 1018], fill=hex_to_rgb("#2d333b"))
    for kx in range(0, size, 128):
        draw_hex_bolt(a_draw, (kx + 64, 910), 6, hex_to_rgb("#525964"), hex_to_rgb("#15171a"), hex_to_rgb("#9aa5b2"))
    for sx in range(0, size, 128):
        a_draw.polygon([(sx + 40, 1018), (sx + 52, 980), (sx + 76, 980), (sx + 88, 1018)], fill=hex_to_rgb("#141619"))

    # 3. Roughness
    roughness = Image.new('L', (size, size), 180)
    r_draw = ImageDraw.Draw(roughness)
    r_draw.rectangle([0, 150, size - 1, 282], fill=110) # Armor strip: satin
    r_draw.rectangle([0, 638, size - 1, 658], fill=30)  # Optical strip: glossy
    r_draw.rectangle([0, 870, size - 1, 1018], fill=130) # Kickplate

    # 4. Metallic
    metallic = Image.new('L', (size, size), 40)
    m_draw = ImageDraw.Draw(metallic)
    m_draw.rectangle([0, 150, size - 1, 282], fill=230) # Armor strip: steel
    m_draw.rectangle([0, 870, size - 1, 1018], fill=220) # Kickplate: steel
    for bx in range(0, size, 256):
        m_draw.rectangle([bx + 116, 8, bx + 140, 136], fill=210) # Pipe bracket: bronze

    # 5. Normal map
    normal = height_to_normal(height, strength=2.8)

    # 6. Emission map (for the glowing cyan optical channel & amber lamps)
    emission = Image.new('RGB', (size, size), (0, 0, 0))
    e_draw = ImageDraw.Draw(emission)
    e_draw.rectangle([0, 638, size - 1, 658], fill=hex_to_rgb("#00e5ff"))
    for lx in range(0, size, 256):
        e_draw.ellipse([lx + 120, 600, lx + 136, 616], fill=hex_to_rgb("#ff9100"))

    return albedo, roughness, metallic, normal, emission

# ---------------------------------------------------------------------------
# 8. Godot StandardMaterial3D (.tres) Generator
# ---------------------------------------------------------------------------

def generate_godot_material_tres(
    material_name: str,
    albedo_tex_path: str,
    roughness_tex_path: Optional[str] = None,
    normal_tex_path: Optional[str] = None,
    metallic_tex_path: Optional[str] = None,
    emission_tex_path: Optional[str] = None,
    roughness_val: float = 0.75,
    metallic_val: float = 0.0,
    uv_scale: Tuple[float, float, float] = (1.0, 1.0, 1.0),
    emission_energy: float = 2.0,
) -> str:
    """
    Creates a text Godot 4.7 StandardMaterial3D resource (.tres) with
    uv1_triplanar = true and uv1_world_triplanar = true.
    """
    ext_resources = []
    res_lines = []
    
    ext_id = 1
    
    # Albedo
    ext_resources.append(f'[ext_resource type="Texture2D" path="{albedo_tex_path}" id="{ext_id}_albedo"]')
    res_lines.append(f'albedo_texture = ExtResource("{ext_id}_albedo")')
    ext_id += 1
    
    # Roughness
    if roughness_tex_path:
        ext_resources.append(f'[ext_resource type="Texture2D" path="{roughness_tex_path}" id="{ext_id}_rough"]')
        res_lines.append(f'roughness = 1.0')
        res_lines.append(f'roughness_texture = ExtResource("{ext_id}_rough")')
        ext_id += 1
    else:
        res_lines.append(f'roughness = {roughness_val:.2f}')
        
    # Metallic
    if metallic_tex_path:
        ext_resources.append(f'[ext_resource type="Texture2D" path="{metallic_tex_path}" id="{ext_id}_metal"]')
        res_lines.append(f'metallic = 1.0')
        res_lines.append(f'metallic_texture = ExtResource("{ext_id}_metal")')
        ext_id += 1
    elif metallic_val > 0.0:
        res_lines.append(f'metallic = {metallic_val:.2f}')
        
    # Normal
    if normal_tex_path:
        ext_resources.append(f'[ext_resource type="Texture2D" path="{normal_tex_path}" id="{ext_id}_norm"]')
        res_lines.append('normal_enabled = true')
        res_lines.append('normal_scale = 1.0')
        res_lines.append(f'normal_texture = ExtResource("{ext_id}_norm")')
        ext_id += 1
        
    # Emission
    if emission_tex_path:
        ext_resources.append(f'[ext_resource type="Texture2D" path="{emission_tex_path}" id="{ext_id}_emis"]')
        res_lines.append('emission_enabled = true')
        res_lines.append(f'emission_energy_multiplier = {emission_energy:.2f}')
        res_lines.append(f'emission_texture = ExtResource("{ext_id}_emis")')
        ext_id += 1

    # World-space triplanar configuration
    res_lines.append(f'uv1_scale = Vector3({uv_scale[0]}, {uv_scale[1]}, {uv_scale[2]})')
    res_lines.append('uv1_triplanar = true')
    res_lines.append('uv1_world_triplanar = true')
    # Filter 5 = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
    res_lines.append('texture_filter = 5')

    load_steps = len(ext_resources) + 1
    header = f'[gd_resource type="StandardMaterial3D" load_steps={load_steps} format=3]\n\n'
    ext_sec = "\n".join(ext_resources) + "\n\n" if ext_resources else ""
    res_sec = f'[resource]\nresource_name = "{material_name}"\n' + "\n".join(res_lines) + "\n"
    
    return header + ext_sec + res_sec

# ---------------------------------------------------------------------------
# 9. Main Pipeline Driver
# ---------------------------------------------------------------------------

def run_pipeline(project_root: str, verbose: bool = True) -> Dict[str, List[str]]:
    """Generates all CC0 prototype textures and Godot materials."""
    tex_proto_dir = os.path.join(project_root, "assets", "textures", "prototype")
    tex_env_dir = os.path.join(project_root, "assets", "textures", "environment")
    mat_proto_dir = os.path.join(project_root, "resources", "materials", "prototype")
    mat_env_dir = os.path.join(project_root, "resources", "materials", "environment")

    for d in [tex_proto_dir, tex_env_dir, mat_proto_dir, mat_env_dir]:
        os.makedirs(d, exist_ok=True)

    generated_textures = []
    generated_materials = []

    if verbose:
        print(">>> [Pipeline] Generating 1.0m Metric Grids...")

    # 1. Metric Grids 1m
    for pal_key, pal in PALETTES.items():
        tex_filename = f"grid_{pal_key}_1m.png"
        tex_path = os.path.join(tex_proto_dir, tex_filename)
        grid_img = generate_metric_grid_1m(pal, size=1024)
        grid_img.save(tex_path, format="PNG", optimize=True)
        generated_textures.append(tex_path)

        # Material
        mat_name = f"mat_grid_{pal_key}_1m"
        mat_filename = f"{mat_name}.tres"
        mat_path = os.path.join(mat_proto_dir, mat_filename)
        res_tex_path = f"res://assets/textures/prototype/{tex_filename}"
        tres_content = generate_godot_material_tres(
            material_name=mat_name,
            albedo_tex_path=res_tex_path,
            roughness_val=0.75,
            uv_scale=(1.0, 1.0, 1.0),
        )
        with open(mat_path, "w", encoding="utf-8") as f:
            f.write(tres_content)
        generated_materials.append(mat_path)
        if verbose:
            print(f"  + Generated {tex_filename} -> {mat_filename}")

    # 2. Metric Grids 0.5m
    if verbose:
        print(">>> [Pipeline] Generating 0.5m Metric Grids...")
    for pal_key in ["dark", "light", "orange"]:
        pal = PALETTES[pal_key]
        tex_filename = f"grid_{pal_key}_05m.png"
        tex_path = os.path.join(tex_proto_dir, tex_filename)
        grid_img = generate_metric_grid_05m(pal, size=1024)
        grid_img.save(tex_path, format="PNG", optimize=True)
        generated_textures.append(tex_path)

        mat_name = f"mat_grid_{pal_key}_05m"
        mat_filename = f"{mat_name}.tres"
        mat_path = os.path.join(mat_proto_dir, mat_filename)
        res_tex_path = f"res://assets/textures/prototype/{tex_filename}"
        tres_content = generate_godot_material_tres(
            material_name=mat_name,
            albedo_tex_path=res_tex_path,
            roughness_val=0.75,
            uv_scale=(1.0, 1.0, 1.0),
        )
        with open(mat_path, "w", encoding="utf-8") as f:
            f.write(tres_content)
        generated_materials.append(mat_path)
        if verbose:
            print(f"  + Generated {tex_filename} -> {mat_filename}")

    # 3. Hazard Stripes
    if verbose:
        print(">>> [Pipeline] Generating Hazard Stripes...")
    hazard_configs = [
        ("hazard_yellow_black", hex_to_rgb("#f1b80d"), hex_to_rgb("#1e2024")),
        ("hazard_orange_dark", hex_to_rgb("#df500e"), hex_to_rgb("#23262c")),
    ]
    for hname, col_a, col_b in hazard_configs:
        tex_filename = f"{hname}.png"
        tex_path = os.path.join(tex_proto_dir, tex_filename)
        hz_img = generate_hazard_stripes(col_a, col_b, size=1024, stripe_width=64)
        hz_img.save(tex_path, format="PNG", optimize=True)
        generated_textures.append(tex_path)

        mat_name = f"mat_{hname}"
        mat_filename = f"{mat_name}.tres"
        mat_path = os.path.join(mat_proto_dir, mat_filename)
        res_tex_path = f"res://assets/textures/prototype/{tex_filename}"
        tres_content = generate_godot_material_tres(
            material_name=mat_name,
            albedo_tex_path=res_tex_path,
            roughness_val=0.65,
            uv_scale=(1.0, 1.0, 1.0),
        )
        with open(mat_path, "w", encoding="utf-8") as f:
            f.write(tres_content)
        generated_materials.append(mat_path)
        if verbose:
            print(f"  + Generated {tex_filename} -> {mat_filename}")

    # 4. Dark Industrial Concrete PBR Set
    if verbose:
        print(">>> [Pipeline] Generating Dark Industrial Concrete PBR Set...")
    conc_albedo, conc_rough, conc_normal = generate_concrete_dark(size=1024)
    conc_files = {
        "concrete_dark_albedo.png": conc_albedo,
        "concrete_dark_roughness.png": conc_rough,
        "concrete_dark_normal.png": conc_normal,
    }
    for fname, img in conc_files.items():
        # Save in prototype
        p_path = os.path.join(tex_proto_dir, fname)
        img.save(p_path, format="PNG", optimize=True)
        generated_textures.append(p_path)
        # Also copy into environment
        e_path = os.path.join(tex_env_dir, fname)
        img.save(e_path, format="PNG", optimize=True)
        generated_textures.append(e_path)

    mat_name = "mat_concrete_dark"
    conc_tres = generate_godot_material_tres(
        material_name=mat_name,
        albedo_tex_path="res://assets/textures/prototype/concrete_dark_albedo.png",
        roughness_tex_path="res://assets/textures/prototype/concrete_dark_roughness.png",
        normal_tex_path="res://assets/textures/prototype/concrete_dark_normal.png",
        uv_scale=(1.0, 1.0, 1.0),
    )
    for target_dir in [mat_proto_dir, mat_env_dir]:
        mp = os.path.join(target_dir, f"{mat_name}.tres")
        with open(mp, "w", encoding="utf-8") as f:
            f.write(conc_tres)
        generated_materials.append(mp)
    if verbose:
        print("  + Generated concrete_dark PBR maps and materials")

    # 5. Metal Deck Floor PBR Set
    if verbose:
        print(">>> [Pipeline] Generating Metal Deck Floor PBR Set...")
    m_alb, m_rgh, m_met, m_nrm = generate_metal_deck(size=1024)
    metal_files = {
        "metal_deck_albedo.png": m_alb,
        "metal_deck_roughness.png": m_rgh,
        "metal_deck_metallic.png": m_met,
        "metal_deck_normal.png": m_nrm,
    }
    for fname, img in metal_files.items():
        p_path = os.path.join(tex_proto_dir, fname)
        img.save(p_path, format="PNG", optimize=True)
        generated_textures.append(p_path)
        e_path = os.path.join(tex_env_dir, fname)
        img.save(e_path, format="PNG", optimize=True)
        generated_textures.append(e_path)

    mat_name = "mat_metal_deck"
    metal_tres = generate_godot_material_tres(
        material_name=mat_name,
        albedo_tex_path="res://assets/textures/prototype/metal_deck_albedo.png",
        roughness_tex_path="res://assets/textures/prototype/metal_deck_roughness.png",
        metallic_tex_path="res://assets/textures/prototype/metal_deck_metallic.png",
        normal_tex_path="res://assets/textures/prototype/metal_deck_normal.png",
        uv_scale=(1.0, 1.0, 1.0),
    )
    for target_dir in [mat_proto_dir, mat_env_dir]:
        mp = os.path.join(target_dir, f"{mat_name}.tres")
        with open(mp, "w", encoding="utf-8") as f:
            f.write(metal_tres)
        generated_materials.append(mp)
    if verbose:
        print("  + Generated metal_deck PBR maps and materials")

    # 6. Sci-Fi Bulkhead Wall Panel PBR Set
    if verbose:
        print(">>> [Pipeline] Generating Sci-Fi Bulkhead Wall Panel PBR Set...")
    p_alb, p_rgh, p_met, p_nrm = generate_scifi_panel(size=1024)
    panel_files = {
        "scifi_panel_albedo.png": p_alb,
        "scifi_panel_roughness.png": p_rgh,
        "scifi_panel_metallic.png": p_met,
        "scifi_panel_normal.png": p_nrm,
    }
    for fname, img in panel_files.items():
        p_path = os.path.join(tex_proto_dir, fname)
        img.save(p_path, format="PNG", optimize=True)
        generated_textures.append(p_path)
        e_path = os.path.join(tex_env_dir, fname)
        img.save(e_path, format="PNG", optimize=True)
        generated_textures.append(e_path)

    mat_name = "mat_scifi_panel"
    panel_tres = generate_godot_material_tres(
        material_name=mat_name,
        albedo_tex_path="res://assets/textures/prototype/scifi_panel_albedo.png",
        roughness_tex_path="res://assets/textures/prototype/scifi_panel_roughness.png",
        metallic_tex_path="res://assets/textures/prototype/scifi_panel_metallic.png",
        normal_tex_path="res://assets/textures/prototype/scifi_panel_normal.png",
        uv_scale=(1.0, 1.0, 1.0),
    )
    for target_dir in [mat_proto_dir, mat_env_dir]:
        mp = os.path.join(target_dir, f"{mat_name}.tres")
        with open(mp, "w", encoding="utf-8") as f:
            f.write(panel_tres)
        generated_materials.append(mp)
    if verbose:
        print("  + Generated scifi_panel PBR maps and materials")

    # 7. Sci-Fi Trim Sheet PBR Set
    if verbose:
        print(">>> [Pipeline] Generating Sci-Fi Trim Sheet PBR Set...")
    t_alb, t_rgh, t_met, t_nrm, t_ems = generate_scifi_trim(size=1024)
    trim_files = {
        "scifi_trim_albedo.png": t_alb,
        "scifi_trim_roughness.png": t_rgh,
        "scifi_trim_metallic.png": t_met,
        "scifi_trim_normal.png": t_nrm,
        "scifi_trim_emission.png": t_ems,
    }
    for fname, img in trim_files.items():
        p_path = os.path.join(tex_proto_dir, fname)
        img.save(p_path, format="PNG", optimize=True)
        generated_textures.append(p_path)
        e_path = os.path.join(tex_env_dir, fname)
        img.save(e_path, format="PNG", optimize=True)
        generated_textures.append(e_path)

    mat_name = "mat_scifi_trim"
    trim_tres = generate_godot_material_tres(
        material_name=mat_name,
        albedo_tex_path="res://assets/textures/prototype/scifi_trim_albedo.png",
        roughness_tex_path="res://assets/textures/prototype/scifi_trim_roughness.png",
        metallic_tex_path="res://assets/textures/prototype/scifi_trim_metallic.png",
        normal_tex_path="res://assets/textures/prototype/scifi_trim_normal.png",
        emission_tex_path="res://assets/textures/prototype/scifi_trim_emission.png",
        emission_energy=2.5,
        uv_scale=(1.0, 1.0, 1.0),
    )
    for target_dir in [mat_proto_dir, mat_env_dir]:
        mp = os.path.join(target_dir, f"{mat_name}.tres")
        with open(mp, "w", encoding="utf-8") as f:
            f.write(trim_tres)
        generated_materials.append(mp)
    if verbose:
        print("  + Generated scifi_trim PBR maps and materials")

    if verbose:
        print(">>> [Pipeline] Completed successfully!")
        print(f"    Total textures written: {len(generated_textures)}")
        print(f"    Total materials written: {len(generated_materials)}")

    return {
        "textures": generated_textures,
        "materials": generated_materials,
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Project Long Colt — Prototype Texture & Material Pipeline")
    parser.add_argument("--project-root", default=None, help="Root path of the Godot project")
    args = parser.parse_args()

    if args.project_root:
        root_dir = args.project_root
    else:
        # Default to detected project directory
        script_dir = os.path.dirname(os.path.abspath(__file__))
        root_dir = os.path.abspath(os.path.join(script_dir, "..", ".."))

    print(f"Targeting Godot Project at: {root_dir}")
    run_pipeline(root_dir)
