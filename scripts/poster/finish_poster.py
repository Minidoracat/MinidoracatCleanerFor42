# -*- coding: utf-8 -*-
"""把 codex imagegen 主視覺疊上 PZ 風標題，輸出 poster.png / preview.png（512x512）。
Deterministic：無隨機數。沿用 MiniMap 家族的告示板＋警戒條視覺語言。"""
import os
from PIL import Image, ImageDraw, ImageFont

SP = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SP))
MOD_42 = os.path.join(REPO, "MOD", "MinidoracatCleanerFor42", "Contents", "mods",
                      "MinidoracatCleanerFor42", "42")
MOD_ROOT = os.path.join(REPO, "MOD", "MinidoracatCleanerFor42")

FONTS = r"C:/Windows/Fonts"
GOLD = (233, 195, 90, 255)
PALE = (240, 234, 214, 255)
INK = (28, 26, 20, 255)
BOARD = (38, 40, 30, 235)      # 暗橄欖告示板
BOARD_EDGE = (18, 18, 12, 255)
TAPE = (214, 200, 160, 210)    # 泛黃膠帶
HAZ_Y = (208, 168, 40, 255)    # 警戒黃
HAZ_K = (24, 22, 18, 255)      # 警戒黑


def font(size, *names):
    for n in names:
        p = os.path.join(FONTS, n)
        if os.path.isfile(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def fit(draw, text, max_w, size, *names):
    f = font(size, *names)
    while size > 12 and draw.textlength(text, font=f) > max_w:
        size -= 2
        f = font(size, *names)
    return f


def stroked(draw, xy, text, f, fill, stroke, w):
    draw.text(xy, text, font=f, fill=fill, stroke_width=w, stroke_fill=stroke)


def tape(draw, cx, cy, w=64, h=26):
    draw.rectangle([cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2], fill=TAPE)


def hazard_strip(draw, x0, y0, x1, y1, step=26):
    draw.rectangle([x0, y0, x1, y1], fill=HAZ_Y)
    for s in range(x0 - (y1 - y0), x1, step * 2):
        draw.polygon([(s, y1), (s + step, y1), (s + step + (y1 - y0), y0), (s + (y1 - y0), y0)],
                     fill=HAZ_K)
    draw.rectangle([x0, y0, x1, y1], outline=BOARD_EDGE, width=3)


def load_art(name):
    im = Image.open(os.path.join(SP, name)).convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    return im


def cleaner_poster():
    im = load_art("main_art.png")
    d = ImageDraw.Draw(im)
    # 標題板：頂部偏左（構圖已為上方留白）
    bx0, by0, bx1, by1 = 28, 26, 660, 232
    d.rectangle([bx0 + 6, by0 + 8, bx1 + 6, by1 + 8], fill=(0, 0, 0, 120))  # 投影
    d.rectangle([bx0, by0, bx1, by1], fill=BOARD, outline=BOARD_EDGE, width=4)
    hazard_strip(d, bx0, by0, bx1, by0 + 14)
    tape(d, bx0 + 26, by0 + 10)
    tape(d, bx1 - 26, by0 + 10)
    # 文字
    f_brand = fit(d, "Minidoracat", bx1 - bx0 - 60, 54, "segoeuib.ttf", "arialbd.ttf")
    f_title = fit(d, "CLEANER", bx1 - bx0 - 56, 106, "impact.ttf", "arialbd.ttf")
    stroked(d, (bx0 + 30, by0 + 30), "Minidoracat", f_brand, PALE, INK, 3)
    stroked(d, (bx0 + 28, by0 + 88), "CLEANER", f_title, GOLD, INK, 5)
    # for Build 42 小板
    f_sub = font(38, "segoeuib.ttf", "arialbd.ttf")
    sw = d.textlength("for Build 42", font=f_sub)
    d.rectangle([bx0, by1 + 10, bx0 + sw + 44, by1 + 66], fill=(52, 46, 34, 225),
                outline=BOARD_EDGE, width=3)
    stroked(d, (bx0 + 22, by1 + 16), "for Build 42", f_sub, PALE, INK, 2)
    return im


def save(im):
    small = im.resize((512, 512), Image.LANCZOS).convert("RGB")
    out = os.path.join(SP, "posters")
    os.makedirs(out, exist_ok=True)
    targets = [
        os.path.join(out, "poster.png"),
        os.path.join(out, "preview.png"),
        os.path.join(MOD_42, "poster.png"),
        os.path.join(MOD_ROOT, "preview.png"),
    ]
    for t in targets:
        os.makedirs(os.path.dirname(t), exist_ok=True)
        small.save(t, "PNG")
        print("寫出:", t)


if __name__ == "__main__":
    save(cleaner_poster())
    print("done")
