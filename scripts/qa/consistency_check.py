#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— 设计令牌 × 代码 一致性校验（consistency_check.py）。

Python 3 标准库，零第三方依赖，可在 Windows 直接运行（无需 Xcode）。

校验四件事（docs/02 §5 设计令牌契约 + design/05 主题规范）：
  ① tokens → Theme.swift 覆盖度（P1）
     - `design/tokens.json` 里 `color.light` / `color.dark` 的每个叶子键与 hex 值
     - `typography` / `spacing` / `radius` / `sizing` / `motion` / `shadow` 的每个键与数值
     - 逐个检查：hex 值（大小写不敏感）是否出现在 `ios/Shared/Theme/Theme.swift`；
       数值是否出现在 Theme.swift（整数/小数都试）；缺失 → P1
  ② 硬编码 / 魔法数字（P2）
     - `ios/AIKeyboard/**` 与 `ios/AIKeyboardExtension/**` 里出现 `#RRGGBB` / `0xRRGGBB`
     - `.font(.system(size: N))` 中 N 不在 tokens 的 typography sizes 里
  ③ tokens.json 自身完整性（P0）
     - docs/02 §5 要求的全部顶层键与关键键名是否存在（缺 → P0）
  ④ 主题预设一致性（design/05 §6，P0/P1/P2）
     - tokens 缺 `theme` 组 → P0
     - 某预设只在 tokens 有、Swift 里找不到（或反之）→ P0
     - 浅色 hex 值不一致 → P1（报告给出 `preset.field: tokens=#X swift=#Y`）
     - 深色 hex 缺失 / 不可解析 → P2（深色值由 AppTheme 按 §1.2 推导，不在 tokens 里登记）

用法：
    python scripts/qa/consistency_check.py
    python scripts/qa/consistency_check.py --json
    python scripts/qa/consistency_check.py --md out.md
    python scripts/qa/consistency_check.py --root <repo>

退出码：0 = 无 P0/P1；1 = 有 P1；2 = 有 P0；3 = 脚本内部错误。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from qa_common import Report, add_common_args, finish, main_guard, rel

TOKENS_REL = "design/tokens.json"
THEME_REL = "ios/Shared/Theme/Theme.swift"
APP_THEME_REL = "ios/Shared/Theme/AppTheme.swift"

# ---------------------------------------------------------------------------
# docs/02 §5 契约：tokens.json 必须有的顶层键与关键键名
# 结构说明：键路径用 "." 连接；值为 None 表示"只要求存在，值不限"；
# 值为字面量表示还要值相等（用于 meta.minIOS 这类硬约束）。
# ---------------------------------------------------------------------------

REQUIRED_META = {
    "name": None,
    "version": None,
    "minIOS": "16.0",
    "canvas.width": 390,
    "canvas.height": 844,
}

# 浅色/深色各必须有这批颜色键（键名照 docs/02 §5）
REQUIRED_COLOR_KEYS = [
    "bg.keyboard", "bg.key", "bg.key.function", "bg.key.pressed",
    "bg.surface", "bg.surfaceElevated", "bg.glassTint",
    "text.primary", "text.secondary",
    "accent", "accent.soft",
    "separator", "success", "warning", "danger",
    "candidate.bar", "candidate.selected",
    "chip.bg", "chip.text",
    "shadow.key",
]

# typography 每个条目是 {size, weight}
REQUIRED_TYPOGRAPHY = {
    "candidate": {"size": 17, "weight": "regular"},
    "key": {"size": 22, "weight": "regular"},
    "body": {"size": 15, "weight": "regular"},
    "caption": {"size": 12, "weight": "regular"},
    "title": {"size": 20, "weight": "semibold"},
    "headline": {"size": 17, "weight": "semibold"},
    "chip": {"size": 13, "weight": "medium"},
    "result": {"size": 16, "weight": "regular"},
}

REQUIRED_SPACING = {"xs": 2, "sm": 4, "md": 8, "lg": 12, "xl": 16, "xxl": 24}
REQUIRED_RADIUS = {"key": 8, "card": 16, "capsule": 999, "sheet": 24, "chip": 14}
REQUIRED_SIZING = {
    "keyboardHeightPortrait": 258,
    "keyboardHeightLandscape": 200,
    "candidateBarHeight": 44,
    "aiBarHeight": 40,
    "keyHeight": 42,
    "keyGap": 6,
    "keyHorizontalPadding": 3,
    "aiPanelExtraHeight": 168,
    "resultExtraHeight": 180,
}
REQUIRED_MOTION = {"fast": 0.15, "normal": 0.25, "springDuration": 0.35, "springDamping": 0.82}
REQUIRED_SHADOW = {"key.y": 1, "key.blur": 0, "key.opacity": 0.18,
                   "card.y": 8, "card.blur": 24, "card.opacity": 0.12}


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def flatten(obj, prefix: str = "") -> dict[str, object]:
    """把嵌套 dict 拍平成 {a.b.c: leaf}。list 视为叶子。"""
    out: dict[str, object] = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = f"{prefix}.{k}" if prefix else str(k)
            if isinstance(v, dict):
                out.update(flatten(v, key))
            else:
                out[key] = v
    return out


def num_equal(a, b, tol: float = 1e-6) -> bool:
    try:
        return abs(float(a) - float(b)) <= tol
    except (TypeError, ValueError):
        return str(a).strip() == str(b).strip()


# 负号必须一起捕获：`shadow.keyboard.top.y = -1` 这类令牌在 Theme.swift 里写作
# `Shadow(y: -1, ...)`，若正则不认负号就会把「1」当成命中、把「-1」误报为缺失。
NUMBER_RE = re.compile(r"(?<![\w.])([+-]?\d+(?:\.\d+)?)(?![\w.])")


def number_appears(text: str, value) -> bool:
    """判断数值是否出现在 Swift 源码里（按完整数字 token 比较，避免 8 命中 80）。"""
    try:
        target = float(value)
    except (TypeError, ValueError):
        return False
    for m in NUMBER_RE.finditer(text):
        try:
            if abs(float(m.group(1)) - target) <= 1e-6:
                return True
        except ValueError:
            continue
    return False


def hex_equal_variants(hexstr: str) -> list[str]:
    """生成 hex 值的多种写法（大小写、去 #、0x 前缀），用于源码里查找。"""
    h = str(hexstr).strip()
    body = h.lstrip("#").replace("0x", "").replace("0X", "")
    variants = {h, body, f"#{body}", f"0x{body}", f"0X{body}",
                body.lower(), body.upper(), f"#{body.lower()}", f"#{body.upper()}"}
    return [v for v in variants if v]


RE_COLOR_HEX = re.compile(r"^\s*#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?\s*$")


# ---------------------------------------------------------------------------
# ① tokens → Theme.swift
# ---------------------------------------------------------------------------

def load_tokens(report: Report, root: Path) -> dict | None:
    p = root / TOKENS_REL
    if not p.is_file():
        report.warn(
            f"未找到 `{TOKENS_REL}`（由 design-lead 负责）。跳过设计令牌一致性检查，"
            "本脚本第 ①②③ 项无法执行；请在设计令牌落盘后重跑。"
        )
        report.stats["tokens"] = "缺失"
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        report.add("P0", "TOKENS-JSON", TOKENS_REL, getattr(exc, "lineno", 0),
                   f"tokens.json 不是合法 JSON：{exc.msg}", "修 JSON 语法（尾逗号/注释/引号）")
        report.stats["tokens"] = "非法"
        return None
    if not isinstance(data, dict):
        report.add("P0", "TOKENS-JSON", TOKENS_REL, 0,
                   "tokens.json 顶层不是对象（应为一个 JSON object）", "检查文件结构")
        report.stats["tokens"] = "非法"
        return None
    report.stats["tokens"] = "已加载"
    return data


def check_tokens_structure(report: Report, tokens: dict):
    """③ tokens.json 自身完整性：docs/02 §5 要求的键是否都在（缺 → P0）。"""
    flat = flatten(tokens)

    def need(prefix: str, key: str, expect, where: str):
        path = f"{prefix}.{key}" if prefix else key
        if path not in flat:
            report.add("P0", "TOKENS-KEY-MISSING", TOKENS_REL, 0,
                       f"tokens.json 缺少 {where} 键 `{path}`（docs/02 §5 契约要求）",
                       f"补 `{path}`，值参考 docs/02 §5")
            return
        if expect is not None and not num_equal(flat[path], expect) \
                and str(flat[path]).strip() != str(expect).strip():
            report.add("P1", "TOKENS-KEY-VALUE", TOKENS_REL, 0,
                       f"tokens.json 的 `{path}` = {flat[path]!r}，契约值为 {expect!r}",
                       "按 docs/02 §5 改齐（改动需同步通知 Lead 与 design-lead）")

    # 顶层键存在性
    for top in ("meta", "color", "typography", "spacing", "radius", "sizing", "motion", "shadow"):
        if top not in tokens:
            report.add("P0", "TOKENS-TOP-MISSING", TOKENS_REL, 0,
                       f"tokens.json 缺少顶层键 `{top}`（docs/02 §5 要求 8 个顶层键）",
                       "补齐 meta/color/typography/spacing/radius/sizing/motion/shadow")
    if "color" in tokens and isinstance(tokens["color"], dict):
        for scheme in ("light", "dark"):
            if scheme not in tokens["color"]:
                report.add("P0", "TOKENS-SCHEME-MISSING", TOKENS_REL, 0,
                           f"tokens.json 缺少 `color.{scheme}`（深色/浅色都要有）",
                           f"补 color.{scheme} 的 {len(REQUIRED_COLOR_KEYS)} 个颜色键")

    for k, v in REQUIRED_META.items():
        need("meta", k, v, "meta")
    for scheme in ("light", "dark"):
        for k in REQUIRED_COLOR_KEYS:
            need(f"color.{scheme}", k, None, f"color.{scheme}")
    for name, spec in REQUIRED_TYPOGRAPHY.items():
        for k, v in spec.items():
            need(f"typography.{name}", k, v, f"typography.{name}")
    for k, v in REQUIRED_SPACING.items():
        need("spacing", k, v, "spacing")
    for k, v in REQUIRED_RADIUS.items():
        need("radius", k, v, "radius")
    for k, v in REQUIRED_SIZING.items():
        need("sizing", k, v, "sizing")
    for k, v in REQUIRED_MOTION.items():
        need("motion", k, v, "motion")
    for k, v in REQUIRED_SHADOW.items():
        base, _, sub = k.partition(".")
        need(f"shadow.{base}", sub, v, f"shadow.{base}")

    # 颜色键命名重复（light/dark 键集合必须一致，否则切换深色会缺色）
    light = flatten(tokens.get("color", {}).get("light", {}))
    dark = flatten(tokens.get("color", {}).get("dark", {}))
    only_light = sorted(set(light) - set(dark))
    only_dark = sorted(set(dark) - set(light))
    for k in only_light:
        report.add("P1", "TOKENS-SCHEME-ASYMMETRY", TOKENS_REL, 0,
                   f"颜色键 `{k}` 只在 light 有、dark 缺失（切深色会缺色）", "两种模式键集合必须一致")
    for k in only_dark:
        report.add("P1", "TOKENS-SCHEME-ASYMMETRY", TOKENS_REL, 0,
                   f"颜色键 `{k}` 只在 dark 有、light 缺失", "两种模式键集合必须一致")

    report.stats["token_leaves"] = len(flat)


def check_theme_coverage(report: Report, tokens: dict, theme_text: str | None):
    """① tokens 的每个色值 / 尺寸值必须在 Theme.swift 里出现。"""
    if theme_text is None:
        report.warn(f"未找到 `{THEME_REL}`（由 ai-service 负责）。"
                    "tokens → Theme.swift 覆盖度检查跳过。")
        report.stats["theme"] = "缺失"
        return
    report.stats["theme"] = f"{theme_text.count(chr(10)) + 1} 行"

    # -- 颜色 hex --
    hex_total = 0
    hex_missing: list[tuple[str, str]] = []
    for scheme in ("light", "dark"):
        scheme_obj = tokens.get("color", {}).get(scheme, {})
        for key, val in flatten(scheme_obj).items():
            sval = str(val).strip()
            if not RE_COLOR_HEX.match(sval):
                continue  # 非 hex（比如 "clear"）
            hex_total += 1
            if not any(v in theme_text for v in hex_equal_variants(sval)):
                hex_missing.append((f"color.{scheme}.{key}", sval))
    for path, val in hex_missing:
        report.add("P1", "THEME-COLOR-MISSING", THEME_REL, find_theme_anchor(theme_text, val, "颜色层"),
                   f"tokens 色值 `{path}` = {val} 未在 Theme.swift 中出现（需逐键实现，docs/02 §4.5）",
                   "在 Theme 的颜色层补齐该键；不要在键盘里直接写 hex")
    report.stats["colors_checked"] = hex_total

    # -- 数值：typography.size / spacing / radius / sizing / motion / shadow --
    numeric_groups: list[tuple[str, dict]] = []
    typo = tokens.get("typography", {})
    typo_sizes = {}
    for name, spec in typo.items():
        if isinstance(spec, dict) and "size" in spec:
            typo_sizes[f"{name}.size"] = spec["size"]
    numeric_groups.append(("typography", typo_sizes))
    for group in ("spacing", "radius", "sizing", "motion"):
        obj = tokens.get(group, {})
        if isinstance(obj, dict):
            numeric_groups.append((group, {k: v for k, v in flatten(obj).items()
                                           if isinstance(v, (int, float))}))
    shadow_obj = tokens.get("shadow", {})
    if isinstance(shadow_obj, dict):
        numeric_groups.append(("shadow", flatten(shadow_obj)))

    num_total = 0
    num_missing: list[tuple[str, object]] = []
    for group, mapping in numeric_groups:
        for key, val in mapping.items():
            num_total += 1
            if not number_appears(theme_text, val):
                num_missing.append((f"{group}.{key}", val))
    for path, val in num_missing:
        report.add("P1", "THEME-NUM-MISSING", THEME_REL, 0,
                   f"tokens 数值 `{path}` = {val} 未在 Theme.swift 中找到"
                   "（尺寸/动效应集中定义在 Theme，禁止散落魔法数）",
                   "在 Theme 的 Sizing/Spacing/Radius/Motion 中补该常量")
    report.stats["numbers_checked"] = num_total


def find_theme_anchor(theme_text: str, needle: str, label: str) -> int:
    """在 Theme.swift 里找一个合适的行号锚点（用于报告可点击）。"""
    m = re.search(r"\benum\s+Theme\b|\bstruct\s+Theme\b", theme_text)
    if m:
        return theme_text.count("\n", 0, m.start()) + 1
    return 1


# ---------------------------------------------------------------------------
# ② 硬编码 hex / 魔法字号
# ---------------------------------------------------------------------------

RE_HARD_HEX = re.compile(r"#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b")
RE_HARD_HEX_0X = re.compile(r"\b0x([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b")
RE_SYSTEM_FONT = re.compile(r"\.font\s*\(\s*\.system\s*\(\s*size\s*:\s*([0-9]+(?:\.[0-9]+)?)")
RE_FONT_SIZE_KW = re.compile(r"\bsize\s*:\s*([0-9]+(?:\.[0-9]+)?)")


def collect_token_sizes(tokens: dict) -> set[float]:
    """收集 tokens 里所有允许的字号/尺寸数值（用于判断是否为"魔法数字"）。"""
    sizes: set[float] = set()
    typo = tokens.get("typography", {})
    for name, spec in typo.items():
        if isinstance(spec, dict) and "size" in spec:
            try:
                sizes.add(float(spec["size"]))
            except (TypeError, ValueError):
                pass
    for group in ("spacing", "radius", "sizing"):
        for k, v in flatten(tokens.get(group, {})).items():
            try:
                sizes.add(float(v))
            except (TypeError, ValueError):
                pass
    return sizes


def check_hardcoded(report: Report, root: Path, tokens: dict | None):
    """扫 App + Extension 的 SwiftUI 代码：硬编码 hex、魔法字号（→ P2）。"""
    allowed_sizes = collect_token_sizes(tokens) if tokens else set()
    ios = root / "ios"
    targets = [ios / "AIKeyboard", ios / "AIKeyboardExtension"]
    hits_hex = 0
    hits_font = 0
    checked = 0
    for base in targets:
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            relpath = rel(path, root)
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            checked += 1
            lines = text.splitlines()
            for idx, line in enumerate(lines, 1):
                stripped = line.strip()
                if stripped.startswith("//") or stripped.startswith("///"):
                    continue
                # 允许色值集中定义文件：Theme 扩展 / Color+Hex 工具（标注 // TOKEN: 或文件名含 Theme）
                allow = "// TOKEN:" in line or "// TOKEN-OK" in line or "Theme.swift" in relpath
                for m in list(RE_HARD_HEX.finditer(line)) + list(RE_HARD_HEX_0X.finditer(line)):
                    if allow:
                        continue
                    if re.match(r"#[0-9A-Fa-f]{3}\b", m.group(0)) and len(m.group(0)) == 4:
                        continue
                    hits_hex += 1
                    report.add("P2", "UI-HARDCODED-COLOR", relpath, idx,
                               f"硬编码色值 `{m.group(0)}`（应使用 Theme 颜色）",
                               "改为 Theme.xxx；确需保留请加 `// TOKEN:` 注释说明")
                for m in RE_SYSTEM_FONT.finditer(line):
                    try:
                        size = float(m.group(1))
                    except ValueError:
                        continue
                    if allowed_sizes and size in allowed_sizes:
                        continue
                    hits_font += 1
                    report.add("P2", "UI-MAGIC-FONT", relpath, idx,
                               f"魔法字号 `.font(.system(size: {m.group(1)}))`（不在 tokens typography 里）",
                               "改用 Theme.fontXxx / AppFont，字号统一由设计令牌驱动")
    report.stats["app_ext_swift"] = checked
    report.stats["hardcoded_hex"] = hits_hex
    report.stats["magic_font"] = hits_font


# ---------------------------------------------------------------------------
# ④ 主题预设一致性（design/05 §6）
# ---------------------------------------------------------------------------

# 一套主题的 6 个浅色字段（与 tokens `theme.presets.<id>` 一一对应）。
# 注意：`name` / `brand` 是文字，不参与颜色比对；深色值由 AppTheme 按 §1.2 推导。
THEME_COLOR_FIELDS = ["accent", "tint", "tint2", "deep", "sub", "canvas"]

# 在 AppTheme.swift 里定位 `case .ink:` ... `HexPalette(` ... `)` 这一段
RE_THEME_CASE = re.compile(r"case\s+\.([A-Za-z_][A-Za-z0-9_]*)\s*:")
RE_THEME_FIELD = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\"(#?[0-9A-Fa-f]{6,8})\""
)
RE_HEX_BODY = re.compile(r"^#?([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?$")


def normalize_hex(value: str) -> str | None:
    """把 `#RRGGBB` / `RRGGBBAA` / `0xRRGGBB` 归一成大写 `RRGGBB(AA)`，非法返回 None。"""
    if value is None:
        return None
    text = str(value).strip()
    m = RE_HEX_BODY.match(text)
    if not m:
        return None
    body = m.group(1).upper()
    alpha = m.group(2)
    return body + (alpha.upper() if alpha else "")


def parse_app_theme_presets(app_theme_text: str) -> dict[str, dict[str, str]]:
    """从 AppTheme.swift 里解析每个预设的 12 个 hex 字面量。

    期望写法（每个预设一个 `case .xxx:` + 一个 `HexPalette(...)`）：
        case .ink:
            return HexPalette(
                accent: "101010", accentDark: "2D2D2D",
                tint: "F7F7F5", tintDark: "2D2D2D38",
                ... 6 组
            )

    返回：`{"ink": {"accent": "101010", "accentDark": "2D2D2D", ...}, ...}`
    解析不到的预设不会出现在返回值里（由调用方报 P0）。
    """
    out: dict[str, dict[str, str]] = {}
    matches = list(RE_THEME_CASE.finditer(app_theme_text))
    for idx, m in enumerate(matches):
        case_name = m.group(1)
        start = m.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(app_theme_text)
        block = app_theme_text[start:end]
        if "HexPalette" not in block:
            continue  # 不是主题配色 switch（比如 Preset 的 displayName switch）
        fields = {name: val for name, val in RE_THEME_FIELD.findall(block)}
        if not fields:
            continue
        # 同名 case 只保留第一处（displayName / brandNote 的 switch 在前，但那里没有 hex 字面量）
        out.setdefault(case_name, fields)
    return out


def check_theme_presets(report: Report, tokens: dict | None, root: Path):
    """④ design/05 §6：tokens.theme.presets 与 AppTheme.swift 逐项比对。

    - tokens 缺 `theme` 组 → P0
    - 某预设 Swift 里找不到（或 Swift 有 tokens 没有）→ P0
    - 浅色 hex 不一致 → P1
    - 深色 hex 缺失 / 不可解析 → P2
    """
    app_theme_path = root / APP_THEME_REL
    if tokens is None:
        return
    theme_obj = tokens.get("theme")
    if not isinstance(theme_obj, dict):
        report.add("P0", "THEME-GROUP-MISSING", TOKENS_REL, 0,
                   "tokens.json 缺少顶层 `theme` 组（design/05 §6 要求 6 套主题 × 6 色 + mascot）",
                   "按 design/05 §1 的表格补 `theme.presets` 与 `theme.mascot`")
        report.stats["theme_presets"] = "缺失"
        return

    presets = theme_obj.get("presets")
    if not isinstance(presets, dict) or not presets:
        report.add("P0", "THEME-PRESETS-MISSING", TOKENS_REL, 0,
                   "tokens.json 的 `theme.presets` 缺失或为空（应有 6 套：ink/coral/indigo/violet/sky/pine）",
                   "按 design/05 §1 补 6 套预设，每套 6 个色值 + name + brand")
        report.stats["theme_presets"] = "缺失"
        return

    if not app_theme_path.is_file():
        report.add("P0", "APPTHEME-MISSING", APP_THEME_REL, 0,
                   f"未找到 `{APP_THEME_REL}`（由 ai-service 负责）",
                   "按 design/05 §2.1 创建 AppTheme.swift")
        report.stats["theme_presets"] = "缺失"
        return

    app_theme_text = app_theme_path.read_text(encoding="utf-8", errors="replace")
    swift_presets = parse_app_theme_presets(app_theme_text)

    # -- mascot 数值（design/05 §3.2）：只校验存在与是数字，不比对具体值 --
    mascot = theme_obj.get("mascot")
    if not isinstance(mascot, dict):
        report.add("P0", "THEME-MASCOT-MISSING", TOKENS_REL, 0,
                   "tokens.json 缺少 `theme.mascot`（8 个符号 + 8 个尺寸数值，design/05 §3）",
                   "按 design/05 §3.2 补 mascot 组")
    else:
        for key in ("visualSizePortrait", "visualSizeLandscape",
                    "cornerCellWidthPortrait", "cornerCellWidthLandscape",
                    "cornerRightInsetPortrait", "cornerRightInsetLandscape",
                    "gapToReturnKeyPortrait", "gapToReturnKeyLandscape"):
            if key not in mascot:
                report.add("P1", "THEME-MASCOT-KEY", TOKENS_REL, 0,
                           f"tokens.json 的 `theme.mascot.{key}` 缺失（design/05 §3.2）",
                           "补该尺寸键；键盘侧 KMMascot 布局依赖它")
        symbols = mascot.get("symbols")
        if not isinstance(symbols, list) or len(symbols) != 8:
            report.add("P1", "THEME-MASCOT-SYMBOLS", TOKENS_REL, 0,
                       f"tokens.json 的 `theme.mascot.symbols` 应为 8 个符号，实际 "
                       f"{len(symbols) if isinstance(symbols, list) else '非数组'} 个",
                       "按 design/05 §3.1 补 whale/whale2/spark/star/moon/leaf/dot/chibi")

    # -- 预设集合对齐 --
    tokens_ids = set(presets.keys())
    swift_ids = set(swift_presets.keys())
    for pid in sorted(tokens_ids - swift_ids):
        report.add("P0", "THEME-PRESET-NOT-IN-SWIFT", APP_THEME_REL, 0,
                   f"tokens 里有主题预设 `{pid}`，但 AppTheme.swift 里找不到对应 "
                   f"`case .{pid}:` + `HexPalette(...)`",
                   f"在 `AppTheme.Preset` 加 `case {pid}` 并在 palette(for:) 补 12 个 hex")
    for pid in sorted(swift_ids - tokens_ids):
        report.add("P0", "THEME-PRESET-NOT-IN-TOKENS", TOKENS_REL, 0,
                   f"AppTheme.swift 里有主题预设 `{pid}`，但 tokens.json `theme.presets` 没有",
                   f"在 tokens.json 补 `theme.presets.{pid}`（6 个浅色色值 + name + brand）")

    # -- 逐字段比对 --
    checked = 0
    mismatch = 0
    dark_ok = 0
    for pid in sorted(tokens_ids & swift_ids):
        spec = presets.get(pid)
        if not isinstance(spec, dict):
            report.add("P0", "THEME-PRESET-MALFORMED", TOKENS_REL, 0,
                       f"tokens.json 的 `theme.presets.{pid}` 不是对象",
                       "应为 {name, brand, accent, tint, tint2, deep, sub, canvas}")
            continue
        swift_fields = swift_presets[pid]
        for field in THEME_COLOR_FIELDS:
            token_hex = normalize_hex(spec.get(field))
            if token_hex is None:
                report.add("P0", "THEME-TOKEN-HEX", TOKENS_REL, 0,
                           f"tokens.json 的 `theme.presets.{pid}.{field}` 缺失或不是合法 hex"
                           f"（实际 {spec.get(field)!r}）",
                           "补 `#RRGGBB` 格式的色值（design/05 §1 表格）")
                continue
            swift_hex = normalize_hex(swift_fields.get(field))
            checked += 1
            if swift_hex is None:
                report.add("P0", "THEME-SWIFT-HEX", APP_THEME_REL, 0,
                           f"AppTheme.swift 里预设 `{pid}` 的 `{field}` 字段缺失或不可解析"
                           f"（实际 {swift_fields.get(field)!r}）",
                           f"在 palette(for: .{pid}) 的 HexPalette 补 `{field}: \"{token_hex}\"`")
                continue
            if swift_hex != token_hex:
                mismatch += 1
                report.add("P1", "THEME-HEX-MISMATCH", APP_THEME_REL, 0,
                           f"`{pid}.{field}`: tokens=#{token_hex} swift=#{swift_hex}"
                           "（design/05 §6 要求十六进制字面量逐项一致）",
                           "改 AppTheme.swift 的浅色值对齐 tokens；如需改配色请先改 tokens.json")
        # 深色值只校验「存在且可解析」（值由 §1.2 推导，不在 tokens 登记）
        for field in THEME_COLOR_FIELDS:
            dark_field = field + "Dark"
            raw = swift_fields.get(dark_field)
            if normalize_hex(raw) is None:
                report.add("P2", "THEME-DARK-HEX", APP_THEME_REL, 0,
                           f"预设 `{pid}` 的 `{dark_field}` 缺失或不是合法 hex（实际 {raw!r}）",
                           "按 design/05 §1.2 的混色算式补深色值（accent 混白 12% / canvas #1C1C1E / tint 叠 22% alpha）")
            else:
                dark_ok += 1

    report.stats["theme_presets"] = f"{len(tokens_ids & swift_ids)} 套"
    report.stats["theme_colors_checked"] = checked
    report.stats["theme_colors_mismatch"] = mismatch
    report.stats["theme_dark_colors"] = dark_ok


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def run(root: Path) -> Report:
    report = Report("墨语 iOS 输入法 · 设计令牌一致性校验（consistency_check.py）", root)

    tokens = load_tokens(report, root)
    theme_path = root / THEME_REL
    theme_text = None
    if theme_path.is_file():
        theme_text = theme_path.read_text(encoding="utf-8", errors="replace")
    else:
        theme_text = None

    if tokens is not None:
        check_tokens_structure(report, tokens)
        check_theme_coverage(report, tokens, theme_text)
        check_theme_presets(report, tokens, root)
    check_hardcoded(report, root, tokens)

    # 设计文档是否落盘（提示）。注意：design-lead 最终交付文件名是
    # `design/03-设计与交互规范.md`（lead 确认过），旧名 `03-视觉设计规范.md` 仅作兼容。
    for extra in ("design/03-设计与交互规范.md", "design/appicon"):
        if not (root / extra).exists():
            report.warn(f"`{extra}` 尚未落盘（design-lead 负责，非阻断）")

    return report


@main_guard
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="墨语 iOS 输入法 · 设计令牌一致性校验")
    add_common_args(ap)
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    report = run(root)
    return finish(report, args)


if __name__ == "__main__":
    sys.exit(main())
