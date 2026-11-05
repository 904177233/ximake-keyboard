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

    private struct Persisted: Codable {
        var counts: [String: Int]
        var phrases: [Phrase]
        var next: [String: [String: Int]]
    }

    private struct UserDictionary: Codable {
        /// 拼音 -> 词 -> 选过几次
        var words: [String: [String: Int]]
        var phrases: [Phrase]
        /// App 每改一次加一，键盘看到变了就重新读。
        var revision: Int
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
    private let lock = NSLock()
    private var counts: [String: Int]
    private var phrases: [Phrase]
    private var next: [String: [String: Int]]
    private var userWords: [String: [String: Int]]
    private var userWordsByDigits: [String: [(key: String, text: String)]] = [:]
    private var revision: Int
    private var phrasesByKey: [String: [String]] = [:]
    private var phrasesByDigits: [String: [Phrase]] = [:]
    private var pendingWrites = 0

    /// 关闭后不再记录新内容（已有数据还在，在 App 的个人词库里清除）。
    public var isEnabled = true

    public init(store: SharedStore) {
        self.store = store
        self.blob = SharedBlob(store: store)
        var loaded = Persisted(counts: [:], phrases: [], next: [:])
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded = decoded
        }
        counts = loaded.counts
        next = loaded.next
        if let dictionary = Self.readDictionary(blob) {
            userWords = dictionary.words
            phrases = dictionary.phrases
            revision = dictionary.revision
        } else {
            // 旧版的短语存在使用统计里，搬过来
            userWords = [:]
            phrases = loaded.phrases
            revision = 0
        }
        rebuildIndexes()
    }

    private static func readDictionary(_ blob: SharedBlob) -> UserDictionary? {
        guard let data = blob.data(forKey: dictionaryKey) else { return nil }
        return try? JSONDecoder().decode(UserDictionary.self, from: data)
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
        return counts[text] ?? 0
    }

    /// 这个拼音下选过的词，选得多的在前。
    public func userWords(forKey key: String) -> [(text: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        guard let texts = userWords[key] else { return [] }
        return texts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// 九宫格：数字串对得上的选过的词。
    public func userWords(forT9 digits: String) -> [(text: String, key: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return (userWordsByDigits[digits] ?? [])
            .map { ($0.text, $0.key, userWords[$0.key]?[$0.text] ?? 0) }
            .sorted { $0.2 > $1.2 }
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
        return followers.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
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
                result.append(Entry(text: text, key: key, count: count))
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
    public func record(segments: [(text: String, key: String)]) {
        guard isEnabled, !segments.isEmpty else { return }
        lock.lock()
        for segment in segments {
            counts[segment.text, default: 0] += 1
            if !segment.key.isEmpty, segment.text.count <= 12 {
                let isNew = userWords[segment.key]?[segment.text] == nil
                userWords[segment.key, default: [:]][segment.text, default: 0] += 1
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
                next[segments[index].text, default: [:]][segments[index + 1].text, default: 0] += 1
            }
        }
        trimLocked()
        pendingWrites += 1
        let shouldFlush = pendingWrites >= Self.flushEvery
        lock.unlock()
        if shouldFlush {
            flush()
        }
    }

    /// 记住「打的是这几个字母，要的是这个词」。简拼（wcgl -> 我吃过了）下次直接排第一。
    public func recordTyped(_ items: [(text: String, typed: String)]) {
        guard isEnabled, !items.isEmpty else { return }
        lock.lock()
        for item in items where !item.typed.isEmpty && item.text.count <= 16 {
            let isNew = userWords[item.typed]?[item.text] == nil
            userWords[item.typed, default: [:]][item.text, default: 0] += 1
            if isNew {
                userWordsByDigits[MoyuDictionary.t9Digits(item.typed), default: []].append((item.typed, item.text))
            }
        }
        pendingWrites += 1
        lock.unlock()
    }

    /// 记录相邻两次上屏的先后关系（上一次上屏的词 -> 这一次）。
    public func recordFollow(previous: String, current: String) {
        guard isEnabled, !previous.isEmpty, !current.isEmpty, previous.count <= 8, current.count <= 8 else { return }
        lock.lock()
        next[previous, default: [:]][current, default: 0] += 1
        trimLocked()
        pendingWrites += 1
        lock.unlock()
    }

    private func trimLocked() {
        if counts.count > Self.maximumWords {
            // 丢掉只用过一次的词
            let keep = counts.filter { $0.value > 1 }
            if keep.count > Self.maximumWords / 2 {
                counts = keep
            } else {
                counts = Dictionary(uniqueKeysWithValues: counts.prefix(Self.maximumWords / 2).map { ($0.key, $0.value) })
            }
        }
        let entryCount = userWords.values.reduce(0) { $0 + $1.count }
        if entryCount > Self.maximumUserEntries {
            // 先丢只选过一次的
            var trimmed: [String: [String: Int]] = [:]
            for (key, texts) in userWords {
                let kept = texts.filter { $0.value > 1 }
                if !kept.isEmpty { trimmed[key] = kept }
            }
            userWords = trimmed
            rebuildIndexes()
        }
        if next.count > Self.maximumBigramHeads {
            next = Dictionary(uniqueKeysWithValues: next.prefix(Self.maximumBigramHeads / 2).map { ($0.key, $0.value) })
        }
    }

    /// 写盘。键盘收起时也会调一次。
    public func flush() {
        lock.lock()
        guard pendingWrites > 0 else {
            lock.unlock()
            return
        }
        pendingWrites = 0
        let usage = Persisted(counts: counts, phrases: [], next: next)
        let dictionary = UserDictionary(words: userWords, phrases: phrases, revision: revision)
        lock.unlock()
        if let data = try? JSONEncoder().encode(usage) {
            store.setData(data, forKey: Self.storageKey)
        }
        if let data = try? JSONEncoder().encode(dictionary) {
            blob.set(data, forKey: Self.dictionaryKey)
        }
    }

    // MARK: - 个人词库管理（App 里用）

    /// App 改过词库的话重新读。键盘每次弹出时调。
    public func reloadIfChanged() {
        guard let dictionary = Self.readDictionary(blob) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard dictionary.revision != revision else { return }
        userWords = dictionary.words
        phrases = dictionary.phrases
        revision = dictionary.revision
        rebuildIndexes()
    }

    /// 手动加一个词。
    public func addEntry(text: String, key: String) {
        let cleanKey = key.lowercased().filter { $0.isLetter && $0.isASCII }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanText.isEmpty else { return }
        lock.lock()
        // 手动加的当成选过几次，保证能排第一
        userWords[cleanKey, default: [:]][cleanText] = max(userWords[cleanKey]?[cleanText] ?? 0, 3)
        revision += 1
        rebuildIndexes()
        lock.unlock()
        writeDictionary()
    }

    /// 删一条。
    public func removeEntry(text: String, key: String) {
        lock.lock()
        userWords[key]?[text] = nil
        if userWords[key]?.isEmpty == true {
            userWords[key] = nil
        }
        phrases.removeAll { $0.text == text && $0.key == key }
        revision += 1
        rebuildIndexes()
        lock.unlock()
        writeDictionary()
    }

    private func writeDictionary() {
        lock.lock()
        let dictionary = UserDictionary(words: userWords, phrases: phrases, revision: revision)
        lock.unlock()
        if let data = try? JSONEncoder().encode(dictionary) {
            blob.set(data, forKey: Self.dictionaryKey)
        }
    }

    /// 清除全部学习数据。
    public func reset() {
        lock.lock()
        counts = [:]
        phrases = []
        next = [:]
        userWords = [:]
        revision += 1
        rebuildIndexes()
        pendingWrites = 0
        let dictionary = UserDictionary(words: [:], phrases: [], revision: revision)
        lock.unlock()
        store.setData(nil, forKey: Self.storageKey)
        blob.set(try? JSONEncoder().encode(dictionary), forKey: Self.dictionaryKey)
    }
}
