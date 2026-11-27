"""在冻结 TSV 上比较同一候选生成器的前后名次；macOS 的完整产品门槛由 imecheck 执行。"""
import argparse
import bisect
import math
import mmap
import struct
from collections import Counter, defaultdict
from functools import lru_cache

from build_lm import HEADER, SHIFT, SOURCE, OUT, TIERS, DEFAULT, fingerprint
import build_binary as b
from experience_eval import Decoder, fixtures
from typo_eval import edits


class Model:
    def __init__(self, path):
        with path.open("rb") as f:
            self.data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        magic, n, nb, nt, self.unknown, shift, scale, _ = HEADER.unpack_from(self.data)
        assert (magic, shift, scale) == (b"MLM1", SHIFT, 16)
        view = memoryview(self.data)
        off = HEADER.size
        def section(size, fmt):
            nonlocal off
            start = off
            off += size * struct.calcsize(fmt)
            return view[start:off].cast(fmt)
        self.hashes = section(n, "Q")
        self.tail = section(nt, "Q")
        self.brow = section(n + 1, "I")
        self.trow = section(n + 1, "I")
        self.last = section(nb, "I")
        self.uni, self.back = section(n, "b"), section(n, "b")
        self.bi, self.bback, self.tri = section(nb, "b"), section(nb, "b"), section(nt, "b")
        assert off == len(view)

    @lru_cache(65536)
    def word(self, text):
        h = fingerprint(text.encode())
        i = bisect.bisect_left(self.hashes, h)
        return i if i < len(self.hashes) and h == self.hashes[i] else self.unknown

    @staticmethod
    def find(row, keys, left, right):
        if left < 0:
            return -1
        end = row[left + 1]
        i = bisect.bisect_left(keys, right, row[left], end)
        return i if i < end and keys[i] == right else -1

    @lru_cache(65536)
    def probability(self, a, b_, c):
        if b_ < 0:
            return self.uni[c] / 16
        t = self.find(self.trow, self.tail, a, (b_ << SHIFT) | c)
        if t >= 0:
            return self.tri[t] / 16
        hist = self.find(self.brow, self.last, a, b_)
        suffix = self.find(self.brow, self.last, b_, c)
        return ((self.bback[hist] if hist >= 0 else 0) +
                (self.bi[suffix] if suffix >= 0 else self.back[b_] + self.uni[c])) / 16

    def trace_pages(self, page_size=16384):
        """记录同一只读布局实际访问的逻辑页，供估计模型工作集。"""
        touched = set()
        class Section:
            def __init__(self, view, offset):
                self.view, self.offset = view, offset

            def __len__(self):
                return len(self.view)

            def __getitem__(self, i):
                touched.add((self.offset + i * self.view.itemsize) // page_size)
                return self.view[i]

        offset = HEADER.size
        for name in ("hashes", "tail", "brow", "trow", "last", "uni", "back", "bi", "bback", "tri"):
            view = getattr(self, name)
            setattr(self, name, Section(view, offset))
            offset += view.nbytes
        return touched

    def feature(self, older, left, word):
        if not left:
            return 0
        a = self.word(older) if older else -1
        b_, c = self.word(left), self.word(word)
        uni = self.uni[c] / 16
        return min(2.5, self.probability(a, b_, c) - uni) + 0.25 * (uni + 4)


class Replay:
    def __init__(self):
        self.d = Decoder()
        self.chat = defaultdict(list)
        self.pairs = {}
        data = (OUT / "chat_initials.bin").read_bytes()
        _, nw, ne, _ = struct.unpack_from("<4sIII", data)
        edge = 16 + 12 * nw
        blob = edge + 12 * ne
        for off, i, q, k, size in struct.iter_unpack("<IIhBB", data[16:edge]):
            p = blob + off
            self.chat[data[p:p+k].decode()].append((data[p+k:p+k+size].decode(), i, q))
        self.pairs.update(((a, c), q) for a, c, q in struct.iter_unpack("<IIb3x", data[edge:blob]))
        rows = (OUT / "en_words.tsv").read_text(encoding="utf8").splitlines()
        self.en = dict((w, int(n)) for w, n in (row.split("\t") for row in rows))
        self.en["chatgpt"] = 1
        self.hot = defaultdict(list)
        self.hot_initials = defaultdict(list)
        for row in (OUT / "hot_words.tsv").read_text(encoding="utf8").splitlines():
            if row and not row.startswith("#"):
                word, sounds, freq = row.split("\t")
                syllables = sounds.split("'")
                entry = (word, syllables, int(freq))
                self.hot["".join(syllables)].append(entry)
                self.hot_initials["".join(s[0] for s in syllables)].append(entry)
        binary = (OUT / "moyu.dict").read_bytes()
        _, _, cnt, _, _, entries_at = struct.unpack_from("<4s5I", binary)
        self.chat_weight = {wid: (flags >> 4) / 5 for wid, _, _, flags in
                            struct.iter_unpack("<IIBB2x", binary[entries_at:entries_at+cnt*12]) if flags >> 4}
        self.keys = sorted(self.d.exact)
        self.english = sorted(self.en)

    @lru_cache(4096)
    def chat_paths(self, key):
        states = [[] for _ in range(len(key)+1)]
        states[0] = [(0, 0, ())]
        for i in range(len(key)):
            paths = sorted(states[i], key=lambda p: -p[0])[:8]
            for j in range(i+1, min(i+8, len(key))+1):
                for w, wid, q in self.chat.get(key[i:j], ()):
                    end = self.pairs.get((wid, 0), -36) if j == len(key) else 0
                    for score, last, words in paths:
                        states[j].append((score + 3*q + 4*(end + self.pairs.get((last, wid), -36)),
                                          wid, words + (w,)))
        return [p for p in sorted(states[-1], key=lambda p: -p[0])[:24]]

    @lru_cache(65536)
    def groups(self, sub, digits, breaks):
        groups = self.d.digits.get(sub, ())[:48] if digits else self.d.exact.get(sub, ())
        return [g for g in groups if all(x in {sum(map(len, g[2][:n])) for n in range(1, len(g[2]))}
                                          for x in breaks)]

    @lru_cache(32768)
    def prefix(self, sub):
        i = bisect.bisect_left(self.keys, sub)
        best = None
        for j in range(i, min(i+8000, len(self.keys))):
            k = self.keys[j]
            if not k.startswith(sub):
                break
            for g in self.d.exact[k]:
                if best is None or best[0] < g[0]:
                    best = g
        return best

    @staticmethod
    @lru_cache(65536)
    def full(key):
        reached = {0}
        for i in range(len(key)):
            if i in reached:
                reached.update(j for j in range(i+1, min(i+6, len(key))+1)
                               if key[i:j] in b.SYL_SET and key[i:j] not in b.UNLIKELY_SINGLE)
        return len(key) in reached

    @lru_cache(32768)
    def edit_tiles(self, sub, at_end):
        result = []
        for k, cost in edits(sub, at_end).items():
            groups = self.d.exact.get(k)
            if groups and groups[0][2][0] not in b.UNLIKELY_SINGLE:
                _, _, syl, entries = groups[0]
                for w, freq, _ in entries[:1]:
                    base = math.log1p(freq)-14 + (0 if k in b.SYL_SET else 2*(len(syl)-1))
                    result.append((w, k, base-max(1, cost-max(0,len(syl)-2)), "edit"))
        return result

    @lru_cache(16384)
    def lattice(self, raw, digits, full, lm, editing):
        key = raw.replace("'", "")
        breaks = {len(s.replace("'", "")) for s in (raw[:i] for i,c in enumerate(raw) if c == "'")}
        positions = []
        for i in range(len(key)):
            tiles = []
            for j in range(i+1, min(len(key), i+24)+1):
                sub = key[i:j]
                internal = tuple(x-i for x in breaks if i<x<j)
                groups = self.groups(sub, digits, internal)
                for _, k, syl, entries in groups:
                    if digits and syl[0] in b.UNLIKELY_SINGLE:
                        continue
                    base = (2*(len(syl)-1) if digits or k not in b.SYL_SET else 0) - 14
                    if syl[0] in b.UNLIKELY_SINGLE:
                        base -= 20
                    for w, freq, _ in entries[:(3 if digits else 8) if lm else (1 if digits else 3)]:
                        tiles.append((j,w,k,math.log1p(freq)+base,"exact"))
                hot = self.hot.get(sub, ()) if not digits and not internal else ()
                for w, syl, f in hot[:2]:
                    tiles.append((j, w, sub, math.log1p(f) - 14 + (0 if sub in b.SYL_SET else 2*(len(syl)-1)), "exact"))
                if editing:
                    if len(sub) <= 12:
                        tiles.extend((j,*t) for t in self.edit_tiles(sub, j==len(key)))
                    continue
                if internal:
                    continue
                if len(sub)<=6 and ((digits and len(sub)>=2) or (not digits and not full and not groups and not hot)):
                    g = (self.d.di if digits else self.d.initials).get(sub, ())
                    penalty = 4 if digits else (10 if len(sub)==1 else 3+4*sum(c in "aeo" for c in sub))
                    for _,k,_,entries in g[:3 if digits else 12]:
                        for w,f,_ in entries[:1 if digits else 2]:
                            tiles.append((j,w,k,math.log1p(f)-14-penalty+3*(len(sub)-1),"initial"))
                    if not digits and len(sub) >= 2:
                        for w, syl, f in self.hot_initials.get(sub, ())[:3]:
                            tiles.append((j,w,"".join(syl),math.log1p(f)-14-penalty+3*(len(sub)-1),"initial"))
                if not digits and not full and j==len(key) and len(sub)>=2 and not groups and not self.full(sub):
                    g = self.prefix(sub)
                    if g:
                        w,f,_ = g[3][0]
                        tiles.append((j,w,g[1],math.log1p(f)-15.5,"partial"))
            positions.append(tiles)
        return positions

    def paths(self, raw, digits, left, full, model, weight, editing=False):
        key = raw.replace("'", "")
        n = len(key)
        states = [[[] for _ in range(n+1)] for _ in range(2 if editing else 1)]
        states[0][0] = [(0, "", "", left, (), "", False)]
        for i, tiles in enumerate(self.lattice(raw, digits, full, bool(model), editing)):
            for layer, buckets in enumerate(states):
                unique = {}
                for state in sorted(buckets[i], key=lambda x:(-x[0], x[1])):
                    hist = (state[2] if model else "", state[3])
                    unique.setdefault(hist, state)
                    if len(unique)>= (1 if editing else 4):
                        break
                for s,text,older,prev,words,_,mismatch in unique.values():
                    for j,w,k,base,kind in tiles:
                        target = layer + (kind=="edit")
                        if target>=len(states):
                            continue
                        if model:
                            ctx = (4 if i == 0 and left else weight) * model.feature(older, prev, w)
                        else:
                            ctx = 3*(w in self.d.strong.get(prev, ()))
                            if kind=="initial" and prev and self.d.freq.get(prev[-1]+w[0],0)>=200:
                                ctx+=2
                        out = b.ENDING_PARTICLES.get(k,w) if i and j==n else w
                        states[target][j].append((s+base+ctx,text+out,prev,w,words+(w,),kind,mismatch or kind=="initial"))
        ranked = sorted(states[-1][-1], key=lambda x:(-x[0],x[1]))
        unique = {}
        histories = set()
        for p in ranked:
            history = (p[2] if model else "", p[3])
            if history in histories or p[1] in unique:
                continue
            histories.add(history)
            unique[p[1]] = p
            if len(unique) == 4:
                break
        return list(unique.values())[:3]

    def convert(self, row, model, weight, correct=True):
        cat,raw,left,_,_ = row
        key = raw.replace("'", "")
        left = "" if left=="-" else left
        digits = cat in ("九宫格","t9") or key.isdigit()
        full = not digits and all(self.full(s) for s in raw.split("'"))
        direct = []
        bounds = tuple(len(s.replace("'","")) for s in (raw[:i] for i,c in enumerate(raw) if c=="'"))
        for _,_,_,entries in self.groups(key,digits,bounds):
            for w,f,_ in entries[:128]:
                prior = (4*model.feature("",left,w) if model else 3*(w in self.d.strong.get(left,())))
                direct.append((math.log1p(f)+prior,w))
        exact = list(dict.fromkeys(w for _,w in sorted(direct,key=lambda p:(-p[0],p[1]))))
        if not digits and "'" not in raw:
            exact = list(dict.fromkeys([w for w, _, _ in self.hot.get(key, ())[:4]] + exact))
        paths = self.paths(raw,digits,left,full,model,weight)
        top = [p[1] for p in paths]
        chat = []
        if not digits and not left and "'" not in raw and 4<=len(key)<=12 and not set(key)&set("aeiouv"):
            def chat_score(p):
                if not model:
                    return p[0]
                words = ("","")+p[2]
                return p[0] + 48 * sum(model.feature(*words[i:i+3]) for i in range(len(p[2])))
            chat_paths = self.chat_paths(key)
            chat = list(dict.fromkeys("".join(p[2]) for p in sorted(chat_paths,key=chat_score,reverse=True)))[:3]
            if model and chat_paths:
                # 保留口语模型自身的优先项，避免通用语料把自然说法全挤出首屏。
                original = list(dict.fromkeys("".join(p[2]) for p in chat_paths))[:2]
                chat = list(dict.fromkeys(chat[:1] + original + chat[1:]))[:3]
        force = (full and paths and len(paths[0][4])>1 and all(len(w)==1 for w in paths[0][4])
                 and exact and len(exact[0])==2 and key not in b.SYL_SET)
        first = exact[:1] if force else []
        if model and chat and paths and len(paths[0][4])==1 and paths[0][5]=="initial":
            first = top[:1]
        if len(key)<=2 and paths and paths[0][5]=="initial":
            top = []
        order = list(dict.fromkeys(first+chat[:1]+top[:1]+exact[:1]+(exact[1:2] if force else [])
                                   +chat[1:]+top[1:]+exact))
        if not digits and "'" not in raw:
            initials = [(math.log1p(f) * (1 + .35 * self.chat_weight.get(wid, 0)), w)
                        for _,_,_,entries in self.d.initials.get(key,[])[:256] for w,f,wid in entries[:8]]
            initials.extend((math.log1p(f)*1.35, w) for w, _, f in self.hot_initials.get(key, ())[:4])
            order.extend(w for _,w in sorted(initials,reverse=True) if w not in order)
        first_edit = ""
        if (correct and not digits and not chat and "'" not in raw and 2<=len(key)<=80 and set(key)&set("aeiouv")
                and (not full or (len(key)<= (18 if model else 12) and not exact))):
            alt = self.paths(raw,False,left,True,model,weight,True)
            if alt and (not paths or alt[0][1]!=paths[0][1]):
                gain = alt[0][0]-paths[0][0] if paths else 100
                mismatch = paths[0][6] if paths else True
                if full:
                    pos = 0 if model and gain>2.5 else 3
                else:
                    pos = 0 if gain>2.5 or (model and mismatch and gain > -1) else 1
                if gain>0 or (not full and mismatch and gain>-4):
                    w = alt[0][1]
                    if pos==0 or w not in order:
                        if w in order:
                            order.remove(w)
                        if pos!=3 or len(order)>=3:
                            order.insert(pos,w)
                            first_edit = w
        if not digits and "'" not in raw and 2<=len(key)<=32:
            english = key if key in self.en else None
            if not english and len(key)>=3:
                i = bisect.bisect_left(self.english,key)
                pool = []
                for w in self.english[i:i+4000]:
                    if not w.startswith(key):
                        break
                    pool.append(w)
                english = max(pool,key=self.en.get,default=None)
            if english:
                idx = 0 if not full and english==key and not exact and (not chat or len(key)>=5) else (2 if full or chat else 1)
                order.insert(idx,english)
        if left and not model:
            common = next((w for w in order if w in exact and w in self.d.strong.get(left,())),None)
            if common:
                order.remove(common)
                order.insert(0,common)
        return order[:5], first_edit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dev",action="store_true")
    parser.add_argument("--tier",default=DEFAULT)
    parser.add_argument("--pages", action="store_true", help="估计三条性能用例访问的文件页")
    args = parser.parse_args()
    engine = Replay()
    if args.dev:
        for tier in TIERS:
            m = Model(SOURCE.parent/(tier+".bin"))
            for weight in (1.5, 3, 5):
                counts = Counter()
                for row in fixtures("long_sentence_dev.tsv"):
                    out,_ = engine.convert(row,m,weight,False)
                    counts["首选"] += out[:1]==[row[3]]
                    counts["前三"] += row[3] in out[:3]
                    counts["逐字"] += sum(a==c for a,c in zip(next(iter(out),""),row[3]))
                print(tier,weight,dict(counts),flush=True)
        return
    model = Model(OUT / "libime_sc.bin" if args.tier == DEFAULT else SOURCE.parent/(args.tier+".bin"))
    if args.pages:
        pages = model.trace_pages()
        for key, correction in (("jintiantianqihenhaowomenyiqichuquwanba", False),
                                ("nixianbashoujiandizhifageiwowojintianxiabanqianjichuqu", False),
                                ("jintiantianqihenhaowomenyiqichuquwamba", True)):
            model.word.cache_clear()
            model.probability.cache_clear()
            pages.clear()
            engine.convert(["", key, "-", "", ""], model, WEIGHT, correction)
            print(key, len(pages), "个 16 KiB 页")
        return
    samples = fixtures("ime_bench.tsv") + [["冻结长句盲集",*row[1:]] for row in fixtures("long_sentence_blind.tsv")]
    baseline = {}
    for name,m in [("改前",None),("改后",model)]:
        interference = [0] * 4
        stats = defaultdict(Counter)
        for row in samples:
            category,raw,left,want,_ = row
            out,edit = engine.convert(row,m,WEIGHT)
            rank = out.index(want)+1 if want in out else 0
            c = stats[category]
            c["样本"]+=1
            c["首选"]+=rank==1
            if m:
                c["修回"] += rank==1 and baseline[tuple(row)]!=1
                c["新错"] += rank!=1 and baseline[tuple(row)]==1
            else:
                baseline[tuple(row)] = rank
            c["第二"]+=rank==2
            c["前三"]+=1<=rank<=3
            c["逐字"]+=sum(a==b_ for a,b_ in zip(next(iter(out),""),want))
            if edit and category in ("全拼词","余串","短句","长句","歧义切分"):
                natural,_ = engine.convert(row,m,WEIGHT,False)
                flags = (out[:1]==[edit], out[1:2]==[edit], out[1:2]==[edit] and natural[1:2]==[want] and rank!=2,
                         want in natural[:3] and want not in out[:3])
                interference = [a+b for a,b in zip(interference, flags)]
                if any(flags):
                    print("干扰",name,raw,want,out,natural)
            if category in ("相邻交换","邻键替换","漏字母","多字母") or raw in ("nzgsm","ncflm","yaoshi","nihaohaoma"):
                print(name,raw,want,out,edit)
        print(name, "正确全拼纠错干扰", interference)
        for cat,c in sorted(stats.items()):
            print(name,cat,dict(c))


WEIGHT = 3
if __name__=="__main__":
    main()

