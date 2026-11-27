"""比较三个真实 Swift 引擎导出的逐条结果。0 代表没有完整消费输入的目标候选。"""
import json
import sys
from collections import Counter
from pathlib import Path


def compare(paths):
    versions = [json.loads(Path(p).read_text(encoding="utf-8")) for p in paths]
    def identity(r):
        return r["category"], r["input"], r["left"], r["expected"]
    keys = [identity(r) for r in versions[0]]
    counts = Counter(k[0] for k in keys)
    if (len(keys) - counts["冻结长句盲集"] < 300 or counts["简拼整句"] < 60
            or counts["中文模式英文词"] < 30 or counts["冻结长句盲集"] != 27):
        raise ValueError("评测集类别或样本数不完整")
    if any([identity(r) for r in rows] != keys for rows in versions):
        raise ValueError("三版输入或顺序不一致")
    errors = []
    protected = {"全拼词", "短句", "长句", "歧义切分", "余串"}
    edits = {"邻键替换", "漏字母", "多字母", "相邻交换"}
    for name in sorted({k[0] for k in keys} | {"正确全拼合计"}):
        group = [[r for r in rows if r["category"] == name or
                  (name == "正确全拼合计" and r["category"] in protected)] for rows in versions]
        def metrics(rows):
            ranks = Counter(r["rank"] for r in rows)
            return ranks[1], ranks[2], ranks[1] + ranks[2] + ranks[3]
        metrics3 = [metrics(rows) for rows in group]
        print(name, "样本", len(group[0]), "3.0.10 / build 84 / 工作区（首选、第二、前三）", *metrics3)
        for label, base in zip(["3.0.10", "build 84"], group[:2]):
            fixed = [r for r, old in zip(group[2], base) if r["rank"] == 1 and old["rank"] != 1]
            lost = [r for r, old in zip(group[2], base) if r["rank"] != 1 and old["rank"] == 1]
            print("  对", label, "修回", len(fixed), "新增错误", len(lost))
            for r in lost[:15]:
                print("    退步", r["input"], r["expected"], r["top"])
        if name == "冻结长句盲集":
            for rows in group:
                total = sum(len(r["expected"]) for r in rows)
                correct = sum(sum(a == b for a, b in zip(r["expected"], next(iter(r["top"]), ""))) for r in rows)
                print("  余串及整句逐字同位置命中", correct, "/", total)
        if name == "简拼整句":
            from_second = sum(old["rank"] == 2 and new["rank"] == 1 for old, new in zip(group[1], group[2]))
            print("  build 84 的第二名升至首选", from_second)
            if metrics3[2][0] < metrics3[1][0] + 2:
                errors.append("71 条聊天简拼首选净改善不足两条")
        if name in edits:
            for rows in group:
                print("  标为纠错且命中 首选/前三", sum(r["correctedAtTarget"] and r["rank"] == 1 for r in rows),
                      sum(r["correctedAtTarget"] and 1 <= r["rank"] <= 3 for r in rows), "/", len(rows))
        if name == "正确全拼合计":
            for rows in group:
                first = sum(r["kinds"][:1] == ["corrected"] for r in rows)
                second = sum(r["kinds"][1:2] == ["corrected"] for r in rows)
                displaced = sum(r["kinds"][1:2] == ["corrected"] and r["naturalRank"] == 2
                                and r["rank"] != 2 for r in rows)
                lost3 = sum(1 <= r["naturalRank"] <= 3 and not 1 <= r["rank"] <= 3 for r in rows)
                print("  开/关纠错：抢首选、占第二、挤掉自然第二目标、目标跌出前三", first, second, displaced, lost3, "/", len(rows))
                if rows is group[-1] and any((first, second, displaced, lost3)):
                    errors.append("正确全拼受到纠错干扰")
        if metrics3[2][0] < metrics3[1][0]:
            errors.append(name + "首选低于 build 84")
        if name in {"正确全拼合计", "简拼整句", "中文模式英文词", "冻结长句盲集"}:
            if metrics3[2][2] < metrics3[1][2]:
                errors.append(name + "前三低于 build 84")
    if errors:
        raise SystemExit("评测未通过：" + "、".join(errors))


if __name__ == "__main__":
    compare(sys.argv[1:])
