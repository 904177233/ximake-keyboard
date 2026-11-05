#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语 App 图标：一颗键帽，上面一滴墨。

键帽代表输入法，墨滴对应名字，也和键盘里的 AI 圆钮、空格键上的小形象是同一个图案。
配色用暖陶色系。图形尽量简单，桌面上缩到 60pt 也认得出来。

输出 1024×1024 满幅方形、不透明（iOS 自己裁圆角，也不接受透明通道）。
运行：python design/appicon/generate_icon.py
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 3
S = SIZE * SCALE
HERE = os.path.dirname(os.path.abspath(__file__))
ASSET = os.path.join(HERE, "..", "..", "ios", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")

CLAY_TOP = (226, 139, 106)
CLAY_BOTTOM = (193, 90, 56)
CAP_TOP = (255, 252, 245)
CAP_BOTTOM = (240, 233, 219)
CAP_EDGE = (150, 66, 38)
INK_TOP = (66, 58, 52)
INK_BOTTOM = (28, 25, 23)


def vertical_gradient(size, top, bottom):
    width, height = size
    column = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(height - 1, 1)
        column.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((width, height))


def squircle_mask(box, exponent=5.2):
    """连续圆角（超椭圆和圆角矩形之间），比普通圆角更接近 iOS 的形状。"""
    x0, y0, x1, y1 = box
    width = x1 - x0
    height = y1 - y0
    half_w = width / 2
    half_h = height / 2
    points = []
    for i in range(1440):
        angle = i / 1440 * 2 * math.pi
        cos, sin = math.cos(angle), math.sin(angle)
        px = abs(cos) ** (2 / exponent) * half_w * (1 if cos >= 0 else -1)
        py = abs(sin) ** (2 / exponent) * half_h * (1 if sin >= 0 else -1)
        points.append((x0 + half_w + px, y0 + half_h + py))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def drop_mask(center_x, tip_y, bottom_y, half_width):
    """水滴：上尖下圆。整条轮廓是一条连续曲线，没有接缝。"""
    height = bottom_y - tip_y
    samples = []
    for i in range(2400):
        t = i / 2400 * 2 * math.pi
        samples.append((math.sin(t) * math.sin(t / 2) ** 1.5, (1 - math.cos(t)) / 2))
    widest = max(abs(x) for x, _ in samples)
    points = [(center_x + x / widest * half_width, tip_y + y * height) for x, y in samples]
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def main():
    canvas = vertical_gradient((S, S), CLAY_TOP, CLAY_BOTTOM).convert("RGB")

    # 背景上一层很淡的顶光，让平面不至于死板
    glow = Image.new("L", (S, S), 0)
    draw = ImageDraw.Draw(glow)
    draw.ellipse((-0.2 * S, -0.75 * S, 1.2 * S, 0.45 * S), fill=46)
    glow = glow.filter(ImageFilter.GaussianBlur(0.09 * S))
    canvas = Image.composite(Image.new("RGB", (S, S), (255, 236, 222)), canvas, glow)

    # 键帽
    margin = 0.205 * S
    cap_box = (margin, margin - 0.012 * S, S - margin, S - margin - 0.024 * S)
    depth = 0.030 * S

    # 落在背景上的柔和阴影
    shadow = squircle_mask((cap_box[0], cap_box[1] + depth * 2.4, cap_box[2], cap_box[3] + depth * 2.4))
    shadow = shadow.filter(ImageFilter.GaussianBlur(0.030 * S)).point(lambda v: int(v * 0.42))
    canvas = Image.composite(Image.new("RGB", (S, S), (112, 44, 22)), canvas, shadow)

    # 键帽的厚度（下沿）
    edge = squircle_mask((cap_box[0], cap_box[1] + depth, cap_box[2], cap_box[3] + depth))
    canvas = Image.composite(Image.new("RGB", (S, S), CAP_EDGE), canvas, edge)

    # 键帽顶面
    top = squircle_mask(cap_box)
    canvas = Image.composite(vertical_gradient((S, S), CAP_TOP, CAP_BOTTOM), canvas, top)

    # 墨滴
    center_x = S / 2
    cap_mid = (cap_box[1] + cap_box[3]) / 2
    drop_height = 0.372 * S
    tip_y = cap_mid - drop_height * 0.56
    bottom_y = cap_mid + drop_height * 0.44
    half_width = 0.128 * S
    drop = drop_mask(center_x, tip_y, bottom_y, half_width)
    canvas = Image.composite(vertical_gradient((S, S), INK_TOP, INK_BOTTOM), canvas, drop)

    # 墨滴上的一笔高光，用主色，把两种颜色连起来
    highlight = Image.new("L", (S, S), 0)
    pen = ImageDraw.Draw(highlight)
    arc_radius = half_width * 0.64
    arc_x = center_x
    arc_y = bottom_y - half_width * 0.98
    stroke = 0.0165 * S
    for i in range(241):
        angle = math.radians(128 + 58 * i / 240)
        x = arc_x + arc_radius * math.cos(angle)
        y = arc_y + arc_radius * math.sin(angle)
        pen.ellipse((x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2), fill=255)
    canvas = Image.composite(Image.new("RGB", (S, S), (233, 150, 116)), canvas, highlight)

    icon = canvas.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    icon.save(os.path.join(HERE, "icon-1024.png"))
    icon.save(os.path.normpath(ASSET))
    for size in (180, 120, 80, 60, 40):
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(HERE, f"icon-{size}.png"))

    # 小尺寸预览，核对缩到桌面大小还认不认得出来
    sheet = Image.new("RGB", (560, 200), (242, 242, 245))
    x = 20
    for size in (180, 120, 80, 60, 40):
        tile = icon.resize((size, size), Image.LANCZOS)
        mask = Image.new("L", (size * 4, size * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * 4, size * 4), radius=int(size * 4 * 0.225), fill=255)
        sheet.paste(tile, (x, 10), mask.resize((size, size), Image.LANCZOS))
        x += size + 14
    sheet.save(os.path.join(os.environ.get("MOYU_SCRATCH", HERE), "icon_preview.png"))


if __name__ == "__main__":
    main()
