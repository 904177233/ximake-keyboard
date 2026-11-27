"""从公开中文句子估计聊天简拼的词频和条件概率，训练、推断与独立评测。"""
import argparse
import bz2
import hashlib
import json
import math
import re
import struct
from collections import Counter, defaultdict

import build_binary as b
from experience_eval import Decoder, fixtures, segmented, split_keys


def bench():
    path = b.HERE / "ime_bench.tsv"
    return [line.split("\t") for line in path.read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")]


def train():
    frequency, reading = {}, {}
    for key, mask, _, entries in split_keys((b.OUT_DIR / "moyu.dict").read_bytes()):
        sounds = b.split_by_mask(key, mask)
        for word, count, _ in entries:
            if count > frequency.get(word, 0) and len(sounds) == len(word):
                frequency[word], reading[word] = count, sounds
    # 排除与评测目标完全相同的子句；更长句中的自然词对仍可训练。
    excluded = {r[3] for r in bench()} | {r[-1] for r in fixtures("long_sentence_blind.tsv")}
    simplify = b.opencc_simplifier()
    unigram, pairs = Counter(), Counter()
    with bz2.open(b.TATOEBA, "rt", encoding="utf-8") as stream:
        for line in stream:
            sentence = simplify(line.rstrip().split("\t", 2)[2]).replace("著", "着")
            for clause in re.findall("[一-鿿]+", sentence):
                if clause in excluded:
                    continue
                words = segmented(clause, frequency, penalty=15)
                if not words:
                    continue
                unigram.update(words)
                pairs.update(zip([""] + words, words + [""]))
    # 词 ID 0 代表句界。词频决定首字母下的召回池，不沿用通用词典的前 12 键。
    kept = sorted(w for w in unigram if unigram[w] >= 2 and len(w) <= 8)
    ids = {w: i for i, w in enumerate([""] + kept)}
    total = sum(unigram.values())
    observations = Counter()
    for (l, r), n in pairs.items():
        observations[l] += n
    # 条件概率以背景词频回退；存 log 比率，低频词对往背景分布收缩。
    edges = {}
    for (l, r), n in pairs.items():
        if l not in ids or r not in ids:
            continue
        background = (unigram[r] if r else observations[""]) / total
        lift = math.log1p(n / (12 * background)) - math.log1p(observations[l] / 12)
        edges[ids[l], ids[r]] = max(-128, min(127, round(lift * 12)))
    by_key = defaultdict(list)
    for w in kept:
        key = "".join(s[0] for s in reading[w])
        by_key[key].append((ids[w], w, "".join(reading[w]), round(16 * math.log(unigram[w] / total))))
    rows = [(k, *row) for k in sorted(by_key)
            for row in sorted(by_key[k], key=lambda x: (-x[3], x[0]))[:12]]
    return rows, edges


HEADER = struct.Struct("<4sIII")
WORD = struct.Struct("<IIhBB")
EDGE = struct.Struct("<IIb3x")


def pack(rows, edges):
    blob, records = bytearray(), bytearray()
    for k, wid, text, reading, q in rows:
        value = text.encode()
        records.extend(WORD.pack(len(blob), wid, q, len(k), len(value)))
        blob.extend(k.encode() + value + reading.encode() + b"\0")
    active = {0} | {row[1] for row in rows}
    kept = sorted((a, b_, v) for (a, b_), v in edges.items() if a in active and b_ in active)
    return (HEADER.pack(b"MCB1", len(rows), len(kept), len(blob)) + records
            + b"".join(EDGE.pack(*edge) for edge in kept) + blob)


def decode(key, table, edges, weight):
    states = [[] for _ in range(len(key) + 1)]
    states[0] = [(0, 0, "")]
    for start in range(len(key)):
        previous = sorted(states[start], key=lambda x: -x[0])[:8]
        for end in range(start + 1, min(len(key), start + 8) + 1):
            for wid, word, q in table.get(key[start:end], ()):
                for score, left, prefix in previous:
                    lift = edges.get((left, wid), -36) / 12
                    value = score + q / 16 + weight * lift
                    if end == len(key):
                        value += weight * edges.get((wid, 0), -36) / 12
                    states[end].append((value, wid, prefix + word))
    return list(dict.fromkeys(w for _, _, w in sorted(states[-1], key=lambda x: -x[0])))[:3]


def metadata():
    return {"name": "chat_initials", "status": "shipped", "format": "MCB1",
            "source": "Tatoeba cmn_sentences.tsv.bz2，中文贡献者；词条读音沿用当前 moyu.dict",
            "url": "https://downloads.tatoeba.org/exports/per_language/cmn/",
            "license": "CC BY 2.0 FR（句子）；模型仅含统计与现有词典词条",
            "source_sha256": "262a48cacb7693f6e47a2c4c42f216a5c45dd28b9b62014b159628cc908e8fcc",
            "build": "tools/dict/chat_model.py --write"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write and hashlib.sha256(b.TATOEBA.read_bytes()).hexdigest() != metadata()["source_sha256"]:
        raise ValueError("训练语料快照已变更，请先核对授权、版本与盲集")
    rows, edges = train()
    table = defaultdict(list)
    for key, wid, word, _, q in rows:
        table[key].append((wid, word, q))
    # 旧 Python 工具没有最终候选列表，单独列出其 DP 路径供交叉检查。
    proxy = Decoder()
    samples = [r for r in bench() if r[0] == "简拼整句"]
    before = [proxy.decode(r[1], width=4) for r in samples]
    print("原 DP 近似", sum(d[:1] == [r[3]] for r, d in zip(samples, before)),
          sum(r[3] in d for r, d in zip(samples, before)))
    trial = []
    for row, old in zip(samples, before):
        key = row[1]
        model = decode(key, table, edges, 1) if 4 <= len(key) <= 12 and not set(key) & set("aeiouv") else []
        trial.append(list(dict.fromkeys(model[:1] + old[:1] + model[1:] + old[1:]))[:3])
    print("按工作区顺序合并近似路径", sum(d[:1] == [r[3]] for r, d in zip(samples, trial)),
          sum(r[3] in d for r, d in zip(samples, trial)),
          "修回", sum(a[:1] != [r[3]] == c[:1] for r, a, c in zip(samples, before, trial)),
          "新增错误", sum(a[:1] == [r[3]] != c[:1] for r, a, c in zip(samples, before, trial)))
    for weight in (0, 1):
        for category in ("简拼整句", "简拼"):
            samples = [r for r in bench() if r[0] == category]
            ranks = Counter()
            for _, key, _, want, _ in samples:
                options = decode(key, table, edges, weight)
                ranks[options.index(want) + 1 if want in options else 0] += 1
                if key in ("nzgsm", "ncflm"):
                    print(key, weight, options)
            print(category, weight, len(samples), ranks)
    word_ids = {row[2]: row[1] for row in rows}
    def sentence_lift(text):
        words = segmented(text, proxy.freq, penalty=15)
        ids = [0] + [word_ids.get(w, -1) for w in words] + [0]
        return sum(edges.get(pair, -36) for pair in zip(ids, ids[1:])) / (12 * max(1, len(words)))

    weight = 0.0
    for dataset in ("long_sentence_dev.tsv", "long_sentence_blind.tsv"):
        original = hits = 0
        trials = []
        for mode, key, left, expected, _ in fixtures(dataset):
            options = proxy.decode(key, "t9" if mode == "t9" else "qwerty", left, width=4)
            original += options[:1] == [expected]
            trials.append((options, [sentence_lift(w) for w in options], expected))
            if mode == "initials" and 4 <= len(key) <= 12 and not set(key) & set("aeiouv"):
                options = decode(key, table, edges, 1)
            hits += options[:1] == [expected]
        print(dataset, "首选", original, hits)
        def rerank(w):
            targets = []
            for candidates, lifts, expected in trials:
                index = max(range(len(candidates)), key=lambda i: w * lifts[i] - i, default=None)
                targets.append(index is not None and candidates[index] == expected)
            return targets
        if dataset == "long_sentence_dev.tsv":
            weights = (0, 0.5, 1, 2)
            print("整句重排开发集", [(w, sum(rerank(w))) for w in weights])
            weight = max(weights, key=lambda w: sum(rerank(w)))
        baseline, trial = rerank(0), rerank(weight)
        print("整句重排权重", weight, "修回", sum(b and not a for a, b in zip(baseline, trial)),
              "新增错误", sum(a and not b for a, b in zip(baseline, trial)))
    data = pack(rows, edges)
    print("字节", len(data), "摘要", hashlib.sha256(data).hexdigest())
    if args.write:
        model = b.OUT_DIR / "chat_initials.bin"
        model.write_bytes(data)
        path = b.OUT_DIR / "dict_meta.json"
        meta = json.loads(path.read_text(encoding="utf-8"))
        meta["offline_models"] = [m for m in meta["offline_models"] if m["name"] != "chat_initials"]
        meta["offline_models"].append(metadata())
        meta["files"][model.name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")



if __name__ == "__main__":
    main()
