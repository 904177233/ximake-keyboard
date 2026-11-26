"""从雾凇 base 多字词的切分训练量化词对，开发集选权重后只对盲集比较一次。"""
import math
import mmap
import struct
from collections import Counter
from functools import lru_cache
from hashlib import sha256

import build_binary as b
from experience_eval import Decoder, fixtures, replay, segmented, summary

HEADER = struct.Struct("<4sII")
EDGE = struct.Struct("<IIB3x")
OUTPUT = b.HERE / ".cache" / "bigram.bin"


def build(dictionary):
    # 用随包词典字符串池偏移作跨读音共享的整数词 ID。
    pairs = Counter()
    for text, (syllables, weight) in b.load_rime_ice().items():
        if len(text) < 3:
            continue
        # 强制至少切出两个词。保留其他词的真实词频。
        freq = dictionary.freq
        saved = freq.pop(text, None)
        words = segmented(text, freq)
        if saved is not None:
            freq[text] = saved
        for left, right in zip(words, words[1:]):
            pairs[dictionary.ids[left], dictionary.ids[right]] += 1
    kept = sorted(sorted(pairs, key=lambda edge:(-pairs[edge],edge))[:90000])
    with OUTPUT.open("wb") as stream:
        stream.write(HEADER.pack(b"MYB1",1,len(kept)))
        for left,right in kept:
            q = min(255, round(16 * math.log1p(pairs[left,right])))
            stream.write(EDGE.pack(left,right,q))
    return len(kept)


def main():
    engine = Decoder()
    n = build(engine)
    print("边、字节、文件摘要", n, OUTPUT.stat().st_size, sha256(OUTPUT.read_bytes()).hexdigest())
    with OUTPUT.open("rb") as stream, mmap.mmap(stream.fileno(),0,access=mmap.ACCESS_READ) as data:
        @lru_cache(maxsize=8192)
        def lookup(left,right):
            lo,hi = 0,n
            while lo<hi:
                mid=(lo+hi)//2
                a,b,q=EDGE.unpack_from(data,HEADER.size+mid*EDGE.size)
                if (a,b)<(left,right):
                    lo=mid+1
                elif (a,b)>(left,right):
                    hi=mid
                else:
                    return q/16
            return 0

        dev = fixtures("long_sentence_dev.tsv")
        dev_baseline = replay(dev, engine, True)
        grid = []
        for weight in (0.125, 0.25, 0.5, 1.0):
            outputs = replay(dev, engine, True, lookup, weight)
            metrics = summary(dev, outputs, dev_baseline)
            grid.append((metrics["top1"], metrics["top3"], metrics["chars"], -weight, metrics))
            print("开发集", weight, metrics)
        _, _, _, negative_weight, selected_metrics = max(grid, key=lambda row: row[:4])
        weight = -negative_weight

        blind = fixtures("long_sentence_blind.tsv")
        previous = replay(blind, Decoder(True))
        current = replay(blind, engine, True)
        trial = replay(blind, engine, True, lookup, weight)
        model_vs_multi = summary(blind, trial, current)
        old_vs_model = summary(blind, trial, previous)
        old_metrics = summary(blind, previous)
        dev_metrics = summary(dev, dev_baseline)
        print("开发集基线", dev_metrics)
        print("选中的权重", weight, selected_metrics)
        print("盲集旧版", old_metrics)
        print("盲集多候选", summary(blind, current, previous))
        print("盲集二元模型", weight, model_vs_multi, "对比旧版", old_vs_model)
        use_model = (
            selected_metrics["top1"] >= dev_metrics["top1"]
            and old_vs_model["top1"] >= old_metrics["top1"]
            and model_vs_multi["fixed"] > model_vs_multi["regressed"]
        )
        print("??", use_model)



if __name__=="__main__":
    main()
