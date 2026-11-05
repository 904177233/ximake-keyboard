#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语 3.0 一致性检查。

v3 把颜色收到一个文件（ios/Shared/Theme/MoyuTheme.swift），不再有 tokens.json 和 Theme.swift，
所以旧版的「令牌 × 代码」对照没有意义了。这里只查现在真正会出错的三件事：

  ① 界面代码里不许写裸色值，颜色只能从调色板取（P1）
  ② 版本号四处必须相同（P0）。漏一处就会出现「装了新版还是旧号」
  ③ 词库文件必须和生成器的格式对得上（P0）

退出码：0 = 无 P0/P1；1 = 有 P1；2 = 有 P0；3 = 脚本内部错误。
"""

from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

from qa_common import Report, add_common_args, finish

THEME_REL = "ios/Shared/Theme/MoyuTheme.swift"
DICT_REL = "ios/Shared/dict/moyu.dict"

#: 界面代码里的裸色值写法。
RAW_COLOR = re.compile(r"(0x[0-9A-Fa-f]{6}\b|Color\(red:|UIColor\(red:|UIColor\(hex:|#[0-9A-Fa-f]{6}\b)")

VERSION_FILES = [
    (".github/workflows/build.yml", r"MARKETING_VERSION:\s*([0-9.]+)"),
    ("ios/Config/Base.xcconfig", r"MARKETING_VERSION\s*=\s*([0-9.]+)"),
    ("ios/project.yml", r'MARKETING_VERSION:\s*"([0-9.]+)"'),
]


def check_colors(root: Path, report: Report) -> None:
    files = 0
    hits = 0
    for folder in ("ios/AIKeyboard", "ios/AIKeyboardExtension"):
        for path in sorted((root / folder).rglob("*.swift")):
            files += 1
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("//"):
                    continue
                if RAW_COLOR.search(line):
                    hits += 1
                    report.add("P1", "RAW-COLOR", path.relative_to(root).as_posix(), number,
                               f"界面代码里写了裸色值：{line.strip()[:80]}",
                               "颜色放进 MoyuTheme.swift，界面从调色板取")
    report.stats["files"] = files
    report.stats["hardcoded_hex"] = hits
    if not (root / THEME_REL).exists():
        report.add("P0", "THEME-MISSING", THEME_REL, 0, "主题文件不存在")


def check_versions(root: Path, report: Report) -> None:
    found: dict[str, str] = {}
    for rel, pattern in VERSION_FILES:
        path = root / rel
        if not path.exists():
            report.add("P0", "VERSION-FILE", rel, 0, "文件不存在")
            continue
        for match in re.finditer(pattern, path.read_text(encoding="utf-8")):
            found[f"{rel}:{match.start()}"] = match.group(1)
    versions = set(found.values())
    report.stats["version"] = "/".join(sorted(versions)) or "?"
    if len(versions) != 1:
        report.add("P0", "VERSION-MISMATCH", VERSION_FILES[0][0], 0, f"版本号不一致：{sorted(versions)}",
                   "三个文件必须写同一个版本号")


def check_dictionary(root: Path, report: Report) -> None:
    path = root / DICT_REL
    if not path.exists():
        report.add("P0", "DICT-MISSING", DICT_REL, 0, "词库文件不存在", "运行 python tools/dict/build_binary.py")
        return
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"MYD3":
        report.add("P0", "DICT-FORMAT", DICT_REL, 0, "词库文件头不对")
        return
    version, entries, keys, off_keys, off_entries, off_t9, off_init, off_t9_init, off_blob = struct.unpack_from("<9I", data, 4)
    report.stats["dict_entries"] = entries
    report.stats["dict_keys"] = keys
    offsets = [off_keys, off_entries, off_t9, off_init, off_t9_init, off_blob]
    if version != 1:
        report.add("P0", "DICT-VERSION", DICT_REL, 0, f"格式版本 {version}，内核只认 1")
    if off_keys + keys * 20 > off_entries or off_entries + entries * 12 > off_t9 or off_blob > len(data):
        report.add("P0", "DICT-OFFSETS", DICT_REL, 0, f"区段位置不对：{offsets}")
    if any(offset % 4 for offset in offsets[:-1]):
        report.add("P0", "DICT-ALIGN", DICT_REL, 0, f"区段没有 4 字节对齐：{offsets}")
    if entries < 50000:
        report.add("P1", "DICT-SMALL", DICT_REL, 0, f"词条只有 {entries}，比预期少很多")


def run(root: Path) -> Report:
    report = Report("一致性检查", root)
    check_colors(root, report)
    check_versions(root, report)
    check_dictionary(root, report)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="墨语 3.0 一致性检查")
    add_common_args(parser)
    args = parser.parse_args(argv)
    return finish(run(Path(args.root).resolve()), args)


if __name__ == "__main__":
    sys.exit(main())
