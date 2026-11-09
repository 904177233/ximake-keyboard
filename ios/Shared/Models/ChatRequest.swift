//
//  ChatRequest.swift
//  ios/Shared/Models
//
//  一次文本对话请求的参数载体（消息列表 + 采样参数 + 是否流式）。
//

import Foundation

/// 要不要让模型先想一想。各家参数不一样，由客户端翻译；不支持的服务会报 400，调用方去掉重发。
public enum ReasoningLevel: String, Codable, Sendable, CaseIterable {
    /// 不想，直接答。
    case fast
    /// 先想再答。
    case deep
}

/// 一次文本对话请求。
public struct ChatRequest: Sendable {
    /// 完整消息列表，按时间顺序排列，`system` 通常在最前。
    public var messages: [ChatMessage]
    /// 采样温度；nil 表示沿用 Provider 配置。
    public var temperature: Double?
    /// 最大回复 token 数；nil 表示沿用 Provider 配置。
    public var maxTokens: Int?
    /// 是否流式（SSE）。键盘内使用流式以降低首字延迟。
    public var stream: Bool
    /// 推理强度；nil 表示不指定，用服务商默认。
    public var reasoning: ReasoningLevel?

    /// 成员初始化。
    public init(
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = true,
        reasoning: ReasoningLevel? = nil
    ) {
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.reasoning = reasoning
    }

    /// 该请求里第一条 system 消息的文本（Anthropic / Gemini 需要把 system 拆出来单独传）。
    public var systemPrompt: String? {
        for message in messages where message.role == .system {
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return message.content
            }
        }
        return nil
    }

    /// 去掉 system 消息后的对话消息（Anthropic / Gemini 用）。
    public var conversationMessages: [ChatMessage] {
        messages.filter { $0.role != .system }
    }

    /// 合并所有消息的纯文本（用于估算 token 与降级展示）。
    public var concatenatedText: String {
        messages.map(\.content).joined(separator: "\n")
    }
}
