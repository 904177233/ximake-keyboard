# -*- coding: utf-8 -*-
"""探查 jieba 词表在不同阈值下的可选规模与词性分布（一次性脚本，用于定扩展参数）。"""

from __future__ import annotations

import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache", "jieba_dict.txt")

CJK_ONLY = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")


def load():
    rows = []
    with open(CACHE, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            rows.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    return rows


def main():
    rows = load()
    print("总行数", len(rows))

    # 各词频阈值下、长度 2-4 纯 CJK 的条数
    print("\n[freq 阈值 x 长度] 纯 CJK 条数")
    print("freq>=   " + "  ".join(f"len{n}" for n in (1, 2, 3, 4, 5, 6)))
    for thr in (30, 50, 100, 150, 200, 250, 300, 400, 500, 800):
        counts = []
        for ln in (1, 2, 3, 4, 5, 6):
            n = sum(1 for w, f, p in rows
                    if f >= thr and len(w) == ln and CJK_ONLY.match(w))
            counts.append(n)
        print(f"{thr:>7}   " + "  ".join(f"{c:>6}" for c in counts))

    # 词性分布（freq>=300, 长度2-4, 纯CJK）
    pos = Counter()
    for w, f, p in rows:
        if f >= 300 and 2 <= len(w) <= 4 and CJK_ONLY.match(w):
            pos[p] += 1
    print("\n[freq>=300, len2-4, 纯CJK] 词性 TOP30：")
    for k, v in pos.most_common(30):
        print(f"    {k or '(空)':<8} {v}")

    print("\n[freq>=300, len2-4] 按词性归类条数：")
    groups = {
        "常用实词 n/v/a/d/vn/ad": {"n", "v", "a", "d", "vn", "ad", "an", "vd"},
        "成语/习语 i/l": {"i", "l", "j"},
        "地名 ns": {"ns"},
        "机构 nt": {"nt"},
        "人名 nr/nrt/nrx": {"nr", "nrt", "nrx", "nrfg"},
        "专名 nz": {"nz"},
        "数量/时间 m/t": {"m", "t", "mq", "fq", "tg"},
        "其它": None,
    }
    for label, keys in groups.items():
        if keys is None:
            continue
        n = sum(v for k, v in pos.items() if k in keys)
        print(f"    {label:<22} {n}")

    # 现有 5276 条里的单字，看能否保底
    print("\n[单字] freq>=各阈值 的纯CJK 单字条数：")
    for thr in (100, 200, 300, 500, 800, 1000, 1200):
        n = sum(1 for w, f, p in rows if len(w) == 1 and f >= thr and CJK_ONLY.match(w))
        print(f"    freq>={thr}: {n}")

    # 体积估算：假设每行 ~26 字节
    for target in (30000, 35000, 40000, 45000, 50000):
        print(f"估算 {target} 条 × 26B ≈ {target * 26 / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
