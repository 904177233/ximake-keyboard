//
//  PromptTemplate.swift
//  ios/Shared/Prompts
//
//  模块职责：定义提示词模板数据结构（`PromptTemplate`）与占位符渲染工具。
//            模板把「系统提示词 + 用户模板」打包成一个可持久化、可编辑的单元，
//            UI 侧只需选择模板并传入文本即可得到渲染后的 `[ChatMessage]`。
//  依赖：Foundation、`Models`（AIFeature / ChatMessage）。
//  使用方：`PromptLibrary`（内置模板与自定义模板）、宿主 App 的提示词编辑页、键盘 AI 面板。
//

import Foundation

/// 提示词模板。
///
/// 字段顺序与 docs/02 §4.4 一致：`id / title / systemImage / feature / systemPrompt / userTemplate / temperature / isBuiltIn`。
///
/// 支持的占位符（在 `userTemplate` 与 `systemPrompt` 中均可使用）：
/// - `{{text}}` —— 用户输入/选中的原文（必填，缺失时兜底为空串）
/// - `{{context}}` —— 上下文（前文、剪贴板、聊天记录等，可空）
/// - `{{tone}}` —— 语气（如「自然」「正式」「温柔」）
/// - `{{target_language}}` —— 目标语言（翻译类模板使用）
/// - `{{reply_count}}` —— 条数（回复建议类模板使用）
///
/// 支持的**条件段落**（`{{#key}}…{{/key}}`，CONTRACT-ADD）：
/// - `values[key]` 非空 → 保留段落内容（标记去掉，内部占位符照常替换）；
/// - 为空或不存在 → 整段（含标记与其中内容）删除；
/// - 用于「有上文才显示（聊天窗口上文）」这类段落，避免 `context` 为空时留下
///   一个空标题行（例如 AI 对话、智能联想模板）；支持嵌套，花括号内允许空格。
///
/// 渲染规则：
/// - 占位符两侧可有空格（`{{ text }}` 同样识别）；
/// - 未知占位符原样保留（便于用户手里老的模板不至于报错）；
/// - `{{text}}` 缺失时替换为空串，并在渲染后裁剪首尾空白，避免产生悬空的句式。
public struct PromptTemplate: Identifiable, Codable, Equatable, Sendable {

    /// 唯一标识（内置模板用稳定字符串，如 `"builtin.polish"`；自定义模板用 UUID 字符串）。
    public let id: String
    /// 展示名（中文，如「润色」）。
    public let title: String
    /// SF Symbol 名（如 `"wand.and.stars"`）。
    public let systemImage: String
    /// 关联的 AI 能力（决定出现在哪个入口下）。
    public let feature: AIFeature
    /// 系统提示词（约束模型角色与输出格式）。
    public let systemPrompt: String
    /// 用户模板（含占位符，通常以 `{{text}}` 结尾）。
    public let userTemplate: String
    /// 采样温度（0...2，越低越稳定）。
    public let temperature: Double
    /// 是否为内置模板（内置不可删除、可「复制为自定义」）。
    public let isBuiltIn: Bool

    /// 创建提示词模板。
    ///
    /// - Parameters:
    ///   - id: 唯一标识。
    ///   - title: 展示名。
    ///   - systemImage: SF Symbol 名。
    ///   - feature: 关联能力。
    ///   - systemPrompt: 系统提示词。
    ///   - userTemplate: 用户模板（含占位符）。
    ///   - temperature: 采样温度，默认 0.3。
    ///   - isBuiltIn: 是否内置，默认 false。
    public init(
        id: String,
        title: String,
        systemImage: String,
        feature: AIFeature,
        systemPrompt: String,
        userTemplate: String,
        temperature: Double = 0.3,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.feature = feature
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.temperature = AIProviderConfig.clampTemperature(temperature)
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - 容错解码

    private enum CodingKeys: String, CodingKey {
        case id, title, systemImage, feature, systemPrompt, userTemplate, temperature, isBuiltIn
    }

    /// 容错解码：老快照缺字段时用默认值补齐，避免整份自定义模板丢失。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
        let rawTitle = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        let rawImage = (try? container.decodeIfPresent(String.self, forKey: .systemImage)) ?? nil
        let rawFeature = (try? container.decodeIfPresent(AIFeature.self, forKey: .feature)) ?? nil
        let rawSystem = (try? container.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? nil
        let rawUser = (try? container.decodeIfPresent(String.self, forKey: .userTemplate)) ?? nil
        let rawTemperature = (try? container.decodeIfPresent(Double.self, forKey: .temperature)) ?? nil
        let rawBuiltIn = (try? container.decodeIfPresent(Bool.self, forKey: .isBuiltIn)) ?? nil

        self.id = rawID ?? UUID().uuidString
        self.title = rawTitle ?? "未命名模板"
        self.systemImage = rawImage ?? "text.bubble"
        self.feature = rawFeature ?? .custom
        self.systemPrompt = rawSystem ?? "你是聊天输入法内的改写助手。"
        self.userTemplate = rawUser ?? "{{text}}"
        self.temperature = AIProviderConfig.clampTemperature(rawTemperature ?? 0.3)
        self.isBuiltIn = rawBuiltIn ?? false
    }

    /// 编码（字段与解码一一对应）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(systemImage, forKey: .systemImage)
        try container.encode(feature, forKey: .feature)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(userTemplate, forKey: .userTemplate)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
    }

    // MARK: - 渲染

    /// 渲染为一条 `ChatMessage` 的用户消息内容（不含 system）。
    ///
    /// - Parameters:
    ///   - text: 原文。
    ///   - context: 上下文，默认空串。
    ///   - tone: 语气，默认「自然」。
    ///   - targetLanguage: 目标语言，默认「英文」。
    ///   - replyCount: 条数，默认 3。
    /// - Returns: 替换占位符后的用户消息正文。
    public func renderUserContent(
        text: String,
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3
    ) -> String {
        let replacements = PromptTemplate.placeholderValues(
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
        let rendered = PromptTemplate.substitute(userTemplate, with: replacements)
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    /// 渲染 systemPrompt（把语气/条数/目标语言等也注入进去）。
    public func renderSystemPrompt(
        text: String = "",
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3
    ) -> String {
        let replacements = PromptTemplate.placeholderValues(
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
        return PromptTemplate.substitute(systemPrompt, with: replacements)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 渲染为完整的对话消息数组（system + user）。
    ///
    /// - Returns: `[system, user]`；systemPrompt 为空时只返回 user。
    public func renderMessages(
        text: String,
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let system = renderSystemPrompt(
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
        if !system.isEmpty {
            messages.append(.system(system))
        }
        messages.append(.user(
            renderUserContent(
                text: text,
                context: context,
                tone: tone,
                targetLanguage: targetLanguage,
                replyCount: replyCount
            )
        ))
        return messages
    }

    // MARK: - 占位符工具（纯函数，便于单测）

    /// 组装占位符 → 值 的映射。
    static func placeholderValues(
        text: String,
        context: String,
        tone: String,
        targetLanguage: String,
        replyCount: Int
    ) -> [String: String] {
        let clampedCount = min(max(replyCount, 1), 5)
        let trimmedTone = tone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "text": text,
            "context": context,
            "tone": trimmedTone.isEmpty ? "自然" : trimmedTone,
            "target_language": trimmedLanguage.isEmpty ? "英文" : trimmedLanguage,
            "reply_count": "\(clampedCount)"
        ]
    }

    /// 替换模板中的 `{{key}}` 占位符（允许花括号内有空格）；未知占位符原样保留。
    ///
    /// 先处理条件段落（`{{#key}}…{{/key}}`），再替换普通占位符。
    static func substitute(_ template: String, with values: [String: String]) -> String {
        let resolved = resolveConditionals(template, with: values)
        var result = resolved
        for (key, value) in values {
            result = result
                .replacingOccurrences(of: "{{\(key)}}", with: value)
                .replacingOccurrences(of: "{{ \(key) }}", with: value)
                .replacingOccurrences(of: "{{\(key) }}", with: value)
                .replacingOccurrences(of: "{{ \(key)}}", with: value)
        }
        return result
    }

    /// 处理条件段落标记 `{{#key}}…{{/key}}`。
    ///
    /// - `values[key]` 去空白后非空 → 保留段落内容；
    /// - 否则整段删除。
    ///
    /// 由内向外逐层消解（每轮只匹配「内部不含其它 `{{#`」的最内层段落），
    /// 因此支持嵌套；最多 32 轮，成对标记异常时保持原样不报错（模板是用户可编辑的）。
    static func resolveConditionals(_ template: String, with values: [String: String]) -> String {
        guard template.contains("{{#") else { return template }

        // 最内层：开标记后到闭标记之间不允许再出现 `{{#`（用惰性匹配 + 显式排除）。
        let pattern = "\\{\\{#\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\}\\}"
            + "((?:(?!\\{\\{#)[\\s\\S])*?)"
            + "\\{\\{/\\s*\\1\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }

        var result = template
        var rounds = 0
        while result.contains("{{#"), rounds < 32 {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: range)
            guard !matches.isEmpty else { break }

            var rebuilt = ""
            var cursor = result.startIndex
            for match in matches {
                guard let fullRange = Range(match.range, in: result),
                      let keyRange = Range(match.range(at: 1), in: result),
                      let bodyRange = Range(match.range(at: 2), in: result) else {
                    continue
                }
                rebuilt += result[cursor..<fullRange.lowerBound]
                let key = String(result[keyRange])
                let body = String(result[bodyRange])
                let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty {
                    rebuilt += body
                }
                cursor = fullRange.upperBound
            }
            rebuilt += result[cursor...]
            result = rebuilt
            rounds += 1
        }
        return result
    }

    // MARK: - 便捷构造

    /// 复制为一份新的自定义模板（生成新 `id`，`isBuiltIn = false`）。
    ///
    /// 用于内置模板「另存为自定义」：内置 id 稳定，用户改动不会影响其它设备/其它版本。
    ///
    /// - Parameter newTitle: 可选的新标题，默认在原标题后加「（自定义）」。
    /// - Returns: 可直接写回 `PromptLibrary.saveCustom(_:)` 的新模板。
    public func duplicatedAsCustom(newTitle: String? = nil) -> PromptTemplate {
        PromptTemplate(
            id: UUID().uuidString,
            title: newTitle ?? "\(title)（自定义）",
            systemImage: systemImage,
            feature: feature,
            systemPrompt: systemPrompt,
            userTemplate: userTemplate,
            temperature: temperature,
            isBuiltIn: false
        )
    }

    /// 用新内容替换模板（保留 id / feature / 内置标记）。
    ///
    /// - Parameters:
    ///   - newTitle: 新标题。
    ///   - newSystemPrompt: 新系统提示词。
    ///   - newUserTemplate: 新用户模板。
    ///   - newTemperature: 新温度。
    /// - Returns: 替换后的模板。
    public func replacing(
        title newTitle: String? = nil,
        systemPrompt newSystemPrompt: String? = nil,
        userTemplate newUserTemplate: String? = nil,
        temperature newTemperature: Double? = nil
    ) -> PromptTemplate {
        PromptTemplate(
            id: id,
            title: newTitle ?? title,
            systemImage: systemImage,
            feature: feature,
            systemPrompt: newSystemPrompt ?? systemPrompt,
            userTemplate: newUserTemplate ?? userTemplate,
            temperature: newTemperature ?? temperature,
            isBuiltIn: isBuiltIn
        )
    }
}
