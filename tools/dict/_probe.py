# -*- coding: utf-8 -*-
"""临时探查脚本：看 jieba 词频表格式与分布。"""
import collections
import io
import os
import re

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache", "jieba_dict.txt")
CJK = re.compile(r"^[\u4e00-\u9fff]+$")

rows = []
tags = collections.Counter()
with io.open(SRC, "r", encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split(" ")
        if len(parts) < 3:
            continue
        word, freq, tag = parts[0], parts[1], parts[2]
        try:
            f = int(freq)
        except ValueError:
            continue
        tags[tag] += 1
        if CJK.match(word) and 1 <= len(word) <= 6:
            rows.append((word, f, tag))

print("总行数(可用):", len(rows))
rows.sort(key=lambda r: -r[1])
print("前 30:", rows[:30])
for k in (1000, 2000, 4000, 6000, 8000):
    if len(rows) > k:
        print("第 %d 名词频: %s %d" % (k, rows[k][0], rows[k][1]))
print("freq>=1000 的 CJK 词数:", sum(1 for r in rows if r[1] >= 1000))
print("tag 分布 top15:", tags.most_common(15))
print("1 字词数量:", sum(1 for r in rows if len(r[0]) == 1))
print("长度分布:", collections.Counter(len(r[0]) for r in rows))
