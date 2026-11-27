"""从指定快照的 libime ARPA 剪枝。构建依赖 NumPy；键盘只读取定长小端表。"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[1] / "ios/Shared/dict"
SOURCE = HERE / ".cache/libime/lm_sc.arpa"
ARCHIVE = "lm_sc.arpa-20260629.tar.zst"
ARCHIVE_SHA = "06808333b9173e5374cf2cb5afc12d08f5625bf9abb536489cac376fc05f2e7f"
ARPA_SHA = "9cbfd115c139162fbafc54a1b7a2dbd03d16ac7cd1bb127b2bfbbbfc78436dfa"
TIERS = {"small": (720000, 120000), "bigram": (1300000, 0),
         "medium": (1000000, 230000), "large": (1250000, 320000)}
DEFAULT = "medium"
HEADER = struct.Struct("<4s7I")
SHIFT = 21
MASK = (1 << SHIFT) - 1


def metadata():
    return {"name": "libime_sc", "format": "MLM1", "version": "20260629", "status": "shipped",
            "url": "https://download.fcitx-im.org/data/" + ARCHIVE, "source_sha256": ARCHIVE_SHA,
            "arpa_sha256": ARPA_SHA, "license": "LGPL-2.1-or-later",
            "copyright": "2022~2026 CSSlayer <wengxt@gmail.com>",
            "build": "python tools/dict/build_lm.py", "profile": DEFAULT}


def fingerprint(word):
    value = 14695981039346656037
    for byte in word:
        value = (value ^ byte) * 1099511628211 & 0xffffffffffffffff
    return value


def vocabulary(path):
    data = path.read_bytes()
    magic, version, count, _, _, entries, _, _, _, blob = struct.unpack_from("<4s9I", data)
    assert (magic, version) == (b"MYD3", 1)
    return {data[blob + off:blob + off + size] for off, _, size, flags in
            struct.iter_unpack("<IIBB2x", data[entries:entries + count * 12]) if not flags & 11}


def read_arpa(path, vocab):
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != ARPA_SHA:
            raise ValueError("解压后的 ARPA 与上游快照不符")
        stream.seek(0)
        index = {}
        unigrams = []
        order = 0
        for raw in stream:
            line = raw.strip()
            if line.startswith(b"\\"):
                if line == b"\\end\\":
                    break
                if not line.endswith(b"-grams:"):
                    continue
                order = int(line[1:2])
                if order == 2:
                    unigrams.sort()
                    hashes, words, probabilities, weights = zip(*unigrams)
                    assert len(set(hashes)) == len(words) < MASK
                    index = {word: i for i, word in enumerate(words)}
                if order == 3:
                    bigrams = keys, probs, backs
                    bigram_count = used
                if order >= 2:
                    limit = 4789953 if order == 2 else 2189434
                    keys = np.empty(limit, "<u8")
                    probs = np.empty(limit, "f4")
                    backs = np.empty(limit, "f4")
                    used = 0
                continue
            if not line or not order:
                continue
            fields = line.split(b"\t")
            if order == 1:
                w = fields[1]
                if w in vocab or w == b"<unk>":
                    unigrams.append((fingerprint(w), w, float(fields[0]), float(fields[2]) if len(fields) > 2 else 0))
            else:
                ids = fields[1].split()
                a = index.get(ids[0])
                b = index.get(ids[1])
                if a is None or b is None:
                    continue
                key = a << SHIFT | b
                if order == 3:
                    c = index.get(ids[2])
                    if c is None:
                        continue
                    key = key << SHIFT | c
                keys[used] = key
                probs[used] = float(fields[0])
                backs[used] = float(fields[2]) if len(fields) == 3 else 0
                used += 1
        def sorted_table(table, count):
            k, p, b = table
            ix = np.argsort(k[:count], kind="stable")
            return k[ix], p[ix], b[ix]
        return (np.array(hashes, "<u8"), np.array(probabilities, "f4"), np.array(weights, "f4"),
                sorted_table(bigrams, bigram_count), sorted_table((keys, probs, backs), used), index[b"<unk>"])


def importance(data):
    _, uni, back, (bk, bp, bw), (tk, tp, _), _ = data
    # 删除一项所产生的绝对对数概率变化 × 估计联合概率，在对数域比较。
    def score(log_joint, delta):
        return log_joint + np.log10(np.maximum(abs(delta), 1e-8))
    bi = score(uni[bk >> SHIFT] + bp, bp - (back[bk >> SHIFT] + uni[bk & MASK]))
    def lookup(keys, fallback, values):
        ix = np.searchsorted(bk, keys).clip(max=len(bk) - 1)
        return np.where(bk[ix] == keys, values[ix], fallback)
    head = tk >> SHIFT
    tail = tk & ((1 << (SHIFT * 2)) - 1)
    first, middle, last = head >> SHIFT, head & MASK, tk & MASK
    history = uni[first] + lookup(head, back[first] + uni[middle], bp)
    lower = lookup(head, 0, bw) + lookup(tail, back[middle] + uni[last], bp)
    return bi, score(history + tp, tp - lower)


def encode(data, scores, tier):
    hashes, uni, back, bigrams, trigrams, unk = data
    def retain(table, values, count):
        ix = np.argsort(-values, kind="stable")[:count]
        ix.sort()
        return [x[ix] for x in table]
    bk, bp, bw = retain(bigrams, scores[0], TIERS[tier][0])
    tk, tp, _ = retain(trigrams, scores[1], TIERS[tier][1])
    n = len(hashes)
    def offsets(keys):
        return np.searchsorted(keys, np.arange(n + 1)).astype("<u4").tobytes()
    def q(values):
        return np.rint(values * 16).clip(-128, 127).astype("i1").tobytes()
    return b"".join([HEADER.pack(b"MLM1", n, len(bk), len(tk), unk, SHIFT, 16, 0),
                     hashes.tobytes(), (tk & ((1 << (2 * SHIFT)) - 1)).astype("<u8").tobytes(),
                     offsets(bk >> SHIFT), offsets(tk >> (2 * SHIFT)), (bk & MASK).astype("<u4").tobytes(),
                     q(uni), q(back), q(bp), q(bw), q(tp)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arpa", type=Path, default=SOURCE)
    parser.add_argument("--tiers", action="store_true", help="把全部实验档位写入 .cache/libime")
    args = parser.parse_args()
    data = read_arpa(args.arpa, vocabulary(OUT / "moyu.dict"))
    scores = importance(data)
    for tier in TIERS if args.tiers else [DEFAULT]:
        binary = encode(data, scores, tier)
        digest = hashlib.sha256(binary).hexdigest()
        print(tier, len(binary), digest)
        if args.tiers:
            directory = SOURCE.parent
            directory.mkdir(parents=True, exist_ok=True)
            (directory / (tier + ".bin")).write_bytes(binary)
        if tier == DEFAULT:
            (OUT / "libime_sc.bin").write_bytes(binary)
            path = OUT / "dict_meta.json"
            meta = json.loads(path.read_text(encoding="utf-8"))
            meta["offline_models"] = [m for m in meta["offline_models"] if m["name"] != "libime_sc"] + [metadata()]
            meta["files"]["libime_sc.bin"] = {"bytes": len(binary), "sha256": digest}
            path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()

