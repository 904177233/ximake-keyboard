//
//  HTTPTransport.swift
//  ios/Shared/Networking
//
//  模块职责：所有 AI 客户端共用的 HTTP 基础设施——构造 URLRequest、统一的 HTTP 错误映射、
//            服务端错误消息提取、Retry-After 解析、baseURL 智能拼接（resolvedURL(path:)）。
//  依赖：仅 Foundation（不 import UIKit/SwiftUI），可在键盘扩展内安全使用。
//  使用方：OpenAICompatibleClient / AnthropicClient / GeminiClient / ImageClient 系列。
//

import Foundation

/// HTTP 传输层工具集合（无状态，纯静态函数）。
public enum HTTPTransport {

    /// 统一的 `URLSession` 配置：内存/磁盘缓存关闭（流式与鉴权请求都不应被缓存）。
    public static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        let clamped = min(max(timeout, 5), 180)
        configuration.timeoutIntervalForRequest = clamped
        configuration.timeoutIntervalForResource = max(clamped, 120)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        // 键盘扩展内存敏感，限制并发连接数。
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    /// 用 `URLSession` 发起普通（非流式）请求，并把 HTTP 状态码映射成 `AIError`。
    ///
    /// - Returns: `(data, response)`，状态码 2xx。
    /// - Throws: `AIError`（网络 / 超时 / 鉴权 / 限流 / 服务端错误）。
    public static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIError.wrap(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.decoding("响应不是 HTTP 响应")
        }
        try validate(httpResponse, data: data)
        return (data, httpResponse)
    }

    /// 校验 HTTP 状态码，非 2xx 时抛带服务端消息的 `AIError`。
    public static func validate(_ response: HTTPURLResponse, data: Data) throws {
        let statusCode = response.statusCode
        guard !(200..<300).contains(statusCode) else { return }
        let message = extractErrorMessage(from: data) ?? extractPlainText(from: data)
        let retryAfter = retryAfterInterval(from: response)
        throw AIError.fromHTTPStatus(statusCode, message: message, retryAfter: retryAfter)
    }

    // MARK: - 错误消息提取

    /// 从错误响应体里提取人类可读消息。
    ///
    /// 依次尝试：
    /// 1. `{"error": {"message": "..."}}`（OpenAI / DashScope / 火山方舟）
    /// 2. `{"error": "..."}`（部分中转站）
    /// 3. `{"message": "..."}`（Anthropic / Gemini）
    /// 4. `{"msg": "..."}` / `{"detail": "..."}`（国内服务商常见）
    /// 5. `[{"error": {...}}]`（Gemini 的数组形式）
    public static func extractErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let dictionary = root as? [String: Any] {
            if let error = dictionary["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty {
                    return message
                }
                if let code = error["code"] as? String, !code.isEmpty {
                    return code
                }
            }
            if let error = dictionary["error"] as? String, !error.isEmpty {
                return error
            }
            for key in ["message", "msg", "detail", "error_msg", "errorMsg"] {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        if let array = root as? [[String: Any]], let first = array.first {
            return extractErrorMessageFromDictionary(first)
        }
        return nil
    }

    private static func extractErrorMessageFromDictionary(_ dictionary: [String: Any]) -> String? {
        if let error = dictionary["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        for key in ["message", "msg", "detail"] {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 极简纯文本兜底（截断到 200 字，避免把整页 HTML 塞进错误提示）。
    public static func extractPlainText(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 200 {
            return String(trimmed.prefix(200)) + "…"
        }
        return trimmed
    }

    /// 解析 `Retry-After` 响应头（秒数形式或 HTTP 日期形式），并夹到 1...120 秒。
    public static func retryAfterInterval(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        var seconds: TimeInterval?
        if let value = TimeInterval(raw) {
            seconds = value
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: raw) {
                seconds = date.timeIntervalSinceNow
            }
        }
        guard let seconds else { return nil }
        return min(max(seconds, 1), 120)
    }

    // MARK: - 请求构造

    /// 构造 JSON POST 请求：设置 `content-type: application/json`、鉴权头与额外头。
    ///
    /// - Parameter accept: `Accept` 头的值。流式（SSE）请求必须传
    ///   `"text/event-stream"`，否则部分服务端/网关会按普通 JSON 请求处理，
    ///   直接一次性返回完整结果甚至 406，客户端就会「点了没反应」。
    ///   非流式请求保持默认的 `application/json`。
    public static func makeJSONRequest(
        url: URL,
        auth: AuthHeader,
        extraHeaders: [String: String],
        timeout: TimeInterval,
        body: [String: Any],
        accept: String = "application/json"
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = min(max(timeout, 5), 180)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        switch auth {
        case let .bearer(key):
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case let .apiKey(key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .queryKey, .none:
            // key 已在 URL query 里（Gemini），或该端点无需鉴权。
            break
        }
        for (field, value) in extraHeaders where !field.isEmpty {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    /// 构造 GET 请求（用于万相任务轮询）。
    public static func makeGETRequest(
        url: URL,
        auth: AuthHeader,
        extraHeaders: [String: String],
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(max(timeout, 5), 180)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case let .bearer(key):
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case let .apiKey(key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .queryKey, .none:
            break
        }
        for (field, value) in extraHeaders where !field.isEmpty {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// 鉴权方式。
    public enum AuthHeader: Sendable {
        /// `Authorization: Bearer <key>`（OpenAI 兼容 / Anthropic 代理 / Gemini 官方）。
        case bearer(String)
        /// `x-api-key: <key>`（Anthropic 官方）。
        case apiKey(String)
        /// Key 拼在 URL query 上（Gemini）。
        case queryKey(String)
        /// 不需要鉴权头。
        case none
    }
}

// MARK: - baseURL 智能拼接

public extension AIProviderConfig {

    /// 智能拼接接口路径。
    ///
    /// 规则（保守，不做域名猜测、不自动补域名）：
    /// - base 已带版本段（`/v1`、`/v2`、`/v3`、`/v4`、`/v1beta`、`.../compatible-mode/v1` 等）
    ///   → 直接拼 `path`，例如 `https://api.deepseek.com/v1` + `/chat/completions`；
    /// - base 不带版本段 → 中间补 `/v1`，例如 `https://api.openai.com` + `/v1/chat/completions`。
    ///
    /// - Parameter path: 以 `/` 开头的接口路径，例如 `"/chat/completions"`。
    /// - Returns: 拼好的 URL；baseURL 非法时返回 nil。
    func resolvedURL(path: String) -> URL? {
        let base = normalizedBaseURL
        guard !base.isEmpty else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let components = base.split(separator: "/").map(String.init)
        let lastSegment = components.last?.lowercased() ?? ""
        let versionedSegments: Set<String> = ["v1", "v2", "v3", "v4", "v1beta", "v1alpha", "v1beta1"]
        let hasVersion = versionedSegments.contains(lastSegment) || lastSegment.hasPrefix("v1") || lastSegment.hasPrefix("v2")
        let fullURL: String
        if hasVersion {
            fullURL = base + normalizedPath
        } else {
            fullURL = base + "/v1" + normalizedPath
        }
        return URL(string: fullURL)
    }

    /// 是否指向已知的"仅生图"网关（用于 Router 与 UI 提示）。
    var isImageOnlyGateway: Bool {
        let lowercasedBase = normalizedBaseURL.lowercased()
        let lowercasedModel = model.lowercased()
        if lowercasedBase.contains("dashscope.aliyuncs.com") && !lowercasedBase.contains("compatible-mode") {
            return true
        }
        return lowercasedModel.contains("seedream") || lowercasedModel.contains("wanx")
    }
}
