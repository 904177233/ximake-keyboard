# -*- coding: utf-8 -*-
"""简拼候选排序探针（诊断用，不参与打包）。

用途：给「聊天高频词权重表 + 简拼多样性」这次修复留一份**改前 / 改后对照**：
    python tools/dict/_probe_initials_rank.py            # 打当前词库的简拼前 5 候选
    python tools/dict/_probe_initials_rank.py --words 我去 好的   # 查这批词在词库里的落点

输出直接用于回报里的「改前 vs 改后」表。
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import _simulate_engine as sim  # noqa: E402

# 验收用的五个简拼（两字母，全部走「仅首字母命中」路径）
CHECK_QUERIES = ("wq", "nh", "zm", "sm", "xq")


def describe(dictionary, word: str) -> str:
    """查一个词在词库里的 拼音 / 词频 / flags。"""
    hits = [row for row in dictionary.rows if row[1] == word]
    if not hits:
        return "%-6s 不在词库里" % word
    pinyin, _word, frequency, flags = hits[0]
    return "%-6s %-14s freq=%-6d flags=%s" % (word, pinyin, frequency, flags)


def main(argv: list[str]) -> int:
    rows = sim.load_entries()
    dictionary = sim.SimulatedDictionary(rows, sim.load_chat_priority())
    engine = sim.SimulatedEngine(dictionary)

    if "--words" in argv:
        index = argv.index("--words")
        for word in argv[index + 1:]:
            print(describe(dictionary, word))
        return 0

    if "--keys" in argv:
        # 打印某个首字母串命中的全部「全拼键 → 词条」，用于设计同长度配额
        index = argv.index("--keys")
        for query in argv[index + 1:]:
            print("== %s ==" % query)
            for key in dictionary.pinyin_keys_initials(query, 24)[:12]:
                entries = dictionary.exact_entries(key, 12)
                cells = ["%s(%d,%s)" % (word, frequency, flags) for word, frequency, flags in entries]
                print("  %-12s %s" % (key, "  ".join(cells)))
        return 0

    print("词库条数 = %d" % len(rows))
    for query in CHECK_QUERIES:
        candidates = engine.candidates(query, limit=5)
        cells = []
        for offset, item in enumerate(candidates, start=1):
            cells.append("%d.%s(%.2f,%s)" % (offset, item["text"], item["score"], item["kind"]))
        print("%-3s -> %s" % (query, "  ".join(cells) if cells else "（无候选）"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
