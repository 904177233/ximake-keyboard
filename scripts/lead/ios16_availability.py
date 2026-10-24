#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS 17+ / macOS-only API 粗查（Lead 专用）。

工程部署目标是 **iOS 16.0**（ios/Config/Base.xcconfig 的 IPHONEOS_DEPLOYMENT_TARGET）。
在 Windows 上无法编译，所以「用了 iOS 17 才有的 SwiftUI/UIKit API」这类错误只有到 CI 才炸。
本脚本按**已知的 iOS 17+ 符号清单**扫描 ios/**.swift，命中即报。

清单来源：Apple 文档标注「iOS 17.0+」的高频 SwiftUI/UIKit API。只收**确定**在 iOS 16 上不可用的，
避免误报（有 `if #available` / `@available` 包裹的会降级为 INFO）。

用法：python scripts/lead/ios16_availability.py [--verbose]
退出码：0=无越界 API；1=有。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios"

# (符号/正则, 引入版本, 说明)
BANNED: list[tuple[str, str, str]] = [
    # —— iOS 17 SwiftUI ——
    (r"\.scrollTargetBehavior\b", "iOS 17", "ScrollView 分页行为"),
    (r"\.scrollTargetLayout\b", "iOS 17", "ScrollView 分页布局"),
    (r"\.defaultScrollAnchor\b", "iOS 17", "ScrollView 默认锚点"),
    (r"\.scrollPosition\(", "iOS 17", "ScrollView 位置绑定"),
    (r"\.containerRelativeFrame\(", "iOS 17", "容器相对尺寸"),
    (r"\.contentMargins\(", "iOS 17", "内容边距"),
    (r"\.symbolEffect\(", "iOS 17", "SF Symbols 动效"),
    (r"\.contentTransition\(", "iOS 17", "内容过渡"),
    (r"\.scrollBounceBehavior\(", "iOS 16.4", "ScrollView 回弹行为"),
    (r"\.scrollIndicatorsFlash\(", "iOS 17", "滚动指示条闪烁"),
    (r"\.geometryGroup\(", "iOS 17", "几何分组"),
    (r"\.visualEffect\(", "iOS 17", "视觉特效"),
    (r"\.onChange\(of:[^)]*\)\s*\{\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s*in", "iOS 17", "onChange 双参闭包"),
    (r"\.bold\(\)\s*$", "iOS 16 ok", ""),  # 占位，不报
    (r"\bObservable\b(?!\s*:\s*ObservableObject)", "iOS 17", "@Observable 宏"),
    (r"@Observable\b", "iOS 17", "Observation 框架"),
    (r"\.annotationTitles\(", "iOS 17", ""),
    (r"\bContentUnavailableView\b", "iOS 17", "空态视图"),
    (r"\.rect\(cornerRadius:", "iOS 17", "Shape.rect(cornerRadius:)"),
    (r"\.rect\(topLeadingRadius:", "iOS 17", "Shape.rect 多角"),
    (r"\.fill\(\.shadow\(", "iOS 17", "阴影填充"),
    (r"\.strokeBorder\([^)]*lineWidth:[^)]*\)\s*\.shadow", "iOS 17", ""),
    (r"\.inspector\(", "iOS 17", "检查器面板"),
    (r"\.presentationBackground\(", "iOS 16.4", "sheet 背景"),
    (r"\.presentationCornerRadius\(", "iOS 16.4", "sheet 圆角"),
    (r"\.presentationDetents\([^)]*selection:", "iOS 16.4", "detent 选择"),
    (r"\.toolbarBackground\(", "iOS 16 ok", ""),
    (r"\.backgroundStyle\(", "iOS 16 ok", ""),
    (r"\.foregroundStyle\(", "iOS 15 ok", ""),
    (r"\bGrid\s*\{", "iOS 16 ok", ""),
    (r"\.gridCellColumns\(", "iOS 16 ok", ""),
    (r"#Preview\b", "Xcode 15+", "预览宏（需 Xcode 15，可用 PreviewProvider 替代）"),
    (r"\.matchedTransitionSource\(", "iOS 18", "zoom 转场"),
    (r"\.navigationTransition\(", "iOS 18", "导航转场"),
    (r"\bMeshGradient\b", "iOS 18", "网格渐变"),
    (r"\.textRenderer\(", "iOS 18", ""),
    # —— UIKit ——
    (r"\bUIViewController\.requestInputViewHeightUpdate\b", "非公开", "键盘高度私有 API"),
    (r"\.traitOverrides\b", "iOS 17", ""),
    (r"\bUITraitChangeObservable\b", "iOS 17", ""),
    # —— 其它 ——
    (r"\bTipKit\b", "iOS 17", "TipKit"),
    (r"\bSwiftData\b", "iOS 17", "SwiftData"),
]

# 用于判定的「占位/无效」条目：说明为空且版本含 "ok" 的跳过
REAL_BANNED = [(rx, ver, note) for rx, ver, note in BANNED if note]


def strip_source(text: str) -> str:
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            out.append("  ")
            i += 2
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    out.append("  ")
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    out.append("  ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            continue
        if ch == '"':
            if text.startswith('"""', i):
                out.append("   ")
                i += 3
                while i < n and not text.startswith('"""', i):
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
                if i < n:
                    out.append("   ")
                    i += 3
                continue
            out.append(" ")
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append(" ")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def main() -> int:
    verbose = "--verbose" in sys.argv
    compiled = [(re.compile(rx), ver, note, rx) for rx, ver, note in REAL_BANNED]
    findings: list[tuple[str, int, str, str, str, bool]] = []

    for p in sorted(IOS.rglob("*.swift")):
        rel = p.relative_to(ROOT).as_posix()
        raw = p.read_text(encoding="utf-8", errors="replace")
        code = strip_source(raw)
        lines = code.splitlines()
        for rx, ver, note, display in compiled:
            for lineno, line in enumerate(lines, 1):
                if rx.search(line):
                    # 该行或前后 3 行内是否有 @available / #available 守卫
                    ctx = "\n".join(lines[max(0, lineno - 4): lineno])
                    guarded = ("#available" in ctx) or ("@available" in ctx)
                    findings.append((rel, lineno, ver, note, display, guarded))

    unguarded = [f for f in findings if not f[5]]
    guarded = [f for f in findings if f[5]]

    if verbose:
        for rel, lineno, ver, note, display, g in unguarded:
            print(f"[P1] {rel}:{lineno}  {display}  ({ver} · {note})")
        for rel, lineno, ver, note, display, g in guarded:
            print(f"[INFO] {rel}:{lineno}  {display}  ({ver}) —— 有 available 守卫")

    print(f"iOS 16 越界 API：未守卫 {len(unguarded)} 条 / 已守卫 {len(guarded)} 条")
    return 0 if not unguarded else 1


if __name__ == "__main__":
    raise SystemExit(main())
