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
/// 关于 `reasoning_content`：DeepSeek Reasoner 等推理模型会在 delta 里附带思维链，
/// 本客户端默认**忽略**（不拼接进正文），仅当 `capturesReasoning == true` 时以
/// `ChatDelta.text` 之外的旁路回调收集（供调试页展示）。
public final class OpenAICompatibleClient: LLMClient, @unchecked Sendable {

    /// 服务商配置（不可变，值类型拷贝）。
    private let config: AIProviderConfig
    /// 明文的 API Key。
    private let apiKey: String
    /// 是否收集推理模型的 `reasoning_content`（默认 false，仅调试用）。
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
        return try parseCompletion(data: data)
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
        let temperature = request.temperature ?? config.temperature
        let maxTokens = request.maxTokens ?? config.maxTokens
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": AIProviderConfig.clampTemperature(temperature),
            "max_tokens": AIProviderConfig.clampMaxTokens(maxTokens),
            "stream": stream
        ]
        // 部分服务端（如 DeepSeek 流式）支持 include_usage，能拿到最后一片 token 统计。
        if stream {
            body["stream_options"] = ["include_usage": true]
        }
        return body
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
            body: body
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
        var didEmitFinal = false
        let promptTokens = estimatePromptTokens(request)

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = parser.feed(Data((line + "\n").utf8))
            for event in events {
                if event.isDone {
                    if !didEmitFinal {
                        didEmitFinal = true
                        continuation.yield(ChatDelta(text: "", isFinal: true))
                    }
                    continuation.finish()
                    return
                }
                guard let payload = parseStreamPayload(event.data) else { continue }
                if payload.finishReason != nil {
                    accumulatedFinishReason = payload.finishReason
                }
                // 忽略 reasoning_content（推理模型思维链），仅正文进入流。
                if !payload.text.isEmpty {
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
            if !payload.text.isEmpty {
                continuation.yield(ChatDelta(text: payload.text, isFinal: false))
            }
        }
        _ = accumulatedFinishReason
        _ = promptTokens
        if !didEmitFinal {
            continuation.yield(ChatDelta(text: "", isFinal: true))
        }
        continuation.finish()
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
                if capturesReasoning, let reasoning = delta["reasoning_content"] as? String {
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
    private func parseCompletion(data: Data) throws -> ChatResult {
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
