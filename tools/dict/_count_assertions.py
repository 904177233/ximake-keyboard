# -*- coding: utf-8 -*-
"""统计 `_simulate_engine.py` 里各分组的断言条数（仅用于核对 README 的数字）。"""

from __future__ import annotations

import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGET = os.path.join(HERE, "_simulate_engine.py")

GROUP_RE = re.compile(r'print\("\[(\d)\] ')
RUN_RE = re.compile(r"\brun\(")


def main():
    text = io.open(TARGET, encoding="utf-8").read()
    block = text[text.index("def main():"):]
    counts = {}
    current = None
    for line in block.splitlines():
        matched = GROUP_RE.search(line)
        if matched:
            current = matched.group(1)
            counts[current] = 0
            continue
        if current and RUN_RE.search(line):
            counts[current] += len(RUN_RE.findall(line))
    total = 0
    for key in sorted(counts):
        print(f"[{key}] {counts[key]} 条")
        total += counts[key]
    print(f"合计 {total} 条")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
