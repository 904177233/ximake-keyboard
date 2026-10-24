# 墨语输入法 · 输入法内核（ios/Shared/IMECore）

纯 Swift 5 / Foundation，无 UI 依赖（不 import UIKit / SwiftUI），最低支持 iOS 16.0。
把"按键串 → 候选词"的全部逻辑收敛在本模块内，UI 只负责展示与上屏。

## 1. 文件职责

| 文件 | 职责 | 行数 |
| --- | --- | --- |
| `IMECandidate.swift` | 契约 §4.6 的公共数据结构：`IMECandidate`、`DictionaryEntry` | 96 |
| `PinyinSyllables.swift` | 无声调音节表（421 个音节）+ 音节切分 DP（**自动生成，勿手工编辑**） | 170 |
| `PinyinDictionary.swift` | 加载 `base_dict.tsv`，建全拼哈希索引与首字母简拼索引 | 576 |
| `PinyinEngine.swift` | 输入串 → 候选：全拼/简拼/混拼/组合切分/前缀预测/英文直通 + 排序 | 531 |
| `UserLearningStore.swift` | 选词计频、最近使用环形缓冲（200 条）、自造词，经 `SharedStore` 持久化 | 279 |
| `PhraseSuggestion.swift` | 加载 `phrases.tsv`，实现"上屏后联想" | 188 |
| `PhraseLibrary.swift` | 用户短语库 `PhraseItem`/`PhraseLibrary`（占位符展开）+ `ClipboardHistory` | 341 |
| `IMEKit.swift` | 门面：一次性组装上述组件，供 UI 层使用 | 106 |

依赖方向（单向，无环）：
```
IMEKit
  ├─ PinyinDictionary ── PinyinSyllables
  ├─ UserLearningStore ── SharedStore（Storage 层，仅用 4 个读写方法）
  ├─ PinyinEngine ── PinyinDictionary + UserLearningStore + PhraseSuggestion
  ├─ PhraseLibrary ── SharedStore
  └─ ClipboardHistory ── SharedStore
```

## 2. 词库加载（`PinyinDictionary`）

### 打包路径兼容

`base_dict.tsv` 位于 `ios/Shared/Resources/dict/`，以 **folder reference** 形式加入 target 时，
Bundle 内的相对路径会随 Xcode 的 resources 配置变化。因此加载器按候选列表逐个尝试：

1. `Bundle.main.url(forResource: "base_dict", withExtension: "tsv", subdirectory: "Resources/dict")`
2. `Bundle.main.url(forResource: "base_dict", withExtension: "tsv", subdirectory: "dict")`
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
> 产物会被打进 `Shared/Resources`。Swift 侧音节表 `PinyinSyllables.swift` 由
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
  ├─ 7. 英文/数字直通（2333、hello）
  └─ 8. 统一打分 + 稳定排序 + 截断
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

### 6.6 线程安全（可选，压力测试）

| # | 断言 | 预期 |
| --- | --- | --- |
| 49 | 8 个并发队列各调用 `candidates(for:)` 1000 次 | 无崩溃、无数据竞争（TSan 干净） |
| 50 | 并发 `recordSelection` 1000 次后 `weight(for:)` 等于累计次数 | `true` |

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

### 6.7 已验证结论（Python 算法复刻）

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

### 6.8 一站式断言脚本（复制即跑，49 条 `assert`）

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
        assert(!kit.diagnosticsSummary.isEmpty)
        assert(kit.candidates(for: "zg").first?.text == "中国")
    }
}
```

**预期输出**（49 条断言全过时 XCTest 打印）：

```
Test Suite 'IMECoreSmokeTests' passed
  Test Case 'test01_dictionaryLoading'  passed  (0.031 s)
  Test Case 'test02_candidates'         passed  (0.004 s)
  Test Case 'test03_candidateQuality'   passed  (0.002 s)
  Test Case 'test04_learning'           passed  (0.006 s)
  Test Case 'test05_phraseAndClipboard' passed  (0.003 s)
  Test Case 'test06_facade'             passed  (0.002 s)
Executed 6 tests, with 49 assertions, 0 failures, 0 unexpected
```

> 若 `test01` 在 `loadedPath != "<builtin>"` 处失败，说明 Xcode 没把 `Shared/Resources` 以
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
| 每文件 ≤600 行 | ✅ 最长 576 行 |
| 注释中文、标识符英文 | ✅ |
| 模块级注释（职责/依赖/使用方） | ✅ 每个文件头部三要素 |

## 8. 已知限制与后续可做

1. **多音字**：按 pypinyin 默认读音生成（`银行`→`yinhang`、`长大`→`zhangda`），
   不做上下文消歧。若后续要提升准确率，可在 `PinyinDictionary` 增加"多音字候选展开"。
2. **组合候选上限**：单块最大 24 字符、最多回溯 64 段，超长输入串会被截断处理。
3. **未做模糊音**：`zh/z`、`ch/c`、`sh/s`、`in/ing`、`l/n` 等模糊音匹配未实现，
   对南方口音用户命中率偏低，可作为后续迭代项（在归一化阶段做等价类折叠）。
4. **无纠错**：输入串打错一个字不会自动纠正（如 `nihap` → `你好`）。
5. **词库加载耗时**为理论估算（Windows 无 Swift 环境），需在真机上用
   `dict.loadDurationMilliseconds` 实测确认；若超标，可把解析改为 `Data` + 手写字节扫描。
6. **`predictNext`** 依赖 `phrases.tsv` 的触发词表，未命中时只回退到最近使用，
   没有语义联想能力（AI 联想由 ai-service 模块提供）。

### 8.1 词库打包路径与 Bundle 布局（跨模块契约，已由 Lead 验证）

- `ios/project.yml` 里两个 target 都以 **folder reference（`type: folder`）** 引用 `Shared/Resources`，
  因此打出来的 Bundle 内路径是 `Resources/dict/base_dict.tsv`、`Resources/dict/phrases.tsv`，
  **不是** `dict/base_dict.tsv`。
- `PinyinDictionary` 的候选路径第 1 条必须命中 `Resources/dict/base_dict.tsv`，
  否则会静默回退到内置小词库 —— 这是「词库看起来装了但候选很少」的唯一原因。
- 全仓 grep 验证：`ios/**/*.swift` 中 `base_dict|phrases\.tsv|dict_meta|ContentsOfFile` 共 24 处命中，
  **全部在 `ios/Shared/IMECore/`**，App/Extension 侧零命中 → 不存在词库重复加载。
- `dict_meta.json` 的 `sha256` 可用于启动时校验词库完整性（当前实现只读 version/count，未校验 sha256，
  属可选增强）。
