#!/usr/bin/env python3
# Run: python3 tools/hud/render_scopes.py <out_dir>  (needs Pillow; the Open Sans path is box-specific)
"""Preview port of scripts/ui/scope_overlay.gd (_draw) to PIL. Same geometry, same constants,
unit u = H/1080. Supersampled 2x for AA. Background is a procedural, blurred neutral scene
(board palette) with a 1.8 m figure at 50 m so the ranging reads can be checked by eye."""
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1] if len(sys.argv) > 1 else "/workspace/hud"
FONT = "/usr/share/fonts/truetype/sand-box/google/Open Sans/OpenSans-VariableFont_wdth,wght.ttf"
SS = 2
TAU = math.tau

MASK = (0.043, 0.059, 0.078, 1.0); BEZEL = (0.114, 0.149, 0.188, 1.0)
BEZEL_EDGE = (0.243, 0.298, 0.353, 1.0); BEZEL_LIP = (0.431, 0.506, 0.569, 1.0)
PLATE = (0.075, 0.098, 0.125, 0.94); LINE = (0.875, 0.902, 0.918, 0.97)
OUTLINE = (0.02, 0.027, 0.035, 0.72); AMBER = (0.878, 0.627, 0.251, 1.0)
AMBER_DIM = (0.82, 0.53, 0.2, 0.95); GLASS_TINT = (0.35, 0.78, 1.0, 0.04)
RIM_SHADE = (0.02, 0.03, 0.04, 0.035); RIM_BANDS = 8; SCANLINE = (0, 0, 0, 0.045)
TEXT_MAG, TEXT_MODE, TEXT_RANGE = 26.0, 22.0, 18.0
RETICLE_MIN_PX, HALO_PX = 2.0, 1.5
TH = 1.8
RIFLE_RANGES = [20.0, 40.0]; MARKSMAN_RANGES = [25.0, 50.0, 75.0]
MIL_STEPS = [1, 2, 5, 10, 20, 50]; MIL_TICK_MIN_PX = 14.0
BASE_FOV = 75.0

def zoom_fov(mag): return math.degrees(2 * math.atan(math.tan(math.radians(BASE_FOV / 2)) / mag))
def V(x, y): return (x, y)
def add(a, b): return (a[0] + b[0], a[1] + b[1])
def sub(a, b): return (a[0] - b[0], a[1] - b[1])
def mul(a, k): return (a[0] * k, a[1] * k)
def norm(a):
    l = math.hypot(*a); return (a[0] / l, a[1] / l) if l > 1e-9 else (0.0, 0.0)
def dot(a, b): return a[0] * b[0] + a[1] * b[1]
def ortho(a): return (a[1], -a[0])  # Godot Vector2.orthogonal()
def from_angle(a): return (math.cos(a), math.sin(a))

class Canvas:
    """Flat-colour layers composited in draw order; consecutive same-colour ops share a layer."""
    def __init__(self, bg):
        self.img = bg.convert("RGBA").resize((bg.width * SS, bg.height * SS), Image.LANCZOS)
        self.W, self.H = bg.width, bg.height
        self.cur = None; self.fonts = {}
    def _use(self, col):
        if col != self.cur:
            self.flush(); self.cur = col
            self.layer = Image.new("L", self.img.size, 0); self.d = ImageDraw.Draw(self.layer)
        return self.d
    def flush(self):
        if self.cur is None: return
        r, g, b, a = self.cur
        solid = Image.new("RGBA", self.img.size, (int(r * 255), int(g * 255), int(b * 255), 255))
        solid.putalpha(self.layer.point(lambda v: int(v * a)))
        self.img = Image.alpha_composite(self.img, solid); self.cur = None
    @staticmethod
    def S(p): return (p[0] * SS, p[1] * SS)
    def polygon(self, pts, col): self._use(col).polygon([self.S(p) for p in pts], fill=255)
    def line(self, a, b, col, width):
        self._use(col).line([self.S(a), self.S(b)], fill=255, width=max(1, round(width * SS)))
    def polyline(self, pts, col, width):
        self._use(col).line([self.S(p) for p in pts], fill=255, width=max(1, round(width * SS)), joint="curve")
    def arc(self, c, r, a0, a1, n, col, width):
        pts = [add(c, mul(from_angle(a0 + (a1 - a0) * i / n), r)) for i in range(n + 1)]
        self.polyline(pts, col, width)
    def rect(self, x, y, w, h, col, filled=True, width=1.0):
        box = [x * SS, y * SS, (x + w) * SS - 1, (y + h) * SS - 1]
        if filled: self._use(col).rectangle(box, fill=255)
        else: self._use(col).rectangle(box, outline=255, width=max(1, round(width * SS)))
    def font(self, fs):
        if fs not in self.fonts:
            f = ImageFont.truetype(FONT, fs * SS)
            try: f.set_variation_by_name("SemiBold")
            except Exception: pass
            self.fonts[fs] = f
        return self.fonts[fs]
    def string(self, pos, text, fs, col, outline=0):
        self._use(col).text(self.S(pos), text, font=self.font(fs), fill=255, anchor="ls",
                            stroke_width=round(outline * 0.5 * SS), stroke_fill=255)
    def finish(self):
        self.flush()
        return self.img.resize((self.W, self.H), Image.LANCZOS).convert("RGB")

class Overlay:
    def __init__(self, cv, view_fov, mag, mode_text):
        self.cv = cv; self.size = (cv.W, cv.H); self.u = cv.H / 1080.0
        self.view_fov = view_fov; self.mag = mag; self.mode_text = mode_text
    def px_per_mil(self): return 0.001 / math.tan(math.radians(self.view_fov) / 2) * self.size[1] * 0.5
    def px_for(self, m, d): return m / d * 1000 * self.px_per_mil()
    def w(self, px): return max(1.0, px * self.u)
    def rw(self, px): return max(RETICLE_MIN_PX, px * self.u)
    def halo(self): return max(1.0, HALO_PX * self.u)
    def mag_text(self): return "%.1fx" % self.mag
    def P(self, c, x, y): return (c[0] + x * self.u, c[1] + y * self.u)
    # reticle helpers
    def _line(self, a, b, col, width):
        w, h = self.rw(width), self.halo(); d = norm(sub(b, a))
        self.cv.line(sub(a, mul(d, h)), add(b, mul(d, h)), OUTLINE, w + h * 2); self.cv.line(a, b, col, w)
    def _arc(self, c, r, a0, a1, col, width):
        w, h = self.rw(width), self.halo(); n = max(8, int(abs(a1 - a0) / TAU * 96))
        pad = 0.0 if abs(a1 - a0) >= TAU else h / max(r, 1)
        self.cv.arc(c, r, a0 - pad, a1 + pad, n, OUTLINE, w + h * 2); self.cv.arc(c, r, a0, a1, n, col, w)
    def _dot(self, c, half, col):
        s = max(RETICLE_MIN_PX * 0.5, half * self.u); h = self.halo()
        self.cv.rect(c[0] - s - h, c[1] - s - h, (s + h) * 2, (s + h) * 2, OUTLINE)
        self.cv.rect(c[0] - s, c[1] - s, s * 2, s * 2, col)
    def font_px(self, ref): return max(10, int(round(ref * self.u)))
    def text_w(self, text, fs): return self.cv.font(fs).getlength(text) / SS
    def _text(self, text, center, ref, col):
        fs = self.font_px(ref); width = self.text_w(text, fs)
        pos = (center[0] - width * 0.5, center[1] + fs * 0.36)
        ol = max(2, int(round(4 * self.u)))
        self.cv.string(pos, text, fs, OUTLINE, ol); self.cv.string(pos, text, fs, col)
    def _plate(self, text, center, ref, col):
        fs = self.font_px(ref); width = self.text_w(text, fs)
        pw, ph = width + 26 * self.u, fs * 1.35
        x, y = center[0] - pw / 2, center[1] - ph / 2
        self.cv.rect(x, y, pw, ph, PLATE); self.cv.rect(x, y, pw, ph, BEZEL_EDGE, False, self.w(2))
        lip = self.w(1.5)
        self.cv.line((x + lip * 2, y + lip * 1.5), (x + pw - lip * 2, y + lip * 1.5), BEZEL_LIP, lip)
        self._text(text, center, ref, col)
    # shapes
    def circle_pts(self, c, r, n=96): return [add(c, mul(from_angle(TAU * i / n), r)) for i in range(n)]
    def subdivide(self, pts, parts):
        out = []
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            steps = parts if math.dist(a, b) > 60 * self.u else 1
            for k in range(steps): out.append((a[0] + (b[0] - a[0]) * k / steps, a[1] + (b[1] - a[1]) * k / steps))
        return out
    def pill_pts(self, c, hw, hh, n=32):
        off = max(hw - hh, 0); pts = []
        for i in range(n + 1): pts.append(add((c[0] + off, c[1]), mul(from_angle(-math.pi / 2 + math.pi * i / n), hh)))
        for i in range(n + 1): pts.append(add((c[0] - off, c[1]), mul(from_angle(math.pi / 2 + math.pi * i / n), hh)))
        return self.subdivide(pts, 6)
    @staticmethod
    def edge_normal(c, a, b):
        e = norm(ortho(sub(b, a)))
        mid = mul(add(a, b), 0.5)
        return mul(e, -1) if dot(e, sub(mid, c)) < 0 else e
    def offset(self, c, pts, d):
        out = []; n = len(pts)
        for i in range(n):
            p = pts[i]
            n1 = self.edge_normal(c, pts[(i + n - 1) % n], p); n2 = self.edge_normal(c, p, pts[(i + 1) % n])
            m = norm(add(n1, n2))
            if m == (0.0, 0.0): m = norm(sub(p, c))
            k = max(dot(m, n1 if n1 != (0.0, 0.0) else m), 0.3)
            out.append(add(p, mul(m, d / k)))
        return out
    def ring(self, inner, outer, col):
        n = len(inner)
        for i in range(n):
            j = (i + 1) % n; self.cv.polygon([inner[i], inner[j], outer[j], outer[i]], col)
    def mask(self, c, pts, alpha):
        far = math.hypot(*self.size) + 16; col = MASK[:3] + (alpha,)
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            self.cv.polygon([a, b, add(c, mul(norm(sub(b, c)), far)), add(c, mul(norm(sub(a, c)), far))], col)
    def glass(self, c, pts, rim_depth):
        self.cv.polygon(pts, GLASS_TINT)
        for k in range(RIM_BANDS):
            self.cv.flush()  # bands stack (Godot draws them one after another)
            self.ring(self.offset(c, pts, -rim_depth * self.u * (k + 1) / RIM_BANDS), pts, RIM_SHADE)
        self.cv.flush()
    def bezel(self, c, pts, width):
        u = self.u; outer = self.offset(c, pts, width * u); chamfer = self.offset(c, pts, width * 0.3 * u)
        self.ring(pts, outer, BEZEL); self.ring(pts, chamfer, BEZEL_EDGE)
        lip = self.offset(c, pts, self.w(1)); self.cv.polyline(lip + [lip[0]], BEZEL_LIP, self.w(2))
        self.cv.polyline(outer + [outer[0]], BEZEL_EDGE, self.w(2))
    def tab(self, center, out, length, depth):
        u = self.u; t = mul(ortho(out), length * 0.5 * u); n = mul(out, depth * 0.5 * u)
        q = [sub(sub(center, t), n), sub(add(center, t), n), add(add(center, t), n), add(sub(center, t), n)]
        self.cv.polygon(q, BEZEL); self.cv.polyline(q + [q[0]], BEZEL_EDGE, self.w(3))
        inset = mul(out, self.w(4))
        a = sub(add(sub(center, mul(t, 0.85)), n), inset); b = sub(add(add(center, mul(t, 0.85)), n), inset)
        self.cv.line(a, b, BEZEL_LIP, self.w(2))
    def scanlines(self, c, r):
        sp = max(3.0, 4.0 * self.u); y = -r + sp
        while y < r:
            h = math.sqrt(r * r - y * y)
            self.cv.line((c[0] - h, c[1] + y), (c[0] + h, c[1] + y), SCANLINE, self.w(1)); y += sp
    # identities
    def sidearm(self, c):
        u = self.u; r = 300 * u; bezel = 28.0; pts = self.circle_pts(c, r)
        self.glass(c, pts, 50); self.mask(c, pts, 0.94); self.bezel(c, pts, bezel)
        for i in range(3):
            d = from_angle(math.pi + TAU * i / 4); self.tab(add(c, mul(d, r + bezel * 0.5 * u)), d, 76, 40)
        for i in range(4):
            a = TAU * i / 4 + TAU / 8; self._arc(c, 38 * u, a - 0.5, a + 0.5, LINE, 5)
        for i in range(4):
            d = from_angle(TAU * i / 4); self._line(add(c, mul(d, 54 * u)), add(c, mul(d, 106 * u)), LINE, 7)
        self._dot(c, 4, LINE)
        self._plate(self.mag_text(), (c[0], c[1] + r + bezel * 0.5 * u), TEXT_MAG, AMBER)
    def service_rifle(self, c):
        u = self.u; hh = 330 * u; hw = min(650 * u, self.size[0] * 0.46); bezel = 24.0
        pts = self.pill_pts(c, hw, hh)
        self.glass(c, pts, 60); self.mask(c, pts, 0.95); self.bezel(c, pts, bezel)
        self.tab((c[0], c[1] - hh - bezel * 0.5 * u), (0, -1), 170, 38)
        self.tab((c[0], c[1] + hh + bezel * 0.5 * u), (0, 1), 170, 38)
        feet = [self.px_for(TH, r) for r in RIFLE_RANGES]
        post_end = max(70 * u, feet[0] + 18 * u); P = self.P
        self._line(P(c, -150, 0), P(c, -22, 0), LINE, 4); self._line(P(c, 22, 0), P(c, 150, 0), LINE, 4)
        self._line(P(c, -280, 0), P(c, -185, 0), LINE, 6); self._line(P(c, 185, 0), P(c, 280, 0), LINE, 6)
        self._line((c[0], c[1] + 22 * u), (c[0], c[1] + post_end), LINE, 4); self._dot(c, 3, LINE)
        for i, rng in enumerate(RIFLE_RANGES):
            y = c[1] + feet[i]; hw2 = 36 * u
            self._line((c[0] - hw2, y), (c[0] + hw2, y), AMBER, 5)
            self._line((c[0] - hw2, y - 12 * u), (c[0] - hw2, y), AMBER, 5)
            self._line((c[0] + hw2, y - 12 * u), (c[0] + hw2, y), AMBER, 5)
            self._text(str(int(rng)), (c[0] + hw2 + 26 * u, y - 4 * u), TEXT_RANGE, AMBER_DIM)
        ex = max(hw - hh, 150 * u); py = c[1] + hh + bezel * 0.5 * u
        self._plate(self.mag_text(), (c[0] + ex, py), TEXT_MAG, AMBER)
        if self.mode_text: self._plate(self.mode_text, (c[0] - ex, py), TEXT_MODE, AMBER)
    def marksman(self, c):
        u = self.u; r = 470 * u; bezel = 34.0; pts = self.circle_pts(c, r)
        self.glass(c, pts, 80); self.scanlines(c, r); self.mask(c, pts, 0.97); self.bezel(c, pts, bezel)
        for i in range(4):
            d = from_angle(TAU * i / 4); n = ortho(d)
            tip = add(c, mul(d, r - 30 * u)); base = add(c, mul(d, r + 4 * u))
            notch = [tip, add(base, mul(n, 22 * u)), sub(base, mul(n, 22 * u))]
            self.cv.polygon(notch, BEZEL); self.cv.polyline(notch + [notch[0]], BEZEL_LIP, self.w(2))
        inner = r * 0.36
        for i in range(4):
            d = from_angle(TAU * i / 4)
            self._line(add(c, mul(d, inner)), add(c, mul(d, r - 2 * u)), LINE, 6)
            self._line(add(c, mul(d, 10 * u)), add(c, mul(d, inner)), LINE, 2.5)
        self._dot(c, 3, LINE)
        mil = self.px_per_mil()
        step = next((m for m in MIL_STEPS if m * mil >= MIL_TICK_MIN_PX * u), MIL_STEPS[-1]); tick = step * mil
        if tick > 0:
            for k in range(1, int((inner - 6 * u) / tick) + 1):
                major = k % 5 == 0; half = (11 if major else 6) * u; o = k * tick; tw = 3 if major else 2
                self._line((c[0] + o, c[1] - half), (c[0] + o, c[1] + half), LINE, tw)
                self._line((c[0] - o, c[1] - half), (c[0] - o, c[1] + half), LINE, tw)
                if major: self._text(str(k * step), (c[0] + o, c[1] + 30 * u), TEXT_RANGE, AMBER_DIM)
        for i, rng in enumerate(MARKSMAN_RANGES):
            y = self.px_for(TH, rng)
            if y > inner - 8 * u: continue
            hw2 = (30 - 7 * i) * u; p = (c[0], c[1] + y)
            self._line((p[0] - hw2, p[1]), (p[0] + hw2, p[1]), AMBER, 4)
            self._text(str(int(rng)), (p[0] + hw2 + 22 * u, p[1]), TEXT_RANGE, AMBER_DIM)
        self._plate(self.mag_text(), add(c, mul(from_angle(math.pi / 4), r + bezel * 0.5 * u)), TEXT_MAG, AMBER)
    def field(self, c):
        u = self.u; hw = min(540 * u, self.size[0] * 0.45); hh = 380 * u; ch = 130 * u; bezel = 24.0
        X, Y = c
        corners = [(X-hw+ch, Y-hh), (X+hw-ch, Y-hh), (X+hw, Y-hh+ch), (X+hw, Y+hh-ch), (X+hw-ch, Y+hh),
                   (X-hw+ch, Y+hh), (X-hw, Y+hh-ch), (X-hw, Y-hh+ch)]
        pts = self.subdivide(corners, 8)
        self.glass(c, pts, 60); self.mask(c, pts, 0.95); self.bezel(c, pts, bezel); P = self.P
        self._line(P(c, -130, 0), P(c, -20, 0), LINE, 4); self._line(P(c, 20, 0), P(c, 130, 0), LINE, 4)
        self._line(P(c, 0, 20), P(c, 0, 160), LINE, 6); self._arc(c, 12 * u, 0, TAU, LINE, 3)
        self._plate(self.mag_text(), (c[0], c[1] + hh + bezel * 0.5 * u), TEXT_MAG, AMBER)

def hexc(h): h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def background(W, H, view_fov):
    """Neutral blurred Lockout-ish scene (bright snow sky, dark walls, sodium lamps), then a
    sharp-ish 1.8 m figure at 50 m standing with its head level with the centre."""
    img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
    top, hor = hexc("#a9b8c4"), hexc("#dfe6ea"); hy = int(H * 0.52)
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
    ppm = 0.001 / math.tan(math.radians(view_fov) / 2) * H * 0.5
    th = 1.8 / 50 * 1000 * ppm; tw = 0.7 / 50 * 1000 * ppm
    fig = Image.new("RGBA", (W, H), (0, 0, 0, 0)); fd = ImageDraw.Draw(fig)
    cx = W * 0.5 + 0.12 * H; head = H * 0.5; base = head + th
    col = hexc("#1d2630") + (255,)
    fd.rectangle([cx - tw / 2, base - th * 0.82, cx + tw / 2, base - th * 0.38], fill=col)
    fd.rectangle([cx - tw * 0.32, base - th * 0.40, cx + tw * 0.32, base], fill=col)
    fd.ellipse([cx - tw * 0.24, head, cx + tw * 0.24, base - th * 0.80], fill=col)
    fd.rectangle([cx - tw * 0.18, base - th * 0.93, cx + tw * 0.18, base - th * 0.88], fill=hexc("#c47a2c") + (255,))
    fig = fig.filter(ImageFilter.GaussianBlur(1.2 * k))
    return Image.alpha_composite(img.convert("RGBA"), fig).convert("RGB")

STYLES = [("sidearm", 2.0, "SEMI"), ("service_rifle", 1.8, "BURST"), ("marksman", 2.5, "SEMI"), ("field", 2.0, "")]

def render(style, mag, mode, W, H):
    vf = zoom_fov(mag); cv = Canvas(background(W, H, vf))
    getattr(Overlay(cv, vf, mag, mode), style)((W / 2, H / 2))
    return cv.finish()

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True); tiles = []
    for name, mag, mode in STYLES:
        for W, H in ((1920, 1080), (1280, 720)):
            im = render(name, mag, mode, W, H)
            p = f"{OUT}/scope_{name}_{W}x{H}.png"; im.save(p); print(p)
            if W == 1920: tiles.append((name, mag, im))
    tw, th, pad = 960, 540, 40
    sheet = Image.new("RGB", (tw * 2 + pad * 3, (th + pad) * 2 + pad), hexc("#1d2630"))
    sd = ImageDraw.Draw(sheet); f = ImageFont.truetype(FONT, 26)
    for i, (name, mag, im) in enumerate(tiles):
        x = pad + (i % 2) * (tw + pad); y = pad + (i // 2) * (th + pad)
        sheet.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
        sd.text((x, y + th + 4), f"{name.upper()}  {mag:.1f}x", font=f, fill=hexc("#e0a040"))
    p = f"{OUT}/scope_contact_sheet.png"; sheet.save(p); print(p)
