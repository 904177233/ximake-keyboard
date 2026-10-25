"""词库加载耗时分解探针（仅本机诊断用，不参与构建）。

用途：为「`IMEKit` 初始化是否可能阻塞首帧」提供量化依据。

两条耗时线必须分开看，混在一起会得出错误结论：

1. **同步加载**（进首帧）＝ 读文件 + 解码 + 逐行解析 + 按全拼分组 + 排序键 + 聊天权重表。
   这一段进 `PinyinDictionary.loadDurationMilliseconds`，预算 **80 ms**。
2. **首字母索引 DP**（懒加载）＝ 33k 条词跑音节切分 DP。它由 `ensureInitialsIndex()`
   在**第一次打简拼时**构建，不在启动路径上，所以**不计入上面那段预算**；但它决定
   第一次打 `wq` 的延迟，因此单独测、单独报。

冷/热各测一次：冷＝进程内首次（页缓存未命中），热＝紧接着再跑一次（页缓存命中）。

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
CHAT_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "chat_priority.tsv")

BUDGET_MS = 80.0


def measure_sync(path):
    """测同步加载的五段耗时，返回 (各段毫秒列表, 条数, 全拼键数)。"""
    start = time.perf_counter()
    raw = open(path, "rb").read()
    t_read = time.perf_counter()
    text = raw.decode("utf-8")
    t_decode = time.perf_counter()

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
    t_parse = time.perf_counter()

    grouped = {}
    for row in rows:
        grouped.setdefault(row[0], []).append(row)
    t_group = time.perf_counter()

    keys = sorted(grouped.keys())
    t_sort = time.perf_counter()

    stages = [
        ("1. 读文件", (t_read - start) * 1000.0),
        ("2. UTF-8 解码", (t_decode - t_read) * 1000.0),
        ("3. 逐行解析", (t_parse - t_decode) * 1000.0),
        ("4. 按全拼分组", (t_group - t_parse) * 1000.0),
        ("5. 排序键数组", (t_sort - t_group) * 1000.0),
    ]
    return stages, (t_sort - start) * 1000.0, len(raw), len(rows), len(keys)


def measure_chat(path):
    """测聊天权重表加载；文件缺失返回 (0.0, 0)。"""
    if not os.path.exists(path):
        return 0.0, 0
    start = time.perf_counter()
    text = open(path, "rb").read().decode("utf-8")
    table = {}
    for line in text.split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        try:
            weight = float(fields[1])
        except ValueError:
            continue
        if 1.0 <= weight <= 3.0:
            table[fields[0]] = max(table.get(fields[0], 0.0), weight)
    return (time.perf_counter() - start) * 1000.0, len(table)


def measure_initials_dp(rows):
    """测首字母索引的懒加载 DP（首次打简拼时触发，不在启动路径上）。"""
    start = time.perf_counter()
    count = 0
    for pinyin, word, _frequency, _flags in rows:
        if not sim.is_pure_cjk(word):
            continue
        sim.segment_exactly(pinyin, len(word)) or sim.segment_min(pinyin)
        count += 1
    return (time.perf_counter() - start) * 1000.0, count


def main():
    if not os.path.exists(DICT_PATH):
        print("词库不存在：%s" % DICT_PATH)
        return 1

    cold_stages, cold_total, raw_bytes, row_count, key_count = measure_sync(DICT_PATH)
    warm_stages, warm_total, _, _, _ = measure_sync(DICT_PATH)
    chat_ms, chat_count = measure_chat(CHAT_PATH)
    dp_ms, dp_count = measure_initials_dp(_iter_rows(DICT_PATH))

    print("词库：%s" % DICT_PATH)
    print("      %d 字节 / %d 条 / %d 个全拼键" % (raw_bytes, row_count, key_count))
    print("")
    print("阶段                              冷（首次）      热（第二次）")
    print("-" * 66)
    for (label, cold), (_same, warm) in zip(cold_stages, warm_stages):
        print("%-30s %10.2f ms %10.2f ms" % (label, cold, warm))
    print("-" * 66)
    print("%-30s %10.2f ms %10.2f ms" % ("同步加载合计（进首帧）", cold_total, warm_total))
    chat_total_cold = cold_total + chat_ms
    print("%-30s %10.2f ms %10.2f ms" % ("  + 聊天权重表（%d 条）" % chat_count, chat_ms, chat_ms))
    print("%-30s %10.2f ms %10.2f ms" % ("预算 80 ms 的实测值", chat_total_cold, warm_total + chat_ms))
    print("")
    print("首字母索引 DP（懒加载，首次打简拼时触发，不计入启动）")
    print("%-30s %10.2f ms（%d 条纯汉字）" % ("6. 音节切分 DP", dp_ms, dp_count))
    print("")
    verdict = chat_total_cold <= BUDGET_MS
    print("结论：同步加载冷启动 %.2f ms，%s %.0f ms 预算（Python 上界；Swift 通常快 3-10 倍）"
          % (chat_total_cold, "未超过" if verdict else "超过", BUDGET_MS))
    if not verdict:
        print("      超出部分主要来自逐行解析，可考虑词库分片或二进制预编索引。")
    return 0


def _iter_rows(path):
    """按需逐行读词库（避免和 measure_sync 共用一份已被回收的内存）。"""
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8")
    for line in text.split("\n"):
        if line.endswith("\r"):
            line = line[:-1]
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        yield (fields[0], fields[1], int(fields[2]), fields[3] if len(fields) > 3 else "")


if __name__ == "__main__":
    sys.exit(main())
