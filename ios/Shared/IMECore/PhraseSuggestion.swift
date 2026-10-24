//
//  PhraseSuggestion.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：加载 `phrases.tsv` 短语联想库，按"上屏文本的尾部触发词"检索下一句建议词，
//            供 PinyinEngine.predictNext(after:) 使用。
//  依赖：Foundation
//  使用方：PinyinEngine、IMEKit
//

import Foundation

/// 一条短语联想建议。
public struct PhraseSuggestion: Sendable, Equatable {
    /// 建议词全拼（UI 可用作学习记录）。
    public var pinyin: String

    /// 触发词（上屏文本尾部命中它时给出该建议）。
    public var trigger: String

    /// 建议词文本。
    public var text: String

    /// 创建一条短语联想建议。
    /// - Parameters:
    ///   - pinyin: 建议词全拼。
    ///   - trigger: 触发词。
    ///   - text: 建议词文本。
    public init(pinyin: String, trigger: String, text: String) {
        self.pinyin = pinyin
        self.trigger = trigger
        self.text = text
    }
}

/// 短语联想索引（只读，加载完成后线程安全）。
///
/// 数据文件 `ios/Shared/Resources/dict/phrases.tsv`，每行：
/// `建议词拼音<TAB>触发词<TAB>建议词`；以 `#` 开头的行为注释。
/// 词库缺失时索引为空，`suggestions(after:)` 返回空数组，不影响主输入流程。
public final class PhraseSuggestionIndex {

    // MARK: - 元信息

    /// 触发词个数。
    public let triggerCount: Int

    /// 建议条目总数。
    public let suggestionCount: Int

    /// 最长触发词的字符数（用于尾部匹配的起始长度）。
    public let maxTriggerLength: Int

    /// 实际命中的文件路径；加载失败时为 `"<none>"`。
    public let loadedPath: String

    // MARK: - 索引

    /// 触发词 -> 建议列表（保持文件内顺序）。
    private let index: [String: [PhraseSuggestion]]

    // MARK: - 初始化

    /// 创建短语联想索引。
    /// - Parameter url: 指定短语文件；传 `nil` 时按候选路径自动查找。
    public init(url: URL? = nil) {
        var entries: [PhraseSuggestion] = []
        var path = "<none>"

        var resolved = url
        if resolved == nil {
            resolved = Self.candidateURLs().first
        }
        if let fileURL = resolved, let parsed = Self.parseFile(at: fileURL) {
            entries = parsed
            path = fileURL.path
        }

        var grouped: [String: [PhraseSuggestion]] = [:]
        var maxLength = 0
        for suggestion in entries {
            maxLength = max(maxLength, suggestion.trigger.count)
            var list = grouped[suggestion.trigger, default: []]
            if !list.contains(where: { $0.text == suggestion.text }) {
                list.append(suggestion)
            }
            grouped[suggestion.trigger] = list
        }

        self.index = grouped
        self.triggerCount = grouped.count
        self.suggestionCount = entries.count
        self.maxTriggerLength = max(1, maxLength)
        self.loadedPath = path
    }

    // MARK: - 查询

    /// 根据上屏文本的结尾检索联想建议。
    ///
    /// 从最长的触发词开始尝试，命中即返回（例如文本结尾是"谢谢你"时，
    /// 优先用"谢谢你"而非"谢谢"）。
    /// - Parameters:
    ///   - text: 已经上屏的文本（可包含多句）。
    ///   - limit: 最多返回条数。
    /// - Returns: 建议词数组；无命中时为空。
    public func suggestions(after text: String, limit: Int) -> [PhraseSuggestion] {
        guard limit > 0 else { return [] }
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        let start = max(0, characters.count - maxTriggerLength)
        var tail = ""
        var index = characters.count
        // 从长到短构造尾部子串（最多 maxTriggerLength 次）
        while index > start {
            tail = String(characters[index - 1]) + tail
            index -= 1
            if let list = self.index[tail] {
                return Array(list.prefix(limit))
            }
        }
        return []
    }

    // MARK: - 加载

    /// 短语文件的候选路径列表（与词库同一套打包策略）。
    /// - Returns: 候选 URL 数组。
    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let subdirectories: [String?] = ["Resources/dict", "dict", nil]
        var bundles: [Bundle] = [Bundle.main]
        let classBundle = Bundle(for: PhraseSuggestionIndex.self)
        if classBundle.bundleURL.path != Bundle.main.bundleURL.path {
            bundles.append(classBundle)
        }
        for bundle in bundles {
            for subdirectory in subdirectories {
                if let url = bundle.url(forResource: "phrases",
                                        withExtension: "tsv",
                                        subdirectory: subdirectory) {
                    urls.append(url)
                }
            }
        }
        for bundle in bundles {
            guard let resourceURL = bundle.resourceURL else { continue }
            urls.append(resourceURL.appendingPathComponent("Resources/dict/phrases.tsv"))
            urls.append(resourceURL.appendingPathComponent("dict/phrases.tsv"))
            urls.append(resourceURL.appendingPathComponent("phrases.tsv"))
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// 解析短语 TSV。
    /// - Parameter url: 文件 URL。
    /// - Returns: 建议数组；文件不可读或没有有效行时返回 `nil`。
    private static func parseFile(at url: URL) -> [PhraseSuggestion]? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let entries = parse(text: text)
        return entries.isEmpty ? nil : entries
    }

    /// 解析短语 TSV 文本。
    /// - Parameter text: 文件内容。
    /// - Returns: 建议数组。
    static func parse(text: String) -> [PhraseSuggestion] {
        var result: [PhraseSuggestion] = []
        result.reserveCapacity(800)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let pinyin = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let trigger = String(fields[1]).trimmingCharacters(in: .whitespaces)
            let word = String(fields[2]).trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty, !word.isEmpty else { continue }
            result.append(PhraseSuggestion(pinyin: pinyin, trigger: trigger, text: word))
        }
        return result
    }
}
