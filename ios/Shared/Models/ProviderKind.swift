//
//  ProviderKind.swift
//  ios/Shared/Models
//
//  模块职责：声明 AI 服务商的协议类型（决定走哪个网络客户端 / 哪种请求响应格式），
//            并提供给 UI 直接使用的中文显示名与 SF Symbol。
//  依赖：仅 Foundation（本文件不 import UIKit/SwiftUI）。
//  使用方：Networking（AIClientFactory / ImageClientRouter）、Storage（ConfigSnapshot）、
//          Models（AIProviderConfig / PresetProviders）、宿主 App 的 ProviderEditorView、
//          键盘扩展内的设置 Sheet。
//

import Foundation

/// AI 服务商的协议类型。
///
/// 设计说明：生图服务（即梦 / 通义万相）不单独占用枚举值，统一归入 `.custom`，
/// 由 `ImageClientRouter` 依据 `baseURL` 与模型名做二次路由。这样其他模块对
/// `ProviderKind` 写穷尽 `switch` 时不会因新增 case 而编译失败，老快照也能安全解码。
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    /// OpenAI 兼容协议（`/v1/chat/completions`）。覆盖绝大多数国内服务商与中转站。
    case openAICompatible
    /// Anthropic Messages 协议（`/v1/messages`）。
    case anthropic
    /// Google Gemini 协议（`/v1beta/models/{model}:streamGenerateContent`），标记为实验性。
    case gemini
    /// 自定义 / 中转站 / 生图专用服务，按 baseURL 与模型名路由。
    case custom

    /// 中文显示名（用于 Provider 列表与编辑器）。
    public var title: String {
        switch self {
        case .openAICompatible:
            return "OpenAI 兼容"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Google Gemini"
        case .custom:
            return "自定义 / 中转站"
        }
    }

    /// 一句话说明（用于新手引导与空态提示）。
    public var subtitle: String {
        switch self {
        case .openAICompatible:
            return "填 baseURL + API Key + 模型名即可，DeepSeek / 通义 / Kimi / GLM / 火山都属此类"
        case .anthropic:
            return "Anthropic 官方 Messages 接口，需要 x-api-key"
        case .gemini:
            return "Google AI Studio 的 Gemini 接口（实验性）"
        case .custom:
            return "中转站、生图服务（即梦 / 通义万相）或其它私有网关"
        }
    }

    /// 列表行使用的 SF Symbol 名称（iOS 16 已有）。
    public var systemImage: String {
        switch self {
        case .openAICompatible:
            return "bolt.horizontal.circle"
        case .anthropic:
            return "a.circle"
        case .gemini:
            return "sparkle"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    /// 该协议是否走 OpenAI 兼容的 `/v1/chat/completions`。
    public var isOpenAICompatible: Bool {
        switch self {
        case .openAICompatible, .custom:
            return true
        case .anthropic, .gemini:
            return false
        }
    }

    /// 容错解码：遇到未来版本新增、当前代码不认识的 kind 时回退到 `.openAICompatible`。
    public static func tolerant(rawValue: String?) -> ProviderKind {
        guard let rawValue, let kind = ProviderKind(rawValue: rawValue) else {
            return .openAICompatible
        }
        return kind
    }
}
