//
//  PromptLibrary+Suggestion.swift
//  墨语（Moyu）
//
//  从 PromptLibrary.swift 拆出「智能联想」整段（design/04 §4）。
//  拆分原因：PromptLibrary.swift 已到 602 行、超过 docs/02 §3.7 的 600 行上限。
//  这里只放联想相关的常量、请求构造与结果解析，其余职责仍在 PromptLibrary.swift。
//

import Foundation

public extension PromptLibrary {

    // MARK: - 智能联想（design/04 §4）

    /// 智能联想的输出上限。三条 12 字短句 + JSON 括号本来 120 就够，
    /// 但推理模型（deepseek-reasoner 等）会先把预算烧在思维链上 —— 给 120 直接
    /// 一整个请求全是 reasoning、正文为空，联想永远返回不了东西。所以抬到 1024：
    /// 非推理模型的输出仍只有几十 token，抬高的只是「上限」不是「实际消耗」。
    public static let suggestionMaxTokens: Int = 1024

    /// 构造智能联想请求（`stream: false`，一次拿完更省事、也便于 1.5s 超时控制）。
    ///
    /// - Parameters:
    ///   - context: 聊天窗口里的上文（design/04 §4.4：≤ 200 字，由调用方裁剪）。
    ///   - text: 用户已经输入的内容。
    ///   - maxTokens: 输出上限，默认 `suggestionMaxTokens`(1024)。
    /// - Returns: `stream: false` 的 `ChatRequest`（temperature 0.9）。
    public static func suggestionRequest(
        context: String,
        text: String,
        maxTokens: Int = PromptLibrary.suggestionMaxTokens
    ) -> ChatRequest {
        let template = BuiltInPrompts.suggestionNext
        let messages = render(
            template,
            text: text,
            context: context,
            tone: "自然",
            targetLanguage: "英文"
        )
        return ChatRequest(
            messages: messages,
            temperature: template.temperature,
            maxTokens: maxTokens,
            stream: false
        )
    }

    /// 联想结果的最大条数（design/04 §4.3：候选栏最多 3 个胶囊）。
    public static let suggestionMaxCount: Int = 3

    /// 联想结果单条最大字数（design/04 §4.3：≤ 12 字）。
    public static let suggestionMaxCharacters: Int = 12

    /// 解析智能联想的模型输出为候选数组（design/04 §4.4「返回解析」）。
    ///
    /// 容错策略（**失败必须完全静默**，绝不抛错、绝不弹提示）：
    /// - ① 优先按 JSON 数组解析（模型照要求输出时走这条路）；
    /// - ② JSON 失败但输出里仍有 `[ ... ]` 时，按中英文逗号切分括号内内容再逐项清洗
    ///   （覆盖全角引号 `“”`、全角逗号 `，`、单引号等「非法 JSON」的常见形态）；
    /// - ③ 仍失败则逐行宽松解析（去 ``` 代码块标记、去 `1.` `2.` `1、` `-` `*` 等序号、去包裹引号）；
    /// - 最后统一过滤空串、超长（> `suggestionMaxCharacters`）、与前面重复的项，
    ///   截断到 `suggestionMaxCount` 条；不足 1 条返回空数组（调用方据此退回传统联想）。
    ///
    /// - Parameter raw: 模型原始输出。
    /// - Returns: 可直接显示的候选短句（0...3 条）。
    public static func parseSuggestionCandidates(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = []

        let bracketStart = trimmed.firstIndex(of: "[")
        let bracketEnd = trimmed.lastIndex(of: "]")
        let hasBracketPair: Bool = {
            guard let start = bracketStart, let end = bracketEnd else { return false }
            return start < end
        }()

        // ① 标准形态：JSON 数组（容忍前后有 ``` 代码块标记或说明文字）。
        if let start = bracketStart, let end = bracketEnd, start < end {
            let jsonText = String(trimmed[start...end])
            if let data = jsonText.data(using: .utf8),
               let array = try? JSONDecoder().decode([String].self, from: data) {
                candidates = array
            }
        }

        // ② 非法 JSON（全角引号/全角逗号/单引号）：按中英文逗号切分括号内内容。
        if candidates.isEmpty, hasBracketPair,
           let start = bracketStart, let end = bracketEnd {
            let inner = String(trimmed[trimmed.index(after: start)..<end])
            guard inner.contains(",") || inner.contains("，") else {
                // 单个元素（无分隔符）直接整体清洗。
                let single = cleanSuggestionItem(inner)
                if !single.isEmpty { candidates = [single] }
                return finalizeSuggestionCandidates(candidates)
            }
            let normalized = inner.replacingOccurrences(of: "，", with: ",")
            let parts = normalized.split(separator: ",", omittingEmptySubsequences: true)
            // 只接受 1...8 项，避免把一句带逗号的长句误切成多段。
            if !parts.isEmpty, parts.count <= 8 {
                candidates = parts.map { cleanSuggestionItem(String($0)) }
                    .filter { !$0.isEmpty }
            }
        }

        // ③ 宽松兜底：逐行清洗。
        if candidates.isEmpty {
            for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                let cleaned = cleanSuggestionItem(String(line))
                if !cleaned.isEmpty {
                    candidates.append(cleaned)
                }
            }
        }

        return finalizeSuggestionCandidates(candidates)
    }

    /// 清洗单条联想候选：去代码块标记、行首序号、包裹引号与行尾逗号/方括号。
    private static func cleanSuggestionItem(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉行首序号：1. / 1、/ 1) / - / * / •
        for prefix in ["1.", "2.", "3.", "4.", "1、", "2、", "3、", "4、",
                       "1)", "2)", "3)", "4)", "-", "*", "•"] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let junk = CharacterSet(charactersIn: "\"“”「」『』‘’,，[]、")
        return cleaned.trimmingCharacters(in: junk)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 统一过滤与去重（保持顺序），截断到 `suggestionMaxCount` 条。
    private static func finalizeSuggestionCandidates(_ candidates: [String]) -> [String] {
        var result: [String] = []
        for candidate in candidates {
            let item = cleanSuggestionItem(candidate)
            guard !item.isEmpty else { continue }
            guard item.count <= suggestionMaxCharacters else { continue }
            guard !result.contains(item) else { continue }
            result.append(item)
            if result.count >= suggestionMaxCount { break }
        }
        return result
    }
}
