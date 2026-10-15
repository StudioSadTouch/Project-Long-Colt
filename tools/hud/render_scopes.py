#!/usr/bin/env python3
# Run: python3 tools/hud/render_scopes.py <out_dir>  (needs Pillow; the Open Sans path is box-specific)
"""Preview port of scripts/ui/scope_overlay.gd (_draw) to PIL. Same geometry, same constants,
unit u = H/1080. Supersampled 2x for AA. Background is a procedural, blurred neutral scene
(board palette) with a 1.8 m figure at 50 m so the ranging reads can be checked by eye."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1] if len(sys.argv) > 1 else "/workspace/hud"
FONT = "/usr/share/fonts/truetype/sand-box/google/Open Sans/OpenSans-VariableFont_wdth,wght.ttf"
SS = 2
TAU = math.tau

def C(r, g, b, a=1.0): return (r, g, b, a)
MASK = C(0.043, 0.059, 0.078); BEZEL = C(0.114, 0.149, 0.188); BEZEL_EDGE = C(0.243, 0.298, 0.353)
BEZEL_LIP = C(0.431, 0.506, 0.569); LINE = C(0.875, 0.902, 0.918, 0.95); SHADOW = C(0, 0, 0, 0.5)
AMBER = C(0.878, 0.627, 0.251, 0.95); AMBER_DIM = C(0.769, 0.478, 0.173, 0.8)
GLASS_TINT = C(0.35, 0.78, 1.0, 0.04); SCANLINE = C(0, 0, 0, 0.045)
TEXT_SIZE, TEXT_SIZE_SMALL = 26.0, 18.0
TH, TW = 1.8, 0.7
RIFLE_RANGES = [20.0, 40.0, 60.0]; MARKSMAN_RANGES = [25.0, 50.0, 75.0, 100.0]
BASE_FOV = 75.0

def zoom_fov(mag): return math.degrees(2 * math.atan(math.tan(math.radians(BASE_FOV / 2)) / mag))
def fa(o, c, a): return (c[0] + math.cos(a) * o, c[1] + math.sin(a) * o)

class Canvas:
    """Flat-colour layers composited in draw order; consecutive same-colour ops share a layer."""
    def __init__(self, bg, h):
        self.img = bg.convert("RGBA").resize((bg.width * SS, bg.height * SS), Image.LANCZOS)
        self.W, self.H = bg.width, bg.height
        self.u = h / 1080.0
        self.cur = None; self.layer = None; self.d = None
        self.fonts = {}
    def _use(self, col):
        if col != self.cur:
            self.flush(); self.cur = col
            self.layer = Image.new("L", self.img.size, 0); self.d = ImageDraw.Draw(self.layer)
        return self.d
    def flush(self):
        if self.cur is None: return
        r, g, b, a = self.cur
        solid = Image.new("RGBA", self.img.size, (int(r*255), int(g*255), int(b*255), 255))
        alpha = self.layer.point(lambda v: int(v * a))
        solid.putalpha(alpha)
        self.img = Image.alpha_composite(self.img, solid); self.cur = None
    def S(self, p): return (p[0] * SS, p[1] * SS)
    def w(self, px): return max(1.0, px * self.u)
    def polygon(self, pts, col): self._use(col).polygon([self.S(p) for p in pts], fill=255)
    def line(self, a, b, col, width):  # raw Godot draw_line
        self._use(col).line([self.S(a), self.S(b)], fill=255, width=max(1, round(width * SS)))
    def polyline(self, pts, col, width):
        d = self._use(col); wd = max(1, round(width * SS))
        d.line([self.S(p) for p in pts], fill=255, width=wd, joint="curve")
    def arc(self, c, r, a0, a1, col, width):
        n = max(8, int(abs(a1 - a0) / TAU * 96))
        pts = [fa(r, c, a0 + (a1 - a0) * i / n) for i in range(n + 1)]
        self._use(col).line([self.S(p) for p in pts], fill=255, width=max(1, round(width * SS)), joint="curve")
    def rect(self, x, y, w, h, col): self._use(col).rectangle([x*SS, y*SS, (x+w)*SS - 1, (y+h)*SS - 1], fill=255)
    def font(self, fs):
        if fs not in self.fonts:
            f = ImageFont.truetype(FONT, fs * SS)
            try: f.set_variation_by_name("SemiBold")
            except Exception: pass
            self.fonts[fs] = f
        return self.fonts[fs]
    def string(self, pos, text, fs, col):
        self._use(col).text(self.S(pos), text, font=self.font(fs), fill=255, anchor="ls")
    def finish(self):
        self.flush()
        return self.img.resize((self.W, self.H), Image.LANCZOS).convert("RGB")

class Overlay:
    def __init__(self, cv, view_fov, mag, mode_text):
        self.cv = cv; self.u = cv.u; self.size = (cv.W, cv.H)
        self.view_fov = view_fov; self.mag = mag; self.mode_text = mode_text
    def px_per_mil(self):
        return 0.001 / math.tan(math.radians(self.view_fov) / 2) * self.size[1] * 0.5
    def px_for(self, m, d): return m / d * 1000 * self.px_per_mil()
    def W(self, px): return max(1.0, px * self.u)
    # helpers mirroring the GDScript
    def _line(self, a, b, col, width):
        self.cv.line(a, b, SHADOW, self.W(width) + self.W(2)); self.cv.line(a, b, col, self.W(width))
    def _arc(self, c, r, a0, a1, col, width):
        self.cv.arc(c, r, a0, a1, SHADOW, self.W(width) + self.W(2)); self.cv.arc(c, r, a0, a1, col, self.W(width))
    def _dot(self, c, half, col):
        u = self.u; h = max(1.0, half * u)
        self.cv.rect(c[0] - h - u, c[1] - h - u, (h + u) * 2, (h + u) * 2, SHADOW)
        self.cv.rect(c[0] - h, c[1] - h, h * 2, h * 2, col)
    def _text(self, text, center, ref, col):
        fs = max(8, int(round(ref * self.u)))
        f = self.cv.font(fs); width = f.getlength(text) / SS
        pos = (center[0] - width / 2, center[1] + fs * 0.35)
        self.cv.string((pos[0] + 1.5 * self.u, pos[1] + 1.5 * self.u), text, fs, SHADOW)
        self.cv.string(pos, text, fs, col)
    def circle_pts(self, c, r, n=96): return [fa(r, c, TAU * i / n) for i in range(n)]
    def pill_pts(self, c, hw, hh, n=32):
        off = max(hw - hh, 0); pts = []
        for i in range(n + 1): pts.append(fa(hh, (c[0] + off, c[1]), -math.pi / 2 + math.pi * i / n))
        for i in range(n + 1): pts.append(fa(hh, (c[0] - off, c[1]), math.pi / 2 + math.pi * i / n))
        return pts
    def mask(self, c, pts, alpha):
        far = math.hypot(*self.size) + 16; col = MASK[:3] + (alpha,)
        for i in range(len(pts)):
            a = pts[i]; b = pts[(i + 1) % len(pts)]
            def F(p):
                dx, dy = p[0] - c[0], p[1] - c[1]; l = math.hypot(dx, dy)
                return (c[0] + dx / l * far, c[1] + dy / l * far)
            self.cv.polygon([a, b, F(b), F(a)], col)
    def glass(self, pts): self.cv.polygon(pts, GLASS_TINT)
    def bezel(self, pts, width):
        closed = pts + [pts[0]]
        self.cv.polyline(closed, BEZEL, self.W(width)); self.cv.polyline(closed, BEZEL_EDGE, self.W(width * 0.3))
        self.cv.polyline(closed, BEZEL_LIP, self.W(1))
    def tab(self, center, out, length, depth):
        u = self.u; t = (-out[1] * length * 0.5 * u, out[0] * length * 0.5 * u)
        n = (out[0] * depth * 0.5 * u, out[1] * depth * 0.5 * u)
        q = [(center[0]-t[0]-n[0], center[1]-t[1]-n[1]), (center[0]+t[0]-n[0], center[1]+t[1]-n[1]),
             (center[0]+t[0]+n[0], center[1]+t[1]+n[1]), (center[0]-t[0]+n[0], center[1]-t[1]+n[1])]
        self.cv.polygon(q, BEZEL); self.cv.polyline(q + [q[0]], BEZEL_EDGE, self.W(2))
    def scanlines(self, c, r):
        sp = max(3.0, 4.0 * self.u); y = -r + sp
        while y < r:
            h = math.sqrt(r * r - y * y)
            self.cv.line((c[0] - h, c[1] + y), (c[0] + h, c[1] + y), SCANLINE, self.W(1)); y += sp
    def mag_text(self): return "%.1fx" % self.mag
    def P(self, c, x, y): return (c[0] + x * self.u, c[1] + y * self.u)

    def sidearm(self, c):
        u = self.u; r = 300 * u; pts = self.circle_pts(c, r)
        self.glass(pts); self.mask(c, pts, 0.94); self.bezel(pts, 16)
        for i in range(4):
            a = TAU * i / 4; d = (math.cos(a), math.sin(a))
            self.tab((c[0] + d[0] * (r + 8 * u), c[1] + d[1] * (r + 8 * u)), d, 44, 16)
        for i in range(4):
            a = TAU * i / 4 + TAU / 8; self._arc(c, 34 * u, a - 0.5, a + 0.5, LINE, 3)
        for i in range(4):
            a = TAU * i / 4; self._line(fa(50 * u, c, a), fa(96 * u, c, a), LINE, 5)
        self._dot(c, 3, LINE)
        self._text(self.mag_text(), (c[0], c[1] + r - 34 * u), TEXT_SIZE, AMBER)

    def service_rifle(self, c):
        u = self.u; hh = 330 * u; hw = min(650 * u, self.size[0] * 0.47)
        pts = self.pill_pts(c, hw, hh)
        self.glass(pts); self.mask(c, pts, 0.95); self.bezel(pts, 14)
        self.tab((c[0], c[1] - hh - 6 * u), (0, -1), 120, 14); self.tab((c[0], c[1] + hh + 6 * u), (0, 1), 120, 14)
        P = self.P
        self._line(P(c, -140, 0), P(c, -20, 0), LINE, 3); self._line(P(c, 20, 0), P(c, 140, 0), LINE, 3)
        self._line(P(c, -260, 0), P(c, -170, 0), LINE, 6); self._line(P(c, 170, 0), P(c, 260, 0), LINE, 6)
        self._line(P(c, 0, 20), P(c, 0, 64), LINE, 3); self._dot(c, 2.5, LINE)
        y = c[1] + 100 * u
        for i, rng in enumerate(RIFLE_RANGES):
            hw2 = self.px_for(TW, rng) * 0.5; ry = y + 34 * u * i
            self._line((c[0] - hw2, ry), (c[0] + hw2, ry), AMBER, 2.5)
            self._line((c[0] - hw2, ry - 6 * u), (c[0] - hw2, ry), AMBER, 2.5)
            self._line((c[0] + hw2, ry - 6 * u), (c[0] + hw2, ry), AMBER, 2.5)
            self._text(str(int(rng)), (c[0] + max(hw2, 20 * u) + 22 * u, ry + 6 * u), TEXT_SIZE_SMALL, AMBER_DIM)
        ex = max(hw - hh, 120 * u)
        self._text(self.mag_text(), (c[0] + ex, c[1] + hh - 44 * u), TEXT_SIZE, AMBER)
        if self.mode_text:
            self._text(self.mode_text, (c[0] - ex, c[1] + hh - 44 * u), TEXT_SIZE_SMALL, AMBER_DIM)

    def marksman(self, c):
        u = self.u; r = 470 * u; pts = self.circle_pts(c, r)
        self.glass(pts); self.scanlines(c, r); self.mask(c, pts, 0.97); self.bezel(pts, 20)
        for i in range(4):
            a = TAU * i / 4; d = (math.cos(a), math.sin(a)); n = (-d[1], d[0])
            tip = fa(r - 26 * u, c, a); base = fa(r + 2 * u, c, a)
            self.cv.polygon([tip, (base[0] + n[0] * 14 * u, base[1] + n[1] * 14 * u),
                             (base[0] - n[0] * 14 * u, base[1] - n[1] * 14 * u)], BEZEL_EDGE)
        inner = r * 0.36
        for i in range(4):
            a = TAU * i / 4
            self._line(fa(inner, c, a), fa(r - 4 * u, c, a), LINE, 7)
            self._line(fa(8 * u, c, a), fa(inner, c, a), LINE, 1.5)
        self._dot(c, 2, LINE)
        mil = self.px_per_mil()
        step_m = next((m for m in (1, 2, 5, 10, 20, 50) if m * mil >= 12 * u), 50)
        tick = step_m * mil
        if tick > 0:
            for k in range(1, int(inner / tick) + 1):
                major = k % 5 == 0; half = (8 if major else 4) * u; o = k * tick
                for s in (-1, 1):
                    sx = s * o
                    self._line((c[0] + sx, c[1] - half), (c[0] + sx, c[1] + half), LINE, 1.5)
                    self._line((c[0] - half, c[1] + sx), (c[0] + half, c[1] + sx), LINE, 1.5)
                if major: self._text(str(k * step_m), (c[0] + o, c[1] + 28 * u), TEXT_SIZE_SMALL, AMBER_DIM)
        base_y = c[1] + r * 0.5; x = c[0] - r * 0.62; step = 34 * u
        self._line((x - 14 * u, base_y), (x + step * 3 + 14 * u, base_y), AMBER, 2.5)
        for i, rng in enumerate(MARKSMAN_RANGES):
            h = self.px_for(TH, rng); px = x + step * i
            self._line((px, base_y), (px, base_y - h), AMBER, 3)
            self._line((px - 6 * u, base_y - h), (px + 6 * u, base_y - h), AMBER, 2.5)
            self._text(str(int(rng)), (px, base_y + 24 * u), TEXT_SIZE_SMALL, AMBER_DIM)
        self._text("MIL", (c[0] + inner + 30 * u, c[1] - 14 * u), TEXT_SIZE_SMALL, AMBER_DIM)
        self._text(self.mag_text(), (c[0] + r * 0.55, c[1] + r * 0.55), TEXT_SIZE, AMBER)

    def field(self, c):
        u = self.u; hw = min(540 * u, self.size[0] * 0.46); hh = 380 * u; ch = 130 * u
        X, Y = c
        pts = [(X-hw+ch, Y-hh), (X+hw-ch, Y-hh), (X+hw, Y-hh+ch), (X+hw, Y+hh-ch), (X+hw-ch, Y+hh),
               (X-hw+ch, Y+hh), (X-hw, Y+hh-ch), (X-hw, Y-hh+ch)]
        self.glass(pts)
        sub = []
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            steps = 8 if math.dist(a, b) > 60 * u else 1
            for k in range(steps): sub.append((a[0] + (b[0]-a[0]) * k / steps, a[1] + (b[1]-a[1]) * k / steps))
        self.mask(c, sub, 0.95); self.bezel(pts, 14)
        P = self.P
        self._line(P(c, -120, 0), P(c, -18, 0), LINE, 3); self._line(P(c, 18, 0), P(c, 120, 0), LINE, 3)
        self._line(P(c, 0, 18), P(c, 0, 150), LINE, 6); self._arc(c, 10 * u, 0, TAU, LINE, 2)
        self._text(self.mag_text(), (c[0], c[1] + hh - 40 * u), TEXT_SIZE, AMBER)

def hexc(h): h = h.lstrip("#"); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def background(W, H, view_fov):
    """Neutral blurred Lockout-ish scene, then a sharp-ish 1.8 m figure at 50 m at centre."""
    img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
    top, hor = hexc("#a9b8c4"), hexc("#dfe6ea")
    hy = int(H * 0.52)
    for y in range(H):
        if y < hy:
            t = y / hy; col = tuple(int(top[i] + (hor[i] - top[i]) * t) for i in range(3))
        else:
            t = (y - hy) / (H - hy); a, b = hexc("#6e8191"), hexc("#3e4c5a")
            col = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=col)
    k = H / 1080
    for x0, w, h, c in [(0.05, 0.16, 0.30, "#3e4c5a"), (0.24, 0.10, 0.18, "#1d2630"), (0.62, 0.20, 0.26, "#3e4c5a"),
                        (0.84, 0.14, 0.40, "#1d2630"), (0.40, 0.05, 0.10, "#6e8191")]:
        d.rectangle([x0 * W, hy - h * H, (x0 + w) * W, hy + 0.02 * H], fill=hexc(c))
    for x in (0.30, 0.70, 0.90):
        d.ellipse([x * W - 40 * k, hy - 0.22 * H - 40 * k, x * W + 40 * k, hy - 0.22 * H + 40 * k], fill=hexc("#e0a040"))
    img = img.filter(ImageFilter.GaussianBlur(14 * k))
    # Target: 1.8 m at 50 m, standing on the horizon line just right of centre.
    ppm = 0.001 / math.tan(math.radians(view_fov) / 2) * H * 0.5
    th = 1.8 / 50 * 1000 * ppm; tw = 0.7 / 50 * 1000 * ppm
    fig = Image.new("RGBA", (W, H), (0, 0, 0, 0)); fd = ImageDraw.Draw(fig)
    cx = W * 0.5 + 0.12 * H; base = H * 0.5 + th * 0.45
    col = hexc("#1d2630") + (255,)
    fd.rectangle([cx - tw / 2, base - th * 0.82, cx + tw / 2, base - th * 0.38], fill=col)
    fd.rectangle([cx - tw * 0.32, base - th * 0.40, cx + tw * 0.32, base], fill=col)
    fd.ellipse([cx - tw * 0.24, base - th, cx + tw * 0.24, base - th * 0.80], fill=col)
    fd.rectangle([cx - tw * 0.18, base - th * 0.93, cx + tw * 0.18, base - th * 0.88], fill=hexc("#c47a2c") + (255,))
    fig = fig.filter(ImageFilter.GaussianBlur(1.2 * k))
    return Image.alpha_composite(img.convert("RGBA"), fig).convert("RGB")

STYLES = [  # name, magnification, mode text
    ("sidearm", 2.0, "SEMI"), ("service_rifle", 1.8, "BURST"), ("marksman", 2.5, "SEMI"), ("field", 2.0, "")]

def render(style, mag, mode, W, H):
    vf = zoom_fov(mag)
    cv = Canvas(background(W, H, vf), H)
    ov = Overlay(cv, vf, mag, mode)
    getattr(ov, style)((W / 2, H / 2))
    return cv.finish()

if __name__ == "__main__":
    import os
    os.makedirs(OUT, exist_ok=True)
    tiles = []
    for name, mag, mode in STYLES:
        for W, H in ((1920, 1080), (1280, 720)):
            im = render(name, mag, mode, W, H)
            p = f"{OUT}/scope_{name}_{W}x{H}.png"; im.save(p); print(p)
            if W == 1920: tiles.append((name, mag, im))
    tw, th = 960, 540; pad = 40
    sheet = Image.new("RGB", (tw * 2 + pad * 3, (th + pad) * 2 + pad), hexc("#1d2630"))
    sd = ImageDraw.Draw(sheet); f = ImageFont.truetype(FONT, 26)
    for i, (name, mag, im) in enumerate(tiles):
        x = pad + (i % 2) * (tw + pad); y = pad + (i // 2) * (th + pad)
        sheet.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
        sd.text((x, y + th + 4), f"{name.upper()}  {mag:.1f}x", font=f, fill=hexc("#e0a040"))
    p = f"{OUT}/scope_contact_sheet.png"; sheet.save(p); print(p)
