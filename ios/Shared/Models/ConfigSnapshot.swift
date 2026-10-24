//
//  ConfigSnapshot.swift
//  ios/Shared/Models
//
//  模块职责：App 与键盘扩展之间共享的**完整配置快照**（服务商列表 + 默认项 + 偏好开关）。
//            这是唯一被序列化成 JSON 放进 App Group / UserDefaults / 剪贴板的数据结构。
//  依赖：仅 Foundation、AIProviderConfig。
//  使用方：Storage（ConfigStore 读写、PasteboardBridge 导入导出）、
//          UI（AppConfigStore 构造、SettingsView 编辑）、键盘扩展（读取默认 Provider）。
//

import Foundation

/// 一份完整的配置快照。
///
/// 版本历史：
/// - v1：初版（providers / defaultProviderID / defaultTone / replyCount / 三个开关 / imageSize）。
/// - v2：新增 `imageProviderID`（生图可与对话使用不同服务商）。
///
/// 解码时对 v1 老快照做了兜底：缺失字段按 `defaultValue` 补齐，`version` 一律归一化为
/// `ConfigSnapshot.currentVersion`（由 `ConfigStore` 负责写回）。
public struct ConfigSnapshot: Codable, Equatable, Sendable {
    /// 当前快照结构版本号。新增字段必须 +1，并在 `ConfigStore.migrate(_:)` 里处理。
    public static let currentVersion: Int = 2

    /// 快照版本号（v1 = 1，v2 = 2）。
    public var version: Int
    /// 用户配置的全部服务商（含内置预设的副本与自定义条目）。
    public var providers: [AIProviderConfig]
    /// 默认**对话**服务商的 id（指向 `providers` 中某条的 `id`）。
    public var defaultProviderID: String?
    /// 默认语气（润色/扩写/回复建议会用到），例如 "自然"。
    public var defaultTone: String
    /// 回复建议条数，默认 3。
    public var replyCount: Int
    /// 是否启用剪贴板历史，默认关闭（隐私优先）。
    public var enableClipboardHistory: Bool
    /// 是否启用本地学习（词频/习惯），默认开启。
    public var enableLearning: Bool
    /// 默认生图尺寸，取值形如 "1024x1024" / "864x1152"。
    public var imageSize: String
    /// 默认**生图**服务商的 id（v2 新增）。与 `defaultProviderID` 相互独立：
    /// 对话与生图可以是两家不同的服务商（例如 DeepSeek 对话 + 即梦生图）。
    public var imageProviderID: String?
    /// 是否启用「AI 联想词」胶囊（候选栏尾部独立区域的上下文猜测词），默认开启。
    public var enableAISuggestion: Bool
    /// 是否启用输入纠错（原始输入无候选/候选过少时按声韵母规则给出带 `[纠错]` 标记的候选），默认开启。
    public var enableTypoCorrection: Bool

    /// 成员初始化。
    ///
    /// 前 8 个参数与 docs/02 §4.3 的顺序一致（宿主 App 的 `AppConfigStore` 依赖该顺序），
    /// `imageProviderID` 作为第 9 个参数追加，默认 nil，因此老调用点无需改动。
    /// `enableAISuggestion` / `enableTypoCorrection` 作为第 10、11 个参数追加，默认 true。
    public init(
        version: Int = ConfigSnapshot.currentVersion,
        providers: [AIProviderConfig] = [],
        defaultProviderID: String? = nil,
        defaultTone: String = "自然",
        replyCount: Int = 3,
        enableClipboardHistory: Bool = false,
        enableLearning: Bool = true,
        imageSize: String = "1024x1024",
        imageProviderID: String? = nil,
        enableAISuggestion: Bool = true,
        enableTypoCorrection: Bool = true
    ) {
        self.version = version
        self.providers = providers
        self.defaultProviderID = defaultProviderID
        self.defaultTone = defaultTone
        self.replyCount = replyCount
        self.enableClipboardHistory = enableClipboardHistory
        self.enableLearning = enableLearning
        self.imageSize = imageSize
        self.imageProviderID = imageProviderID
        self.enableAISuggestion = enableAISuggestion
        self.enableTypoCorrection = enableTypoCorrection
    }

    // MARK: - 容错解码

    private enum CodingKeys: String, CodingKey {
        case version, providers, defaultProviderID, defaultTone, replyCount
        case enableClipboardHistory, enableLearning, imageSize, imageProviderID
        case enableAISuggestion, enableTypoCorrection
    }

    /// 容错解码：任何字段缺失/类型不符都回退到默认值，保证老快照（v1）能直接读。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        self.providers = (try? container.decodeIfPresent([AIProviderConfig].self, forKey: .providers)) ?? []
        self.defaultProviderID = try? container.decodeIfPresent(String.self, forKey: .defaultProviderID)
        self.defaultTone = (try? container.decodeIfPresent(String.self, forKey: .defaultTone)) ?? "自然"
        let decodedReplyCount = (try? container.decodeIfPresent(Int.self, forKey: .replyCount)) ?? 3
        self.replyCount = min(max(decodedReplyCount, 1), 5)
        self.enableClipboardHistory = (try? container.decodeIfPresent(Bool.self, forKey: .enableClipboardHistory)) ?? false
        self.enableLearning = (try? container.decodeIfPresent(Bool.self, forKey: .enableLearning)) ?? true
        self.imageSize = (try? container.decodeIfPresent(String.self, forKey: .imageSize)) ?? "1024x1024"
        // v1 快照没有这个字段 → nil，属于预期行为。
        self.imageProviderID = try? container.decodeIfPresent(String.self, forKey: .imageProviderID)
        self.enableAISuggestion = (try? container.decodeIfPresent(Bool.self, forKey: .enableAISuggestion)) ?? true
        self.enableTypoCorrection = (try? container.decodeIfPresent(Bool.self, forKey: .enableTypoCorrection)) ?? true
    }

    /// 显式编码（保证字段齐全、顺序稳定，便于排查）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(providers, forKey: .providers)
        try container.encodeIfPresent(defaultProviderID, forKey: .defaultProviderID)
        try container.encode(defaultTone, forKey: .defaultTone)
        try container.encode(replyCount, forKey: .replyCount)
        try container.encode(enableClipboardHistory, forKey: .enableClipboardHistory)
        try container.encode(enableLearning, forKey: .enableLearning)
        try container.encode(imageSize, forKey: .imageSize)
        try container.encodeIfPresent(imageProviderID, forKey: .imageProviderID)
        try container.encode(enableAISuggestion, forKey: .enableAISuggestion)
        try container.encode(enableTypoCorrection, forKey: .enableTypoCorrection)
    }

    // MARK: - 默认值工厂

    /// 全新安装时的默认快照：只带一个 DeepSeek 对话服务商 + 一个即梦生图服务商，
    /// 两者都没有 API Key，UI 会引导用户去填写。
    public static func defaultValue() -> ConfigSnapshot {
        var providers: [AIProviderConfig] = []
        if let deepSeek = PresetProviders.recommended?.makeProvider(isDefault: true) {
            providers.append(deepSeek)
        }
        if let seedream = PresetProviders.defaultImagePreset?.makeProvider() {
            providers.append(seedream)
        }
        return ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            providers: providers,
            defaultProviderID: providers.first?.id,
            defaultTone: "自然",
            replyCount: 3,
            enableClipboardHistory: false,
            enableLearning: true,
            imageSize: "1024x1024",
            imageProviderID: PresetProviders.defaultImagePreset?.id,
            enableAISuggestion: true,
            enableTypoCorrection: true
        )
    }

    /// 只含内置预设、不带任何用户改动的快照（用于"恢复默认设置"）。
    public static func presetOnly() -> ConfigSnapshot {
        var providers = PresetProviders.chatPresetTemplates.map { $0.makeProvider() }
        providers.append(contentsOf: PresetProviders.imagePresetTemplates.map { $0.makeProvider() })
        return ConfigSnapshot(
            version: ConfigSnapshot.currentVersion,
            providers: providers,
            defaultProviderID: PresetProviders.recommended?.id,
            defaultTone: "自然",
            replyCount: 3,
            enableClipboardHistory: false,
            enableLearning: true,
            imageSize: "1024x1024",
            imageProviderID: PresetProviders.defaultImagePreset?.id,
            enableAISuggestion: true,
            enableTypoCorrection: true
        )
    }

    // MARK: - 查询便捷属性

    /// 默认对话服务商实体（找不到时回退到第一条可对话的服务商）。
    public var defaultProvider: AIProviderConfig? {
        if let id = defaultProviderID, let matched = providers.first(where: { $0.id == id }) {
            return matched
        }
        return providers.first { $0.supportsChat }
    }

    /// 默认生图服务商实体（找不到时回退到第一条可生图的服务商）。
    public var imageProvider: AIProviderConfig? {
        if let id = imageProviderID, let matched = providers.first(where: { $0.id == id }) {
            return matched
        }
        return providers.first { $0.supportsImage }
    }

    /// 是否已配置好（默认对话服务商存在且填了 baseURL / 模型）。
    public var isChatReady: Bool {
        guard let provider = defaultProvider else { return false }
        return provider.isChatConfigured
    }

    /// 是否已配置好生图（存在可生图的服务商）。
    public var isImageReady: Bool {
        imageProvider?.isImageConfigured ?? false
    }

    /// 按 id 查找服务商。
    public func provider(id: String) -> AIProviderConfig? {
        providers.first { $0.id == id }
    }
}
