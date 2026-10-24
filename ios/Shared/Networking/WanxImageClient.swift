//
//  WanxImageClient.swift
//  ios/Shared/Networking
//
//  模块职责：通义万相（DashScope 文生图）生图客户端。DashScope 文生图是**异步任务**接口：
//            先创建任务拿到 `task_id`，再轮询任务状态直到 `SUCCEEDED`，最后下载 `results[].url`。
//  依赖：Foundation、Models、HTTPTransport、AIError。
//  使用方：ImageClientRouter（baseURL 含 dashscope.aliyuncs.com，或 model 含 wanx）。
//

import Foundation

/// 通义万相 · DashScope 生图客户端（异步任务 + 轮询）。
///
/// 请求约定：
/// 1) 创建任务
///    - `POST https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis`
///    - Header：`Authorization: Bearer <DASHSCOPE_API_KEY>`、`X-DashScope-Async: enable`、`Content-Type: application/json`
///    - Body：`{"model":"wanx2.1-t2i-turbo","input":{"prompt":"..."},"parameters":{"size":"1024*1024","n":1}}`
///    - 响应：`{"output":{"task_id":"...","task_status":"PENDING"},"request_id":"..."}`
/// 2) 轮询任务
///    - `GET https://dashscope.aliyuncs.com/api/v1/tasks/{task_id}`（**不带** `X-DashScope-Async`）
///    - 响应：`{"output":{"task_status":"SUCCEEDED","results":[{"url":"https://..."}]}}`
///      `task_status` 取值：`PENDING` / `RUNNING` / `SUCCEEDED` / `FAILED` / `CANCELED` / `UNKNOWN`
/// 3) 下载图片
///
/// 说明：
/// - 尺寸用星号分隔（`1024*1024`），与 OpenAI 风格的 `1024x1024` 不同，客户端自动转换；
/// - 生成的 url 有效期 24 小时，客户端会立即下载并保留 `remoteURL`；
/// - 轮询从 1.5s 起指数退避，最长 3s 一次，总超时 90s 抛 `.timeout`，任务取消立即停止轮询。
public final class WanxImageClient: ImageGenerating, @unchecked Sendable {

    /// 通义万相默认模型。
    public static let defaultModel = "wanx2.1-t2i-turbo"
    /// 万相常用尺寸（API 使用星号分隔）。
    public static let supportedSizes: [String] = [
        "1024*1024",
        "720*1280",
        "1280*720",
        "768*1152",
        "1152*768"
    ]
    /// 轮询总超时（秒）。
    public static let pollTimeout: TimeInterval = 90
    /// 轮询初始间隔（秒）。
    public static let initialPollInterval: TimeInterval = 1.5
    /// 轮询最大间隔（秒）。
    public static let maxPollInterval: TimeInterval = 3.0

    /// 服务商配置。
    private let config: AIProviderConfig
    /// 明文 API Key。
    private let apiKey: String
    /// 复用的 URLSession。
    private let session: URLSession

    /// 创建客户端。
    public init(config: AIProviderConfig, apiKey: String, session: URLSession? = nil) {
        self.config = config
        self.apiKey = apiKey
        self.session = session ?? HTTPTransport.makeSession(timeout: max(config.timeout, 60))
    }

    // MARK: - ImageGenerating

    /// 生成图片（创建任务 → 轮询 → 下载）。
    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        guard config.isImageConfigured else { throw AIError.notConfigured }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
        let prompt = request.trimmedPrompt
        guard !prompt.isEmpty else { throw AIError.contentRejected("提示词不能为空") }

        let taskID = try await createTask(request: request, prompt: prompt)
        let urls = try await pollTask(taskID: taskID)
        guard !urls.isEmpty else {
            throw AIError.contentRejected("通义万相没有返回图片，可能被内容安全策略拦截，请调整提示词")
        }
        var results: [GeneratedImage] = []
        for remoteURL in urls {
            let bytes = try await ImageDownloader.download(url: remoteURL, session: session)
            results.append(
                GeneratedImage(
                    data: bytes,
                    remoteURL: remoteURL,
                    mimeType: ImageDownloader.mimeType(for: remoteURL)
                )
            )
        }
        guard !results.isEmpty else {
            throw AIError.decoding("通义万相返回的图片下载失败")
        }
        return results
    }

    // MARK: - 创建任务

    /// 创建文生图异步任务，返回 `task_id`。
    private func createTask(request: ImageRequest, prompt: String) async throws -> String {
        guard let url = creationURL() else { throw AIError.notConfigured }
        let model = WanxImageClient.resolvedModel(config.imageModel)
        var parameters: [String: Any] = [
            "size": WanxImageClient.resolvedSize(request.size),
            "n": max(min(request.count, 4), 1)
        ]
        if !request.quality.isEmpty {
            parameters["quality"] = request.quality
        }
        let body: [String: Any] = [
            "model": model,
            "input": ["prompt": prompt],
            "parameters": parameters
        ]
        var urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .bearer(apiKey),
            extraHeaders: config.extraHeaders,
            timeout: max(config.timeout, 60),
            body: body
        )
        // 异步任务必须带该 Header；创建任务本身幂等（同一 prompt 会产生多个 task，故不重试）。
        urlRequest.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        let (data, _) = try await HTTPTransport.send(urlRequest, session: session)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("通义万相创建任务返回内容不是合法 JSON")
        }
        guard let output = root["output"] as? [String: Any],
              let taskID = output["task_id"] as? String,
              !taskID.isEmpty else {
            let message = HTTPTransport.extractErrorMessage(from: data) ?? "未返回 task_id"
            throw AIError.server(code: 200, message: message)
        }
        return taskID
    }

    /// `{base}/api/v1/services/aigc/text2image/image-synthesis`。
    ///
    /// base 可能是 `https://dashscope.aliyuncs.com`（预设）或带 `/api/v1` 的自定义地址。
    private func creationURL() -> URL? {
        let base = config.normalizedBaseURL
        guard !base.isEmpty else { return nil }
        let lowercased = base.lowercased()
        if lowercased.hasSuffix("/api/v1") || lowercased.contains("/api/v1/") {
            return URL(string: base + "/services/aigc/text2image/image-synthesis")
        }
        return URL(string: base + "/api/v1/services/aigc/text2image/image-synthesis")
    }

    /// `{base}/api/v1/tasks/{task_id}`。
    private func taskURL(taskID: String) -> URL? {
        let base = config.normalizedBaseURL
        guard !base.isEmpty else { return nil }
        let lowercased = base.lowercased()
        let encoded = taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskID
        if lowercased.hasSuffix("/api/v1") || lowercased.contains("/api/v1/") {
            return URL(string: base + "/tasks/" + encoded)
        }
        return URL(string: base + "/api/v1/tasks/" + encoded)
    }

    // MARK: - 轮询

    /// 轮询任务直到成功，返回图片 URL 列表。
    ///
    /// - Throws: `AIError.timeout`（超过 90s）、`AIError.server`（任务 FAILED）、`AIError.cancelled`（任务被取消）。
    private func pollTask(taskID: String) async throws -> [URL] {
        let deadline = Date().addingTimeInterval(WanxImageClient.pollTimeout)
        var interval = WanxImageClient.initialPollInterval
        while Date() < deadline {
            try Task.checkCancellation()
            guard let url = taskURL(taskID: taskID) else { throw AIError.notConfigured }
            let urlRequest = try HTTPTransport.makeGETRequest(
                url: url,
                auth: .bearer(apiKey),
                extraHeaders: config.extraHeaders,
                timeout: max(config.timeout, 60)
            )
            let (data, _) = try await HTTPTransport.send(urlRequest, session: session)
            let status = try parseTaskStatus(data: data)
            switch status {
            case .succeeded:
                return try parseImageURLs(data: data)
            case .failed(let message):
                throw AIError.server(code: 200, message: message)
            case .canceled:
                throw AIError.cancelled
            case .pending, .running, .unknown:
                break
            }
            // 指数退避：1.5s → 2.25s → 3s（封顶）。
            interval = min(interval * 1.5, WanxImageClient.maxPollInterval)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw AIError.timeout
    }

    /// DashScope 任务状态。
    enum TaskStatus: Equatable {
        case pending
        case running
        case succeeded
        case failed(String)
        case canceled
        case unknown
    }

    /// 解析 `output.task_status`。
    private func parseTaskStatus(data: Data) throws -> TaskStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("通义万相轮询返回内容不是合法 JSON")
        }
        guard let output = root["output"] as? [String: Any] else {
            // 轮询阶段 4xx/5xx 已由 HTTPTransport 抛错；这里只处理缺 output 的异常体。
            let message = HTTPTransport.extractErrorMessage(from: data) ?? "轮询响应缺少 output 字段"
            throw AIError.server(code: 200, message: message)
        }
        let raw = (output["task_status"] as? String)?.uppercased() ?? ""
        switch raw {
        case "PENDING":
            return .pending
        case "RUNNING":
            return .running
        case "SUCCEEDED":
            return .succeeded
        case "FAILED":
            return .failed((output["message"] as? String) ?? "通义万相任务失败")
        case "CANCELED":
            return .canceled
        default:
            return .unknown
        }
    }

    /// 解析 `output.results[].url`。
    private func parseImageURLs(data: Data) throws -> [URL] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any],
              let results = output["results"] as? [[String: Any]] else {
            throw AIError.decoding("通义万相响应缺少 output.results")
        }
        var urls: [URL] = []
        for item in results {
            if let urlString = item["url"] as? String, let url = URL(string: urlString) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - 参数归一化

    /// 空模型回退默认 `wanx2.1-t2i-turbo`。
    static func resolvedModel(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultModel
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化尺寸：`1024x1024` / `1024×1024` / `1024*1024` 统一成星号形式。
    static func resolvedSize(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = normalized.filter { $0.isNumber || $0 == "*" }
        return supportedSizes.contains(filtered) ? filtered : "1024*1024"
    }
}
