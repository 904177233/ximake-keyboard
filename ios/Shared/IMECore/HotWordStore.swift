//
//  HotWordStore.swift
//  墨语 · 输入法内核
//
//  新词表：内置词库发版以后才流行起来的词（视频号、饭搭子……）。
//  文件格式和 ios/Shared/dict/hot_words.tsv 一样：词<TAB>音节（' 隔开）<TAB>词频。
//  键盘每天从仓库拉一次最新版（见 AIKeyboardExtension/Core/HotWordUpdater.swift），
//  引擎拿这里的词补在词库后面：整串对得上时进整句和候选，也能按首字母（简拼）找到。
//

import Foundation

/// 新词表（只读）。
public final class HotWordStore {

    public struct Word: Sendable {
        public let text: String
        public let key: String
        public let syllables: [String]
        public let frequency: Int
    }

    private var byKey: [String: [Word]] = [:]
    private var byInitials: [String: [Word]] = [:]

    /// 一共多少个词。
    public private(set) var count = 0

    /// 文件太大或格式不对时不读，防止拉到的东西有问题。
    public static let maximumBytes = 1_000_000

    /// 从文件读。
    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    /// 从文本读。不认识的行跳过。
    public init(text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, let frequency = Int(fields[2]), frequency > 0 else { continue }
            let text = String(fields[0])
            let syllables = fields[1].split(separator: "'").map(String.init)
            guard !text.isEmpty, text.count == syllables.count,
                  syllables.allSatisfy({ PinyinSyllables.isSyllable($0) }) else { continue }
            let word = Word(text: text, key: syllables.joined(), syllables: syllables, frequency: min(frequency, 200_000))
            byKey[word.key, default: []].append(word)
            byInitials[String(syllables.compactMap(\.first)), default: []].append(word)
            count += 1
        }
        for key in byKey.keys { byKey[key]?.sort { $0.frequency > $1.frequency } }
        for key in byInitials.keys { byInitials[key]?.sort { $0.frequency > $1.frequency } }
    }

    /// 全拼正好是 key 的词。
    public func words(forKey key: String) -> [Word] {
        byKey[key] ?? []
    }

    /// 简拼正好是 initials 的词（两个字母以上才查）。
    public func words(forInitials initials: String) -> [Word] {
        initials.count >= 2 ? (byInitials[initials] ?? []) : []
    }

    /// 键盘自己的缓存位置。
    public static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("moyu-hot-words.tsv")
    }
}
