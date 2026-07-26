#!/usr/bin/env python3
"""Generate macOS-style app icons (mic + waveform) for Transcribe.app."""
import math
from PIL import Image, ImageDraw

S = 1024  # master size
SUP = 2   # supersample factor for smooth edges


def squircle_mask(size, radius_frac=0.225):
    """Apple-ish rounded-rect (rounded rectangle approximation)."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    r = int(size * radius_frac)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return m


def vgrad(size, top, bottom):
    """Vertical gradient image."""
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((size, size))


def draw_mic(d, cx, cy, scale, color):
    """Draw a clean rounded microphone, vertically centered on (cx, cy)."""
    s = scale
    lw = int(40 * s)               # stroke weight for cradle/stem/base
    bw = int(150 * s)              # body width
    bh = int(300 * s)              # body height
    # Lay the assembly out around cy: body up top, cradle cupping it, stem, base.
    body_top = cy - int(230 * s)
    body_bot = body_top + bh
    # mic capsule body (fully rounded pill)
    d.rounded_rectangle([cx - bw // 2, body_top, cx + bw // 2, body_bot],
                        radius=bw // 2, fill=color)
    # cradle: wide U-arc cupping the lower half of the body, clearly separated
    aw = int(300 * s)              # cradle width
    ah = int(300 * s)              # cradle height (bounding box)
    arc_top = body_bot - int(150 * s)
    d.arc([cx - aw // 2, arc_top, cx + aw // 2, arc_top + ah],
          start=15, end=165, fill=color, width=lw)
    # stem down from cradle bottom
    stem_top = arc_top + ah // 2 + int(20 * s)
    stem_bot = stem_top + int(110 * s)
    d.line([cx, stem_top, cx, stem_bot], fill=color, width=lw)
    # base foot
    basew = int(200 * s)
    d.line([cx - basew // 2, stem_bot, cx + basew // 2, stem_bot],
           fill=color, width=lw)


def draw_waves(d, cx, cy, scale, color):
    """Symmetric waveform bars flanking the mic."""
    heights = [80, 150, 240, 150, 80]          # relative bar heights
    gap = int(70 * scale)
    bw = int(34 * scale)
    # left side bars (mirror) and right side bars
    offsets = [3, 4]   # which bars sit to each side of the mic
    positions = [-4, -3, 3, 4]
    hmap = {-4: 80, -3: 150, 3: 150, 4: 80}
    for k in positions:
        x = cx + k * gap
        h = int(hmap[k] * scale)
        d.rounded_rectangle([x - bw // 2, cy - h // 2, x + bw // 2, cy + h // 2],
                            radius=bw // 2, fill=color)


def build(top_color, bottom_color, fname, waves=True):
    big = S * SUP
    base = vgrad(big, top_color, bottom_color).convert("RGBA")
    d = ImageDraw.Draw(base)
    cx = big // 2
    cy = big // 2
    if waves:
        draw_waves(d, cx, cy, SUP, (255, 255, 255, 235))
        draw_mic(d, cx, cy, SUP, (255, 255, 255, 255))
    else:
        draw_mic(d, cx, cy, SUP * 1.15, (255, 255, 255, 255))
    # subtle inner highlight at top
    mask = squircle_mask(big)
    base.putalpha(mask)
    out = base.resize((S, S), Image.LANCZOS)
    out.save(fname)
    # small preview
    out.resize((256, 256), Image.LANCZOS).save(fname.replace(".png", "_preview.png"))


# Option A: indigo -> violet, mic + waveform
build((99, 102, 241), (139, 92, 246),
      "/private/tmp/claude-501/-Users-josefbuttgen-Desktop/07a36138-4bed-4307-84a7-d0f8cb6b90d9/scratchpad/iconA.png",
      waves=True)
# Option B: teal -> deep blue, mic only (cleaner)
build((20, 184, 166), (37, 99, 235),
      "/private/tmp/claude-501/-Users-josefbuttgen-Desktop/07a36138-4bed-4307-84a7-d0f8cb6b90d9/scratchpad/iconB.png",
      waves=True)
print("done")
