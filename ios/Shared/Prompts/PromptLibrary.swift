//
//  PromptLibrary.swift
//  ios/Shared/Prompts
//
//  模块职责：提示词模板的统一入口——内置模板查询、自定义模板的读写（持久化到 SharedStore）、
//            模板 → `[ChatMessage]` 的渲染，以及生图提示词增强 / AI 对话 / 智能联想
//            三类专用请求的构造与联想结果解析。
//  依赖：Foundation、`Models`（AIFeature / ChatMessage / ChatRequest）、`Storage`（SharedStore）。
//  使用方：键盘扩展 AI 面板、键盘 AI 对话面板（`chatRequest(...)`）、
//          候选栏智能联想（`suggestionRequest(...)` / `parseSuggestionCandidates(_:)`）、
//          宿主 App 的 PlaygroundView / PromptLibraryView、
//          `ios/AIKeyboard/Support/SharedBridge.swift`（PromptCatalog）。
//
//  存储键：`moyu.prompts.custom.v1`（JSON 数组，见 `SharedStore`）。
//  渲染约定：见 `PromptTemplate` 的文档；「回复建议」输出格式为恰好 N 条、每条一行、
//            行首 `1.` `2.` `3.`（N 由 `{{reply_count}}` 注入，默认 3）。
//            「智能联想」输出格式为 JSON 数组（design/04 §4.4），解析失败静默为空。
//

import Foundation

/// 提示词模板库。
///
/// 典型用法（键盘侧）：
/// ```swift
/// let messages = PromptLibrary.render(
///     .polish,
///     text: proxy.documentContextBeforeInput ?? "",
///     context: "",
///     tone: "自然",
///     targetLanguage: "英文"
/// )
/// let stream = AIClientFactory.makeLLM(config: config, apiKey: key)
///     .stream(ChatRequest(messages: messages))
/// ```
public enum PromptLibrary {

    // MARK: - 存储键

    /// 自定义模板在 `SharedStore` 中的存储键。
    public static let customStorageKey = "moyu.prompts.custom.v1"

    // MARK: - 内置模板

    /// 全部内置模板（16 条，见 `BuiltInPrompts.all`）。
    public static var builtIn: [PromptTemplate] {
        BuiltInPrompts.all
    }

    /// 某个能力下的全部模板（内置在前，自定义在后）。
    ///
    /// - Parameter feature: AI 能力。
    /// - Returns: 该能力下的模板；`loadCustom()` 失败时退化为仅内置。
    public static func templates(feature: AIFeature) -> [PromptTemplate] {
        let builtInTemplates = BuiltInPrompts.templates(for: feature)
        let customTemplates = loadCustom().filter { $0.feature == feature }
        return builtInTemplates + customTemplates
    }

    /// 按 id 查模板（先查内置，再查自定义）。
    ///
    /// - Parameter id: 模板 id，例如 `"builtin.polish"` 或自定义模板的 UUID 字符串。
    /// - Returns: 命中的模板；未命中返回 nil。
    public static func template(id: String) -> PromptTemplate? {
        if let matched = BuiltInPrompts.template(id: id) {
            return matched
        }
        return loadCustom().first { $0.id == id }
    }

    /// 某个能力的默认模板（`AIFeature.defaultTemplateID` 命中的内置模板）。
    ///
    /// - Parameter feature: AI 能力。
    /// - Returns: 默认模板；内置缺失时退回该能力下的第一条。
    public static func defaultTemplate(for feature: AIFeature) -> PromptTemplate? {
        if let matched = BuiltInPrompts.template(id: feature.defaultTemplateID) {
            return matched
        }
        return BuiltInPrompts.templates(for: feature).first
    }

    // MARK: - 渲染

    /// 按能力渲染消息（使用该能力的默认模板）。
    ///
    /// - Parameters:
    ///   - feature: AI 能力。
    ///   - text: 原文（必填）。
    ///   - context: 上下文，默认空串。
    ///   - tone: 语气，默认「自然」。
    ///   - targetLanguage: 目标语言，默认「英文」（仅翻译类模板使用）。
    ///   - replyCount: 条数，默认 3（仅回复建议类模板使用）。
    /// - Returns: `[system, user]`；找不到默认模板时返回只含用户原文的最小消息数组。
    public static func render(
        feature: AIFeature,
        text: String,
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3
    ) -> [ChatMessage] {
        guard let template = defaultTemplate(for: feature) else {
            return fallbackMessages(text: text, systemPrompt: nil)
        }
        return render(
            template,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
    }

    /// 按能力和指定模板 id 渲染消息。
    ///
    /// - Parameters:
    ///   - feature: AI 能力（用于兜底）。
    ///   - templateID: 模板 id；传 nil 或找不到时使用该能力的默认模板。
    ///   - text: 原文。
    ///   - context: 上下文。
    ///   - tone: 语气。
    ///   - targetLanguage: 目标语言。
    ///   - replyCount: 条数。
    /// - Returns: 渲染后的消息数组。
    public static func render(
        feature: AIFeature,
        templateID: String?,
        text: String,
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3
    ) -> [ChatMessage] {
        let resolved = templateID.flatMap { template(id: $0) } ?? defaultTemplate(for: feature)
        guard let resolved else {
            return fallbackMessages(text: text, systemPrompt: nil)
        }
        return render(
            resolved,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
    }

    /// 渲染指定模板（docs/02 §4.4 的基础签名）。
    ///
    /// - Parameters:
    ///   - template: 模板。
    ///   - text: 原文。
    ///   - context: 上下文。
    ///   - tone: 语气。
    ///   - targetLanguage: 目标语言。
    /// - Returns: `[system, user]`（systemPrompt 为空时只有 user）。
    public static func render(
        _ template: PromptTemplate,
        text: String,
        context: String,
        tone: String,
        targetLanguage: String
    ) -> [ChatMessage] {
        render(
            template,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: 3
        )
    }

    /// 渲染指定模板（带条数与温度覆盖的完整签名）。
    ///
    /// - Parameters:
    ///   - template: 模板。
    ///   - text: 原文。
    ///   - context: 上下文（前文、剪贴板、聊天记录）。
    ///   - tone: 语气（自然/正式/温柔…）。
    ///   - targetLanguage: 目标语言（翻译类模板使用）。
    ///   - replyCount: 条数（回复建议类模板使用，clamp 1...5）。
    ///   - temperature: 温度覆盖；nil 用模板自带值。
    /// - Returns: `[system, user]`；`text` 为空时仍返回消息（由调用方决定是否发请求）。
    public static func render(
        _ template: PromptTemplate,
        text: String,
        context: String,
        tone: String,
        targetLanguage: String,
        replyCount: Int,
        temperature: Double? = nil
    ) -> [ChatMessage] {
        let system = template.renderSystemPrompt(
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
        let user = template.renderUserContent(
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
        var messages: [ChatMessage] = []
        if !system.isEmpty {
            messages.append(.system(system))
        }
        messages.append(.user(user))
        // 温度由调用方在 ChatRequest 里显式传入（见 `makeRequest`），此处不改消息内容。
        _ = temperature
        return messages
    }

    /// 构造一个完整的 `ChatRequest`（自动带上模板温度与 maxTokens）。
    ///
    /// - Parameters:
    ///   - template: 模板。
    ///   - text: 原文。
    ///   - context: 上下文。
    ///   - tone: 语气。
    ///   - targetLanguage: 目标语言。
    ///   - replyCount: 条数。
    ///   - maxTokens: 输出上限；nil 用模板/服务商默认。
    /// - Returns: 可直接交给 `LLMClient.stream(_:)` 的请求。
    public static func makeRequest(
        _ template: PromptTemplate,
        text: String,
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3,
        maxTokens: Int? = nil
    ) -> ChatRequest {
        let messages = render(
            template,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )
        return ChatRequest(
            messages: messages,
            temperature: template.temperature,
            maxTokens: maxTokens,
            stream: true
        )
    }

    // MARK: - 生图提示词增强

    /// 生图「提示词增强」请求：把中文画面描述翻译并增强成英文生图 prompt。
    ///
    /// 供 keyboard-ui 复用：先 `makeLLM().complete(request)` 拿到英文 prompt，
    /// 再把它交给 `AIClientFactory.makeImage().generate(...)`。
    ///
    /// - Parameter text: 中文画面描述。
    /// - Returns: 单轮 `ChatRequest`（temperature 0.6，maxTokens 400，非流式更省事）。
    public static func imagePromptEnhanceRequest(_ text: String) -> ChatRequest {
        let template = BuiltInPrompts.imagePrompt
        let messages = render(
            template,
            text: text,
            context: "",
            tone: "自然",
            targetLanguage: "英文"
        )
        return ChatRequest(
            messages: messages,
            temperature: template.temperature,
            maxTokens: 400,
            stream: false
        )
    }

    /// 生图提示词增强（流式版本，需要边出边显示时用）。
    ///
    /// - Parameter text: 中文画面描述。
    /// - Returns: 单轮 `ChatRequest`（`stream: true`）。
    public static func imagePromptEnhanceStreamRequest(_ text: String) -> ChatRequest {
        var request = imagePromptEnhanceRequest(text)
        request = ChatRequest(
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            stream: true
        )
        return request
    }

    // MARK: - AI 对话（design/04 §3）

    /// 对话单次回答的 token 上限（中文约 300~400 字，够键盘内对话用）。
    /// 对话的默认输出上限（512）。v1.3 起真实调用点改传 `nil`（由客户端按模型兜底）。
    public static let chatMaxTokens: Int = 512

    /// 对话的系统提示词（`builtin.chat.assistant` 渲染后的成品）。
    ///
    /// 给「不想用 `chatRequest`、要自己拼多轮」的调用方取现成人设用；
    /// 优先推荐直接用 `chatRequest(text:context:history:)`。
    public static var chatSystemPrompt: String {
        BuiltInPrompts.chatAssistant.renderSystemPrompt()
    }

    /// 构造 AI 对话的一轮请求（单轮问答，多轮历史由调用方拼进 `history`）。
    ///
    /// 为什么单开这个方法而不是复用 `render(...)`：
    /// 1. 对话需要**多轮历史**（`[user, assistant, …, user]`），`render` 只产出 `[system, user]`；
    /// 2. 对话的 `maxTokens` 要比改写类大（默认 512），而 `PromptTemplate` 没有 `maxTokens` 字段
    ///    （docs/02 §4.4 的字段是冻结契约，不能加），只能在请求构造处注入；
    /// 3. 对话不需要 `tone / targetLanguage / replyCount` 这些改写类占位符。
    ///
    /// - Parameters:
    ///   - text: 用户这一轮说的话。
    ///   - context: 聊天窗口里的上文（可空；为空时模板里的「（聊天窗口上文）」整段消失）。
    ///   - history: **本轮之前**的对话轮次（按时间正序，可含 system / user / assistant）。
    ///     若调用方把本轮用户消息也塞进了 `history`（末尾已与 `text` 渲染结果相同），
    ///     这里会自动跳过追加，避免出现两条一样的 user 消息。
    ///   - maxTokens: 单次回答上限，默认 `chatMaxTokens`(512)。
    /// - Returns: `stream: true` 的 `ChatRequest`；`messages` = `[system] + history + [user]`。
    public static func chatRequest(
        text: String,
        context: String = "",
        history: [ChatMessage] = [],
        maxTokens: Int = PromptLibrary.chatMaxTokens
    ) -> ChatRequest {
        let template = BuiltInPrompts.chatAssistant
        let system = template.renderSystemPrompt(
            text: text,
            context: context,
            tone: "自然",
            targetLanguage: "英文"
        )
        let userContent = template.renderUserContent(
            text: text,
            context: context,
            tone: "自然",
            targetLanguage: "英文"
        )
        let finalUserContent = userContent.isEmpty ? "你好" : userContent
        var messages: [ChatMessage] = []
        if !system.isEmpty {
            messages.append(.system(system))
        }
        // 历史里若已含 system（例如上次请求原样回传），去掉重复的那条，避免两家 system。
        let historyWithoutSystem = history.filter { $0.role != .system }
        messages.append(contentsOf: historyWithoutSystem)
        // 调用方把本轮也放进 history 的写法：末尾已是同一条 user 就不再追加。
        let alreadyAppended = historyWithoutSystem.last.map {
            $0.role == .user && $0.content == finalUserContent
        } ?? false
        if !alreadyAppended {
            messages.append(.user(finalUserContent))
        }
        return ChatRequest(
            messages: messages,
            temperature: template.temperature,
            maxTokens: maxTokens,
            stream: true
        )
    }

    // MARK: - 智能联想（design/04 §4）

    /// 智能联想的输出上限（`maxTokens = 120`）。三条 12 字短句 + JSON 括号足够。
    public static let suggestionMaxTokens: Int = 120

    /// 构造智能联想请求（`stream: false`，一次拿完更省事、也便于 1.5s 超时控制）。
    ///
    /// - Parameters:
    ///   - context: 聊天窗口里的上文（design/04 §4.4：≤ 200 字，由调用方裁剪）。
    ///   - text: 用户已经输入的内容。
    ///   - maxTokens: 输出上限，默认 `suggestionMaxTokens`(120)。
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

    // MARK: - 自定义模板持久化

    /// 读取用户自定义模板。
    ///
    /// - Returns: 自定义模板数组；从未保存过或解析失败时返回空数组。
    public static func loadCustom() -> [PromptTemplate] {
        guard let data = SharedStore.shared.data(forKey: customStorageKey) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([PromptTemplate].self, from: data) else {
            // 数据损坏时不抛错（键位在共享层，抛错会让键盘整体不可用），退化为空列表。
            return []
        }
        return decoded
    }

    /// 保存用户自定义模板（整体覆盖）。
    ///
    /// - Parameter templates: 自定义模板数组（内置模板不应写入这里，会被 `isBuiltIn` 标记过滤）。
    public static func saveCustom(_ templates: [PromptTemplate]) {
        let sanitized = templates.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        SharedStore.shared.setData(data, forKey: customStorageKey)
    }

    /// 新增或更新一条自定义模板（按 id 覆盖，不存在则追加）。
    ///
    /// - Parameter template: 自定义模板（`isBuiltIn` 会被强制置为 false）。
    public static func upsertCustom(_ template: PromptTemplate) {
        var templates = loadCustom()
        let normalized = template.replacing().withBuiltInFlag(false)
        if let index = templates.firstIndex(where: { $0.id == normalized.id }) {
            templates[index] = normalized
        } else {
            templates.append(normalized)
        }
        saveCustom(templates)
    }

    /// 删除自定义模板。
    ///
    /// - Parameter id: 模板 id（内置模板 id 会被忽略）。
    public static func removeCustom(id: String) {
        let templates = loadCustom().filter { $0.id != id }
        saveCustom(templates)
    }

    /// 把内置模板「另存为自定义」（生成新 id，不覆盖内置版本）。
    ///
    /// - Parameters:
    ///   - template: 内置模板（或其副本）。
    ///   - newTitle: 可选新标题。
    /// - Returns: 写入存储后的新模板。
    @discardableResult
    public static func duplicateAsCustom(_ template: PromptTemplate, newTitle: String? = nil) -> PromptTemplate {
        let duplicated = template.duplicatedAsCustom(newTitle: newTitle)
        upsertCustom(duplicated)
        return duplicated
    }

    // MARK: - 内部辅助

    /// 兜底消息（模板缺失时仍能跑一次最小请求）。
    private static func fallbackMessages(text: String, systemPrompt: String?) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(text.isEmpty ? "请继续。" : text))
        return messages
    }
}

// MARK: - 便捷扩展

extension PromptTemplate {
    /// 返回一份 `isBuiltIn` 被强制设置成指定值的副本（用于把内置模板转成自定义模板）。
    ///
    /// - Parameter flag: 目标内置标记，通常传 false。
    /// - Returns: 仅 `isBuiltIn` 不同的新模板。
    func withBuiltInFlag(_ flag: Bool) -> PromptTemplate {
        PromptTemplate(
            id: id,
            title: title,
            systemImage: systemImage,
            feature: feature,
            systemPrompt: systemPrompt,
            userTemplate: userTemplate,
            temperature: temperature,
            isBuiltIn: flag
        )
    }
}
