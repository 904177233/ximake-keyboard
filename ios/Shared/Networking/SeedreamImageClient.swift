//
//  SeedreamImageClient.swift
//  ios/Shared/Networking
//
//  即梦（Seedream / 火山方舟 Ark）生图客户端。Ark 采用 OpenAI 兼容的
//  `POST {base}/images/generations` 同步接口，默认返回 `url`，需再下载图片数据。
//

import Foundation

/// 即梦 · 火山方舟（Seedream）生图客户端。
///
/// - 各版本的模型名和尺寸下限不一样（4.5、5.0 lite 最小 2560x1440），每个账号开通的模型也不一样。
///   所以按「用户选的 -> 上次成功的 -> 新到旧」逐个试，模型不可用时换下一个。不出图不收费。
/// - `watermark: false` 需要账号具备无水印权限，否则服务端会忽略该字段。
public final class SeedreamImageClient: ImageGenerating, @unchecked Sendable {

    /// 默认生图模型。
    public static let defaultModel = "doubao-seedream-5-0-pro-260628"
    /// 备选生图模型。
    public static let fallbackModel = "doubao-seedream-4-0-250828"
    /// 从新到旧试。
    static let modelChain = [
        "doubao-seedream-5-0-pro-260628",
        "doubao-seedream-5-0-lite-260128",
        "doubao-seedream-4-5-251128",
        "doubao-seedream-4-0-250828",
        "doubao-seedream-3-0-t2i-250415"
    ]
    /// 尺寸档位。
    public static let supportedSizes: [String] = [
        "1024x1024",
        "864x1152",
        "1152x864",
        "1280x720",
        "720x1280"
    ]

    private static let lastGoodKey = "moyu.seedream.lastGoodModel"

    /// 只用配置里的模型，不自动换（有的账号只有某一个模型有额度）。
    private let onlyConfiguredModel: Bool
    /// 服务商配置。
    private let config: AIProviderConfig
    /// 明文 API Key。
    private let apiKey: String
    /// 复用的 URLSession。
    private let session: URLSession

    /// 创建客户端。
    public init(config: AIProviderConfig, apiKey: String, session: URLSession? = nil, onlyConfiguredModel: Bool = false) {
        self.onlyConfiguredModel = onlyConfiguredModel
        self.config = config
        self.apiKey = apiKey
        self.session = session ?? HTTPTransport.makeSession(timeout: max(config.timeout, 120))
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

        let lastGood = UserDefaults.standard.string(forKey: Self.lastGoodKey)
        var attempts: [(model: String, error: AIError)] = []
        let models = onlyConfiguredModel
            ? [Self.candidates(configured: config.imageModel, lastGood: nil)[0]]
            : Self.candidates(configured: config.imageModel, lastGood: lastGood)
        for model in models {
            var body: [String: Any] = [
                "model": model,
                "prompt": prompt,
                "size": Self.resolvedSize(request.size, model: model),
                "response_format": "url",
                "watermark": false
            ]
            if request.count > 1 {
                body["n"] = min(request.count, 4)
            }
            let urlRequest = try HTTPTransport.makeJSONRequest(
                url: url,
                auth: .bearer(apiKey),
                extraHeaders: config.extraHeaders,
                timeout: max(config.timeout, 120),
                body: body
            )
            do {
                let data = try await performWithRetry(urlRequest, attempt: 1)
                let images = try await decodeImages(data: data).map { image -> GeneratedImage in
                    var tagged = image
                    tagged.model = model
                    return tagged
                }
                UserDefaults.standard.set(model, forKey: Self.lastGoodKey)
                return images
            } catch let error as AIError where Self.shouldTryNextModel(error) {
                attempts.append((model, error))
            }
        }
        throw Self.allModelsFailed(attempts)
    }

    // MARK: - 检查 Key 和模型（不花钱）

    /// 检查结果。
    public enum ProbeResult: Equatable, Sendable {
        /// 这个模型开通了。
        case usable(String)
        case unauthorized
        /// 一个都用不了。
        case noModel(String?)
        /// 连不上。
        case unreachable(String)
    }

    /// 用空提示词请求：Key 错回 401，模型没开通回 404，都对的话回 400 说缺提示词。不出图，不收费。
    public static func probe(config: AIProviderConfig, apiKey: String, session: URLSession? = nil) async -> ProbeResult {
        guard let url = config.resolvedURL(path: "/images/generations") else {
            return .noModel("地址不对")
        }
        let urlSession = session ?? HTTPTransport.makeSession(timeout: 20)
        var lastMessage: String?
        for model in candidates(configured: config.imageModel, lastGood: nil) {
            guard let request = try? HTTPTransport.makeJSONRequest(url: url,
                                                                   auth: .bearer(apiKey),
                                                                   extraHeaders: config.extraHeaders,
                                                                   timeout: 20,
                                                                   body: ["model": model, "prompt": ""]) else {
                continue
            }
            do {
                _ = try await HTTPTransport.send(request, session: urlSession)
                return .usable(model)
            } catch let error as AIError {
                switch error {
                case .unauthorized:
                    return .unauthorized
                case let .server(code, message) where code == 400:
                    if isModelMissing(message) {
                        lastMessage = message
                    } else {
                        return .usable(model)
                    }
                case let .server(_, message):
                    lastMessage = message
                default:
                    return .unreachable(error.errorDescription ?? "连不上")
                }
            } catch {
                return .unreachable(error.localizedDescription)
            }
        }
        return .noModel(lastMessage)
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
                    throw AIError.server(code: 413, message: "图片太大，请换更小的尺寸")
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

    /// 要试的模型，按顺序去重。
    static func candidates(configured: String?, lastGood: String?) -> [String] {
        var seen = Set<String>()
        let chosen = (configured ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ([chosen, lastGood ?? ""] + modelChain).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 服务器说的是没额度、欠费。
    static func isQuotaProblem(_ message: String?) -> Bool {
        let lower = (message ?? "").lowercased()
        return ["quota", "balance", "insufficient", "overdue", "arrear", "exceeded", "额度", "余额", "欠费"].contains { lower.contains($0) }
    }

    /// 服务器说的是模型不存在或没开通。
    static func isModelMissing(_ message: String?) -> Bool {
        let lower = (message ?? "").lowercased()
        return ["modelnotopen", "notfound", "not found", "not activated", "does not exist", "未开通"]
            .contains { lower.contains($0) }
    }

    /// 换个模型可能就好了。提示词被内容审核拦下来的不算，换模型也一样。
    static func shouldTryNextModel(_ error: AIError) -> Bool {
        guard case let .server(code, message) = error, [400, 403, 404].contains(code) else { return false }
        return !(message ?? "").lowercased().contains("sensitive")
    }

    /// 都失败了怎么说。
    ///
    /// 不能只报第一个：第一个往往是配置里的老模型（3.0），它报「没开通」会把真正的原因盖住。
    /// 有不是「没开通 / 不存在」的错（参数不对、额度用完），那才是真问题，先报它；
    /// 全是没开通，就把试过的都列出来。
    static func allModelsFailed(_ attempts: [(model: String, error: AIError)]) -> AIError {
        guard !attempts.isEmpty else { return .notConfigured }
        for attempt in attempts {
            if case let .server(code, message) = attempt.error, isQuotaProblem(message) {
                return .server(code: code, message: "\(displayName(attempt.model)) 没有额度了。到火山方舟控制台看看哪个模型还有额度，在画图设置里选它，并打开「只用这个模型」。服务器原话：\(message ?? "")")
            }
        }
        for attempt in attempts {
            if case let .server(code, message) = attempt.error, code != 404, !isModelMissing(message) {
                return .server(code: code, message: "\(displayName(attempt.model))：\(message ?? "没有说明")")
            }
        }
        let names = attempts.map { displayName($0.model) }.joined(separator: "、")
        var reason = ""
        if case let .server(_, message)? = attempts.last?.error, let message {
            reason = "\n服务器原话：\(message)"
        }
        return .server(code: 404,
                       message: "试了 \(names)，都显示没开通或不存在。到火山方舟控制台「开通管理」开通一个 Seedream 模型；开通的如果是别的型号，在画图服务的「模型」里填它的名字。\(reason)")
    }

    /// 给人看的模型名。
    static func displayName(_ model: String) -> String {
        let known = [
            "doubao-seedream-5-0-pro-260628": "Seedream 5.0 Pro",
            "doubao-seedream-5-0-lite-260128": "Seedream 5.0 Lite",
            "doubao-seedream-4-5-251128": "Seedream 4.5",
            "doubao-seedream-4-0-250828": "Seedream 4.0",
            "doubao-seedream-3-0-t2i-250415": "Seedream 3.0"
        ]
        return known[model] ?? model
    }

    /// 这个模型该用什么尺寸。4.5 和 5.0 lite 不接受 1K 这一档。
    static func resolvedSize(_ raw: String, model: String) -> String {
        if model.contains("4-5") || model.contains("5-0-lite") {
            return "2K"
        }
        let normalized = raw
            .replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: "×", with: "x")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return supportedSizes.contains(normalized) ? normalized : "1024x1024"
    }
}
