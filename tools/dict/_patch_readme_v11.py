"""一次性补丁：把 IMECore/README.md 里 v1.0.0 时代的数字更新为 v1.1.0（33,160 条）。

用途：词库扩展（5,276 → 33,160 条）后，README 里的 wordCount / version / 诊断摘要样例
还停留在旧值。本脚本做纯字符串替换，跑完即可删除。
"""

from __future__ import annotations

import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PATH = os.path.join(ROOT, "ios", "Shared", "IMECore", "README.md")

REPLACEMENTS = [
    ("| 48 | `kit.diagnosticsSummary` 非空且包含 `\"5276\"` 或实际条数 | `true` |",
     "| 48 | `kit.diagnosticsSummary` 非空且包含实际条数（`33160`） | `true` |"),
    ("1: wordCount = 5276                     PASS",
     "1: wordCount = 33160                    PASS"),
    ('2: version = "1.0.0"                    PASS',
     '2: version = "1.1.0"                    PASS'),
    ("词库条数 = 5276，短语条数 = 755",
     "词库条数 = 33160，短语条数 = 755"),
    ('assert(dict.wordCount == 5276,                        "词库条数应为 5276，实际 \\(dict.wordCount)")',
     'assert(dict.wordCount == 33160,                       "词库条数应为 33160，实际 \\(dict.wordCount)")'),
    ("assert(kit.wordCount == 5276)",
     "assert(kit.wordCount == 33160)"),
    ('assert(kit.diagnosticsSummary.contains("5276"))',
     'assert(kit.diagnosticsSummary.contains("33160"))'),
    ("| 每文件 ≤600 行 | ✅ 最长 594 行（`PinyinEngine.swift`） |",
     "| 每文件 ≤600 行 | ✅ 最长 598 行（`PinyinEngine.swift`） |"),
    ("`词库 v1.0.0｜5276 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 12.3ms`",
     "`词库 v1.1.0｜33160 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 62.4ms`"),
    ("| `wordCount` | `Int` | `5276` | 词条总数；兜底时为 `50` |",
     "| `wordCount` | `Int` | `33160` | 词条总数；兜底时为 `50` |"),
    ("词库 v1.0.0｜5276 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 12.3ms",
     "词库 v1.1.0｜33160 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 62.4ms"),
]


def main() -> int:
    text = io.open(PATH, encoding="utf-8").read()
    missing = 0
    for old, new in REPLACEMENTS:
        count = text.count(old)
        if count == 0:
            missing += 1
            print("[miss] %s" % old[:70])
            continue
        text = text.replace(old, new)
        print("[ok %d] %s" % (count, old[:60]))
    io.open(PATH, "w", encoding="utf-8", newline="\n").write(text)
    print("[done] 未命中 %d 处" % missing)
    return 0 if missing == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
