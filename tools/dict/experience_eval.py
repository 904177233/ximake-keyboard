"""在 Windows 上用 Python 复现整句、长句盲集和续词评测。"""
from __future__ import annotations

import hashlib
import math
import struct
import subprocess
from collections import defaultdict

from pypinyin import lazy_pinyin

import build_binary as b

BASELINE = "54723f0712c5bfc757e0e26b901c3ca552e2cabc"
BLIND_SHA = "6a87736e208e0282575fad88d96467da3c7f48f0ddac0d89e3c2ae8c35673b6b"
DEV_SHA = "aa9f7fdf7fcec154d321ce7e0baf73068c121460b350a4748ff10e54942c8a2d"


def resource(name: str, old: bool = False) -> bytes:
    if old:
        return subprocess.check_output(
            ["git", "show", f"{BASELINE}:ios/Shared/dict/{name}"],
            cwd=b.ROOT,
        )
    return (b.OUT_DIR / name).read_bytes()


def fixtures(name: str) -> list[list[str]]:
    data = (b.HERE / name).read_bytes().replace(b"\r\n", b"\n")
    digest = hashlib.sha256(data).hexdigest()
    if name == "long_sentence_blind.tsv":
        assert digest == BLIND_SHA, f"blind set changed: {digest}"
    if name == "long_sentence_dev.tsv":
        assert digest == DEV_SHA, f"dev set changed: {digest}"
    return [
        line.split("\t")
        for line in data.decode("utf-8").splitlines()
        if line and not line.startswith("#")
    ]


def split_keys(data: bytes):
    (
        magic,
        version,
        entry_count,
        key_count,
        off_keys,
        off_entries,
        off_t9,
        off_init,
        off_t9_init,
        off_blob,
        t9_count,
        init_count,
        t9_init_count,
    ) = struct.unpack_from("<4s12I", data)
    assert magic == b"MYD3" and version == 1
    assert entry_count >= 0 and key_count >= 0
    assert off_keys >= 64 and off_entries >= off_keys
    assert off_t9 >= off_entries and off_init >= off_t9
    assert off_t9_init >= off_init and off_blob >= off_t9_init
    assert t9_count >= 0 and init_count >= 0 and t9_init_count >= 0

    for i in range(key_count):
        off, first, freq, mask, count, length, syllables = struct.unpack_from(
            "<IIIIHBB", data, off_keys + i * 20
        )
        key = data[off_blob + off:off_blob + off + length].decode("utf-8")
        words = []
        for j in range(count):
            word_id, weight, size, flags, _reserved = struct.unpack_from(
                "<IIBBH", data, off_entries + (first + j) * 12
            )
            if not flags & 11:
                word = data[off_blob + word_id:off_blob + word_id + size].decode("utf-8")
                words.append((word, weight, word_id))
        if words:
            yield key, mask, freq, words


class Decoder:
    def __init__(self, old: bool = False):
        self.old = old
        self.exact = defaultdict(list)
        self.initials = defaultdict(list)
        self.digits = defaultdict(list)
        self.di = defaultdict(list)
        self.ids = {}
        self.freq = {}
        self.strong = {}
        self.cols = [dict() for _ in range(6)]

        for line in resource("next.tsv", old).decode("utf-8").splitlines():
            head, *fields = line.split("\t")
            fields += [""] * max(0, 6 - len(fields))
            self.strong[head] = set((fields[0] + " " + fields[3]).split())
            for table, column in zip(self.cols, fields):
                if column:
                    table[head] = column.split()

        for key, mask, freq, words in split_keys(resource("moyu.dict", old)):
            syllables = b.split_by_mask(key, mask)
            group = (freq, key, syllables, words)
            self.exact[key].append(group)
            self.digits[b.to_t9(key)].append(group)
            initials = b.initials_of(key, mask)
            if initials:
                self.initials[initials].append(group)
                if len(initials) > 1:
                    self.di[b.to_t9(initials)].append(group)
            for word, weight, word_id in words:
                self.ids[word] = word_id
                self.freq[word] = max(self.freq.get(word, 0), weight)

        for table in (self.digits, self.initials, self.di):
            for groups in table.values():
                groups.sort(key=lambda group: -group[0])

    def decode(
        self,
        query: str,
        mode: str = "qwerty",
        left: str = "",
        width: int = 1,
        model=None,
        weight: float = 0,
    ) -> list[str]:
        digits = mode == "t9"
        n = len(query)
        parts = b.segment(query) if not digits else None
        full = bool(parts) and not b.UNLIKELY_SINGLE.intersection(parts)
        states = [[] for _ in range(n + 1)]
        states[0] = [(0.0, "", left, "")]

        for start in range(n):
            bucket = states[start]
            best = {}
            for state in sorted(bucket, key=lambda state: -state[0]):
                best.setdefault(state[2], state)
                if len(best) >= width:
                    break
            if not best:
                continue

            for end in range(start + 1, min(start + 24, n) + 1):
                sub = query[start:end]
                if digits:
                    exact = self.digits.get(sub, ())
                    exact = [
                        group for group in exact
                        if group[2][0] not in b.UNLIKELY_SINGLE
                    ][:1 if self.old else 48]
                else:
                    exact = self.exact.get(sub, ())

                transitions = []
                for _, key, syllables, entries in exact:
                    bonus = 2 * (len(syllables) - 1) if digits or key not in b.SYL_SET else 0
                    penalty = 20 if syllables[0] in b.UNLIKELY_SINGLE else 0
                    particle = b.ENDING_PARTICLES.get(key) if start and end == n else None
                    for index, (word, frequency, _) in enumerate(entries):
                        ending = not self.old and particle == word
                        if index < (8 if self.old else b.DP_EXACT_ENTRY_LIMIT) or ending:
                            score = math.log1p(frequency) - 14 + bonus - penalty
                            transitions.append((word, score, key, ending))

                if len(sub) <= 6 and (
                    (digits and len(sub) >= 2)
                    or (not digits and not exact)
                ):
                    penalty = (
                        4 if digits else
                        (10 if len(sub) == 1 else 3)
                        + (6 if full else 0)
                        + (4 * sum(c in "aeo" for c in sub) if len(sub) > 1 else 0)
                    )
                    initial_groups = (
                        self.di if digits else self.initials
                    ).get(sub, ())
                    group_limit = 3 if digits else b.DP_INITIAL_KEY_LIMIT
                    entry_limit = 1 if digits else b.DP_INITIAL_ENTRY_LIMIT
                    for frequency, key, _syllables, entries in initial_groups[:group_limit]:
                        for word, entry_frequency, _ in entries[:entry_limit]:
                            transitions.append(
                                (
                                    word,
                                    math.log1p(entry_frequency) - 14 - penalty
                                    + 3 * (len(sub) - 1),
                                    key,
                                    None,
                                )
                            )

                for total, text, previous, _ in best.values():
                    for word, score, key, ending in transitions:
                        if ending:
                            best_score = max(
                                value + (3 if candidate in self.strong.get(previous, ()) else 0)
                                for candidate, value, _, ending_value in transitions
                                if ending_value is not None
                            )
                            score = min(best_score + 0.001, score + 8)
                        loose = ending is None
                        pair = 3 if not ending and word in self.strong.get(previous, ()) else 0
                        if (
                            loose
                            and previous
                            and self.freq.get(previous[-1] + word[0], 0) >= 200
                        ):
                            pair += 2
                        if weight and previous and model is not None:
                            pair += weight * model(
                                self.ids.get(previous, -1),
                                self.ids.get(word, -1),
                            )
                        result = word
                        if self.old and start and end == n:
                            result = b.ENDING_PARTICLES.get(key, word)
                        states[end].append(
                            (total + score + pair, text + result, word, key)
                        )

        ranked = sorted(states[n], key=lambda state: -state[0])
        return list(dict.fromkeys(state[1] for state in ranked))[:3 if width > 1 else 1]


def replay(rows, decoder: Decoder, multi: bool = False, model=None, weight: float = 0):
    outputs = []
    for mode, query, left, _want, _whole in rows:
        context = "" if decoder.old else left
        primary = decoder.decode(query, mode, context)
        if multi:
            extra = decoder.decode(query, mode, context, 4, model, weight)
            primary = (
                extra
                if weight
                else list(dict.fromkeys(primary + extra))[:3]
            )
        outputs.append([context + word for word in primary])
    return outputs


def summary(rows, output, reference=None) -> dict[str, int]:
    top1 = top3 = chars = total = fixed = regressed = 0
    for index, ((_, _, _, _want, goal), words) in enumerate(zip(rows, output)):
        first = next(iter(words), "")
        top1 += first == goal
        top3 += goal in words[:3]
        chars += sum(a == b for a, b in zip(first, goal))
        total += len(goal)
        if reference is not None:
            was = next(iter(reference[index]), "") == goal
            fixed += not was and first == goal
            regressed += was and first != goal
    return {
        "n": len(rows),
        "top1": top1,
        "top3": top3,
        "chars": chars,
        "total": total,
        "fixed": fixed,
        "regressed": regressed,
    }


def short_rows(sentences: list[str]):
    return [("qwerty", "".join(lazy_pinyin(sentence)), "", sentence, sentence) for sentence in sentences]


def segmented(text: str, frequency: dict[str, int]) -> list[str]:
    best = [None] * (len(text) + 1)
    best[0] = (0.0, [])
    for start in range(len(text)):
        if best[start] is None:
            continue
        for end in range(start + 1, min(start + 6, len(text)) + 1):
            word = text[start:end]
            value = frequency.get(word)
            if value is None:
                continue
            score = best[start][0] + math.log1p(value) - 12
            if best[end] is None or score > best[end][0]:
                best[end] = (score, best[start][1] + [word])
    return best[-1][1] if best[-1] else []


def predictions(decoder: Decoder, text: str, last: str, phrases: dict[str, list[str]]):
    def lookup(table, anchor: str, minimum: int = 1):
        for size in range(min(4, len(anchor)), minimum - 1, -1):
            if anchor[-size:] in table:
                return table[anchor[-size:]]
        return []

    scores = {}

    def add(words, score: float):
        for word in words:
            if word != text:
                scores[word] = max(score, scores.get(word, -100.0))

    question = text[-1] in "\u5417\u5462\u4e48\u561b\u5565\u8c01\u54ea\u51e0"
    exclaim = text[-1] in "\u554a\u54c7\u5566\u54c7\u54c8\u563f\u54ce"
    if len(text) >= 3 and (question or exclaim or len(text) >= 4):
        if question:
            add(["\uff1f"], 10 if decoder.old else 10.0)
        elif exclaim:
            add(["\uff01"], 10 if decoder.old else 1.8)
        else:
            add(["\uff0c"], 10 if decoder.old else 5.0)
        add(["\u3002"], 10 if decoder.old else (1.1 if question else 1.0 if exclaim else 0.45))

    anchor = text if decoder.old else last
    add(lookup(decoder.cols[0], anchor), 3.2)
    if decoder.old:
        for size in range(1, len(text) + 1):
            if text[-size:] in phrases:
                add(phrases[text[-size:]], 2.8)
                break
    follows = lookup(decoder.cols[2], anchor)
    if not decoder.old:
        for word, token in zip(follows, lookup(decoder.cols[4], anchor)):
            if token.startswith("t"):
                add([word], 0.85 + min(1.5, 0.25 * math.log1p(int(token[1:]))))
    add(follows, 1.0)
    add(
        lookup(decoder.cols[1], text, 1 if len(text) < 3 else 2),
        0.8 if decoder.old else (1.0 if len(text) <= 2 else 1.25),
    )
    return sorted(scores, key=scores.get, reverse=True)


def main():
    old = Decoder(True)
    new = Decoder()
    for title, rows in [
        ("调频组", short_rows(b.SENTENCES)),
        ("HOLDOUT", short_rows(b.HOLDOUT)),
        ("UNSEEN", short_rows(b.UNSEEN)),
        ("长句盲集", fixtures("long_sentence_blind.tsv")),
    ]:
        prior = replay(rows, old)
        now = replay(rows, new, True)
        print(title, summary(rows, prior), summary(rows, now, prior))

    phrases = defaultdict(list)
    for line in resource("phrases.tsv").decode("utf-8").splitlines():
        if line and not line.startswith("#"):
            _, trigger, word = line.split("\t")
            phrases[trigger].append(word)

    counts = [[0, 0], [0, 0]]
    n = 0
    for sentence in b.HOLDOUT + b.UNSEEN:
        words = segmented(sentence, old.freq)
        for pos in range(1, len(words)):
            n += 1
            for index, decoder in enumerate((old, new)):
                for column, text in enumerate((words[pos - 1], "".join(words[:pos]))):
                    counts[index][column] += (
                        words[pos] in predictions(decoder, text, words[pos - 1], phrases)[:3]
                    )
    print("续词前三", n, counts)


if __name__ == "__main__":
    main()
