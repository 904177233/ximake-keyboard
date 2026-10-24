//
//  AISuggestionPrompt.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：上下文联想（L2）的提示词构造与返回结果解析——纯函数，不做网络请求。
//            上游由 UI 层按 `AISuggestionPolicy` 的防抖/超时/取消规则调用任意 `LLMClient`。
//  依赖：Foundation、ContextualSuggestion.swift（`ContextualSuggestion` / `AISuggestionPolicy`）
//  使用方：keyboard-ui（AI 联想调度器）、IMEKit（门面转发）
//

import Foundation

/// L2 的提示词构造 + 结果解析（纯函数，不依赖 Networking 具体类型）。
///
/// 设计目标：把「怎么问模型」与「怎么读懂模型」收敛在内核里，
/// UI 层只需要拿 `systemPrompt` + `userMessage(...)` 去调用任意 `LLMClient`，
/// 再把返回文本交给 `parse(_:limit:)`。
public enum AISuggestionPrompt {

    /// 系统提示词：约束模型的角色、语气与输出格式。
    public static var systemPrompt: String {
        [
            "你是中文输入法的「下一句预测」助手。用户在微信等聊天场景里回消息，",
            "你要根据上下文猜他接下来最可能发出去的那一句话。",
            "",
            "硬性要求：",
            "1. 像真人发消息一样说话：口语、自然、简短，每条不超过 20 个字。",
            "2. 直接给出句子本身：不要解释、不要旁白、不要引号、不要书名号。",
            "3. 每条一行，行首用「1. 2. 3.」编号，条数与用户要求严格一致。",
            "4. 各条之间风格要有差异（例如：直接答应 / 犹豫 / 反问或调侃），不要三句一个意思。",
            "5. 只用简体中文；不确定具体数字、地址、人名时宁可用模糊说法，不要编造。"
        ].joined(separator: "\n")
    }

    /// 生成给 LLM 的用户消息（含上下文末句、当前组字、语气与格式要求）。
    /// - Parameters:
    ///   - context: 输入框里光标前的文本。
    ///   - composing: 当前正在组字的拼音串（可为空）。
    ///   - tone: 语气描述（如「日常聊天」「温柔」「简短直接」），空串按日常聊天处理。
    ///   - count: 期望条数（会被夹到 1...`AISuggestionPolicy.maximumAIResults`）。
    /// - Returns: 可直接作为 user message 的字符串。
    public static func userMessage(context: String,
                                   composing: String,
                                   tone: String,
                                   count: Int) -> String {
        let wanted = max(1, min(count, AISuggestionPolicy.maximumAIResults))
        let rawContext = String(context.suffix(AISuggestionPolicy.maximumContextCharacters))
        let trimmedContext = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = LocalSuggestionIndex.lastSentence(context)
        let composingText = composing.trimmingCharacters(in: .whitespacesAndNewlines)
        let toneText = tone.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = []
        lines.append("【上下文】聊天框里已有的内容：")
        lines.append(trimmedContext.isEmpty ? "（无）" : trimmedContext)
        if !sentence.isEmpty, sentence != trimmedContext {
            lines.append("【最近一句】" + sentence)
        }
        lines.append("【我正在输入】" + (composingText.isEmpty ? "（还没开始打字）" : composingText))
        lines.append("【语气】" + (toneText.isEmpty ? "日常聊天" : toneText))
        lines.append("")
        lines.append("请给出 \(wanted) 条我接下来最可能发出去的回复候选。")
        lines.append("要求：")
        lines.append("- 恰好 \(wanted) 条，每条一行，行首用「\(numberingHint(wanted))」编号")
        lines.append("- 每条不超过 20 个字，口语化；不要解释、不要引号")
        lines.append("- 各条之间风格要有差异")
        return lines.joined(separator: "\n")
    }

    /// 解析模型返回文本为候选数组。
    ///
    /// 容错范围：`1.` / `1、` / `1)` / `（1）` 编号、Markdown 代码围栏、项目符号、
    /// 行内多编号（`1.好的 2.不行`）、分号分隔、多余空行、包裹的引号、结尾句号。
    /// 会丢弃空行、超长行（>32 字，多半是解释而不是候选）与重复项。
    /// - Parameters:
    ///   - raw: 模型返回的原始文本。
    ///   - limit: 最多要几条。
    /// - Returns: 按置信度降序的候选数组（可能为空，调用方应保留 L1 结果）。
    public static func parse(_ raw: String, limit: Int) -> [ContextualSuggestion] {
        guard limit > 0, !raw.isEmpty else { return [] }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var results: [ContextualSuggestion] = []
        var seen: Set<String> = []
        for line in normalized.components(separatedBy: "\n") {
            for segment in splitBySemicolon(line) {
                for piece in splitByInlineNumbering(segment) {
                    let cleaned = sanitize(piece)
                    guard !cleaned.isEmpty, cleaned.count <= 32 else { continue }
                    guard seen.insert(cleaned).inserted else { continue }
                    let confidence = max(0.5, 0.86 - 0.08 * Double(results.count))
                    results.append(ContextualSuggestion(text: cleaned,
                                                        source: .ai,
                                                        confidence: confidence))
                    if results.count >= limit {
                        return results
                    }
                }
            }
        }
        return results
    }

    // MARK: - 解析辅助

    /// 生成编号提示，如 `1. 2. 3.`。
    /// - Parameter count: 条数。
    /// - Returns: 编号提示串。
    private static func numberingHint(_ count: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(count)
        for index in 1...max(1, count) {
            parts.append("\(index).")
        }
        return parts.joined(separator: " ")
    }

    /// 按分号切分一行（模型偶尔用「；」分隔多条）。
    /// - Parameter line: 一行文本。
    /// - Returns: 切分结果。
    private static func splitBySemicolon(_ line: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in line {
            if character == "；" || character == ";" {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces
    }

    /// 按行内编号切分（`1.好的 2.不行` → `好的`、`不行`）。
    /// - Parameter line: 一行文本。
    /// - Returns: 切分结果。
    private static func splitByInlineNumbering(_ line: String) -> [String] {
        let characters = Array(line)
        var pieces: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if isASCIIDigit(character), index + 1 < characters.count {
                let next = characters[index + 1]
                let isNumbering: Bool
                switch next {
                case ".", "、", ")", "）", "．", ":", "：":
                    isNumbering = true
                default:
                    isNumbering = false
                }
                var atBoundary = current.isEmpty
                if let last = current.last {
                    atBoundary = last.isWhitespace || last == "，"
                }
                if isNumbering, atBoundary {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pieces.append(current)
                    }
                    current = ""
                    index += 2
                    continue
                }
            }
            current.append(character)
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    /// 清洗单条候选：去掉编号、项目符号、包裹引号、结尾句号。
    /// - Parameter raw: 原始片段。
    /// - Returns: 清洗结果（无效时返回空串）。
    private static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.hasPrefix("```") || text.hasPrefix("~~~") {
            return ""
        }

        var continuing = true
        while continuing, !text.isEmpty {
            continuing = false

            guard let first = text.first else { break }

            // 项目符号 / 引用符号
            if first == "-" || first == "•" || first == "*" || first == "·" || first == ">" {
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuing = true
                continue
            }

            // （1） / (1)
            if first == "(" || first == "（" {
                if let closing = text.firstIndex(where: { $0 == ")" || $0 == "）" }) {
                    let inner = text[text.index(after: text.startIndex)..<closing]
                    if !inner.isEmpty, inner.allSatisfy({ isASCIIDigit($0) }) {
                        text = String(text[text.index(after: closing)...])
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuing = true
                        continue
                    }
                }
            }

            // 1. / 1、 / 1) / 1：
            if isASCIIDigit(first) {
                var cursor = text.startIndex
                while cursor < text.endIndex, isASCIIDigit(text[cursor]) {
                    cursor = text.index(after: cursor)
                }
                if cursor < text.endIndex {
                    switch text[cursor] {
                    case ".", "、", ")", "）", "．", ":", "：":
                        text = String(text[text.index(after: cursor)...])
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuing = true
                    default:
                        break
                    }
                }
                if continuing {
                    continue
                }
            }
        }

        // 去掉包裹的引号
        let quotes: Set<Character> = ["\"", "'", "“", "”", "「", "」", "『", "』", "《", "》"]
        while let first = text.first, quotes.contains(first) {
            text.removeFirst()
        }
        while let last = text.last, quotes.contains(last) {
            text.removeLast()
        }
        // 去掉结尾的句号/逗号/顿号（聊天里一般不写）
        while let last = text.last, last == "。" || last == "，" || last == "、" {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 判断是否为 ASCII 数字（`0`...`9`）。
    /// - Parameter character: 待判断字符。
    /// - Returns: 是返回 `true`。
    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}
