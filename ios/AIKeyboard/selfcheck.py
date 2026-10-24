#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语 · 宿主 App（ios/AIKeyboard）自用静态自查脚本。

本脚本只检查 `ios/AIKeyboard/` 这一个模块（宿主 App UI 的写入范围），
用来在没有 Xcode / swift 编译器的 Windows 环境下兜住最常见的低级错误。
它与 `scripts/qa/` 下的仓库级检查互补：那两套脚本按"整个仓库"扫描，
这里额外覆盖 App 层特有的约束（Theme 符号是否真的存在、AppMetrics 成员
是否都声明过、`.ultraThinMaterial` 是否只在 GlassSurface 里出现等）。

用法：
    python ios/AIKeyboard/selfcheck.py          # 输出问题清单，退出码 0/1
    python ios/AIKeyboard/selfcheck.py -v       # 同时打印每个文件的通过情况

检查项（P0 = 一定编译不过 / 明确违反契约，P1 = 很可能出问题，P2 = 风格建议）：
    P0  BALANCED        括号 / 花括号明显不平衡
    P0  DUP-TYPE        同目录或跨目录出现同名类型定义（Swift 会 invalid redeclaration）
    P0  UNDEF-SYMBOL    引用了 Theme.* / AppMetrics.* 里不存在的成员
    P0  BANNED-API      使用了 iOS 17+ 专属 API 或 try! / as! / fatalError
    P0  MISSING-IMPORT  用了 SwiftUI 类型却没有 import SwiftUI
    P1  FILE-TOO-LONG   单文件超过 docs/02 §3.7 的 600 行上限
    P1  GLASS-LEAK      在 GlassSurface.swift 之外直接使用 .ultraThinMaterial
    P2  HEADER          文件开头缺少「模块职责」注释块
    P2  CRLF / BOM      换行或编码不规范
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from typing import Dict, List, Set, Tuple

MODULE_ROOT = os.path.dirname(os.path.abspath(__file__))
MAX_LINES = 600

# ---------------------------------------------------------------------------
# 规则表
# ---------------------------------------------------------------------------

# iOS 17+ 专属 API（工程下限 iOS 16，出现即 P0）
BANNED_API_PATTERNS: List[Tuple[str, str]] = [
    (r"@Observable\b", "iOS 17 的 @Observable（用 ObservableObject）"),
    (r"\bContentUnavailableView\b", "iOS 17 的 ContentUnavailableView（用 EmptyState）"),
    (r"\.scrollTargetBehavior\s*\(", "iOS 17 的 .scrollTargetBehavior"),
    (r"\.scrollPosition\s*\(", "iOS 17 的 .scrollPosition"),
    (r"\.symbolEffect\s*\(", "iOS 17 的 .symbolEffect"),
    (r"\bMeshGradient\b", "iOS 18 的 MeshGradient"),
    (r"\.containerRelativeFrame\s*\(", "iOS 17 的 .containerRelativeFrame"),
    (r"\.onScrollGeometryChange\s*\(", "iOS 18 的 .onScrollGeometryChange"),
    (r"\.rect\(cornerRadius", "iOS 17 的 .rect(cornerRadius:)（用 RoundedRectangle）"),
    (r"\.presentationBackground\s*\(", "iOS 16.4+ 的 .presentationBackground"),
    (r"\btry!\b", "禁止 try!（用 do/catch 或 try?）"),
    (r"\bas!\s", "禁止 as!（用 as? + guard）"),
    (r"\bfatalError\s*\(", "禁止 fatalError"),
]

# 硬编码颜色（颜色/字号必须来自 Theme）
HARDCODED_COLOR_PATTERNS: List[Tuple[str, str]] = [
    (r"Color\(hex\s*:", "硬编码 hex 颜色（应用 Theme.*）"),
    (r"#colorLiteral", "硬编码 colorLiteral"),
    (r"Color\.black\b", "深色模式会脏的 Color.black（用 Theme.textPrimary）"),
    (r"Color\.white\b", "深色模式会脏的 Color.white（用 Theme.textOnAccent）"),
    (r"UIColor\(red\s*:", "硬编码 RGB 颜色"),
]

# 主 App 域不允许写死字号（键盘域组件除外，本模块就是主 App 域）
MAGIC_FONT_PATTERN = r"\.font\(\.system\(size:\s*[0-9]"

DECL_KEYWORDS = ("struct", "enum", "class", "protocol", "typealias")


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def read_text(path: str) -> str:
    with open(path, "rb") as handle:
        raw = handle.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        return "\ufeff" + raw[3:].decode("utf-8", errors="replace")
    return raw.decode("utf-8", errors="replace")


def swift_files(root: str) -> List[str]:
    found: List[str] = []
    for base, _dirs, names in os.walk(root):
        for name in names:
            if name.endswith(".swift"):
                found.append(os.path.join(base, name))
    return sorted(found)


def strip_comments_and_strings(source: str) -> str:
    """去掉注释与字符串字面量，避免把文案/注释当成代码检查。"""
    out: List[str] = []
    i = 0
    length = len(source)
    in_block = False
    in_line = False
    in_string = False
    triple = False
    while i < length:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < length else ""
        if in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_line:
            if ch == "\n":
                in_line = False
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue
        if in_string:
            if triple:
                if source[i : i + 3] == '"""':
                    in_string = False
                    triple = False
                    i += 3
                    continue
                out.append("\n" if ch == "\n" else " ")
                i += 1
                continue
            if ch == "\\":
                out.append(" ")
                if i + 1 < length:
                    out.append(" ")
                i += 2
                continue
            if ch == '"':
                in_string = False
                i += 1
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        if source[i : i + 3] == '"""':
            in_string = True
            triple = True
            i += 3
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def collect_declarations(root: str) -> Dict[str, List[Tuple[str, int, str]]]:
    """收集**顶层**类型声明，返回 {类型名: [(相对路径, 行号, 种类)]}。

    只统计顶格声明的类型：Swift 允许不同类型的嵌套枚举同名
    （例如 `PillChip.Style` 与 `SurfaceCard.Style`），只看缩进为 0 的行
    才不会把合法的嵌套类型当成重复定义。
    """
    result: Dict[str, List[Tuple[str, int, str]]] = {}
    pattern = re.compile(
        r"^(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+)*"
        r"(struct|enum|class|protocol|typealias)\s+(\w+)"
    )
    for path in swift_files(root):
        rel = os.path.relpath(path, root)
        for index, line in enumerate(read_text(path).splitlines(), start=1):
            match = pattern.match(line)
            if not match:
                continue
            kind, name = match.group(1), match.group(2)
            result.setdefault(name, []).append((rel, index, kind))
    return result


def collect_theme_members(theme_path: str) -> Set[str]:
    """从 Theme.swift 收集可用成员，返回形如 `accent` / `Spacing.xl` 的集合。"""
    members: Set[str] = set()
    current_container = "Theme"
    container_pattern = re.compile(r"^\s*(?:public\s+)?(?:enum|struct|extension)\s+(\w+)")
    member_pattern = re.compile(r"^\s*(?:public\s+)?static\s+(?:let|var)\s+(\w+)")
    for line in read_text(theme_path).splitlines():
        container = container_pattern.match(line)
        if container:
            current_container = container.group(1)
            continue
        member = member_pattern.match(line)
        if member:
            name = member.group(1)
            members.add(name if current_container == "Theme" else f"{current_container}.{name}")
    return members


def resolve_theme(member: str, known: Set[str]) -> bool:
    """`accent.opacity` / `fontTitle.weight` / `Shadow.card.y` 这类后缀调用要逐级回退。"""
    candidate = member
    while True:
        if candidate in known:
            return True
        if "." not in candidate:
            return False
        candidate = candidate.rsplit(".", 1)[0]


def collect_appmetrics_members(metrics_path: str) -> Set[str]:
    members: Set[str] = set()
    pattern = re.compile(r"^\s*(?:public\s+)?static\s+(?:let|var)\s+(\w+)")
    for line in read_text(metrics_path).splitlines():
        match = pattern.match(line)
        if match:
            members.add(match.group(1))
    return members


def brace_balance(source: str) -> bool:
    code = strip_comments_and_strings(source)
    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {value: key for key, value in pairs.items()}
    stack: List[str] = []
    for ch in code:
        if ch in pairs:
            stack.append(ch)
        elif ch in closers:
            if not stack or stack[-1] != closers[ch]:
                return False
            stack.pop()
    return not stack


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="ios/AIKeyboard 自用静态自查")
    parser.add_argument("-v", "--verbose", action="store_true", help="打印每个文件的检查结果")
    parser.add_argument("--max-lines", type=int, default=MAX_LINES, help="单文件行数上限")
    args = parser.parse_args()

    root = MODULE_ROOT
    repo_root = os.path.abspath(os.path.join(root, "..", ".."))
    theme_path = os.path.join(repo_root, "ios", "Shared", "Theme", "Theme.swift")
    metrics_path = os.path.join(root, "Support", "AppMetrics.swift")

    files = swift_files(root)
    findings: List[Tuple[str, str, str, str]] = []  # (级别, 规则, 位置, 说明)

    if not files:
        print("没有找到任何 .swift 文件，检查路径是否指向 ios/AIKeyboard。")
        return 1

    theme_known: Set[str] = collect_theme_members(theme_path) if os.path.exists(theme_path) else set()
    metrics_known: Set[str] = collect_appmetrics_members(metrics_path) if os.path.exists(metrics_path) else set()

    declarations = collect_declarations(root)

    for path in files:
        rel = os.path.relpath(path, root).replace("\\", "/")
        source = read_text(path)
        code = strip_comments_and_strings(source)
        lines = source.splitlines()
        line_count = len(lines)

        # P0 括号平衡
        if not brace_balance(source):
            findings.append(("P0", "BALANCED", rel, "括号/花括号不平衡"))

        # P0 禁用 API
        for pattern, reason in BANNED_API_PATTERNS:
            for match in re.finditer(pattern, code):
                line_no = code[: match.start()].count("\n") + 1
                findings.append(("P0", "BANNED-API", f"{rel}:{line_no}", reason))

        # P0 硬编码颜色
        for pattern, reason in HARDCODED_COLOR_PATTERNS:
            for match in re.finditer(pattern, code):
                line_no = code[: match.start()].count("\n") + 1
                findings.append(("P0", "HARDCODED-COLOR", f"{rel}:{line_no}", reason))

        # P1 写死字号（GlassSurface / 组件里允许 Theme 组合，仍提示）
        for match in re.finditer(MAGIC_FONT_PATTERN, code):
            line_no = code[: match.start()].count("\n") + 1
            findings.append(("P1", "MAGIC-FONT", f"{rel}:{line_no}", "写死字号，应改用 AppFont / Theme.font*"))

        # P0 引用不存在的 Theme 成员
        if theme_known:
            for match in re.finditer(r"\bTheme\.([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)", code):
                member = match.group(1)
                if member in theme_known:
                    continue
                if resolve_theme(member, theme_known):
                    continue
                # Shadow.xxx.y 这类三层结构
                parts = member.split(".")
                if len(parts) >= 3 and resolve_theme(".".join(parts[:2]), theme_known):
                    continue
                line_no = code[: match.start()].count("\n") + 1
                findings.append(("P0", "UNDEF-SYMBOL", f"{rel}:{line_no}", f"Theme.{member} 不存在"))

        # P0 引用不存在的 AppMetrics 成员
        if metrics_known:
            for match in re.finditer(r"\bAppMetrics\.([A-Za-z_]\w*)", code):
                member = match.group(1)
                if member not in metrics_known:
                    line_no = code[: match.start()].count("\n") + 1
                    findings.append(("P0", "UNDEF-SYMBOL", f"{rel}:{line_no}", f"AppMetrics.{member} 不存在"))

        # P0 缺 import SwiftUI
        if re.search(r"\bsome View\b|\bView\b\s*\{|\bViewBuilder\b|\bColor\b|\bFont\b", code):
            if "import SwiftUI" not in source:
                findings.append(("P0", "MISSING-IMPORT", rel, "使用了 SwiftUI 类型但没有 import SwiftUI"))

        # P1 文件过长
        if line_count > args.max_lines:
            findings.append(("P1", "FILE-TOO-LONG", rel, f"{line_count} 行（上限 {args.max_lines}）"))

        # P1 glass 泄漏
        if ".ultraThinMaterial" in code and os.path.basename(rel) != "GlassSurface.swift":
            findings.append(("P1", "GLASS-LEAK", rel, "只有 GlassSurface 可以直用 .ultraThinMaterial"))

        # P2 文件头（要求开头有中文说明注释块，不强求固定措辞）
        head = "\n".join(lines[:15])
        head_comment = "\n".join(
            line for line in lines[:15] if line.strip().startswith("//")
        )
        chinese_count = len(re.findall(r"[\u4e00-\u9fff]", head_comment))
        if not head.lstrip().startswith("//") or chinese_count < 10:
            findings.append(("P2", "HEADER", rel, "文件开头缺少中文说明注释块"))

        # P2 编码
        if "\ufeff" in source[:1]:
            findings.append(("P2", "BOM", rel, "文件带 UTF-8 BOM"))
        if "\r\n" in source:
            findings.append(("P2", "CRLF", rel, "使用 CRLF 换行"))

        if args.verbose and not any(item[2].startswith(rel) for item in findings):
            print(f"  ok  {rel}")

    # P0 重复类型声明
    for name, entries in declarations.items():
        kinds = [entry for entry in entries if entry[2] != "typealias"]
        if len(kinds) > 1:
            where = "、".join(f"{rel}:{line}" for rel, line, _kind in kinds)
            findings.append(("P0", "DUP-TYPE", kinds[0][0], f"类型 {name} 重复定义：{where}"))

    # ------------------------------------------------------------------
    # 汇总
    # ------------------------------------------------------------------
    order = {"P0": 0, "P1": 1, "P2": 2}
    findings.sort(key=lambda item: (order.get(item[0], 9), item[1], item[2]))

    print("=" * 78)
    print(" 墨语 · 宿主 App（ios/AIKeyboard）自用静态自查")
    print(f" 模块根目录: {root}")
    print(f" 文件数    : {len(files)}   行数: {sum(len(read_text(p).splitlines()) for p in files)}")
    print(f" Theme 成员: {len(theme_known)}   AppMetrics 成员: {len(metrics_known)}   类型定义: {len(declarations)}")
    print("=" * 78)

    counts = {"P0": 0, "P1": 0, "P2": 0}
    for level, rule, where, message in findings:
        counts[level] = counts.get(level, 0) + 1
        print(f"[{level}] {rule:<16} {where}\n       {message}")

    if not findings:
        print("\n未发现任何问题。\n")

    print("=" * 78)
    print(f" P0={counts['P0']}  P1={counts['P1']}  P2={counts['P2']}")
    if counts["P0"]:
        print(" 结论: 有 P0 问题，必须修复后才能交付")
    elif counts["P1"]:
        print(" 结论: 无 P0，建议修掉 P1")
    else:
        print(" 结论: 通过")
    print("=" * 78)
    return 1 if counts["P0"] else 0


if __name__ == "__main__":
    sys.exit(main())
