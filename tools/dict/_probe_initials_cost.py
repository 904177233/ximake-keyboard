"""首字母索引构建成本分解探针（仅本机诊断用，不参与构建）。

背景：`PinyinDictionary.buildInitialsIndex` 在加载时对每个纯汉字词调用
`initialsString(for:)`，内部先试 `PinyinSyllables.segment(pinyin, exactly: 字数)`，
失败再退回 `segment(pinyin)`。两次都是二维 DP。词库从 5276 扩到 33k 后，
这部分是加载耗时的主要增长源，必须先量化再判断是否超 80ms 预算。

本探针只做「操作计数」，用解析式估算 Swift 耗时，不跑完整 Python DP，
避免 Python 解释器开销污染结论。

运行：python tools/dict/_probe_initials_cost.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _simulate_engine as sim  # noqa: E402
from syllable_table import SYLLABLES  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICT_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "base_dict.tsv")
SYL = frozenset(SYLLABLES)
MAX_LEN = max(len(s) for s in SYL)


def load_rows(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        rows.append((fields[0], fields[1], int(fields[2])))
    return rows


def dp_exact_ops(pinyin, segments):
    """统计 `segment(_:exactly:)` 的内层循环次数（与 Swift 实现同构）。"""
    count = len(pinyin)
    if segments <= 0 or count == 0:
        return 0
    ops = 0
    for index in range(count):
        for used in range(segments + 1):
            remain = count - index
            upper = min(MAX_LEN, remain)
            for length in range(1, upper + 1):
                ops += 1
    return ops


def dp_min_ops(pinyin):
    """统计 `segment(_:maxSegments:)`（最少音节切分）的内层循环次数。"""
    count = len(pinyin)
    ops = 0
    for index in range(count):
        remain = count - index
        upper = min(MAX_LEN, remain)
        ops += upper
    return ops


def main():
    if not os.path.exists(DICT_PATH):
        print("词库不存在：%s" % DICT_PATH)
        return 1
    rows = load_rows(DICT_PATH)
    cjk = [(py, w) for py, w, _f in rows if sim.is_pure_cjk(w)]
    non_cjk = len(rows) - len(cjk)

    exact_ops = 0
    fallback_ops = 0
    fallback_words = 0
    for pinyin, word in cjk:
        exact_ops += dp_exact_ops(pinyin, len(word))
        segs = sim.segment_exactly(pinyin, len(word))
        if not segs:
            fallback_words += 1
            fallback_ops += dp_min_ops(pinyin)

    total_ops = exact_ops + fallback_ops
    print("词库：%d 条（纯汉字 %d 条 / 纯 ASCII 及其它 %d 条）" % (len(rows), len(cjk), non_cjk))
    print("精确切分 DP 内层循环        %12d 次" % exact_ops)
    print("退回最少音节 DP 内层循环    %12d 次（%d 个词需要退回）" % (fallback_ops, fallback_words))
    print("合计                        %12d 次" % total_ops)
    print("")
    print("按 Swift 每次内层迭代 + 少量数组拷贝估算：")
    for ns in (15, 25, 40, 60):
        ms = total_ops * ns / 1e6
        print("    %.2f us/千次 → %6.1f ms（%d ns/次迭代）" % (ns / 1000.0, ms, ns))
    print("")
    print("参考：Swift 里 `prefix + [seg]` 每次命中才发生，量级远小于内层迭代次数；")
    print("      实际耗时以 macOS 上 PinyinDictionary.loadDurationMilliseconds 实测为准。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
