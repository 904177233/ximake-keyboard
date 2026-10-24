#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""project.pbxproj 的 OpenStep plist 词法/语法校验（只读检查器）。

背景
----
`ios/AIKeyboard.xcodeproj/project.pbxproj` 不是 JSON、不是 XML，而是 Apple 的
**Old-style / OpenStep property list** 格式。它的"裸字符串"(unquoted string) 允许
字符集由 CoreFoundation 的 `CFPropertyList.c` 决定，实测为：

    A-Z a-z 0-9 . _ $ / : -

**不包含** `+`、`~`、`#`、`@`、`&`、`=`、`,`、`?`、`*`、`!`、`'`、`(`、`)`、`%` 等。

一旦某个 `path = ...;` 的取值里出现这些字符却没加引号，xcodebuild 会直接报：

    Old-style plist parser: missing semicolon in dictionary on line N
    xcodebuild: error: Unable to read project '...'
    Reason: The project '...' is damaged and cannot be opened due to a parse error

——整个工程打不开，连 `xcodebuild -list` 都跑不到。

这个检查器补的正是自研校验器（括号平衡、UUID 引用完整性）查不出的那一层：
**词法层**。它按 OpenStep plist 的词法规则逐字符扫描，遇到非法裸字符就报错并
给出应加引号的位置。

用法
----
    python scripts/lead/pbxproj_plist_check.py [--verbose]

退出码
------
    0 = 未发现词法问题
    1 = 发现词法问题（会导致 Xcode 打不开工程）
    2 = 文件不存在 / 自身错误
"""

from __future__ import annotations

import argparse
import pathlib
import sys

DEFAULT_PBXPROJ = pathlib.Path("ios/AIKeyboard.xcodeproj/project.pbxproj")

# CoreFoundation OpenStep plist 允许出现在 **裸字符串** 里的字符。
# 依据：CFPropertyList.c 中 isUnquotedStringChar() 的实现。
UNQUOTED_CHARS = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "._$/:"
    "-"
)

# 在语法的"值位置"之外的合法标点（结构性字符，不是字符串的一部分）
STRUCTURAL = set("{}()=;,")


class Issue:
    def __init__(self, line: int, col: int, kind: str, detail: str, snippet: str) -> None:
        self.line = line
        self.col = col
        self.kind = kind
        self.detail = detail
        self.snippet = snippet

    def __str__(self) -> str:
        return f"  [P0] L{self.line}:{self.col} {self.kind}\n        {self.detail}\n        {self.snippet}"


def scan(text: str) -> tuple[list[Issue], int, int]:
    """逐字符扫描 pbxproj，检查裸字符串是否用了非法字符。

    返回 (issues, 字符串总数, 加引号的字符串数)
    """
    issues: list[Issue] = []
    n = len(text)
    i = 0
    line = 1
    col = 1
    n_strings = 0
    n_quoted = 0

    def line_text(ln: int) -> str:
        parts = text.splitlines()
        if 1 <= ln <= len(parts):
            return parts[ln - 1].strip()[:140]
        return ""

    while i < n:
        ch = text[i]

        # --- 换行 / 列号维护 ---------------------------------------------
        if ch == "\n":
            line += 1
            col = 1
            i += 1
            continue

        # --- 注释：/* ... */ ---------------------------------------------
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                issues.append(
                    Issue(line, col, "未闭合的块注释", "`/*` 之后找不到 `*/`", line_text(line))
                )
                return issues, n_strings, n_quoted
            chunk = text[i : end + 2]
            line += chunk.count("\n")
            if "\n" in chunk:
                col = len(chunk) - chunk.rfind("\n")
            else:
                col += len(chunk)
            i = end + 2
            continue

        # --- 注释：// ... ------------------------------------------------
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            end = text.find("\n", i)
            if end == -1:
                break
            i = end
            continue

        # --- 带引号的字符串 ----------------------------------------------
        if ch == '"':
            n_strings += 1
            n_quoted += 1
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            if j >= n:
                issues.append(
                    Issue(line, col, "未闭合的字符串", "`\"` 之后找不到配对的 `\"`", line_text(line))
                )
                return issues, n_strings, n_quoted
            chunk = text[i : j + 1]
            line += chunk.count("\n")
            if "\n" in chunk:
                col = len(chunk) - chunk.rfind("\n")
            else:
                col += len(chunk)
            i = j + 1
            continue

        # --- 裸字符串 -----------------------------------------------------
        if ch in UNQUOTED_CHARS:
            start_i = i
            start_line = line
            start_col = col
            while i < n and text[i] in UNQUOTED_CHARS:
                i += 1
                col += 1
            n_strings += 1
            # 裸字符串正常结束（后面是空白 / 结构字符 / 注释）：没问题
            if i >= n:
                break
            nxt = text[i]
            if nxt in STRUCTURAL or nxt in " \t\r\n":
                continue
            # 裸字符串后面紧跟一个字符合法字符集之外的字符 → 词法错误
            if nxt == "/" and i + 1 < n and text[i + 1] in "*/":
                continue
            raw = text[start_i:i] + nxt
            issues.append(
                Issue(
                    start_line,
                    start_col,
                    "裸字符串含非法字符",
                    (
                        f"`{raw}` 中出现了未加引号的字符 {nxt!r}。"
                        f"OpenStep plist 的裸字符串只允许 A-Z a-z 0-9 . _ $ / : -，"
                        f"遇到 {nxt!r} 会让 Xcode 报 "
                        f"`Old-style plist parser: missing semicolon`，整个工程打不开。"
                        f" 修复：给这个值整体加双引号 → \"{raw}\""
                    ),
                    line_text(start_line),
                )
            )
            continue

        # 结构字符与空白：跳过
        if ch in STRUCTURAL or ch in " \t\r":
            i += 1
            col += 1
            continue

        # 其他字符出现在裸字符串起点：多半也是问题，但只在后面跟字母数字时报
        nxt = text[i]
        issues.append(
            Issue(
                line,
                col,
                "意外的裸字符",
                (
                    f"此处出现 {nxt!r}，它既不是结构字符也不是合法裸字符串起始字符。"
                    f"如果它是某个 `path = ...` 取值的一部分，请把整个取值加双引号。"
                ),
                line_text(line),
            )
        )
        i += 1
        col += 1

    return issues, n_strings, n_quoted


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="project.pbxproj 的 OpenStep plist 词法校验")
    ap.add_argument("--path", default=str(DEFAULT_PBXPROJ), help="pbxproj 路径")
    ap.add_argument("--verbose", action="store_true", help="打印统计细节")
    args = ap.parse_args(argv)

    p = pathlib.Path(args.path)
    if not p.is_file():
        print(f"[错误] 找不到 {p}", file=sys.stderr)
        return 2

    raw = p.read_bytes()
    if raw[:3] == b"\xef\xbb\xbf":
        print("[P1] 文件带 UTF-8 BOM；Xcode 能读但建议去掉")
    text = raw.decode("utf-8")

    if not text.startswith("// !$*UTF8*$!"):
        print("[P1] 首行不是 `// !$*UTF8*$!`，Xcode 可能按 ASCII 解析导致中文乱码")

    issues, n_strings, n_quoted = scan(text)

    print("=" * 78)
    print("project.pbxproj · OpenStep plist 词法校验（只读）")
    print("=" * 78)
    print(f"文件      : {p}")
    print(f"大小      : {len(raw)} B / {len(text.splitlines())} 行")
    print(f"字符串    : 共 {n_strings} 个（其中加引号 {n_quoted} 个）")
    if args.verbose:
        print(f"裸字符串允许字符: {''.join(sorted(UNQUOTED_CHARS))}")
    print()

    if issues:
        print(f"发现 {len(issues)} 个词法问题（P0，会导致 xcodebuild 打不开工程）：")
        for it in issues:
            print(it)
        print("-" * 78)
        print("结论: 不通过 —— 必须修掉，否则 CI 会在 `xcodebuild -list` 步失败")
        return 1

    print("结论: 通过（未发现裸字符串非法字符）")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
