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

    private var words: [String] = []
    private var counts: [Int] = []

    /// 词表里有多少个词。
    public var count: Int { words.count }

    /// 读词表。
    /// - Parameter url: en_words.tsv 的路径；不传时从安装包里找，找不到就是空表。
    public init(url: URL? = nil) {
        guard let fileURL = url ?? Self.bundledURL(),
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var rows: [(String, Int)] = []
        rows.reserveCapacity(40_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let value = Int(fields[1]) else { continue }
            rows.append((String(fields[0]), value))
        }
        rows.sort { $0.0 < $1.0 }
        words = rows.map(\.0)
        counts = rows.map(\.1)
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
        guard lower.count >= 2, lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }), !words.isEmpty else {
            return []
        }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle] < lower { low = middle + 1 } else { high = middle }
        }
        var rows: [(word: String, count: Int)] = []
        var index = low
        while index < words.count, words[index].hasPrefix(lower), rows.count < 4000 {
            rows.append((words[index], counts[index]))
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
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle] < lower { low = middle + 1 } else { high = middle }
        }
        return low < words.count && words[low] == lower
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
