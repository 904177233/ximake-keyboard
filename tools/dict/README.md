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
| `base_dict.tsv` | 33160 | 825646 | `4eb3333c95b72e2a63da7856eba66eacef8ee1839a40b4c4ad6da759dda302ab` |
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

### flags 分布（v1.0.0，共 5276 条）

| flag | 条数 | 含义 |
| --- | --- | --- |
| `core` | 3400 | jieba 通用高频词 |
| `chat` | 1761 | 聊天场景用词 |
| `emoji` | 415 | 可联想表情 / emoji 条目 |
| `net` | 368 | 网络用语 / 热梗 |
| `bless` | 344 | 祝福 / 问候 |
| `idiom` | 120 | 成语 |
| `punct` | 57 | 标点符号 |

来源分布：`jieba 3400 / chat_supplement 1953 / symbol_map 240`。
词长分布：1 字 1202、2 字 2873、3 字 560、4 字 520、5 字 80、6 字 32、7 字 6、8 字 2、9 字 1。

### 数据完整性检查

| 检查项 | 结果 |
| --- | --- |
| 重复词 | 0 |
| 空词 | 0 |
| 含空白（空格/制表符）词 | 0 |
| 词频降序排列 | 是 |
| 纯汉字词条拼音与 pypinyin 逐条比对 | 5016 / 5016 全部一致（0 处不符） |
| 纯汉字词条误标 `emoji`/`punct` | 0（曾发现 24 条并已修复，见 4.6） |

### 30 条人工抽检表

固定步长（第 `i*(n-1)/29` 条）等距抽样，覆盖首/中/尾三段的通用词、聊天词与符号条目：

| # | 拼音 | 词 | 词频 | flags | 拼音校验 |
| --- | --- | --- | --- | --- | --- |
| 01 | `le` | 了 | 883634 | core | OK |
| 02 | `xiang` | 像 | 31874 | core | OK |
| 03 | `diyi` | 第一 | 19725 | chat,core | OK |
| 04 | `jiegou` | 结构 | 14200 | core | OK |
| 05 | `qin` | 亲 | 10670 | core | OK |
| 06 | `zhaokai` | 召开 | 9138 | core | OK |
| 07 | `mianqian` | 面前 | 7896 | core | OK |
| 08 | `disan` | 第三 | 6818 | chat,core | OK |
| 09 | `bude` | 不得 | 6248 | core | OK |
| 10 | `haoda` | 好哒 | 5600 | chat,bless | OK |
| 11 | `bucuo` | 不错 | 5322 | core | OK |
| 12 | `taishangtoule` | 太上头了 | 5200 | chat,net | OK |
| 13 | `liangce` | 两侧 | 4863 | core | OK |
| 14 | `xiexieha` | 谢谢哈 | 4600 | chat,bless | OK |
| 15 | `ele` | 饿了 | 4200 | chat,emoji | OK |
| 16 | `zuizao` | 最早 | 4124 | core | OK |
| 17 | `heshang` | 和尚 | 3959 | core | OK |
| 18 | `hai` | 害 | 3654 | core | OK |
| 19 | `zhishang` | 之上 | 3503 | core | OK |
| 20 | `zichan` | 资产 | 3243 | core | OK |
| 21 | `xiaoqu` | 小区 | 3200 | chat | OK |
| 22 | `annidelai` | 按你的来 | 3000 | chat | OK |
| 23 | `qianlai` | 前来 | 2917 | core | OK |
| 24 | `jinghao` | # | 2700 | emoji,punct | OK（符号条目，拼音取别名） |
| 25 | `zhuixing` | 追星 | 2600 | chat,net | OK |
| 26 | `houhuiyouqi` | 后会有期 | 2400 | chat,idiom | OK |
| 27 | `shengyujiazhi` | 剩余价值 | 2306 | core | OK |
| 28 | `yiqichifanba` | 一起吃饭吧 | 2200 | chat | OK |
| 29 | `chuangshang` | 床上 | 2057 | core | OK |
| 30 | `yuelianglian` | 🌝 | 300 | emoji | OK（emoji 条目，拼音取别名） |

**抽检结论：30 / 30 通过**。多音字按默认读音，符合契约"多音字取默认读音即可"的要求；
已知个例：`音乐`→`yinyue`（正）、`长大`→`zhangda`（正）、`银行`→`yinhang`（正）、
`重庆`→`chongqing`（正）。符号/emoji 条目的拼音取「联想别名」的全拼
（`yuelianglian` → 🌝），打别名词时同时出现符号与汉字。

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
| `_simulate_engine.py` | 用 Python 复刻 `PinyinEngine` 候选算法（含模糊音），读真实词库跑 **65 条断言**（验证算法与数据，不替代 Xcode 编译） |
| `_probe_loadtime.py` | 分阶段测量词库加载耗时（读文件 / 解码 / 解析 / 分组 / 排序 / 首字母 DP），给出 Python 上界估算 |
| `_probe_fuzzy_perf.py` | 测量模糊音变体数与开关前后的按键耗时差（对应 README §3.8 的性能表） |
| `_probe_seed.py` | 抽取 `PinyinDictionary.swift` 内置兜底词表，统计条数 / 常用字覆盖 |
| `_probe_balance.py` | 剥注释与字符串后统计 IMECore 各 swift 文件的括号配平与编码问题 |
| `_probe_typo.py` | 输入纠错性能探针：用 Python 复刻 `TypoCorrector.swift` 的编辑距离 1 算法，读真实词库测耗时与产出 |
| `_probe_scale.py` / `_probe_select.py` / `_probe_dp_penalty.py` / `_probe_initials_cost.py` | 词库扩展调参探针：阈值/词性分布、可选规模、DP 每词代价标定、首字母索引构建成本分解 |
| `_patch_count_assert.py` | 一次性补丁：把 `_simulate_engine.py` 的条数区间断言同步到新规模（30000–50000），不是删断言 |
| `_count_assertions.py` | 统计 `_simulate_engine.py` 各分组的断言条数（用于核对 README 里的数字） |
| `.cache/jieba_dict.txt` | jieba 原始词表缓存（4.9 MB，**不打包进 App**） |
| `_fetch_src.py` / `_probe.py` | 数据源获取与格式探查的一次性脚本（保留备查） |

音节表变更流程：改 `syllable_table.py` → 跑 `python tools/dict/gen_swift_syllables.py` →
重跑 `build_dict.py`。**不要手工编辑 `PinyinSyllables.swift`**（文件头已标注自动生成）。
