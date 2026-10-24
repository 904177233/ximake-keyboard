//
//  AIProviderConfig.swift
//  ios/Shared/Models
//
//  模块职责：一个 AI 服务商的完整配置（协议类型 / baseURL / 模型 / 采样参数 / 自定义 header），
//            是 App 与键盘扩展之间搬运的核心数据。
//  依赖：Foundation、ProviderKind。
//  使用方：Networking（三个 LLM 客户端与生图路由取参数）、Storage（ConfigSnapshot 持久化）、
//          UI（ProviderEditorView 编辑、SettingsView 列表）。
//

import Foundation

/// 一个 AI 服务商的完整配置。
///
/// 全部字段都有默认值，任何子集参数都能构造，便于 UI 表单与老版本快照迁移。
public struct AIProviderConfig: Identifiable, Codable, Equatable, Sendable {
    /// 稳定唯一标识（UUID 字符串）。同时作为 Keychain 中 API Key 的 account。
    public var id: String
    /// 展示名称，例如 "DeepSeek"。
    public var name: String
    /// 协议类型，决定走哪个网络客户端。
    public var kind: ProviderKind
    /// 接口根地址，例如 `https://api.deepseek.com/v1`。末尾斜杠会被客户端自动归一化。
    public var baseURL: String
    /// 文本对话模型，例如 `deepseek-chat`。
    public var model: String
    /// 生图模型（可选），例如 `doubao-seedream-3-0-t2i-250415`。
    public var imageModel: String?
    /// 采样温度，0...2，默认 0.7。
    public var temperature: Double
    /// 单次回复最大 token 数，默认 1024。
    public var maxTokens: Int
    /// 请求超时（秒），默认 30。
    public var timeout: TimeInterval
    /// 附加请求头，用于中转站鉴权（例如 `HTTP-Referer`、`X-Title`）。
    public var extraHeaders: [String: String]
    /// 该模型是否支持图片输入（视觉），v1 仅用于 UI 提示。
    public var supportsVision: Bool
    /// 是否为默认 Provider（同一时刻建议只有一个为 true，由 UI 维护）。
    public var isDefault: Bool

    /// API Key 在 Keychain 中的引用键。约定等于 `id`，方便 Keychain 以 account 存取。
    ///
    /// 该属性是计算属性（不参与 Codable），保证 Key 永远不会被写进配置 JSON。
    public var apiKeyRef: String { id }

    /// 全部字段带默认值的成员初始化。
    public init(
        id: String = UUID().uuidString,
        name: String = "",
        kind: ProviderKind = .openAICompatible,
        baseURL: String = "",
        model: String = "",
        imageModel: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int = 1024,
        timeout: TimeInterval = 30,
        extraHeaders: [String: String] = [:],
        supportsVision: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.imageModel = imageModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeout = timeout
        self.extraHeaders = extraHeaders
        self.supportsVision = supportsVision
        self.isDefault = isDefault
    }

    // MARK: - 容错解码（老版本快照缺字段时用默认值补齐）

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, imageModel
        case temperature, maxTokens, timeout, extraHeaders, supportsVision, isDefault
    }

    /// 容错解码：缺字段、字段类型不符、未知 kind 都不会抛错，回退到默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.kind = ProviderKind.tolerant(rawValue: try? container.decodeIfPresent(String.self, forKey: .kind))
        self.baseURL = (try? container.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        self.model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
        self.imageModel = try? container.decodeIfPresent(String.self, forKey: .imageModel)
        let decodedTemperature = (try? container.decodeIfPresent(Double.self, forKey: .temperature)) ?? nil
        self.temperature = AIProviderConfig.clampTemperature(decodedTemperature ?? 0.7)
        self.maxTokens = AIProviderConfig.clampMaxTokens(
            (try? container.decodeIfPresent(Int.self, forKey: .maxTokens)) ?? nil ?? 1024
        )
        let decodedTimeout = (try? container.decodeIfPresent(Double.self, forKey: .timeout)) ?? nil
        self.timeout = (decodedTimeout ?? 30) > 0 ? (decodedTimeout ?? 30) : 30
        self.extraHeaders = (try? container.decodeIfPresent([String: String].self, forKey: .extraHeaders)) ?? [:]
        self.supportsVision = (try? container.decodeIfPresent(Bool.self, forKey: .supportsVision)) ?? false
        self.isDefault = (try? container.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
    }

    /// 显式编码，保证只写已知字段（计算属性天然不参与）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(imageModel, forKey: .imageModel)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(extraHeaders, forKey: .extraHeaders)
        try container.encode(supportsVision, forKey: .supportsVision)
        try container.encode(isDefault, forKey: .isDefault)
    }

    // MARK: - 归一化

    /// 去空白、去末尾 `/` 的 baseURL；空串表示未配置。
    public var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// 该 Provider 是否具备发起文本对话的最小配置。
    public var isChatConfigured: Bool {
        !normalizedBaseURL.isEmpty && !model.isEmpty
    }

    /// 该 Provider 是否具备发起生图的最小配置。
    public var isImageConfigured: Bool {
        !normalizedBaseURL.isEmpty && !(imageModel ?? "").isEmpty
    }

    /// 该 Provider 是否可以用于**文本对话**。
    ///
    /// 三个不满足的情形：
    /// 1. 未填模型名（生图专用预设的 `model` 为空）；
    /// 2. `id` 命中 `PresetProviders.isImageOnly(id:)`（内置的即梦 / 通义万相预设）；
    /// 3. `kind == .custom` 且 baseURL 指向已知的生图网关（方舟 / DashScope 生图端点）。
    ///
    /// UI 在"选择默认对话服务商"时应过滤本属性为 false 的条目，并提示「该服务仅支持生图」。
    public var supportsChat: Bool {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if PresetProviders.isImageOnly(id: id) {
            return false
        }
        // 用户把生图预设"另存为自定义"后会换成新 UUID，此时只能靠 baseURL + 模型名判断。
        let lowercasedBase = normalizedBaseURL.lowercased()
        let lowercasedModel = model.lowercased()
        if lowercasedBase.contains("dashscope.aliyuncs.com") && !lowercasedBase.contains("compatible-mode") {
            // DashScope 原生端点（非 OpenAI 兼容模式）没有 chat/completions。
            return false
        }
        if lowercasedModel.contains("seedream") || lowercasedModel.contains("wanx") {
            return false
        }
        return true
    }

    /// 该 Provider 是否可以用于**生图**（有 imageModel 且有 baseURL）。
    public var supportsImage: Bool {
        isImageConfigured
    }

    /// 当 `supportsChat == false` 时给出的中文原因，供 UI 直接展示。
    public var unsupportedChatReason: String? {
        supportsChat ? nil : "该服务仅支持生图，不能用于文本对话。请改选 DeepSeek / 通义千问 / Kimi 等对话服务商。"
    }

    /// 一份用于 UI 展示的脱敏描述，例如 "OpenAI 兼容 · deepseek-chat"。
    public var displaySummary: String {
        let modelName = model.isEmpty ? "未选择模型" : model
        return "\(kind.title) · \(modelName)"
    }

    // MARK: - 数值约束

    /// 把温度夹到 0...2。
    public static func clampTemperature(_ value: Double) -> Double {
        min(max(value, 0), 2)
    }

    /// 把 maxTokens 夹到 1...32768。
    public static func clampMaxTokens(_ value: Int) -> Int {
        min(max(value, 1), 32768)
    }
}

/// 一条可选的模型条目，用于 Provider 编辑器里的模型选择列表。
///
/// CONTRACT-ADD: docs/02 §4.1 未列出该类型，为 UI 侧下拉选择提供轻量数据载体，纯新增、不影响契约。
public struct ModelRef: Identifiable, Codable, Equatable, Sendable {
    /// 唯一标识（一般直接用模型名）。
    public var id: String
    /// 展示名，例如 "DeepSeek Chat"。
    public var title: String
    /// 传给接口的模型名，例如 `deepseek-chat`。
    public var modelID: String
    /// 该模型是否支持图片输入。
    public var supportsVision: Bool

    /// 构造一条模型条目。
    public init(id: String? = nil, title: String, modelID: String, supportsVision: Bool = false) {
        self.id = id ?? modelID
        self.title = title
        self.modelID = modelID
        self.supportsVision = supportsVision
    }
}
