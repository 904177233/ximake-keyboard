"""组合切分 DP 的「每词代价」标定探针。

背景：词库从 5,276 扩到 33,160 条后，`appendComposedCandidates` 的最大化
`sum(logScore(freq))` 目标会奖励「切得越多片越好」，导致 `woxihuanni` 被切成
「我+西湖+啊+嗯+你」而不是「我+喜欢+你」。本探针扫描每词代价 `penalty`，
观察典型长句输入的最优切分是否回到语义正确路径。

用法：python tools/dict/_probe_dp_penalty.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _simulate_engine as sim  # noqa: E402
from syllable_table import SYLLABLES  # noqa: E402

MAX_TILE = 24


def log_score(frequency):
    return math.log(max(frequency, 0) + 1.0)


def best_path(dictionary, normalized, penalty):
    """用带每词代价的 DP 求最优切分，返回 (text, tiles, sum_log)。"""
    chars = list(normalized)
    count = len(chars)
    best = [-float("inf")] * (count + 1)
    back = [-1] * (count + 1)
    tile_text = [None] * (count + 1)
    tile_freq = [0] * (count + 1)
    best[0] = 0.0
    for start in range(count):
        if not math.isfinite(best[start]):
            continue
        max_length = min(MAX_TILE, count - start)
        for size in range(1, max_length + 1):
            key = "".join(chars[start:start + size])
            hit = dictionary.exact_entries(key, 1)
            if not hit:
                continue
            word, frequency, flags = hit[0]
            if "emoji" in flags or "punct" in flags:
                continue
            if not any(sim.cjk(c) for c in word):
                continue
            score = best[start] + log_score(frequency) - penalty
            if score > best[start + size]:
                best[start + size] = score
                back[start + size] = start
                tile_text[start + size] = word
                tile_freq[start + size] = frequency
    if not math.isfinite(best[count]):
        return None
    pieces = []
    cursor = count
    while cursor > 0:
        previous = back[cursor]
        if previous < 0 or tile_text[cursor] is None:
            return None
        pieces.append(tile_text[cursor])
        cursor = previous
    return "".join(reversed(pieces)), len(pieces), 0.0


QUERIES = [
    ("woxihuanni", "我喜欢你"),
    ("nihaoma", "你好吗"),
    ("wobuyao", "我不要"),
    ("nizaina", "你在哪"),
    ("womenzouba", "我们走吧"),
    ("jintiantianqihenhao", "今天天气很好"),
    ("wanshangchifanba", "晚上吃饭吧"),
    ("woyaohuijia", "我要回家"),
    ("zaijianle", "再见了"),
    ("nizaiganma", "你在干嘛"),
    ("mingtianjian", "明天见"),
    ("xiexieni", "谢谢你"),
    ("duibuqi", "对不起"),
    ("nihaoya", "你好呀"),
    ("wobuzhidao", "我不知道"),
    ("nizaishuoshenme", "你在说什么"),
    ("zhegeshenme", "这个什么"),
    ("nengbuneng", "能不能"),
    ("jintianxiaban", "今天下班"),
    ("womenyikuai", "我们一块"),
]


def main():
    rows = sim.load_entries()
    dictionary = sim.SimulatedDictionary(rows)
    print("词库：%d 条" % len(rows))
    for penalty in (0.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0):
        good = 0
        details = []
        for query, expected in QUERIES:
            result = best_path(dictionary, query, penalty)
            text = result[0] if result else ""
            if text == expected:
                good += 1
            else:
                details.append("%s->%s" % (query, text or "<none>"))
        print("penalty=%-5.1f 正确 %2d/%d  %s" % (penalty, good, len(QUERIES), "; ".join(details)))


if __name__ == "__main__":
    main()
