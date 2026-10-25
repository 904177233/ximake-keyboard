//
//  OpenAICompatibleClient.swift
//  ios/Shared/Networking
//
//  模块职责：实现 OpenAI 兼容协议（`POST {base}/chat/completions`）的流式与一次性对话，
//            覆盖 DeepSeek / 通义千问（兼容模式）/ Kimi / 智谱 GLM / 火山方舟 / OpenRouter /
//            硅基流动 / OpenAI 以及绝大多数中转站。
//  依赖：Foundation、Models、SSEParser、HTTPTransport、AIError。
//  使用方：AIClientFactory.makeLLM → 键盘扩展 AIService、宿主 App PlaygroundView。
//

import Foundation

/// OpenAI 兼容协议的文本对话客户端。
///
/// 请求约定：
/// - `POST {base}/chat/completions`
/// - Header：`Authorization: Bearer <key>`、`Content-Type: application/json`
/// - Body：`{"model": ..., "messages": [...], "temperature": ..., "max_tokens": ..., "stream": true}`
/// - 流式响应：`data: {"choices":[{"delta":{"content":"..."},"finish_reason":null}]}`，末尾 `data: [DONE]`
///
/// 关于 `reasoning_content`：DeepSeek Reasoner / o1 / o3 / QwQ 等推理模型会在 delta 里
/// 附带思维链，并且**先长时间只吐思维链、之后才吐正文**。本客户端始终把它解析出来，
/// 通过 `ChatDelta.reasoning` 旁路交给上层（不会拼进 `text`，避免把「内心独白」当答案），
/// 同时给推理模型的 `max_tokens` 兜底（见 `resolvedMaxTokens`），避免预算全被思维链吃掉、
/// 正文一个字都不剩。
public final class OpenAICompatibleClient: LLMClient, @unchecked Sendable {

    /// 服务商配置（不可变，值类型拷贝）。
    private let config: AIProviderConfig
    /// 明文的 API Key。
    private let apiKey: String
    /// 是否收集推理模型的 `reasoning_content`。
    ///
    /// - Note: 保留此参数只为源码兼容（既有调用方仍在传），行为上**已不再生效**：
    ///   思维链现在一律解析并转发到 `ChatDelta.reasoning`，由 UI 自行决定是否展示。
    private let capturesReasoning: Bool
    /// 复用的 URLSession。
    private let session: URLSession

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - config: 服务商配置。
    ///   - apiKey: 明文 Key（为空时首次请求抛 `.missingAPIKey`）。
    ///   - capturesReasoning: 是否收集 `reasoning_content`，默认 false。
    public init(config: AIProviderConfig, apiKey: String, capturesReasoning: Bool = false) {
        self.config = config
        self.apiKey = apiKey
        self.capturesReasoning = capturesReasoning
        self.session = HTTPTransport.makeSession(timeout: config.timeout)
    }

    // MARK: - LLMClient

    /// 流式对话。取消 `Task` 会立即中断底层 URLSession 任务。
    ///
    /// 注意这里必须**强持有** `self`（`Task { [self] in … }`，不能写 `[weak self]`）：
    /// 调用方常见的写法是 `let client = AIClientFactory.makeLLM(...)` 然后立刻
    /// `return client.stream(request)`（探活探针 `ConnectivityProbe.makeHelloStream` 就是这样）。
    /// 若 Task 只弱引用 self，client 在函数返回瞬间被释放，流会立刻以
    /// `AIError.cancelled` 结束 —— 上层把它当成「用户主动取消」而静默忽略，
    /// 表现就是「点测试连接没有任何反应」。`onTermination` 里仍会取消 task，
    /// 因此不存在强引用循环。
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await self.runStream(request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: AIError.wrap(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 一次性对话（`stream: false`）。
    public func complete(_ request: ChatRequest) async throws -> ChatResult {
        try checkPreconditions()
        var body = try makeBody(request, stream: false)
        body["stream"] = false
        guard let url = config.resolvedURL(path: "/chat/completions") else {
            throw AIError.notConfigured
        }
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .bearer(apiKey),
            extraHeaders: config.extraHeaders,
            timeout: config.timeout,
            body: body
        )
        let (data, _) = try await HTTPTransport.send(urlRequest, session: session)
        do {
            return try parseCompletion(data: data)
        } catch {
            throw decorate(error, url: url)
        }
    }

    /// 给错误补上「实际请求到哪、用的是哪个模型」。
    ///
    /// 「配置好却报错」绝大多数是 baseURL 或模型名写错，而错误文案里原本只有
    /// 服务端那一句话，用户根本不知道客户端到底把请求发去了哪。
    /// 这里把**解析后的完整 URL + 模型名**追加进去，一次就能看出问题。
    ///
    /// 只装饰「排查类」错误（服务端报错 / 解析失败 / 正文为空 / 未知），
    /// 鉴权、限流、超时、网络这些文案本身已经足够明确，不再加噪。
    private func decorate(_ error: Error, url: URL?) -> AIError {
        let wrapped = AIError.wrap(error)
        let detail: String = {
            var parts: [String] = []
            if let url { parts.append("请求地址 \(url.absoluteString)") }
            parts.append("模型 \(config.model.isEmpty ? "（空）" : config.model)")
            return "\n（诊断：\(parts.joined(separator: " · "))）"
        }()
        switch wrapped {
        case let .server(code, message):
            return .server(code: code, message: (message ?? "") + detail)
        case let .decoding(text):
            return .decoding(text + detail)
        case let .contentRejected(reason):
            return .contentRejected((reason ?? "") + detail)
        case let .unknown(text):
            return .unknown(text + detail)
        default:
            return wrapped
        }
    }

    // MARK: - 内部实现

    /// 前置校验：baseURL / 模型 / API Key。
    private func checkPreconditions() throws {
        guard config.isChatConfigured else {
            throw AIError.notConfigured
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
    }

    /// 构造请求体（使用 [String: Any] 以便携带服务商自定义字段）。
    private func makeBody(_ request: ChatRequest, stream: Bool) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        for message in request.messages {
            messages.append([
                "role": message.role.rawValue,
                "content": message.content
            ])
        }
        guard !messages.isEmpty else {
            throw AIError.notConfigured
        }
        let maxTokens = resolvedMaxTokens(request)
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": AIProviderConfig.clampMaxTokens(maxTokens),
            "stream": stream
        ]
        // 推理模型**不下发** `temperature`。
        //
        // OpenAI 的 o1 / o3 只接受 temperature = 1，给别的值直接 400
        // `Unsupported value: 'temperature' does not support 0.7 with this model`；
        // DeepSeek 的 `deepseek-reasoner` 则是「不报错也不生效」。
        // 两种情况下唯一正确的做法都是别发 —— 少一个字段永远不会导致失败。
        if !OpenAICompatibleClient.isReasoningModel(config.model) {
            let temperature = request.temperature ?? config.temperature
            body["temperature"] = AIProviderConfig.clampTemperature(temperature)
        }
        // 注意：这里**不加** `stream_options`。
        //
        // 它是 OpenAI 专有参数，大量「OpenAI 兼容」端点并不认识：DeepSeek 部分版本、
        // 通义 compatible-mode、Kimi、智谱 GLM、硅基流动、部分 OpenRouter 模型都会直接
        // 返回 400 `Unrecognized request argument supplied: stream_options`，
        // 表现为「试验场点了没反应 / 直接失败」。
        // 而流式侧的 usage 本来就没被使用（见 `runStream` 里的 `_ = usage`），
        // 去掉它对功能零损失，换来的是对所有兼容端点可用。
        return body
    }

    /// 计算本次请求的 `max_tokens`。
    ///
    /// 推理模型（`deepseek-reasoner`、`o1` / `o3`、`QwQ`、`*-thinking` …）会**先**把
    /// token 预算全部花在思维链（`reasoning_content`）上，思维链收敛之后才开始产出正文。
    /// 配置里的默认预算（1024）经常连思维链都不够，于是正文一个字都拿不到，
    /// 用户看到的就是「服务商没有返回内容」—— 明明接口是通的。
    ///
    /// 规则：
    /// - 调用方**显式**给了 `maxTokens` → 原样尊重（探活探针只发 "hi"，要的就是小预算快返回）；
    /// - 调用方没给、且模型命中推理模型特征 → `max(config.maxTokens, 4096)`，给正文留出预算；
    /// - 其余情况 → `config.maxTokens`。
    private func resolvedMaxTokens(_ request: ChatRequest) -> Int {
        if let explicit = request.maxTokens {
            return explicit
        }
        guard OpenAICompatibleClient.isReasoningModel(config.model) else {
            // v2.2 修用户反馈「回复还是服务商没有返回内容…你把 token 限制设置高一点，
            // 万一有人有长对话需求怎么办」：非推理模型也保底 2048。
            // 用户把「最大回复长度」调得很小时才用他的值，否则统一按 2048 起。
            return max(config.maxTokens, 2048)
        }
        // 推理模型的思维链本身就要吃掉 1–2k token，4096 在多轮长对话里仍会
        // 让正文被截断，抬到 8192。
        return max(config.maxTokens, 8192)
    }

    /// 模型名是否属于会用 `reasoning_content` 输出思维链的推理模型。
    ///
    /// 特征（全部小写匹配）：含 `reasoner` / `qwq` / `thinking`、含 `-r1`、以 `-r` 结尾，
    /// 或含有独立的 `o1` / `o3` 词（`o1`、`o1-mini`、`o3-mini`）。
    /// `o1` / `o3` 先按分隔符切词再比对，避免把 `gpt-4o-mini` 这类名字误判进推理分支。
    static func isReasoningModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        if lower.contains("reasoner") || lower.contains("qwq") || lower.contains("thinking") {
            return true
        }
        if lower.contains("-r1") || lower.hasSuffix("-r") {
            return true
        }
        let tokens = lower.split(whereSeparator: { "-/.:_ ".contains($0) })
        return tokens.contains { $0 == "o1" || $0 == "o3" }
    }

    /// 执行流式请求。
    private func runStream(
        _ request: ChatRequest,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        try checkPreconditions()
        let body = try makeBody(request, stream: true)
        guard let url = config.resolvedURL(path: "/chat/completions") else {
            throw AIError.notConfigured
        }
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .bearer(apiKey),
            extraHeaders: config.extraHeaders,
            timeout: config.timeout,
            body: body,
            accept: "text/event-stream"
        )

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.decoding("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // 错误体也要读完，否则连接会被提前关闭。
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 64 * 1024 { break }
            }
            throw AIError.fromHTTPStatus(
                httpResponse.statusCode,
                message: HTTPTransport.extractErrorMessage(from: errorData),
                retryAfter: HTTPTransport.retryAfterInterval(from: httpResponse)
            )
        }

        var parser = SSEParser()
        var accumulatedFinishReason: String?
        var didEmitText = false
        // 本次流里是否收到过思维链（推理模型可能只有思维链、正文为空）。
        var sawReasoning = false
        let promptTokens = estimatePromptTokens(request)
        // 兜底用：如果服务端根本没按 SSE 返回（有些「OpenAI 兼容」网关会忽略
        // `stream: true`，直接一次性吐一个完整 JSON），这里要把原始字节留下来，
        // 结束时按非流式响应再解析一次。否则用户只会看到「服务商没有返回内容」。
        var rawBuffer = Data()

        // 带标签的循环：收到 `[DONE]` 时跳到循环外，让「正文为空」的判定统一在末尾执行。
        // 早期版本在这里直接 finish 并 return，于是「推理模型只吐了思维链」被当成正常结束，
        // 上层只能显示一句「服务商没有返回内容」。
        streamLoop: for try await line in bytes.lines {
            try Task.checkCancellation()
            rawBuffer.append(Data((line + "\n").utf8))
            if rawBuffer.count > 1024 * 1024 {
                rawBuffer.removeAll(keepingCapacity: true)
            }
            let events = parser.feed(Data((line + "\n").utf8))
            for event in events {
                if event.isDone {
                    break streamLoop
                }
                guard let payload = parseStreamPayload(event.data) else { continue }
                if payload.finishReason != nil {
                    accumulatedFinishReason = payload.finishReason
                }
                // 思维链单独走 `ChatDelta.reasoning`：不拼进正文（否则打字机会把「思考过程」
                // 当答案显示），也不再像以前那样直接丢弃（丢弃的结果就是正文一片空白）。
                if !payload.reasoning.isEmpty {
                    sawReasoning = true
                    continuation.yield(ChatDelta(text: "", isFinal: false, reasoning: payload.reasoning))
                }
                if !payload.text.isEmpty {
                    didEmitText = true
                    continuation.yield(ChatDelta(text: payload.text, isFinal: false))
                }
                // 某些服务端把 usage 放在最后一片（stream_options.include_usage）。
                if payload.hasUsage, let usage = payload.usage {
                    continuation.yield(ChatDelta(text: "", isFinal: false))
                    _ = usage // 用量仅用于 complete() 聚合，流式侧不额外暴露
                }
            }
        }
        // 兜底：没有 [DONE] 但流已结束。
        for event in parser.flush() {
            if event.isDone { break }
            guard let payload = parseStreamPayload(event.data) else { continue }
            if !payload.reasoning.isEmpty {
                sawReasoning = true
                continuation.yield(ChatDelta(text: "", isFinal: false, reasoning: payload.reasoning))
            }
            if !payload.text.isEmpty {
                didEmitText = true
                continuation.yield(ChatDelta(text: payload.text, isFinal: false))
            }
        }
        // 二级兜底：整段流里一个正文字符都没拿到 —— 说明服务端忽略了 `stream: true`，
        // 一次性回了个非流式体（或者回了不符合 SSE 规范的分片，被 SSEParser 全部漏掉）。
        // 把缓冲区按非流式响应再解析一次，把完整回复一次性吐出来。
        //
        // v2.5 修正：早期这里要求「缓冲区第一个非空白字节是 `{`」才肯兜底，
        // 但实测的网关回的是 `data：{…}`（前缀是 `d`、且冒号是全角），
        // 于是这个判断永远不成立、兜底形同不存在 —— 用户在聊天里照样看到
        // 「服务商没有返回内容」。现在只要缓冲区非空就尝试宽松解析，
        // 解析不出来（真的是垃圾）自然返回 nil，不会误吐内容。
        if !didEmitText, !rawBuffer.isEmpty {
            if let lenient = OpenAICompatibleClient.parseSSEBodyAsCompletion(rawBuffer),
               !lenient.text.isEmpty {
                didEmitText = true
                continuation.yield(ChatDelta(text: lenient.text, isFinal: false))
            } else if let payload = try? parseCompletion(data: rawBuffer),
                      !payload.text.isEmpty {
                // 走到这里说明它确实是一个普通 JSON 对象（服务端忽略 stream:true 的另一种形态）。
                // 用 `try?` 而不是 `try`：缓冲区里可能就是一坨解析不了的东西，
                // 那种情况下应该继续往下走「正文为空」的统一判定，而不是抛一个更晦涩的解码错误。
                didEmitText = true
                continuation.yield(ChatDelta(text: payload.text, isFinal: false))
            }
        }
        // 正文为空时给出「用户能照着改」的中文错误，而不是让上层只显示「服务商没有返回内容」。
        //
        // v2.3：把**原始响应片段**一起带上。用户报「测试连接返回空内容」时，
        // 之前只有一句笼统文案，完全看不出服务端到底回了什么（是空 body、
        // 是 HTML 错误页、还是字段名不一样）。带片段后一次就能定位。
        try throwIfNoTextEmitted(
            sawText: didEmitText,
            sawReasoning: sawReasoning,
            finishReason: accumulatedFinishReason,
            rawSnippet: HTTPTransport.extractPlainText(from: rawBuffer)
        )
        _ = promptTokens
        // 统一在这里补结束标记：`[DONE]` 分支不再自己 yield，避免出现两片 final。
        continuation.yield(ChatDelta(text: "", isFinal: true))
        continuation.finish()
    }

    /// 「正文为空」的统一判定（按优先级抛错）。
    ///
    /// 推理模型的 token 预算被思维链吃光时，服务端照样返回 200、照样正常结束，
    /// 只是正文是空串。不在这里说清楚的话，用户只会看到「服务商没有返回内容」，
    /// 根本想不到是「最大回复长度」太小。
    ///
    /// - Parameters:
    ///   - sawText: 是否已经吐过至少一个正文字符。
    ///   - sawReasoning: 本次是否收到过思维链。
    ///   - finishReason: 累计的 `finish_reason`（可能为 nil）。
    ///   - rawSnippet: 原始响应片段；非空时拼进错误里，方便一眼看出服务端到底回了什么。
    private func throwIfNoTextEmitted(
        sawText: Bool,
        sawReasoning: Bool,
        finishReason: String?,
        rawSnippet: String? = nil
    ) throws {
        guard !sawText else { return }
        // 把原始响应压成一行短片段，最多 160 字。这是排查「返回空内容」最快的手段：
        // 空 body、HTML 错误页、字段名对不上，三种情况片段一眼就能区分。
        let snippet: String = {
            guard let rawSnippet else { return "" }
            let oneLine = rawSnippet
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oneLine.isEmpty else { return "" }
            return "\n服务端原始响应：" + String(oneLine.prefix(160))
        }()
        if finishReason == "length" {
            throw AIError.contentRejected(
                "输出被「最大回复长度」截断了。推理模型的思维链会占用大量 token，"
                    + "请到「高级参数」把最大回复长度调到 2048 以上。" + snippet
            )
        }
        if sawReasoning {
            throw AIError.contentRejected(
                "这是推理模型，本次回复全部用在思维链上了，正文没有产出。"
                    + "请把「最大回复长度」调到 2048 以上，或改用非推理模型（如 deepseek-chat）。"
                    + snippet
            )
        }
        // 既没有正文也没有思维链：多半是「200 但内容不合格」——例如服务端只回了
        // `{"error":...}`、回了 HTML、或字段名不是 choices/delta.content。
        // 只有拿到原始片段，用户（和开发者）才知道下一步该改什么。
        if !snippet.isEmpty {
            throw AIError.contentRejected("服务商返回了 200，但没有解析出任何正文。" + snippet)
        }
        throw AIError.contentRejected("服务商返回了空响应（HTTP 200，body 为空）。")
    }

    /// 解析单片流式数据。
    private struct StreamPayload {
        var text: String = ""
        var finishReason: String?
        var usage: TokenUsage?
        var hasUsage: Bool = false
        var reasoning: String = ""
    }

    /// 解析 `{"choices":[{"delta":{"content":"..."},"finish_reason":"stop"}],"usage":{...}}`。
    private func parseStreamPayload(_ raw: String) -> StreamPayload? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var payload = StreamPayload()
        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any] {
                if let content = delta["content"] as? String {
                    payload.text = content
                }
                if let reasoning = delta["reasoning_content"] as? String {
                    payload.reasoning = reasoning
                }
            }
            if let finishReason = first["finish_reason"] as? String {
                payload.finishReason = finishReason
            }
        }
        if let usage = root["usage"] as? [String: Any] {
            payload.hasUsage = true
            payload.usage = OpenAICompatibleClient.parseUsage(usage)
        }
        return payload
    }

    /// 解析非流式响应体。
    ///
    /// **同时接受两种形态**（v2.4 起）：
    /// 1. 标准非流式 JSON：`{"choices":[{"message":{"content":"..."}}]}`
    /// 2. **SSE 流式分片**：`data: {"choices":[{"delta":{"content":"..."}}]}\n\n…`
    ///
    /// 为什么要接受第 2 种：请求里虽然写了 `stream: false`，但**很多中转/网关会忽略
    /// 这个字段、仍然按流式回**（实测某网关：即使 `stream:false`，返回体依然是
    /// `object: "chat.completion.chunk"` 的 `data:` 分片）。旧实现只按整段 JSON 解析，
    /// 于是「HTTP 200、正文一个字都取不到」，用户看到的就是
    /// 「服务商返回了 200，但没有解析出任何正文」。
    /// 对这种网关，正确做法是把分片拼起来当成完整回复。
    private func parseCompletion(data: Data) throws -> ChatResult {
        // ── 形态 2：SSE 分片（先判，因为它的 body 不是单个 JSON 对象）──
        if let sseResult = OpenAICompatibleClient.parseSSEBodyAsCompletion(data) {
            return sseResult
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("返回内容不是合法 JSON：\(HTTPTransport.extractPlainText(from: data) ?? "")")
        }
        // 有些中转站在 200 里塞错误体。
        if let errorMessage = HTTPTransport.extractErrorMessage(from: data), root["choices"] == nil {
            throw AIError.server(code: 200, message: errorMessage)
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIError.decoding("响应里没有 choices 字段")
        }
        var text = ""
        if let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                text = content
            } else if let parts = message["content"] as? [[String: Any]] {
                // 少数服务端返回分段内容。
                text = parts.compactMap { $0["text"] as? String }.joined()
            }
        } else if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
            text = content
        }
        let finishReason = first["finish_reason"] as? String
        var usage: TokenUsage?
        if let usageDictionary = root["usage"] as? [String: Any] {
            usage = OpenAICompatibleClient.parseUsage(usageDictionary)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if finishReason == "content_filter" {
                throw AIError.contentRejected("模型判定内容不合规")
            }
            // 非流式响应同样可能「只有思维链、正文为空」（推理模型的预算被思维链吃光），
            // 复用同一套判定，别让这里退化成一句笼统的「内容被拒绝」。
            let reasoning = (first["message"] as? [String: Any])?["reasoning_content"] as? String ?? ""
            try throwIfNoTextEmitted(
                sawText: false,
                sawReasoning: !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                finishReason: finishReason,
                // 把整段响应体带上（`extractPlainText` 内部已截到 200 字）。
                // 「200 但正文为空」时，用户与开发者全靠这段才知道服务端到底回了什么。
                rawSnippet: HTTPTransport.extractPlainText(from: data)
            )
            throw AIError.contentRejected(nil)
        }
        return ChatResult(text: trimmed, usage: usage, finishReason: finishReason)
    }

    /// 解析 `{"prompt_tokens":..,"completion_tokens":..,"total_tokens":..}`。
    static func parseUsage(_ dictionary: [String: Any]) -> TokenUsage {
        let prompt = dictionary["prompt_tokens"] as? Int ?? 0
        let completion = dictionary["completion_tokens"] as? Int ?? 0
        let total = dictionary["total_tokens"] as? Int ?? (prompt + completion)
        return TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }

    /// 粗略估算 prompt token 数（中文按 1 字 ≈ 1 token，英文按 4 字符 ≈ 1 token）。
    private func estimatePromptTokens(_ request: ChatRequest) -> Int {
        let text = request.concatenatedText
        var estimate = 0
        for scalar in text.unicodeScalars {
            estimate += scalar.value > 0x2E80 ? 1 : 0
        }
        estimate += (text.count - estimate) / 4
        return max(estimate, 1)
    }
}
