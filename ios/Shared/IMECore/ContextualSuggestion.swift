//
//  ContextualSuggestion.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：上下文联想（ContextualSuggestion）的「数据模型 + L1 本地实现」。
//            `ContextualSuggestion`：一条「下一句」候选（完整短句，点一下整条上屏）；
//            `AISuggestionPolicy`：L2 的防抖/超时/条数参数与准入判断；
//            `LocalSuggestionIndex`：L1，纯本地、同步、无网络，主线程秒出（<5ms）。
//            L2 的提示词构造与结果解析在 `AISuggestionPrompt.swift`。
//  依赖：Foundation、SharedStore（仅 data(forKey:)/setData(_:forKey:)）、ContextualSeedTemplates
//  使用方：keyboard-ui（候选栏「下一句」区）、IMEKit（门面转发）
//

import Foundation

/// 一条上下文联想候选：完整短句，点一下整条上屏。
///
/// 与 `IMECandidate` 的区别：
/// - `IMECandidate` 是「拼音 → 词」，用于候选栏的常规候选；
/// - `ContextualSuggestion` 是「上下文 → 下一句」，用于候选栏的联想区，
///   文本是完整的一句话，不参与拼音组字，点选后直接上屏。
public struct ContextualSuggestion: Identifiable, Equatable, Sendable {

    /// 候选来源。
    public enum Source: String, Sendable {
        /// L1 本地索引（秒出、不联网、离线可用）。
        case local
        /// L2 云端模型（异步、可取消，失败静默降级到 L1）。
        case ai
    }

    /// 稳定标识（同一来源下的同一条文本 id 不变，可直接用于 SwiftUI `ForEach`）。
    public let id: String

    /// 完整上屏文本（一句话，不是单词）。
    public let text: String

    /// 来源。
    public let source: Source

    /// 置信度（0...1，候选栏按此降序排列）。
    public let confidence: Double

    /// 创建一条候选（显式指定 id）。
    /// - Parameters:
    ///   - id: 稳定标识。
    ///   - text: 完整上屏文本。
    ///   - source: 来源。
    ///   - confidence: 置信度（0...1）。
    public init(id: String, text: String, source: Source, confidence: Double) {
        self.id = id
        self.text = text
        self.source = source
        self.confidence = confidence
    }

    /// 创建一条候选（id 由「来源 + 文本」自动生成）。
    /// - Parameters:
    ///   - text: 完整上屏文本。
    ///   - source: 来源。
    ///   - confidence: 置信度（0...1）。
    public init(text: String, source: Source, confidence: Double) {
        self.init(id: source.rawValue + ":" + text,
                  text: text,
                  source: source,
                  confidence: confidence)
    }
}

/// L2（AI）联想的运行参数与准入判断（纯常量 + 纯函数，供 UI 调度器读取，避免魔法数字散落各处）。
///
/// 使用约定（keyboard-ui 侧）：
/// 1. 用户每敲一个字符都重置一个 `debounceInterval` 的定时器，只有静默超过它才发请求；
/// 2. 新请求发出前必须 `cancel()` 旧任务（避免旧响应覆盖新结果）；
/// 3. 请求超过 `requestTimeout` 直接放弃，**不显示错误、不打扰用户**；
/// 4. 请求失败 / 超时 / 结果为空时保持 L1 的结果，不要清空候选栏。
public enum AISuggestionPolicy {

    /// 防抖间隔（秒）：连续打字期间不发请求，静默超过该值才请求。
    public static let debounceInterval: TimeInterval = 0.4

    /// 单次请求超时（秒）：超时直接放弃，静默降级到 L1。
    public static let requestTimeout: TimeInterval = 3.5

    /// L2 最多返回条数。
    public static let maximumAIResults = 3

    /// L1 最多返回条数（宁可少不可错）。
    public static let maximumLocalResults = 2

    /// 送给模型的上下文最大字符数（只要末尾，避免 token 浪费）。
    public static let maximumContextCharacters = 200

    /// 触发联想所需的最短上下文（或组字）字符数，太短没有语义、白白耗流量。
    public static let minimumQueryCharacters = 2

    /// 是否值得发起 L2 请求（上下文足够长，或用户已经打了一段拼音）。
    /// - Parameters:
    ///   - context: 输入框里光标前的文本（宿主 `documentContextBeforeInput`）。
    ///   - composing: 当前正在组字的拼音串。
    /// - Returns: 值得请求返回 `true`。
    public static func isQueryable(context: String, composing: String) -> Bool {
        let sentence = LocalSuggestionIndex.lastSentence(context)
        if sentence.count >= minimumQueryCharacters {
            return true
        }
        let trimmedComposing = composing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedComposing.count >= minimumQueryCharacters
    }
}

/// 纯本地、同步、无网络依赖的 L1 提供者。
///
/// 算法（两级匹配，均为 O(1)/O(规则数)，实测远低于 5ms）：
/// 1. **学到的映射**：以「上下文末句的后 2~4 个字」为键，查 `record(context:committed:)` 累积的
///    「这个上下文之后我说过什么」；最长键优先，命中即用（更精确的上下文优先）。
/// 2. **内置模板兜底**：没学过时用 `ContextualSeedTemplates` 的 81 组触发词，
///    取「能匹配上下文末尾的最长触发词」那一组，产出该组的候选短句。
///
/// 线程模型：内部 `NSLock` 保护，可从任意线程调用；`suggestions` 只做内存查表，不碰磁盘。
public final class LocalSuggestionIndex: @unchecked Sendable {

    // MARK: - 常量

    /// 学到的映射最多保留多少个「上下文键」（超出按最近使用淘汰）。
    public static let maximumStoredKeys = 400

    /// 每个上下文键最多保留多少条后续句。
    public static let maximumEntriesPerKey = 6

    /// 上下文键长度（取末句尾部这么多字，作为「最近邻」指纹）。
    public static let contextKeyLength = 4

    /// 上下文键最短长度（末句不足 4 字时退化为 2~3 字键）。
    public static let minimumContextKeyLength = 2

    /// 末句截断长度（只要最后一句，避免上下文越长越慢）。
    public static let maximumSentenceCharacters = 32

    /// 一条候选文本的最大长度（超过视为噪声，不学、不推荐）。
    public static let maximumReplyCharacters = 60

    /// 持久化键。
    private enum Keys {
        static let contextual = "moyu.ime.contextual.v1"
    }

    // MARK: - 持久化载体

    /// 一条学到的「之后我说过的话」。
    private struct Entry: Codable {
        /// 上屏文本。
        var text: String
        /// 被选中次数。
        var count: Int
        /// 最近一次时间戳（秒）。
        var updatedAt: TimeInterval
    }

    /// 落盘结构（JSON）。
    private struct Persisted: Codable {
        /// 上下文键 → 候选列表（按 count、updatedAt 降序）。
        var entries: [String: [Entry]]
    }

    // MARK: - 内存状态

    private let store: SharedStore
    private let lock = NSLock()

    /// 上下文键 → 候选列表。
    private var entries: [String: [Entry]]

    /// 内置模板（按触发词长度降序，长触发词更具体、优先命中）。
    private let seedRules: [ContextualSeedTemplates.Rule]

    // MARK: - 初始化

    /// 创建本地联想索引。
    /// - Parameter store: 共享存储容器（App 与键盘扩展共用；内存降级时自动只在内存里工作）。
    public init(store: SharedStore) {
        self.store = store
        var loaded: [String: [Entry]] = [:]
        if let data = store.data(forKey: Keys.contextual),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded = decoded.entries
        }
        self.entries = loaded
        self.seedRules = ContextualSeedTemplates.rules.sorted { lhs, rhs in
            if lhs.trigger.count != rhs.trigger.count {
                return lhs.trigger.count > rhs.trigger.count
            }
            return lhs.confidence > rhs.confidence
        }
    }

    // MARK: - 契约 API

    /// 记录一次上屏，用于学习「上下文 → 下一句」。
    ///
    /// 调用时机：用户点选了**上下文联想**候选并上屏之后。
    /// 注意 `context` 必须是「当时用来生成候选的那段上下文」，
    /// 而不是上屏之后再从输入框读到的文本（后者已经包含刚上屏的内容，会把映射学歪）。
    /// - Parameters:
    ///   - context: 生成候选时使用的上下文（宿主 `documentContextBeforeInput`）。
    ///   - committed: 实际上屏的文本。
    public func record(context: String, committed: String) {
        let reply = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply.count <= Self.maximumReplyCharacters else { return }
        let sentence = Self.lastSentence(context)
        guard sentence.count >= Self.minimumContextKeyLength else { return }
        let key = Self.contextKey(for: sentence)
        guard !key.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        lock.lock()
        var bucket = entries[key] ?? []
        if let existing = bucket.firstIndex(where: { $0.text == reply }) {
            bucket[existing].count += 1
            bucket[existing].updatedAt = now
        } else {
            bucket.append(Entry(text: reply, count: 1, updatedAt: now))
        }
        bucket.sort { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        if bucket.count > Self.maximumEntriesPerKey {
            bucket.removeLast(bucket.count - Self.maximumEntriesPerKey)
        }
        entries[key] = bucket
        trimIfNeededLocked()
        let snapshot = Persisted(entries: entries)
        lock.unlock()

        persist(snapshot)
    }

    /// 本地秒出候选（同步、主线程安全，必须 <5ms）。
    ///
    /// 产出 0~2 条（`limit` 再大也不会超过 2），宁可少不可错。
    /// 当 `composing` 非空（用户已经开始打拼音）时最多给 1 条并降低置信度，
    /// 避免和常规拼音候选抢位置、造成误触。
    /// - Parameters:
    ///   - context: 输入框里光标前的文本（取末句参与匹配）。
    ///   - composing: 当前正在组字的拼音串（可为空）。
    ///   - limit: 上层最多要几条。
    /// - Returns: 按置信度降序的候选数组。
    public func suggestions(context: String, composing: String, limit: Int) -> [ContextualSuggestion] {
        guard limit > 0 else { return [] }
        let sentence = Self.lastSentence(context)
        guard sentence.count >= Self.minimumContextKeyLength else { return [] }

        let composingText = Self.normalizedComposing(composing)
        let isComposing = !composingText.isEmpty
        var budget = min(limit, AISuggestionPolicy.maximumLocalResults)
        if isComposing {
            budget = min(budget, 1)
        }
        guard budget > 0 else { return [] }
        let discount = isComposing ? 0.6 : 1.0

        var results: [ContextualSuggestion] = []
        var seen: Set<String> = []
        results.reserveCapacity(budget)

        // 1) 先查「学到的」映射（最近邻：最长键优先）。
        lock.lock()
        let learned = lookupLocked(for: sentence)
        lock.unlock()
        for item in learned {
            if results.count >= budget {
                break
            }
            let text = item.entry.text
            guard text != sentence, seen.insert(text).inserted else { continue }
            let base = 0.82 + min(0.12, Double(item.entry.count) * 0.04)
            let confidence = min(0.99, base * item.weight * discount)
            results.append(ContextualSuggestion(text: text, source: .local, confidence: confidence))
        }

        // 2) 再用内置模板兜底（只取最长命中的那一组，避免不同触发词的建议混在一起）。
        //    注意：这里**不能**排除「触发词 == 整句」的情况——「在吗」「谢谢你」这类最常见的
        //    上下文本身就是触发词，排除掉会让 L1 几乎永远命中不了；重复上屏由下面的 text != sentence 挡住。
        //    触发词比对面稍宽：末句尾部的语气词（啊/呀/呢/吧…）会先被剥掉再比，见 `triggerMatches`。
        if results.count < budget {
            for rule in seedRules {
                guard Self.triggerMatches(sentence: sentence, trigger: rule.trigger) else { continue }
                for raw in rule.texts {
                    if results.count >= budget {
                        break
                    }
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text != sentence, seen.insert(text).inserted else { continue }
                    let confidence = min(0.95, rule.confidence * 0.92 * discount)
                    results.append(ContextualSuggestion(text: text,
                                                        source: .local,
                                                        confidence: confidence))
                }
                break
            }
        }

        // 稳定排序：置信度降序；置信度相同时**保持生成时的顺序**（模板里排在前面的候选更口语，
        // 学到的候选按 count/updatedAt 已排好）。Swift 的 sort 不保证稳定，故显式带上序号。
        let ordered = results.enumerated()
            .map { (offset: $0.offset, item: $0.element) }
            .sorted { lhs, rhs in
                if lhs.item.confidence != rhs.item.confidence {
                    return lhs.item.confidence > rhs.item.confidence
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.item }
        if ordered.count > budget {
            return Array(ordered.prefix(budget))
        }
        return ordered
    }

    // MARK: - 诊断

    /// 已学到的上下文键数量（诊断页展示用）。
    public var learnedKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// 内置模板规则数（诊断页展示用）。
    public var seedRuleCount: Int {
        seedRules.count
    }

    /// 清空本地联想记忆（设置页「清除联想记忆」）。
    public func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        store.setData(nil, forKey: Keys.contextual)
    }

    // MARK: - 文本归一化（L1 与 L2 共用）

    /// 取上下文中的最后一句（去掉尾部标点，最多 `maximumSentenceCharacters` 字）。
    ///
    /// 例：`"好的。明天几点到？"` → `"明天几点到"`；`"嗯嗯！！"` → `"嗯嗯"`；
    /// `"多行\n第二行"` → `"第二行"`。
    /// - Parameter context: 光标前的原始上下文。
    /// - Returns: 末句（已去掉尾部空白与标点）；无有效内容时返回空串。
    public static func lastSentence(_ context: String) -> String {
        var text = context
        while let last = text.last, isIgnorable(last) {
            text.removeLast()
        }
        guard !text.isEmpty else { return "" }

        var buffer: [Character] = []
        buffer.reserveCapacity(maximumSentenceCharacters)
        for character in text.reversed() {
            if isSentenceTerminator(character) {
                if buffer.isEmpty {
                    continue
                }
                break
            }
            buffer.append(character)
            if buffer.count >= maximumSentenceCharacters {
                break
            }
        }
        var sentence = String(buffer.reversed())
        while let last = sentence.last, isIgnorable(last) {
            sentence.removeLast()
        }
        return sentence
    }

    /// 归一化组字串（小写、去首尾空白）。
    /// - Parameter composing: 原始拼音串。
    /// - Returns: 归一化结果。
    static func normalizedComposing(_ composing: String) -> String {
        composing.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 句末语气词：真人聊天几乎不会完整打出「怎么办」，多半是「怎么办啊」。
    ///
    /// 这些字只在**句尾**被剥掉，且必须剩下比触发词更长的部分，避免把
    /// 「好啊」剥成「好」这种把短句削没的情况。
    static let sentenceFinalParticles: Set<Character> = [
        "啊", "呀", "呢", "吧", "嘛", "哦", "啦", "咯", "呐", "哈"
    ]

    /// 判断末句是否命中某个触发词（允许句尾带语气词）。
    ///
    /// 为什么不在模板里把 `谢谢` / `谢谢啊` / `谢谢呀` 各写一条：那是 3 倍的维护成本，
    /// 而且永远补不全（`呢`/`啦`/`咯`…）。把语气词剥掉统一处理，模板表才能保持干净。
    ///
    /// - Parameters:
    ///   - sentence: 已归一化的末句。
    ///   - trigger: 模板触发词。
    /// - Returns: 命中返回 `true`。
    static func triggerMatches(sentence: String, trigger: String) -> Bool {
        guard !trigger.isEmpty else { return false }
        if sentence.hasSuffix(trigger) { return true }
        var trimmed = sentence
        while let last = trimmed.last,
              sentenceFinalParticles.contains(last),
              trimmed.count > trigger.count {
            trimmed.removeLast()
            if trimmed.hasSuffix(trigger) { return true }
        }
        return false
    }

    /// 取末句的上下文键（后 `contextKeyLength` 个字，不足则取全部）。
    /// - Parameter sentence: 已归一化的末句。
    /// - Returns: 上下文键。
    static func contextKey(for sentence: String) -> String {
        guard sentence.count >= minimumContextKeyLength else { return "" }
        let length = min(contextKeyLength, sentence.count)
        return String(sentence.suffix(length))
    }

    /// 判断字符是否应被忽略（空白、标点、符号）。
    /// - Parameter character: 待判断字符。
    /// - Returns: 忽略返回 `true`。
    private static func isIgnorable(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }

    /// 判断字符是否为句子终止符（倒序扫描时用于截出最后一句）。
    /// - Parameter character: 待判断字符。
    /// - Returns: 是终止符返回 `true`。
    private static func isSentenceTerminator(_ character: Character) -> Bool {
        switch character {
        case "。", "．", ".", "！", "!", "？", "?", "；", ";", "…", "\n", "\r":
            return true
        default:
            return false
        }
    }

    // MARK: - 内部实现

    /// 按「最长键优先」查学到的映射。调用方必须已持有 `lock`。
    /// - Parameter sentence: 已归一化的末句。
    /// - Returns: 候选列表（附带该键长度对应的权重）。
    private func lookupLocked(for sentence: String) -> [(entry: Entry, weight: Double)] {
        var length = min(Self.contextKeyLength, sentence.count)
        while length >= Self.minimumContextKeyLength {
            let key = String(sentence.suffix(length))
            if let bucket = entries[key], !bucket.isEmpty {
                let weight: Double
                if length >= Self.contextKeyLength {
                    weight = 1.0
                } else if length == Self.contextKeyLength - 1 {
                    weight = 0.96
                } else {
                    weight = 0.92
                }
                return bucket.map { (entry: $0, weight: weight) }
            }
            length -= 1
        }
        return []
    }

    /// 超出容量时按最近使用淘汰。调用方必须已持有 `lock`。
    private func trimIfNeededLocked() {
        guard entries.count > Self.maximumStoredKeys else { return }
        let overflow = entries.count - Self.maximumStoredKeys
        let ordered = entries.keys.sorted { lhs, rhs in
            let left = entries[lhs]?.map { $0.updatedAt }.max() ?? 0
            let right = entries[rhs]?.map { $0.updatedAt }.max() ?? 0
            return left < right
        }
        for key in ordered.prefix(overflow) {
            entries.removeValue(forKey: key)
        }
    }

    /// 落盘（失败静默：联想记忆丢了不影响输入）。
    /// - Parameter snapshot: 待写入的快照。
    private func persist(_ snapshot: Persisted) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store.setData(data, forKey: Keys.contextual)
    }
}
