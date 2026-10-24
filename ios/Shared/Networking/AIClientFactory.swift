//
//  AIClientFactory.swift
//  ios/Shared/Networking
//
//  模块职责：根据 `AIProviderConfig.kind`（对话）或 baseURL/模型名（生图）创建对应客户端，
//            是 UI 与网络层之间唯一的入口，保证"换服务商不改 UI 代码"。
//  依赖：仅 Foundation + Models。
//  使用方：键盘扩展 AIService、宿主 App PlaygroundView / ImagePanelView / 设置页测试按钮。
//

import Foundation

/// AI 客户端工厂。
public enum AIClientFactory {

    /// 创建文本对话客户端。
    ///
    /// - Parameters:
    ///   - config: 服务商配置。
    ///   - apiKey: 从 Keychain 取出的明文 Key；为空时客户端会在首次请求前抛 `.missingAPIKey`。
    /// - Returns: 符合协议的具体客户端（`OpenAICompatibleClient` / `AnthropicClient` / `GeminiClient`）。
    public static func makeLLM(config: AIProviderConfig, apiKey: String) -> LLMClient {
        switch config.kind {
        case .openAICompatible, .custom:
            return OpenAICompatibleClient(config: config, apiKey: apiKey)
        case .anthropic:
            return AnthropicClient(config: config, apiKey: apiKey)
        case .gemini:
            return GeminiClient(config: config, apiKey: apiKey)
        }
    }

    /// 创建生图客户端。
    ///
    /// 路由规则（`ImageClientRouter`）：
    /// - baseURL 含 `ark.cn-beijing.volces.com` 或模型名含 `seedream` / `doubao` → 即梦（Seedream）
    /// - baseURL 含 `dashscope.aliyuncs.com` 或模型名含 `wanx` → 通义万相（异步任务）
    /// - 其余 → OpenAI 兼容 `{base}/images/generations`
    ///
    /// - Parameters:
    ///   - config: 生图服务商配置（`imageModel` 必须非空）。
    ///   - apiKey: Keychain 中的明文 Key。
    public static func makeImage(config: AIProviderConfig, apiKey: String) -> ImageGenerating {
        ImageClientRouter.makeClient(config: config, apiKey: apiKey)
    }
}
