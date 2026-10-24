"""一次性补丁：修正 tools/dict/README.md 的 §6 结尾与 §7 文件清单，并新增「词库扩展」章节。

跑完即可删除。
"""

from __future__ import annotations

import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
README = os.path.join(ROOT, "tools", "dict", "README.md")

REPLACEMENTS = [
    # 1) 纯汉字 punct 标记那行说明与计数不符（v1.1.0 已全清）
    (
        "| 纯汉字词条带 `punct` 标记 | 0（全角括号颜文字，如「（狗头）」「（比心）」） |",
        "| 纯汉字词条带 `punct` 标记 | 0（v1.0.0 曾有 6 条全角括号颜文字，扩库后这些条目已并入 `chat` 组） |",
    ),
    # 2) 段末结论与下一个标题之间缺空行
    (
        "**抽检结论：30 / 30 拼音正确**。多音字按默认读音，符合契约「多音字取默认读音即可」的要求；已知个例：`音乐`→`yinyue`、`长大`→`zhangda`、`银行`→`yinhang`、`重庆`→`chongqing`（均正确）。符号/emoji 条目的拼音取「联想别名」的全拼（`yuelianglian` → 🌝），打别名词时同时出现符号与汉字。单词音节与 pypinyin 逐条比对：32,900 条纯汉字词条 **0 处不符**（校验脚本见 §5）。\n### 已修复的质量问题（回归记录）",
        "**抽检结论：30 / 30 拼音正确**。多音字按默认读音，符合契约「多音字取默认读音即可」的要求；已知个例：`音乐`→`yinyue`、`长大`→`zhangda`、`银行`→`yinhang`、`重庆`→`chongqing`（均正确）。符号/emoji 条目的拼音取「联想别名」的全拼（`yuelianglian` → 🌝），打别名词时同时出现符号与汉字。逐个音节与 pypinyin 比对：32,900 条纯汉字词条 **0 处不符**。\n\n### 已修复的质量问题（回归记录）",
    ),
    # 3) 文件清单补新增探针与补丁脚本
    (
        "| `_probe_typo.py` | 输入纠错性能探针：用 Python 复刻 `TypoCorrector.swift` 的编辑距离 1 算法，读真实词库测耗时与产出 |",
        "| `_probe_typo.py` | 输入纠错性能探针：用 Python 复刻 `TypoCorrector.swift`（复用 FuzzyPinyin 规则 + 编辑距离 1），读真实词库测耗时与产出，10 条断言 |",
    ),
    (
        "| `_patch_count_assert.py` | 一次性补丁：把 `_simulate_engine.py` 的条数区间断言同步到新规模（30000–50000），不是删断言 |",
        "| `_patch_count_assert.py` | 一次性补丁：把 `_simulate_engine.py` 的条数区间断言同步到新规模（30000–50000），不是删断言 |\n"
        "| `_patch_readme_v11.py` / `_patch_readme_version.py` / `_patch_readme_tools.py` | 一次性补丁：扩库后把两份 README 里的条数/版本号/抽检表同步到 v1.1.0 |",
    ),
]

EXTRA_SECTION = """
## 8. 词库扩展（2026-10-25）

v1.0.0 的 5,276 条只能覆盖「最常用的一小撮词」，`docs/08-AI输入法能力调研报告.md` 的 P0-2
结论是「词库从 5,276 扩到 3–5 万条，是投入产出比最高的一件事」。于是 v1.1.0 做了一次扩库：
**5,276 → 33,160 条（+528%），体积 139,702 → 825,646 字节（806 KB，仍远低于 1.5 MB 上限）**。

### 8.1 筛选规则（为什么这样筛）

扩库**不是**简单地把 jieba 前 N 条全收进来——那样会混进大量生僻字、人名、音译词，
把候选栏变成噪声发生器。最终采用的规则：

| 维度 | 取值 | 为什么 |
| --- | --- | --- |
| 词长 | 1–6 字（实际 99.6% 是 1–4 字） | 拼音输入基本不打 5 字以上的长词 |
| 词频下限 | `JIEBA_MIN_FREQ = 70` | 实测：≥100 只有 26,654 条（不到 3 万）；≥80 有 29,650 条（还是不到）；≥70 有 31,598 条（正好过线）。70–100 段抽样是「车裂/遗恨/遵奉/间冰期」这类可接受的长尾；<60 开始出现明显噪声 |
| 常用字过滤 | 基准词频 `COMMON_CHAR_BASIS_FREQ = 300`、支持度 `COMMON_CHAR_SUPPORT = 2` | 用「在 ≥300 词频的词里至少出现 2 次」反推常用字集合（2,646 字）。**基准从 1000 降到 300 的原因**：freq≥1000 反推的常用字只有 1,157 字，会把「菱花」「羽毛扇」这类完全正常的词误杀。支持度从 3 降到 2 是为了让「菱」「扇」这类只出现在两个常用词里的字也能过 |
| 专名（人名）| `nr/nrt/nrx/nrfg` 需 `freq ≥ 2000` | **关键调参**：初值 3000 会误杀 14 个 v1.0.0 已有常用词——光荣/冷笑/古老/太后/宋江/宫殿/明星/曹操/权威/武林/荣誉/言语/雷达/黄石（jieba 把它们误标成了 `nr`）。扫 3000→2500→2200→2000 时旧词丢失数 14→8→4→0，故定 2000 |
| 地名 | `ns` 需 `freq ≥ 800` | 用户会打地名（`beijing`/`shanghai`），但不需要「郧」这类极低频县名 |
| 机构 | `nt` 需 `freq ≥ 800` | 同上，保留「管理局」「公安局」这类高频机构词 |
| 其他专名 | `nz` 需 `freq ≥ 2000` | 品牌/作品名，只留高频 |
| 单字 | 不看词性全收 | 拼音输入靠单字兜底（`de`→的、`shi`→是），单字一个都不能少 |
| 截断 | `N_JIEBA = 36000` | 实际筛出 31,628 条，未触发截断 |

**为什么不做「按词性白名单只留 n/v/a/d」**：实测 `nz`（专名）、`ns`（地名）、`nt`（机构）
里也有大量用户真会打的词，一刀切会掉召回；改成「按词性设不同词频门槛」既能挡住生僻专名，
又能保住「北京」「淘宝」这类词。

### 8.2 扩库后必须同步修的引擎问题（DP 碎片化）

词库变大后 `_simulate_engine.py` 从 65/65 掉到 63/65，其中一条是**真实的质量退化**：
`woxihuanni` 被切成「我+西湖+啊+嗯+你」而不是「我喜欢你」。

根因：`appendComposedCandidates` 的 DP 最大化 `Σ log(freq+1)`，而单字词频远高于多字词
（「在」727,915 vs「现在」十几万）。v1.0.0 只有 5,276 条时 33k 词库里那些
「西湖」「啊嗯」还没进来，所以看不出来；扩库后它们进来了，DP 就拼出了更"高频"但语义错的路径。

修复：给 DP 加**每词代价** `composedTilePenalty = 14.0`（切 k 块要多付 k×14 分），
取值由 `_probe_dp_penalty.py` 在 20 条长句上扫 0–15 标定——0 时正确率 1/20，14.0 时 16/20。
**Python 复刻（`_simulate_engine.py` 的 `COMPOSED_TILE_PENALTY`）与 Swift 实现必须同值**，
否则候选排序会分叉。详见 `ios/Shared/IMECore/README.md` §3.2。

### 8.3 扩库后的性能（必须在真机确认）

| 指标 | v1.0.0（5,276 条） | v1.1.0（33,160 条） | 说明 |
| --- | --- | --- | --- |
| 文件体积 | 139,702 B | 825,646 B | +591%，仍 < 1.5 MB |
| 逐行解析（Python 上界） | 3.86 ms | 24.05 ms | 6.2× |
| 建索引（Python 上界） | 约 310 ms | 约 2,300 ms | 主要是首字母 DP |
| 首字母 DP 内层循环 | 约 48 万次 | **3,115,290 次** | 按 15–60 ns/次估 **46.7–186.9 ms** |
| 候选生成（Python 上界） | 0.02–0.2 ms | 0.02–0.23 ms | **不受扩库影响**（前缀索引与 DP 都只查相关键） |

⚠️ **结论：扩库不影响按键延迟（候选生成只查命中键），但可能把冷启动加载从 15–25 ms 推到
45–190 ms，逼近甚至超过 docs/08 的 80 ms 预算。** 真机必须读
`PinyinDictionary.loadDurationMilliseconds` 确认；若超标，优先优化
`PinyinSyllables.segment(_:exactly:)`（把三层 `[[[String]?]]` 换成一维 `[Int32]` 切点表）
或把首字母索引改成懒建，**不要靠删词库来降耗时**。详见 `_probe_initials_cost.py`
与 `ios/Shared/IMECore/README.md` §2「加载性能」。

### 8.4 兼容性保证

- **旧词零丢失**：v1.0.0 的 5,276 条全部仍在（`_probe_select.py` 实测 `旧词丢失 []`）；
  旧 1,202 个单字也全部保留（现在共 2,882 个单字）。
- **列格式不变**：仍然 4 列 `拼音<TAB>词<TAB>词频<TAB>flags`，`PinyinDictionary.parse`
  只要求 ≥3 列，无需改解析器。
- **词频降序不变**：`883634 .. 70`，索引按文件顺序建，首候选质量不受影响。
- **断言不删只改**：`_simulate_engine.py` 唯一改动是条数区间断言
  `4000-7000` → `30000-50000`（扩规模必然要改），其余 64 条原样保留且全部通过。
"""


def main() -> int:
    text = io.open(README, encoding="utf-8").read()
    missing = 0
    for old, new in REPLACEMENTS:
        if text.count(old) == 0:
            missing += 1
            print("[miss] %s" % old.strip()[:70])
            continue
        text = text.replace(old, new)
        print("[ok] %s" % old.strip()[:60])
    if "## 8. 词库扩展（2026-10-25）" not in text:
        text = text.rstrip("\n") + "\n" + EXTRA_SECTION
        print("[ok] 追加 §8 词库扩展")
    io.open(README, "w", encoding="utf-8", newline="\n").write(text)
    print("[done] 未命中 %d 处" % missing)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
