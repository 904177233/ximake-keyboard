"""Windows 上复现 imecheck 的固定触点。整句使用 Python 近似引擎，发布门槛由 Swift 执行。"""
import argparse
import bisect
import math
from functools import lru_cache

from lm_eval import Replay, Model, OUT, WEIGHT, fixtures, b


def layout(width):
    w = (width - 51) / 10
    keys = []
    def row(letters, x, y, cap):
        keys.extend((c, x + i * (cap + 5), y, cap, 44) for i, c in enumerate(letters))
    row("qwertyuiop", 3, 6, w)
    row("asdfghjkl", (width - 9*w - 40)/2, 59, w)
    side = max(40, w * 1.28)
    row("#", 3, 112, side)
    row("zxcvbnm", (width - 7*w - 30)/2, 112, w)
    row("#", width - 3 - side, 112, side)
    for x, cap in [(3,42), (50,38), (93,32), (width-153,32),
                   (130,width-288), (width-116,40), (width-71,68)]:
        row("#", x, 165, cap)
    return keys


PREFIX = {}
for syllable in b.SYL_SET - b.UNLIKELY_SINGLE:
    if not syllable.isascii():
        continue
    for i, c in enumerate(syllable):
        PREFIX.setdefault(syllable[:i], set()).add(c)


@lru_cache(8192)
def continuation(text):
    if not text:
        return set()
    reached = {0}
    mask = set()
    for i in range(len(text)):
        if i not in reached:
            continue
        for j in range(i+1, min(i+6,len(text))+1):
            sub = text[i:j]
            if sub in b.SYL_SET and sub not in b.UNLIKELY_SINGLE:
                reached.add(j)
            if j == len(text):
                mask.update(PREFIX.get(sub, ()))
    if len(text) in reached:
        mask.update(PREFIX[""])
    return mask


class Noise:
    def __init__(self):
        self.state = 87

    def uniform(self):
        mask = (1 << 64) - 1
        self.state = (self.state + 0x9E3779B97F4A7C15) & mask
        z = self.state
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9 & mask
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB & mask
        return (((z ^ (z >> 31)) >> 11) + 0.5) / (1 << 53)

    def pair(self):
        r = math.sqrt(-2 * math.log(self.uniform()))
        angle = 2 * math.pi * self.uniform()
        return r * math.cos(angle), r * math.sin(angle)


def resolve(point, keys, prefix, english, upward):
    x, y = point
    def edge(key):
        _, l, t, w, h = key
        return max(l-x, 0, x-l-w)**2 + max(t-y, 0, y-t-h)**2
    old = min(keys, key=edge)
    original, l, t, w, h = old
    mask = continuation(prefix)
    if not mask or original == "#" or (l+.2*w <= x < l+.8*w and t+.2*h <= y < t+.8*h):
        return original, original
    best = original
    def score(key):
        c, left, top, width, height = key
        dx = (x-left-width/2)/(w+5)
        dy = (y-upward-top-height/2)/(h+9)
        return dx*dx+dy*dy - .24*(c in mask)
    lowest = score(old)
    for key in keys:
        c, left, top, width, height = key
        if c == "#" or abs(x-left-width/2) > (w+5)*.78 or abs(y-top-height/2) > (h+9)*.78:
            continue
        if score(key) < lowest:
            best, lowest = c, score(key)
    if best != original and len(prefix)<32:
        k = prefix+original
        i = bisect.bisect_left(english,k)
        if i<len(english) and english[i].startswith(k):
            best = original
    return original, best


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offset", type=float, default=2, help="触点向上补偿的点数")
    parser.add_argument("--bias", type=float, default=3, help="模拟手指相对键心向下偏移的点数")
    args = parser.parse_args()
    engine = Replay(match_swift_beam=True)
    model = Model(OUT/"libime_sc.bin")
    sample = [r for r in fixtures("ime_bench.tsv") if r[0] in ("短句","长句")]
    noise = Noise()
    for wi, width in enumerate((390,393,430)):
        keys = layout(width)
        caps = {k[0]: k for k in keys}
        errors = [0,0]
        hits = [0,0]
        letters = 0
        for ri, (cat, raw, left, want, sounds) in enumerate(sample):
            sigma = (.25,.30,.35)[(ri+wi)%3]
            strings = ["",""]
            interrupted = [False,False]
            for c in raw:
                _,l,t,w,h = caps[c]
                nx,ny = noise.pair()
                point = l+w/2+nx*sigma*w, t+h/2+ny*sigma*w+args.bias
                pair = resolve(point,keys,strings[1],engine.english,args.offset)
                for i, key in enumerate(pair):
                    errors[i] += key != c
                    if key == "#":
                        interrupted[i] = True
                        strings[i] = ""
                    else:
                        strings[i] += key
                letters += 1
            for i, text in enumerate(strings):
                if not interrupted[i]:
                    out,_ = engine.convert((cat,text,left,want,sounds),model,WEIGHT)
                    hits[i] += out[:1]==[want]
        print(width, "字母总数", letters, "错误", errors, "整句", hits, "/",len(sample),flush=True)


if __name__=="__main__":
    main()
