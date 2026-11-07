"""纠错调参：给评测句子随机打错一处，看纠错后的整句能不能排第一，打对的和简拼会不会被乱纠。

ios/Shared/IMECore/PinyinEngine.swift 里的纠错（solveCorrected / editedTiles）照这里的做法写，
代价常量（substituteCost 等）要和这里的 P 一致。用法：

    python tools/dict/typo_eval.py              # 默认参数
    python tools/dict/typo_eval.py first=3      # 改参数试

2026-11-07 的结果：182 句打错一处的，100 句纠对排第一、15 句排第二；
225 条打对的句子和简拼里 3 条出了纠错候选，0 条排第一。
"""
import math
import random
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_binary as b  # noqa: E402
from pypinyin import lazy_pinyin, Style  # noqa: E402

FRESH = """
正常使用了|现在输入法已经完全可以正常使用了|我今天不想上班|你明天有空吗|这个问题怎么解决|我们什么时候出发|晚上想吃什么|他说他不来了
你怎么还没睡|我已经到公司了|这个东西太贵了|帮我买一杯咖啡|下午三点开会|你先回去吧|我马上就到了|今天真的好累
你说的很有道理|这件事情不着急|我觉得还可以|有什么需要帮忙的吗|我们一起去吃饭吧|你吃过了吗|我在路上了|等我五分钟
孩子今天发烧了|我想你了|明天早上八点见|这个方案可以吗|老板让我加班|周末一起去爬山吧|你看到我发的消息了吗|不用谢
这家店的东西很好吃|我把文件发给你了|我的手机没电了|你到家了吗|外面下雨了记得带伞|我们下周再聊|这个电影很好看|你想喝什么
""".replace("\n", "|").strip("|").split("|")
INITIALS = """
我吃过了|你在干什么|我不知道|你好吗|我喜欢你|明天见面|我们走了|今天下班了|我在路上了|你吃了吗|没关系|谢谢你|对不起
我要回家|你在哪|明天见|好的|知道了|你说得对|我觉得可以|开始了|睡觉了|吃饭了|早点休息|我在开会|下午开会|等等我|马上到
我到家了|你怎么了|怎么回事|什么时候|不好意思|辛苦了|我想你了|晚安|收到|我先走了|有时间吗|一起吃饭吧|没问题|在吗|好久不见
""".replace("\n", "|").strip("|").split("|")
#: 切分有歧义的（音节边界、零声母、ü）
BOUNDARY = """
我们的方案很好|西安很好玩|祝你平安|档案在哪里|答案是什么|偶尔去一次|他们很恩爱|我饿了|天鹅湖|海鸥飞过|企鹅很可爱|名额满了
晚安|东欧国家|棉袄很暖和|这个提案不错|我爱你|恋爱了|感恩有你|女生宿舍|绿色的衣服|去旅游吧|他是律师|略过这一步|不要虐待动物
战略合作|游戏攻略|省略号|女朋友生气了|这个绿豆汤|旅行的意义|我们一起努力|心爱的人|相爱的人|你帮我一下|能不能帮我一个忙|我想喝奶茶
你今天怎么了|这个价格还可以|快点儿回来|我先挂了|一起看电影|你帮我看看|明天再说吧|我在开车|这个皮包好看|我去拿快递
""".replace("\n", "|").strip("|").split("|")


ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
ADJ = {}
for r, row in enumerate(ROWS):
    for c, ch in enumerate(row):
        n = []
        if c > 0: n.append(row[c - 1])
        if c + 1 < len(row): n.append(row[c + 1])
        for o in (r - 1, r + 1):
            if 0 <= o < 3:
                off = -1 if o > r else 0
                for k in (c + off, c + off + 1):
                    if 0 <= k < len(ROWS[o]): n.append(ROWS[o][k])
        ADJ[ch] = n

class Engine(b.Eval):
    def solve(self, query, previous=None):
        n = len(query)
        best = [-math.inf] * (n + 1)
        back = [None] * (n + 1)
        best[0] = 0.0
        parts = b.segment(query)
        full_pinyin = parts is not None and not any(p in b.UNLIKELY_SINGLE for p in parts)
        for i in range(n):
            if best[i] == -math.inf:
                continue
            prev = back[i][1] if back[i] else previous
            for j in range(i + 1, min(n, i + 24) + 1):
                sub = query[i:j]
                rows = self.by_key.get(sub)
                if not rows:
                    if len(sub) <= 6:
                        penalty = b.SINGLE_INITIAL_PENALTY if len(sub) == 1 else b.INITIALS_PENALTY
                        if full_pinyin:
                            penalty += b.FULL_PINYIN_INITIALS_PENALTY
                        if len(sub) >= 2:
                            penalty += b.INITIALS_VOWEL_PENALTY * sum(c in "aeo" for c in sub)
                        for freq, text, key in self.init.get(sub, [])[:b.INITIAL_TOP_K]:
                            junction = b.JUNCTION_BONUS if prev and prev[-1] + text[0] in self.two_char else 0.0
                            pair = b.BIGRAM_BONUS if prev and text in self.pairs.get(prev, ()) else 0.0
                            score = (math.log(freq + 1) - b.TILE_PENALTY - penalty + junction + pair
                                     + b.INITIALS_LENGTH_BONUS * (len(sub) - 1))
                            if best[i] + score > best[j]:
                                best[j] = best[i] + score
                                back[j] = (i, text, key, score, True)
                    continue
                first = (b.segment(sub) or [sub])[0]
                extra = -20.0 if first in b.UNLIKELY_SINGLE else 0.0
                one = sub in b.SYL_SET
                for text, freq, syl, _ in rows[:8]:
                    pair = b.BIGRAM_BONUS if prev and text in self.pairs.get(prev, ()) else 0.0
                    bonus = 0.0 if one else b.SYLLABLE_BONUS * (syl - 1)
                    score = math.log(freq + 1) - b.TILE_PENALTY + bonus + extra + pair
                    if best[i] + score > best[j]:
                        best[j] = best[i] + score
                        back[j] = (i, text, sub, score, False)
        if back[n] is None:
            return None
        tiles = []
        cur = n
        while cur > 0:
            i, text, key, score, loose = back[cur]
            tiles.append((i, cur, text, score, loose))
            cur = i
        return tiles[::-1]


def typo(query, rng):
    p = rng.randrange(len(query))
    kind = rng.choice(["sub", "sub", "swap", "delete", "insert"])
    if kind == "sub":
        return query[:p] + rng.choice(ADJ[query[p]]) + query[p + 1:], kind
    if kind == "swap" and p + 1 < len(query) and query[p] != query[p + 1]:
        return query[:p] + query[p + 1] + query[p] + query[p + 2:], kind
    if kind == "delete":
        return query[:p] + query[p + 1:], "missing"
    ch = rng.choice(ADJ[query[p]] + [query[p]])
    return query[:p] + ch + query[p:], "extra"



P = dict(sub=5.0, swap=4.0, delete=5.0, insert=5.5, first=2.0, maxlen=12)
INSERTABLE = "aeiouhgn"


def edits(sub, at_end):
    out = {}
    def put(v, c):
        if v != sub and (v not in out or out[v] > c):
            out[v] = c
    for p, ch in enumerate(sub):
        if len(sub) == 1:
            break
        for nb in ADJ.get(ch, []):
            put(sub[:p] + nb + sub[p + 1:], P["sub"])
        if p + 1 < len(sub) and sub[p] != sub[p + 1]:
            put(sub[:p] + sub[p + 1] + sub[p] + sub[p + 2:], P["swap"])
        if len(sub) > 2:
            put(sub[:p] + sub[p + 1:], P["delete"])
    for p in range(1, len(sub) + (0 if at_end else 1)):
        for ch in INSERTABLE:
            put(sub[:p] + ch + sub[p:], P["insert"])
    return out


class DP(Engine):
    def tiles_at(self, query, i, prev, full_pinyin, allow_edit):
        n = len(query)
        res = []  # (j, text, score, loose, edited)
        for j in range(i + 1, min(n, i + 24) + 1):
            sub = query[i:j]
            rows = self.by_key.get(sub)
            if rows:
                one = sub in b.SYL_SET
                first = (b.segment(sub) or [sub])[0]
                extra = -20.0 if first in b.UNLIKELY_SINGLE else 0.0
                for text, freq, syl, _ in rows[:8]:
                    pair = b.BIGRAM_BONUS if prev and text in self.pairs.get(prev, ()) else 0.0
                    bonus = 0.0 if one else b.SYLLABLE_BONUS * (syl - 1)
                    res.append((j, text, math.log(freq + 1) - b.TILE_PENALTY + bonus + extra + pair, False, False))
            elif len(sub) <= 6:
                penalty = b.SINGLE_INITIAL_PENALTY if len(sub) == 1 else b.INITIALS_PENALTY
                if full_pinyin:
                    penalty += b.FULL_PINYIN_INITIALS_PENALTY
                if len(sub) >= 2:
                    penalty += b.INITIALS_VOWEL_PENALTY * sum(c in "aeo" for c in sub)
                for freq, text, key in self.init.get(sub, [])[:b.INITIAL_TOP_K]:
                    junction = b.JUNCTION_BONUS if prev and prev[-1] + text[0] in self.two_char else 0.0
                    pair = b.BIGRAM_BONUS if prev and text in self.pairs.get(prev, ()) else 0.0
                    res.append((j, text, math.log(freq + 1) - b.TILE_PENALTY - penalty + junction + pair
                                + b.INITIALS_LENGTH_BONUS * (len(sub) - 1), True, False))
            if allow_edit and 1 <= len(sub) <= P["maxlen"]:
                for v, cost in edits(sub, j == n).items():
                    rows = self.by_key.get(v)
                    if not rows:
                        continue
                    one = v in b.SYL_SET
                    text, freq, syl, _ = rows[0]
                    pair = b.BIGRAM_BONUS if prev and text in self.pairs.get(prev, ()) else 0.0
                    bonus = 0.0 if one else b.SYLLABLE_BONUS * (syl - 1)
                    res.append((j, text, math.log(freq + 1) - b.TILE_PENALTY + bonus + pair - cost, False, True))
        return res

    def solve2(self, query):
        n = len(query)
        parts = b.segment(query)
        full_pinyin = parts is not None and not any(p in b.UNLIKELY_SINGLE for p in parts)
        best = [[-math.inf] * (n + 1) for _ in range(2)]
        back = [[None] * (n + 1) for _ in range(2)]
        best[0][0] = 0.0
        for i in range(n):
            for layer in (0, 1):
                if best[layer][i] == -math.inf:
                    continue
                prev = back[layer][i][1] if back[layer][i] else None
                for j, text, score, loose, edited in self.tiles_at(query, i, prev, full_pinyin, layer == 0):
                    to = 1 if edited else layer
                    # 纠过的那一层不收简拼块：纠完还有对不上的就不算纠好
                    if to == 1 and loose:
                        continue
                    v = best[layer][i] + score
                    if v > best[to][j]:
                        best[to][j] = v
                        back[to][j] = (i, text, layer)
        def path(layer):
            if back[layer][n] is None:
                return None
            out = []; cur = n; l = layer
            while cur > 0:
                i, text, pl = back[l][cur]
                out.append(text); cur = i; l = pl
            return "".join(reversed(out))
        return path(0), best[0][n], path(1), best[1][n]

    def correct(self, query):
        orig, s0, corr, s1 = self.solve2(query)
        if corr is None or corr == orig:
            return orig, None, False
        if orig is not None and s1 <= s0:
            return orig, None, False
        return orig, corr, orig is None or s1 - s0 > P["first"]


def main():
    for spec in sys.argv[1:]:
        k, v = spec.split("=")
        P[k] = float(v)
    builder = b.collect()
    e = DP(builder)
    full = lambda s: "".join(lazy_pinyin(s))
    ini = lambda s: "".join(p[0] for p in lazy_pinyin(s, style=Style.NORMAL))
    sentences = FRESH + b.UNSEEN + b.HOLDOUT + BOUNDARY
    rng = random.Random(7)
    st = dict(n=0, first=0, second=0, orig_ok=0)
    shown = []
    for s in sentences:
        clean = full(s)
        q, kind = typo(clean, rng)
        if q == clean:
            continue
        st["n"] += 1
        orig, corr, first = e.correct(q)
        if orig == s: st["orig_ok"] += 1
        elif corr == s and first: st["first"] += 1
        elif corr == s: st["second"] += 1
        elif len(shown) < 30: shown.append(f"{q}({kind}) {orig} | {corr}")
    bad_first, bad_any = [], 0
    clean_cases = [(s, full(s)) for s in sentences] + [(s, ini(s)) for s in INITIALS]
    for s, q in clean_cases:
        orig, corr, first = e.correct(q)
        if corr:
            bad_any += 1
            if first: bad_first.append(f"{q}: {orig} -> {corr}")
    print(P, st)
    print(f"打对的/简拼 {len(clean_cases)} 条里被纠：{bad_any}，放第一：{len(bad_first)}", bad_first[:15])
    for line in shown: print("   没纠对：", line)

if __name__ == "__main__":
    main()
