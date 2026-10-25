# -*- coding: utf-8 -*-
"""探针：用真实词库复刻简拼路径，检查 `wq` / `nh` / `zm` / `sm` / `xq` 的候选顺序。

只读，不改任何数据。跑法：
    python tools/dict/_probe_wq.py

词库列序是 `拼音<TAB>词<TAB>词频<TAB>flags`（注意拼音在前）。
首字母用 `syllable_table.ALL` 做最长匹配切分，与 Swift 端 DP 切分结果一致。
"""

import io
import math
import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICT = os.path.join(BASE, "ios", "Shared", "dict", "base_dict.tsv")
PRIORITY = os.path.join(BASE, "ios", "Shared", "dict", "chat_priority.tsv")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from syllable_table import SYLLABLES  # noqa: E402

SYLLABLE_SET = set(SYLLABLES)
MAX_LEN = max(len(s) for s in SYLLABLE_SET)


def split_syllables(pinyin):
    """最长匹配切音节（贪心从最长音节往下试）。"""
    out = []
    i = 0
    while i < len(pinyin):
        matched = None
        for size in range(MAX_LEN, 0, -1):
            chunk = pinyin[i:i + size]
            if chunk in SYLLABLE_SET:
                matched = chunk
                break
        if matched is None:
            return None
        out.append(matched)
        i += len(matched)
    return out


def initials_of(pinyin):
    """全拼串 -> 首字母串（woqu -> wq）。"""
    sylls = split_syllables(pinyin)
    if not sylls:
        return None
    return "".join(s[0] for s in sylls)


def load_priority():
    table = {}
    with io.open(PRIORITY, "r", encoding="utf-8", newline="\n") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            try:
                table[parts[0]] = float(parts[1])
            except ValueError:
                continue
    return table


def load_dict():
    entries = []
    with io.open(DICT, "r", encoding="utf-8", newline="\n") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            try:
                freq = int(parts[2])
            except ValueError:
                continue
            entries.append((parts[1], parts[0], freq))  # 词, 拼音, 词频
    return entries


def log_score(freq):
    return math.log(max(freq, 1), 10)


def build_index(entries):
    """按首字母串索引：[initials][pinyin] -> [(text, freq)]"""
    index = {}
    for text, pinyin, freq in entries:
        ini = initials_of(pinyin)
        if not ini:
            continue
        index.setdefault(ini, {}).setdefault(pinyin, []).append((text, freq))
    return index


def probe(query, index, priority, top=8):
    """复刻 PinyinEngine+Initials.appendInitialsCandidates 的排序。"""
    keys = index.get(query, {})
    ranked_buckets = []
    for key, items in keys.items():
        scored = []
        for text, freq in items:
            prio = priority.get(text, 0.0)
            rank = (log_score(freq) + 0.6) * (1.0 + prio)
            scored.append((text, freq, prio, rank))
        scored.sort(key=lambda x: (-x[3], x[0]))
        ranked_buckets.append((key, scored))
    ranked_buckets.sort(key=lambda x: (-(x[1][0][3] if x[1] else 0), x[0]))

    out = []
    structure = {}
    for offset, (key, scored) in enumerate(ranked_buckets):
        used = 0
        for text, freq, prio, rank in scored:
            if used >= 2:
                break
            stem = text[0] + "|" + str(len(text))
            seen = structure.get(stem, 0)
            if seen >= 2:
                continue
            structure[stem] = seen + 1
            used += 1
            out.append((text, freq, prio))
    return out[:top]


def main():
    entries = load_dict()
    priority = load_priority()
    index = build_index(entries)
    print("dict entries : %d" % len(entries))
    print("chat priority: %d" % len(priority))
    print("initials keys: %d" % len(index))
    print("")

    for query in ("wq", "nh", "zm", "sm", "xq", "zj"):
        rows = probe(query, index, priority)
        print("[%-4s] %s" % (query, "  ".join(
            "%s(%d,p%.1f)" % (r[0], r[1], r[2]) for r in rows)))
    print("")

    for word in ("我去", "顽强", "望去", "无穷", "中国", "优秀", "嗯好", "在吗"):
        hit = [e for e in entries if e[0] == word]
        print("%-4s -> %s  prio=%s" % (word, hit[:1], priority.get(word, 0.0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
