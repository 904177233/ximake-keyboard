//
//  EnglishLexicon.swift
//  墨语 · 输入法内核
//
//  英文模式下打字时的补全：打了 hel，给 hello、help、held。
//  词表是 ios/Shared/dict/en_words.tsv（词<TAB>每十亿词出现次数，按字母排好），
//  来自 wordfreq 的英文词频（数据 CC BY-SA 4.0），由 tools/dict/build_binary.py 生成。
//

import Foundation

/// 英文补全词表（只读，第一次用到时读入）。
public final class EnglishLexicon {

    private let mapped: NSData?
    private lazy var offsets: [UInt32] = {
        guard let mapped, mapped.length <= Int(UInt32.max) else { return [] }
        let bytes = UnsafeRawBufferPointer(start: mapped.bytes, count: mapped.length)
        var starts: [UInt32] = []
        starts.reserveCapacity(40_000)
        if !bytes.isEmpty { starts.append(0) }
        for i in bytes.indices where bytes[i] == 10 && i + 1 < bytes.count {
            starts.append(UInt32(i + 1))
        }
        return starts
    }()

    public var count: Int { offsets.count }

    public init(url: URL? = nil) {
        mapped = (url ?? Self.bundledURL()).flatMap { try? NSData(contentsOf: $0, options: .alwaysMapped) }
    }

    private func row(_ index: Int) -> (word: String, count: Int) {
        guard let mapped else { return ("", 0) }
        let bytes = UnsafeRawBufferPointer(start: mapped.bytes, count: mapped.length)
        let start = Int(offsets[index])
        let end = index + 1 < offsets.count ? Int(offsets[index + 1]) : bytes.count
        guard let tab = bytes[start..<end].firstIndex(of: 9) else { return ("", 0) }
        var n = 0
        for byte in bytes[(tab + 1)..<end] where (48...57).contains(byte) {
            n = n * 10 + Int(byte - 48)
        }
        return (String(decoding: bytes[start..<tab], as: UTF8.self), n)
    }

    private func lowerBound(_ word: String) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if row(mid).word < word { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 本项目补录的技术名称，不伪造 wordfreq 次数。
    private static let technical = ["chatgpt"]

    func mixedCompletion(_ typed: String) -> String? {
        let key = typed.lowercased()
        guard (2...32).contains(key.utf8.count) else { return nil }
        if Self.technical.contains(key) || contains(key) { return typed }
        guard key.count >= 3 else { return nil }
        let word = Self.technical.first { $0.hasPrefix(key) } ?? completions(for: key, limit: 1).first
        return word.map { Self.matchCase($0, like: typed) }
    }

    private static func bundledURL() -> URL? {
        for bundle in [Bundle.main, Bundle(for: EnglishLexicon.self)] {
            if let url = bundle.url(forResource: "en_words", withExtension: "tsv", subdirectory: "dict") {
                return url
            }
        }
        return nil
    }

    /// 以 prefix 开头的常用词，按常用程度排。
    ///
    /// 大小写跟着用户打的走：打 Hel 给 Hello，打 HEL 给 HELLO。
    /// 只打了一个字母时不给（太多了，没意义），打的已经是个完整的词时它排第一。
    public func completions(for prefix: String, limit: Int = 8) -> [String] {
        let lower = prefix.lowercased()
        guard lower.count >= 2, lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }), count > 0 else {
            return []
        }
        let low = lowerBound(lower)
        var rows: [(word: String, count: Int)] = []
        var index = low
        while index < count && rows.count < 4000 {
            let entry = row(index)
            guard entry.word.hasPrefix(lower) else { break }
            rows.append(entry)
            index += 1
        }
        rows.sort { $0.count > $1.count }
        var result: [String] = []
        if let exact = rows.first(where: { $0.word == lower }) {
            result.append(exact.word)
        }
        for row in rows where result.count < limit && row.word != lower {
            result.append(row.word)
        }
        return result.map { Self.matchCase($0, like: prefix) }
    }

    /// 是不是词表里的词。
    public func contains(_ word: String) -> Bool {
        let lower = word.lowercased()
        let index = lowerBound(lower)
        return index < count && row(index).word == lower
    }

    private static func matchCase(_ word: String, like typed: String) -> String {
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
            return word.uppercased()
        }
        if let first = typed.first, first.isUppercase {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        // i 单独成词时总是大写（i'm -> I'm）
        if word == "i" || word.hasPrefix("i'") {
            return "I" + word.dropFirst()
        }
        return word
    }
}
