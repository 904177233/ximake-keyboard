#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Theme 命名空间引用核对（只读，Lead 专用，不参与构建）。

做什么：解析 `ios/Shared/Theme/Theme.swift` 里的**全部**命名空间容器
（`enum` / `struct` / `class`，含嵌套，例如 `Theme { enum Sizing { ... } }`）
以及每个容器第一层的 `static let/var/func` 与 `case` 成员，形成
`{容器路径: 成员集合}`；然后扫描全仓 `Theme.<...>.<member>` 形式的引用，
校验「最后的成员名」在「它所在的容器」中确实存在。

为什么需要：Windows 上跑不了 swiftc，而 `Theme.Sizing.sectionGap` 这类
「命名空间写错」的错误（成员实际在 `Theme.Spacing` 上）必然是编译错误，
且靠普通字符串搜索很难系统性地发现。历史上真的发生过一次。

局限：不跟进 `typealias`、不处理动态成员查找；`Theme.Color.accent.opacity(0.5)`
这类链式调用只校验到 `Theme.Color.accent` 这一段。

用法：
    python scripts/lead/theme_refs.py            # 摘要
    python scripts/lead/theme_refs.py --verbose  # 列出全部可疑项位置

退出码：0 = 全部可解析；1 = 有可疑项。
"""

from __future__ import annotations

import pathlib
import re
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[2]
THEME = ROOT / "ios" / "Shared" / "Theme" / "Theme.swift"

CONTAINER = re.compile(
    r"^[ \t]*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|indirect\s+)*"
    r"(?:enum|struct|class)\s+([A-Za-z_]\w*)"
)
MEMBER = re.compile(
    r"^[ \t]*(?:public\s+|internal\s+|private\s+|fileprivate\s+|nonisolated\s+|"
    r"@\w+\s+)*static\s+(?:let|var|func)\s+([A-Za-z_]\w*)"
)
CASE = re.compile(
    r"^[ \t]*(?:public\s+|internal\s+|private\s+|fileprivate\s+)*case\s+([A-Za-z_]\w*)"
)
# 引用：Theme(.Namespace)*.member  —— 取最后两段做校验
REF = re.compile(r"\bTheme((?:\.(?:[A-Za-z_]\w*))+)")

# 成员解析完之后，可能跟着的「实例属性 / 方法」名（链式调用）。
# 例如 Theme.Shadow.card.blur —— card 是 Theme.Shadow 的 static 成员，
# blur 是它返回的 struct 的实例属性，不是 Theme 命名空间成员，无需校验。
CHAIN_AFTER = {
    "opacity", "weight", "design", "font", "size", "padding", "frame",
    "cornerRadius", "shadow", "foregroundStyle", "foregroundColor",
    "background", "scale", "uppercased", "lowercased", "hex", "value",
    "cgColor", "uiColor", "blendMode", "clipShape", "stroke", "lineLimit",
    "baselineOffset", "tracking", "kerning", "lineSpacing",
    # 阴影 / 圆角 / 尺寸这类 struct 的实例属性
    "blur", "x", "y", "radius", "color", "offset", "spread", "width", "height",
    "top", "bottom", "leading", "trailing", "horizontal", "vertical",
}


def strip_comments(text: str) -> str:
    """去掉 // 与 /* */ 注释，保留行结构。"""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif ch == "/" and i + 1 < n and text[i + 1] == "*":
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def parse_namespaces() -> dict[str, set[str]]:
    """返回 {'Theme.Sizing': {'keyGap', ...}, 'Theme': {...}, ...}。"""
    text = strip_comments(THEME.read_text(encoding="utf-8"))
    spaces: dict[str, set[str]] = defaultdict(set)

    stack: list[tuple[str, int]] = []  # (容器名, 进入时的 brace_depth)
    brace_depth = 0

    for raw in text.splitlines():
        m = CONTAINER.match(raw)
        if m and raw.count("{") > 0:
            path = ".".join([s[0] for s in stack] + [m.group(1)])
            spaces[path]  # 确保键存在
            stack.append((m.group(1), brace_depth))
            brace_depth += raw.count("{") - raw.count("}")
            continue

        if stack:
            top_name, top_depth = stack[-1]
            if brace_depth == top_depth + 1:
                mm = MEMBER.match(raw) or CASE.match(raw)
                if mm:
                    spaces[".".join(s[0] for s in stack)].add(mm.group(1))

        brace_depth += raw.count("{") - raw.count("}")
        while stack and brace_depth <= stack[-1][1]:
            stack.pop()

    return dict(spaces)


def main() -> int:
    if not THEME.is_file():
        print(f"[ERROR] 找不到 {THEME}")
        return 1

    spaces = parse_namespaces()
    print("=" * 78)
    print("Theme 命名空间引用核对（只读）")
    print("=" * 78)
    print(f"命名空间（含嵌套）：{len(spaces)} 个")
    for name, members in sorted(spaces.items()):
        print(f"  {name:28s} {len(members):3d} 个成员")

    suspicious: dict[tuple[str, str], list[str]] = defaultdict(list)
    total_refs = 0
    for path in sorted((ROOT / "ios").rglob("*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        text = strip_comments(path.read_text(encoding="utf-8"))
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("///") or stripped.startswith("//!"):
                continue
            for m in REF.finditer(line):
                segments = m.group(1).strip(".").split(".")
                total_refs += 1
                if not segments or segments == [""]:
                    continue

                # 从最长的候选容器往回退：Theme.A.B.C → 先试 Theme.A.B，再试 Theme.A
                # 单段 Theme.foo → 容器就是 Theme 本身
                container = None
                member = None
                for k in range(len(segments) - 1, 0, -1):
                    cand = "Theme." + ".".join(segments[:k])
                    if cand in spaces:
                        container = cand
                        member = segments[k]
                        break
                if container is None and "Theme" in spaces:
                    container = "Theme"
                    member = segments[0]
                if container is None:
                    # 容器本身不存在 → 也是问题
                    suspicious[("Theme." + segments[0], "<容器不存在>")].append(
                        f"{rel}:{lineno}"
                    )
                    continue
                if member in CHAIN_AFTER:
                    continue
                if member not in spaces[container]:
                    suspicious[(container, member)].append(f"{rel}:{lineno}")

    print()
    print(f"`Theme.*` 引用总数 : {total_refs}")
    print(f"可疑项             : {len(suspicious)}")
    verbose = "--verbose" in sys.argv
    for (container, member), locs in sorted(suspicious.items()):
        print(f"  [P1] {container}.{member}  x{len(locs)}")
        for loc in (locs if verbose else locs[:3]):
            print(f"        {loc}")
        if not verbose and len(locs) > 3:
            print(f"        … 另 {len(locs) - 3} 处")
    print("-" * 78)

    if suspicious:
        print("结论: 有可疑引用（可能是命名空间写错，Swift 会报 cannot find 'X' in scope）")
        return 1
    print("结论: 通过（全部可解析）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
