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
#: 新词和日常词（手工整理），构建时并进词库，也原样发一份给键盘每天拉取。
HOT_WORDS = HERE / "hot_words.tsv"
#: Tatoeba 的中文句子（CC BY 2.0 FR），用来数「这个词后面常跟什么」。
TATOEBA = HERE / ".cache" / "tatoeba" / "cmn_sentences.tsv.bz2"
#: 两个词在 Tatoeba 里连着出现这么多次以上，整句转换时也当常见搭配加分。
TATOEBA_STRONG = 10
#: 语气词不当整句转换的常见搭配：「是我吗」很常见，可它会让 woma 变成「我吗」而不是「我妈」。句末另有规则。
SENTENCE_PARTICLES = {"吗", "呢", "吧", "啊", "呀", "啦", "嘛", "哦", "哈", "了", "的"}
#: Tatoeba 例句里常用的外国人名，不拿来做联想。
TATOEBA_NAMES = {"汤姆", "玛丽", "约翰", "爱丽丝", "鲍勃", "杰克", "迈克", "露西", "比尔", "托尼", "吉姆", "保罗",
                 "凯特", "贝蒂", "南希", "肯", "简", "莉莉", "亚当", "布朗", "史密斯", "杰克逊", "汤米", "汤姆的", "玛莉", "麦克"}
#: 英文联想的词表：wordfreq 的英文词频（数据 CC BY-SA 4.0），取最常用的这么多个。
ENGLISH_WORDS = 40000
#: 这两份不进仓库，放在 .cache 里，下载地址见 docs/16-交接文档.md。
ESSAY = HERE / ".cache" / "rime-essay" / "essay.txt"
OPENCC = HERE / ".cache" / "opencc"
#: essay 权重低于这个的基本是噪声（灌上、折箭），当它没有。
ESSAY_MIN_WEIGHT = 500
#: jieba 没有的词，essay 权重到这个数才收。
ESSAY_NEW_WORD_MIN = 500
#: 两边都有的词，词频里 essay 占多少（按对数算），其余是 jieba。
ESSAY_BLEND = 1.0
#: rime-ice（雾凇拼音）基础词库，GPL-3.0，下载地址见 docs/16-交接文档.md。没有这个文件就跳过。
RIME_ICE = HERE / ".cache" / "rime-ice" / "base.dict.yaml"
#: rime-ice 的 8105 字表：每个字每个读音的字频（GPL-3.0），用来给多音字的其它读音定词频。
RIME_CHARS = HERE / ".cache" / "rime-ice" / "8105.dict.yaml"
#: 其它读音占这个字总字频的比例低于这个数就不收（绿 lu、不 fou 这类古音）。
ALT_READING_MIN_SHARE = 0.01
#: 词库里没有的词，rime-ice 权重到这个数才收。
RIME_NEW_MIN = 1000
#: 两边都有的词，词频里 rime-ice 占多少（按对数算）。
RIME_BLEND = 0.0
#: 三个字以上的短语（我吃过了、你在干什么）权重普遍低，但简拼最需要它们，门槛单独放低。
RIME_PHRASE_MIN = 1000
ESSAY_RAISE_V1 = True
#: 词频低于这个的词不拿来推「后半截」联想。
COMPOUND_MIN_FREQ = 200
#: 推「下一个词」时用的 rime-ice 短语：权重下限、每个词留几个、至少几条短语支持。
FOLLOW_PHRASE_MIN = 300
FOLLOW_KEEP = 8
FOLLOW_MIN_PHRASES = 3
#: 推出来的下一个词本身要够常用（去掉 债、债券 这类书面词）。
FOLLOW_WORD_MIN = 3000

DICT_VERSION = "3.0.7"
GENERATED_DATE = "2026-11-09"

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
#: 没有字表数据时猜的读音，上限压低：多半是古音。
ALT_READING_UNKNOWN_CAP = 200

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


def split_by_mask(key: str, mask: int) -> list[str]:
    """按音节起点掩码把键切回音节。"""
    starts = [i for i in range(min(len(key), 32)) if mask >> i & 1] or [0]
    return [key[a:b] for a, b in zip(starts, starts[1:] + [len(key)])]


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


def opencc_simplifier():
    """繁体转简体：先按短语表，再按单字表。"""
    def read(name: str) -> dict[str, str]:
        table = {}
        for line in (OPENCC / name).read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#") and "\t" in line:
                head, rest = line.split("\t", 1)
                table[head] = rest.split()[0]
        return table

    chars = read("TSCharacters.txt")
    phrases = read("TSPhrases.txt")

    def simplify(text: str) -> str:
        out = []
        i = 0
        while i < len(text):
            for size in (4, 3, 2):
                piece = text[i:i + size]
                if len(piece) == size and piece in phrases:
                    out.append(phrases[piece])
                    i += size
                    break
            else:
                out.append(chars.get(text[i], text[i]))
                i += 1
        return "".join(out)

    return simplify


def word_frequencies(builder: "Builder") -> dict[str, int]:
    freq: dict[str, int] = {}
    for (_key, _mask), words in builder.table.items():
        for text, (f, flags) in words.items():
            if flags & (FLAG_EMOJI | FLAG_PUNCT | FLAG_ASCII) or not CJK.match(text):
                continue
            freq[text] = max(freq.get(text, 0), f)
    return freq


def tatoeba_pairs(builder: "Builder") -> dict[str, Counter]:
    """Tatoeba 的句子按词库切成词，数前后两个词连着出现的次数。结果存在 builder 上，只算一次。"""
    cached = getattr(builder, "tatoeba", None)
    if cached is not None:
        return cached
    if not TATOEBA.exists():
        builder.tatoeba = {}
        return builder.tatoeba
    import bz2

    simplify = opencc_simplifier()
    freq = word_frequencies(builder)

    def split(text: str) -> list[str] | None:
        n = len(text)
        best: list[tuple[float, list[str]] | None] = [None] * (n + 1)
        best[0] = (0.0, [])
        for i in range(n):
            if best[i] is None:
                continue
            for j in range(i + 1, min(n, i + 6) + 1):
                word = text[i:j]
                f = freq.get(word)
                if f is None:
                    continue
                score = best[i][0] + math.log(f + 1) - 12
                if best[j] is None or score > best[j][0]:
                    best[j] = (score, best[i][1] + [word])
        return best[n][1] if best[n] else None

    pairs: dict[str, Counter] = defaultdict(Counter)
    for line in bz2.open(TATOEBA, "rt", encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3:
            continue
        # 著 在口语例句里几乎都是「着」（忙著、看著），OpenCC 的单字表默认给「著」
        for clause in re.findall(r"[一-鿿]+", simplify(parts[2]).replace("著", "着")):
            words = split(clause)
            if not words:
                continue
            for left, right in zip(words, words[1:]):
                if left in TATOEBA_NAMES or right in TATOEBA_NAMES:
                    continue
                pairs[left][right] += 1
            builder.stats["tatoeba_clauses"] += 1
    builder.tatoeba = dict(pairs)
    return builder.tatoeba


def phrase_followers(builder: "Builder") -> dict[str, list[str]]:
    """把 rime-ice 的多字短语（我吃过了）按词库切成词（我|吃过|了），数前后两个词连在一起的情况。

    rime-ice 是词库不是聊天语料，推出来的会带点书面味（公司 -> 地址），所以联想里排在手工表后面。
    """
    rime = load_rime_ice()
    if not rime:
        return {}
    freq: dict[str, int] = {}
    for (_key, _mask), words in builder.table.items():
        for text, (f, flags) in words.items():
            if flags & (FLAG_EMOJI | FLAG_PUNCT | FLAG_ASCII) or not CJK.match(text):
                continue
            freq[text] = max(freq.get(text, 0), f)

    def split(text: str) -> list[str] | None:
        n = len(text)
        best = [-math.inf] * (n + 1)
        back = [0] * (n + 1)
        best[0] = 0.0
        for i in range(n):
            if best[i] == -math.inf:
                continue
            for j in range(i + 1, min(n, i + 4) + 1):
                word = text[i:j]
                if word == text or word not in freq:
                    continue
                value = best[i] + math.log(freq[word] + 1) - 10
                if value > best[j]:
                    best[j] = value
                    back[j] = i
        if best[n] == -math.inf:
            return None
        parts = []
        cursor = n
        while cursor > 0:
            parts.append(text[back[cursor]:cursor])
            cursor = back[cursor]
        return parts[::-1]

    weight: dict[str, Counter[str]] = defaultdict(Counter)
    support: dict[str, Counter[str]] = defaultdict(Counter)
    for text, (_syllables, w) in rime.items():
        if len(text) < 3 or w < FOLLOW_PHRASE_MIN:
            continue
        parts = split(text)
        if not parts or len(parts) < 2:
            continue
        for left, right in zip(parts, parts[1:]):
            weight[left][right] += w
            support[left][right] += 1
    result = {}
    for head, counter in weight.items():
        if freq.get(head, 0) < COMPOUND_MIN_FREQ:
            continue
        words = [w for w, _ in counter.most_common()
                 if support[head][w] >= FOLLOW_MIN_PHRASES and freq.get(w, 0) >= FOLLOW_WORD_MIN][:FOLLOW_KEEP]
        if words:
            result[head] = words
    return result


def write_next_words(builder: Builder, path: Path) -> int:
    """手工表 + 从词库推出来的后半截（今 -> 天、年、晚）+ 从短语库推的下一个词，写成 next.tsv。"""
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
    followers = phrase_followers(builder)
    corpus = tatoeba_pairs(builder)
    lines = []
    heads = set(authored) | {h for h in weights if len(h) == 1 or h in known} | set(followers) | set(corpus)
    for head in sorted(heads):
        words = authored.get(head, [])
        rest = [w for w, _ in weights[head].most_common(14) if w not in words][:10] if head in weights else []
        counter = corpus.get(head, Counter())
        # 第四列：真实句子里的下一个词（Tatoeba）优先，不够再用短语库推的
        follow = [w for w, c in counter.most_common(12) if c >= 2 and w not in words][:FOLLOW_KEEP]
        follow += [w for w in followers.get(head, []) if w not in words and w not in follow][:max(0, FOLLOW_KEEP - len(follow))]
        # 第五列：连着出现很多次的，整句转换时也加分
        strong = [w for w, c in counter.most_common(30) if c >= TATOEBA_STRONG and w not in SENTENCE_PARTICLES]
        if words or rest or follow or strong:
            lines.append(f"{head}\t{' '.join(words)}\t{' '.join(rest)}\t{' '.join(follow)}\t{' '.join(strong)}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(lines)


def load_essay(known: set[str]) -> dict[str, int]:
    """读 essay.txt，转成简体、合并异体后返回 {词: 原始权重}。

    essay 是繁体的。一个繁体字可能对应几个简体（乾 -> 干、乾），
    这时优先选 known（jieba 词表）里有的那个组合。
    """
    from itertools import islice, product

    def read_table(name: str) -> dict[str, list[str]]:
        table = {}
        for line in (OPENCC / name).read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#") and "\t" in line:
                head, rest = line.split("\t", 1)
                table[head] = rest.split()
        return table

    chars = read_table("TSCharacters.txt")
    phrases = read_table("TSPhrases.txt")

    def simplify(word: str) -> str:
        if word in phrases:
            return phrases[word][0]
        options = [chars.get(ch, [ch]) for ch in word]
        first = "".join(row[0] for row in options)
        if first in known or all(len(row) == 1 for row in options):
            return first
        for combo in islice(product(*options), 64):
            text = "".join(combo)
            if text in known:
                return text
        return first

    merged: Counter[str] = Counter()
    for line in ESSAY.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].isdigit() and CJK.match(parts[0]) and len(parts[0]) <= MAX_WORD_LEN:
            merged[simplify(parts[0])] += int(parts[1])
    return dict(merged)


def load_hot_words() -> list[tuple[str, list[str], int]]:
    """读 hot_words.tsv：(词, 音节, 词频)。"""
    from pypinyin import lazy_pinyin

    rows = []
    if not HOT_WORDS.exists():
        return rows
    for line in HOT_WORDS.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2 or not CJK.match(parts[0]) or not parts[1].isdigit():
            continue
        syllables = parts[2].split() if len(parts) >= 3 and parts[2].strip() else [x.lower() for x in lazy_pinyin(parts[0])]
        if len(syllables) != len(parts[0]) or not all(x in SYL_SET for x in syllables):
            print("新词注音不对，跳过：", parts[0], syllables)
            continue
        rows.append((parts[0], syllables, int(parts[1])))
    return rows


def write_hot_words(path: Path) -> int:
    """给键盘的新词表：词<TAB>音节（' 隔开）<TAB>词频。键盘每天从仓库拉一次这个文件。"""
    rows = load_hot_words()
    lines = [f"{word}\t{chr(39).join(syllables)}\t{freq}" for word, syllables, freq in rows]
    path.write_text("# 墨语新词表 v1\n" + "\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return len(rows)


def write_english_words(path: Path) -> int:
    """英文联想词表：词<TAB>每十亿词出现次数。数据来自 wordfreq（CC BY-SA 4.0），没装 wordfreq 就不动旧文件。"""
    try:
        import wordfreq
    except ImportError:
        print("没装 wordfreq，英文词表沿用旧的")
        return -1
    rows = []
    for word in wordfreq.top_n_list("en", ENGLISH_WORDS * 2):
        if not re.fullmatch(r"[a-z]+(?:'[a-z]+)?", word) or (len(word) == 1 and word not in ("a", "i")):
            continue
        count = max(1, int(wordfreq.word_frequency(word, "en") * 1e9))
        # 带撇号的只留常用缩写（don't、i'm），两个字母的只留常见的，去掉 a's、aa 这类
        if ("'" in word and count < 200_000) or (len(word) == 2 and count < 100_000):
            continue
        rows.append((word, count))
        if len(rows) >= ENGLISH_WORDS:
            break
    rows.sort()
    path.write_text("\n".join(f"{w}\t{c}" for w, c in rows) + "\n", encoding="utf-8", newline="\n")
    return len(rows)


def load_rime_ice() -> dict[str, tuple[list[str], int]]:
    """读 rime-ice 的 base.dict.yaml：词 -> (拼音, 权重)。同一个词有几个读音时留权重高的。"""
    if not RIME_ICE.exists():
        return {}
    result: dict[str, tuple[list[str], int]] = {}
    started = False
    for line in RIME_ICE.read_text(encoding="utf-8").splitlines():
        if not started:
            started = line.strip() == "..."
            continue
        parts = line.split("\t")
        if len(parts) != 3 or not parts[2].isdigit() or not CJK.match(parts[0]) or len(parts[0]) > MAX_WORD_LEN:
            continue
        syllables = parts[1].split()
        if len(syllables) != len(parts[0]) or not all(s in SYL_SET for s in syllables):
            continue
        weight = int(parts[2])
        if parts[0] not in result or result[parts[0]][1] < weight:
            result[parts[0]] = (syllables, weight)
    return result


def load_rime_chars() -> dict[str, dict[str, int]]:
    """读 rime-ice 的 8105 字表：字 -> {读音: 字频}。"""
    if not RIME_CHARS.exists():
        return {}
    result: dict[str, dict[str, int]] = defaultdict(dict)
    started = False
    for line in RIME_CHARS.read_text(encoding="utf-8").splitlines():
        if not started:
            started = line.strip() == "..."
            continue
        parts = line.split("\t")
        if len(parts) < 3 or len(parts[0]) != 1 or not parts[2].isdigit() or parts[1] not in SYL_SET:
            continue
        result[parts[0]][parts[1]] = max(result[parts[0]].get(parts[1], 0), int(parts[2]))
    return dict(result)


def essay_scale(essay: dict[str, int], jieba: dict[str, int]) -> float:
    """essay 和 jieba 的刻度不一样：取常用词上两者比值的中位数，换算成 jieba 的刻度。"""
    ratios = sorted(math.log(jieba[word] / weight) for word, weight in essay.items()
                    if weight >= 1000 and jieba.get(word, 0) >= 100)
    return math.exp(ratios[len(ratios) // 2])


def collect() -> Builder:
    from pypinyin import Style, lazy_pinyin, pinyin

    builder = Builder()
    chat_weights = load_chat_weights()

    def chat_bits(word: str) -> int:
        weight = chat_weights.get(word, 0.0)
        return (min(15, int(round(weight * 5))) << 4) if weight else 0

    # ① 旧词库：聊天词、网络词、表情、标点，词频人工调过，优先保留
    v1_texts: dict[str, int] = {}
    v1_chat: set[str] = set()
    for line in BASE_V1.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        key, word, freq = parts[0], parts[1], int(parts[2])
        tags = set((parts[3] if len(parts) > 3 else "").split(","))
        flags = chat_bits(word)
        # 旧词库把「累」「开心」「想吃」这些字也标成了 emoji，它们要参与整句转换
        if "emoji" in tags and not CJK.match(word):
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
        if "chat" in tags:
            v1_chat.add(word)
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

    # essay 的词频来自网络文本，比 jieba 更接近聊天；两边都有的词用它重新算词频
    jieba_freq = {word: freq for word, freq, _pos in rows}
    essay = load_essay(set(jieba_freq))
    scale = essay_scale(essay, jieba_freq)
    essay = {word: weight for word, weight in essay.items() if weight >= ESSAY_MIN_WEIGHT}
    builder.stats["essay_scale_x1000"] = int(scale * 1000)

    def blended(word: str, freq: int) -> int:
        weight = essay.get(word)
        if not weight:
            return freq
        return max(1, int(math.exp(ESSAY_BLEND * math.log(weight * scale + 1) + (1 - ESSAY_BLEND) * math.log(freq + 1))))

    for word, freq, pos in rows:
        if not CJK.match(word) or len(word) > MAX_WORD_LEN or word in v1_texts:
            continue
        if word in essay and ESSAY_BLEND > 0:
            freq = blended(word, freq)
            builder.stats["essay_reweight"] += 1
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

    # ②′ essay 里有、jieba 没有的词（微信、朋友圈这类新词）
    for word, weight in essay.items():
        if word in jieba_freq or word in v1_texts or weight < ESSAY_NEW_WORD_MIN or len(word) < 2:
            continue
        if not all(ch in keep_chars for ch in word):
            continue
        syllables = [s.lower() for s in lazy_pinyin(word)]
        if not all(s in SYL_SET for s in syllables):
            continue
        builder.add("".join(syllables), syllables, word, max(MIN_FREQ, int(weight * scale)), chat_bits(word))
        builder.stats["essay_new"] += 1

    # ②″ 旧词库的词频也来自新闻语料（万 > 玩）。聊天词只抬不压，其余直接换。
    # 单字只换默认读音：「还」的词频不能算到 huan 头上。
    if ESSAY_RAISE_V1:
        for (key, _mask), words in builder.table.items():
            for word, row in words.items():
                if word not in v1_texts or word not in essay or row[1] & (FLAG_EMOJI | FLAG_PUNCT):
                    continue
                if len(word) == 1 and lazy_pinyin(word)[0].lower() != key:
                    continue
                # 语气词的词频都来自句尾，算进来句子中间就全是它（我把 -> 我吧）。句尾有专门的规则。
                if word in ENDING_PARTICLES.values():
                    continue
                scaled = int(essay[word] * scale)
                row[0] = max(row[0], scaled) if word in v1_chat else scaled
                builder.stats["essay_v1"] += 1

    # ②⁗ rime-ice：带拼音和词频，聊天常用的组合多（吃过、我吃、过了、我吃过了）
    rime = load_rime_ice()
    if rime:
        current: dict[str, int] = {}
        for words in builder.table.values():
            for text, (freq, _flags) in words.items():
                current[text] = max(current.get(text, 0), freq)
        ratios = sorted(math.log(current[text] / weight) for text, (_syl, weight) in rime.items()
                        if weight >= 1000 and current.get(text, 0) >= 100)
        rime_scale = math.exp(ratios[len(ratios) // 2]) if ratios else 1.0
        builder.stats["rime_scale_x1000"] = int(rime_scale * 1000)
        known_chars = {ch for text in current for ch in text}
        if RIME_BLEND > 0:
            for (key, mask), words in builder.table.items():
                for text, row in words.items():
                    entry = rime.get(text)
                    if entry is None or "".join(entry[0]) != key or text in v1_chat or row[1] & (FLAG_EMOJI | FLAG_PUNCT):
                        continue
                    scaled = entry[1] * rime_scale + 1
                    row[0] = max(1, int(math.exp(RIME_BLEND * math.log(scaled) + (1 - RIME_BLEND) * math.log(row[0] + 1))))
                    builder.stats["rime_reweight"] += 1
        for text, (syllables, weight) in rime.items():
            threshold = RIME_PHRASE_MIN if len(text) >= 3 else RIME_NEW_MIN
            if weight < threshold or text in current or len(text) < 2:
                continue
            if not all(ch in known_chars for ch in text):
                continue
            builder.add("".join(syllables), syllables, text, max(MIN_FREQ, int(weight * rime_scale)), chat_bits(text))
            builder.stats["rime_new"] += 1

    # ③ 单字的其它读音
    # 以前用 pypinyin 的全部读音，再按默认读音词频打折，最高 3000：不 fu、被 pi、还 fu 这些古音
    # 都到了 3000，比「皮」「付」还高，整句里到处是它们（pinan -> 副男）。
    # 现在有 8105 字表时按每个读音的真实字频分；字表里没有的读音不收。
    rime_chars = load_rime_chars()
    for char, freq in single_freq.items():
        if char not in keep_chars:
            continue
        default = lazy_pinyin(char)[0].lower()
        table = rime_chars.get(char)
        if table:
            total = sum(table.values()) or 1
            for reading, weight in table.items():
                share = weight / total
                if reading == default or share < ALT_READING_MIN_SHARE:
                    continue
                builder.add(reading, [reading], char, min(ALT_READING_CAP, max(8, int(freq * share))), 0)
                builder.stats["alt_reading"] += 1
            continue
        readings = pinyin(char, style=Style.NORMAL, heteronym=True)[0]
        for reading in readings[1:6]:
            reading = reading.lower()
            if reading in SYL_SET:
                builder.add(reading, [reading], char, min(ALT_READING_UNKNOWN_CAP, max(8, int(freq * ALT_READING_DISCOUNT))), 0)
                builder.stats["alt_reading_guess"] += 1

    # ③′ 字表里有、但词库里这个读音不在的单字（率 lv、还 huan 的旧数据可能缺）不另补：旧词库已覆盖常用读音。

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

    # ④′ 新词和日常词：没有的加上，有的只抬不压
    for word, syllables, freq in load_hot_words():
        key = "".join(syllables)
        slot = builder.table[(key, mask_of(syllables))]
        old = slot.get(word, [0, 0])
        slot[word] = [max(old[0], freq), old[1] | FLAG_CHAT | chat_bits(word)]
        builder.stats["hot_words"] += 1

    # ⑤ 略、虐也能打 lue、nue（很多人这么打）。字母数一样，切分位置不变。
    for (key, mask), words in list(builder.table.items()):
        syllables = split_by_mask(key, mask)
        if not any(s in ("lve", "nve") for s in syllables):
            continue
        alias = "".join("lue" if s == "lve" else "nue" if s == "nve" else s for s in syllables)
        slot = builder.table[(alias, mask)]
        for word, (freq, flags) in words.items():
            if word not in slot:
                slot[word] = [freq, flags]
                builder.stats["ue_alias"] += 1
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
SINGLE_INITIAL_PENALTY = 10.0
INITIALS_PENALTY = 3.0
#: 简拼每一段试几个候选词（Swift 里同名常量要一起改）。
INITIAL_TOP_K = 3
#: 前一个词的最后一个字和这个词的第一个字连起来是个词（吃 + 过了 -> 吃过），加分。
JUNCTION_BONUS = 2.0
#: 简拼每多一个字母加的分：一下对上四个字母的词比拆成两段可信得多。
INITIALS_LENGTH_BONUS = 3.0
SYLLABLE_BONUS = 2.0
BIGRAM_BONUS = 3.0
UNLIKELY_SINGLE = {"n", "m", "ng", "hm", "hng"}
#: 整串都能切成完整拼音时，中间再把几个字母当简拼要多扣分：bang 是「帮」，不是 ba + ng（那个）。
FULL_PINYIN_INITIALS_PENALTY = 6.0
#: 简拼里有 a、e、o（零声母字的首字母）时每个扣的分：hap 多半是打错的 hao，不是「海岸炮」。
INITIALS_VOWEL_PENALTY = 4.0
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


#: 换词频数据时写的另一组。看过一次结果，之后不要照着它调。
UNSEEN = """
我先去洗澡了|你今天吃药了吗|这周末我要搬家|我家的猫生病了|你帮我问问他|会议改到明天了|我下班去接你|今天的菜有点咸|这条裙子好看吗|我手机快没电了
你什么时候回来|我在超市买东西|记得给妈妈打电话|我们去楼下吃吧|这个软件怎么下载|你的快递到了|我昨天没睡好|晚上一起看电影吗|天气太热了|我把钱转给你
你别忘了带身份证|我们约个时间吧|我现在不方便说话|他还没有回复我|这道题我不会做|你能不能快一点|我肚子有点疼|今天公司放假|这个周末加班吗|我请你吃饭
你最近在忙什么|我已经订好酒店了|飞机晚点了|我们打车过去吧|你吃早饭了吗|这个视频太搞笑了|给我发个定位|我在门口等你|钱包忘在家里了|明天记得叫我起床
她今天请假了|这个密码不对|我要换个新手机|你的声音好好听|你能发个照片吗|快过年了|我们分开走吧|电脑又坏了|房租该交了|我马上下楼
""".replace("\n", "|").strip("|").split("|")


class Eval:
    def __init__(self, builder: Builder) -> None:
        self.by_key: dict[str, list[tuple[str, int, int, int]]] = defaultdict(list)
        self.init: dict[str, list[tuple[int, str, str]]] = defaultdict(list)
        self.pairs = {k: list(v) for k, v in load_next_words().items()}
        for left, counter in tatoeba_pairs(builder).items():
            for right, count in counter.items():
                if count >= TATOEBA_STRONG and right not in SENTENCE_PARTICLES and right not in self.pairs.setdefault(left, []):
                    self.pairs[left].append(right)
        self.two_char: set[str] = set()
        for (key, mask), words in builder.table.items():
            syllables = bin(mask).count("1") or 1
            for text, (freq, flags) in words.items():
                if flags & (FLAG_EMOJI | FLAG_PUNCT | FLAG_ASCII):
                    continue
                self.by_key[key].append((text, freq, syllables, flags))
                if len(text) == 2 and freq >= 200:
                    self.two_char.add(text)
            if mask:
                clean = [(f, t) for t, (f, fl) in words.items() if not fl & (FLAG_EMOJI | FLAG_PUNCT | FLAG_ASCII)]
                if clean:
                    top = max(clean)
                    self.init[initials_of(key, mask)].append((top[0], top[1], key))
        for key in self.by_key:
            self.by_key[key].sort(key=lambda row: -row[1])
        for initials in self.init:
            self.init[initials].sort(reverse=True)

    def convert(self, query: str) -> str:
        n = len(query)
        best = [-math.inf] * (n + 1)
        back: list[tuple[int, str, str] | None] = [None] * (n + 1)
        best[0] = 0.0
        parts = segment(query)
        full_pinyin = parts is not None and not any(p in UNLIKELY_SINGLE for p in parts)
        for i in range(n):
            if best[i] == -math.inf:
                continue
            for j in range(i + 1, min(n, i + 24) + 1):
                sub = query[i:j]
                rows = self.by_key.get(sub)
                previous = back[i][1] if back[i] else None
                if not rows:
                    # 简拼：这一段没有全拼能对上时才试
                    if len(sub) <= 6:
                        penalty = SINGLE_INITIAL_PENALTY if len(sub) == 1 else INITIALS_PENALTY
                        if full_pinyin:
                            penalty += FULL_PINYIN_INITIALS_PENALTY
                        if len(sub) >= 2:
                            penalty += INITIALS_VOWEL_PENALTY * sum(c in "aeo" for c in sub)
                        for freq, text, key in self.init.get(sub, [])[:INITIAL_TOP_K]:
                            junction = JUNCTION_BONUS if previous and previous[-1] + text[0] in self.two_char else 0.0
                            pair = BIGRAM_BONUS if previous and text in self.pairs.get(previous, ()) else 0.0
                            value = (best[i] + math.log(freq + 1) - TILE_PENALTY - penalty + junction + pair
                                     + INITIALS_LENGTH_BONUS * (len(sub) - 1))
                            if value > best[j]:
                                best[j] = value
                                back[j] = (i, text, key)
                    continue
                first = (segment(sub) or [sub])[0]
                extra = -20.0 if first in UNLIKELY_SINGLE else 0.0
                one_syllable = sub in SYL_SET
                for text, freq, syllables, _ in rows[:8]:
                    pair = BIGRAM_BONUS if previous and text in self.pairs.get(previous, ()) else 0.0
                    bonus = 0.0 if one_syllable else SYLLABLE_BONUS * (syllables - 1)
                    value = best[i] + math.log(freq + 1) - TILE_PENALTY + bonus + extra + pair
                    if value > best[j]:
                        best[j] = value
                        back[j] = (i, text, sub)
        if back[n] is None:
            return ""
        pieces = []
        cursor = n
        last_key = back[n][2]
        self.trace = []
        while cursor > 0:
            prev, text, _key = back[cursor]
            pieces.append(text)
            self.trace.append((query[prev:cursor], text, _key))
            cursor = prev
        self.trace.reverse()
        if len(pieces) >= 2 and last_key in ENDING_PARTICLES:
            pieces[0] = ENDING_PARTICLES[last_key]
        return "".join(reversed(pieces))


def evaluate(builder: Builder) -> None:
    from pypinyin import lazy_pinyin

    engine = Eval(builder)
    for title, sentences in (("调词频用过的句子", SENTENCES), ("没用过的句子", HOLDOUT), ("后来写的句子", UNSEEN)):
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
    print("新词表", write_hot_words(OUT_DIR / "hot_words.tsv"))
    print("英文词表", write_english_words(OUT_DIR / "en_words.tsv"))

    (OUT_DIR / "dict_meta.json").write_text(json.dumps({
        "version": DICT_VERSION,
        "generated_at": GENERATED_DATE,
        "entries": info["entries"],
        "keys": info["keys"],
        "bytes": info["bytes"],
        "sources": [
            {"name": "jieba dict.txt", "license": "MIT", "url": "https://github.com/fxsjy/jieba"},
            {"name": "pypinyin", "license": "MIT", "url": "https://github.com/mozillazg/python-pinyin"},
            {"name": "rime-essay essay.txt", "license": "LGPL-3.0", "url": "https://github.com/rime/rime-essay"},
            {"name": "OpenCC TSCharacters / TSPhrases", "license": "Apache-2.0", "url": "https://github.com/BYVoid/OpenCC"},
            {"name": "rime-ice cn_dicts/base.dict.yaml + 8105.dict.yaml", "license": "GPL-3.0", "url": "https://github.com/iDvel/rime-ice"},
            {"name": "Tatoeba cmn_sentences", "license": "CC BY 2.0 FR", "url": "https://tatoeba.org"},
            {"name": "wordfreq (English word list)", "license": "CC BY-SA 4.0 (data)", "url": "https://github.com/rspeer/wordfreq"},
        ],
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if args.eval:
        evaluate(builder)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
