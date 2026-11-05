//
//  ProviderCheck.swift
//  ios/Shared/Networking
//
//  模块职责：用用户的 Key 确认一个服务能不能用。
//            各家的模型名变得很快，预设里写的只是起点：模型下线了就从这家现在的列表里换一个，
//            不让用户自己去查模型名。App 和键盘的设置页共用。
//

import Foundation

/// 查一家服务现在有哪些模型。
public enum ModelCatalog {

    /// 这些词说明它不是聊天模型。
    private static let notChat = ["embedding", "embed", "whisper", "tts", "rerank", "moderation", "audio",
                                  "image", "seedream", "seedance", "video", "ocr", "asr", "wan2", "wan3", "wanx",
                                  "cogview", "dall-e", "sora", "realtime", "transcribe", "speech", "t2i", "t2v", "i2v"]
    private static let imageWords = ["image", "seedream", "wanx", "wan2", "cogview", "dall-e", "t2i"]

    /// 取模型列表。接口不支持或请求失败时抛错，调用方决定怎么办。
    /// - Parameter forImage: true 只留画图模型，false 只留聊天模型。
    public static func fetch(config: AIProviderConfig, apiKey: String, forImage: Bool,
                             session: URLSession? = nil) async throws -> [String] {
        guard let url = listURL(for: config) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        for (name, value) in config.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if config.kind == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await HTTPTransport.send(request, session: session ?? HTTPTransport.makeSession(timeout: 10))
        return filter(parseIDs(data), forImage: forImage)
    }

    /// 列表接口的地址。没有列表接口时返回 nil。
    static func listURL(for config: AIProviderConfig) -> URL? {
        switch config.kind {
        case .gemini:
            return nil
        case .anthropic:
            let base = config.normalizedBaseURL
            if base.lowercased().hasSuffix("/v1") {
                return URL(string: base + "/models?limit=100")
            }
            return URL(string: base + "/v1/models?limit=100")
        case .openAICompatible, .custom:
            // 万相的原生地址没有列表接口，同一个 Key 走它的兼容模式查
            let base = config.normalizedBaseURL.lowercased()
            if base.contains("dashscope.aliyuncs.com"), !base.contains("compatible-mode") {
                return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models")
            }
            return config.resolvedURL(path: "/models")
        }
    }

    /// 解析 `{"data":[{"id":"…"}]}`（OpenAI、Anthropic 都是这个形状）。
    static func parseIDs(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { $0["id"] as? String }
    }

    static func filter(_ ids: [String], forImage: Bool) -> [String] {
        ids.filter { id in
            let lower = id.lowercased()
            return forImage
                ? imageWords.contains { lower.contains($0) }
                : !notChat.contains { lower.contains($0) }
        }
    }

    /// 当前模型用不了时换哪个：优先预设里排前面的，其次列表第一个。
    public static func replacement(for current: String, preferred: [String], available: [String]) -> String? {
        let lowered = Set(available.map { $0.lowercased() })
        if let first = preferred.first(where: { lowered.contains($0.lowercased()) && $0 != current }) {
            return first
        }
        return available.first { $0 != current }
    }
}

/// 确认一个服务能不能用的结果。
public struct ProviderCheckResult: Sendable {
    /// 可能换过模型的配置，保存时用它。
    public var config: AIProviderConfig
    public var isUsable: Bool
    /// 说给用户听的一句话。
    public var message: String
    /// 这家现在的模型（查过才有），设置页拿来给人选。
    public var models: [String]
}

public enum ProviderCheck {

    public static func run(config: AIProviderConfig, apiKey: String) async -> ProviderCheckResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return ProviderCheckResult(config: config, isUsable: false, message: "先填 Key", models: [])
        }
        if !config.supportsChat {
            return await checkImage(config: config, apiKey: key)
        }
        return await checkChat(config: config, apiKey: key)
    }

    // MARK: - 写字

    private static func checkChat(config: AIProviderConfig, apiKey: String) async -> ProviderCheckResult {
        let started = Date()
        do {
            let sample = try await sayHello(config: config, apiKey: apiKey)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return ProviderCheckResult(config: config, isUsable: true,
                                       message: sample.isEmpty
                                           ? "连上了（\(ms) 毫秒），但模型没有返回文字，换个模型试试。"
                                           : "能用（\(ms) 毫秒）：\(String(sample.prefix(40)))",
                                       models: [])
        } catch {
            let wrapped = AIError.wrap(error)
            let reason = wrapped.errorDescription ?? error.localizedDescription
            guard isModelProblem(wrapped) else {
                return ProviderCheckResult(config: config, isUsable: false, message: reason, models: [])
            }
            return await recoverModel(config: config, apiKey: apiKey, firstReason: reason)
        }
    }

    /// Key 没问题但模型不行：查这家现在有什么，换几个试试。
    /// 有的服务商（火山方舟）列表里有的不一定开通了，所以不能只试一个；查不到列表就试预设里的。
    private static func recoverModel(config: AIProviderConfig, apiKey: String,
                                     firstReason: String) async -> ProviderCheckResult {
        let models = (try? await ModelCatalog.fetch(config: config, apiKey: apiKey, forImage: false)) ?? []
        let preferred = PresetProviders.preset(id: config.id)?.availableModels.map(\.modelID) ?? []
        let known = Set(models.map { $0.lowercased() })
        let ordered = models.isEmpty ? preferred : preferred.filter { known.contains($0.lowercased()) } + models
        var seen: Set<String> = [config.model]
        for next in ordered.filter({ seen.insert($0).inserted }).prefix(4) {
            var changed = config
            changed.model = next
            if let sample = try? await sayHello(config: changed, apiKey: apiKey), !sample.isEmpty {
                return ProviderCheckResult(config: changed, isUsable: true,
                                           message: "能用。\(config.model) 用不了，已换成 \(next)。",
                                           models: models)
            }
        }
        var message = firstReason
        if config.normalizedBaseURL.lowercased().contains("volces") {
            message += "\n豆包的模型要先开通：到火山方舟控制台的「开通管理」开通后再试。"
        } else if !models.isEmpty {
            message += "\n这家现在的模型在下面，选一个再试。"
        }
        return ProviderCheckResult(config: config, isUsable: false, message: message, models: models)
    }

    private static func sayHello(config: AIProviderConfig, apiKey: String) async throws -> String {
        let request = ChatRequest(messages: [.user("hi")], temperature: 0, maxTokens: 1024, stream: false)
        let result = try await AIClientFactory.makeLLM(config: config, apiKey: apiKey).complete(request)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 服务器回的 400、403、404 多半是模型的事（下线了或没开通）。Key 错、限流、断网换模型也没用。
    public static func isModelProblem(_ error: AIError) -> Bool {
        if case let .server(code, _) = error {
            return code == 400 || code == 403 || code == 404
        }
        return false
    }

    // MARK: - 画图

    /// 即梦：不出图也能分清 Key 错和模型没开通。
    private static func checkSeedream(config: AIProviderConfig, apiKey: String) async -> ProviderCheckResult {
        switch await SeedreamImageClient.probe(config: config, apiKey: apiKey) {
        case let .usable(model):
            var changed = config
            changed.imageModel = model
            return ProviderCheckResult(config: changed, isUsable: true,
                                       message: "Key 能用，用 \(model) 画图。没有真的画图，第一张图出来才算数。",
                                       models: [])
        case .unauthorized:
            return ProviderCheckResult(config: config, isUsable: false, message: "Key 不对，检查一下有没有复制完整。", models: [])
        case let .noModel(reason):
            return ProviderCheckResult(config: config, isUsable: false,
                                       message: "Key 是对的，但 Seedream 模型都用不了，多半是还没开通。到火山方舟控制台的「开通管理」开通后再试。\n\(reason ?? "")",
                                       models: [])
        case let .unreachable(reason):
            return ProviderCheckResult(config: config, isUsable: false, message: reason, models: [])
        }
    }

    /// 真画一张要花钱，这里只查模型列表，顺便确认 Key。
    private static func checkImage(config: AIProviderConfig, apiKey: String) async -> ProviderCheckResult {
        if ImageClientRouter.route(for: config) == .seedream {
            return await checkSeedream(config: config, apiKey: apiKey)
        }
        do {
            let models = try await ModelCatalog.fetch(config: config, apiKey: apiKey, forImage: true)
            let current = config.imageModel ?? ""
            let known = models.contains { $0.lowercased() == current.lowercased() }
            let preferred = PresetProviders.preset(id: config.id)?.availableModels.map(\.modelID) ?? []
            if !models.isEmpty, !known,
               let next = ModelCatalog.replacement(for: current, preferred: preferred, available: models) {
                var changed = config
                changed.imageModel = next
                return ProviderCheckResult(config: changed, isUsable: true,
                                           message: "Key 能用。\(current) 不在这家的列表里，已换成 \(next)。没有真的画图，第一张图画出来才算数。",
                                           models: models)
            }
            return ProviderCheckResult(config: config, isUsable: true,
                                       message: "Key 能用。没有真的画图，第一张图画出来才算数。",
                                       models: models)
        } catch {
            let wrapped = AIError.wrap(error)
            if case .unauthorized = wrapped {
                return ProviderCheckResult(config: config, isUsable: false,
                                           message: wrapped.errorDescription ?? "Key 不对", models: [])
            }
            // 列表查不了不等于不能画，放行，但说清楚
            return ProviderCheckResult(config: config, isUsable: true,
                                       message: "这家查不了模型列表，Key 对不对要画一张才知道。",
                                       models: [])
        }
    }
}

public extension PresetProviders {

    /// 同一个 Key 能用的另一半（写字 ↔ 画图）。
    static let sharedKeyPartners: [String: String] = [
        "preset-qwen": "preset-wanx",
        "preset-wanx": "preset-qwen",
        "preset-ark": "preset-seedream",
        "preset-seedream": "preset-ark"
    ]

    /// 列表里用的短名字。
    static func shortName(id: String) -> String {
        switch id {
        case "preset-deepseek": return "DeepSeek"
        case "preset-qwen": return "通义千问"
        case "preset-kimi": return "Kimi"
        case "preset-glm": return "智谱"
        case "preset-ark": return "豆包"
        case "preset-openrouter": return "OpenRouter"
        case "preset-siliconflow": return "硅基流动"
        case "preset-openai": return "OpenAI"
        case "preset-anthropic": return "Claude"
        case "preset-seedream": return "即梦"
        case "preset-wanx": return "通义万相"
        default: return preset(id: id)?.name ?? id
        }
    }

    /// 添加列表里的一句话介绍。
    static func tagline(id: String) -> String {
        switch id {
        case "preset-deepseek": return "便宜，中文好，推荐先用这个"
        case "preset-qwen": return "阿里云，同一个 Key 还能画图"
        case "preset-kimi": return "月之暗面"
        case "preset-glm": return "有免费模型，适合先试试"
        case "preset-ark": return "字节跳动，同一个 Key 还能画图"
        case "preset-openrouter": return "一个 Key 用很多家，国内可能连不上"
        case "preset-siliconflow": return "开源模型多，新账号有赠送额度"
        case "preset-openai": return "国内通常连不上"
        case "preset-anthropic": return "国内通常连不上"
        case "preset-seedream": return "字节跳动，和豆包共用 Key"
        case "preset-wanx": return "阿里云，和通义千问共用 Key"
        default: return ""
        }
    }

    /// 保存一个服务，并把该顺手做的做了：刚加的就用它；同一个 Key 能画图（或写字）的也配上。
    ///
    /// - Parameters:
    ///   - hasKey: 这个 id 现在有没有 Key（`saved` 自己的 Key 可能还没写进去）。
    /// - Returns: 顺手加上的另一半。调用方要把同一个 Key 也存给它。
    @discardableResult
    static func adopt(_ saved: AIProviderConfig, keyIsSet: Bool, isNew: Bool,
                      into snapshot: inout ConfigSnapshot,
                      hasKey: (String) -> Bool) -> AIProviderConfig? {
        if let index = snapshot.providers.firstIndex(where: { $0.id == saved.id }) {
            snapshot.providers[index] = saved
        } else {
            snapshot.providers.append(saved)
        }
        func usable(_ provider: AIProviderConfig?) -> Bool {
            guard let provider else { return false }
            return provider.id == saved.id ? keyIsSet : hasKey(provider.id)
        }
        // 默认配的那家没填 Key 的话，默认就等于没配
        if saved.supportsChat, snapshot.defaultProviderID == nil || (keyIsSet && (isNew || !usable(snapshot.defaultProvider))) {
            snapshot.defaultProviderID = saved.id
        }
        if saved.supportsImage, snapshot.imageProviderID == nil || (keyIsSet && !usable(snapshot.imageProvider)) {
            snapshot.imageProviderID = saved.id
        }
        guard keyIsSet, let partnerID = sharedKeyPartners[saved.id], let partnerPreset = preset(id: partnerID) else {
            return nil
        }
        let partnerIsImage = partnerPreset.isImageOnly
        // 这件事已经有填了 Key 的服务在做，就不动
        if snapshot.providers.contains(where: { provider in
            (partnerIsImage ? provider.supportsImage : provider.supportsChat) && usable(provider)
        }) {
            return nil
        }
        let partner = snapshot.providers.first { $0.id == partnerID } ?? partnerPreset.makeProvider()
        if !snapshot.providers.contains(where: { $0.id == partnerID }) {
            snapshot.providers.append(partner)
        }
        if partnerIsImage {
            snapshot.imageProviderID = partnerID
        } else {
            snapshot.defaultProviderID = partnerID
        }
        return partner
    }

    /// 默认的那家没填 Key、别的填了的话，默认改成填了的。
    static func repairDefaults(_ snapshot: inout ConfigSnapshot, hasKey: (String) -> Bool) {
        if let current = snapshot.defaultProvider, hasKey(current.id) {
            // 已经能用
        } else if let keyed = snapshot.providers.first(where: { $0.supportsChat && hasKey($0.id) }) {
            snapshot.defaultProviderID = keyed.id
        }
        if let current = snapshot.imageProvider, hasKey(current.id) {
            // 已经能用
        } else if let keyed = snapshot.providers.first(where: { $0.supportsImage && hasKey($0.id) }) {
            snapshot.imageProviderID = keyed.id
        }
    }

    /// 已确认用不了的画图模型 -> 替代。
    static let retiredImageModels: [String: String] = [
        "doubao-seedream-3-0-t2i-250415": "doubao-seedream-5-0-pro-260628"
    ]

    /// 读配置时换掉已确认下线的模型。只换内置服务，自定义服务（中转站）的模型名可能另有含义。
    static func migrateRetiredModels(_ provider: inout AIProviderConfig) {
        guard preset(id: provider.id) != nil else { return }
        if let next = retiredModels[provider.model] {
            provider.model = next
        }
        if let image = provider.imageModel, let next = retiredImageModels[image] {
            provider.imageModel = next
        }
    }

    /// 已确认下线的模型名 -> 替代。老用户存过的配置在读取时换掉。
    static let retiredModels: [String: String] = [
        "deepseek-chat": "deepseek-flash",
        "deepseek-reasoner": "deepseek-flash",
        "claude-3-5-sonnet-latest": "claude-sonnet-5-5",
        "claude-3-5-haiku-latest": "claude-haiku-5-5"
    ]
}
