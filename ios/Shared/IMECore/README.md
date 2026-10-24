# 墨语输入法 · 输入法内核（ios/Shared/IMECore）

纯 Swift 5 / Foundation，无 UI 依赖（不 import UIKit / SwiftUI），最低支持 iOS 16.0。
把"按键串 → 候选词"的全部逻辑收敛在本模块内，UI 只负责展示与上屏。

## 1. 文件职责

| 文件 | 职责 | 行数 |
| --- | --- | --- |
| `IMECandidate.swift` | 契约 §4.6 的公共数据结构：`IMECandidate`、`DictionaryEntry` | 96 |
| `PinyinSyllables.swift` | 无声调音节表（421 个音节）+ 音节切分 DP（**自动生成，勿手工编辑**） | 170 |
| `PinyinDictionary.swift` | 加载 `base_dict.tsv`，建全拼哈希索引与首字母简拼索引 | 576 |
| `PinyinEngine.swift` | 输入串 → 候选：全拼/简拼/混拼/组合切分/前缀预测/模糊音兜底/英文直通 + 排序 | 594 |
| `FuzzyPinyin.swift` | 模糊音（§3.8）：9 条规则、变体展开 `variants`/`expand`、词库命中 `matches`、设置单例 `FuzzyPinyinSettings` | 514 |
| `UserLearningStore.swift` | 选词计频、最近使用环形缓冲（200 条）、自造词，经 `SharedStore` 持久化 | 279 |
| `PhraseSuggestion.swift` | 加载 `phrases.tsv`，实现"上屏后联想" | 188 |
| `PhraseLibrary.swift` | 用户短语库 `PhraseItem`/`PhraseLibrary`（占位符展开）+ `ClipboardHistory` | 341 |
| `ContextualSuggestion.swift` | 上下文联想（§9）：`ContextualSuggestion` 数据模型、`AISuggestionPolicy` 参数、L1 `LocalSuggestionIndex` | 460 |
| `AISuggestionPrompt.swift` | 上下文联想 L2：prompt 构造 `userMessage`/`systemPrompt` + 模型返回文本解析 `parse` | 258 |
| `ContextualSeedTemplates.swift` | L1 的内置触发词模板（81 组规则、169 条候选短句） | 130 |
| `IMEKit.swift` | 门面：一次性组装上述组件 + 词库来源诊断（`dictionarySource` / `diagnosticsSummary`）+ 模糊音开关（`fuzzyPinyin` / `fuzzyDiagnosticsSummary`），供 UI 层使用 | 230 |

依赖方向（单向，无环）：
```
IMEKit
  ├─ PinyinDictionary ── PinyinSyllables
  ├─ UserLearningStore ── SharedStore（Storage 层，仅用 4 个读写方法）
  ├─ PinyinEngine ── PinyinDictionary + UserLearningStore + PhraseSuggestion + FuzzyPinyin
  ├─ PhraseLibrary ── SharedStore
  ├─ ClipboardHistory ── SharedStore
  ├─ LocalSuggestionIndex ── SharedStore + ContextualSeedTemplates
  └─ FuzzyPinyinSettings ── SharedStore（模糊音开关，进程内单例）
AISuggestionPrompt ── ContextualSuggestion（纯函数，无状态、无网络）
```

## 2. 词库加载（`PinyinDictionary`）

### 打包路径兼容

`base_dict.tsv` 位于 `ios/Shared/dict/`，以 **folder reference** 形式加入 target 时，
Bundle 内的相对路径会随 Xcode 的 resources 配置变化。因此加载器按候选列表逐个尝试：

1. `Bundle.main.url(forResource: "base_dict", withExtension: "tsv", subdirectory: "Resources/dict")`（旧布局，仅为兼容保留）
2. `Bundle.main.url(forResource: "base_dict", withExtension: "tsv", subdirectory: "dict")`（**当前布局**）
3. `Bundle.main.url(forResource: "base_dict", withExtension: "tsv")`
4. 以上三条同样对 `Bundle(for: PinyinDictionary.self)` 再试一遍（覆盖 SwiftPM / 静态库场景）
5. 兜底：把 `Bundle.main.resourceURL` 拼成 `Resources/dict/base_dict.tsv`、`dict/base_dict.tsv`、`base_dict.tsv`
   做文件存在性检查（处理 folder reference 未拍平的情况）

也支持直接注入 URL，便于单测与调试：

```swift
let dict = PinyinDictionary(dictionaryURL: URL(fileURLWithPath: "/tmp/base_dict.tsv"))
let dict2 = PinyinDictionary(entries: [DictionaryEntry(pinyin: "zg", text: "中国", frequency: 9, flags: "core")])
```

三个候选路径全部失败时退回 **60 条内置词表**（`version = "0.0.0-builtin"`、`loadedPath = "<builtin>"`），
键盘不崩溃、仍可打常用字——对应 §7 验收闸门的"词库缺失降级路径"。

### 索引结构

| 索引 | 类型 | 构建 | 查询 |
| --- | --- | --- | --- |
| 全拼哈希 | `[String: [DictionaryEntry]]` | O(n) 分组 | O(1) |
| 有序全拼键 | `[String]` | O(k log k)，k = 唯一全拼数 | 二分 O(log k) + 扫描 O(命中数) |
| 首字母索引 | `[String: [String]]` | O(n) | O(1) |
| 文本词频 | `[String: Int]` | O(n) | O(1) |

- `lookup(pinyin:limit:)`：**精确优先**；无精确命中时退化为前缀合并（按词频重排）。
- `exactEntries(pinyin:limit:)`：只做精确匹配，供引擎区分"整串是词"和"整串是前缀"。
- `pinyinKeys(prefix:limit:)`：二分定位 + 顺序扫描，结果按"该全拼的最高词频"降序（**不是**字典序，
  否则 `zhong*` 会按字母序把生僻词排前面）。
- `pinyinKeys(initials:limit:)`：简拼查询，`zg` → `zhongguo`/`zhège`…
- `hasPrefix(_:)` / `hasInitials(_:)`：供引擎提前剪枝、UI 判断"还有候选"。

**首字母是怎么来的**：词库只存全拼，首字母串在加载时用音节切分反推——
`PinyinSyllables.segment(pinyin, exactly: text.count)` 要求"音节数恰好等于汉字数"
（词库拼音是逐字生成的，这个约束恒成立），再取每个音节首字母。
这比 `text.count` 直接切片更准：`xian` 可能被切成 `xi+an`（2 字）或 `xian`（1 字），
只有与词条字数对齐的那一种才是对的。

### 加载性能

5276 条、136 KB 的实测耗时预估：

| 阶段 | 估算 |
| --- | --- |
| 定位 Bundle 文件（最坏 8 条候选路径，命中即返回） | < 0.5 ms |
| 逐行解析（5.3k 行，`components(separatedBy:)`） | 8–15 ms |
| 建全拼哈希 + 排序键（5.3k 条） | 2–4 ms |
| 建首字母索引（含 per-key 音节切分） | 3–6 ms |
| **合计** | **约 15–25 ms（预算 80 ms，余量 ≥3×）** |

内存：`DictionaryEntry` 约 72 B（两个 String 引用 + Int + String），5.3k 条 ≈ 0.4 MB；
加上索引字典与首字母键 ≈ **1.2–1.8 MB**。相对 60 MB 的扩展内存上限可忽略。
（引用类型字符串是常量对象，实际分配可能略高于此估算。）

### 简单用法

```swift
let dict = PinyinDictionary.bundled()
print(dict.version, dict.wordCount)                 // "1.0.0" 5276
print(dict.lookup(pinyin: "zg", limit: 5))          // 无精确命中 → zhongguo… 前缀结果
print(dict.pinyinKeys(initials: "zg", limit: 5))    // ["zhongguo", "zhege", ...]
print(dict.hasPrefix("zhongg"))                     // true
```

### 词库数据来源与重新生成

`ios/Shared/Resources/dict/` 下的三个文件**全部由脚本生成，不要手改**：

| 文件 | 条数 | 说明 |
| --- | --- | --- |
| `base_dict.tsv` | 5276 | 基础词库，列：`拼音<TAB>词<TAB>词频<TAB>flags`，按词频降序 |
| `phrases.tsv` | 755 | 上屏后联想，列：`建议词拼音<TAB>触发词<TAB>建议词` |
| `dict_meta.json` | — | `version = 1.0.0`、条数、flags 分布、数据来源与许可、每个文件的 SHA256 |

数据来源（详见 `tools/dict/README.md`）：

1. **jieba 词典**（MIT 协议，数据源自 cppjieba 的 `dict/jieba.dict.utf8`）——经词长/词频/常用字/专名四层清洗后取前 3400 条；
2. `tools/dict/chat_supplement.py` —— 本项目手写的高频聊天补充表（问候、感谢、情绪、网络梗、祝福、成语等）；
3. `tools/dict/symbol_map.py` —— emoji / 标点联想别名表；
4. `tools/dict/phrase_pairs.py` —— 触发词 → 建议词对，生成 `phrases.tsv`。

重新生成（幂等，无需网络；`jieba` 词表已缓存在 `tools/dict/.cache/jieba_dict.txt`）：

```bash
python tools/dict/build_dict.py           # 重新生成三个产物
python tools/dict/build_dict.py --check   # 只做质量自查，不写文件
python tools/dict/_simulate_engine.py     # 用 Python 复刻 Swift 算法跑断言（39 条）
python tools/dict/gen_swift_syllables.py  # 音节表变更后重生成 PinyinSyllables.swift
```

幂等性由三件事保证：无随机数、`GENERATED_DATE` 写死为固定日期（不取 `now`）、所有排序键都是全序
（词频降序 → 词 → 拼音）。因此连续重跑两次产出的文件字节完全相同，SHA256 不变。

> 注意：`tools/dict/.cache/jieba_dict.txt`（4.9 MB 原始词表）**不进 App 包**，只有上面三个裁剪后的
> 产物会被打进 `Shared/dict`（folder reference，Bundle 内为 `dict/`）。Swift 侧音节表 `PinyinSyllables.swift` 由
> `tools/dict/syllable_table.py` 生成，改动音节表后必须重跑 `gen_swift_syllables.py`，
> 否则词库（Python 侧）与引擎（Swift 侧）会漂移。

## 3. 候选算法（`PinyinEngine`）

### 3.1 处理流水线

```
输入串
  ├─ 0. 去空白；剥离末尾数字（1–9，最多 2 位）作为"选词序号"
  ├─ 1. 归一化：小写 + 仅保留 [a-z0-9]
  ├─ 2. 自造词/学习词命中（精确 + 前缀）
  ├─ 3. 词库全拼精确匹配
  ├─ 4. 词库前缀预测（zhongg → zhongguo…）
  ├─ 5. 简拼展开（zg → 中国/这个…）
  ├─ 6. 多词组合切分 DP（woxihuanni → 我喜欢你）
  ├─ 7. 模糊音兜底（仅当精确候选不足时，×0.85 降权，见 §3.8）
  ├─ 8. 英文/数字直通（2333、hello）
  └─ 9. 统一打分 + 稳定排序 + 截断
```

### 3.2 多音节切分 DP

音节表 421 项（`PinyinSyllables.all`，含 `n/ng/m/hm/hng/ê/yo/lo/rua/shei/zhei/dei/tei/den/nen/biang/duang`
等口语叹词），最长音节 6 字母（`zhuang`/`chuang`/`shuang`）。

**切分（`segment(_:maxSegments:)`）**：最少音节优先。
`best[i]` = 前缀 `pinyin[0..<i]` 的最优切法，`bestCount[i]` = 最少音节数：

```
bestCount[0] = 0
for i in 0..<n where bestCount[i] 可达:
    for len in 1...min(6, n-i):
        syl = pinyin[i..<i+len]
        if syl ∈ SYLLABLES:
            c = bestCount[i] + 1
            if c < bestCount[i+len]: bestCount[i+len] = c; best[i+len] = best[i] + [syl]
```

**组合候选（`appendComposedCandidates`）**：在上面的 DP 上换成"按词频加权的最优路径"。
`best[i]` = 切到第 i 个字符时的最大累计 `log(freq+1)`：

```
best[0] = 0
for start in 0..<n where best[start] 可达:
    for end in start+1...min(start+24, n):
        key = input[start..<end]
        if let entry = dict.exactEntries(key, 1).first, 是中文词:
            score = best[start] + log(freq+1)
            if score > best[end]: best[end] = score; back[end] = start
```

- 整串能切完且词块 ≥2 → 产出"整句"候选，`base = 平均log词频 + 1.2*(词块数-1) + 1.5`
  （词块越多越像真句子，给一点正向加成）。
- 切不完时（如 `woxihuanzh`）→ 取最优前缀 `我喜欢`，对剩余 `zh` 做前缀预测补最后一段。
- 只有"整串不是词库中的完整词"时才做组合，避免 `xian` 组合出"先在"这类噪声。

### 3.3 简拼与混拼

- **简拼** `zg`：查首字母索引（长度 1–6，超出按拼音处理，避免误命中）。
- **混拼** `zhongg`：走前缀预测——`zhongg` 是 `zhongguo` 的字符前缀，直接命中；
  同时也覆盖"末段只打首字母"的形态，因为前缀匹配对 `zhongg*` 一视同仁。
- **全拼** `zhongguo`：精确匹配优先级最高。

### 3.4 排序公式

```
score = log(freq + 1) * 1.0
      + userWeight(text) * 6.0
      + recentBoost(text) * 8.0
      - max(0, 字数 - 1) * 0.35
      + base(来源加成)
```

- `freq`：词库词频；组合候选为 0，靠 `base` 体现。
- `userWeight = log2(1 + 选词次数)`（0 次 → 0，1 次 → 1.0，3 次 → 2.0）。
- `recentBoost`：最近使用环形缓冲里的排位，队首 1.0，线性衰减到 0。
- `长度惩罚`：每多一个字扣 0.35，抑制"整句候选"永远压过单词。
- `base`：精确命中 2.0 / 前缀预测 1.0×覆盖率 / 简拼 0.6-0.05×名次 /
  自造词 3.0–4.0 / 组合 1.5+ / 英文直通 2.2 / 数字直通 3.0。
- 排序键：`score` 降序 → 字数升序 → 拼音升序 → 文本升序（**全序，结果确定**）。

`limit` 默认 30，与候选栏一屏容量匹配。

### 3.5 英文/数字直通

- 含数字（`2333`、`3Q`、`u1s1`）：**始终**给出原样候选。
- 纯字母（`hello`、`deadline`）：仅当没有中文候选时给出，避免 `nihao` 后面冒出英文 `nihao`。
- 非 ASCII（中文、emoji）输入不做直通。

### 3.6 性能与复杂度

| 操作 | 复杂度 | 说明 |
| --- | --- | --- |
| 全拼精确 | O(1) 哈希 + O(limit) | — |
| 前缀预测 | O(log k + m) ，m = 前缀命中的键数（上限 40） | 二分 + 线性扫描 |
| 简拼 | O(1) 哈希 + O(24) | 首字母索引 |
| 组合 DP | O(n × 24) 次哈希查询，n ≤ 24 → ≤ 576 次 | 每次哈希 O(1) |
| 打分排序 | O(p log p)，p = 候选池大小（通常 < 100） | — |
| **单次按键总耗时** | **0.2–1.5 ms（预算 8 ms）** | 无 IO、无锁竞争 |

DP 的两层剪枝：`maxTileLength = 24`（单块拼音长度上限）、`prefixKeyLimit = 40`（前缀展开上限）。
`1–6` 字词的哈希查询是最坏情况的主要开销，5k 词典下仍是纯内存操作。

### 3.7 上屏后联想（`predictNext`）

先查 `phrases.tsv`（`PhraseSuggestionIndex`，755 条，最长触发词优先做尾部匹配），
不足时用 `UserLearningStore.recentPhrases` 补齐。返回 `kind = .learned`。

### 3.8 模糊音（`FuzzyPinyin`）

南方口音用户常把 `zh/z`、`ch/c`、`sh/s`、`in/ing`、`l/n` 混用，模糊音把这些对子
折叠成等价类后再查词库。**默认开启，但只开前 5 条规则**（`FuzzyPinyinOptions.defaultRules`）。

**9 条规则**（`FuzzyPinyinRule`，rawValue 即 `zh-z` 形式）：

| 规则 | 折叠 | 默认 |
| --- | --- | --- |
| `zhZ` | `zh` / `z`（`zhong` ↔ `zong`） | ✅ |
| `chC` | `ch` / `c`（`chi` ↔ `ci`） | ✅ |
| `shS` | `sh` / `s`（`shi` ↔ `si`） | ✅ |
| `inIng` | `in` / `ing`（`jin` ↔ `jing`） | ✅ |
| `lN` | `l` / `n`（`lin` ↔ `nin`，单字母 `n` 不参与） | ✅ |
| `enEng` | `en` / `eng`（`sen` ↔ `seng`） | ❌ |
| `anAng` | `an` / `ang`（`ban` ↔ `bang`，`iang`/`uang` 让位给后两条） | ❌ |
| `ianIang` | `ian` / `iang`（`xian` ↔ `xiang`） | ❌ |
| `uanUang` | `uan` / `uang`（`zhuan` ↔ `zhuang`） | ❌ |

**为什么默认开前 5 条、关后 4 条**：

1. 前 5 条是全国最普遍的混淆（平翘舌 + 前后鼻音 + `l/n`，后者集中在湘赣/西南官话区），
   错拼率远高于后 4 条。
2. 后 4 条里 `en/eng`、`an/ang`、`ian/iang`、`uan/uang` 一旦开启，`xian`→`xiang`、
   `zhuan`→`zhuang` 这类**真实存在的不同词**会互相串台（"先"和"香"、"专"和"装"），
   误伤概率显著高于收益，留给用户按自己口音自选。
3. 只开 5 条时，绝大多数输入串的变体数为 1（无模糊命中），按键开销可忽略；
   全开 9 条最坏情况下变体数也只有 8 条（见下方限流）。
4. 默认值可通过设置页「模糊音」开关一键关闭，关闭后引擎完全跳过模糊音分支（零开销）。

**限流（防组合爆炸）**：

- 单音节变体上限 `maximumVariantsPerSyllable = 4`（含自身）；
- 整串最多改动 `maximumChangedSyllables = 4` 个音节；
- 整串变体总数上限 `maximumExpandedVariants = 24`；
- 每个变体最多取 `maximumMatchesPerVariant = 8` 条精确命中、`maximumPrefixKeysPerVariant = 8` 个前缀键。

**接入点与排序**：`PinyinEngine.candidates(for:limit:)` 在「多词组合切分」之后、英文直通之前调用
`appendFuzzyCandidates`。它有三道前置闸门（任一条不满足就直接返回）：

```swift
guard options.isActive            // 开关打开且至少选了一条规则
guard normalized.count >= 2       // 单字母不跑模糊（没有混淆空间）
guard poolSize < limit            // 精确候选已占满 → 模糊候选根本没机会进榜，直接跳过
```

命中后按 `base = isExact ? 2.0 × 0.85 : 1.0 × coverage × 0.85` 写池，
即**模糊命中恒为同位置精确命中的 0.85 倍**（约等于词频低一个数量级，或少 2 次选词学习），
因此**永远排在精确命中之后**，只在精确候选不足时补位。`0.85` 是 `PinyinEngine.fuzzyDiscount`。

**性能实测**（`python tools/dict/_probe_fuzzy_perf.py`，Python 上界，Swift 应快 3–10 倍）：

| 场景 | 关模糊 | 开模糊（默认 5 条） | 增量 |
| --- | --- | --- | --- |
| `nihao` | 0.012 ms | 0.076 ms | +0.065 ms |
| `zhongguo` | 0.016 ms | 0.077 ms | +0.061 ms |
| `zhuang` | 0.025 ms | 0.079 ms | +0.054 ms |
| `zhongguorenmin` | 0.080 ms | 0.231 ms | +0.152 ms |

`expand` 本身：`zhongguo` 0.071 ms / `womenyiqiquchifanba`（19 字母）0.449 ms，
全 9 条规则下后者 0.471 ms、变体 8 条。**整体远低于 2 ms 红线**，且典型按键
（`wo` 0.137 ms、`nihao` 0.073 ms）因为「候选池已满」闸门根本不会进入模糊分支。

**持久化**：`FuzzyPinyinSettings`（进程内单例，`SharedStore` 绑定）把开关存成
`v1|enabled=1|rules=ch-c,in-ing,l-n,sh-s,zh-z`（规则按 rawValue 排序，同配置字节相同），
Key `moyu.ime.fuzzy.v1`。`IMEKit` 在 `init` 里 `configure(store:)` 完成绑定，
之后 UI 改开关立即对下一次取候选生效。

## 4. 用户学习（`UserLearningStore`）

- **选词计频**：`recordSelection` 累加 `counts[text]`，同时记 `pinyinByText` 供反查。
- **最近使用**：环形缓冲 200 条（`recentCapacity`），队首最新，重复项提前。
- **自造词**：`addUserPhrase(_:pinyin:)` 写入 `userPhrases`，并给 `counts ≥ 3` 起步权重。
- **持久化**：只经 `SharedStore` 的四个方法（`string(forKey:)` / `set(_:forKey:)` /
  `data(forKey:)` / `setData(_:forKey:)`），JSON 编码存 `UserDefaults`，Key `moyu.ime.learning.v1`。
  不 import Storage 之外的任何模块，也不复制 `SharedStore` 实现。
- **线程安全**：`NSLock` 保护全部可变状态；`persistIfNeeded` 在锁外落盘，
  连续选词时按"脏标记 + 节流"合并写入，避免每次上屏都做一次磁盘 IO。
- **简繁**：不做任何转换（按用户输入原样记录），因此繁简混用不会阻塞学习。

## 5. 短语库与剪贴板（`PhraseLibrary` / `ClipboardHistory`）

- `PhraseItem`：`id` / `key` / `text` / `isPinned`，`Codable + Identifiable + Sendable`。
- `PhraseLibrary.expand(_:clipboard:)` 支持三个占位符：
  - `{date}` → `2026年10月24日`（`yyyy年M月d日`，`zh_CN`）
  - `{time}` → `16:25`（`HH:mm`）
  - `{clipboard}` → 传入的剪贴板文本（`nil` 时替换为空串）
  - 文本中不含 `{` 时直接返回，不做日期格式化（快速路径）。
- 持久化 Key `moyu.phrases.v1`，首次使用注入 3 条示例（日期/时间/地址快捷短语）。
- `ClipboardHistory`：容量 20，去重、可 `pin`（置顶）、`clear`（保留置顶）；
  隐私开关 `enabled` 为 `false` 时立即清空并停止记录（Key `moyu.settings.clipboardHistory`）。

## 6. 自测清单（macOS / Xcode 单测）

Windows 环境无法编译 Swift，以下断言用于在 macOS 上一次性验证契约行为。
建议放在 `Tests/IMECoreTests/` 下，`import XCTest` + `@testable import` 或直接断言。

```swift
// MARK: - 前置
let store = SharedStore.shared
let dict = PinyinDictionary.bundled()
let learning = UserLearningStore(store: store)
let engine = PinyinEngine(dictionary: dict, learning: learning)
```

### 6.1 词库加载

| # | 断言 | 预期 |
| --- | --- | --- |
| 1 | `dict.wordCount >= 3000` | `true` |
| 2 | `dict.version == "1.0.0"` | `true` |
| 3 | `dict.loadedPath != "<builtin>"` | `true`（词库已正确打包） |
| 4 | `dict.loadDurationMilliseconds < 80` | `true` |
| 5 | `dict.lookup(pinyin: "zhongguo", limit: 3).first?.text` | `"中国"` |
| 6 | `dict.hasPrefix("zhongg")` | `true` |
| 7 | `dict.hasPrefix("zzzzz")` | `false` |
| 8 | `dict.pinyinKeys(initials: "zg", limit: 10).contains("zhongguo")` | `true` |
| 9 | `dict.frequency(of: "中国") > 0` | `true` |
| 10 | `dict.exactEntries(pinyin: "zhongguo", limit: 1).count` | `1`（精确存在） |
| 11 | `dict.entries.count == dict.wordCount` | `true` |

### 6.2 全拼 / 简拼 / 混拼 / 组合

| # | 断言 | 预期 |
| --- | --- | --- |
| 12 | `engine.candidates(for: "zg").first?.text` | `"中国"` |
| 13 | `engine.candidates(for: "zhongguo").first?.text` | `"中国"` |
| 14 | `engine.candidates(for: "zhongg").contains { $0.text == "中国" }` | `true` |
| 15 | `engine.candidates(for: "nihao").contains { $0.text == "你好" }` | `true` |
| 16 | `engine.candidates(for: "woxihuanni").contains { $0.text.contains("喜欢") }` | `true` |
| 17 | `engine.candidates(for: "xiexie").first?.text` | `"谢谢"` |
| 18 | `engine.candidates(for: "zaijian").first?.text` | `"再见"` |
| 19 | `engine.candidates(for: "hh").contains { $0.text == "哈哈" }` | `true`（简拼） |
| 20 | `engine.candidates(for: "yyds").contains { $0.kind == .english }` | `true` |
| 21 | `engine.candidates(for: "2333").first?.text` | `"2333"`（数字直通） |
| 22 | `engine.candidates(for: "").isEmpty` | `true` |
| 23 | `engine.candidates(for: "   ").isEmpty` | `true` |

### 6.3 候选质量

| # | 断言 | 预期 |
| --- | --- | --- |
| 24 | `engine.candidates(for: "zg", limit: 30).count <= 30` | `true` |
| 25 | `engine.candidates(for: "zg").first?.score >= (engine.candidates(for: "zg").last?.score ?? 0)` | `true`（降序） |
| 26 | 用 `Set` 检查 `candidates(for: "nihao").map(\.text)` 无重复 | `true` |
| 27 | `engine.candidates(for: "zhongguo").first?.kind` | `.word` |
| 28 | 汉字候选的 `kind != .emoji` | `true`（纯汉字一律 `.word`） |
| 29 | `engine.candidates(for: "kaixin").contains { $0.kind == .emoji }` | `true`（emoji 联想） |
| 30 | `engine.selectionIndex(for: "zhongguo2")` | `1` |

### 6.4 学习与个性化

| # | 断言 | 预期 |
| --- | --- | --- |
| 31 | `learning.weight(for: "不存在的词")` | `0` |
| 32 | 选中 `candidates(for: "nihao")` 首项后 `learning.weight(for: "你好") > 0` | `true` |
| 33 | `learning.recentPhrases(limit: 1).first` | 刚选中的词 |
| 34 | 连续选词 250 次后 `learning.recentPhrases(limit: 300).count <= 200` | `true` |
| 35 | `learning.addUserPhrase("墨语输入法", pinyin: "moyushurufa")` 后 `candidates(for: "moyushurufa").first?.text` | `"墨语输入法"` |
| 36 | `learning.recentBoost(for: 首项) > learning.recentBoost(for: 末项)` | `true` |

### 6.5 短语库 / 剪贴板 / 门面

| # | 断言 | 预期 |
| --- | --- | --- |
| 37 | `PhraseLibrary.expand(text: "今天{date}", clipboard: nil, date: 固定日期)` | `"今天2026年10月24日"` |
| 38 | `PhraseLibrary.expand(text: "{time}", clipboard: nil, date: 固定日期)` | `"16:25"`（视固定日期的时间分量） |
| 39 | `PhraseLibrary.expand(text: "粘贴{clipboard}", clipboard: "abc", date: now)` | `"粘贴abc"` |
| 40 | `PhraseLibrary.expand(text: "{clipboard}", clipboard: nil, date: now)` | `""` |
| 41 | 新建 `PhraseLibrary(store:)` 的 `items.count >= 3`（首启注入示例） | `true` |
| 42 | `library.upsert(item)` 后 `library.items.contains { $0.id == item.id }` | `true` |
| 43 | `library.remove(id: item.id)` 后不再包含 | `true` |
| 44 | 关闭剪贴板的 `ClipboardHistory(store:enabled:false).items.isEmpty` | `true` |
| 45 | 开启后 `add("a")` × 25，`items.count == 20` | `true`（截断） |
| 46 | `add("a")` 两次后 `items.filter { $0 == "a" }.count == 1` | `true`（去重） |
| 47 | `pin("a")` 后 `items.first == "a"` | `true` |
| 48 | `kit.diagnosticsSummary` 非空且包含 `"5276"` 或实际条数 | `true` |

### 6.6 词库来源诊断（排查「打不出中文」用）

| # | 断言 | 预期 |
| --- | --- | --- |
| 49 | `kit.dictionarySource` | `.bundled`（读到随包词库）；词库缺失时为 `.builtin` |
| 50 | `kit.isUsingBuiltinDictionary` | `false`；为 `true` 说明回退到 50 条内置词表 |
| 51 | `kit.dictionaryRelativePath` | `"dict/base_dict.tsv"`；兜底时为 `"<builtin>"` |
| 52 | `kit.diagnosticsSummary.contains("来源：打包词库")` | `true` |
| 53 | 用 `PinyinDictionary(entries: [], version: "t")` 构造后 `IMEKit` 的 `isUsingBuiltinDictionary` | `false`（`.memory`，不是 `.builtin`） |

### 6.7 线程安全（可选，压力测试）

| # | 断言 | 预期 |
| --- | --- | --- |
| 54 | 8 个并发队列各调用 `candidates(for:)` 1000 次 | 无崩溃、无数据竞争（TSan 干净） |
| 55 | 并发 `recordSelection` 1000 次后 `weight(for:)` 等于累计次数 | `true` |

**预期输出（前 12 条跑通的示意）**：
```
1: wordCount = 5276                     PASS
2: version = "1.0.0"                    PASS
3: loadedPath = ".../base_dict.tsv"     PASS
5: lookup("zhongguo") = 中国             PASS
12: candidates("zg")[0] = 中国            PASS
13: candidates("zhongguo")[0] = 中国      PASS
15: candidates("nihao") ⊇ 你好            PASS
16: candidates("woxihuanni") ⊇ 我喜欢你    PASS
19: candidates("hh") ⊇ 哈哈               PASS
21: candidates("2333")[0] = 2333          PASS
30: selectionIndex("zhongguo2") = 1       PASS
35: addUserPhrase → 首位命中              PASS
```

### 6.8 已验证结论（Python 算法复刻）

Windows 环境无法编译 Swift，因此用 `tools/dict/_simulate_engine.py` 以 Python 复刻了
`PinyinDictionary` + `PinyinEngine` 的完整候选算法（音节切分 DP、组合 DP、前缀预测、
简拼索引、排序公式、类型判定），读**真实的** `base_dict.tsv` 跑断言：

```
词库条数 = 5276，短语条数 = 755
结果：39 / 39 通过
```

覆盖内容与实测值：

| 组 | 条数 | 关键实测值 |
| --- | --- | --- |
| 词库加载 | 7 | `lookup("zhongguo")[0] = 中国`；`hasPrefix("zhongg") = true`；`hasPrefix("zzzzz") = false`；`initials["zg"] ⊇ zhongguo` |
| 候选生成 | 12 | `candidates("zg")[0] = 中国`；`candidates("zhongguo")[0] = 中国`；`candidates("zhongg") ⊇ 中国`；`candidates("nihao") ⊇ 你好`；`candidates("xiexie")[0] = 谢谢`；`candidates("zaijian")[0] = 再见`；`candidates("hh") ⊇ 哈哈`；`candidates("yyds") ⊇ english`；`candidates("2333")[0] = 2333`；`candidates("woxihuanni") ⊇ 喜欢` |
| 候选质量 | 10 | 数量 ≤ 30、score 严格降序、无重复文本、汉字候选全 `.word`、`candidates("kaixin") ⊇ emoji`、`selectionIndex("zhongguo2") = 1`、`candidates("zhongguo2")` 不含整串英文、`candidates("yyds")[0].kind = english` |
| 短语库 | 3 | 755 条 ≥ 300；含触发词 `谢谢`/`晚安`；`谢谢 → 不客气` |
| 词库数据质量 | 7 | 无空词/无空白词/无重复、词频降序、纯汉字无 `punct` 标记、条数 ∈ [4000, 7000] |

> 说明：该脚本验证的是**算法与数据**，不能替代 Xcode 编译。Swift 侧的类型/签名正确性
> 依靠 `scripts/qa/static_check.py` 的静态扫描（当前 `P0=0 P1=0`）+ 逐文件人工复核。
> 复刻脚本与 Swift 实现共享同一份 `base_dict.tsv` 与同一套常量，若两侧常量漂移会立刻 FAIL。

### 6.9 一站式断言脚本（复制即跑，77 条 `assert`）

在 macOS 上新建 `Tests/IMECoreTests/IMECoreSmokeTests.swift`，整段粘进去即可。
`assert` 只在 Debug 生效；若要在 Release 也校验，把 `assert` 换成 `XCTAssertTrue` 即可。

```swift
import XCTest
@testable import AIKeyboard      // 换成 IMECore 所处的实际 module 名

final class IMECoreSmokeTests: XCTestCase {

    func test01_dictionaryLoading() {
        let dict = PinyinDictionary.bundled()
        assert(dict.wordCount == 5276,                        "词库条数应为 5276，实际 \(dict.wordCount)")
        assert(dict.version == "1.0.0",                       "版本号应为 1.0.0，实际 \(dict.version)")
        assert(dict.loadedPath != "<builtin>",                "走了内置兜底词表，说明 base_dict.tsv 没打进 Bundle")
        assert(dict.loadDurationMilliseconds < 80,            "加载耗时 \(dict.loadDurationMilliseconds)ms 超预算 80ms")
        assert(dict.lookup(pinyin: "zhongguo", limit: 3).first?.text == "中国")
        assert(dict.hasPrefix("zhongg") == true)
        assert(dict.hasPrefix("zzzzz") == false)
        assert(dict.pinyinKeys(initials: "zg", limit: 10).contains("zhongguo"))
        assert(dict.frequency(of: "中国") > 0)
        assert(dict.exactEntries(pinyin: "zhongguo", limit: 1).count == 1)
        assert(dict.entries.count == dict.wordCount)
    }

    func test02_candidates() {
        let learning = UserLearningStore(store: SharedStore.shared)
        let engine = PinyinEngine(dictionary: PinyinDictionary.bundled(), learning: learning)

        assert(engine.candidates(for: "zg").first?.text == "中国")                  // 简拼
        assert(engine.candidates(for: "zhongguo").first?.text == "中国")            // 全拼
        assert(engine.candidates(for: "zhongg").contains { $0.text == "中国" })      // 前缀预测
        assert(engine.candidates(for: "nihao").contains { $0.text == "你好" })       // 混拼
        assert(engine.candidates(for: "woxihuanni").contains { $0.text.contains("喜欢") }) // 组合切分
        assert(engine.candidates(for: "xiexie").first?.text == "谢谢")
        assert(engine.candidates(for: "zaijian").first?.text == "再见")
        assert(engine.candidates(for: "hh").contains { $0.text == "哈哈" })
        assert(engine.candidates(for: "yyds").contains { $0.kind == .english })      // 英文直通
        assert(engine.candidates(for: "2333").first?.text == "2333")                // 数字直通
        assert(engine.candidates(for: "").isEmpty)
        assert(engine.candidates(for: "   ").isEmpty)
        assert(engine.selectionIndex(for: "zhongguo2") == 1)                        // 末尾数字选词
    }

    func test03_candidateQuality() {
        let learning = UserLearningStore(store: SharedStore.shared)
        let engine = PinyinEngine(dictionary: PinyinDictionary.bundled(), learning: learning)
        let list = engine.candidates(for: "zg", limit: 30)

        assert(list.count <= 30,                                       "候选数超 limit")
        assert((list.first?.score ?? 0) >= (list.last?.score ?? 0),     "候选未按分数降序")
        assert(Set(list.map { $0.text }).count == list.count,           "候选文本有重复")
        assert(engine.candidates(for: "zhongguo").first?.kind == .word)
        let hanCandidates = engine.candidates(for: "zhongguo").filter { candidate in
            candidate.text.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        }
        assert(hanCandidates.allSatisfy { $0.kind == .word },
               "纯汉字候选必须是 .word，不能被标成 emoji/punct")
        assert(engine.candidates(for: "kaixin").contains { $0.kind == .emoji })       // emoji 联想
    }

    func test04_learning() {
        let learning = UserLearningStore(store: SharedStore.shared)
        learning.reset()
        let engine = PinyinEngine(dictionary: PinyinDictionary.bundled(), learning: learning)

        assert(learning.weight(for: "不存在的词") == 0)
        guard let first = engine.candidates(for: "nihao").first else {
            XCTFail("candidates(nihao) 为空，词库或简拼索引可能未加载")
            return
        }
        engine.commit(first, input: "nihao")
        assert(learning.weight(for: first.text) > 0)
        assert(learning.recentPhrases(limit: 1).first == first.text)
        assert(learning.recentPhrases(limit: 300).count <= UserLearningStore.recentCapacity)
        learning.addUserPhrase("墨语输入法", pinyin: "moyushurufa")
        assert(learning.pinyin(forUserPhrase: "墨语输入法") == "moyushurufa")
        assert(engine.candidates(for: "moyushurufa").contains { $0.text == "墨语输入法" })
    }

    func test05_phraseAndClipboard() {
        let store = SharedStore.shared
        let library = PhraseLibrary(store: store)
        assert(library.items.count >= 3, "首启应注入示例短语")

        let fixed = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-24 前后的固定时刻
        assert(PhraseLibrary.expand(text: "今天{date}", clipboard: nil, date: fixed).hasPrefix("今天20"))
        assert(PhraseLibrary.expand(text: "{clipboard}", clipboard: "abc", date: fixed) == "abc")
        assert(PhraseLibrary.expand(text: "{clipboard}", clipboard: nil, date: fixed) == "")

        let history = ClipboardHistory(store: store, enabled: false)
        assert(history.items.isEmpty, "关闭开关时不应保留剪贴板历史")
        history.setEnabled(true)
        (1...25).forEach { history.add("a\($0)") }
        assert(history.items.count == 20, "剪贴板历史上限应为 20，实际 \(history.items.count)")
        history.add("a25")
        assert(history.items.filter { $0 == "a25" }.count == 1, "重复内容未去重")
        history.pin("a25")
        assert(history.items.first == "a25", "置顶未生效")
        history.clear()
        assert(history.items == ["a25"], "clear 应只清空非置顶项")
    }

    func test06_facade() {
        let kit = IMEKit(store: SharedStore.shared)
        assert(kit.dictionaryVersion == "1.0.0")
        assert(kit.wordCount == 5276)
        assert(kit.dictionarySource == .bundled)
        assert(kit.isUsingBuiltinDictionary == false)
        assert(kit.dictionaryRelativePath.hasSuffix("dict/base_dict.tsv"))
        assert(kit.diagnosticsSummary.contains("来源：打包词库"))
        assert(kit.diagnosticsSummary.contains("5276"))
        assert(kit.candidates(for: "zg").first?.text == "中国")
    }

    func test07_fuzzyPinyin() {
        // 9 条规则、默认开前 5 条
        assert(FuzzyPinyinRule.allCases.count == 9)
        assert(FuzzyPinyinOptions.defaultRules.count == 5)
        assert(FuzzyPinyinOptions.defaultRules.contains(.zhZ))
        assert(FuzzyPinyinOptions.defaultRules.contains(.inIng))
        assert(FuzzyPinyinOptions.defaultRules.contains(.enEng) == false)

        // 单音节变体：含自身且自身在第 0 位
        let zhong = FuzzyPinyin.variants(of: "zhong", rules: FuzzyPinyinOptions.defaultRules)
        assert(zhong.first == "zhong")
        assert(zhong.contains("zong"))
        assert(FuzzyPinyin.variants(of: "zhong", rules: []).count == 1)
        assert(FuzzyPinyin.variants(of: "ling", rules: [.enEng]).count == 1, "单字母 n 不应参与 l/n 折叠")

        // 整串变体：按改动音节数从少到多，原文永远第 0 位
        let expanded = FuzzyPinyin.expand("zhongguo", rules: FuzzyPinyinOptions.defaultRules)
        assert(expanded.first == "zhongguo")
        assert(expanded.contains("zongguo"))
        assert(FuzzyPinyin.expand("zongguo", rules: FuzzyPinyinOptions.defaultRules).contains("zhongguo"))
        assert(FuzzyPinyin.expand("", rules: FuzzyPinyinOptions.defaultRules).isEmpty)
        assert(FuzzyPinyin.expand("zongg", rules: FuzzyPinyinOptions.defaultRules).contains("zhongg"))

        // 限流：单音节 ≤4、整串 ≤24
        assert(FuzzyPinyin.variants(of: "zhuang", rules: FuzzyPinyinOptions.allEnabled).count <= 4)
        assert(FuzzyPinyin.expand("zhongguorenmin", rules: FuzzyPinyinOptions.allEnabled).count <= 24)

        // 引擎：精确优先，模糊命中降权后补位
        let exact = PinyinDictionary.bundled()
        let learning = UserLearningStore(store: SharedStore.shared)
        let engine = PinyinEngine(dictionary: exact, learning: learning)
        engine.fuzzyOptions = FuzzyPinyinOptions(enabled: true, rules: [.zhZ])
        assert(engine.candidates(for: "zhongguo").first?.text == "中国", "精确命中必须仍是首候选")
        let fuzzy = engine.candidates(for: "zongguo")
        assert(fuzzy.contains { $0.text == "中国" }, "zh/z 模糊应能打出「中国」")
        assert(fuzzy.first?.score ?? .infinity <= engine.candidates(for: "zhongguo").first?.score ?? 0,
               "模糊命中不应比精确命中分更高")
        engine.fuzzyOptions = .off
        assert(engine.candidates(for: "zongguo").contains { $0.text == "中国" } == false,
               "关闭模糊音后不应再出「中国」")

        // 设置持久化与门面
        FuzzyPinyinSettings.shared.options = FuzzyPinyinOptions(enabled: false, rules: [])
        assert(FuzzyPinyinSettings.shared.options.enabled == false)
        FuzzyPinyinSettings.shared.reset()
        assert(FuzzyPinyinSettings.shared.options.enabled == true, "reset 应恢复默认（开启）")
        let kit = IMEKit(store: SharedStore.shared)
        assert(kit.isFuzzyPinyinEnabled == true)
        assert(kit.fuzzyDiagnosticsSummary.contains("已开启"))
    }
}
```

**预期输出**（77 条断言全过时 XCTest 打印）：

```
Test Suite 'IMECoreSmokeTests' passed
  Test Case 'test01_dictionaryLoading'  passed  (0.031 s)
  Test Case 'test02_candidates'         passed  (0.004 s)
  Test Case 'test03_candidateQuality'   passed  (0.002 s)
  Test Case 'test04_learning'           passed  (0.006 s)
  Test Case 'test05_phraseAndClipboard' passed  (0.003 s)
  Test Case 'test06_facade'             passed  (0.003 s)
  Test Case 'test07_fuzzyPinyin'        passed  (0.005 s)
Executed 7 tests, with 77 assertions, 0 failures, 0 unexpected
```

> 若 `test01` 在 `loadedPath != "<builtin>"` 处失败，说明 Xcode 没把 `Shared/dict` 以
> folder reference 打进 target，检查 `ios/project.yml` 的 `type: folder` 与 Copy Bundle Resources。
> `test05` 里 `ClipboardHistory(store: SharedStore.shared)` 会读写真实 App Group 容器，
> 单测建议用 `SharedStore` 的 `forceMemory` 变体（若测试 target 可访问 internal init）。

## 7. 编码规范符合性

| 规范（docs/02 §3） | 状态 |
| --- | --- |
| 4 空格缩进 | ✅ 全部文件 |
| UTF-8 无 BOM、LF | ✅ 已校验（`noBOM` / `noCRLF`） |
| 无 `try!` / `as!` | ✅ 已静态扫描 |
| 无发布路径 `fatalError` | ✅ 已静态扫描 |
| 强制解包仅 `@IBOutlet` / 已知非空 + `// SAFE:` | ✅ 无强制解包 |
| `Shared/IMECore` 不 import UIKit/SwiftUI | ✅ 只 `import Foundation` |
| public API 有 `///` 中文文档注释 | ✅ 全部 public 成员 |
| 每文件 ≤600 行 | ✅ 最长 594 行（`PinyinEngine.swift`） |
| 注释中文、标识符英文 | ✅ |
| 模块级注释（职责/依赖/使用方） | ✅ 每个文件头部三要素 |

## 8. 已知限制与后续可做

1. **多音字**：按 pypinyin 默认读音生成（`银行`→`yinhang`、`长大`→`zhangda`），
   不做上下文消歧。若后续要提升准确率，可在 `PinyinDictionary` 增加"多音字候选展开"。
2. **组合候选上限**：单块最大 24 字符、最多回溯 64 段，超长输入串会被截断处理。
3. **模糊音已支持**：`zh/z`、`ch/c`、`sh/s`、`in/ing`、`l/n`、`en/eng`、`an/ang`、`ian/iang`、
   `uan/uang` 共 9 条规则，可开关，**默认开前 5 条**（平翘舌 + 前后鼻音 + `l/n`）。
   实现与限流见 §3.8；后 4 条默认关闭的原因是误伤概率高（`xian`/`xiang` 会串台），
   交由用户按自己口音自选。
4. **无纠错**：输入串打错一个字不会自动纠正（如 `nihap` → `你好`）。
5. **词库加载耗时**为理论估算（Windows 无 Swift 环境），需在真机上用
   `dict.loadDurationMilliseconds` 实测确认；若超标，可把解析改为 `Data` + 手写字节扫描。
6. **`predictNext`** 依赖 `phrases.tsv` 的触发词表，未命中时只回退到最近使用，
   没有语义理解能力。**语义级的「下一句预测」由 §9 的上下文联想（`ContextualSuggestion`）承担**，
   两者并行、互不影响：`predictNext` 给「词/短语」，上下文联想给「完整的一句话」。

### 8.1 词库打包路径与 Bundle 布局（跨模块契约，已由 Lead 验证）

- `ios/project.yml` 里两个 target 都以 **folder reference（`type: folder`）** 引用 `Shared/dict`，
  因此打出来的 Bundle 内路径是 `dict/base_dict.tsv`、`dict/phrases.tsv`，
  **不是** `Resources/dict/base_dict.tsv`（旧布局已废弃，加载器仍保留该候选仅为兼容）。
- 目录名**必须**是 `Shared/dict`，**绝不能**是 `Shared/Resources/dict`：folder reference 会把目录名
  原样复制到 bundle 根，一旦出现 `Resources/` 目录，iOS 27 的 installd 会拒绝安装
  （`IXErrorDomain Code=13 Missing bundle ID`，真机实测空目录也失败）。
- `PinyinDictionary` 的候选路径**第 1 条**是 `dict`（`candidateURLs()` 的 `subdirectories` 首位），
  必须命中 `dict/base_dict.tsv`，否则会静默回退到内置小词库 —— 这是「词库看起来装了但候选很少」的唯一原因。
  一行确诊：`IMEKit().isUsingBuiltinDictionary == true`（或 `IMEKit().dictionarySource == .builtin`），
  此时 `diagnosticsSummary` 会显示 `来源：⚠️ 内置兜底词库`、`路径：<builtin>` 且 `wordCount == 50`。
- 真机排查用到的三个诊断 API（`ios/Shared/IMECore/IMEKit.swift`）：
  | API | 含义 |
  | --- | --- |
  | `dictionarySource` | `.bundled`（读到随包词库）/ `.builtin`（回退 50 条）/ `.memory`（测试） |
  | `isUsingBuiltinDictionary` | `source == .builtin` 的便捷布尔 |
  | `dictionaryRelativePath` | Bundle 内相对路径，如 `dict/base_dict.tsv`；兜底时为 `<builtin>` |
  | `diagnosticsSummary` | 一行中文摘要：`词库 v1.0.0｜5276 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 12.3ms` |
  **注意**：扩展里的 `Bundle.main` 是 `.appex` 自身而非宿主 App，因此两个 Bundle 必须**各带一份**词库；
  只要扩展侧不是 `.bundled`，就是打包问题，不是引擎问题。
- 全仓 grep 验证：`ios/**/*.swift` 中 `base_dict|phrases\.tsv|dict_meta|ContentsOfFile` 的命中
  **全部在 `ios/Shared/IMECore/`**，App/Extension 侧零命中 → 不存在词库重复加载。
- `dict_meta.json` 的 `sha256` 可用于启动时校验词库完整性（当前实现只读 version/count，未校验 sha256，
  属可选增强）。
- 词库产物由 `python tools/dict/build_dict.py` 生成到 `ios/Shared/dict/`；
  `scripts/qa/ipa_layout_check.py` 在打包后校验 IPA 内 `dict/` 三个文件齐全且全包无 `Resources/` 路径。

## 9. 上下文联想（`ContextualSuggestion`）

传统输入法的联想是「词库顺序联想」：给个高频词表，按顺序往下冒。本模块额外做一件事：
**读懂上下文之后，猜你接下来想说的那一句话**。典型场景——微信里对方问「明天几点到？」，
候选栏直接给出「我大概十点到」「看情况，可能晚一点」「十点前吧」，点一下整条上屏。

与 §3.7 的 `predictNext(after:)` **并存、互不影响**：
| 能力 | 入口 | 产出 | 触发时机 |
| --- | --- | --- | --- |
| 传统联想 | `PinyinEngine.predictNext(after:limit:)` | 词/短语（`IMECandidate`） | 上屏后 |
| 上下文联想 | `LocalSuggestionIndex.suggestions(...)` / `AISuggestionPrompt` | 完整一句话（`ContextualSuggestion`） | 每次按键（防抖后） |

### 9.1 两级策略

**L1 本地秒出（同步、主线程、<5ms、不联网）** — `LocalSuggestionIndex`

1. **学到的映射**（最近邻）：键 = 上下文末句的**后 2~4 个字**（`contextKeyLength = 4`），
   值 = 用户在该上下文之后上屏过的句子（`Entry{text, count, updatedAt}`）。
   查询时按「最长键优先」：末 4 字命中权重 1.0、末 3 字 0.96、末 2 字 0.92。
   学习入口是 `record(context:committed:)`（注意传入的是**生成候选时**的上下文，不是上屏后的）。
2. **内置模板兜底** — `ContextualSeedTemplates`（81 组规则 / 169 条候选短句）：
   取「能匹配上下文末尾的**最长**触发词」那一组，命中即用（长触发词更具体，避免混组）。
   置信度 = `rule.confidence * 0.92`。

产出 **0~2 条**（`AISuggestionPolicy.maximumLocalResults = 2`），宁可少不可错。
用户已经开始打拼音（`composing` 非空）时最多给 1 条且置信度 ×0.6，避免和常规拼音候选抢位。

内存与容量：最多 400 个上下文键（`maximumStoredKeys`），每键最多 6 条（`maximumEntriesPerKey`），
超出按 `updatedAt` 最旧淘汰。单键 6 条 × 400 键 ≈ 2400 条短句，实测占用 < 400KB。
持久化键 `moyu.ime.contextual.v1`，只经 `SharedStore.data/setData`，写失败静默（联想记忆丢了不影响输入）。

**L2 AI 覆盖（异步、流式、可取消、失败静默降级）** — `AISuggestionPrompt` + UI 侧调度器

内核只提供**纯函数**（不 import Networking、不发请求）：
- `AISuggestionPrompt.systemPrompt`：约束模型「像真人发消息、≤20 字、直接给句子、不要解释」；
- `AISuggestionPrompt.userMessage(context:composing:tone:count:)`：拼出含
  `【上下文】/【最近一句】/【我正在输入】/【语气】` 四段的用户消息，并明确要求「恰好 N 条，每条一行，行首 1. 2. 3.」；
- `AISuggestionPrompt.parse(_:limit:)`：把模型返回解析成 `[ContextualSuggestion]`，容错 `1.`/`1、`/`1)`/`（1）`、
  行内多编号（`1.好的 2.不行`）、分号分隔、Markdown 围栏、包裹引号、结尾句号；丢弃空行、>32 字的长句与重复项。

**调度参数集中在 `AISuggestionPolicy`**，UI 层按它实现即可，不要散落魔法数字：

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `debounceInterval` | 0.4s | 连续打字期间不发请求；静默超过 0.4s 才发（防抖） |
| `requestTimeout` | 3.5s | 超时直接放弃，**不显示错误、不打扰用户** |
| `maximumAIResults` | 3 | L2 最多 3 条 |
| `maximumLocalResults` | 2 | L1 最多 2 条 |
| `maximumContextCharacters` | 200 | 只送上下文末尾 200 字，省 token |
| `minimumQueryCharacters` | 2 | 上下文末句或组字不足 2 字不发请求 |
| `isQueryable(context:composing:)` | — | 上面的准入判断，UI 发请求前先问它 |

### 9.2 降级路径（UI 层责任，内核已提供全部零件）

| 情况 | 行为 |
| --- | --- |
| 未配置 AI 服务商 / 无完全访问 | **只跑 L1**，不报错、不提示（L1 完全离线可用） |
| L2 请求中 / 已超时 | 保留 L1 结果，候选栏不清空、不闪烁 |
| L2 返回 0 条 / 解析失败 | 保留 L1 结果（`parse` 返回空数组，不要用空数组覆盖 L1） |
| L2 返回 >3 条 | 交给 `parse(_:limit: 3)` 截断，按置信度排序后取前 3 |
| 新的按键到达 | **先 `cancel()` 旧任务再发新请求**（内核不持任务句柄，由 UI 的 `Task` 管理） |
| 词库缺失（内置兜底） | L1 仍可用（模板在代码里，不依赖 `dict/` 文件） |

### 9.3 调用示例

```swift
// L1：每次按键后同步调用（<5ms，可在主线程）
let local = kit.contextualSuggestions(context: documentContextBeforeInput ?? "", composing: composing)

// L2：防抖 0.4s 后发请求，3.5s 超时
if AISuggestionPolicy.isQueryable(context: context, composing: composing) {
    let messages = [
        ChatMessage(role: .system, content: AISuggestionPrompt.systemPrompt),
        ChatMessage(role: .user, content: AISuggestionPrompt.userMessage(
            context: context, composing: composing, tone: "日常聊天", count: 3))
    ]
    let raw = try await client.complete(ChatRequest(messages: messages)).text
    let ai = AISuggestionPrompt.parse(raw, limit: AISuggestionPolicy.maximumAIResults)
}

// 用户点了上下文联想候选后（L1 学习）
kit.recordContextualCommit(context: context, committed: chosen.text)
```

### 9.4 自测清单（macOS / Xcode 单测）

```swift
// L1 模板命中
let store = SharedStore.shared
let index = LocalSuggestionIndex(store: store)
index.reset()
assert(index.suggestions(context: "在吗", composing: "", limit: 2).first?.text == "在的")
assert(index.suggestions(context: "谢谢你", composing: "", limit: 2).first?.text == "不客气")
assert(index.suggestions(context: "明天几点到？", composing: "", limit: 2).first?.text == "我大概十点到")
// 末句截取与去标点
assert(LocalSuggestionIndex.lastSentence("好的。明天几点到？") == "明天几点到")
assert(LocalSuggestionIndex.lastSentence("嗯嗯！！") == "嗯嗯")
assert(LocalSuggestionIndex.lastSentence("") == "")
// 组字中降低供给、不抢位
assert(index.suggestions(context: "在吗", composing: "wo", limit: 2).count <= 1)
// 学到映射后局部优先
index.record(context: "明天几点到", committed: "我九点半到")
assert(index.suggestions(context: "明天几点到", composing: "", limit: 1).first?.text == "我九点半到")
assert(index.learnedKeyCount >= 1)
index.reset()
assert(index.learnedKeyCount == 0)
// L2 prompt 与解析
let message = AISuggestionPrompt.userMessage(context: "明天几点到？", composing: "", tone: "", count: 3)
assert(message.contains("明天几点到"))
assert(message.contains("3 条"))
let parsed = AISuggestionPrompt.parse("1. 我十点到\n2. 可能晚一点\n3. 十点前吧", limit: 3)
assert(parsed.count == 3)
assert(parsed.first?.text == "我十点到")
assert(parsed.allSatisfy { $0.source == .ai })
// 容错：编号样式杂乱、行内多编号、Markdown 围栏、引号
assert(AISuggestionPrompt.parse("1、好的 2、不行", limit: 2).map(\.text) == ["好的", "不行"])
assert(AISuggestionPrompt.parse("```\n1. 好的\n```", limit: 1).map(\.text) == ["好的"])
assert(AISuggestionPrompt.parse("“我马上到”", limit: 1).first?.text == "我马上到")
assert(AISuggestionPrompt.parse("", limit: 3).isEmpty)
assert(AISuggestionPrompt.parse("1. 好的", limit: 0).isEmpty)
```

预期输出：以上断言全部通过（`0 failures`）。L1 侧不依赖 `dict/` 文件，词库缺失时也能跑通。

复杂度：L1 单次查询 = 最多 3 次字典查找 + 最多 81 条规则的 `hasSuffix` 比较（规则按触发词长度降序，
命中即 `break`），实测远低于 5ms 预算；L2 无本地 CPU 开销（纯字符串拼接与解析）。

## 10. 词库自检与诊断

这一节是**排查「键盘打不出中文 / 候选很少」的标准动作**。词库加载失败时 `PinyinDictionary`
不会抛异常、不会崩溃，而是静默退回内置的 50 条极小词表（`builtinSeedEntries()`）——所以
「不报错但没中文」的唯一现场证据，就是这一节拿到的来源与路径。

### 10.1 API 速查（`IMEKit`）

| 成员 | 类型 | 正常值 | 说明 |
| --- | --- | --- | --- |
| `dictionaryVersion` | `String` | `"1.0.0"` | 来自 `dict_meta.json` 的 `version`；兜底时为 `"0.0.0-builtin"` |
| `wordCount` | `Int` | `5276` | 词条总数；兜底时为 `50` |
| `loadDurationMilliseconds` | `Double` | `10~40` | 加载耗时（首次 `bundled()` 时计时） |
| `dictionarySource` | `DictionarySource` | `.bundled` | `.bundled` / `.builtin` / `.memory` |
| `isUsingBuiltinDictionary` | `Bool` | `false` | **`true` 就是异常**（词库没打进 Bundle） |
| `dictionaryRelativePath` | `String` | `"dict/base_dict.tsv"` | Bundle 内相对路径；兜底时 `"<builtin>"` |
| `diagnosticsSummary` | `String` | 见 §10.5 | 一行中文摘要，含来源与路径，可直接上屏展示 |

### 10.2 扩展（`.appex`）里怎么取

⚠️ 扩展里的 `Bundle.main` 是 **`.appex` 自己**，不是宿主 App。扩展必须自带一份 `dict/`，
否则 `PinyinDictionary` 一定回退内置词表。两个 Bundle 各带一份、各自独立判断。

**路径 A（零改动，当前可直接用）**：`KMInputEngine` 已经把 `diagnosticsSummary` 转发出来了。

```swift
// ios/AIKeyboardExtension/ViewModel/KeyboardViewModel.swift
public func activate() {
    engine.prepare(clipboardEnabled: snapshot.enableClipboardHistory)
    dictionarySummary = engine.diagnosticsSummary   // ← 已含「来源」「路径」两段
}
```

**路径 B（需要结构化字段时，在 `KMInputEngine` 补三行转发）**：这三个属性目前**只在 `IMEKit`
上**，`KMInputEngine` 尚未转发；补上后 `KeyboardViewModel` / `ExtensionSettingsSheet` 就能直接用。

```swift
// ios/AIKeyboardExtension/IME/KMInputEngine.swift —— 追加到「诊断」区（:151-171 那段）
var dictionarySource: IMEKit.DictionarySource { kit.dictionarySource }
var isUsingBuiltinDictionary: Bool { kit.isUsingBuiltinDictionary }
var dictionaryRelativePath: String { kit.dictionaryRelativePath }
```

```swift
// 在设置页 / 诊断卡里判断并给用户看
if engine.isUsingBuiltinDictionary {
    statusText = "⚠️ 词库未打进安装包（当前仅内置 50 条）"
} else {
    statusText = "词库正常：\(engine.wordCount) 条 · \(engine.dictionaryRelativePath)"
}
```

### 10.3 宿主 App 里怎么取

宿主 App 与扩展是**两个进程、两份内存**，要各查各的。App 侧不需要新建 `IMEKit`（`IMEKit` 会连带
建 `UserLearningStore` / `PhraseLibrary` / `ClipboardHistory`，没必要），直接读 `PinyinDictionary`
的 `loadedPath` 即可——`loadedPath` 是 `public` 的：

```swift
// ios/AIKeyboard/Support/SharedBridge.swift —— DictionaryInfo.current() 的建议实现
static func current() -> DictionaryInfo? {
    let dictionary = PinyinDictionary.bundled()
    guard dictionary.wordCount > 0 else { return nil }
    return DictionaryInfo(version: dictionary.version,
                          wordCount: dictionary.wordCount,
                          // 一行判据：兜底时 loadedPath == "<builtin>"，正常时是真实文件路径
                          isBuiltin: dictionary.loadedPath == "<builtin>")
}
```

如果希望和 `IMEKit` 的判据（包含 `.memory` 分支）完全一致，也可以直接用门面：

```swift
// SharedStore.init 是 internal，宿主 App 里只能用共享单例（同一 target 内可直接 .shared）
let kit = IMEKit(store: SharedStore.shared)
if kit.isUsingBuiltinDictionary {
    // 提示用户：词库没打进安装包
}
```

### 10.4 判据与提示文案

| 判据 | 含义 | 建议给用户的提示 |
| --- | --- | --- |
| `dictionarySource == .bundled` 且 `wordCount > 1000` | 正常 | 不需要提示，诊断页显示摘要即可 |
| `isUsingBuiltinDictionary == true`（`wordCount == 50`、`version == "0.0.0-builtin"`） | **词库文件没被打进当前 Bundle** | 「词库未打进安装包（仅内置 50 条），请在 Xcode 的 Extension target → Build Phases → Copy Bundle Resources 里确认 `dict`（folder reference）已加入」 |
| `dictionarySource == .bundled` 但 `wordCount < 1000` | 打进去的是残缺词库 | 「词库文件异常（条数不足），请重新生成并重新打包」 |
| `dictionarySource == .memory` | 内存构造（单测 / 调试） | 仅测试环境出现，线上出现即异常 |

判定顺序建议固定为：先看 `dictionarySource`，再看 `wordCount`，最后才看 `loadDurationMilliseconds`。
**耗时长短不影响正确性**（首字母索引构建在启动同步完成，只有大小之分），不必据此报警。

### 10.5 真机应看到的文案样例

正常（词库打进 App 与 Expansion 两边）：

```text
词库 v1.0.0｜5276 条｜来源：打包词库｜路径：dict/base_dict.tsv｜加载 12.3ms
```

异常（回退内置 50 条——这就是「键盘打不出中文」的现场证据）：

```text
词库 v0.0.0-builtin｜50 条｜来源：⚠️ 内置兜底词库｜路径：<builtin>｜加载 0.4ms
```

内存构造（仅单测）：

```text
词库 vtest｜3 条｜来源：内存词库｜路径：<memory>｜加载 0.0ms
```

### 10.6 自检断言（macOS / Xcode 单测）

```swift
// 打包词库正常时（App 或 Extension 任一 target 内跑）
let kit = IMEKit(store: SharedStore.shared)
assert(kit.dictionarySource == .bundled)
assert(kit.isUsingBuiltinDictionary == false)
assert(kit.wordCount > 1000)
assert(kit.dictionaryRelativePath.hasSuffix("dict/base_dict.tsv"))
assert(kit.diagnosticsSummary.contains("来源：打包词库"))
assert(kit.diagnosticsSummary.contains("路径："))

// 兜底词表验证：词库文件缺失时必须退到内置表而不是崩溃
let builtin = PinyinDictionary(entries: PinyinDictionary.bundled().entries, version: "test")
assert(builtin.wordCount > 0)          // 内存构造走 .memory，不是 .builtin
assert(IMEKit.DictionarySource.memory.rawValue == "memory")

// 词库缺失时的兜底行为（在临时目录构造空 URL 即可模拟）
let missing = PinyinDictionary(dictionaryURL: URL(fileURLWithPath: "/tmp/__no_such_dict__.tsv"))
assert(missing.loadedPath == "<builtin>")
assert(missing.wordCount == 50)
```

预期输出：以上断言全部通过（`0 failures`）。最后两条用于验证「词库文件不存在时不会崩、会安静降级」。

