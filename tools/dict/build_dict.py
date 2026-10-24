# -*- coding: utf-8 -*-
"""墨语输入法 · 中文聊天词库生成器。

用法：
    python tools/dict/build_dict.py            # 生成到 ios/Shared/dict/
    python tools/dict/build_dict.py --check    # 只做质量自查，不写文件

产物（全部 UTF-8 无 BOM、LF 换行）：
    ios/Shared/dict/base_dict.tsv   拼音 <TAB> 词 <TAB> 词频 <TAB> flags
    ios/Shared/dict/phrases.tsv     建议词拼音 <TAB> 触发词 <TAB> 建议词
    ios/Shared/dict/dict_meta.json  版本/条数/日期/来源/SHA256

注意：输出目录**必须**是 `ios/Shared/dict/`，绝不能是 `ios/Shared/Resources/dict/`。
folder reference 会把目录名原样复制到 App bundle 根，若出现 `Resources/` 目录，
iOS 27 的 installd 会拒绝安装（IXErrorDomain Code=13 Missing bundle ID）。

数据来源：
    1) jieba 自带词频表 dict.txt（cppjieba dict，MIT License），已缓存到 .cache/jieba_dict.txt；
    2) tools/dict/chat_supplement.py 手写高频聊天补充表（本项目原创）；
    3) tools/dict/symbol_map.py emoji/标点联想映射（本项目原创）；
    4) tools/dict/phrase_pairs.py 上屏后联想短语对（本项目原创）。

幂等性：无随机、无 now()、排序键 (freq desc, pinyin, text)，重复执行字节级一致。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict

# 允许 `python tools/dict/build_dict.py` 直接运行（脚本目录加入 sys.path）
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import chat_supplement  # noqa: E402
import phrase_pairs  # noqa: E402
import symbol_map  # noqa: E402
from syllable_table import SYLLABLES, is_splittable  # noqa: E402

CACHE_PATH = os.path.join(HERE, ".cache", "jieba_dict.txt")
# 输出目录：必须是 Shared/dict（不能是 Shared/Resources/dict，见模块 docstring 的说明）
OUT_DIR = os.path.join(ROOT, "ios", "Shared", "dict")

DICT_VERSION = "1.0.0"
GENERATED_DATE = "2026-10-24"   # 固定日期，保证可重跑幂等（不取 now）

# ---- 选词参数（改这里就能调规模） ----
N_JIEBA = 3400          # 从 jieba 词表取前 N 条通用词
JIEBA_MIN_FREQ = 1200   # jieba 词频下限（低于此的通用词不收录，避免生僻词）
MIN_LEN, MAX_LEN = 1, 6  # 词长（汉字个数）
COMMON_CHAR_SUPPORT = 3  # 一个字至少出现在 N 个高频词里才算"常用字"

# flags 输出顺序（可读且稳定）
FLAG_ORDER = ["chat", "net", "bless", "emoji", "punct", "idiom", "core", "user"]

CJK_RE = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")
ALNUM_RE = re.compile(r"^[0-9A-Za-z]+$")
PY_RE = re.compile(r"^[a-z]+$")
HAS_CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")

# jieba 词性中属于"人名/音译/专名"的标记，长词低词频的多为无用专名，做过滤
NAME_POS = {"nr", "nrt", "nrx", "nrfg"}
NAME_KEEP_FREQ = 8000


def log(msg: str) -> None:
    print(msg, flush=True)


# --------------------------------------------------------------------------
# 1. 读取 jieba 词频表
# --------------------------------------------------------------------------
def load_jieba() -> list[tuple[str, int, str]]:
    """返回 [(word, freq, pos)]，按 freq 降序、word 升序排序。"""
    if not os.path.exists(CACHE_PATH):
        raise SystemExit(
            "找不到 jieba 词表缓存: %s\n"
            "请先执行: python -m pip install jieba 并复制 jieba/dict.txt 到该路径" % CACHE_PATH
        )
    rows: list[tuple[str, int, str]] = []
    with open(CACHE_PATH, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            rows.append((parts[0], int(parts[1]), parts[2] if len(parts) > 2 else ""))
    rows.sort(key=lambda r: (-r[1], r[0]))
    return rows


def common_chars(rows: list[tuple[str, int, str]]) -> set[str]:
    """从高频词中反推"常用字集合"，用于剔除生僻字词（如 笉/灱 这类）。"""
    support: Counter[str] = Counter()
    for word, freq, _pos in rows:
        if freq < 1000 or not CJK_RE.match(word):
            continue
        for ch in set(word):
            support[ch] += 1
    return {ch for ch, n in support.items() if n >= COMMON_CHAR_SUPPORT}


def select_jieba(rows: list[tuple[str, int, str]], keep_chars: set[str]) -> list[tuple[str, int, str]]:
    """按词频取前 N 条通用词，过滤生僻字/超长词/低质专名。"""
    picked: list[tuple[str, int, str]] = []
    for word, freq, pos in rows:
        if freq < JIEBA_MIN_FREQ:
            break                       # rows 已按 freq 降序，可直接收尾
        if not CJK_RE.match(word):
            continue
        if not (MIN_LEN <= len(word) <= MAX_LEN):
            continue
        if not all(ch in keep_chars for ch in word):
            continue
        if pos in NAME_POS and len(word) >= 3 and freq < NAME_KEEP_FREQ:
            continue
        if PY_RE.match(word) or ALNUM_RE.match(word):
            continue
        picked.append((word, freq, pos))
        if len(picked) >= N_JIEBA:
            break
    return picked


# --------------------------------------------------------------------------
# 2. 拼音派生 + 校验
# --------------------------------------------------------------------------
def build_pinyin_table() -> tuple[object, str]:
    """返回 (lazy_pinyin 函数, 落地说明字符串)。优先 pypinyin，缺失则用内置音节表降级。"""
    try:
        from pypinyin import lazy_pinyin  # type: ignore
        return lazy_pinyin, "pypinyin 0.55.0 (Style.NORMAL, 多音字取默认读音)"
    except ImportError:
        return _fallback_lazy_pinyin, "内置音节映射降级实现（pypinyin 未安装）"


def _fallback_lazy_pinyin(word: str) -> list[str]:
    """无 pypinyin 时的降级实现：用 syllable_table 的 DP 对整串做最大匹配切分。"""
    text = "".join(word.split()).lower()
    out: list[str] = []
    i = 0
    while i < len(text):
        for ln in range(6, 0, -1):
            seg = text[i : i + ln]
            if seg in _SYL_SET:
                out.append(seg)
                i += ln
                break
        else:
            out.append(text[i])
            i += 1
    return out


_SYL_SET = frozenset(SYLLABLES)


def word_to_pinyin(word: str, lazy_pinyin) -> str | None:
    """把词转成无声调连写全拼；不合法（含非拼音片段）返回 None。

    规则：
    - 纯汉字词：逐字取默认读音，必须全部命中音节表；
    - 纯 ASCII 字母/数字词（yyds/u1s1/2333）：直接小写作为索引串（英文直通用）；
    - 其它（含 emoji/标点/中英混排）：返回 None，由上层的 symbol_map 别名补齐。
    """
    if CJK_RE.match(word):
        try:
            syls = lazy_pinyin(word)
        except Exception:  # noqa: BLE001 - 第三方库异常一律降级为丢弃
            return None
        parts: list[str] = []
        for syl in syls:
            s = (syl or "").lower()
            if not PY_RE.match(s) or s not in _SYL_SET:
                return None
            parts.append(s)
        pinyin = "".join(parts)
    elif ALNUM_RE.match(word):
        pinyin = word.lower()
    else:
        return None
    if not pinyin or len(pinyin) > 32:
        return None
    return pinyin


# --------------------------------------------------------------------------
# 3. 合并三个来源
# --------------------------------------------------------------------------
Entry = dict  # {"text": str, "freq": int, "flags": set[str], "source": str}


def new_entry(text: str, freq: int, flags: str, source: str) -> Entry:
    return {
        "text": text,
        "freq": int(freq),
        "flags": {f for f in flags.split(",") if f},
        "source": source,
    }


def merge_entries(entries: list[Entry]) -> dict[str, Entry]:
    """按词文本去重：词频累加、flags 并集、source 记录首次来源。"""
    merged: dict[str, Entry] = {}
    for e in entries:
        cur = merged.get(e["text"])
        if cur is None:
            merged[e["text"]] = e
            continue
        cur["freq"] += e["freq"]
        cur["flags"] |= e["flags"]
        if e["source"] not in cur["source"]:
            cur["source"] = cur["source"] + "+" + e["source"]
        # 符号别名拼音优先保留：emoji 先被补充表收录时自身无法派生拼音，
        # 需要由 symbol_map 提供的 forced_pinyin 兜底，否则会被误丢弃。
        if "forced_pinyin" in e and "forced_pinyin" not in cur:
            cur["forced_pinyin"] = e["forced_pinyin"]
    return merged


def collect_entries(lazy_pinyin) -> tuple[list[dict], Counter]:
    """汇总所有来源并派生拼音，返回 (最终词条列表, 丢弃统计)。"""
    dropped: Counter[str] = Counter()
    raw: list[Entry] = []

    # 3.1 jieba 通用词
    rows = load_jieba()
    keep_chars = common_chars(rows)
    jieba_rows = select_jieba(rows, keep_chars)
    for word, freq, _pos in jieba_rows:
        raw.append(new_entry(word, freq, "core", "jieba"))

    # 3.2 手写聊天补充表（含 emoji/标点组的词）
    for word, freq, flags in chat_supplement.iter_words():
        if not (word and len(word) <= 12):
            dropped["补充表超长/空词"] += 1
            continue
        raw.append(new_entry(word, freq, flags, "chat_supplement"))

    # 3.3 emoji / 标点联想：拼音取"别名"的全拼
    alias_pinyin_cache: dict[str, str | None] = {}
    for alias, symbol, flags, freq in symbol_map.iter_symbols():
        if alias not in alias_pinyin_cache:
            alias_pinyin_cache[alias] = word_to_pinyin(alias, lazy_pinyin)
        alias_py = alias_pinyin_cache[alias]
        if not alias_py:
            dropped["符号别名无有效拼音"] += 1
            continue
        entry = new_entry(symbol, freq, flags, "symbol_map")
        entry["forced_pinyin"] = alias_py
        raw.append(entry)

    merged = merge_entries(raw)

    # 3.4 派生拼音 + 过滤
    final: list[dict] = []
    for text, e in merged.items():
        forced = e.get("forced_pinyin")
        pinyin = forced or word_to_pinyin(text, lazy_pinyin)
        if pinyin is None:
            dropped["无法派生合法拼音"] += 1
            continue
        if not is_splittable(pinyin) and not ALNUM_RE.match(pinyin):
            dropped["拼音不可切分"] += 1
            continue
        flags = ",".join(f for f in FLAG_ORDER if f in e["flags"])
        final.append({
            "pinyin": pinyin,
            "text": text,
            "freq": e["freq"],
            "flags": flags,
            "source": e["source"],
        })

    # 3.5 同拼音同词冲突（理论上同词已去重，这里防御异常数据）
    seen_key: dict[tuple[str, str], int] = {}
    deduped: list[dict] = []
    for row in final:
        key = (row["pinyin"], row["text"])
        if key in seen_key:
            dropped["同拼音同词重复"] += 1
            continue
        seen_key[key] = 1
        deduped.append(row)

    deduped.sort(key=lambda r: (-r["freq"], r["pinyin"], r["text"]))
    return deduped, dropped


# --------------------------------------------------------------------------
# 4. 短语联想表
# --------------------------------------------------------------------------
def build_phrases(lazy_pinyin) -> tuple[list[dict], Counter]:
    """生成 (拼音, 触发词, 建议词) 三元组列表。"""
    dropped: Counter[str] = Counter()
    seen: set[tuple[str, str]] = set()
    rows: list[dict] = []
    for trigger, suggestions in phrase_pairs.PAIR_GROUPS:
        trigger = trigger.strip()
        if not trigger or any(ch.isspace() for ch in trigger):
            dropped["触发词非法"] += 1
            continue
        for s in suggestions.split():
            s = s.strip()
            if not s:
                continue
            key = (trigger, s)
            if key in seen:
                dropped["触发-建议重复"] += 1
                continue
            seen.add(key)
            py = word_to_pinyin(s, lazy_pinyin)
            if py is None:
                # 建议词可含标点：剥掉非汉字后再试
                pure = "".join(HAS_CJK_RE.findall(s))
                py = word_to_pinyin(pure, lazy_pinyin) if pure else None
            if py is None:
                dropped["建议词无法派生拼音"] += 1
                continue
            rows.append({"pinyin": py, "trigger": trigger, "text": s})
    return rows, dropped


# --------------------------------------------------------------------------
# 5. 写出 + 自查
# --------------------------------------------------------------------------
def write_tsv(path: str, header_comment: str, lines: list[str]) -> bytes:
    body = header_comment + "\n" + "\n".join(lines) + "\n"
    data = body.encode("utf-8")
    with open(path, "wb") as fh:
        fh.write(data)
    return data


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def quality_report(entries: list[dict], phrases: list[dict], dropped: Counter) -> dict:
    texts = [e["text"] for e in entries]
    dup_text = [t for t, n in Counter(texts).items() if n > 1]
    empty = [t for t in texts if not t.strip()]
    spaces = [t for t in texts if any(ch.isspace() for ch in t)]
    flag_counts: Counter[str] = Counter()
    for e in entries:
        for f in e["flags"].split(","):
            if f:
                flag_counts[f] += 1
    src_counts: Counter[str] = Counter()
    for e in entries:
        for s in e["source"].split("+"):
            src_counts[s] += 1
    len_counts = Counter(len(t) for t in texts)
    freq_sorted = all(entries[i]["freq"] >= entries[i + 1]["freq"] for i in range(len(entries) - 1))
    return {
        "total": len(entries),
        "phrases": len(phrases),
        "flag_counts": dict(flag_counts.most_common()),
        "source_counts": dict(src_counts.most_common()),
        "len_counts": dict(sorted(len_counts.items())),
        "dup_text": dup_text[:10],
        "empty": empty[:10],
        "spaces": spaces[:10],
        "freq_sorted": freq_sorted,
        "dropped": dict(dropped.most_common()),
        "freq_min": entries[-1]["freq"] if entries else 0,
        "freq_max": entries[0]["freq"] if entries else 0,
    }


def sample_rows(entries: list[dict], n: int = 30) -> list[dict]:
    """按固定步长抽样（幂等），用于 README 人工抽检表。"""
    if not entries:
        return []
    step = max(1, len(entries) // n)
    picked = [entries[i] for i in range(0, len(entries), step)][:n]
    return picked


def main() -> int:
    ap = argparse.ArgumentParser(description="生成墨语中文聊天词库")
    ap.add_argument("--check", action="store_true", help="只做质量自查，不写文件")
    ap.add_argument("--out", default=OUT_DIR, help="输出目录")
    args = ap.parse_args()

    lazy_pinyin, py_note = build_pinyin_table()
    log("[1/4] 读取 jieba 词表: %s" % CACHE_PATH)
    entries, dropped = collect_entries(lazy_pinyin)
    log("[2/4] 生成短语联想…")
    phrases, phrase_dropped = build_phrases(lazy_pinyin)
    dropped.update(phrase_dropped)

    report = quality_report(entries, phrases, dropped)
    log("[3/4] 质量自查：")
    log("      总条数 = %d（目标 4000-7000）" % report["total"])
    log("      短语条数 = %d（目标 >=300）" % report["phrases"])
    log("      flags 分布 = %s" % json.dumps(report["flag_counts"], ensure_ascii=False))
    log("      来源分布 = %s" % json.dumps(report["source_counts"], ensure_ascii=False))
    log("      词长分布 = %s" % json.dumps(report["len_counts"], ensure_ascii=False))
    log("      词频范围 = %s .. %s，降序排列 = %s"
        % (report["freq_max"], report["freq_min"], report["freq_sorted"]))
    log("      重复词 = %s / 空词 = %s / 含空白词 = %s"
        % (report["dup_text"], report["empty"], report["spaces"]))
    log("      丢弃统计 = %s" % json.dumps(report["dropped"], ensure_ascii=False))

    if args.check:
        log("[--check] 不写文件，结束。")
        return 0

    if not (4000 <= report["total"] <= 7000):
        log("!! 条数不在 4000-7000 目标区间，请调整 N_JIEBA / JIEBA_MIN_FREQ")

    os.makedirs(args.out, exist_ok=True)
    base_path = os.path.join(args.out, "base_dict.tsv")
    phrase_path = os.path.join(args.out, "phrases.tsv")
    meta_path = os.path.join(args.out, "dict_meta.json")

    base_lines = ["%s\t%s\t%d\t%s" % (e["pinyin"], e["text"], e["freq"], e["flags"]) for e in entries]
    base_bytes = write_tsv(
        base_path,
        "# 墨语输入法基础词库 v%s | 拼音<TAB>词<TAB>词频<TAB>flags | 共 %d 条"
        % (DICT_VERSION, len(entries)),
        base_lines,
    )
    phrase_lines = ["%s\t%s\t%s" % (p["pinyin"], p["trigger"], p["text"]) for p in phrases]
    write_tsv(
        phrase_path,
        "# 墨语输入法短语联想库 v%s | 建议词拼音<TAB>触发词<TAB>建议词 | 共 %d 条"
        % (DICT_VERSION, len(phrases)),
        phrase_lines,
    )

    meta = {
        "version": DICT_VERSION,
        "generated_at": GENERATED_DATE,
        "count": len(entries),
        "phrase_count": len(phrases),
        "flags": report["flag_counts"],
        "sources": [
            {"name": "jieba dict.txt", "url": "https://github.com/fxsjy/jieba", "license": "MIT"},
            {"name": "chat_supplement.py", "url": "本项目原创", "license": "项目内使用"},
            {"name": "symbol_map.py", "url": "本项目原创", "license": "项目内使用"},
            {"name": "phrase_pairs.py", "url": "本项目原创", "license": "项目内使用"},
        ],
        "pinyin": py_note,
        "files": {
            "base_dict.tsv": {
                "bytes": len(base_bytes),
                "sha256": hashlib.sha256(base_bytes).hexdigest(),
            },
            "phrases.tsv": {
                "bytes": os.path.getsize(phrase_path),
                "sha256": sha256_of(phrase_path),
            },
        },
    }
    with open(meta_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")

    log("[4/4] 已写出：")
    log("      %s（%d 条，%.1f KB）" % (base_path, len(entries), len(base_bytes) / 1024))
    log("      %s（%d 条）" % (phrase_path, len(phrases)))
    log("      %s" % meta_path)
    log("      抽样 30 条（供 README 抽检表）：")
    for row in sample_rows(entries, 30):
        log("        %-18s %-8s %-6d %s" % (row["pinyin"], row["text"], row["freq"], row["flags"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
