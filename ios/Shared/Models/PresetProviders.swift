//
//  PresetProviders.swift
//  ios/Shared/Models
//
//  模块职责：内置 AI 服务商预设（国内常见 9 家 + 生图 2 家），提供名称/kind/baseURL/
//            默认 model/生图 model/申请 Key 的中文说明，供"一键添加"使用；
//            并对外提供 chatPresets() / imagePresets() 两个 [AIProviderConfig] 快捷工厂。
//  依赖：仅 Foundation、AIProviderConfig、ProviderKind。
//  使用方：宿主 App 的 ProviderListView / ProviderEditorView（添加服务商）、
//          Storage（ConfigSnapshot.defaultValue 用 DeepSeek 预设初始化）、
//          keyboard-ui / host-app-ui（选择默认对话 / 生图服务商时的候选列表）。
//

import Foundation

/// 内置服务商预设。
///
/// 使用方式：
/// ```swift
/// let candidates = PresetProviders.chatPresets()      // [AIProviderConfig]，可直接展示/落库
/// if let preset = PresetProviders.preset(id: "preset-seedream") {
///     var provider = preset.makeProvider()            // 生图预设
/// }
/// ```
public enum PresetProviders {

    /// 一条内置预设。除展示信息外还能直接生成可用的 `AIProviderConfig`。
    public struct Preset: Identifiable, Equatable, Sendable {
        /// 稳定 ID（跨设备、跨次启动一致，便于 `ConfigSnapshot.imageProviderID` 长期引用）。
        public var id: String
        /// 展示名称。
        public var name: String
        /// 协议类型。
        public var kind: ProviderKind
        /// 接口根地址。
        public var baseURL: String
        /// 默认文本模型（生图专用预设为空串）。
        public var model: String
        /// 生图模型（无生图能力时为空）。
        public var imageModel: String?
        /// 中文说明：去哪申请 Key、注意事项。
        public var note: String
        /// 官网 / 控制台地址（可选，UI 可做成 "去申请" 按钮）。
        public var consoleURL: URL?
        /// 是否为生图专用（只能用来生图，不能对话）。
        public var isImageOnly: Bool
        /// 可选模型列表（UI 下拉选择用）。
        public var availableModels: [ModelRef]

        /// 生成一份可编辑的 `AIProviderConfig` 副本（id 沿用预设 id，可被 UI 持久化）。
        public func makeProvider(isDefault: Bool = false) -> AIProviderConfig {
            AIProviderConfig(
                id: id,
                name: name,
                kind: kind,
                baseURL: baseURL,
                model: model,
                imageModel: imageModel,
                temperature: 0.7,
                maxTokens: 1024,
                timeout: 30,
                extraHeaders: [:],
                supportsVision: false,
                isDefault: isDefault
            )
        }
    }

    // MARK: - 生图专用判定（UI / Networking 共用，避免各模块自己复制映射表）

    /// 生图专用预设的稳定 ID 集合。
    public static let imageOnlyPresetIDs: Set<String> = ["preset-seedream", "preset-wanx"]

    /// 该 id 是否指向"仅支持生图"的服务。
    ///
    /// 判定规则（满足任一即为 true）：
    /// 1. id 命中内置生图预设集合（`preset-seedream` / `preset-wanx`）；
    /// 2. id 命中某个内置预设，且该预设"有 imageModel 但没有对话 model"。
    ///
    /// 用户自定义的条目（UUID id）不在此判定内——那种情形由
    /// `AIProviderConfig.supportsChat` 依据 baseURL / 模型名判断。
    public static func isImageOnly(id: String) -> Bool {
        if imageOnlyPresetIDs.contains(id) {
            return true
        }
        guard let matched = preset(id: id) else {
            return false
        }
        return matched.imageModel != nil && matched.model.isEmpty
    }

    // MARK: - 全部预设（模板）

    /// 9 家文本对话服务商模板（顺序即 UI 推荐顺序，DeepSeek 排第一因为默认推荐）。
    public static let chatPresetTemplates: [Preset] = [
        Preset(
            id: "preset-deepseek",
            name: "DeepSeek 深度求索",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            imageModel: nil,
            note: "在 platform.deepseek.com 注册后于「API keys」创建，价格低、中文好，默认推荐。",
            consoleURL: URL(string: "https://platform.deepseek.com/api_keys"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "DeepSeek Chat（通用）", modelID: "deepseek-chat"),
                ModelRef(title: "DeepSeek Reasoner（推理）", modelID: "deepseek-reasoner")
            ]
        ),
        Preset(
            id: "preset-qwen",
            name: "通义千问 · 阿里云百炼",
            kind: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus",
            imageModel: nil,
            note: "在阿里云百炼控制台（bailian.console.aliyun.com）开通后创建 DashScope API Key；这里用的是它的 OpenAI 兼容模式地址。",
            consoleURL: URL(string: "https://bailian.console.aliyun.com/"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "qwen-plus（均衡）", modelID: "qwen-plus"),
                ModelRef(title: "qwen-turbo（快速便宜）", modelID: "qwen-turbo"),
                ModelRef(title: "qwen-max（最强）", modelID: "qwen-max")
            ]
        ),
        Preset(
            id: "preset-kimi",
            name: "Kimi · 月之暗面",
            kind: .openAICompatible,
            baseURL: "https://api.moonshot.cn/v1",
            model: "moonshot-v1-8k",
            imageModel: nil,
            note: "在 platform.moonshot.cn 的「API Key 管理」创建，新账号有体验额度。",
            consoleURL: URL(string: "https://platform.moonshot.cn/console/api-keys"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "moonshot-v1-8k", modelID: "moonshot-v1-8k"),
                ModelRef(title: "moonshot-v1-32k", modelID: "moonshot-v1-32k"),
                ModelRef(title: "moonshot-v1-128k", modelID: "moonshot-v1-128k")
            ]
        ),
        Preset(
            id: "preset-glm",
            name: "智谱 GLM",
            kind: .openAICompatible,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            model: "glm-4-flash",
            imageModel: nil,
            note: "在 open.bigmodel.cn 的「API Keys」创建；glm-4-flash 有免费额度，适合先跑通。",
            consoleURL: URL(string: "https://open.bigmodel.cn/usercenter/apikeys"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "glm-4-flash（免费额度）", modelID: "glm-4-flash"),
                ModelRef(title: "glm-4-plus", modelID: "glm-4-plus"),
                ModelRef(title: "glm-4-air", modelID: "glm-4-air")
            ]
        ),
        Preset(
            id: "preset-ark",
            name: "火山方舟 · 豆包",
            kind: .openAICompatible,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            model: "doubao-1-5-pro-32k",
            imageModel: "doubao-seedream-3-0-t2i-250415",
            note: "在火山引擎控制台开通「方舟」，创建推理接入点 / API Key；豆包模型名也可填接入点 ID（ep-xxx）。生图走即梦（Seedream）。",
            consoleURL: URL(string: "https://console.volcengine.com/ark"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "doubao-1-5-pro-32k", modelID: "doubao-1-5-pro-32k"),
                ModelRef(title: "doubao-1-5-lite-32k", modelID: "doubao-1-5-lite-32k")
            ]
        ),
        Preset(
            id: "preset-openrouter",
            name: "OpenRouter",
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            model: "openai/gpt-4o-mini",
            imageModel: nil,
            note: "在 openrouter.ai/keys 创建 Key，可一个 Key 调多家模型（模型名要带厂商前缀，如 anthropic/claude-3.5-sonnet）。国内网络可能需自备代理。",
            consoleURL: URL(string: "https://openrouter.ai/keys"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "openai/gpt-4o-mini", modelID: "openai/gpt-4o-mini"),
                ModelRef(title: "anthropic/claude-3.5-sonnet", modelID: "anthropic/claude-3.5-sonnet"),
                ModelRef(title: "google/gemini-flash-1.5", modelID: "google/gemini-flash-1.5")
            ]
        ),
        Preset(
            id: "preset-siliconflow",
            name: "硅基流动 SiliconFlow",
            kind: .openAICompatible,
            baseURL: "https://api.siliconflow.cn/v1",
            model: "Qwen/Qwen2.5-7B-Instruct",
            imageModel: nil,
            note: "在 cloud.siliconflow.cn 的「API 密钥」创建，聚合了大量开源模型，新账号有赠送额度。",
            consoleURL: URL(string: "https://cloud.siliconflow.cn/account/ak"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "Qwen/Qwen2.5-7B-Instruct", modelID: "Qwen/Qwen2.5-7B-Instruct"),
                ModelRef(title: "deepseek-ai/DeepSeek-V3", modelID: "deepseek-ai/DeepSeek-V3")
            ]
        ),
        Preset(
            id: "preset-openai",
            name: "OpenAI",
            kind: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini",
            imageModel: "gpt-image-1",
            note: "在 platform.openai.com/api-keys 创建；国内直连不稳定，通常需要自备网络环境或中转站。",
            consoleURL: URL(string: "https://platform.openai.com/api-keys"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "gpt-4o-mini", modelID: "gpt-4o-mini"),
                ModelRef(title: "gpt-4o", modelID: "gpt-4o", supportsVision: true)
            ]
        ),
        Preset(
            id: "preset-anthropic",
            name: "Anthropic Claude",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com",
            model: "claude-3-5-sonnet-latest",
            imageModel: nil,
            note: "在 console.anthropic.com 的「API Keys」创建；baseURL 不要带 /v1，客户端会自动拼 /v1/messages。",
            consoleURL: URL(string: "https://console.anthropic.com/settings/keys"),
            isImageOnly: false,
            availableModels: [
                ModelRef(title: "claude-3-5-sonnet-latest", modelID: "claude-3-5-sonnet-latest"),
                ModelRef(title: "claude-3-5-haiku-latest", modelID: "claude-3-5-haiku-latest")
            ]
        )
    ]

    /// 生图专用预设模板（走 ImageClientRouter，不参与文本对话）。
    public static let imagePresetTemplates: [Preset] = [
        Preset(
            id: "preset-seedream",
            name: "即梦 · 火山方舟",
            kind: .custom,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            model: "",
            imageModel: "doubao-seedream-3-0-t2i-250415",
            note: "在火山引擎控制台开通方舟并创建推理接入点 / API Key（与豆包对话共用同一个 Key）。备选模型 doubao-seedream-4-0-250828 更强但更贵。",
            consoleURL: URL(string: "https://console.volcengine.com/ark"),
            isImageOnly: true,
            availableModels: [
                ModelRef(title: "Seedream 3.0（默认）", modelID: "doubao-seedream-3-0-t2i-250415"),
                ModelRef(title: "Seedream 4.0（更强）", modelID: "doubao-seedream-4-0-250828")
            ]
        ),
        Preset(
            id: "preset-wanx",
            name: "通义万相 · DashScope",
            kind: .custom,
            baseURL: "https://dashscope.aliyuncs.com",
            model: "",
            imageModel: "wanx2.1-t2i-turbo",
            note: "在阿里云百炼控制台申请 DashScope API Key（与通义千问共用一个 Key）。图片链接有效期约 24 小时，本 App 会立刻下载到本地。",
            consoleURL: URL(string: "https://bailian.console.aliyun.com/"),
            isImageOnly: true,
            availableModels: [
                ModelRef(title: "wanx2.1-t2i-turbo（快）", modelID: "wanx2.1-t2i-turbo"),
                ModelRef(title: "wanx2.1-t2i-plus（精细）", modelID: "wanx2.1-t2i-plus")
            ]
        )
    ]

    /// 全部预设模板（对话 9 家 + 生图 2 家）。
    public static var all: [Preset] {
        chatPresetTemplates + imagePresetTemplates
    }

    // MARK: - 常用模型（设置页「模型」输入框的候选）

    /// 某个协议类型下已知可用的模型名（供设置页做「常用模型」快捷选择，仍允许用户自由输入）。
    ///
    /// 注意：`ProviderKind` 只区分**协议**、不区分厂商 —— DeepSeek / 通义千问 / Kimi /
    /// 智谱 GLM / 火山方舟 / OpenRouter / OpenAI 全都走 `.openAICompatible`。
    /// 因此 `.openAICompatible` 返回的是「所有厂商的并集」（去重、顺序固定）；
    /// 想按厂商给精确清单，请用 `knownModels(forBaseURL:)`（设置页拿到的是用户填的
    /// baseURL，用它更准）；认不出厂商时返回空数组，UI 退化成纯自由输入即可。
    ///
    /// - Parameter kind: 协议类型。
    /// - Returns: 模型名列表；未知协议返回空数组。
    public static func knownModels(for kind: ProviderKind) -> [String] {
        switch kind {
        case .openAICompatible:
            var seen = Set<String>()
            return chatVendorModels.flatMap { $0 }.filter { seen.insert($0).inserted }
        case .anthropic, .gemini, .custom:
            return []
        }
    }

    /// 按 baseURL 的域名推断厂商，返回该厂商已知可用的模型名。
    ///
    /// 只收录**确认存在**的模型名（宁可少写，也不给用户一个点一下就 404 的候选）。
    /// 用户仍然可以手输任意模型名（例如刚发布的版本），这里只是候选。
    ///
    /// - Parameter baseURL: 服务商根地址，如 `https://api.deepseek.com/v1`。
    /// - Returns: 该厂商的常用模型名；认不出厂商时返回空数组。
    public static func knownModels(forBaseURL baseURL: String) -> [String] {
        let lower = baseURL.lowercased()
        if lower.contains("deepseek") {
            return deepSeekModels
        }
        if lower.contains("dashscope") || lower.contains("aliyuncs") {
            return qwenModels
        }
        if lower.contains("moonshot") || lower.contains("kimi") {
            return kimiModels
        }
        if lower.contains("bigmodel") || lower.contains("zhipu") {
            return glmModels
        }
        if lower.contains("openrouter") {
            return openRouterModels
        }
        if lower.contains("api.openai.com") {
            return openAIModels
        }
        return []
    }

    /// DeepSeek（官方 OpenAI 兼容端点）。
    private static let deepSeekModels = ["deepseek-chat", "deepseek-reasoner"]

    /// OpenAI 官方。
    private static let openAIModels = ["gpt-4o-mini", "gpt-4o", "o3-mini"]

    /// 通义千问（DashScope 兼容模式）。
    private static let qwenModels = ["qwen-plus", "qwen-max", "qwen-turbo", "qvq-max"]

    /// Kimi（Moonshot）。
    private static let kimiModels = ["kimi-latest", "moonshot-v1-8k"]

    /// 智谱 GLM。
    private static let glmModels = ["glm-4-plus", "glm-4-flash", "glm-z1-air"]

    /// OpenRouter（模型名带 `厂商/` 前缀）。
    private static let openRouterModels = [
        "openai/gpt-4o-mini",
        "anthropic/claude-sonnet-4",
        "deepseek/deepseek-chat"
    ]

    /// 各厂商模型表的合集，供 `.openAICompatible`（不分厂商）取并集。
    private static let chatVendorModels: [[String]] = [
        deepSeekModels,
        openAIModels,
        qwenModels,
        kimiModels,
        glmModels,
        openRouterModels
    ]

    // MARK: - 快捷工厂（UI 直接用）

    /// 全部**可对话**预设转成的 `[AIProviderConfig]`（每次调用返回新副本，可直接编辑）。
    public static func chatPresets() -> [AIProviderConfig] {
        chatPresetTemplates.map { $0.makeProvider() }
    }

    /// 全部**生图**预设转成的 `[AIProviderConfig]`（id 为 preset-seedream / preset-wanx）。
    public static func imagePresets() -> [AIProviderConfig] {
        imagePresetTemplates.map { $0.makeProvider() }
    }

    /// 全部预设转成的 `[AIProviderConfig]`（对话 + 生图）。
    public static func allPresets() -> [AIProviderConfig] {
        chatPresets() + imagePresets()
    }

    // MARK: - 查找

    /// 按 ID 查找预设模板（含生图预设）。
    public static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }

    /// 默认推荐的服务商（DeepSeek）。
    public static var recommended: Preset? {
        preset(id: "preset-deepseek")
    }

    /// 默认生图服务商（即梦 / Seedream）。
    public static var defaultImagePreset: Preset? {
        preset(id: "preset-seedream")
    }
}
