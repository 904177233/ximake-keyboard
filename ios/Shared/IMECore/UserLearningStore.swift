//
//  UserLearningStore.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：记录用户的选词次数、最近使用短语与自造词，为候选排序提供个性化权重；
//            通过 SharedStore 的四个基础方法完成持久化，不直接接触 UserDefaults。
//  依赖：Foundation、SharedStore（同 target，仅使用公开方法）
//  使用方：PinyinEngine、IMEKit、host-app-ui（学习记录清理入口）
//

import Foundation

/// 用户学习记录（线程安全）。
///
/// 设计要点：
/// - 选词计数只增不减，权重取 `log2(1 + count)`，使第 1 次选词即产生明显提升，
///   随后边际递减，避免单个词被无限放大；
/// - 最近使用采用环形缓冲（上限 200 条），命中时把词移到队首；
/// - 自造词保存"文本 -> 全拼"，让用户新词也能被全拼/简拼检索到；
/// - 持久化统一走 `SharedStore.setData(_:forKey:)`（JSON），兼容 App Group 不可用时的内存降级。
public final class UserLearningStore {

    // MARK: - 常量

    /// 最近使用环形缓冲上限。
    public static let recentCapacity = 200

    /// 持久化键（版本后缀便于将来结构升级）。
    private enum Keys {
        static let learning = "moyu.ime.learning.v1"
    }

    // MARK: - 持久化载体

    /// 落盘结构（JSON）。
    private struct Persisted: Codable {
        var counts: [String: Int]
        var recent: [String]
        var userPhrases: [UserPhrase]

        struct UserPhrase: Codable {
            var text: String
            var pinyin: String
        }
    }

    // MARK: - 内存状态

    private let store: SharedStore
    private let lock = NSLock()

    /// 词 -> 选词次数。
    private var counts: [String: Int]

    /// 最近使用（队首最新）。
    private var recent: [String]

    /// 自造词（按加入顺序）。
    private var userPhrases: [Persisted.UserPhrase]

    /// 文本 -> 全拼（自造词 + 参与过选词的词）。
    private var pinyinByText: [String: String]

    /// 最近使用的快速定位表（文本 -> 队首距离），惰性重建。
    private var recentRank: [String: Int]

    /// 是否有未落盘的修改（用于减少无效写入）。
    private var dirty = false

    // MARK: - 初始化

    /// 创建学习记录。
    ///
    /// - Parameter store: 共享存储容器（App 与键盘扩展共用）。
    public init(store: SharedStore) {
        self.store = store
        var loaded = Persisted(counts: [:], recent: [], userPhrases: [])
        if let data = store.data(forKey: Keys.learning),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded = decoded
        }
        self.counts = loaded.counts
        self.recent = Array(loaded.recent.prefix(Self.recentCapacity))
        self.userPhrases = loaded.userPhrases
        var map: [String: String] = [:]
        for phrase in loaded.userPhrases {
            map[phrase.text] = phrase.pinyin
        }
        self.pinyinByText = map
        self.recentRank = [:]
        rebuildRecentRank()
    }

    // MARK: - 契约 API

    /// 记录一次选词。
    ///
    /// - Parameters:
    ///   - candidate: 被选中的候选。
    ///   - input: 选词时的输入串（用于将来做前缀纠错，当前仅作诊断用途）。
    public func recordSelection(candidate: IMECandidate, input: String) {
        lock.lock()
        counts[candidate.text, default: 0] += 1
        promoteRecent(candidate.text)
        if !candidate.pinyin.isEmpty {
            pinyinByText[candidate.text] = candidate.pinyin
        }
        dirty = true
        lock.unlock()
        persistIfNeeded()
    }

    /// 查询某词的个性化权重。
    ///
    /// 采用 `log2(1 + 选词次数)`：0 次为 0，1 次为 1.0，3 次为 2.0，7 次为 3.0。
    /// - Parameter text: 候选文本。
    /// - Returns: 权重（非负）。
    public func weight(for text: String) -> Double {
        lock.lock()
        let count = counts[text] ?? 0
        lock.unlock()
        guard count > 0 else { return 0 }
        return log2(Double(count) + 1.0)
    }

    /// 最近选择的词（队首最新）。
    /// - Parameter limit: 最多返回条数。
    /// - Returns: 文本数组。
    public func recentPhrases(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = Array(recent.prefix(limit))
        lock.unlock()
        return snapshot
    }

    /// 添加自造词。
    ///
    /// - Parameters:
    ///   - text: 词文本（空白会被裁掉，空串忽略）。
    ///   - pinyin: 无声调全拼（小写；传空串时不参与拼音检索）。
    public func addUserPhrase(_ text: String, pinyin: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedPinyin = Self.normalizePinyin(pinyin)
        lock.lock()
        if let existing = userPhrases.firstIndex(where: { $0.text == trimmed }) {
            userPhrases[existing].pinyin = normalizedPinyin
        } else {
            userPhrases.append(Persisted.UserPhrase(text: trimmed, pinyin: normalizedPinyin))
        }
        if !normalizedPinyin.isEmpty {
            pinyinByText[trimmed] = normalizedPinyin
        }
        // 自造词默认给一个较高权重，保证立刻能被优先看到
        counts[trimmed, default: 0] = max(counts[trimmed] ?? 0, 3)
        promoteRecent(trimmed)
        dirty = true
        lock.unlock()
        persistIfNeeded()
    }

    // MARK: - 扩展 API（供引擎排序使用）

    /// 最近使用带来的排序增益（0...1）。
    ///
    /// 队首为 1.0，越靠后越小，超出 `recentCapacity` 为 0。
    /// - Parameter text: 候选文本。
    /// - Returns: 增益值。
    public func recentBoost(for text: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let rank = recentRank[text] else { return 0 }
        let position = Double(max(0, rank))
        let capacity = Double(Self.recentCapacity)
        return max(0, 1.0 - position / capacity)
    }

    /// 全部自造词文本（按加入顺序）。
    /// - Returns: 文本数组。
    public func userPhraseTexts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return userPhrases.map { $0.text }
    }

    /// 自造词对应的全拼；不存在时返回 `nil`。
    /// - Parameter text: 词文本。
    /// - Returns: 全拼。
    public func pinyin(forUserPhrase text: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return userPhrases.first { $0.text == text }?.pinyin
    }

    /// 某文本的选词次数。
    /// - Parameter text: 词文本。
    /// - Returns: 次数。
    public func selectionCount(for text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[text] ?? 0
    }

    /// 清空全部学习数据（设置页"清除输入习惯"入口）。
    public func reset() {
        lock.lock()
        counts = [:]
        recent = []
        userPhrases = []
        pinyinByText = [:]
        recentRank = [:]
        dirty = true
        lock.unlock()
        persistIfNeeded(force: true)
    }

    // MARK: - 最近使用环形缓冲

    /// 把文本提升到最近使用队首（已存在则先移除）。
    /// 调用方必须已持有 `lock`。
    /// - Parameter text: 词文本。
    private func promoteRecent(_ text: String) {
        if let existing = recent.firstIndex(of: text) {
            recent.remove(at: existing)
        }
        recent.insert(text, at: 0)
        if recent.count > Self.recentCapacity {
            recent.removeLast(recent.count - Self.recentCapacity)
        }
        rebuildRecentRank()
    }

    /// 重建最近使用的位置索引。
    /// 调用方必须已持有 `lock`。
    private func rebuildRecentRank() {
        var rank: [String: Int] = [:]
        rank.reserveCapacity(recent.count)
        for (index, text) in recent.enumerated() where rank[text] == nil {
            rank[text] = index
        }
        recentRank = rank
    }

    // MARK: - 持久化

    /// 有修改时落盘。
    /// - Parameter force: 忽略 `dirty` 标记强制写入。
    private func persistIfNeeded(force: Bool = false) {
        lock.lock()
        guard dirty || force else {
            lock.unlock()
            return
        }
        let snapshot = Persisted(counts: counts,
                                 recent: recent,
                                 userPhrases: userPhrases)
        dirty = false
        lock.unlock()

        if let data = try? JSONEncoder().encode(snapshot) {
            store.setData(data, forKey: Keys.learning)
        }
    }

    // MARK: - 工具

    /// 归一化拼音：小写、仅保留字母数字。
    /// - Parameter pinyin: 原始拼音。
    /// - Returns: 归一化结果。
    static func normalizePinyin(_ pinyin: String) -> String {
        var result = ""
        result.reserveCapacity(pinyin.count)
        for character in pinyin.lowercased() where character.isLetter || character.isNumber {
            result.append(character)
        }
        return result
    }
}
