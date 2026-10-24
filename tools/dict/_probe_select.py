# -*- coding: utf-8 -*-
"""词库扩展参数调优探针（一次性脚本）。

对不同的「词频阈值 / 词长 / 常用字支持度」组合，统计 jieba 侧可入选条数与质量样本，
用于给 build_dict.py 定扩展参数（目标：jieba 侧 ~28,000 条，总条数 ≥ 30,000）。
"""

from __future__ import annotations

import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache", "jieba_dict.txt")

CJK_ONLY = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")
NAME_POS = {"nr", "nrt", "nrx", "nrfg"}
CACHE_ROWS: list[tuple[str, int, str]] = []


def load():
    rows = []
    with open(CACHE, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            rows.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    rows.sort(key=lambda r: (-r[1], r[0]))
    return rows


def char_set(rows, basis_freq: int, support: int) -> set[str]:
    counter: Counter[str] = Counter()
    for word, freq, _pos in rows:
        if freq < basis_freq or not CJK_ONLY.match(word):
            continue
        for ch in set(word):
            counter[ch] += 1
    return {ch for ch, n in counter.items() if n >= support}


def select(rows, keep: set[str], min_freq: int, max_len: int, name_keep_freq: int):
    picked = []
    for word, freq, pos in rows:
        if freq < min_freq:
            break
        if not CJK_ONLY.match(word):
            continue
        if len(word) > max_len:
            continue
        if not all(ch in keep for ch in word):
            continue
        if pos in NAME_POS and len(word) >= 3 and freq < name_keep_freq:
            continue
        picked.append((word, freq, pos))
    return picked


def main():
    rows = load()
    print("jieba 总行数", len(rows))

    print("\n[常用字集合规模]")
    for basis, support in ((1000, 3), (500, 3), (300, 2), (200, 2), (150, 2)):
        chars = char_set(rows, basis, support)
        print(f"    basis={basis:<5} support={support}: {len(chars)} 个常用字")

    print("\n[入选条数] max_len=4，不同 freq/常用字组合")
    header = f"{'freq':>6} {'chars':>12} {'条数':>7} {'单字':>6} {'2字':>6} {'3字':>6} {'4字':>6}"
    print(header)
    for basis, support in ((1000, 3), (500, 3), (300, 2), (200, 2)):
        keep = char_set(rows, basis, support)
        for min_freq in (100, 120, 150, 200, 250, 300):
            picked = select(rows, keep, min_freq, 4, 8000)
            lens = Counter(len(w) for w, _, _ in picked)
            print(f"{min_freq:>6} {f'basis{basis}/sup{support}':>12} {len(picked):>7} "
                  f"{lens[1]:>6} {lens[2]:>6} {lens[3]:>6} {lens[4]:>6}")

    print("\n[最终候选（basis=300/sup=2, freq>=130, max_len=4）抽检 40 条]")
    keep = char_set(rows, 300, 2)
    picked = select(rows, keep, 130, 4, 8000)
    print("条数", len(picked))
    step = max(1, len(picked) // 40)
    for i in range(0, len(picked), step)[:40] if False else list(range(0, len(picked), step))[:40]:
        w, f, p = picked[i]
        print(f"    {w:<8} {f:>6}  {p}")

    print("\n[被丢弃的样本 / 词性分布]")
    pos = Counter(p for _, _, p in picked)
    print("    词性:", dict(pos.most_common(15)))

    names = [(w, f) for w, f, p in picked if p in NAME_POS]
    print(f"    仍保留的人名类 {len(names)} 条，样本：", names[:10])
    ns = [(w, f) for w, f, p in picked if p == "ns"]
    print(f"    地名类 {len(ns)} 条，样本：", ns[:12])
    nzs = [(w, f) for w, f, p in picked if p == "nz"]
    print(f"    专名类 {len(nzs)} 条，样本：", nzs[:10])

    # 体积估算：pinyin 平均长度
    total_chars = sum(len(w) for w, _, _ in picked)
    print(f"\n平均词长 {total_chars / max(len(picked), 1):.2f} 字")
    return 0


if __name__ == "__main__":
    sys.exit(main())
