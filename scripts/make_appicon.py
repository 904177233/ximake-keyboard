#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— AppIcon / AccentColor 生成器。

用 Pillow 生成 iOS 14+ 单尺寸（1024x1024）AppIcon，并写入 Assets.xcassets：
    ios/Resources/Assets.xcassets/
        Contents.json
        AppIcon.appiconset/Contents.json + AppIcon-1024.png
        AccentColor.colorset/Contents.json          （品牌蓝 #0A84FF）
        LaunchBackground.colorset/Contents.json     （可选，启动屏底色）

用法（Windows / macOS / Linux 均可）：
    # 1) 默认：脚本自己画一个简洁可用的图标（深色渐变底 + 白色几何「墨/键」符号）
    python scripts/make_appicon.py

    # 2) 用设计团队产出的正式方案覆盖（design/appicon/icon-1024.png）
    python scripts/make_appicon.py --from design/appicon/icon-1024.png

    # 3) 指定输出目录 / 强制重画
    python scripts/make_appicon.py --out ios/Resources/Assets.xcassets --force

设计说明（默认自绘版）：
    背景：#0B1020 → #16324F 对角线性渐变（比纯黑更有层次，和品牌蓝 #0A84FF 同色相）
    前景：白色「墨」字骨架 + 一枚圆角键帽轮廓，表达「输入法 + AI」；
          右下角一颗 #0A84FF 的圆点作为 AI 高光。
    厚度：iOS 会自己切圆角，所以 PNG 必须是**满幅直角**的 1024x1024，不要预先画圆角。

退出码：0 成功；1 失败（含 Pillow 未安装、源图不合规）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:  # pragma: no cover - 环境缺失时给可读提示
    print("[错误] 未安装 Pillow。请先运行：", file=sys.stderr)
    print(f"  {sys.executable} -m pip install Pillow", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "ios" / "Resources" / "Assets.xcassets"
DEFAULT_SOURCE = REPO_ROOT / "design" / "appicon" / "icon-1024.png"

ICON_SIZE = 1024

BRAND_BLUE = (0x0A, 0x84, 0xFF)          # #0A84FF  AccentColor
BG_TOP = (0x0B, 0x10, 0x20)              # 深蓝黑
BG_BOTTOM = (0x16, 0x32, 0x4F)           # 深海军蓝
WHITE = (255, 255, 255)

# macOS / Windows 上常见、且能覆盖 1024px 的中文字体候选（找不到就退回几何图形）
CJK_FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyhbd.ttc",      # 微软雅黑 Bold
    r"C:\Windows\Fonts\msyh.ttc",        # 微软雅黑
    r"C:\Windows\Fonts\simhei.ttf",      # 黑体
    r"C:\Windows\Fonts\Deng.ttf",        # 等线
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


# ---------------------------------------------------------------------------
# 绘图工具
# ---------------------------------------------------------------------------

def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _lerp_color(c1, c2, t: float):
    return tuple(int(round(_lerp(c1[i], c2[i], t))) for i in range(3))


def _diagonal_gradient(size: int, top, bottom, angle_bias: float = 0.35):
    """生成对角线性渐变（左上 → 右下），返回 RGB Image。"""
    base = Image.new("RGB", (size, size), top)
    px = base.load()
    for y in range(size):
        for x in range(size):
            # 归一化对角进度：x 权重略低于 y，避免左下/右上过暗
            t = (x / (size - 1)) * angle_bias + (y / (size - 1)) * (1.0 - angle_bias)
            px[x, y] = _lerp_color(top, bottom, t)
    return base


def _vertical_gradient(size: int, top, bottom):
    base = Image.new("RGB", (size, size), top)
    px = base.load()
    for y in range(size):
        t = y / max(1, size - 1)
        row = _lerp_color(top, bottom, t)
        for x in range(size):
            px[x, y] = row
    return base


def _find_cjk_font(size: int):
    """返回 (font, path) 或 (None, None)。"""
    for path in CJK_FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size), path
            except Exception:
                continue
    return None, None


def _draw_rounded_key(draw: ImageDraw.ImageDraw, box, radius: int, fill, outline=None, width: int = 0):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_default_icon(size: int = ICON_SIZE) -> Image.Image:
    """自绘一版简洁可用的图标：深色渐变底 + 白色几何「墨/键」符号。"""
    img = _diagonal_gradient(size, BG_TOP, BG_BOTTOM, angle_bias=0.38)

    # ---- 背景柔光（右上角的品牌蓝光晕，让图标不死板）----
    glow = Image.new("RGB", (size, size), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy, r = int(size * 0.78), int(size * 0.20), int(size * 0.46)
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(0x0A, 0x84, 0xFF))
    glow = glow.filter(ImageFilter.GaussianBlur(int(size * 0.16)))
    img = Image.blend(img, Image.blend(img, glow, 0.0), 0.0) if False else img
    img = Image.composite(
        Image.new("RGB", (size, size), (0x0A, 0x84, 0xFF)),
        img,
        glow.convert("L").point(lambda v: int(v * 0.45)),
    )

    draw = ImageDraw.Draw(img, "RGBA")

    # ---- 主符号：圆角键帽的外框（表达"键盘"）----
    pad = int(size * 0.185)
    key_box = [pad, pad, size - pad, size - pad]
    key_radius = int(size * 0.155)
    # 外发光描边
    for i, alpha in ((10, 18), (6, 30), (2, 60)):
        draw.rounded_rectangle(
            [key_box[0] - i, key_box[1] - i, key_box[2] + i, key_box[3] + i],
            radius=key_radius + i,
            outline=(255, 255, 255, alpha),
            width=2,
        )
    # 键帽主体（半透明白玻璃）
    draw.rounded_rectangle(key_box, radius=key_radius,
                           fill=(255, 255, 255, 26),
                           outline=(255, 255, 255, 200), width=max(3, size // 220))

    # ---- 键帽内：「墨」字（有中文字体时）----
    font, font_path = _find_cjk_font(int(size * 0.42))
    if font is not None:
        text = "墨"
        bbox = draw.textbbox((0, 0), text, font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        tx = (size - tw) / 2 - bbox[0]
        ty = (size - th) / 2 - bbox[1] - int(size * 0.045)
        # 先画一层柔光再画实心，模拟玻璃高光
        draw.text((tx, ty), text, font=font, fill=(255, 255, 255, 255))
    else:
        # 无中文字体：画三条横线 + 一条竖线的抽象"笔画"
        cx = size / 2
        bar_h = max(6, int(size * 0.028))
        gap = int(size * 0.115)
        for i, w_ratio in enumerate((0.40, 0.50, 0.34)):
            y = size * 0.40 + i * gap
            w = size * w_ratio
            draw.rounded_rectangle([cx - w / 2, y - bar_h / 2, cx + w / 2, y + bar_h / 2],
                                   radius=bar_h // 2, fill=(255, 255, 255, 240))
        draw.rounded_rectangle([cx - bar_h / 2, size * 0.30, cx + bar_h / 2, size * 0.68],
                               radius=bar_h // 2, fill=(255, 255, 255, 240))

    # ---- 右下角 AI 高光点 ----
    dot_r = int(size * 0.052)
    dot_cx, dot_cy = int(size * 0.735), int(size * 0.735)
    draw.ellipse([dot_cx - dot_r * 2, dot_cy - dot_r * 2, dot_cx + dot_r * 2, dot_cy + dot_r * 2],
                 fill=(0x0A, 0x84, 0xFF, 40))
    draw.ellipse([dot_cx - dot_r, dot_cy - dot_r, dot_cx + dot_r, dot_cy + dot_r],
                 fill=(0x0A, 0x84, 0xFF, 255))
    draw.ellipse([dot_cx - int(dot_r * 0.45), dot_cy - int(dot_r * 0.62),
                  dot_cx + int(dot_r * 0.15), dot_cy - int(dot_r * 0.12)],
                 fill=(255, 255, 255, 150))

    # ---- 底部一行小键帽，暗示键盘 ----
    k_h = int(size * 0.042)
    k_w = int(size * 0.075)
    k_gap = int(size * 0.024)
    total = 5 * k_w + 4 * k_gap
    start_x = (size - total) / 2
    y0 = size - int(size * 0.125)
    for i in range(5):
        x0 = start_x + i * (k_w + k_gap)
        alpha = 210 if i == 2 else 120
        draw.rounded_rectangle([x0, y0, x0 + k_w, y0 + k_h], radius=k_h // 2,
                               fill=(255, 255, 255, alpha))

    return img.convert("RGB")


def load_source_icon(path: Path) -> Image.Image:
    """读取设计稿 PNG，校验尺寸并转成满幅 RGB。"""
    if not path.exists():
        raise FileNotFoundError(f"找不到源图：{path}")
    img = Image.open(path)
    img.load()
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        bg = Image.new("RGB", rgba.size, BG_TOP)
        bg.paste(rgba, mask=rgba.split()[-1])
        img = bg
    else:
        img = img.convert("RGB")
    if img.size != (ICON_SIZE, ICON_SIZE):
        print(f"[提示] 源图尺寸 {img.size} ≠ ({ICON_SIZE}, {ICON_SIZE})，已用 LANCZOS 缩放。")
        img = img.resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
    return img


# ---------------------------------------------------------------------------
# Assets.xcassets 写入
# ---------------------------------------------------------------------------

CONTENTS_APPICON = {
    "images": [
        {
            "filename": "AppIcon-1024.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
    ],
    "info": {"author": "xcode", "version": 1},
}

CONTENTS_ACCENT = {
    "colors": [
        {
            "color": {
                "color-space": "srgb",
                "components": {"alpha": "1.000", "blue": "1.000", "green": "0.518", "red": "0.039"},
            },
            "idiom": "universal",
        },
        {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "color": {
                "color-space": "srgb",
                "components": {"alpha": "1.000", "blue": "1.000", "green": "0.600", "red": "0.180"},
            },
            "idiom": "universal",
        },
    ],
    "info": {"author": "xcode", "version": 1},
}

CONTENTS_ROOT = {"info": {"author": "xcode", "version": 1}}


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8")


def build(out_root: Path, source: Path | None, force: bool = False) -> int:
    out_root = out_root.resolve()
    appiconset = out_root / "AppIcon.appiconset"
    accent = out_root / "AccentColor.colorset"
    png_path = appiconset / "AppIcon-1024.png"

    appiconset.mkdir(parents=True, exist_ok=True)
    accent.mkdir(parents=True, exist_ok=True)

    # ---- 根 Contents.json ----
    _write_json(out_root / "Contents.json", CONTENTS_ROOT)

    # ---- AppIcon ----
    if source is not None:
        icon = load_source_icon(source)
        print(f"[AppIcon] 使用设计稿：{source}")
    else:
        if png_path.exists() and not force:
            icon = None
            print(f"[AppIcon] 已存在，跳过（--force 可重画）：{png_path}")
        else:
            icon = draw_default_icon()
            print("[AppIcon] 使用脚本自绘版本")
    if icon is not None:
        icon.save(png_path, format="PNG", optimize=True)
        print(f"[AppIcon] 已写入：{png_path} ({ICON_SIZE}x{ICON_SIZE})")
    _write_json(appiconset / "Contents.json", CONTENTS_APPICON)

    # ---- AccentColor ----
    _write_json(accent / "Contents.json", CONTENTS_ACCENT)
    print(f"[AccentColor] 已写入：{accent / 'Contents.json'}  (#0A84FF)")

    # ---- 目录摘要 ----
    print("\n[完成] Assets.xcassets 结构：")
    for p in sorted(out_root.rglob("*")):
        if p.is_file():
            print(f"  {p.relative_to(out_root.parent)}  ({p.stat().st_size} bytes)")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="生成墨语 AppIcon（1024x1024）与 AccentColor 到 Assets.xcassets",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python scripts/make_appicon.py\n"
               "  python scripts/make_appicon.py --from design/appicon/icon-1024.png --force\n",
    )
    parser.add_argument("--from", dest="source", default=None,
                        help=f"设计稿 1024x1024 PNG 路径（默认：{DEFAULT_SOURCE} 存在则用它）")
    parser.add_argument("--out", dest="out", default=str(DEFAULT_OUT),
                        help=f"Assets.xcassets 输出目录（默认：{DEFAULT_OUT}）")
    parser.add_argument("--force", action="store_true", help="已存在时强制重画/覆盖")
    parser.add_argument("--no-source-autodetect", action="store_true",
                        help="即使 design/appicon/icon-1024.png 存在也不用它，强制自绘")
    args = parser.parse_args(argv)

    source = None
    if args.source:
        source = Path(args.source)
        if not source.is_absolute():
            source = (Path.cwd() / source).resolve()
        if not source.exists():
            print(f"[错误] --from 指定的文件不存在：{source}", file=sys.stderr)
            return 1
    elif not args.no_source_autodetect and DEFAULT_SOURCE.exists():
        source = DEFAULT_SOURCE
        print(f"[提示] 发现设计稿 {DEFAULT_SOURCE}，自动使用（可用 --no-source-autodetect 关闭）")

    try:
        return build(Path(args.out), source, force=args.force)
    except Exception as exc:  # noqa: BLE001
        print(f"[错误] 生成失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
