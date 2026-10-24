//
//  GeminiClient.swift
//  ios/Shared/Networking
//
//  模块职责：实现 Google Gemini 协议（`POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse&key=...`）
//            的流式与一次性对话。**实验性**：国内直连不可用，且返回结构随版本变化较大，
//            解析失败时会给出明确的 `notSupported` 风格提示。
//  依赖：Foundation、Models、SSEParser、HTTPTransport、AIError。
//  使用方：AIClientFactory.makeLLM（kind == .gemini）→ 宿主 App 的调试页。
//

import Foundation

/// Google Gemini 客户端（实验性）。
///
/// 请求约定：
/// - `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse&key=<API_KEY>`
/// - Header：`Content-Type: application/json`
/// - Body：`{"contents":[{"role":"user","parts":[{"text":"..."}]}],"systemInstruction":{"parts":[{"text":"..."}]},"generationConfig":{...}}`
/// - 流式响应：`data: {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}`
///
/// 已知限制：
/// - base 默认 `https://generativelanguage.googleapis.com`，用户也可填中转站地址；
/// - 若返回结构不符（中转站返回 OpenAI 格式），会抛 `.decoding` 并提示改用"OpenAI 兼容"协议。
public final class GeminiClient: LLMClient, @unchecked Sendable {

    /// 服务商配置。
    private let config: AIProviderConfig
    /// 明文 API Key（拼在 query 上）。
    private let apiKey: String
    /// 复用的 URLSession。
    private let session: URLSession

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

    /// 一次性对话（`generateContent` 非流式端点）。
    public func complete(_ request: ChatRequest) async throws -> ChatResult {
        try checkPreconditions()
        guard let url = endpoint(streaming: false) else { throw AIError.notConfigured }
        let body = makeBody(request)
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .queryKey(apiKey),
            extraHeaders: config.extraHeaders,
            timeout: config.timeout,
            body: body
        )
        let (data, _) = try await HTTPTransport.send(urlRequest, session: session)
        return try parseCompletion(data: data)
    }

    // MARK: - 内部实现

    /// 前置校验。
    private func checkPreconditions() throws {
        guard config.isChatConfigured else { throw AIError.notConfigured }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
        guard !config.model.isEmpty else {
            throw AIError.notConfigured
        }
    }

    /// 拼接 Gemini 端点。
    ///
    /// 例：`https://generativelanguage.googleapis.com` →
    /// `https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:streamGenerateContent?alt=sse&key=xxx`
    private func endpoint(streaming: Bool) -> URL? {
        let base = config.normalizedBaseURL
        guard !base.isEmpty else { return nil }
        let method = streaming ? "streamGenerateContent" : "generateContent"
        let versionPath: String
        if base.lowercased().contains("/v1beta") || base.lowercased().contains("/v1") {
            versionPath = base + "/models/\(config.model):\(method)"
        } else {
            versionPath = base + "/v1beta/models/\(config.model):\(method)"
        }
        var queryItems: [String] = []
        if streaming {
            queryItems.append("alt=sse")
        }
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        queryItems.append("key=\(encodedKey)")
        let separator = versionPath.contains("?") ? "&" : "?"
        return URL(string: versionPath + separator + queryItems.joined(separator: "&"))
    }

    /// 构造 Gemini 请求体。
    private func makeBody(_ request: ChatRequest) -> [String: Any] {
        var contents: [[String: Any]] = []
        for message in request.conversationMessages {
            let role = message.role == .assistant ? "model" : "user"
            contents.append([
                "role": role,
                "parts": [["text": message.content]]
            ])
        }
        if contents.isEmpty {
            contents.append(["role": "user", "parts": [["text": "请继续。"]]])
        }
        let temperature = AIProviderConfig.clampTemperature(request.temperature ?? config.temperature)
        let maxTokens = AIProviderConfig.clampMaxTokens(request.maxTokens ?? config.maxTokens)
        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        if let system = request.systemPrompt, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        // Gemini 的 safetySettings 默认即可，不加额外限制以免误伤正常文本。
        return body
    }

    /// 执行流式请求。
    private func runStream(
        _ request: ChatRequest,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        try checkPreconditions()
        guard let url = endpoint(streaming: true) else { throw AIError.notConfigured }
        let body = makeBody(request)
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .queryKey(apiKey),
            extraHeaders: config.extraHeaders,
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
        var didEmitContent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let events = parser.feed(Data((line + "\n").utf8))
            for event in events {
                if event.isDone { break }
                guard let text = parseStreamText(event.data) else { continue }
                if !text.isEmpty {
                    didEmitContent = true
                    continuation.yield(ChatDelta(text: text, isFinal: false))
                }
            }
        }
        for event in parser.flush() {
            if event.isDone { break }
            if let text = parseStreamText(event.data), !text.isEmpty {
                didEmitContent = true
                continuation.yield(ChatDelta(text: text, isFinal: false))
            }
        }
        if !didEmitContent {
            throw AIError.decoding("Gemini 返回结构无法识别，请把协议类型改为「OpenAI 兼容」或换用其它服务商")
        }
        continuation.yield(ChatDelta(text: "", isFinal: true))
        continuation.finish()
    }

    /// 从一帧里抽出所有 `candidates[0].content.parts[].text`。
    private func parseStreamText(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return GeminiClient.extractText(from: root)
    }

    /// 解析非流式响应。
    private func parseCompletion(data: Data) throws -> ChatResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("Gemini 返回内容不是合法 JSON")
        }
        if root["candidates"] == nil,
           let errorMessage = HTTPTransport.extractErrorMessage(from: data) {
            throw AIError.server(code: 200, message: errorMessage)
        }
        let text = GeminiClient.extractText(from: root)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 可能是被安全策略拦截（promptFeedback.blockReason）。
            let blocked = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw AIError.contentRejected(blocked ?? "模型没有返回任何内容")
        }
        var finishReason: String?
        if let candidates = root["candidates"] as? [[String: Any]], let first = candidates.first {
            finishReason = first["finishReason"] as? String
        }
        var usage: TokenUsage?
        if let metadata = root["usageMetadata"] as? [String: Any] {
            let prompt = metadata["promptTokenCount"] as? Int ?? 0
            let completion = metadata["candidatesTokenCount"] as? Int ?? 0
            usage = TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
        }
        return ChatResult(text: trimmed, usage: usage, finishReason: finishReason)
    }

    /// 从 Gemini 响应字典里抽取文本（多 candidate 取第一个）。
    static func extractText(from root: [String: Any]) -> String {
        guard let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}
