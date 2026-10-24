//
//  ImageClient.swift
//  ios/Shared/Networking
//
//  模块职责：OpenAI 风格生图客户端（`POST {base}/images/generations`），并实现
//            `ImageClientRouter`——按 baseURL 与模型名把生图请求路由到
//            即梦（Seedream/火山方舟）、通义万相（DashScope 异步任务）或 OpenAI 兼容实现。
//  依赖：Foundation、Models、HTTPTransport、AIError。
//  使用方：AIClientFactory.makeImage → 键盘扩展生图面板、宿主 App ImagePanelView。
//

import Foundation

/// 生成图片后从远端 URL 下载数据的公共实现（三个生图客户端共用）。
enum ImageDownloader {

    /// 单张图片体积上限：4 MB（键盘扩展内存有限）。
    static let maxBytes = 4 * 1024 * 1024

    /// 下载图片并做体积校验。
    ///
    /// - Throws: `AIError.network`（下载失败）、`AIError.server`（体积超限）。
    static func download(url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw AIError.wrap(error)
        }
        if data.count > maxBytes {
            throw AIError.server(
                code: 413,
                message: "图片体积 \(data.count / 1024 / 1024) MB 超过 4 MB 上限，请换更小的尺寸"
            )
        }
        guard !data.isEmpty else {
            throw AIError.decoding("生图返回的图片内容为空")
        }
        return data
    }

    /// 根据 URL 后缀猜测 MIME 类型。
    static func mimeType(for url: URL?) -> String {
        guard let pathExtension = url?.pathExtension.lowercased() else { return "image/png" }
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        default:
            return "image/png"
        }
    }
}

/// OpenAI 风格生图客户端。
///
/// 请求约定：
/// - `POST {base}/images/generations`
/// - Header：`Authorization: Bearer <key>`
/// - Body：`{"model":"gpt-image-1","prompt":"...","n":1,"size":"1024x1024","quality":"standard","response_format":"b64_json"}`
/// - 响应：`{"data":[{"b64_json":"..."} | {"url":"..."}]}`
///
/// 兼容性处理：
/// - 只返回 `url` 的服务端：下载后返回 Data（≤ 4 MB），并保留 `remoteURL`；
/// - `gpt-image-1` 不接受 `response_format`：先带该字段请求，若 400 且 message 提到
///   "unknown"/"unrecognized"/"response_format" 则去掉该字段重试一次；
/// - 仅对幂等的生图请求做 ≤2 次指数退避重试（网络错误 / 5xx / 429）。
public final class OpenAICompatibleImageClient: ImageGenerating, @unchecked Sendable {

    /// 服务商配置（imageModel 必须非空）。
    private let config: AIProviderConfig
    /// 明文 API Key。
    private let apiKey: String
    /// 复用的 URLSession（超时 60s，生图比对话慢）。
    private let session: URLSession
    /// 自定义接口路径（默认 `/images/generations`，中转站可用 `path` 覆盖）。
    private let customPath: String?

    /// 创建客户端。
    ///
    /// - Parameters:
    ///   - config: 生图服务商配置。
    ///   - apiKey: 明文 Key。
    ///   - session: 可注入的 URLSession（测试用）。
    ///   - path: 自定义接口路径，例如 `"/v1/images/generations"`；nil 走默认拼接。
    public init(
        config: AIProviderConfig,
        apiKey: String,
        session: URLSession? = nil,
        path: String? = nil
    ) {
        self.config = config
        self.apiKey = apiKey
        self.session = session ?? HTTPTransport.makeSession(timeout: max(config.timeout, 60))
        self.customPath = path
    }

    // MARK: - ImageGenerating

    /// 生成图片。
    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        guard config.isImageConfigured else {
            throw AIError.notConfigured
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
        let trimmedPrompt = request.trimmedPrompt
        guard !trimmedPrompt.isEmpty else {
            throw AIError.contentRejected("提示词不能为空")
        }
        let model = config.imageModel ?? ""
        // gpt-image-1 系列不接受 response_format，默认不带；其它模型默认带 b64_json。
        let shouldSendResponseFormat = !OpenAICompatibleImageClient.modelRejectsResponseFormat(model)
        let data = try await performGeneration(
            request: request,
            model: model,
            includeResponseFormat: shouldSendResponseFormat,
            attempt: 1
        )
        return try await decodeImages(data: data, session: session)
    }

    // MARK: - 请求

    /// 某些模型的参数差异（目前只有 gpt-image-1 系列不支持 response_format）。
    static func modelRejectsResponseFormat(_ model: String) -> Bool {
        let lowercased = model.lowercased()
        return lowercased.hasPrefix("gpt-image")
    }

    /// 执行一次生成请求，失败时按需重试。
    private func performGeneration(
        request: ImageRequest,
        model: String,
        includeResponseFormat: Bool,
        attempt: Int
    ) async throws -> Data {
        guard let url = generationURL() else { throw AIError.notConfigured }
        var body: [String: Any] = [
            "model": model,
            "prompt": request.trimmedPrompt,
            "n": max(request.count, 1),
            "size": request.size
        ]
        if !request.quality.isEmpty {
            body["quality"] = request.quality
        }
        if includeResponseFormat {
            body["response_format"] = "b64_json"
        }
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .bearer(apiKey),
            extraHeaders: config.extraHeaders,
            timeout: max(config.timeout, 60),
            body: body
        )
        do {
            let (data, _) = try await HTTPTransport.send(urlRequest, session: session)
            return data
        } catch let error as AIError {
            // gpt-image-1 老网关：提示未知字段 → 去掉 response_format 重试一次。
            if includeResponseFormat, case let .server(code, message) = error, code == 400 {
                let lowercasedMessage = (message ?? "").lowercased()
                let looksLikeUnknownField = lowercasedMessage.contains("unknown")
                    || lowercasedMessage.contains("unrecognized")
                    || lowercasedMessage.contains("response_format")
                    || lowercasedMessage.contains("extra fields")
                    || lowercasedMessage.contains("unsupported")
                if looksLikeUnknownField {
                    return try await performGeneration(
                        request: request,
                        model: model,
                        includeResponseFormat: false,
                        attempt: attempt
                    )
                }
            }
            // 仅幂等重试 ≤2 次，指数退避 1s / 2s。
            if error.isRetryable, attempt <= 2 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                try Task.checkCancellation()
                return try await performGeneration(
                    request: request,
                    model: model,
                    includeResponseFormat: includeResponseFormat,
                    attempt: attempt + 1
                )
            }
            throw error
        }
    }

    /// `{base}/images/generations`（或自定义 path）。
    private func generationURL() -> URL? {
        if let customPath, !customPath.isEmpty {
            if customPath.hasPrefix("http"), let url = URL(string: customPath) {
                return url
            }
            return config.resolvedURL(path: customPath)
        }
        return config.resolvedURL(path: "/images/generations")
    }

    // MARK: - 响应解析

    /// 解析 `{"data":[{"b64_json":...}|{"url":...}]}`。
    private func decodeImages(data: Data, session: URLSession) async throws -> [GeneratedImage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("生图返回内容不是合法 JSON：\(HTTPTransport.extractPlainText(from: data) ?? "")")
        }
        if let errorMessage = HTTPTransport.extractErrorMessage(from: data), root["data"] == nil {
            throw AIError.server(code: 200, message: errorMessage)
        }
        guard let items = root["data"] as? [[String: Any]], !items.isEmpty else {
            throw AIError.contentRejected("服务端没有返回图片，可能被内容安全策略拦截")
        }
        var results: [GeneratedImage] = []
        for item in items {
            if let base64 = item["b64_json"] as? String,
               let bytes = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
               !bytes.isEmpty {
                if bytes.count > ImageDownloader.maxBytes {
                    throw AIError.server(code: 413, message: "图片体积超过 4 MB 上限，请换更小的尺寸")
                }
                let mime = (item["mime_type"] as? String) ?? "image/png"
                results.append(GeneratedImage(data: bytes, remoteURL: nil, mimeType: mime))
                continue
            }
            if let urlString = item["url"] as? String, let remoteURL = URL(string: urlString) {
                let bytes = try await ImageDownloader.download(url: remoteURL, session: session)
                results.append(
                    GeneratedImage(
                        data: bytes,
                        remoteURL: remoteURL,
                        mimeType: ImageDownloader.mimeType(for: remoteURL)
                    )
                )
                continue
            }
        }
        guard !results.isEmpty else {
            throw AIError.decoding("生图响应里既没有 b64_json 也没有 url")
        }
        return results
    }
}
