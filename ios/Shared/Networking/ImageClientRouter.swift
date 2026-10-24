//
//  ImageClientRouter.swift
//  ios/Shared/Networking
//
//  模块职责：生图客户端路由。按 `baseURL` 与 `imageModel` 判断该用哪家生图协议，
//            返回统一的 `ImageGenerating`。这是"不新增 ProviderKind 枚举值"决策的落点。
//  依赖：Foundation、Models、AIError。
//  使用方：AIClientFactory.makeImage(config:apiKey:)。
//
//  设计决策（见 ios/Shared/Networking/README.md「设计决策」）：
//  即梦（Seedream/Ark）与通义万相（DashScope）的请求体与协议都与标准 OpenAI 生图不同，
//  因此需要独立的客户端实现；但**不新增 `ProviderKind` 枚举值**——其他 agent 的 UI 代码里
//  存在对 `ProviderKind` 的穷尽 switch，新增 case 会让它们编译失败。改用 `.custom` + 本路由。
//

import Foundation

/// 生图客户端路由。
public enum ImageClientRouter {

    /// 生图协议类型（公开给设置页展示与自检；不参与持久化，不进入 Codable）。
    public enum Route: Equatable, Sendable {
        /// 即梦 · 火山方舟（Ark OpenAI 兼容同步接口）。
        case seedream
        /// 通义万相（DashScope 异步任务接口）。
        case wanx
        /// 标准 OpenAI 兼容 `/images/generations`。
        case openAICompatible
    }

    /// 按配置创建生图客户端。
    ///
    /// 路由规则（按顺序匹配，先命中先返回）：
    /// 1. `baseURL` 含 `ark.cn-beijing.volces.com`，或 `imageModel`/`model` 含 `seedream`/`doubao` → `SeedreamImageClient`
    /// 2. `baseURL` 含 `dashscope.aliyuncs.com`，或 `imageModel`/`model` 含 `wanx` → `WanxImageClient`
    /// 3. 其余 → `OpenAICompatibleImageClient`
    ///
    /// - Parameters:
    ///   - config: 生图服务商配置（`imageModel` 非空才会真正发请求）。
    ///   - apiKey: 明文 API Key。
    ///   - session: 可注入的 URLSession（测试用）。
    ///   - path: 自定义生图接口路径，仅对 OpenAI 兼容分支生效。
    public static func makeClient(
        config: AIProviderConfig,
        apiKey: String,
        session: URLSession? = nil,
        path: String? = nil
    ) -> ImageGenerating {
        switch route(for: config) {
        case .seedream:
            return SeedreamImageClient(config: config, apiKey: apiKey, session: session)
        case .wanx:
            return WanxImageClient(config: config, apiKey: apiKey, session: session)
        case .openAICompatible:
            return OpenAICompatibleImageClient(config: config, apiKey: apiKey, session: session, path: path)
        }
    }

    /// 判定路由类型（公开给设置页做「当前使用哪家生图协议」的展示与自检）。
    public static func route(for config: AIProviderConfig) -> Route {
        let baseURL = config.normalizedBaseURL.lowercased()
        let imageModel = (config.imageModel ?? "").lowercased()
        let chatModel = config.model.lowercased()

        // 即梦 / 火山方舟：baseURL 域名或模型名命中即可。
        if baseURL.contains("ark.cn-beijing.volces.com")
            || imageModel.contains("seedream")
            || imageModel.contains("doubao")
            || chatModel.contains("seedream") {
            return .seedream
        }
        // 通义万相：DashScope 域名（注意：千问对话用的是 .../compatible-mode/v1，这里只看生图模型是否命中）。
        if baseURL.contains("dashscope.aliyuncs.com")
            || imageModel.contains("wanx")
            || chatModel.contains("wanx") {
            return .wanx
        }
        return .openAICompatible
    }

    /// 当前路由对应的中文协议名，用于设置页展示。
    public static func routeDisplayName(for config: AIProviderConfig) -> String {
        switch route(for: config) {
        case .seedream:
            return "即梦（火山方舟）"
        case .wanx:
            return "通义万相（DashScope 异步任务）"
        case .openAICompatible:
            return "OpenAI 兼容生图"
        }
    }
}
