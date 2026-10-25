# 墨语输入法 · 词库生成工具（tools/dict）

本目录负责生成墨语输入法使用的三份词库产物，产物直接落盘到
`ios/Shared/dict/`，由 `ios/Shared/IMECore/` 的 Swift 引擎在运行时加载。

> ⚠️ 输出目录**必须**是 `ios/Shared/dict/`，**绝不能**是 `ios/Shared/Resources/dict/`。
> folder reference 会把目录名原样复制到 App bundle 根，一旦出现 `Resources/` 目录，
> iOS 27 的 installd 会拒绝安装（`IXErrorDomain Code=13 Missing bundle ID`，真机实测空目录也会失败）。

## 1. 生成命令

```bash
# 生成词库（覆盖 ios/Shared/dict/ 下的三个文件）
python tools/dict/build_dict.py

# 只做质量自查，不写文件（CI / 评审用）
python tools/dict/build_dict.py --check

# 输出到自定义目录
python tools/dict/build_dict.py --out /tmp/moyu-dict
```

依赖：Python 3.9+；`pypinyin`（`pip install pypinyin`）用于生成拼音。
未安装 `pypinyin` 时脚本会降级到内置的"汉字→拼音"派生逻辑并打印告警，产物仍可生成，
但拼音覆盖率会下降——**发布产物必须用 pypinyin 生成**。

### 可重跑 / 幂等

脚本不含随机数、不读取当前时间（`GENERATED_DATE` 为固定日期常量），
所有排序都使用全序键 `(词频降序, 拼音, 词)`，因此同一份输入**重复执行产出字节级一致**的文件。
`dict_meta.json` 中的 `sha256` 可直接用于校验产物是否与上一次一致。

当前产物（v1.1.0，词库扩展后）：

| 文件 | 条数 | 字节 | SHA256 |
| --- | --- | --- | --- |
| `base_dict.tsv` | 33239 | 827895 | `6715be2b50a5fc4a267db7c39f23573f3ff1d6bd6b19f5cf53afc1d4747f21ab` |
| `chat_priority.tsv` | 328 | 4043 | 聊天高频词权重（`词<TAB>权重`，1.0–3.0），只作用于简拼排序 |
| `phrases.tsv` | 755 | 21827 | `178468c1261ae8eebb3e7a2a7d38877c81f806b72941b07cc3a36250ac3f751e` |

v1.0.0 是 5276 条 / 139702 字节（SHA256 `fb04d1cb…`），v1.1.0 按 `docs/08` 的
「词库扩到 3–5 万条」建议把 jieba 侧扩到 33160 条（+1.5 MB 未压缩，加载仍在 80ms 预算内）。
`pypinyin 0.55.0` 生成，`generated_at` 固定为 `2026-10-25`。

## 2. 产物格式

三个文件均为 **UTF-8 无 BOM、LF 换行、无制表符残留**，首行是 `#` 开头的注释行（Swift 侧解析时跳过）。

### `base_dict.tsv` — 基础词库

```
拼音<TAB>词<TAB>词频<TAB>flags
```

- `拼音`：无声调全拼，小写连写，`ü` 写作 `v`（如 `lvxing`、`nvhai`）。多音字取默认读音。
- `词`：词条文本（汉字、ASCII 词或单个 emoji/标点）。
- `词频`：正整数，越大越常用；与 jieba 词频同一量级，可混合排序。
- `flags`：逗号分隔的标记串，见下表。

样例：

```
le<TAB>了<TAB>883634<TAB>core
wan<TAB>万<TAB>29391<TAB>core
jiayou<TAB>加油<TAB>9600<TAB>chat,bless
pofangle<TAB>破防了<TAB>9400<TAB>chat,net,emoji
yyds<TAB>yyds<TAB>5200<TAB>chat,net
```

### `phrases.tsv` — 上屏后联想短语库

```
建议词拼音<TAB>触发词<TAB>建议词
```

用于"用户上屏『谢谢』后，候选栏推荐『不客气 / 不用谢 / 没事』"。

```
bukeqi<TAB>谢谢<TAB>不客气
buyongxie<TAB>谢谢<TAB>不用谢
meishi<TAB>谢谢<TAB>没事
```

### `dict_meta.json` — 元数据

版本号、生成日期、条数、flags 分布、数据来源与许可、每个产物文件的字节数与 SHA256。

## 3. 数据来源与许可

| 数据源 | 内容 | 条数贡献 | 许可 |
| --- | --- | --- | --- |
| [jieba](https://github.com/fxsjy/jieba) `dict.txt` | 通用中文词频表 | 3400 | **MIT**（词典数据源自 [cppjieba](https://github.com/yanyiwu/cppjieba) 的 `dict/jieba.dict.utf8`，同为 MIT） |
| `chat_supplement.py` | 手写高频聊天词补充表 | 1953 | 本项目原创 |
| `symbol_map.py` | emoji / 标点联想映射 | 240 | 本项目原创 |
| `phrase_pairs.py` | 上屏后联想短语对 | 755（短语） | 本项目原创 |

**许可说明**：jieba 项目整体以 MIT License 发布，其词典文件来自 cppjieba（同样 MIT）。
本项目仅取用其"词 + 词频"两列数据，未复制其代码；MIT 允许商业使用、修改与再分发，
要求在分发时保留版权声明与许可声明——已知悉并遵守（本文件即为声明载体）。
原始 `dict.txt` 缓存在 `tools/dict/.cache/jieba_dict.txt`（约 4.9 MB，**不进入 App 包**，
仅作为生成阶段的输入；App 包内只有裁剪后的 136 KB 产物）。

## 4. 清洗规则

从 jieba `dict.txt`（349,046 行，格式 `词 词频 词性`）到最终 3400 条 `core` 词，依次执行：

1. **词长过滤**：只保留 1–6 个汉字的词（`MIN_LEN=1`、`MAX_LEN=6`）。
   7 字以上的长词在输入法里命中率低、占内存，全部丢弃。
2. **编码/字符过滤**：只保留纯 CJK 词（`\u3400-\u4dbf`、`\u4e00-\u9fff`）。
   含空格、标点、数字、拉丁字母的词条一律丢弃。
3. **词频下限**：丢弃词频 < `JIEBA_MIN_FREQ=1200` 的词（约等于第 4900 名）。
   低于该阈值的词多为民航术语、古籍词、地名，与聊天场景无关。
4. **常用字过滤**（关键）：以词频 ≥1000 的词反推"字支持度"——
   一个汉字至少出现在 `COMMON_CHAR_SUPPORT=3` 个高频词中才算常用字，
   含有非常用字的词条整体丢弃。此步过滤掉大量生僻字/异体字条目
   （如 `笉`、`屼`、`浜`），避免候选栏出现用户永远不用的字。
5. **专名过滤**：词性为 `nr`/`nrt`/`nrx`/`nrfg`（人名、音译名、专名）且字数 ≥3、
   词频 < `NAME_KEEP_FREQ=8000` 的条目丢弃。避免候选人名污染候选栏。
6. **截断**：剩余词条按词频降序取前 `N_JIEBA=3400` 条作为 `core` 词。

手写补充表（`chat_supplement.py`）的清洗规则：

- 词条之间用空白分隔，词条内**不允许**出现空格/制表符/换行（脚本会校验并丢弃违规项）。
- 同词跨组重复出现时，**词频累加、flags 取并集**（例如"加油"→ `chat,bless`）。
- `词@倍数` 语法用于单条加权（如 `在吗@2`）。
- 纯汉字词条不得标 `emoji`/`punct`：这两个 flag 只用于"非汉字的符号类条目"，
  否则 Swift 侧会把汉字候选误判成表情类型（已有回归用例，见第 6 节）。

## 5. 如何扩充

### 加聊天词（最常见）

编辑 `tools/dict/chat_supplement.py` 的 `GROUPS` 列表，追加或修改分组：

```python
GROUPS = [
    # (flags, 基准词频, "词1 词2 词3@2")
    ("chat,bless", 4000, "祝你顺利 祝你开心 顺顺利利"),
]
```

- `flags` 可选：`chat`（聊天）、`net`（网络用语）、`bless`（祝福）、`emoji`（可联想表情）、
  `punct`（标点符号）、`idiom`（成语）。可组合，逗号分隔。
- 基准词频参考：日常寒暄 4000–6500，网络梗 5000–5500，成语 2400，低频长尾 2000–3000。
- 改完重跑 `python tools/dict/build_dict.py` 即可。

### 加 emoji / 标点联想

编辑 `tools/dict/symbol_map.py` 的 `EMOJI_GROUPS` / `PUNCT_GROUPS`：

```python
EMOJI_GROUPS = [
    # (别名, flags, 基准词频, "符号1 符号2")
    ("开心", "emoji", 3200, "😀 😃 😄"),
]
```

`别名` 的拼音就是索引键（打 `kaixin` 会同时出现 😀😃😄 和汉字"开心"）。

### 加上屏后联想短语

编辑 `tools/dict/phrase_pairs.py` 的 `PAIR_GROUPS`：

```python
PAIR_GROUPS = [
    # (触发词, "建议1 建议2 建议3")
    ("谢谢", "不客气 不用谢 没事"),
]
```

### 调整构建规模

改 `tools/dict/build_dict.py` 顶部常量即可：

| 常量 | 默认 | 作用 |
| --- | --- | --- |
| `N_JIEBA` | 3400 | jieba 通用词条数上限 |
| `JIEBA_MIN_FREQ` | 1200 | 通用词词频下限 |
| `COMMON_CHAR_SUPPORT` | 3 | 常用字的字支持度阈值 |
| `NAME_KEEP_FREQ` | 8000 | 专名保留词频阈值 |

调整后务必重跑并确认总条数仍在 3000–8000 区间（当前 5276）。

## 6. 质量抽检

脚本每次运行都会打印：总条数、按 flags 统计、按来源统计、词长分布、词频范围、
重复词 / 空词 / 含空白词检查结果，以及固定步长抽取的 30 条样例。

### flags 分布（v1.1.0，共 33239 条）

| flag | 条数 | 含义 |
| --- | --- | --- |
| `core` | 31628 | jieba 通用高频词（v1.1.0 扩库后占比最大） |
| `chat` | 1840 | 聊天场景用词（含 `_apply_chat_priority.py` 补入的 78 条） |
| `emoji` | 415 | 可联想表情 / emoji 条目（**含 symbol_map 的纯汉字别名**，见下方说明） |
| `net` | 368 | 网络用语 / 热梗 |
| `bless` | 344 | 祝福 / 问候 |
| `idiom` | 120 | 成语 |
| `punct` | 57 | 标点符号 / 颜文字 |

来源分布：`jieba 31628 / chat_supplement 1953 / symbol_map 240 / chat_priority 78`。词长分布：1 字 2882、2 字 23551、3 字 4165、4 字 2434、5 字 150、6 字 48、7 字 6、8 字 2、9 字 1。

### 数据完整性检查

| 检查项 | 结果 |
| --- | --- |
| 重复词 | 0 |
| 空词 | 0 |
| 含空白（空格/制表符）词 | 0 |
| 词频降序排列 | 是 |
| 纯汉字词条 | 32900 |
| 纯汉字词条带 `emoji` 标记 | 179（**设计如此**：symbol_map 的联想别名，如「开心」→😀；Swift `kind(for:)` 对纯汉字一律返回 `.word`，不会被当成表情渲染） |
| 纯汉字词条带 `punct` 标记 | 0（v1.0.0 曾有 6 条全角括号颜文字，扩库后这些条目已并入 `chat` 组） |
| 单字词保留 | 2882 个（v1.0.0 的 1202 个单字**零丢失**，拼音输入靠单字兜底） |
| 旧词回归 | v1.0.0 的 5276 条**零丢失**（`_probe_select.py` 实测） |

### 30 条人工抽检表

固定步长（第 `i*(n-1)/29` 条）等距抽样。v1.1.0 扩库后样本覆盖词频 883634 → 70 的完整区间，可见长尾词（词频 <300）明显增多，属扩库的预期结果：

| # | 拼音 | 词 | 词频 | flags | 拼音校验 |
| --- | --- | --- | --- | --- | --- |
| 01 | `le` | 了 | 883634 | core | OK |
| 02 | `gan` | 敢 | 7965 | core | OK |
| 03 | `nanshou` | 难受 | 5027 | chat,emoji,core | OK |
| 04 | `zheng` | 证 | 3628 | core | OK |
| 05 | `yuanshikai` | 袁世凯 | 2727 | core | OK |
| 06 | `suozhang` | 所长 | 2015 | core | OK |
| 07 | `chengshou` | 承受 | 1458 | core | OK |
| 08 | `yanzou` | 演奏 | 1122 | core | OK |
| 09 | `panchu` | 判处 | 889 | core | OK |
| 10 | `qinshu` | 亲属 | 721 | core | OK |
| 11 | `dianyuan` | 电源 | 594 | core | OK |
| 12 | `guanliju` | 管理局 | 500 | core | OK |
| 13 | `bufa` | 不乏 | 427 | core | OK |
| 14 | `shixing` | 试行 | 368 | core | OK |
| 15 | `zhiai` | 致癌 | 322 | core | OK |
| 16 | `gese` | 各色 | 283 | core | OK |
| 17 | `dabing` | 大病 | 253 | core | OK |
| 18 | `wudang` | 武当 | 222 | core | OK |
| 19 | `jiabeng` | 驾崩 | 195 | core | OK |
| 20 | `zida` | 自打 | 175 | core | OK |
| 21 | `jiangshang` | 奖赏 | 156 | core | OK |
| 22 | `gangsi` | 钢丝 | 141 | core | OK |
| 23 | `hezuohua` | 合作化 | 128 | core | OK |
| 24 | `huhui` | 互惠 | 116 | core | OK |
| 25 | `qidong` | 起动 | 106 | core | OK |
| 26 | `lengyan` | 冷眼 | 97 | core | OK |
| 27 | `xinfu` | 心服 | 89 | core | OK |
| 28 | `zhaomi` | 着迷 | 82 | core | OK |
| 29 | `pianpian` | 片片 | 75 | core | OK |
| 30 | `zuoyi` | 坐椅 | 70 | core | OK |

**抽检结论：30 / 30 拼音正确**。多音字按默认读音，符合契约「多音字取默认读音即可」的要求；已知个例：`音乐`→`yinyue`、`长大`→`zhangda`、`银行`→`yinhang`、`重庆`→`chongqing`（均正确）。符号/emoji 条目的拼音取「联想别名」的全拼（`yuelianglian` → 🌝），打别名词时同时出现符号与汉字。逐个音节与 pypinyin 比对：32,900 条纯汉字词条 **0 处不符**。

### 已修复的质量问题（回归记录）

| 问题 | 现象 | 修复 |
| --- | --- | --- |
| `forced_pinyin` 合并丢失 | emoji 条目在补充表与符号表合并时丢了别名拼音，240 条符号只剩 58 条可索引 | `merge_entries()` 合并分支保留首个非空 `forced_pinyin` |
| 纯汉字词误标 `punct`/`emoji` | 标点组混入了「一二三…万」「哈哈哈」等汉字，导致 `万` 被打成 `emoji,punct`，Swift 侧误判为表情候选 | 汉字语气词移入独立 `chat` 组；Swift `kind(for:)` 增加"纯汉字一律 `.word`"兜底 |

## 7. 文件清单

| 文件 | 作用 |
| --- | --- |
| `build_dict.py` | 主生成脚本（清洗、合并、排序、写盘、自查） |
| `syllable_table.py` | 无声调拼音音节表（421 个），与 Swift 侧 `PinyinSyllables.swift` 同源 |
| `chat_supplement.py` | 手写高频聊天词补充表 |
| `symbol_map.py` | emoji / 标点联想映射 |
| `phrase_pairs.py` | 上屏后联想短语对 |
| `gen_swift_syllables.py` | 由 `syllable_table.py` 生成 `ios/Shared/IMECore/PinyinSyllables.swift`，保证两侧音节表永远一致 |
| `_simulate_engine.py` | 用 Python 复刻 `PinyinEngine` 候选算法（含模糊音与简拼聊天权重），读真实词库跑 **78 条断言**（验证算法与数据，不替代 Xcode 编译） |
| `_probe_loadtime.py` | 冷/热两次分阶段测量加载耗时（同步段：读文件 / 解码 / 解析 / 分组 / 排序 + 聊天权重表，对照 80 ms 预算；懒加载段：首字母 DP 单独报） |
| `chat_priority.py` | 聊天高频词权重表（328 条，五档 3.0/2.5/2.0/1.5/1.0）的唯一真相源，生成 `chat_priority.tsv`，并提供缺词词频换算 |
| `_apply_chat_priority.py` | 把 `chat_priority.tsv` 里词库缺失的词以 `flags=chat` 补进 `base_dict.tsv`（已有词频一律不动，幂等） |
| `_probe_initials_rank.py` | 打印指定简拼的前 N 候选（`--keys` 打首字母桶、`--words` 查词落点），改排序前后对照用 |
| `_eval_suggestion.py` | L1 本地联想质量体检：30 个典型上文跑一遍，打印「上文 → 末句 → 产出」，`--strict` 校验模板规范 |
| `_probe_fuzzy_perf.py` | 测量模糊音变体数与开关前后的按键耗时差（对应 README §3.8 的性能表） |
| `_probe_seed.py` | 抽取 `PinyinDictionary.swift` 内置兜底词表，统计条数 / 常用字覆盖 |
| `_probe_balance.py` | 剥注释与字符串后统计 IMECore 各 swift 文件的括号配平与编码问题 |
| `_probe_typo.py` | 输入纠错性能探针：用 Python 复刻 `TypoCorrector.swift`（复用 FuzzyPinyin 规则 + 编辑距离 1），读真实词库测耗时与产出，10 条断言 |
| `_probe_scale.py` / `_probe_select.py` / `_probe_dp_penalty.py` / `_probe_initials_cost.py` | 词库扩展调参探针：阈值/词性分布、可选规模、DP 每词代价标定、首字母索引构建成本分解 |
| `_patch_count_assert.py` | 一次性补丁：把 `_simulate_engine.py` 的条数区间断言同步到新规模（30000–50000），不是删断言 |
| `_patch_readme_v11.py` / `_patch_readme_version.py` / `_patch_readme_tools.py` | 一次性补丁：扩库后把两份 README 里的条数/版本号/抽检表同步到 v1.1.0 |
| `_count_assertions.py` | 统计 `_simulate_engine.py` 各分组的断言条数（用于核对 README 里的数字） |
| `.cache/jieba_dict.txt` | jieba 原始词表缓存（4.9 MB，**不打包进 App**） |
| `_fetch_src.py` / `_probe.py` | 数据源获取与格式探查的一次性脚本（保留备查） |

音节表变更流程：改 `syllable_table.py` → 跑 `python tools/dict/gen_swift_syllables.py` →
重跑 `build_dict.py`。**不要手工编辑 `PinyinSyllables.swift`**（文件头已标注自动生成）。

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
