//
//  PinyinEngine.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：把用户按键产生的拼音串转换为候选词序列——支持全拼、简拼、混拼、多音节
//            动态规划切分、前缀预测、多词组合、模糊音兜底、英文/数字直通，并按"词频 + 用户习惯 +
//            最近使用 - 长度惩罚"综合排序（契约 §4.6）。
//  依赖：Foundation、PinyinDictionary、PinyinSyllables、UserLearningStore、PhraseSuggestionIndex、
//        FuzzyPinyin（模糊音变体与命中收集）
//  使用方：keyboard-ui 的 KeyboardViewModel、IMEKit
//

import Foundation

/// 拼音候选引擎（线程安全：候选计算无共享可变状态，短语索引惰性初始化有锁保护）。
public final class PinyinEngine {

    // MARK: - 排序权重（docs/02 §4.6 排序公式）

    /// 词频权重（对数词频的系数）。
    private static let frequencyWeight = 1.0

    /// 用户习惯权重（与 `UserLearningStore.weight(for:)` 相乘）。
    private static let userWeight = 6.0

    /// 最近使用权重（与 `UserLearningStore.recentBoost(for:)` 相乘）。
    private static let recentWeight = 8.0

    /// 长度惩罚系数（每超出一个字扣分，抑制长词过度抢先）。
    private static let lengthPenalty = 0.35

    /// 组合切分时单个词块允许的最大拼音长度。
    private static let maxTileLength = 24

    /// 组合切分时「每多切一个词块」的代价（DP 惩罚项）。
    ///
    /// DP 目标是最大化 `Σ log(freq+1)`，而单字词频远高于多字词（「在」727,915 vs
    /// 「现在」十几万），词库变大后会把长串切成一堆高频单字。减去固定代价后，
    /// 切 k 块要拿 k 个词的信息量补回 k×penalty，碎片路径就不再划算。
    /// 取值依据：`tools/dict/_probe_dp_penalty.py` 在 20 条长句上扫 0–15，14.0 正确率最高
    /// （16/20）——Python 复刻的 `COMPOSED_TILE_PENALTY` 必须与此值一致。
    private static let composedTilePenalty = 14.0

    /// 前缀预测最多展开的拼音键数量。
    private static let prefixKeyLimit = 40

    /// 简拼最多展开的首字母串长度（超长串不再按简拼处理，避免误命中）。
    private static let maxInitialsQueryLength = 6

    /// 模糊音命中降权系数（精确 1.0、模糊 0.85，约等于「词频低一个数量级」，
    /// 仍能排进候选栏但永远在精确命中之后）。
    private static let fuzzyDiscount = 0.85

    // MARK: - 依赖

    /// 词库。
    let dictionary: PinyinDictionary

    /// 用户学习数据。
    private let learning: UserLearningStore

    /// 保护短语联想索引的惰性初始化。
    private let indexLock = NSLock()

    /// 短语联想索引（首次预测时加载）。
    private var phraseIndex: PhraseSuggestionIndex?

    /// 短语联想索引是否已尝试加载（避免文件缺失时每次重试）。
    private var phraseIndexLoaded = false

    // MARK: - 初始化

    /// 创建候选引擎。
    /// - Parameters:
    ///   - dictionary: 已加载的拼音词库。
    ///   - learning: 用户学习数据（选词计频、最近使用、自造词）。
    public init(dictionary: PinyinDictionary, learning: UserLearningStore) {
        self.dictionary = dictionary
        self.learning = learning
    }

    // MARK: - 模糊音设置

    /// 当前生效的模糊音设置。
    ///
    /// 读写都直接落到进程内单例 `FuzzyPinyinSettings.shared`（单一真相源），因此
    /// 键盘内设置页改开关后引擎下一次取候选立即生效，无需重启键盘，也不会出现
    /// 「UI 显示已开、引擎还在用旧值」的两份状态。
    public var fuzzyOptions: FuzzyPinyinOptions {
        get { FuzzyPinyinSettings.shared.options }
        set { FuzzyPinyinSettings.shared.options = newValue }
    }

    // MARK: - 输入纠错开关

    /// 是否启用输入纠错（默认开启）。
    ///
    /// 纠错只在「原始输入无候选或候选 < 3 条」时兜底补几条 `[纠错]` 候选，不参与正常排序。
    /// `ConfigSnapshot.enableTypoCorrection` 接线后由调用方写入本属性即可关闭。
    public var isTypoCorrectionEnabled: Bool = true

    // MARK: - 候选生成

    /// 生成候选词。
    ///
    /// 处理顺序：自造词/学习词 → 全拼精确与前缀预测 → 简拼 → 多词组合切分 → 模糊音兜底
    /// （仅当精确候选不足时）→ 英文/数字直通，最后统一打分排序并截断。末尾 `1`–`9`
    /// 数字视为"选词序号"，不计入拼音匹配（UI 用 `selectionIndex(for:)` 取序号）。
    ///
    /// - Parameters:
    ///   - input: 用户当前输入串（拼音、英文或数字，含空格会被忽略）。
    ///   - limit: 最多返回的候选数，默认 30。
    /// - Returns: 按得分降序排列的候选数组；输入为空时返回空数组。
    public func candidates(for input: String, limit: Int = 30) -> [IMECandidate] {
        guard limit > 0 else { return [] }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let query = Self.stripTrailingSelection(trimmed)
        let normalized = Self.normalize(query)

        var pool: [String: Scored] = [:]
        pool.reserveCapacity(64)

        appendLearnedCandidates(normalized: normalized, into: &pool)
        if !normalized.isEmpty {
            appendDictionaryCandidates(normalized: normalized, into: &pool)
            appendInitialsCandidates(normalized: normalized, into: &pool)
            appendComposedCandidates(normalized: normalized, into: &pool)
            appendFuzzyCandidates(normalized: normalized, poolSize: pool.count, limit: limit, into: &pool)
        }
        let hasCandidates = !pool.isEmpty
        // 注意传 `query` 而不是 `trimmed`：末尾的数字是"选词序号"，不应把 `zhongguo2`
        // 整串当成英文候选塞进候选栏。
        appendEnglishCandidate(input: query, normalized: normalized, hasCandidates: hasCandidates, into: &pool)

        // 统一打分：log(freq+1)*w1 + 用户权重*w2 + 最近使用*w3 - 长度惩罚*w4
        var results: [IMECandidate] = []
        results.reserveCapacity(pool.count)
        for scored in pool.values {
            let frequencyTerm = Self.logScore(scored.frequency) * Self.frequencyWeight
            let userTerm = learning.weight(for: scored.text) * Self.userWeight
            let recentTerm = learning.recentBoost(for: scored.text) * Self.recentWeight
            let penalty = Double(max(0, scored.text.count - 1)) * Self.lengthPenalty
            let score = scored.base + frequencyTerm + userTerm + recentTerm - penalty
            results.append(IMECandidate(text: scored.text, pinyin: scored.pinyin, score: score, kind: scored.kind))
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.text.count != rhs.text.count { return lhs.text.count < rhs.text.count }
            if lhs.pinyin != rhs.pinyin { return lhs.pinyin < rhs.pinyin }
            return lhs.text < rhs.text
        }

        var trimmed = Array(results.prefix(limit))
        // 输入纠错：原始输入「无候选」或「候选过少」时，追加带 `[纠错]` 标记的候选到尾部。
        appendTypoCorrections(normalized: normalized, limit: limit, into: &trimmed)
        return trimmed
    }

    /// 上屏并记录选词（不在词库里的组合句/新词会自动沉淀为自造词）。
    ///
    /// - Parameters:
    ///   - candidate: 被选中的候选。
    ///   - input: 选词时的输入串。
    public func commit(_ candidate: IMECandidate, input: String) {
        learning.recordSelection(candidate: candidate, input: input)
        guard candidate.kind == .word || candidate.kind == .learned else { return }
        guard !candidate.text.isEmpty, !candidate.pinyin.isEmpty else { return }
        guard dictionary.frequency(of: candidate.text) == 0 else { return }
        learning.addUserPhrase(candidate.text, pinyin: candidate.pinyin)
    }

    /// 上屏后联想下一个词（先查短语库的"触发词 → 建议词"，不足时用最近使用补齐）。
    ///
    /// - Parameters:
    ///   - text: 已经上屏的文本（通常是整句或最后一个词）。
    ///   - limit: 最多返回的联想数。
    /// - Returns: 联想候选（`kind` 为 `.learned`），按相关度降序。
    public func predictNext(after text: String, limit: Int) -> [IMECandidate] {
        guard limit > 0 else { return [] }
        var results: [IMECandidate] = []
        var seen = Set<String>()
        results.reserveCapacity(limit)

        if let index = suggestionIndex() {
            for suggestion in index.suggestions(after: text, limit: limit) {
                guard !suggestion.text.isEmpty, seen.insert(suggestion.text).inserted else { continue }
                results.append(IMECandidate(text: suggestion.text, pinyin: suggestion.pinyin, score: 1.0, kind: .learned))
            }
        }

        guard results.count < limit else { return results }
        for (offset, phrase) in learning.recentPhrases(limit: limit * 2).enumerated() {
            guard results.count < limit else { break }
            guard seen.insert(phrase).inserted else { continue }
            let score = 0.5 - Double(offset) * 0.01
            results.append(IMECandidate(text: phrase, pinyin: "", score: score, kind: .learned))
        }
        return results
    }

    /// 末尾数字选词的序号（`zhongguo2` → 1，即第二候选）。
    ///
    /// UI 若自行处理数字选词可不调用；这里仅提供解析能力，`candidates(for:)` 已自动忽略该数字。
    ///
    /// - Parameter input: 原始输入串。
    /// - Returns: 从 0 开始的候选下标；没有末尾数字时返回 `nil`。
    public func selectionIndex(for input: String) -> Int? {
        let stripped = Self.stripTrailingSelection(input)
        guard stripped.count < input.count else { return nil }
        let digits = String(input.suffix(input.count - stripped.count))
        guard let value = Int(digits), value >= 1 else { return nil }
        return value - 1
    }

    // MARK: - 数据来源：学习词

    /// 收集自造词候选（精确命中 + 前缀预测）。
    private func appendLearnedCandidates(normalized: String, into pool: inout [String: Scored]) {
        guard !normalized.isEmpty else { return }
        for text in learning.userPhraseTexts() {
            guard let pinyin = learning.pinyin(forUserPhrase: text), !pinyin.isEmpty else { continue }
            if pinyin == normalized {
                insert(text: text, pinyin: pinyin, frequency: 0, base: 4.0, kind: .learned, into: &pool)
            } else if pinyin.hasPrefix(normalized) {
                let coverage = Double(normalized.count) / Double(max(pinyin.count, 1))
                insert(text: text, pinyin: pinyin, frequency: 0, base: 3.0 * coverage, kind: .learned, into: &pool)
            }
        }
    }

    // MARK: - 数据来源：词库（全拼 + 前缀）

    /// 收集全拼精确匹配与前缀预测候选。
    private func appendDictionaryCandidates(normalized: String, into pool: inout [String: Scored]) {
        // 1) 全拼精确匹配
        for entry in dictionary.exactEntries(pinyin: normalized, limit: 40) {
            insert(
                text: entry.text,
                pinyin: normalized,
                frequency: entry.frequency,
                base: 2.0,
                kind: Self.kind(for: entry),
                into: &pool
            )
        }

        // 2) 前缀预测：zhongg -> zhongguo/zhongguohua…（同时覆盖"末段用首字母的混拼"）
        let keys = dictionary.pinyinKeys(prefix: normalized, limit: Self.prefixKeyLimit)
        for key in keys where key != normalized {
            let coverage = Double(normalized.count) / Double(max(key.count, 1))
            for entry in dictionary.exactEntries(pinyin: key, limit: 2) {
                insert(
                    text: entry.text,
                    pinyin: key,
                    frequency: entry.frequency,
                    base: 1.0 * coverage,
                    kind: Self.kind(for: entry),
                    into: &pool
                )
            }
        }
    }

    // MARK: - 数据来源：简拼

    /// 收集简拼候选（`zg` -> 中国/这个…）。
    private func appendInitialsCandidates(normalized: String, into pool: inout [String: Scored]) {
        guard normalized.count >= dictionary.minimumInitialsLength,
              normalized.count <= dictionary.maximumInitialsLength,
              normalized.count <= Self.maxInitialsQueryLength
        else { return }

        let keys = dictionary.pinyinKeys(initials: normalized, limit: 24)
        for (offset, key) in keys.enumerated() {
            guard offset < 12 else { break }
            for entry in dictionary.exactEntries(pinyin: key, limit: 1) {
                let base = 0.6 - Double(offset) * 0.05
                insert(
                    text: entry.text,
                    pinyin: key,
                    frequency: entry.frequency,
                    base: base,
                    kind: Self.kind(for: entry),
                    into: &pool
                )
            }
        }
    }

    // MARK: - 数据来源：多词组合切分（DP）

    /// 收集"多词拼成一句"的候选（`woxihuanni` -> 我喜欢你）。
    ///
    /// 仅当整个输入串不是词库中的完整词条时才做组合，避免出现"先在"之类的无意义拼接。
    private func appendComposedCandidates(normalized: String, into pool: inout [String: Scored]) {
        guard normalized.count >= 2 else { return }
        guard dictionary.exactEntries(pinyin: normalized, limit: 1).isEmpty else { return }

        let chars = Array(normalized)
        let count = chars.count
        var best = [Double](repeating: -Double.infinity, count: count + 1)
        var back = [Int](repeating: -1, count: count + 1)
        var tileText = [String?](repeating: nil, count: count + 1)
        var tileLog = [Double](repeating: 0, count: count + 1)
        best[0] = 0

        for start in 0..<count {
            guard best[start].isFinite else { continue }
            let maxLength = min(Self.maxTileLength, count - start)
            guard maxLength > 0 else { continue }
            for length in 1...maxLength {
                let key = String(chars[start..<(start + length)])
                guard let entry = dictionary.exactEntries(pinyin: key, limit: 1).first else { continue }
                guard !entry.isEmoji, !entry.isPunctuation else { continue }
                guard Self.containsCJK(entry.text) else { continue }
                let logTerm = Self.logScore(entry.frequency)
                let score = best[start] + logTerm - Self.composedTilePenalty
                if score > best[start + length] {
                    best[start + length] = score
                    back[start + length] = start
                    tileText[start + length] = entry.text
                    tileLog[start + length] = logTerm
                }
            }
        }

        // 情况 A：整串都能切完
        if best[count].isFinite,
           let full = pathResult(end: count, back: back, tileText: tileText, tileLog: tileLog),
           full.tiles >= 2 {
            let base = full.sumLog / Double(full.tiles) + 1.2 * Double(full.tiles - 1) + 1.5
            insert(text: full.text, pinyin: normalized, frequency: 0, base: base, kind: .word, into: &pool)
        }

        // 情况 B：切到某个前缀后用前缀预测补齐最后一段（woxihuanzh -> 我喜欢 + 中/这…）
        var bestEnd = 0
        var bestScore = -Double.infinity
        for end in 1..<count where best[end].isFinite {
            if best[end] > bestScore {
                bestScore = best[end]
                bestEnd = end
            }
        }
        guard bestEnd > 0,
              let head = pathResult(end: bestEnd, back: back, tileText: tileText, tileLog: tileLog)
        else { return }

        let remainder = String(chars[bestEnd..<count])
        let keys = dictionary.pinyinKeys(prefix: remainder, limit: 6)
        for key in keys {
            for entry in dictionary.exactEntries(pinyin: key, limit: 1) {
                guard !entry.isEmoji, !entry.isPunctuation else { continue }
                guard Self.containsCJK(entry.text) else { continue }
                let base = head.sumLog / Double(head.tiles) + 0.6 + 0.4 * Double(head.tiles - 1)
                insert(
                    text: head.text + entry.text,
                    pinyin: normalized,
                    frequency: 0,
                    base: base,
                    kind: .word,
                    into: &pool
                )
            }
        }
    }

    // MARK: - 数据来源：模糊音兜底

    /// 收集模糊音候选（`zongguo` → 中国，`senme` → 什么）。
    ///
    /// 性能约束（整次按键 <2ms）：只在精确候选不足时展开（`poolSize >= limit` 挡掉绝大多数
    /// 按键）；变体由 `FuzzyPinyin.expand` 限流（≤24 个、按改动音节数升序），每变体最多 8 条
    /// 精确词 + 8 个前缀键；模糊命中统一乘 `fuzzyDiscount` 排在精确之后。
    /// - Parameters: `normalized` 已归一化输入；`poolSize` 当前候选池条目数；`limit` 候选上限。
    private func appendFuzzyCandidates(normalized: String,
                                       poolSize: Int,
                                       limit: Int,
                                       into pool: inout [String: Scored]) {
        let options = fuzzyOptions
        guard options.isActive else { return }
        guard normalized.count >= 2 else { return }
        guard poolSize < limit else { return }
        let matches = FuzzyPinyin.matches(for: normalized,
                                          rules: options.activeRules,
                                          dictionary: dictionary)
        guard !matches.isEmpty else { return }
        for match in matches {
            let base = match.isExact
                ? 2.0 * Self.fuzzyDiscount
                : 1.0 * match.coverage * Self.fuzzyDiscount
            insert(
                text: match.text,
                pinyin: match.pinyin,
                frequency: match.frequency,
                base: base,
                kind: .word,
                into: &pool
            )
        }
    }

    // MARK: - 数据来源：英文/数字直通

    /// 纯 ASCII 输入的直通候选。
    ///
    /// - 含数字：始终给出原样候选（如 `2333`、`3Q`）。
    /// - 纯字母：仅在没有中文候选时给出（如 `hello`），避免 `nihao` 冒出英文 `nihao`。
    private func appendEnglishCandidate(
        input: String,
        normalized: String,
        hasCandidates: Bool,
        into pool: inout [String: Scored]
    ) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) else { return }
        let hasDigits = trimmed.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        if !hasDigits && hasCandidates { return }

        let pinyin = normalized.isEmpty ? trimmed.lowercased() : normalized
        insert(
            text: trimmed,
            pinyin: pinyin,
            frequency: 0,
            base: hasDigits ? 3.0 : 2.2,
            kind: .english,
            into: &pool
        )
    }

    // MARK: - 短语联想索引

    /// 惰性加载短语联想索引。
    private func suggestionIndex() -> PhraseSuggestionIndex? {
        indexLock.lock()
        if phraseIndexLoaded {
            let cached = phraseIndex
            indexLock.unlock()
            return cached
        }
        indexLock.unlock()

        let created = PhraseSuggestionIndex()
        indexLock.lock()
        phraseIndex = created.suggestionCount > 0 ? created : nil
        phraseIndexLoaded = true
        let result = phraseIndex
        indexLock.unlock()
        return result
    }

    // MARK: - 内部工具

    /// 候选池中的一条（打分前的原始信息）。
    private struct Scored {
        /// 候选文本。
        var text: String
        /// 对应拼音。
        var pinyin: String
        /// 词频（组合候选为 0，其得分已计入 `base`）。
        var frequency: Int
        /// 来源加权（精确/前缀/简拼/组合/直通各不同）。
        var base: Double
        /// 候选类型。
        var kind: IMECandidate.Kind
    }

    /// 写入候选池（同文本取更优者）。
    private func insert(
        text: String,
        pinyin: String,
        frequency: Int,
        base: Double,
        kind: IMECandidate.Kind,
        into pool: inout [String: Scored]
    ) {
        guard !text.isEmpty else { return }
        let incoming = Scored(text: text, pinyin: pinyin, frequency: frequency, base: base, kind: kind)
        if let existing = pool[text] {
            let existingRank = existing.base + Self.logScore(existing.frequency)
            let incomingRank = incoming.base + Self.logScore(incoming.frequency)
            if incomingRank > existingRank {
                pool[text] = incoming
            }
        } else {
            pool[text] = incoming
        }
    }

    /// 从 DP 的 `back`/`tileText` 数组还原一条完整路径。
    ///
    /// `tileLog` 存的是每块**未扣惩罚**的对数词频——DP 分数已减过 `composedTilePenalty`，
    /// 这里若再用 `logScore(frequency)` 重算，情况 A/B 的 base 就会与 DP 口径不一致。
    private func pathResult(
        end: Int,
        back: [Int],
        tileText: [String?],
        tileLog: [Double]
    ) -> (text: String, tiles: Int, sumLog: Double)? {
        var pieces: [String] = []
        var sumLog = 0.0
        var cursor = end
        var steps = 0
        while cursor > 0 {
            steps += 1
            guard steps <= 64 else { return nil }
            let previous = back[cursor]
            guard previous >= 0, let piece = tileText[cursor] else { return nil }
            pieces.append(piece)
            sumLog += tileLog[cursor]
            cursor = previous
        }
        guard cursor == 0, !pieces.isEmpty else { return nil }
        return (Array(pieces.reversed()).joined(), pieces.count, sumLog)
    }

    /// 对数词频：`log(freq + 1)`，freq 为 0 时返回 0。
    private static func logScore(_ frequency: Int) -> Double {
        log(Double(max(frequency, 0)) + 1.0)
    }

    /// 词条类型映射（判定顺序：纯汉字 → `.word`；纯 ASCII 按有无字母数字分 `.english`/
    /// `.punctuation`；其余按 `emoji`/`punct` 标记归类）。
    private static func kind(for entry: DictionaryEntry) -> IMECandidate.Kind {
        if isPureCJK(entry.text) { return .word }
        if isPureASCII(entry.text) {
            let hasAlphanumeric = entry.text.unicodeScalars.contains { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            }
            return hasAlphanumeric ? .english : .punctuation
        }
        if entry.isEmoji { return .emoji }
        if entry.isPunctuation { return .punctuation }
        return .word
    }

    /// 是否为纯 ASCII 词条（拉丁字母/数字/半角符号）。
    private static func isPureASCII(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII }
    }

    /// 是否包含中日韩统一表意文字（用于过滤组合切分中的非中文词块）。
    private static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { return true }
        }
        return false
    }

    /// 是否为"纯汉字"词条（不含括号、标点、emoji、拉丁字母）。
    ///
    /// 用于候选类型判定：`（狗头）` 这类带括号的表达属于标点/颜文字，而 `万`、`开心` 属于普通词。
    private static func isPureCJK(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isCJK = (value >= 0x4E00 && value <= 0x9FFF) || (value >= 0x3400 && value <= 0x4DBF)
            if !isCJK { return false }
        }
        return true
    }

    /// 归一化：小写并只保留 ASCII 字母与数字。
    private static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.lowercased().unicodeScalars {
            let value = scalar.value
            if (value >= 97 && value <= 122) || (value >= 48 && value <= 57) {
                result.append(Character(scalar))
            }
        }
        return result
    }

    /// 去掉末尾用于选词的 1–9（最多 2 位），返回纯拼音部分。
    private static func stripTrailingSelection(_ text: String) -> String {
        guard let last = text.last, last.isNumber else { return text }
        var cut = text.endIndex
        while cut > text.startIndex {
            let previous = text.index(before: cut)
            guard text[previous].isNumber else { break }
            cut = previous
        }
        let digitCount = text.distance(from: cut, to: text.endIndex)
        guard digitCount <= 2 else { return text }
        let head = String(text[text.startIndex..<cut])
        guard !head.isEmpty else { return text }
        let headIsLetters = head.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && CharacterSet.letters.contains(scalar)
        }
        guard headIsLetters else { return text }
        return head
    }
}
