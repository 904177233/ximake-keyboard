"""词库加载耗时分解探针（仅本机诊断用，不参与构建）。

用途：为「`IMEKit` 初始化是否可能阻塞首帧」提供量化依据。
Python 的解释执行比 Swift 慢 3-10 倍，因此这里得到的数字只能作为**上界估算**，
真实耗时必须在 macOS 上用 `PinyinDictionary.loadDurationMilliseconds` 实测。

运行：python tools/dict/_probe_loadtime.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _simulate_engine as sim  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICT_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "base_dict.tsv")


def main():
    if not os.path.exists(DICT_PATH):
        print("词库不存在：%s" % DICT_PATH)
        return 1

    t0 = time.perf_counter()
    raw = open(DICT_PATH, "rb").read()
    t1 = time.perf_counter()
    text = raw.decode("utf-8")
    t2 = time.perf_counter()

    rows = []
    for line in text.split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        rows.append((fields[0], fields[1], int(fields[2]), fields[3] if len(fields) > 3 else ""))
    t3 = time.perf_counter()

    grouped = {}
    for row in rows:
        grouped.setdefault(row[0], []).append(row)
    t4 = time.perf_counter()

    keys = sorted(grouped.keys())
    t5 = time.perf_counter()

    dp_total = 0.0
    dp_count = 0
    for pinyin, word, _frequency, _flags in rows:
        if not sim.is_pure_cjk(word):
            continue
        start = time.perf_counter()
        sim.segment_exactly(pinyin, len(word)) or sim.segment_min(pinyin)
        dp_total += (time.perf_counter() - start) * 1000
        dp_count += 1
    t6 = time.perf_counter()

    print("词库：%s（%d 字节 / %d 条 / %d 个全拼键）" % (DICT_PATH, len(raw), len(rows), len(keys)))
    print("1. 读文件        %6.2f ms" % ((t1 - t0) * 1000))
    print("2. UTF-8 解码    %6.2f ms" % ((t2 - t1) * 1000))
    print("3. 逐行解析      %6.2f ms" % ((t3 - t2) * 1000))
    print("4. 按全拼分组    %6.2f ms" % ((t4 - t3) * 1000))
    print("5. 排序键数组    %6.2f ms" % ((t5 - t4) * 1000))
    print("6. 首字母 DP     %6.2f ms（%d 条纯汉字）" % (dp_total, dp_count))
    print("   —— 合计       %6.2f ms（Python 上界；Swift 通常快 3-10 倍）" % ((t6 - t0) * 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main())
