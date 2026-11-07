//
//  NextWordIndex.swift
//  墨语 · 输入法内核
//
//  「这个词后面常跟什么」。数据来自 tools/dict/build_binary.py 生成的 next.tsv，每行：
//      词 <TAB> 手工整理的下一个词 <TAB> 从词库推出来的后半截 <TAB> 从短语库推出来的下一个词
//
//  第四列：把 rime-ice 里的多字短语（我吃过了）切成词（我|吃过|了），数前后两个词连在一起的次数。
//
//  手工整理的部分质量高，既用于上屏后的联想，也用于整句转换时判断两个词连在一起是否自然
//  （「我想」比「我向」常见）。后半截只用于联想：打了「今」，下一个可能是「天」。
//

import Foundation

/// 下一词索引（只读，第一次用到时读入内存）。
public final class NextWordIndex {

    private var authored: [String: [String]] = [:]
    private var authoredSets: [String: Set<String>] = [:]
    private var compound: [String: [String]] = [:]
    private var following: [String: [String]] = [:]

    /// 最长按几个字匹配上屏内容的结尾。
    private static let maximumHeadLength = 4

    /// 创建索引。
    /// - Parameter url: next.tsv 的路径；不传时从安装包里找，找不到就是空索引。
    public init(url: URL? = nil) {
        guard let fileURL = url ?? Self.bundledURL(),
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let head = String(fields[0])
            if !fields[1].isEmpty {
                let words = fields[1].split(separator: " ").map(String.init)
                authored[head] = words
                authoredSets[head] = Set(words)
            }
            if !fields[2].isEmpty {
                compound[head] = fields[2].split(separator: " ").map(String.init)
            }
            if fields.count >= 4, !fields[3].isEmpty {
                following[head] = fields[3].split(separator: " ").map(String.init)
            }
        }
    }

    private static func bundledURL() -> URL? {
        for bundle in [Bundle.main, Bundle(for: NextWordIndex.self)] {
            if let url = bundle.url(forResource: "next", withExtension: "tsv", subdirectory: "dict") {
                return url
            }
        }
        return nil
    }

    /// 两个词连在一起是否常见。
    public func isCommonPair(_ previous: String, _ next: String) -> Bool {
        authoredSets[previous]?.contains(next) ?? false
    }

    /// 手工整理的下一个词：优先按最长的结尾匹配。
    public func authoredWords(after text: String) -> [String] {
        lookup(text, in: authored)
    }

    /// 从词库推出来的后半截。
    /// - Parameter minimumHeadLength: 结尾至少按几个字匹配（一整句后面不要按单个字补全）。
    public func compoundWords(after text: String, minimumHeadLength: Int = 1) -> [String] {
        lookup(text, in: compound, minimumLength: minimumHeadLength)
    }

    /// 从短语库推出来的下一个词。
    public func followingWords(after text: String) -> [String] {
        lookup(text, in: following)
    }

    private func lookup(_ text: String, in table: [String: [String]], minimumLength: Int = 1) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var length = min(Self.maximumHeadLength, characters.count)
        while length >= max(minimumLength, 1) {
            if let words = table[String(characters.suffix(length))] {
                return words
            }
            length -= 1
        }
        return []
    }
}
