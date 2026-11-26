//
//  UserLearningStore.swift
//  墨语 · 输入法内核
//
//  记住用户的习惯，分两部分：
//  - 个人词库：每个拼音下选过哪些词、选了几次，以及自己组出来的短语。打同样的拼音时排第一。
//    存在 App 和键盘共用的地方（SharedBlob），App 里能看、能加、能删、能清空。
//  - 使用统计：哪个词后面常跟哪个词。只存在键盘里。
//  写盘做了节流，不会每按一次键写一次。
//

import Foundation

/// 用户学习记录（线程安全）。
public final class UserLearningStore {

    /// 用户短语。
    public struct Phrase: Codable, Sendable, Equatable {
        public var text: String
        public var key: String

        public init(text: String, key: String) {
            self.text = text
            self.key = key
        }
    }

    /// 个人词库里的一条。
    public struct Entry: Sendable, Equatable, Identifiable {
        public var text: String
        public var key: String
        public var count: Int
        public var id: String { key + "|" + text }
    }

    private struct Persisted: Codable, Sendable {
        var counts: [String: Int]
        var phrases: [Phrase]
        var next: [String: [String: Int]]
        var countDates: [String: TimeInterval]?
        var nextDates: [String: [String: TimeInterval]]?
    }

    private struct UserDictionary: Codable, Sendable {
        /// 拼音 -> 词 -> 选过几次
        var words: [String: [String: Int]]
        var phrases: [Phrase]
        /// App 每改一次加一，键盘看到变了就重新读。
        var revision: Int
        var wordDates: [String: [String: TimeInterval]]?
        var pinnedWords: Set<String>?
    }

    private static let storageKey = "moyu.ime.learning.v3"
    private static let dictionaryKey = "moyu.ime.userdict.v1"
    private static let maximumWords = 6000
    private static let maximumUserEntries = 5000
    private static let maximumPhrases = 3000
    private static let maximumBigramHeads = 2500
    private static let flushEvery = 6

    private let store: SharedStore
    private let blob: SharedBlob
    private let persistenceQueue = DispatchQueue(label: "com.moyu.user-learning.persistence")
    private let lock = NSLock()
    private var counts: [String: Int]
    private var countDates: [String: TimeInterval]
    private var phrases: [Phrase]
    private var next: [String: [String: Int]]
    private var nextDates: [String: [String: TimeInterval]]
    private var userWords: [String: [String: Int]]
    private var wordDates: [String: [String: TimeInterval]]
    private var pinnedWords: Set<String>
    private var userWordsByDigits: [String: [(key: String, text: String)]] = [:]
    private var revision: Int
    private var phrasesByKey: [String: [String]] = [:]
    private var phrasesByDigits: [String: [Phrase]] = [:]
    private var pendingWrites = 0

    /// 关闭后不再记录新内容（已有数据还在，在 App 的个人词库里清除）。
    private var learningEnabled = true
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return learningEnabled
        }
        set {
            lock.lock()
            learningEnabled = newValue
            lock.unlock()
        }
    }

    public init(store: SharedStore) {
        self.store = store
        self.blob = SharedBlob(store: store)
        var loaded = Persisted(counts: [:], phrases: [], next: [:], countDates: [:], nextDates: [:])
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded = decoded
        }
        let now = Date().timeIntervalSince1970
        // 旧版没有日期，计数按「一次 = 1」存；新版按四分之一次存，升级时换算
        counts = loaded.countDates == nil ? loaded.counts.mapValues { $0 * Self.pickUnit } : loaded.counts
        countDates = loaded.countDates ?? Dictionary(uniqueKeysWithValues: loaded.counts.keys.map { ($0, now) })
        next = loaded.nextDates == nil ? Self.scaled(loaded.next) : loaded.next
        nextDates = loaded.nextDates ?? Self.dates(for: loaded.next, now: now)
        if let dictionary = Self.readDictionary(blob) {
            userWords = dictionary.wordDates == nil ? Self.scaled(dictionary.words) : dictionary.words
            phrases = dictionary.phrases
            revision = dictionary.revision
            wordDates = dictionary.wordDates ?? Self.dates(for: dictionary.words, now: now)
            pinnedWords = dictionary.pinnedWords ?? []
        } else {
            // 旧版的短语存在使用统计里，搬过来
            userWords = [:]
            phrases = loaded.phrases
            revision = 0
            wordDates = [:]
            pinnedWords = []
        }
        rebuildIndexes()
    }

    private static func readDictionary(_ blob: SharedBlob) -> UserDictionary? {
        guard let data = blob.data(forKey: dictionaryKey) else { return nil }
        return try? JSONDecoder().decode(UserDictionary.self, from: data)
    }

    private static func dates(for words: [String: [String: Int]], now: TimeInterval) -> [String: [String: TimeInterval]] {
        Dictionary(uniqueKeysWithValues: words.map { key, texts in
            (key, Dictionary(uniqueKeysWithValues: texts.keys.map { ($0, now) }))
        })
    }

    /// 存的计数以四分之一次为单位：点选 +4，空格或标点自动接受 +1。
    private static let pickUnit = 4

    private static func scaled(_ words: [String: [String: Int]]) -> [String: [String: Int]] {
        words.mapValues { $0.mapValues { $0 * pickUnit } }
    }

    /// 换回「选过几次」并按 30 天半衰期衰减，四舍五入（只选过一次的词约 30 天后才归零）。
    private func decayedCount(_ count: Int, updatedAt: TimeInterval?) -> Int {
        guard count > 0 else { return 0 }
        let picks = Double(count) / Double(Self.pickUnit)
        guard let updatedAt else { return Int(picks.rounded()) }
        let age = max(0, Date().timeIntervalSince1970 - updatedAt)
        let halfLife: TimeInterval = 30 * 24 * 60 * 60
        return Int((picks * pow(0.5, age / halfLife)).rounded())
    }

    private static func increment(for strength: Double) -> Int {
        max(1, Int((min(max(strength, 0.1), 3.0) * Double(pickUnit)).rounded()))
    }

    private func rebuildIndexes() {
        phrasesByKey = [:]
        phrasesByDigits = [:]
        for phrase in phrases {
            phrasesByKey[phrase.key, default: []].append(phrase.text)
            phrasesByDigits[MoyuDictionary.t9Digits(phrase.key), default: []].append(phrase)
        }
        userWordsByDigits = [:]
        for (key, texts) in userWords {
            let digits = MoyuDictionary.t9Digits(key)
            for text in texts.keys {
                userWordsByDigits[digits, default: []].append((key, text))
            }
        }
    }

    // MARK: - 查询

    /// 这个词被选过几次。
    public func count(of text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return decayedCount(counts[text] ?? 0, updatedAt: countDates[text])
    }

    /// 这个拼音下选过的词，选得多的在前。
    public func userWords(forKey key: String) -> [(text: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        guard let texts = userWords[key] else { return [] }
        return texts.map { (text: $0.key, count: decayedCount($0.value, updatedAt: wordDates[key]?[$0.key])) }
            .sorted { lhs, rhs in
                let leftPinned = pinnedWords.contains(key + "|" + lhs.text)
                let rightPinned = pinnedWords.contains(key + "|" + rhs.text)
                return leftPinned != rightPinned ? leftPinned : lhs.count > rhs.count
            }
            .map { ($0.text, $0.count) }
    }

    /// 九宫格：数字串对得上的选过的词。
    public func userWords(forT9 digits: String) -> [(text: String, key: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return (userWordsByDigits[digits] ?? [])
            .map { (text: $0.text, key: $0.key,
                    count: decayedCount(userWords[$0.key]?[$0.text] ?? 0, updatedAt: wordDates[$0.key]?[$0.text]),
                    pinned: pinnedWords.contains($0.key + "|" + $0.text)) }
            .sorted { lhs, rhs in
                lhs.pinned != rhs.pinned ? lhs.pinned : lhs.count > rhs.count
            }
            .map { ($0.text, $0.key, $0.count) }
    }

    /// 手动添加的词始终优先于统计学习结果。
    public func isPinnedUserWord(text: String, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinnedWords.contains(key + "|" + text)
    }

    /// 拼音正好是 key 的用户短语。
    public func phrases(forKey key: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return phrasesByKey[key] ?? []
    }

    /// 数字串正好是 digits 的用户短语。
    public func phrases(forT9 digits: String) -> [Phrase] {
        lock.lock()
        defer { lock.unlock() }
        return phrasesByDigits[digits] ?? []
    }

    /// 拼音以 prefix 开头的用户短语。
    public func phrases(withPrefix prefix: String, limit: Int) -> [Phrase] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Phrase] = []
        for phrase in phrases where phrase.key.count > prefix.count && phrase.key.hasPrefix(prefix) {
            result.append(phrase)
            if result.count >= limit { break }
        }
        return result
    }

    /// 这个词后面常跟的词。
    public func next(after text: String, limit: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let followers = next[text] else { return [] }
        return followers.map { (text: $0.key, count: decayedCount($0.value, updatedAt: nextDates[text]?[$0.key])) }
            .filter { $0.count > 0 }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.text < rhs.text
            }
            .prefix(limit)
            .map { $0.text }
    }

    /// 个人词库里有多少条（词 + 短语）。
    public var learnedWordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return userWords.values.reduce(0) { $0 + $1.count } + phrases.count
    }

    /// 个人词库全部内容（App 里显示）。短语的次数记为 0。
    public func allEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Entry] = []
        for (key, texts) in userWords {
            for (text, count) in texts {
                result.append(Entry(text: text, key: key,
                                   count: decayedCount(count, updatedAt: wordDates[key]?[text])))
            }
        }
        let known = Set(result.map(\.id))
        for phrase in phrases where !known.contains(phrase.key + "|" + phrase.text) {
            result.append(Entry(text: phrase.text, key: phrase.key, count: 0))
        }
        return result.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    // MARK: - 记录

    /// 记录一次上屏。
    ///
    /// 每一段都记进个人词库（这个拼音下选了这个词）；多段组成的句子再记成一条用户短语。
    /// - Parameter segments: 组成这次上屏的各段（词 + 拼音）。
    public func record(segments: [(text: String, key: String)], strength: Double = 1.0) {
        guard !segments.isEmpty else { return }
        lock.lock()
        guard learningEnabled else {
            lock.unlock()
            return
        }
        let increment = Self.increment(for: strength)
        let now = Date().timeIntervalSince1970
        for segment in segments {
            counts[segment.text, default: 0] += increment
            countDates[segment.text] = now
            if !segment.key.isEmpty, segment.text.count <= 12 {
                let isNew = userWords[segment.key]?[segment.text] == nil
                userWords[segment.key, default: [:]][segment.text, default: 0] += increment
                wordDates[segment.key, default: [:]][segment.text] = now
                if isNew {
                    userWordsByDigits[MoyuDictionary.t9Digits(segment.key), default: []].append((segment.key, segment.text))
                }
            }
        }
        if segments.count >= 2 {
            let text = segments.map { $0.text }.joined()
            let key = segments.map { $0.key }.joined()
            if text.count <= 16, !key.isEmpty, !phrases.contains(where: { $0.text == text }) {
                phrases.append(Phrase(text: text, key: key))
                phrasesByKey[key, default: []].append(text)
                phrasesByDigits[MoyuDictionary.t9Digits(key), default: []].append(Phrase(text: text, key: key))
                if phrases.count > Self.maximumPhrases {
                    phrases.removeFirst(phrases.count - Self.maximumPhrases)
                    rebuildIndexes()
                }
            }
            for index in 0..<(segments.count - 1) {
                let previous = segments[index].text
                let current = segments[index + 1].text
                next[previous, default: [:]][current, default: 0] += increment
                nextDates[previous, default: [:]][current] = now
            }
        }
        trimLocked()
        pendingWrites += 1
        let shouldFlush = pendingWrites >= Self.flushEvery
        lock.unlock()
        if shouldFlush {
            enqueueFlush()
        }
    }

    /// 记住「打的是这几个字母，要的是这个词」。简拼（wcgl -> 我吃过了）下次直接排第一。
    public func recordTyped(_ items: [(text: String, typed: String)], strength: Double = 1.0) {
        guard !items.isEmpty else { return }
        lock.lock()
        guard learningEnabled else {
            lock.unlock()
            return
        }
        let increment = Self.increment(for: strength)
        let now = Date().timeIntervalSince1970
        for item in items where !item.typed.isEmpty && item.text.count <= 16 {
            let isNew = userWords[item.typed]?[item.text] == nil
            userWords[item.typed, default: [:]][item.text, default: 0] += increment
            wordDates[item.typed, default: [:]][item.text] = now
            if isNew {
                userWordsByDigits[MoyuDictionary.t9Digits(item.typed), default: []].append((item.typed, item.text))
            }
        }
        pendingWrites += 1
        lock.unlock()
    }

    /// 记录相邻两次上屏的先后关系（上一次上屏的词 -> 这一次）。
    public func recordFollow(previous: String, current: String, strength: Double = 1.0) {
        guard !previous.isEmpty, !current.isEmpty, previous.count <= 8, current.count <= 8 else { return }
        lock.lock()
        guard learningEnabled else {
            lock.unlock()
            return
        }
        let increment = Self.increment(for: strength)
        next[previous, default: [:]][current, default: 0] += increment
        nextDates[previous, default: [:]][current] = Date().timeIntervalSince1970
        trimLocked()
        pendingWrites += 1
        lock.unlock()
    }

    private func trimLocked() {
        if counts.count > Self.maximumWords {
            // 丢掉只用过一次的词
            let keep = counts.filter { $0.value > Self.pickUnit }
            if keep.count > Self.maximumWords / 2 {
                counts = keep
            } else {
                counts = Dictionary(uniqueKeysWithValues: counts.prefix(Self.maximumWords / 2).map { ($0.key, $0.value) })
            }
            countDates = countDates.filter { counts[$0.key] != nil }
        }
        let entryCount = userWords.values.reduce(0) { $0 + $1.count }
        if entryCount > Self.maximumUserEntries {
            // 先丢只选过一次的
            var trimmed: [String: [String: Int]] = [:]
            for (key, texts) in userWords {
                let kept = texts.filter { $0.value > Self.pickUnit }
                if !kept.isEmpty { trimmed[key] = kept }
            }
            userWords = trimmed
            wordDates = wordDates.filter { trimmed[$0.key] != nil }
            rebuildIndexes()
        }
        if next.count > Self.maximumBigramHeads {
            next = Dictionary(uniqueKeysWithValues: next.prefix(Self.maximumBigramHeads / 2).map { ($0.key, $0.value) })
            nextDates = nextDates.filter { next[$0.key] != nil }
        }
    }

    private func enqueueFlush() {
        lock.lock()
        defer { lock.unlock() }
        guard pendingWrites > 0 else { return }
        pendingWrites = 0
        revision += 1
        let usage = Persisted(counts: counts, phrases: [], next: next, countDates: countDates, nextDates: nextDates)
        let dictionary = UserDictionary(words: userWords, phrases: phrases, revision: revision,
                                        wordDates: wordDates, pinnedWords: pinnedWords)
        persistenceQueue.async { [store, blob] in
            if let data = try? JSONEncoder().encode(usage) {
                store.setData(data, forKey: Self.storageKey)
            }
            if let data = try? JSONEncoder().encode(dictionary) {
                blob.set(data, forKey: Self.dictionaryKey)
            }
        }
    }

    /// 键盘收起时把剩下的记录写完。
    public func flush() {
        enqueueFlush()
        persistenceQueue.sync {}
    }

    // MARK: - 个人词库管理（App 里用）

    /// App 改过词库的话重新读。键盘每次弹出时调。
    public func reloadIfChanged() {
        lock.lock()
        defer { lock.unlock() }
        guard let dictionary = persistenceQueue.sync(execute: { Self.readDictionary(blob) }),
              dictionary.revision != revision else { return }
        userWords = dictionary.wordDates == nil ? Self.scaled(dictionary.words) : dictionary.words
        phrases = dictionary.phrases
        revision = dictionary.revision
        wordDates = dictionary.wordDates ?? Self.dates(for: dictionary.words, now: Date().timeIntervalSince1970)
        pinnedWords = dictionary.pinnedWords ?? []
        rebuildIndexes()
    }

    /// 手动加一个词。
    public func addEntry(text: String, key: String) {
        let cleanKey = key.lowercased().filter { $0.isLetter && $0.isASCII }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanText.isEmpty else { return }
        lock.lock()
        // 手动加的当成选过几次，保证能排第一
        userWords[cleanKey, default: [:]][cleanText] = max(userWords[cleanKey]?[cleanText] ?? 0, 3 * Self.pickUnit)
        wordDates[cleanKey, default: [:]][cleanText] = Date().timeIntervalSince1970
        pinnedWords.insert(cleanKey + "|" + cleanText)
        revision += 1
        rebuildIndexes()
        writeDictionaryLocked()
        lock.unlock()
    }

    /// 删一条。
    public func removeEntry(text: String, key: String) {
        lock.lock()
        userWords[key]?[text] = nil
        wordDates[key]?[text] = nil
        pinnedWords.remove(key + "|" + text)
        if userWords[key]?.isEmpty == true {
            userWords[key] = nil
        }
        phrases.removeAll { $0.text == text && $0.key == key }
        revision += 1
        rebuildIndexes()
        writeDictionaryLocked()
        lock.unlock()
    }

    private func writeDictionaryLocked() {
        let dictionary = UserDictionary(words: userWords, phrases: phrases, revision: revision,
                                        wordDates: wordDates, pinnedWords: pinnedWords)
        persistenceQueue.sync {
            if let data = try? JSONEncoder().encode(dictionary) {
                blob.set(data, forKey: Self.dictionaryKey)
            }
        }
    }

    /// 清除全部学习数据。
    public func reset() {
        lock.lock()
        counts = [:]
        countDates = [:]
        phrases = []
        next = [:]
        nextDates = [:]
        userWords = [:]
        wordDates = [:]
        pinnedWords = []
        revision += 1
        rebuildIndexes()
        pendingWrites = 0
        persistenceQueue.sync { store.setData(nil, forKey: Self.storageKey) }
        writeDictionaryLocked()
        lock.unlock()
    }
}
