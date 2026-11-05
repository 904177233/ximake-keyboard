#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语 3.0 词库生成器：产出键盘直接内存映射的 ios/Shared/dict/moyu.dict。

为什么换成二进制
----------------
旧版把 3.3 万行 TSV 读进内存再建哈希表，冷启动几十毫秒、常驻十几兆，再扩词库键盘就会被
系统杀掉。新格式是排好序的定长表，用 mmap 打开后按需读页：不解析、不占脏内存，
十几万词也和几千词一样快。

数据来源（都在本地，脚本不联网）
  - .cache/jieba_dict.txt   jieba 词频表（MIT），占绝大多数词条
  - source/base_dict_v1.tsv 旧版词库，带聊天用语、网络词、表情别名和人工调过的词频
  - ../../ios/Shared/dict/chat_priority.tsv 聊天高频词权重（简拼排序用）
  - extra_words.tsv         手工补充和纠偏（词<TAB>词频）
  - pypinyin                读音；单字收录全部读音（旧版只有默认读音，打 huan 出不来「还」）

文件格式（小端，所有区段 4 字节对齐）
  头 64 字节：magic 'MYD3'，随后是 u32：formatVersion, entryCount, keyCount, offKeys, offEntries,
              offT9Perm, offInitPerm, offT9InitPerm, offBlob, t9PermCount, initPermCount,
              t9InitPermCount, 余下保留
  键表  每条 20 字节：keyOff u32, firstEntry u32, maxFreq u32, sylMask u32,
                       entryCount u16, keyLen u8, sylCount u8
        按 (拼音串, sylMask) 升序。同一个串可以有多条（xian = 先 / xi'an = 西安），音节切法不同。
        sylMask 第 i 位为 1 表示第 i 个字母是音节开头，用来算首字母和显示分词。
  词表  每条 12 字节：textOff u32, freq u32, textLen u8, flags u8, 保留 u16
        flags：bit0 表情，bit1 标点，bit2 聊天词，bit3 非汉字（英文/数字），高 4 位 = 聊天权重×5
  T9 排列      u32 键下标，按 (九宫格数字串, 最高词频降序)
  首字母排列    u32 键下标，按 (首字母串, 最高词频降序)
  T9 首字母排列 u32 键下标，按 (首字母的数字串, 最高词频降序)，只收 2 个音节以上的词
  字符串池      拼音串和词文本

用法
  python tools/dict/build_binary.py          生成词库和下一词表（next.tsv）
  python tools/dict/build_binary.py --eval   生成后用常见句子测一遍整句转换
"""
from __future__ import annotations

import argparse
import json
import math
import re
import struct
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from syllable_table import SYLLABLES  # noqa: E402

OUT_DIR = ROOT / "ios" / "Shared" / "dict"
JIEBA = HERE / ".cache" / "jieba_dict.txt"
BASE_V1 = HERE / "source" / "base_dict_v1.tsv"
EXTRA = HERE / "extra_words.tsv"
CHAT_PRIORITY = OUT_DIR / "chat_priority.tsv"
NEXT_WORDS = HERE / "next_words.tsv"
#: 词频低于这个的词不拿来推「后半截」联想。
COMPOUND_MIN_FREQ = 200

DICT_VERSION = "3.0.0"
GENERATED_DATE = "2026-11-05"

#: jieba 词频下限。词频再低的多是专名和噪声，收进来只会占地方。
MIN_FREQ = 5
MAX_WORD_LEN = 8
PERSON_POS = {"nr", "nrt", "nrx", "nrfg"}
MIN_FREQ_BY_POS = {"ns": 200, "nt": 300, "nz": 800, **{p: 1500 for p in PERSON_POS}}
#: 聊天词在语料里被低估（jieba 来自新闻和人民日报），统一抬高一些。
CHAT_FREQ_BOOST = 6
#: 单字非默认读音的词频折扣和上限。
#: 必须有上限：「不」本身词频极高，打八折读成 fu 还是比「服」高，整句就会选错。
ALT_READING_DISCOUNT = 0.12
ALT_READING_CAP = 3000

CJK = re.compile(r"^[一-鿿]+$")
SYL_SET = frozenset(SYLLABLES)
T9_MAP = {c: str(i + 2) for i, group in enumerate("abc def ghi jkl mno pqrs tuv wxyz".split()) for c in group}

FLAG_EMOJI, FLAG_PUNCT, FLAG_CHAT, FLAG_ASCII = 1, 2, 4, 8


def to_t9(text: str) -> str:
    return "".join(T9_MAP.get(c, "") for c in text)


def segment(key: str, exactly: int | None = None) -> list[str] | None:
    """把连写拼音切成音节。给了 exactly 时要求音节数相等，否则取最少音节。"""
    n = len(key)
    if exactly is not None:
        memo: dict[tuple[int, int], list[str] | None] = {}

        def walk(pos: int, left: int) -> list[str] | None:
            if pos == n:
                return [] if left == 0 else None
            if left == 0:
                return None
            state = (pos, left)
            if state in memo:
                return memo[state]
            for size in range(min(6, n - pos), 0, -1):
                piece = key[pos:pos + size]
                if piece in SYL_SET:
                    rest = walk(pos + size, left - 1)
                    if rest is not None:
                        memo[state] = [piece] + rest
                        return memo[state]
            memo[state] = None
            return None

        found = walk(0, exactly)
        if found is not None:
            return found
    best: list[list[str] | None] = [None] * (n + 1)
    best[0] = []
    for i in range(n):
        if best[i] is None:
            continue
        for size in range(min(6, n - i), 0, -1):
            piece = key[i:i + size]
            if piece in SYL_SET:
                cand = best[i] + [piece]
                if best[i + size] is None or len(cand) < len(best[i + size]):
                    best[i + size] = cand
    return best[n]


def mask_of(syllables: list[str]) -> int:
    mask = 0
    pos = 0
    for syllable in syllables:
        if pos < 32:
            mask |= 1 << pos
        pos += len(syllable)
    return mask


def initials_of(key: str, mask: int) -> str:
    return "".join(key[i] for i in range(min(len(key), 32)) if mask >> i & 1)


class Builder:
    def __init__(self) -> None:
        # (key, mask) -> {text: [freq, flags]}
        self.table: dict[tuple[str, int], dict[str, list[int]]] = defaultdict(dict)
        self.stats: Counter[str] = Counter()

    def add(self, key: str, syllables: list[str] | None, text: str, freq: int, flags: int) -> None:
        if not key or not text or len(key) > 40:
            return
        mask = mask_of(syllables) if syllables else 0
        slot = self.table[(key, mask)]
        current = slot.get(text)
        if current is None:
            slot[text] = [int(freq), flags]
        else:
            current[0] = max(current[0], int(freq))
            current[1] |= flags


def load_chat_weights() -> dict[str, float]:
    weights: dict[str, float] = {}
    if CHAT_PRIORITY.exists():
        for line in CHAT_PRIORITY.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                try:
                    weights[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    return weights


def load_next_words() -> dict[str, list[str]]:
    table: dict[str, list[str]] = {}
    for line in NEXT_WORDS.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or "\t" not in line:
            continue
        head, rest = line.split("\t", 1)
        table[head] = rest.split()
    return table


def write_next_words(builder: Builder, path: Path) -> int:
    """手工表 + 从词库推出来的后半截（今 -> 天、年、晚），写成 next.tsv。"""
    authored = load_next_words()
    known = set()
    weights: dict[str, Counter[str]] = defaultdict(Counter)
    for (_key, _mask), words in builder.table.items():
        for text, (freq, flags) in words.items():
            if flags & (FLAG_EMOJI | FLAG_PUNCT | FLAG_ASCII) or not CJK.match(text):
                continue
            known.add(text)
            if not 2 <= len(text) <= 4 or freq < COMPOUND_MIN_FREQ:
                continue
            for cut in range(1, len(text)):
                # 后半截太长就不像「下一个词」了（今 -> 天天气）
                if len(text) - cut <= 2:
                    weights[text[:cut]][text[cut:]] += freq
    lines = []
    for head in sorted(set(authored) | {h for h in weights if len(h) == 1 or h in known}):
        words = authored.get(head, [])
        rest = [w for w, _ in weights[head].most_common(14) if w not in words][:10] if head in weights else []
        if words or rest:
            lines.append(f"{head}\t{' '.join(words)}\t{' '.join(rest)}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(lines)


def collect() -> Builder:
    from pypinyin import Style, lazy_pinyin, pinyin

    builder = Builder()
    chat_weights = load_chat_weights()

    def chat_bits(word: str) -> int:
        weight = chat_weights.get(word, 0.0)
        return (min(15, int(round(weight * 5))) << 4) if weight else 0

    # ① 旧词库：聊天词、网络词、表情、标点，词频人工调过，优先保留
    v1_texts: dict[str, int] = {}
    for line in BASE_V1.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        key, word, freq = parts[0], parts[1], int(parts[2])
        tags = set((parts[3] if len(parts) > 3 else "").split(","))
        flags = chat_bits(word)
        if "emoji" in tags:
            flags |= FLAG_EMOJI
        if "punct" in tags:
            flags |= FLAG_PUNCT
        if "chat" in tags:
            flags |= FLAG_CHAT
            # 只抬多字词。单字本来就高频，再抬就会把词切碎成一串单字（有时间 -> 有是见）。
            if len(word) >= 2:
                freq *= CHAT_FREQ_BOOST
        if not CJK.match(word):
            flags |= FLAG_ASCII if word.isascii() else 0
        syllables = segment(key, len(word) if CJK.match(word) else None)
        builder.add(key, syllables, word, freq, flags)
        v1_texts[word] = freq
        builder.stats["v1"] += 1

    # ② jieba：补足十万级通用词
    rows = []
    for line in JIEBA.read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            rows.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))

    support: Counter[str] = Counter()
    single_freq: dict[str, int] = {}
    for word, freq, _pos in rows:
        if not CJK.match(word):
            continue
        if len(word) == 1:
            single_freq[word] = freq
        if freq >= 30:
            for ch in set(word):
                support[ch] += 1
    keep_chars = {ch for ch, count in support.items() if count >= 2} | {c for c, f in single_freq.items() if f >= 80}

    for word, freq, pos in rows:
        if not CJK.match(word) or len(word) > MAX_WORD_LEN or word in v1_texts:
            continue
        if freq < MIN_FREQ or not all(ch in keep_chars for ch in word):
            builder.stats["jieba_skip"] += 1
            continue
        if len(word) > 1 and freq < MIN_FREQ_BY_POS.get(pos, 0):
            builder.stats["jieba_proper"] += 1
            continue
        syllables = [s.lower() for s in lazy_pinyin(word)]
        if not all(s in SYL_SET for s in syllables):
            builder.stats["jieba_badpy"] += 1
            continue
        builder.add("".join(syllables), syllables, word, freq, chat_bits(word))
        builder.stats["jieba"] += 1

    # ③ 单字的其它读音
    for char, freq in single_freq.items():
        if char not in keep_chars:
            continue
        readings = pinyin(char, style=Style.NORMAL, heteronym=True)[0]
        base = freq
        for reading in readings[1:6]:
            reading = reading.lower()
            if reading in SYL_SET:
                builder.add(reading, [reading], char, min(ALT_READING_CAP, max(8, int(base * ALT_READING_DISCOUNT))), 0)
                builder.stats["alt_reading"] += 1

    # ④ 手工补充与纠偏：可以覆盖词频
    if EXTRA.exists():
        for line in EXTRA.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            word, freq = parts[0], int(parts[1])
            syllables = [s.lower() for s in lazy_pinyin(word)]
            if not all(s in SYL_SET for s in syllables):
                continue
            key = "".join(syllables)
            slot = builder.table[(key, mask_of(syllables))]
            flags = slot.get(word, [0, 0])[1] | FLAG_CHAT | chat_bits(word)
            slot[word] = [freq, flags]
            builder.stats["extra"] += 1
    return builder


def write_binary(builder: Builder, path: Path) -> dict:
    blob = bytearray()
    interned: dict[bytes, int] = {}

    def intern(data: bytes) -> int:
        if data in interned:
            return interned[data]
        offset = len(blob)
        blob.extend(data)
        interned[data] = offset
        return offset

    keys = sorted(builder.table.keys())
    key_records: list[bytes] = []
    entry_records: list[bytes] = []
    meta: list[tuple[str, int, int]] = []  # key, mask, maxFreq
    for key, mask in keys:
        entries = sorted(builder.table[(key, mask)].items(), key=lambda kv: (-kv[1][0], kv[0]))
        first = len(entry_records)
        for text, (freq, flags) in entries[:255]:
            raw = text.encode("utf-8")
            if len(raw) > 255:
                continue
            entry_records.append(struct.pack("<IIBBH", intern(raw), min(freq, 0xFFFFFFFF), len(raw), flags & 0xFF, 0))
        count = len(entry_records) - first
        max_freq = entries[0][1][0] if entries else 0
        raw_key = key.encode("ascii", "ignore")
        syllable_count = bin(mask).count("1")
        key_records.append(struct.pack("<IIIIHBB", intern(raw_key), first, min(max_freq, 0xFFFFFFFF), mask,
                                       min(count, 0xFFFF), min(len(raw_key), 255), min(syllable_count, 255)))
        meta.append((key, mask, max_freq))

    letters_only = re.compile(r"^[a-z]+$")
    t9_perm = [i for i, (key, _m, _f) in enumerate(meta) if letters_only.match(key)]
    t9_perm.sort(key=lambda i: (to_t9(meta[i][0]), -meta[i][2]))
    init_perm = [i for i, (key, mask, _f) in enumerate(meta) if mask and letters_only.match(key) and len(key) <= 32]
    init_perm.sort(key=lambda i: (initials_of(meta[i][0], meta[i][1]), -meta[i][2]))
    t9_init_perm = [i for i in init_perm if bin(meta[i][1]).count("1") >= 2]
    t9_init_perm.sort(key=lambda i: (to_t9(initials_of(meta[i][0], meta[i][1])), -meta[i][2]))

    def align(buffer: bytearray) -> None:
        while len(buffer) % 4:
            buffer.append(0)

    body = bytearray(64)
    off_keys = len(body)
    body.extend(b"".join(key_records))
    align(body)
    off_entries = len(body)
    body.extend(b"".join(entry_records))
    align(body)
    off_t9 = len(body)
    body.extend(struct.pack(f"<{len(t9_perm)}I", *t9_perm))
    off_init = len(body)
    body.extend(struct.pack(f"<{len(init_perm)}I", *init_perm))
    off_t9_init = len(body)
    body.extend(struct.pack(f"<{len(t9_init_perm)}I", *t9_init_perm))
    off_blob = len(body)
    body.extend(blob)

    header = struct.pack("<4s12I", b"MYD3", 1, len(entry_records), len(key_records), off_keys, off_entries,
                         off_t9, off_init, off_t9_init, off_blob, len(t9_perm), len(init_perm), len(t9_init_perm))
    body[: len(header)] = header
    path.write_bytes(bytes(body))
    return {"entries": len(entry_records), "keys": len(key_records), "bytes": len(body)}


# ---------------------------------------------------------------------------
# 整句转换评测：算法和 Swift 内核（PinyinEngine.swift）保持一致
# ---------------------------------------------------------------------------
TILE_PENALTY = 14.0
SYLLABLE_BONUS = 2.0
BIGRAM_BONUS = 3.0
UNLIKELY_SINGLE = {"n", "m", "ng", "hm", "hng"}
#: 整句最后一个字是这些音时，换成语气词。没有上下文模型时，这条规则最划算。
ENDING_PARTICLES = {"ma": "吗", "ba": "吧", "ne": "呢", "a": "啊", "ya": "呀", "la": "啦", "le": "了"}

SENTENCES = """
我喜欢你|你好吗|我不要|你在哪|我们走吧|今天天气很好|晚上吃饭吧|我要回家|再见了|你在干嘛|明天见|谢谢你|对不起|你好呀|我不知道
你在说什么|能不能|今天下班|明天几点出发|我这边都行|你吃饭了吗|我刚到家|等我一下|马上就到|我想你了|有时间吗|周末一起出去玩吧
这个多少钱|我已经发给你了|你看一下|没问题|好的我知道了|辛苦了|不好意思|麻烦你了|我晚点回你|现在在开会|下午三点开会
帮我看看这个文件|今天太累了|早点休息|晚安|早上好|你说得对|我觉得可以|这样不太好吧|为什么不行|什么时候有空|我们什么时候见面
你到了告诉我|路上小心|记得带伞|外面下雨了|我在路上了|堵车了|快到了|你先吃吧|不用等我|今天加班|工资发了吗|这个月好穷
我也是这么想的|真的假的|太好笑了|笑死我了|你别生气|别担心|没关系|慢慢来|加油|我相信你|生日快乐|新年快乐|恭喜发财
你今天怎么样|最近忙不忙|好久不见|有空一起吃饭|我请你喝咖啡|这家店很好吃|电影几点开始|票买好了吗|我把地址发你|手机没电了
""".replace("\n", "|").strip("|").split("|")

#: 没有参与调词频的句子。只看这一组才知道真实水平，改词频时不要照着它改。
HOLDOUT = """
你吃饭了吗|我们明天再见|今天很忙|这个东西很好用|下午有一个会议|我想吃火锅|你在哪里了|我在等你的电话|这个问题不难解决
他说他明天不来|请帮我看一下|我知道了|谢谢你的帮助|周六有空吗|我们一起开会吧|这是我的第一次|你喜欢什么颜色|天气真好
我今天不舒服|没关系我来处理|你好请问有人吗|这样也可以|大家辛苦了|我们去看电影吧|孩子放学了吗|我妈让我回家吃饭|老板今天心情不好
这件衣服多少钱|你把门关上|我忘记带钥匙了|明天要交作业|我们下次再聊|他已经走了|你觉得怎么样|我马上给你打电话|这家公司不错
火车几点到|我刚吃完饭|你别担心我|周末想去哪里玩|这个价格太贵了|我要去上班了|你能帮我一个忙吗|今晚早点睡|书放在桌子上
""".replace("\n", "|").strip("|").split("|")


class Eval:
    def __init__(self, builder: Builder) -> None:
        self.by_key: dict[str, list[tuple[str, int, int, int]]] = defaultdict(list)
        self.init: dict[str, list[tuple[int, str, str]]] = defaultdict(list)
        self.pairs = load_next_words()
        for (key, mask), words in builder.table.items():
            syllables = bin(mask).count("1") or 1
            for text, (freq, flags) in words.items():
                if flags & (FLAG_EMOJI | FLAG_PUNCT | FLAG_ASCII):
                    continue
                self.by_key[key].append((text, freq, syllables, flags))
            if mask:
                top = max(words.items(), key=lambda kv: kv[1][0])
                self.init[initials_of(key, mask)].append((top[1][0], top[0], key))
        for key in self.by_key:
            self.by_key[key].sort(key=lambda row: -row[1])

    def convert(self, query: str) -> str:
        n = len(query)
        best = [-math.inf] * (n + 1)
        back: list[tuple[int, str, str] | None] = [None] * (n + 1)
        best[0] = 0.0
        for i in range(n):
            if best[i] == -math.inf:
                continue
            for j in range(i + 1, min(n, i + 24) + 1):
                sub = query[i:j]
                rows = self.by_key.get(sub)
                if not rows:
                    continue
                first = (segment(sub) or [sub])[0]
                extra = -20.0 if first in UNLIKELY_SINGLE else 0.0
                previous = back[i][1] if back[i] else None
                for text, freq, syllables, _ in rows[:8]:
                    pair = BIGRAM_BONUS if previous and text in self.pairs.get(previous, ()) else 0.0
                    value = best[i] + math.log(freq + 1) - TILE_PENALTY + SYLLABLE_BONUS * (syllables - 1) + extra + pair
                    if value > best[j]:
                        best[j] = value
                        back[j] = (i, text, sub)
        if back[n] is None:
            return ""
        pieces = []
        cursor = n
        last_key = back[n][2]
        while cursor > 0:
            prev, text, _key = back[cursor]
            pieces.append(text)
            cursor = prev
        if len(pieces) >= 2 and last_key in ENDING_PARTICLES:
            pieces[0] = ENDING_PARTICLES[last_key]
        return "".join(reversed(pieces))


def evaluate(builder: Builder) -> None:
    from pypinyin import lazy_pinyin

    engine = Eval(builder)
    for title, sentences in (("调词频用过的句子", SENTENCES), ("没用过的句子", HOLDOUT)):
        exact = 0
        total_chars = 0
        right_chars = 0
        misses = []
        for sentence in sentences:
            query = "".join(lazy_pinyin(sentence))
            got = engine.convert(query)
            total_chars += len(sentence)
            right_chars += sum(1 for a, b in zip(sentence, got) if a == b)
            if got == sentence:
                exact += 1
            else:
                misses.append(f"{sentence} -> {got}")
        print(f"{title}：整句完全正确 {exact}/{len(sentences)}，逐字正确率 {right_chars / max(total_chars, 1):.1%}")
        for miss in misses:
            print("  ", miss)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--eval", action="store_true", help="生成后跑整句转换评测")
    args = parser.parse_args()

    builder = collect()
    info = write_binary(builder, OUT_DIR / "moyu.dict")
    print(dict(builder.stats))
    print(info)
    print("下一词表行数", write_next_words(builder, OUT_DIR / "next.tsv"))

    (OUT_DIR / "dict_meta.json").write_text(json.dumps({
        "version": DICT_VERSION,
        "generated_at": GENERATED_DATE,
        "entries": info["entries"],
        "keys": info["keys"],
        "bytes": info["bytes"],
        "sources": [
            {"name": "jieba dict.txt", "license": "MIT", "url": "https://github.com/fxsjy/jieba"},
            {"name": "pypinyin", "license": "MIT", "url": "https://github.com/mozillazg/python-pinyin"},
        ],
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.eval:
        evaluate(builder)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
