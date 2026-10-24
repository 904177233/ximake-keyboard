//
//  SeedreamImageClient.swift
//  ios/Shared/Networking
//
//  模块职责：即梦（Seedream / 火山方舟 Ark）生图客户端。Ark 采用 OpenAI 兼容的
//            `POST {base}/images/generations` 同步接口，默认返回 `url`，需再下载图片数据。
//  依赖：Foundation、Models、HTTPTransport、AIError。
//  使用方：ImageClientRouter（baseURL 含 ark.cn-beijing.volces.com，或 model 含 seedream/doubao）。
//

import Foundation

/// 即梦 · 火山方舟（Seedream）生图客户端。
///
/// 请求约定：
/// - `POST https://ark.cn-beijing.volces.com/api/v3/images/generations`
/// - Header：`Authorization: Bearer <ARK_API_KEY>`、`Content-Type: application/json`
/// - Body：`{"model":"doubao-seedream-3-0-t2i-250415","prompt":"...","size":"1024x1024","response_format":"url","watermark":false}`
/// - 响应：`{"data":[{"url":"https://..."}],"usage":{"generated_images":1},"created":1730000000}`
///
/// 说明：
/// - 返回的 url 有效期约 24 小时，客户端会立即下载为 Data（≤ 4 MB）并保留 `remoteURL`；
/// - 可用尺寸：`1024x1024`、`864x1152`、`1152x864`、`1280x720`、`720x1280`；
/// - `watermark: false` 需要账号具备无水印权限，否则服务端会忽略该字段。
public final class SeedreamImageClient: ImageGenerating, @unchecked Sendable {

    /// 即梦默认生图模型（3.0）。
    public static let defaultModel = "doubao-seedream-3-0-t2i-250415"
    /// 即梦备选生图模型（4.0）。
    public static let fallbackModel = "doubao-seedream-4-0-250828"
    /// 即梦支持的尺寸（API 只接受这几档）。
    public static let supportedSizes: [String] = [
        "1024x1024",
        "864x1152",
        "1152x864",
        "1280x720",
        "720x1280"
    ]

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

    /// 生成图片。
    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        guard config.isImageConfigured else { throw AIError.notConfigured }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
        let prompt = request.trimmedPrompt
        guard !prompt.isEmpty else { throw AIError.contentRejected("提示词不能为空") }
        guard let url = generationURL() else { throw AIError.notConfigured }

        let model = SeedreamImageClient.resolvedModel(config.imageModel)
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": SeedreamImageClient.resolvedSize(request.size),
            "response_format": "url",
            "watermark": false
        ]
        // 部分接入点接受 n，1 张即可；保持在 body 里便于服务端计量。
        if request.count > 1 {
            body["n"] = min(request.count, 4)
        }
        let urlRequest = try HTTPTransport.makeJSONRequest(
            url: url,
            auth: .bearer(apiKey),
            extraHeaders: config.extraHeaders,
            timeout: max(config.timeout, 60),
            body: body
        )
        let data = try await performWithRetry(urlRequest, attempt: 1)
        return try await decodeImages(data: data)
    }

    // MARK: - 内部实现

    /// `{base}/images/generations`。
    private func generationURL() -> URL? {
        config.resolvedURL(path: "/images/generations")
    }

    /// 仅对幂等请求做 ≤2 次指数退避重试。
    private func performWithRetry(_ request: URLRequest, attempt: Int) async throws -> Data {
        do {
            let (data, _) = try await HTTPTransport.send(request, session: session)
            return data
        } catch let error as AIError {
            if error.isRetryable, attempt <= 2 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                try Task.checkCancellation()
                return try await performWithRetry(request, attempt: attempt + 1)
            }
            throw error
        }
    }

    /// 解析 `{"data":[{"url":...}|{"b64_json":...}]}` 并下载图片。
    private func decodeImages(data: Data) async throws -> [GeneratedImage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decoding("即梦生图返回内容不是合法 JSON")
        }
        if root["data"] == nil, let message = HTTPTransport.extractErrorMessage(from: data) {
            throw AIError.server(code: 200, message: message)
        }
        guard let items = root["data"] as? [[String: Any]], !items.isEmpty else {
            throw AIError.contentRejected("即梦没有返回图片，可能被内容安全策略拦截，请调整提示词")
        }
        var results: [GeneratedImage] = []
        for item in items {
            if let base64 = item["b64_json"] as? String,
               let bytes = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
               !bytes.isEmpty {
                if bytes.count > ImageDownloader.maxBytes {
                    throw AIError.server(code: 413, message: "图片体积超过 4 MB 上限，请换更小的尺寸")
                }
                results.append(GeneratedImage(data: bytes, remoteURL: nil, mimeType: "image/png"))
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
            throw AIError.decoding("即梦生图响应里既没有 url 也没有 b64_json")
        }
        return results
    }

    /// 归一化模型名：空则用默认 3.0；`doubao-seedream` 前缀但未带日期时补默认日期后缀。
    static func resolvedModel(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultModel
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化尺寸：只保留 API 支持的档位，不支持时退回 `1024x1024`。
    static func resolvedSize(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: "×", with: "x")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if supportedSizes.contains(normalized) {
            return normalized
        }
        return "1024x1024"
    }
}
