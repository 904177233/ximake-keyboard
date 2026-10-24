# -*- coding: utf-8 -*-
"""引擎行为仿真（仅用于验证 Swift 实现与 README 断言的一致性，不参与打包）。

本脚本用 Python 复刻 `PinyinEngine` / `PinyinDictionary` 的核心算法，
读真实的 `base_dict.tsv`，跑一遍 README 第 6 节的自测断言里可仿真的部分，
把"预期值"变成"实测值"。Windows 上无法编译 Swift，这是最接近的验证手段。

用法：
    python tools/dict/_simulate_engine.py
"""

from __future__ import annotations

import io
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from syllable_table import SYLLABLES  # noqa: E402

DICT_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "base_dict.tsv")
PHRASE_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "phrases.tsv")

MAX_TILE_LENGTH = 24
PREFIX_KEY_LIMIT = 40
MAX_INITIALS_QUERY_LENGTH = 6

# ---- 模糊音常量（对应 `ios/Shared/IMECore/FuzzyPinyin.swift`）----

# 声明顺序必须与 Swift `FuzzyPinyinRule.allCases` 完全一致，否则变体顺序会不同。
FUZZY_RULES = ("zh-z", "ch-c", "sh-s", "in-ing", "en-eng", "l-n", "an-ang", "ian-iang", "uan-uang")
FUZZY_DEFAULT_RULES = frozenset({"zh-z", "ch-c", "sh-s", "in-ing", "l-n"})
FUZZY_ALL_RULES = frozenset(FUZZY_RULES)
FUZZY_MAX_VARIANTS_PER_SYLLABLE = 4
FUZZY_MAX_CHANGED_SYLLABLES = 4
FUZZY_MAX_EXPANDED_VARIANTS = 24
FUZZY_MAX_MATCHES_PER_VARIANT = 8
FUZZY_MAX_PREFIX_KEYS_PER_VARIANT = 8
FUZZY_DISCOUNT = 0.85

# 组合切分的「每词代价」：抑制把长串切成大量单字碎片的路径（对应 Swift 同名常量）。
COMPOSED_TILE_PENALTY = 14.0


def cjk(ch: str) -> bool:
    """是否为汉字。"""
    code = ord(ch)
    return 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF


def is_pure_cjk(text: str) -> bool:
    """是否为纯汉字串（与 Swift `isPureCJK` 一致）。"""
    return bool(text) and all(cjk(c) for c in text)


def load_entries():
    """读词库，返回按词频降序的词条列表。"""
    rows = []
    with io.open(DICT_PATH, encoding="utf-8", newline="") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            pinyin, word, frequency, flags = line.split("\t")
            rows.append((pinyin, word, int(frequency), flags))
    rows.sort(key=lambda item: (-item[2], item[1], item[0]))
    return rows


def segment_exactly(pinyin: str, segments: int):
    """恰好切成 `segments` 个音节的 DP（对应 `PinyinSyllables.segment(_:exactly:)`）。"""
    if segments <= 0:
        return [] if not pinyin else None
    length = len(pinyin)
    table = [[None] * (segments + 1) for _ in range(length + 1)]
    table[0][0] = []
    for index in range(length):
        for used in range(segments):
            if table[index][used] is None:
                continue
            for size in range(1, 7):
                if index + size > length:
                    break
                syllable = pinyin[index:index + size]
                if syllable in SYLLABLES and table[index + size][used + 1] is None:
                    table[index + size][used + 1] = table[index][used] + [syllable]
    return table[length][segments]


def segment_min(pinyin: str):
    """最少音节切分（对应 `PinyinSyllables.segment(_:maxSegments:)`）。"""
    length = len(pinyin)
    best = [None] * (length + 1)
    best[0] = []
    for index in range(length):
        if best[index] is None:
            continue
        for size in range(1, 7):
            if index + size > length:
                break
            syllable = pinyin[index:index + size]
            if syllable not in SYLLABLES:
                continue
            candidate = best[index] + [syllable]
            if best[index + size] is None or len(candidate) < len(best[index + size]):
                best[index + size] = candidate
    return best[length]


class SimulatedDictionary:
    """对应 `PinyinDictionary`。"""

    def __init__(self, rows):
        self.rows = rows
        self.by_pinyin = {}
        for pinyin, word, frequency, flags in rows:
            self.by_pinyin.setdefault(pinyin, []).append((word, frequency, flags))
        self.keys = sorted(self.by_pinyin)
        self.text_frequency = {}
        for pinyin, word, frequency, flags in rows:
            self.text_frequency.setdefault(word, frequency)
        self.initials = {}
        for pinyin, word, frequency, flags in rows:
            if not is_pure_cjk(word):
                continue
            segments = segment_exactly(pinyin, len(word)) or segment_min(pinyin)
            if not segments:
                continue
            key = "".join(item[0] for item in segments)
            self.initials.setdefault(key, []).append(pinyin)
        for key in self.initials:
            self.initials[key].sort(key=lambda item: (-(self.by_pinyin[item][0][1]), item))
        self.initials_length_range = (
            min((len(key) for key in self.initials), default=0),
            max((len(key) for key in self.initials), default=0),
        )

    def exact_entries(self, pinyin, limit):
        return self.by_pinyin.get(pinyin, [])[:limit]

    def pinyin_keys_prefix(self, prefix, limit):
        """对应 Swift `pinyinKeys(prefix:limit:)`：二分定位后扫描 limit*8 个键再按词频排序截断。"""
        low, high = 0, len(self.keys)
        while low < high:
            mid = (low + high) // 2
            if self.keys[mid] < prefix:
                low = mid + 1
            else:
                high = mid
        scan_limit = limit * 8
        found = []
        index = low
        while index < len(self.keys) and len(found) < scan_limit:
            if not self.keys[index].startswith(prefix):
                break
            found.append(self.keys[index])
            index += 1
        found.sort(key=lambda item: (-(self.by_pinyin[item][0][1]), item))
        return found[:limit]

    def pinyin_keys_initials(self, initials, limit):
        return self.initials.get(initials, [])[:limit]

    def has_prefix(self, pinyin):
        if pinyin in self.by_pinyin:
            return True
        return bool(self.pinyin_keys_prefix(pinyin, 1))

    def frequency(self, text):
        return self.text_frequency.get(text, 0)


class SimulatedFuzzy:
    """对应 `ios/Shared/IMECore/FuzzyPinyin.swift` 的纯函数部分。"""

    @staticmethod
    def _append_digraph(digraph, single, base, raw):
        if base.startswith(digraph):
            raw.append(single + base[len(digraph):])
        elif base.startswith(single):
            raw.append(digraph + base[len(single):])

    @staticmethod
    def _append_final(long_final, short_final, base, excluding, raw):
        if any(base.endswith(item) for item in excluding):
            return
        if base.endswith(long_final):
            raw.append(base[: len(base) - (len(long_final) - len(short_final))])
        elif base.endswith(short_final):
            raw.append(base + long_final[len(short_final):])

    @classmethod
    def alternatives(cls, base, rules):
        """枚举单音节候选（未校验、未去重）。"""
        raw = []
        for rule in FUZZY_RULES:
            if rule not in rules:
                continue
            if rule == "zh-z":
                cls._append_digraph("zh", "z", base, raw)
            elif rule == "ch-c":
                cls._append_digraph("ch", "c", base, raw)
            elif rule == "sh-s":
                cls._append_digraph("sh", "s", base, raw)
            elif rule == "l-n":
                if len(base) >= 2:
                    if base.startswith("l"):
                        raw.append("n" + base[1:])
                    elif base.startswith("n"):
                        raw.append("l" + base[1:])
            elif rule == "in-ing":
                cls._append_final("ing", "in", base, [], raw)
            elif rule == "en-eng":
                cls._append_final("eng", "en", base, [], raw)
            elif rule == "an-ang":
                cls._append_final("ang", "an", base, ["iang", "uang"], raw)
            elif rule == "ian-iang":
                cls._append_final("iang", "ian", base, [], raw)
            elif rule == "uan-uang":
                cls._append_final("uang", "uan", base, [], raw)
        results = []
        seen = {base}
        for candidate in raw:
            if candidate == base or candidate not in SYLLABLES or candidate in seen:
                continue
            seen.add(candidate)
            results.append(candidate)
        return results

    @classmethod
    def variants(cls, syllable, rules, limit=8):
        """单音节变体（含自身且自身在第 0 位）。"""
        if limit <= 0:
            return []
        base = syllable.lower()
        if not base:
            return []
        results = [base]
        if not rules:
            return results
        cap = min(limit, FUZZY_MAX_VARIANTS_PER_SYLLABLE)
        seen = {base}
        for candidate in cls.alternatives(base, rules):
            if len(results) >= cap:
                break
            if candidate not in seen:
                seen.add(candidate)
                results.append(candidate)
        return results

    @staticmethod
    def split(normalized):
        """切音节 + 保留末尾不完整尾巴（对应 Swift `split(_:)`）。"""
        full = segment_min(normalized) if normalized in SYLLABLES else None
        if full is not None and "".join(full) == normalized:
            return full, ""
        cut = len(normalized) - 1
        while cut >= 1:
            head = normalized[:cut]
            if head in SYLLABLES:
                return [head], normalized[cut:]
            segmented = segment_min(head)
            if segmented is not None and "".join(segmented) == head:
                return segmented, normalized[cut:]
            cut -= 1
        return [], normalized

    @classmethod
    def _enumerate(cls, options, index, remaining, tail, buffer, results, seen, limit):
        if len(results) >= limit:
            return
        if index >= len(options):
            text = buffer + tail
            if text not in seen:
                seen.add(text)
                results.append(text)
            return
        choices = options[index]
        if not choices:
            return
        cls._enumerate(options, index + 1, remaining, tail, buffer + choices[0], results, seen, limit)
        if remaining <= 0:
            return
        for alternative in choices[1:]:
            cls._enumerate(options, index + 1, remaining - 1, tail,
                           buffer + alternative, results, seen, limit)
            if len(results) >= limit:
                return

    @classmethod
    def expand(cls, text, rules, limit=24):
        """整串变体（含原文且原文在第 0 位，按改动音节数从少到多）。"""
        if limit <= 0:
            return []
        base = text.lower()
        if not base:
            return []
        cap = min(limit, FUZZY_MAX_EXPANDED_VARIANTS)
        if not all(c.isascii() and c.isalpha() for c in base):
            return [base]
        if not rules:
            return [base]
        syllables, tail = cls.split(base)
        if not syllables:
            return [base]
        options = [cls.variants(item, rules, FUZZY_MAX_VARIANTS_PER_SYLLABLE) for item in syllables]
        results = []
        seen = set()
        budget = 0
        max_budget = min(len(options), FUZZY_MAX_CHANGED_SYLLABLES)
        while budget <= max_budget:
            cls._enumerate(options, 0, budget, tail, "", results, seen, cap)
            if len(results) >= cap:
                break
            budget += 1
        return results

    @classmethod
    def matches(cls, normalized, rules, dictionary):
        """模糊音在词库里的命中（精确 + 前缀，只保留纯汉字词条）。"""
        variants = cls.expand(normalized, rules, FUZZY_MAX_EXPANDED_VARIANTS)
        if len(variants) <= 1:
            return []
        results = []
        seen = set()
        for variant in variants[1:]:
            for word, frequency, flags in dictionary.exact_entries(variant, FUZZY_MAX_MATCHES_PER_VARIANT):
                if not is_pure_cjk(word) or word in seen:
                    continue
                seen.add(word)
                results.append((word, variant, frequency, True, 1.0))
            for key in dictionary.pinyin_keys_prefix(variant, FUZZY_MAX_PREFIX_KEYS_PER_VARIANT):
                if key == variant:
                    continue
                coverage = len(variant) / max(len(key), 1)
                for word, frequency, flags in dictionary.exact_entries(key, 2):
                    if not is_pure_cjk(word) or word in seen:
                        continue
                    seen.add(word)
                    results.append((word, key, frequency, False, coverage))
        return results


class SimulatedEngine:
    """对应 `PinyinEngine`（只复刻候选生成与排序，不含用户学习）。"""

    def __init__(self, dictionary):
        self.dict = dictionary

    @staticmethod
    def normalize(text):
        return "".join(c for c in text.lower() if c.isascii() and (c.isalpha() or c.isdigit()))

    @staticmethod
    def strip_trailing_selection(text):
        if not text or not text[-1].isdigit():
            return text
        cut = len(text)
        while cut > 0 and text[cut - 1].isdigit():
            cut -= 1
        if len(text) - cut > 2:
            return text
        head = text[:cut]
        if not head:
            return text
        if not all(c.isascii() and c.isalpha() for c in head):
            return text
        return head

    @staticmethod
    def log_score(frequency):
        return math.log(max(frequency, 0) + 1.0)

    @staticmethod
    def kind(text, flags):
        """对应 Swift `PinyinEngine.kind(for:)`：纯汉字 -> word；纯 ASCII 按含字母数字与否分
        english/punctuation；其余按 emoji/punct 标记。"""
        if is_pure_cjk(text):
            return "word"
        if text and all(ord(c) < 128 for c in text):
            has_alnum = any(c.isascii() and c.isalnum() for c in text)
            return "english" if has_alnum else "punctuation"
        if "emoji" in flags:
            return "emoji"
        if "punct" in flags:
            return "punctuation"
        return "word"

    def _insert(self, pool, text, pinyin, frequency, base, kind):
        if not text:
            return
        current = pool.get(text)
        rank = base + self.log_score(frequency)
        if current is None or rank > current["base"] + self.log_score(current["frequency"]):
            pool[text] = {
                "pinyin": pinyin,
                "frequency": frequency,
                "base": base,
                "kind": kind,
            }

    def _append_dictionary(self, pool, query):
        for word, frequency, flags in self.dict.exact_entries(query, 40):
            self._insert(pool, word, query, frequency, 2.0, self.kind(word, flags))
        for key in self.dict.pinyin_keys_prefix(query, PREFIX_KEY_LIMIT):
            if key == query:
                continue
            coverage = len(query) / max(len(key), 1)
            for word, frequency, flags in self.dict.exact_entries(key, 2):
                self._insert(pool, word, key, frequency, 1.0 * coverage, self.kind(word, flags))

    def _append_initials(self, pool, query):
        low, high = self.dict.initials_length_range
        if not (low <= len(query) <= high) or len(query) > MAX_INITIALS_QUERY_LENGTH:
            return
        for offset, key in enumerate(self.dict.pinyin_keys_initials(query, 24)):
            if offset >= 12:
                break
            for word, frequency, flags in self.dict.exact_entries(key, 1):
                self._insert(pool, word, key, frequency, 0.6 - offset * 0.05, self.kind(word, flags))

    def _append_composed(self, pool, query):
        if len(query) < 2:
            return
        if self.dict.exact_entries(query, 1):
            return
        chars = list(query)
        count = len(chars)
        best = [-float("inf")] * (count + 1)
        back = [-1] * (count + 1)
        tile_text = [None] * (count + 1)
        tile_frequency = [0] * (count + 1)
        tile_log = [0.0] * (count + 1)
        best[0] = 0.0
        for start in range(count):
            if not math.isfinite(best[start]):
                continue
            max_length = min(MAX_TILE_LENGTH, count - start)
            for size in range(1, max_length + 1):
                key = "".join(chars[start:start + size])
                hit = self.dict.exact_entries(key, 1)
                if not hit:
                    continue
                word, frequency, flags = hit[0]
                if "emoji" in flags or "punct" in flags:
                    continue
                if not any(cjk(c) for c in word):
                    continue
                log_term = self.log_score(frequency)
                score = best[start] + log_term - COMPOSED_TILE_PENALTY
                if score > best[start + size]:
                    best[start + size] = score
                    back[start + size] = start
                    tile_text[start + size] = word
                    tile_frequency[start + size] = frequency
                    tile_log[start + size] = log_term

        def path(end):
            pieces = []
            sum_log = 0.0
            cursor = end
            steps = 0
            while cursor > 0:
                steps += 1
                if steps > 64:
                    return None
                previous = back[cursor]
                if previous < 0 or tile_text[cursor] is None:
                    return None
                pieces.append(tile_text[cursor])
                sum_log += tile_log[cursor]
                cursor = previous
            if cursor != 0 or not pieces:
                return None
            return "".join(reversed(pieces)), len(pieces), sum_log

        if math.isfinite(best[count]):
            full = path(count)
            if full and full[1] >= 2:
                base = full[2] / full[1] + 1.2 * (full[1] - 1) + 1.5
                self._insert(pool, full[0], query, 0, base, "word")

        best_end = 0
        best_score = -float("inf")
        for end in range(1, count):
            if math.isfinite(best[end]) and best[end] > best_score:
                best_score = best[end]
                best_end = end
        if best_end <= 0:
            return
        head = path(best_end)
        if not head:
            return
        remainder = "".join(chars[best_end:count])
        for key in self.dict.pinyin_keys_prefix(remainder, 6):
            for word, frequency, flags in self.dict.exact_entries(key, 1):
                if "emoji" in flags or "punct" in flags:
                    continue
                if not any(cjk(c) for c in word):
                    continue
                base = head[2] / head[1] + 0.6 + 0.4 * (head[1] - 1)
                self._insert(pool, head[0] + word, query, 0, base, "word")

    def _append_english(self, pool, raw, query, has_candidates):
        text = raw.strip()
        if not text or not all(ord(c) < 128 for c in text):
            return
        has_digits = any(c.isdigit() for c in text)
        if not has_digits and has_candidates:
            return
        self._insert(pool, text, query or text.lower(), 0, 3.0 if has_digits else 2.2, "english")

    def _append_fuzzy(self, pool, query, pool_size, limit, rules):
        """对应 Swift `appendFuzzyCandidates`：精确候选不足时才用模糊变体，整体 ×0.85 降权。"""
        if not rules:
            return
        if len(query) < 2:
            return
        if pool_size >= limit:
            return
        for word, pinyin, frequency, is_exact, coverage in SimulatedFuzzy.matches(query, rules, self.dict):
            base = 2.0 * FUZZY_DISCOUNT if is_exact else 1.0 * coverage * FUZZY_DISCOUNT
            self._insert(pool, word, pinyin, frequency, base, self.kind(word, "core"))

    def candidates(self, raw, limit=30, fuzzy_rules=FUZZY_DEFAULT_RULES):
        if limit <= 0:
            return []
        stripped = raw.strip()
        if not stripped:
            return []
        selection_stripped = self.strip_trailing_selection(stripped)
        query = self.normalize(selection_stripped)
        pool = {}
        if query:
            self._append_dictionary(pool, query)
            self._append_initials(pool, query)
            self._append_composed(pool, query)
            self._append_fuzzy(pool, query, len(pool), limit, fuzzy_rules)
        # 与 Swift 一致：英文直通传入的是"去掉选词数字后"的串
        self._append_english(pool, selection_stripped, query, bool(pool))

        results = []
        for text, info in pool.items():
            score = (
                self.log_score(info["frequency"]) * 1.0
                + info["base"]
                - max(0, len(text) - 1) * 0.35
            )
            results.append((score, len(text), info["pinyin"], text, info["kind"]))
        results.sort(key=lambda item: (-item[0], item[1], item[2], item[3]))
        return [
            {"text": item[3], "pinyin": item[2], "score": item[0], "kind": item[4]}
            for item in results[:limit]
        ]

    def selection_index(self, raw):
        stripped = self.strip_trailing_selection(raw)
        if len(stripped) >= len(raw):
            return None
        digits = raw[len(stripped):]
        try:
            value = int(digits)
        except ValueError:
            return None
        return value - 1 if value >= 1 else None


def load_phrases():
    """读短语联想库。"""
    rows = []
    with io.open(PHRASE_PATH, encoding="utf-8", newline="") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            pinyin, trigger, text = line.split("\t")
            rows.append((pinyin, trigger, text))
    return rows


def check(label, actual, expected):
    """打印一条断言结果。"""
    if isinstance(expected, bool):
        passed = bool(actual) == expected
    else:
        passed = actual == expected
    mark = "PASS" if passed else "FAIL"
    print(f"[{mark}] {label}: 实测={actual!r} 预期={expected!r}")
    return passed


def main():
    rows = load_entries()
    dictionary = SimulatedDictionary(rows)
    engine = SimulatedEngine(dictionary)
    phrases = load_phrases()
    passed = 0
    total = 0

    def run(label, actual, expected):
        nonlocal passed, total
        total += 1
        if check(label, actual, expected):
            passed += 1

    print("=" * 78)
    print("墨语词库 + 引擎仿真自测（读真实 base_dict.tsv）")
    print("=" * 78)
    print(f"词库条数 = {len(rows)}，短语条数 = {len(phrases)}")
    print("-" * 78)

    print("[1] 词库加载")
    run("wordCount >= 3000", len(rows) >= 3000, True)
    run("lookup(zhongguo)[0]", dictionary.exact_entries("zhongguo", 1)[0][0], "中国")
    run("hasPrefix(zhongg)", dictionary.has_prefix("zhongg"), True)
    run("hasPrefix(zzzzz)", dictionary.has_prefix("zzzzz"), False)
    run("initials zg contains zhongguo", "zhongguo" in dictionary.pinyin_keys_initials("zg", 10), True)
    run("frequency(中国) > 0", dictionary.frequency("中国") > 0, True)
    run("exact(zhongguo) count == 1", len(dictionary.exact_entries("zhongguo", 5)), 1)

    print("-" * 78)
    print("[2] 候选生成")
    run('candidates("zg")[0]', engine.candidates("zg")[0]["text"], "中国")
    run('candidates("zhongguo")[0]', engine.candidates("zhongguo")[0]["text"], "中国")
    run('candidates("zhongg") 含 中国', any(c["text"] == "中国" for c in engine.candidates("zhongg")), True)
    run('candidates("nihao") 含 你好', any(c["text"] == "你好" for c in engine.candidates("nihao")), True)
    run('candidates("xiexie")[0]', engine.candidates("xiexie")[0]["text"], "谢谢")
    run('candidates("zaijian")[0]', engine.candidates("zaijian")[0]["text"], "再见")
    run('candidates("hh") 含 哈哈', any(c["text"] == "哈哈" for c in engine.candidates("hh")), True)
    run('candidates("yyds") 含 english', any(c["kind"] == "english" for c in engine.candidates("yyds")), True)
    run('candidates("2333")[0]', engine.candidates("2333")[0]["text"], "2333")
    run('candidates("") 为空', engine.candidates(""), [])
    run('candidates("   ") 为空', engine.candidates("   "), [])
    run('candidates("woxihuanni") 含 喜欢',
        any("喜欢" in c["text"] for c in engine.candidates("woxihuanni")), True)

    print("-" * 78)
    print("[3] 候选质量")
    run('candidates("zg") 数量 <= 30', len(engine.candidates("zg")) <= 30, True)
    scores = [c["score"] for c in engine.candidates("zg")]
    run('candidates("zg") 降序', scores == sorted(scores, reverse=True), True)
    texts = [c["text"] for c in engine.candidates("nihao")]
    run('candidates("nihao") 无重复', len(texts) == len(set(texts)), True)
    run('candidates("zhongguo")[0].kind', engine.candidates("zhongguo")[0]["kind"], "word")
    run("汉字候选 kind 全为 word",
        all(c["kind"] == "word" for c in engine.candidates("zhongguo") if is_pure_cjk(c["text"])), True)
    run('candidates("kaixin") 含 emoji',
        any(c["kind"] == "emoji" for c in engine.candidates("kaixin")), True)
    run('selectionIndex("zhongguo2")', engine.selection_index("zhongguo2"), 1)
    run('selectionIndex("zhongguo")', engine.selection_index("zhongguo"), None)
    run('candidates("zhongguo2") 不含整串英文',
        [c for c in engine.candidates("zhongguo2") if c["text"] == "zhongguo2"], [])
    ascii_words = [c["text"] for c in engine.candidates("yyds") if c["kind"] == "english"]
    run('candidates("yyds")[0].kind', engine.candidates("yyds")[0]["kind"], "english")

    print("-" * 78)
    print("[4] 短语库")
    triggers = {item[1] for item in phrases}
    run("短语条数 >= 300", len(phrases) >= 300, True)
    run('phrases 含触发词 "谢谢"', "谢谢" in triggers, True)
    run('phrases 含触发词 "晚安"', "晚安" in triggers, True)
    suggestions = [item[2] for item in phrases if item[1] == "谢谢"]
    run('谢谢 的建议含 "不客气"', any("不客气" in item for item in suggestions), True)

    print("-" * 78)
    print("[5] 词库数据质量")
    words = [row[1] for row in rows]
    run("无空词", [w for w in words if not w.strip()], [])
    run("无含空白词", [w for w in words if any(c.isspace() for c in w)], [])
    run("无重复词", len(words) - len(set(words)), 0)
    run("词频降序", all(rows[i][2] >= rows[i + 1][2] for i in range(len(rows) - 1)), True)
    bad_punct = [row[1] for row in rows if "punct" in row[3] and is_pure_cjk(row[1])]
    run("纯汉字词条无 punct 标记", bad_punct, [])
    run("总条数在 30000-50000", 30000 <= len(rows) <= 50000, True)

    print("-" * 78)
    print("[6] 模糊音（对应 ios/Shared/IMECore/FuzzyPinyin.swift）")
    run("规则数 == 9", len(FUZZY_RULES), 9)
    run("默认规则 == 前 5 条", sorted(FUZZY_DEFAULT_RULES),
        sorted(["zh-z", "ch-c", "sh-s", "in-ing", "l-n"]))
    run("variants(zhong, default)[0] 是自身", SimulatedFuzzy.variants("zhong", FUZZY_DEFAULT_RULES)[0], "zhong")
    run("variants(zhong, default) 含 zong", "zong" in SimulatedFuzzy.variants("zhong", FUZZY_DEFAULT_RULES), True)
    run("variants(zhong, 空规则) 只有自身", SimulatedFuzzy.variants("zhong", frozenset()), ["zhong"])
    run("variants(si, default) 含 shi", "shi" in SimulatedFuzzy.variants("si", FUZZY_DEFAULT_RULES), True)
    run("variants(lin, default) 含 nin", "nin" in SimulatedFuzzy.variants("lin", FUZZY_DEFAULT_RULES), True)
    run("variants(lin, 仅 zh-z) 不含 nin", "nin" in SimulatedFuzzy.variants("lin", frozenset({"zh-z"})), False)
    run("variants 单条上限 <= 4", len(SimulatedFuzzy.variants("zhuang", FUZZY_ALL_RULES, 8)) <= 4, True)
    run("variants 全是合法音节",
        all(item in SYLLABLES for item in SimulatedFuzzy.variants("zhuang", FUZZY_ALL_RULES)), True)
    run("expand(zhongguo)[0] 是原文", SimulatedFuzzy.expand("zhongguo", FUZZY_DEFAULT_RULES)[0], "zhongguo")
    run("expand(zhongguo) 含 zongguo", "zongguo" in SimulatedFuzzy.expand("zhongguo", FUZZY_DEFAULT_RULES), True)
    run("expand(zongguo) 含 zhongguo", "zhongguo" in SimulatedFuzzy.expand("zongguo", FUZZY_DEFAULT_RULES), True)
    run("expand 空串为空", SimulatedFuzzy.expand("", FUZZY_DEFAULT_RULES), [])
    run("expand 上限生效",
        len(SimulatedFuzzy.expand("zhongguorenmin", FUZZY_ALL_RULES, 5)) <= 5, True)
    run("expand(zongg) 含 zhongg（尾音节保留）",
        "zhongg" in SimulatedFuzzy.expand("zongg", FUZZY_DEFAULT_RULES), True)
    run("expand 按改动数排序（0 改在前 1 改在后）",
        SimulatedFuzzy.expand("zongguo", FUZZY_DEFAULT_RULES)[0], "zongguo")
    fuzzy_rules = frozenset({"zh-z"})
    run('candidates("zongguo") 精确无中文，模糊出 中国',
        any(c["text"] == "中国" for c in engine.candidates("zongguo", fuzzy_rules=fuzzy_rules)), True)
    exact = engine.candidates("zhongguo", fuzzy_rules=fuzzy_rules)
    run('candidates("zhongguo")[0] 仍是 中国（精确优先）', exact[0]["text"], "中国")
    run('candidates("zhongguo") 无重复',
        len([c["text"] for c in exact]) == len({c["text"] for c in exact}), True)
    no_fuzzy = engine.candidates("zongguo", fuzzy_rules=frozenset())
    run('candidates("zongguo") 关模糊后无 中国',
        any(c["text"] == "中国" for c in no_fuzzy), False)
    run("模糊折扣 = 0.85 且严格小于精确", (FUZZY_DISCOUNT == 0.85 and FUZZY_DISCOUNT < 1.0), True)
    # 用最小合成词库验证两条硬约束：①候选池已满时模糊不再跑（性能闸门）②模糊命中排在精确之后。
    syn_rows = [
        ("zhongguo", "中国", 1000, "core"),
        ("zhongguo", "种国", 900, "core"),
        ("zhongguo", "仲国", 800, "core"),
        ("zongguo", "宗国", 700, "core"),
    ]
    syn_engine = SimulatedEngine(SimulatedDictionary(syn_rows))
    syn_rules = frozenset({"zh-z"})
    run("候选池已满时模糊候选不挤入",
        [c["text"] for c in syn_engine.candidates("zhongguo", limit=3, fuzzy_rules=syn_rules)],
        ["中国", "种国", "仲国"])
    run("有空间时模糊候选追加且排在精确之后",
        [c["text"] for c in syn_engine.candidates("zhongguo", limit=10, fuzzy_rules=syn_rules)],
        ["中国", "种国", "仲国", "宗国"])
    run("关闭模糊时合成词库无 宗国",
        [c["text"] for c in syn_engine.candidates("zhongguo", limit=10, fuzzy_rules=frozenset())],
        ["中国", "种国", "仲国"])
    run('candidates("nihaoo") 仍返回候选（模糊不污染）',
        len(engine.candidates("nihaoo", fuzzy_rules=fuzzy_rules)) > 0, True)

    print("=" * 78)
    print(f"结果：{passed} / {total} 通过")
    print("=" * 78)
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
