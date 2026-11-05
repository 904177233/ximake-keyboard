//
//  UserLearningStore.swift
//  墨语 · 输入法内核
//
//  记住用户的习惯：选过哪些词、自己组出来的短语、哪个词后面常跟哪个词。
//  数据只存在本机。写盘做了节流，不会每按一次键写一次。
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

    private struct Persisted: Codable {
        var counts: [String: Int]
        var phrases: [Phrase]
        var next: [String: [String: Int]]
    }

    private static let storageKey = "moyu.ime.learning.v3"
    private static let maximumWords = 6000
    private static let maximumPhrases = 3000
    private static let maximumBigramHeads = 2500
    private static let flushEvery = 6

    private let store: SharedStore
    private let lock = NSLock()
    private var counts: [String: Int]
    private var phrases: [Phrase]
    private var next: [String: [String: Int]]
    private var phrasesByKey: [String: [String]] = [:]
    private var phrasesByDigits: [String: [Phrase]] = [:]
    private var pendingWrites = 0

    /// 关闭后不再记录新内容（已有数据还在，由「清除」入口删除）。
    public var isEnabled = true

    public init(store: SharedStore) {
        self.store = store
        var loaded = Persisted(counts: [:], phrases: [], next: [:])
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded = decoded
        }
        counts = loaded.counts
        phrases = loaded.phrases
        next = loaded.next
        rebuildPhraseIndex()
    }

    private func rebuildPhraseIndex() {
        phrasesByKey = [:]
        phrasesByDigits = [:]
        for phrase in phrases {
            phrasesByKey[phrase.key, default: []].append(phrase.text)
            phrasesByDigits[MoyuDictionary.t9Digits(phrase.key), default: []].append(phrase)
        }
    }

    // MARK: - 查询

    /// 这个词被选过几次。
    public func count(of text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[text] ?? 0
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

    /// 记住了多少词（设置页显示）。
    public var learnedWordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.count
    }

    // MARK: - 记录

    /// 记录一次上屏。
    ///
    /// 多段组成的句子会记成一条用户短语，下次打同样的拼音就直接出来。
    /// - Parameter segments: 组成这次上屏的各段（词 + 拼音）。
    public func record(segments: [(text: String, key: String)]) {
        guard isEnabled, !segments.isEmpty else { return }
        lock.lock()
        for segment in segments {
            counts[segment.text, default: 0] += 1
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
                    rebuildPhraseIndex()
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
        let snapshot = Persisted(counts: counts, phrases: phrases, next: next)
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            store.setData(data, forKey: Self.storageKey)
        }
    }

    /// 清除全部学习数据。
    public func reset() {
        lock.lock()
        counts = [:]
        phrases = []
        next = [:]
        phrasesByKey = [:]
        phrasesByDigits = [:]
        pendingWrites = 0
        lock.unlock()
        store.setData(nil, forKey: Self.storageKey)
    }
}
