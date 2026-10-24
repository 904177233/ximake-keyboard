//
//  AnthropicClient.swift
//  ios/Shared/Networking
//
//  模块职责：实现 Anthropic Messages 协议（`POST {base}/v1/messages`）的流式与一次性对话。
//  依赖：Foundation、Models、SSEParser、HTTPTransport、AIError。
//  使用方：AIClientFactory.makeLLM（kind == .anthropic）→ 键盘扩展 AIService、宿主 App。
//

import Foundation

/// Anthropic Claude 客户端。
///
/// 请求约定：
/// - `POST {base}/v1/messages`（base 不要带 `/v1`，本客户端负责拼）
/// - Header：`x-api-key: <key>`、`anthropic-version: 2023-06-01`、`content-type: application/json`
/// - Body：`{"model":..,"max_tokens":..,"system":"..","messages":[...],"stream":true,"temperature":..}`
/// - 流式响应事件：
///   `event: content_block_delta` + `data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}`
///   `event: message_stop` 结束；`event: error` 表示出错。
///
/// 注意：Anthropic 要求 `system` 必须单独传（不能放在 messages 里），且 `messages` 只能有
/// user / assistant 两种 role。`ChatRequest.systemPrompt` 与 `conversationMessages` 负责拆分。
public final class AnthropicClient: LLMClient, @unchecked Sendable {

    /// 服务商配置。
    private let config: AIProviderConfig
    /// 明文 API Key。
    private let apiKey: String
    /// 复用的 URLSession。
    private let session: URLSession
    /// Anthropic 要求的 API 版本头。
    private let anthropicVersion = "2023-06-01"

    /// 创建客户端。
    public init(config: AIProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        self.session = HTTPTransport.makeSession(timeout: config.timeout)
    }

    // MARK: - LLMClient

    /// 流式对话。
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: AIError.cancelled)
                    return
                }
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

    /// 一次性对话。
    public func complete(_ request: ChatRequest) async throws -> ChatResult {
        try checkPreconditions()
        var body = makeBody(request, stream: false)
        body["stream"] = false
        guard let url = messagesURL() else { throw AIError.notConfigured }
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .apiKey(apiKey),
            extraHeaders: anthropicHeaders(),
            timeout: config.timeout,
            body: body
        )
        let (data, _) = try await HTTPTransport.send(urlRequest, session: session)
        return try parseCompletion(data: data)
    }

    // MARK: - 内部实现

    /// `{base}/v1/messages`：base 已带版本段就直接拼 `/messages`，否则补 `/v1/messages`。
    private func messagesURL() -> URL? {
        let base = config.normalizedBaseURL
        guard !base.isEmpty else { return nil }
        let lowercased = base.lowercased()
        if lowercased.hasSuffix("/v1") || lowercased.contains("/v1/") {
            return config.resolvedURL(path: "/messages")
        }
        return URL(string: base + "/v1/messages")
    }

    /// 合并 Anthropic 必需头与用户自定义头。
    private func anthropicHeaders() -> [String: String] {
        var headers = config.extraHeaders
        headers["anthropic-version"] = anthropicVersion
        // 允许浏览器直连（部分中转站要求），官方接口会忽略该头。
        headers["anthropic-dangerous-direct-browser-access"] = "true"
        return headers
    }

    /// 前置校验。
    private func checkPreconditions() throws {
        guard config.isChatConfigured else { throw AIError.notConfigured }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
    }

    /// 构造 Messages 请求体。
    private func makeBody(_ request: ChatRequest, stream: Bool) -> [String: Any] {
        let temperature = AIProviderConfig.clampTemperature(request.temperature ?? config.temperature)
        let maxTokens = AIProviderConfig.clampMaxTokens(request.maxTokens ?? config.maxTokens)
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": stream,
            // 用单条 user 兜底，避免 messages 为空被服务端拒绝。
            "messages": [[String: Any]]()
        ]
        if let system = request.systemPrompt, !system.isEmpty {
            body["system"] = system
        }
        var messages: [[String: Any]] = []
        for message in request.conversationMessages {
            let role = message.role == .assistant ? "assistant" : "user"
            messages.append(["role": role, "content": message.content])
        }
        if messages.isEmpty {
            messages.append(["role": "user", "content": "请继续。"])
        }
        body["messages"] = messages
        return body
    }

    /// 执行流式请求。
    private func runStream(
        _ request: ChatRequest,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        try checkPreconditions()
        let body = makeBody(request, stream: true)
        guard let url = messagesURL() else { throw AIError.notConfigured }
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .apiKey(apiKey),
            extraHeaders: anthropicHeaders(),
            timeout: config.timeout,
            body: body
        )

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.decoding("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
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
        var didFinish = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = parser.feed(Data((line + "\n").utf8))
            for event in events {
                if try handleStreamEvent(event, continuation: continuation) {
                    didFinish = true
                    continuation.finish()
                    return
                }
            }
        }
        for event in parser.flush() {
            if try handleStreamEvent(event, continuation: continuation) {
                didFinish = true
                break
            }
        }
        if !didFinish {
            continuation.yield(ChatDelta(text: "", isFinal: true))
        }
        continuation.finish()
    }

    /// 解析单个 Anthropic SSE 事件。
    ///
    /// - Returns: 是否已到达终止事件（`message_stop`）。
    private func handleStreamEvent(
        _ event: SSEEvent,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) throws -> Bool {
        let type = event.event
        if type == "message_stop" {
            continuation.yield(ChatDelta(text: "", isFinal: true))
            return true
        }
        if type == "error" {
            let message = HTTPTransport.extractErrorMessage(from: Data(event.data.utf8))
            throw AIError.server(code: 200, message: message ?? "Anthropic 返回错误事件")
        }
        guard let data = event.data.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let eventType = (root["type"] as? String) ?? type ?? ""
        switch eventType {
        case "content_block_delta":
            if let delta = root["delta"] as? [String: Any] {
                if let text = delta["text"] as? String, !text.isEmpty {
                    continuation.yield(ChatDelta(text: text, isFinal: false))
                }
                // delta.type == "thinking_delta" 时 text 为空，直接忽略。
            }
        case "message_delta":
            // 这里可能带 stop_reason 与 usage，不需要向 UI 暴露。
            break
        case "message_stop":
            continuation.yield(ChatDelta(text: "", isFinal: true))
            return true
        case "error":
            let errorMessage = (root["error"] as? [String: Any])?["message"] as? String
            throw AIError.server(code: 200, message: errorMessage ?? "Anthropic 返回错误事件")
        default:
            break
        }
        return false
    }

    /// 解析非流式响应体。
    private func parseCompletion(data: Data) throws -> ChatResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("返回内容不是合法 JSON")
        }
        if let errorMessage = HTTPTransport.extractErrorMessage(from: data), root["content"] == nil {
            throw AIError.server(code: 200, message: errorMessage)
        }
        guard let content = root["content"] as? [[String: Any]] else {
            throw AIError.decoding("响应里没有 content 字段")
        }
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let finishReason = root["stop_reason"] as? String
        var usage: TokenUsage?
        if let usageDictionary = root["usage"] as? [String: Any] {
            let prompt = usageDictionary["input_tokens"] as? Int ?? 0
            let completion = usageDictionary["output_tokens"] as? Int ?? 0
            usage = TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIError.contentRejected(finishReason == "refusal" ? "模型拒绝回答" : nil)
        }
        return ChatResult(text: trimmed, usage: usage, finishReason: finishReason)
    }
}
