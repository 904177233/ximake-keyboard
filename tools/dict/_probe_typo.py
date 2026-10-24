"""输入纠错（TypoCorrector）性能探针。

用途：Windows 无 Swift 环境，用 Python 逐行复刻 `ios/Shared/IMECore/TypoCorrector.swift`
的算法（复用 `FuzzyPinyin` 的 9 条规则 + 编辑距离 1），读**真实**词库 `base_dict.tsv`
判定「词库里是否有词」，测量 `correct()` 在典型输入下的耗时与产出。

注意：Python 解释执行比 Swift 慢 3-10 倍，报出的数字是**上界**；真机耗时应以
Xcode 上的 `measure {}` 为准（Swift 侧同类逻辑通常在 0.01-0.1ms）。

用法：
    python tools/dict/_probe_typo.py
    python tools/dict/_probe_typo.py --repeat 200
"""

from __future__ import annotations

import argparse
import io
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICT_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "base_dict.tsv")
TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS_DIR)

from syllable_table import SYLLABLES  # noqa: E402

# 与 Swift `FuzzyPinyinRule` / `FuzzyPinyin` 常量对齐。
FUZZY_RULES = [
    ("zh/z", "zh", "z"),
    ("ch/c", "ch", "c"),
    ("sh/s", "sh", "s"),
    ("in/ing", "ing", "in"),
    ("en/eng", "eng", "en"),
    ("l/n", "l", "n"),
    ("an/ang", "ang", "an"),
    ("ian/iang", "iang", "ian"),
    ("uan/uang", "uang", "uan"),
]
MAX_VARIANTS_PER_SYLLABLE = 4
MAX_CHANGED_SYLLABLES = 4
MAX_EXPANDED_VARIANTS = 24
MAX_EDIT_ONE_VARIANTS = 64
MAX_INPUT_LENGTH = 8
ALPHABET = "abcdefghijklmnopqrstuvwxyz"

SYLLABLE_SET = set(SYLLABLES)

# 代表性用例：正确输入（不该被改坏）+ 典型错拼（应被纠出来）。
CASES = [
    ("nihao", "正确输入"),
    ("zhongguo", "正确输入"),
    ("xihuan", "正确输入"),
    ("woxihuanni", "正确输入"),
    ("nihaoma", "正确输入"),
    ("zhongg", "前缀输入"),
    ("zongguo", "zh/z 错拼"),
    ("cifan", "ch/c 错拼"),
    ("sishi", "sh/s 错拼"),
    ("jinwan", "in/ing 错拼"),
    ("lin", "l/n 错拼"),
    ("nihaoo", "多打字母"),
    ("niha", "漏打字母"),
    ("zongg", "zh/z + 前缀"),
    ("shi", "正确输入"),
    ("s", "单字母"),
]


def load_pinyin_keys(path):
    """读出词库里的全部全拼键（等价于 Swift 侧 `dictionary` 的键集合）。"""
    keys = set()
    with io.open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n").rstrip("\r")
            if not line or line.startswith("#") or line.startswith("\ufeff"):
                continue
            fields = line.split("\t")
            if len(fields) < 3:
                continue
            key = fields[0].strip().lower()
            if key:
                keys.add(key)
    return keys


def build_prefixes(keys):
    """预建前缀集合：`knownInitials(x)` 等价于「词库里有以 x 为前缀的键」。"""
    prefixes = set()
    for key in keys:
        for index in range(1, len(key) + 1):
            prefixes.add(key[:index])
    return prefixes


def variants_of(syllable, rules=None, limit=8):
    """复刻 `FuzzyPinyin.variants(of:rules:)`（单音节；rules=None 表示全部 9 条）。"""
    base = syllable.lower()
    out = [base]
    seen = {base}
    if base not in SYLLABLE_SET:
        return out
    selected = FUZZY_RULES if rules is None else [r for r in FUZZY_RULES if r[0] in rules]
    candidates = []
    for _, long_form, short_form in selected:
        if base.startswith(long_form) and len(base) > len(long_form):
            candidates.append(short_form + base[len(long_form):])
        elif base.startswith(short_form):
            candidates.append(long_form + base[len(short_form):])
        if base.endswith(long_form) and len(base) > len(long_form):
            candidates.append(base[: len(base) - len(long_form)] + short_form)
        elif base.endswith(short_form):
            candidates.append(base[: len(base) - len(short_form)] + long_form)
    cap = min(limit, MAX_VARIANTS_PER_SYLLABLE)
    for candidate in candidates:
        if len(out) >= cap:
            break
        if candidate != base and candidate in SYLLABLE_SET and candidate not in seen:
            seen.add(candidate)
            out.append(candidate)
    return out[:cap]


def segment_syllables(text):
    """复刻 `PinyinSyllables.segment(_:)`：返回「最少音节」的切分，不可切返回 None。"""
    length = len(text)
    best = [None] * (length + 1)
    best[0] = []
    for start in range(length):
        if best[start] is None:
            continue
        for size in range(1, 7):
            if start + size > length:
                break
            piece = text[start:start + size]
            if piece not in SYLLABLE_SET:
                continue
            candidate = best[start] + [piece]
            if best[start + size] is None or len(candidate) < len(best[start + size]):
                best[start + size] = candidate
    return best[length]


def split_input(normalized):
    """复刻 `FuzzyPinyin.split(_:)`：返回（音节列表, 末尾未切完的尾巴）。"""
    full = segment_syllables(normalized)
    if full is not None:
        return full, ""
    for cut in range(len(normalized) - 1, 0, -1):
        head = segment_syllables(normalized[:cut])
        if head is not None:
            return head, normalized[cut:]
    return [], normalized


def expand_input(normalized, rules=None, limit=24):
    """复刻 `FuzzyPinyin.expand(_:rules:limit:)`：整串级变体，按改动音节数递增。"""
    cap = min(limit, MAX_EXPANDED_VARIANTS)
    base = normalized.lower()
    if not base or not base.isascii() or not base.isalpha():
        return [base]
    syllables, tail = split_input(base)
    if not syllables:
        return [base]
    options = [variants_of(syllable, rules=rules) for syllable in syllables]
    out = []
    seen = {base}

    def walk(index, remaining, buffer):
        if len(out) >= cap:
            return
        if index == len(options):
            text = "".join(buffer) + tail
            if text not in seen:
                seen.add(text)
                out.append(text)
            return
        walk(index + 1, remaining, buffer + [options[index][0]])
        if remaining > 0:
            for choice in options[index][1:]:
                walk(index + 1, remaining - 1, buffer + [choice])

    for budget in range(min(len(options), MAX_CHANGED_SYLLABLES) + 1):
        walk(0, budget, [])
        if len(out) >= cap:
            break
    return out[:cap]


def edit_one_variants(base):
    """复刻 `TypoCorrector.editOneCorrections`：漏打（删除 / 末尾补字母）+ 多打（插入）。"""
    out = []
    seen = {base}
    chars = list(base)
    for index in range(len(chars)):
        candidate = "".join(chars[:index] + chars[index + 1:])
        if candidate and candidate not in seen:
            seen.add(candidate)
            out.append((candidate, 0.60, "漏打字母"))
            if len(out) >= MAX_EDIT_ONE_VARIANTS:
                return out
    # 末尾补一个字母：最常见的「漏打」形态（`niha` → `nihao`），置信度高于删除类。
    for letter in ALPHABET:
        candidate = "".join(chars + [letter])
        if candidate and candidate not in seen:
            seen.add(candidate)
            out.append((candidate, 0.62, "漏打字母"))
            if len(out) >= MAX_EDIT_ONE_VARIANTS:
                return out
    # 其它位置插入一个字母，按「末尾优先」排列：
    # 若从位置 0 开始枚举，26 个字母会先把 64 条上限占满，末尾位置的候选永远排不进来。
    for index in range(len(chars)):
        for letter in ALPHABET:
            candidate = "".join(chars[:index] + [letter] + chars[index:])
            if candidate and candidate not in seen:
                seen.add(candidate)
                out.append((candidate, 0.50, "多打字母"))
                if len(out) >= MAX_EDIT_ONE_VARIANTS:
                    return out
    return out


def is_splittable(text):
    """复刻 `PinyinSyllables.isSyllable(x) || segment(x) != nil`。"""
    if text in SYLLABLE_SET:
        return True
    length = len(text)
    best = [False] * (length + 1)
    best[0] = True
    for start in range(length):
        if not best[start]:
            continue
        for size in range(1, 7):
            if start + size > length:
                break
            if text[start:start + size] in SYLLABLE_SET:
                best[start + size] = True
    return best[length]


def correct(base, prefixes, limit=3):
    """复刻 `TypoCorrector.correct`。"""
    if limit <= 0 or not base or len(base) > MAX_INPUT_LENGTH:
        return []
    if not base.isascii() or not base.isalpha() or not base.islower():
        return []

    best = {}

    def record(corrected, confidence, rule):
        if corrected in best:
            if confidence > best[corrected][0]:
                best[corrected] = (confidence, rule)
            return
        best[corrected] = (confidence, rule)

    # 1) 声韵母规则（复用 FuzzyPinyin 的规则表）。
    if base in SYLLABLE_SET:
        # 单音节：逐条规则单独调用，便于把命中的规则名带回。
        for rule_name, _, _ in FUZZY_RULES:
            for variant in variants_of(base, rules={rule_name}):
                if variant != base:
                    record(variant, 0.62, rule_name)
    else:
        # 多音节整串：用 expand 取「改一个音节」那层。
        for variant in expand_input(base, rules=None, limit=MAX_EXPANDED_VARIANTS):
            if variant != base:
                record(variant, 0.66, "声韵母")
    # 2) 编辑距离 1。
    for candidate, confidence, rule in edit_one_variants(base):
        record(candidate, confidence, rule)

    results = []
    for corrected, (confidence, rule) in best.items():
        if not is_splittable(corrected):
            continue
        if corrected not in prefixes:
            continue
        results.append((corrected, confidence, rule))
    results.sort(key=lambda item: (-item[1], len(item[0]), item[0]))
    return results[:limit]


def main(argv=None):
    parser = argparse.ArgumentParser(description="输入纠错性能探针（Python 复刻）")
    parser.add_argument("--repeat", type=int, default=50, help="每条用例重复次数（默认 50）")
    args = parser.parse_args(argv)

    if not os.path.isfile(DICT_PATH):
        print("[错误] 找不到词库：%s" % DICT_PATH)
        return 2

    keys = load_pinyin_keys(DICT_PATH)
    prefixes = build_prefixes(keys)
    print("词库：%s（%d 个全拼键 / %d 个前缀）" % (DICT_PATH, len(keys), len(prefixes)))
    print("=" * 78)

    total = 0.0
    slowest = 0.0
    slowest_case = ""
    outputs = []
    for raw, label in CASES:
        start = time.perf_counter()
        for _ in range(args.repeat):
            results = correct(raw, prefixes, limit=3)
        elapsed = (time.perf_counter() - start) / args.repeat * 1000.0
        total += elapsed
        if elapsed > slowest:
            slowest = elapsed
            slowest_case = raw
        outputs.append((raw, label, elapsed, results))
        rendered = "、".join("%s(%s,%.2f)" % (c[0], c[2], c[1]) for c in results) or "（无）"
        print("  %-12s %-14s %7.3f ms   纠错 → %s" % (raw, label, elapsed, rendered))

    print("=" * 78)
    print("用例数 %d 条 × 重复 %d 次" % (len(CASES), args.repeat))
    print("平均 %.4f ms / 最慢 %.4f ms（%s）" % (total / len(CASES), slowest, slowest_case))
    print("→ Python 解释执行比 Swift 慢 3-10 倍，上述数字是上界；")
    print("  Swift 侧 `TypoCorrector.correct` 实测目标 ≤1ms（设计上限：9 次规则变体 + ≤64 次编辑距离候选）。")
    print("=" * 78)

    # 关键行为断言（与 README 自测清单一致）。
    first = dict((raw, results) for raw, _, _, results in outputs)
    checks = [
        ("zongguo 能纠出 zhongguo", any(c[0] == "zhongguo" for c in first["zongguo"])),
        ("nihaoo 能纠出 nihao", any(c[0] == "nihao" for c in first["nihaoo"])),
        ("niha 能纠出 nihao", any(c[0] == "nihao" for c in first["niha"])),
        ("nihao 不会被改坏（不产出自身）", not any(c[0] == "nihao" for c in first["nihao"])),
        ("单字母 s 不产出 2 字以上噪声", all(len(c[0]) <= 2 for c in first["s"])),
        ("所有纠错结果都是合法拼音串", all(is_splittable(c[0]) for _, _, _, rs in outputs for c in rs)),
        ("所有纠错结果都在词库前缀里", all(c[0] in prefixes for _, _, _, rs in outputs for c in rs)),
        ("limit=0 返回空", correct("zongguo", prefixes, limit=0) == []),
        ("超长输入返回空", correct("zhongguorenmin", prefixes) == []),
        ("非字母输入返回空", correct("nihao2", prefixes) == []),
    ]

    passed = 0
    for name, ok in checks:
        print("[%s] %s" % ("PASS" if ok else "FAIL", name))
        passed += 1 if ok else 0
    print("=" * 78)
    print("结果：%d / %d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
