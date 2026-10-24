# -*- coding: utf-8 -*-
"""临时核查脚本（不入库）：检查内置兜底词表与词库解析鲁棒性。"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICT_SWIFT = os.path.join(ROOT, "ios", "Shared", "IMECore", "PinyinDictionary.swift")


def main():
    text = open(DICT_SWIFT, encoding="utf-8").read()
    match = re.search(r'let seed = """(.*?)"""', text, re.S)
    if not match:
        print("未找到 seed 字符串")
        return 1
    rows = [line.strip() for line in match.group(1).split("\n") if line.strip()]
    print("seed 行数：", len(rows))
    words = [row.split()[1] for row in rows]
    print("词条数：", len(words))
    print("去重后：", len(set(words)))
    common = "我你的了是不在有和人这那好吗吧啊他她它们"
    covered = "".join(ch for ch in common if ch in words)
    missing = "".join(ch for ch in common if ch not in words)
    print("常用单字覆盖：", covered)
    print("缺失：", missing or "无")
    print("前 5 行：", rows[:5])
    print("后 5 行：", rows[-5:])
    bad = [row for row in rows if len(row.split()) < 3]
    print("字段不足的行：", bad or "无")
    return 0


if __name__ == "__main__":
    sys.exit(main())
