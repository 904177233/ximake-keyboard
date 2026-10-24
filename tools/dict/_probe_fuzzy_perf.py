# -*- coding: utf-8 -*-
"""模糊音性能测量（仅用于估算 Swift 实现的按键开销，不参与打包）。

测量三件事：
    1. `FuzzyPinyin.expand` 的变体数量与耗时（对应 Swift 同名函数）；
    2. 引擎 `candidates` 开 / 关模糊音的耗时差（对应 `appendFuzzyCandidates`）；
    3. 最坏输入的耗时（长串 + 全 9 条规则）。

Python 解释执行比 Swift 慢 3-10 倍，这里的数字是上界；Swift 侧仍应在 macOS 上用
`CFAbsoluteTimeGetCurrent` 实测复核。

用法：
    python tools/dict/_probe_fuzzy_perf.py
"""

from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import _simulate_engine as sim  # noqa: E402


def timeit(func, repeat):
    """跑 `repeat` 次，返回 (平均毫秒, 最小毫秒)。"""
    best = float("inf")
    start = time.perf_counter()
    for _ in range(repeat):
        one = time.perf_counter()
        func()
        best = min(best, time.perf_counter() - one)
    total = time.perf_counter() - start
    return total / repeat * 1000.0, best * 1000.0


def main():
    rows = sim.load_entries()
    dictionary = sim.SimulatedDictionary(rows)
    engine = sim.SimulatedEngine(dictionary)

    print("=" * 78)
    print("模糊音性能测量（Python 上界，Swift 应快 3-10 倍）")
    print("=" * 78)

    print("[1] FuzzyPinyin.expand 变体数 / 耗时（默认 5 条规则）")
    samples = ["zhongguo", "zongguo", "nihao", "shanghai", "zhongguorenmin",
               "womenyiqiquchifanba", "z", "zh", "zongg"]
    for text in samples:
        variants = sim.SimulatedFuzzy.expand(text, sim.FUZZY_DEFAULT_RULES)
        avg, best = timeit(
            lambda t=text: sim.SimulatedFuzzy.expand(t, sim.FUZZY_DEFAULT_RULES), 200)
        print(f"    {text:<22} 变体 {len(variants):>3} 条   平均 {avg:>7.3f} ms   最小 {best:>7.3f} ms")

    print("-" * 78)
    print("[2] 全 9 条规则（最坏情况）")
    for text in ["zhuang", "zhongguorenmin", "womenyiqiquchifanba"]:
        variants = sim.SimulatedFuzzy.expand(text, sim.FUZZY_ALL_RULES)
        avg, best = timeit(
            lambda t=text: sim.SimulatedFuzzy.expand(t, sim.FUZZY_ALL_RULES), 100)
        print(f"    {text:<22} 变体 {len(variants):>3} 条   平均 {avg:>7.3f} ms   最小 {best:>7.3f} ms")

    print("-" * 78)
    print("[3] 引擎 candidates：关模糊 vs 开模糊（默认 5 条规则）")
    for text in ["zhongguo", "zongguo", "nihao", "zhuang", "zhongguorenmin"]:
        off_avg, off_best = timeit(
            lambda t=text: engine.candidates(t, fuzzy_rules=frozenset()), 200)
        on_avg, on_best = timeit(
            lambda t=text: engine.candidates(t, fuzzy_rules=sim.FUZZY_DEFAULT_RULES), 200)
        count_off = len(engine.candidates(text, fuzzy_rules=frozenset()))
        count_on = len(engine.candidates(text, fuzzy_rules=sim.FUZZY_DEFAULT_RULES))
        print(f"    {text:<22} 关 {off_avg:>7.3f} ms ({count_off:>2} 条)   "
              f"开 {on_avg:>7.3f} ms ({count_on:>2} 条)   增量 {on_avg - off_avg:>+7.3f} ms")

    print("-" * 78)
    print("[4] 典型按键（候选池已满时不跑模糊）")
    for text in ["wo", "nihao", "zhongguo"]:
        avg, best = timeit(
            lambda t=text: engine.candidates(t, limit=30, fuzzy_rules=sim.FUZZY_DEFAULT_RULES), 300)
        print(f"    {text:<22} 平均 {avg:>7.3f} ms   最小 {best:>7.3f} ms")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())
