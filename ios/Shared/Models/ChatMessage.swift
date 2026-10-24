//
//  ChatMessage.swift
//  ios/Shared/Models
//
//  模块职责：对话消息的最小数据单元（角色 + 文本），是 Prompt 渲染与网络请求的共同货币。
//  依赖：仅 Foundation。
//  使用方：Prompts（PromptLibrary.render 产出 [ChatMessage]）、Networking（三个客户端把
//          [ChatMessage] 映射为各自协议的 JSON）、UI（PlaygroundView 展示对话）。
//

import Foundation

/// 一条对话消息。
public struct ChatMessage: Codable, Hashable, Sendable {
    /// 消息角色。
    public enum Role: String, Codable, Sendable {
        /// 系统提示（人设、输出约束）。
        case system
        /// 用户输入。
        case user
        /// 模型回复（多轮上下文时使用）。
        case assistant
    }

    /// 角色。
    public var role: Role
    /// 纯文本内容。
    public var content: String

    /// 成员初始化。
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// 容错解码（缺字段时为空串 / user）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawRole = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? nil
        self.role = rawRole.flatMap(Role.init(rawValue:)) ?? .user
        self.content = (try? container.decodeIfPresent(String.self, forKey: .content)) ?? ""
    }

    /// 构造一条 system 消息。
    public static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }

    /// 构造一条 user 消息。
    public static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    /// 构造一条 assistant 消息。
    public static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }
}
