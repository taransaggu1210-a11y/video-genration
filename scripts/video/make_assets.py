import sys
import os
from PIL import Image, ImageDraw

SS = 4  # supersample factor for anti-aliasing

# Baseline design: at INNER_W=1408 (the 1600-wide base video), border=2,
# outer radius=16, inner radius=15. Other sizes scale proportionally so the
# card looks the same regardless of the base video's resolution.
BASE_INNER_W = 1408
BASE_OUTER_R = 16
BASE_INNER_R = 15

INNER_W = int(sys.argv[1]) if len(sys.argv) > 1 else BASE_INNER_W
BORDER = int(sys.argv[2]) if len(sys.argv) > 2 else 2
OUT_DIR = sys.argv[3] if len(sys.argv) > 3 else "."

SCALE = INNER_W / BASE_INNER_W
INNER_H = round(INNER_W * 9 / 16)
OUTER_R = round(BASE_OUTER_R * SCALE)
INNER_R = round(BASE_INNER_R * SCALE)
CARD_W, CARD_H = INNER_W + 2 * BORDER, INNER_H + 2 * BORDER

GOLD_LIGHT = (247, 231, 176, 255)   # champagne highlight
GOLD_MID   = (205, 185, 104, 255)  # site --gold
GOLD_DARK  = (138, 110, 47, 255)   # bronze shadow


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))


def diagonal_gradient(w, h):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    max_d = (w - 1) + (h - 1)
    for y in range(h):
        for x in range(w):
            t = (x + y) / max_d
            if t < 0.5:
                c = lerp(GOLD_LIGHT, GOLD_MID, t / 0.5)
            else:
                c = lerp(GOLD_MID, GOLD_DARK, (t - 0.5) / 0.5)
            px[x, y] = c
    return img


def rounded_mask(w, h, radius, ss=SS):
    m = Image.new("L", (w * ss, h * ss), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, w * ss - 1, h * ss - 1], radius=radius * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)


# --- gold_border.png: gradient-filled outer rounded rect, with a rounded
# transparent hole cut out for the video, outer silhouette also rounded ---
gradient = diagonal_gradient(CARD_W, CARD_H)
outer_mask = rounded_mask(CARD_W, CARD_H, OUTER_R)

border_img = Image.new("RGBA", (CARD_W, CARD_H), (0, 0, 0, 0))
border_img.paste(gradient, (0, 0), outer_mask)

# cut the inner hole fully transparent
hole_mask = Image.new("L", (CARD_W, CARD_H), 0)
inner_shape = rounded_mask(INNER_W, INNER_H, INNER_R)
hole_mask.paste(inner_shape, (BORDER, BORDER))

r, g, b, a = border_img.split()
a_px = a.load()
h_px = hole_mask.load()
for y in range(CARD_H):
    for x in range(CARD_W):
        if h_px[x, y] > 0:
            a_px[x, y] = int(a_px[x, y] * (1 - h_px[x, y] / 255.0))
border_img = Image.merge("RGBA", (r, g, b, a))
border_img.save(os.path.join(OUT_DIR, "gold_border.png"))

# --- inner_mask.png: white rounded rect (radius INNER_R) on black, used to
# round the teaser video's own corners via alphamerge ---
inner_mask_img = Image.new("L", (INNER_W, INNER_H), 0)
inner_mask_img.paste(rounded_mask(INNER_W, INNER_H, INNER_R), (0, 0))
inner_mask_img.save(os.path.join(OUT_DIR, "inner_mask.png"))

print("card:", CARD_W, CARD_H, "inner:", INNER_W, INNER_H, "border:", BORDER)
