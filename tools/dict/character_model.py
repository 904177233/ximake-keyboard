"""从现有 Tatoeba 快照生成字级三元回退表。只保存出现至少两次的边。"""
import bisect
import bz2
import hashlib
import json
import math
import re
import struct
from collections import Counter

import build_binary as b
from chat_model import metadata as chat_metadata
from experience_eval import fixtures

FILE = "chat_chars.bin"
BOS, EOS = 1, 2
SCALE = 256


def metadata():
    info = chat_metadata()
    return dict(info, name="chat_chars", format="MCC1", source="Tatoeba 中文贡献者；连续汉字片段的字符统计",
                build="tools/dict/character_model.py")


def build():
    if hashlib.sha256(b.TATOEBA.read_bytes()).hexdigest() != metadata()["source_sha256"]:
        raise ValueError("Tatoeba 快照校验失败")
    excluded = set()
    for name in ("ime_bench.tsv", "long_sentence_dev.tsv", "long_sentence_blind.tsv"):
        for row in fixtures(name):
            excluded.update(row[3:])
    simplify = b.opencc_simplifier()
    uni, bi, tri = Counter(), Counter(), Counter()
    with bz2.open(b.TATOEBA, "rt", encoding="utf-8") as stream:
        for line in stream:
            text = simplify(line.rstrip().split("\t", 2)[2]).replace("著", "着")
            for clause in re.findall("[一-鿿]+", text):
                if clause in excluded:
                    continue
                chars = [BOS, *map(ord, clause), EOS]
                uni.update(chars)
                bi.update(zip(chars, chars[1:]))
                tri.update(zip(chars, chars[1:], chars[2:]))
    # 加性平滑。保存相对于无观察时的对数概率增量，以及各历史的回退系数。
    total = sum(uni.values())
    def background(c):
        return (uni[c] + 2) / total
    def lower(a, c):
        n = bi[a,c]
        return ((n if n >= 2 else 0) + 64 * background(c)) / (uni[a] + 64)
    def q(value):
        return round(value * SCALE)
    result = bytearray(struct.pack("<4sIII", b"MCC1", 65536, sum(n>=2 for n in bi.values()), sum(n>=2 for n in tri.values())))
    for c in range(65536):
        result.extend(struct.pack("<hh", q(math.log(background(c))), q(-math.log1p(uni[c]/64))))
    for (a,c), n in sorted(bi.items()):
        if n >= 2:
            result.extend(struct.pack("<Ihh", a << 16 | c, q(math.log1p(n/(64*background(c)))), q(-math.log1p(n/16))))
    for (a,b_,c), n in sorted(tri.items()):
        if n >= 2:
            key = a << 32 | b_ << 16 | c
            result.extend(struct.pack("<Q", key << 16 | q(math.log1p(n/(16*lower(b_,c))))))
    return result


class CharacterModel:
    def __init__(self, path=None):
        data = (path or b.OUT_DIR / FILE).read_bytes()
        magic, n, nb, nt = struct.unpack_from("<4sIII", data)
        assert magic == b"MCC1" and n == 65536
        self.uni = memoryview(data)[16:16+n*4].cast("h")
        start = 16+n*4
        self.bi = {k: (lift, back) for k,lift,back in struct.iter_unpack("<Ihh",data[start:start+nb*8])}
        self.tri = memoryview(data)[start+8*nb:].cast("Q")
        assert len(self.tri) == nt

    def score(self, a, b_, c):
        lift, _ = self.bi.get(b_ << 16 | c, (0,0))
        _, back = self.bi.get(a << 16 | b_, (0,0))
        key = a << 48 | b_ << 32 | c << 16
        i = bisect.bisect_left(self.tri,key)
        extra = self.tri[i] - key if i<len(self.tri) and self.tri[i]>>16 == key>>16 else 0
        return (self.uni[2*c] + self.uni[2*b_+1] + lift + back + extra) / SCALE

    def extend(self, prefix, text, final, residual=False):
        prev = ([0, BOS] + [min(ord(c),65535) for c in prefix[-2:]])[-2:]
        chars = [min(ord(c),65535) for c in text]
        if final:
            chars.append(EOS)
        total = 0.0
        a,b_ = prev
        for c in chars:
            value = self.score(a,b_,c)
            if residual:
                uni = self.uni[2*c] / SCALE
                value = max(uni - 2, value) - 0.5 * uni
            total += value
            a,b_ = b_,c
        return total


if __name__ == "__main__":
    data = build()
    (b.OUT_DIR/FILE).write_bytes(data)
    path = b.OUT_DIR/"dict_meta.json"
    meta = json.loads(path.read_text(encoding="utf-8"))
    meta["offline_models"] = [m for m in meta["offline_models"] if m["name"] != "chat_chars"] + [metadata()]
    meta["files"][FILE] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    path.write_text(json.dumps(meta, ensure_ascii=False, indent=2)+"\n", encoding="utf-8", newline="\n")
    print(FILE, meta["files"][FILE])
