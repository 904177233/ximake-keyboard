#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
墨语（Moyu）App 图标生成器  v3
================================
输出：design/appicon/icon-1024.png（1024×1024 满幅方形，**不画圆角**：
      iOS 在 SpringBoard 上自动裁切 superellipse 圆角，源图必须画满方形）

设计概念：**一颗会说话的键帽（A keycap that talks）**
  ┌─────────────────────────────┐
  │  深色底 + 墨晕光             │
  │      ╭──────────────╮  ✦    │   ← 右上 AI 星芒，压住键帽边角
  │      │              │       │
  │      │      墨      │       │   ← 键帽 = 输入法；「墨」= 中文书写
  │      │              │       │
  │      ╰───╮──────────╯       │
  │          ╰─╮                │   ← 气泡尾巴 = 对话 / AI
  └─────────────────────────────┘

图层（由后至前）：
  1. 深色底：#17171F → #09090E 垂直渐变
  2. 墨晕：中心偏上的蓝紫径向光 #426ACC
  3. 键帽 ∪ 气泡尾巴：**同一个 alpha mask** 一次性贴渐变 #FFFFFF → #D0D8E8，
     外带落影 + 内侧 5px 白高光边（用 mask 减内缩形状得到边缘环）
  4. 「墨」字：msyhbd 微软雅黑 Bold，深墨色 #13192D，柔和落影
  5. AI 星芒：右上主星 + 左上/右下两颗小星，蓝渐变 #6AC6FF → #0A84FF
  6. 顶部 46% 白色微高光（.ultraThinMaterial 平面化）+ 四角轻暗角

安全区：可见主体外接 x∈[182,842]、y∈[182,940]，均在 iOS 图标 10% 安全边距内。
依赖：Pillow（本机 11.1.0）
运行：python generate_icon.py
"""
import os
import math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------- 品牌配色（图标专用）----------
BG_TOP = (23, 23, 31)          # #17171F
BG_BOT = (9, 9, 14)            # #09090E
GLOW = (66, 106, 204)          # 墨晕蓝
TILE_TOP = (255, 255, 255)     # #FFFFFF
TILE_BOT = (208, 216, 232)     # #D0D8E8
INK = (19, 25, 45)             # #13192D
ACCENT_A = (10, 132, 255)      # #0A84FF  ← tokens.json color.accent
ACCENT_B = (106, 198, 255)     # #6AC6FF

# ---------- 几何 ----------
TILE = 660
TILE_X0 = (SIZE - TILE) // 2       # 182
TILE_Y0 = (SIZE - TILE) // 2       # 182
TILE_R = 148                       # 148/660 ≈ 22.4%
GLYPH_RATIO = 0.335                # 「墨」字号 = 1024 × 0.335 = 343px（约占键帽 52%）
TAIL_W, TAIL_H, TAIL_ANGLE = 132, 118, 24

FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    r"C:\Windows\Fonts\Dengb.ttf",
    r"C:\Windows\Fonts\STSONG.TTF",
]


# ---------- 工具 ----------
def pick_font(px):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, px), p
            except Exception:
                continue
    return ImageFont.load_default(), "<default>"


def vgrad(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)],
               fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def radial_glow(size, center, radius, color, max_alpha=150, power=2.0):
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = center
    r = radius
    step = max(2, radius // 100)
    while r > 0:
        a = int(max_alpha * ((1.0 - r / radius) ** power))
        if a > 0:
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color + (a,))
        r -= step
    return img.filter(ImageFilter.GaussianBlur(radius * 0.04))


def sparkle_poly(cx, cy, r, spikes=4, thin=0.27):
    """四角星多边形：长臂 r，短臂 r*thin（thin 0.27 让星形在小尺寸下也不过细）"""
    pts, n = [], spikes * 2
    for i in range(n):
        ang = -math.pi / 2 + i * (2 * math.pi / n)
        rr = r if i % 2 == 0 else r * thin
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    return pts


def build_body_mask():
    """键帽 ∪ 气泡尾巴 —— 单一 alpha mask，保证无接缝"""
    m = Image.new("L", (SIZE, SIZE), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([TILE_X0, TILE_Y0, TILE_X0 + TILE, TILE_Y0 + TILE],
                        radius=TILE_R, fill=255)
    bx = TILE_X0 + 96
    by = TILE_Y0 + TILE - 30
    d.polygon([(bx, by),
               (bx + TAIL_W, by - TAIL_ANGLE),
               (bx + 26, by + TAIL_H)], fill=255)
    # 磨圆尖角：模糊 + 阈值回二值
    m = m.filter(ImageFilter.GaussianBlur(8))
    m = m.point(lambda v: 255 if v > 128 else 0)
    return m


def composite_ring(base, mask, inset=5, alpha=232):
    """在 mask 边缘画一圈 inset 像素宽的高光边"""
    inner = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(inner).rounded_rectangle(
        [TILE_X0 + inset, TILE_Y0 + inset,
         TILE_X0 + TILE - inset, TILE_Y0 + TILE - inset],
        radius=max(0, TILE_R - inset), fill=255)
    ring = Image.composite(mask, Image.new("L", (SIZE, SIZE), 0),
                           Image.eval(inner, lambda v: 255 - v))
    rim = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    rim.putalpha(ring.point(lambda v: alpha if v > 0 else 0))
    return Image.alpha_composite(base, rim)


def draw_star_blob(cx, cy, r, glow_alpha, blur):
    """返回 (光晕层, 星形层)。星形带一圈深色描边，保证压在浅色键帽上也能分离。"""
    m = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(m).polygon(sparkle_poly(cx, cy, r), fill=255)
    star = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    star.paste(vgrad((SIZE, SIZE), ACCENT_B, ACCENT_A).convert("RGBA"), (0, 0), m)
    halo = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    halo.paste(Image.new("RGBA", (SIZE, SIZE), ACCENT_B + (glow_alpha,)), (0, 0), m)
    halo = halo.filter(ImageFilter.GaussianBlur(blur))
    return halo, star, m


def star_with_rim(cx, cy, r, glow_alpha, blur, rim_px=5):
    """星形 + 外发光 + 深色外描边（外描边 = 膨胀后的 mask 减原 mask）"""
    halo, star, m = draw_star_blob(cx, cy, r, glow_alpha, blur)
    grown = m.filter(ImageFilter.MaxFilter(rim_px * 2 + 1))
    rim = Image.new("RGBA", (SIZE, SIZE), (6, 16, 38, 110))
    rim.putalpha(Image.composite(
        Image.new("L", (SIZE, SIZE), 110),
        Image.new("L", (SIZE, SIZE), 0),
        Image.composite(grown, Image.new("L", (SIZE, SIZE), 0),
                        Image.eval(m, lambda v: 255 - v))))
    return halo, rim, star


# ---------- 主绘制 ----------
def build():
    S = SIZE
    base = vgrad((S, S), BG_TOP, BG_BOT).convert("RGBA")

    # 1) 墨晕
    base = Image.alpha_composite(
        base, radial_glow((S, S), (S * 0.50, S * 0.44), int(S * 0.68), GLOW, 170, 1.8))

    # 2) 键帽 + 尾巴：单一 mask
    mask = build_body_mask()

    # 2a) 落影（mask 下移 22px、模糊）
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (S, S), (0, 0, 0, 190)), (0, 0), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(24))
    shifted = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shifted.paste(shadow, (0, 22))
    base = Image.alpha_composite(base, shifted)

    # 2b) 主体渐变
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    body.paste(vgrad((S, S), TILE_TOP, TILE_BOT).convert("RGB"), (0, 0), mask)
    base = Image.alpha_composite(base, body)

    # 2c) 内侧高光边
    base = composite_ring(base, mask)

    # 3) 「墨」字
    px = int(S * GLYPH_RATIO)
    f, font_path = pick_font(px)
    glyph = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dg = ImageDraw.Draw(glyph)
    bb = dg.textbbox((0, 0), "墨", font=f)
    gw, gh = bb[2] - bb[0], bb[3] - bb[1]
    gx = (S - gw) / 2 - bb[0]
    gy = (S * 0.470) - gh / 2 - bb[1]
    # 落影
    gsh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(gsh).text((gx + 4, gy + 9), "墨", font=f, fill=(26, 36, 66, 110))
    base = Image.alpha_composite(base, gsh.filter(ImageFilter.GaussianBlur(11)))
    dg.text((gx, gy), "墨", font=f, fill=INK + (255,))
    base = Image.alpha_composite(base, glyph)

    # 4) AI 星芒（收敛外发光 + 深色描边，保证在浅色键帽上有清晰剪影）
    for cx, cy, r, ga, bl in [
        (TILE_X0 + TILE - 22, TILE_Y0 + 30, 120, 175, 16),    # 主星
        (TILE_X0 + TILE - 190, TILE_Y0 - 26, 40, 145, 9),     # 左上小星
        (TILE_X0 + TILE + 16, TILE_Y0 + 214, 34, 135, 8),     # 右下小星
    ]:
        halo, rim, star = star_with_rim(cx, cy, r, ga, bl)
        base = Image.alpha_composite(base, halo)
        base = Image.alpha_composite(base, rim)
        base = Image.alpha_composite(base, star)

    # 5) 顶部 46% 高光
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dh = ImageDraw.Draw(hl)
    for y in range(0, int(S * 0.46)):
        t = 1 - (y / (S * 0.46))
        dh.line([(0, y), (S, y)], fill=(255, 255, 255, int(20 * (t ** 1.7))))
    base = Image.alpha_composite(base, hl)

    # 6) 四角轻暗角
    vig = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dv = ImageDraw.Draw(vig)
    for i in range(28):
        a = int(32 * (1 - i / 28))
        dv.rounded_rectangle([i, i, S - 1 - i, S - 1 - i],
                             radius=max(0, 250 - i * 5), outline=(0, 0, 0, a), width=1)
    base = Image.alpha_composite(base, vig.filter(ImageFilter.GaussianBlur(12)))

    return base.convert("RGB"), font_path


def main():
    img, font_path = build()
    assert img.size == (SIZE, SIZE), img.size
    out = os.path.join(OUT_DIR, "icon-1024.png")
    img.save(out, "PNG", optimize=True)
    print(f"[ok] icon-1024.png  1024x1024  {os.path.getsize(out) / 1024:.1f} KB  "
          f"font={os.path.basename(font_path)}")
    for s in (180, 120, 80, 60, 40):
        p = os.path.join(OUT_DIR, f"icon-{s}.png")
        img.resize((s, s), Image.LANCZOS).save(p, "PNG", optimize=True)
        print(f"[ok] icon-{s}.png")


if __name__ == "__main__":
    main()
