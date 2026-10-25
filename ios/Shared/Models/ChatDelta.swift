//
//  ChatDelta.swift
//  ios/Shared/Models
//
//  模块职责：流式对话的单个增量事件（一段新增文本 + 是否结束）。
//  依赖：仅 Foundation。
//  使用方：Networking（SSE 解析后逐条 yield）、键盘扩展（追加到结果卡片做打字机效果）。
//

import Foundation

/// 流式对话的一次增量。
public struct ChatDelta: Sendable {
    /// 本段新增文本（可能为空串，表示仅携带结束标记，或只携带思维链）。
    public var text: String
    /// 是否为最后一片（`[DONE]` / `message_stop` 或 finish_reason 已到达）。
    public var isFinal: Bool
    /// 本段新增的**思维链**（推理模型的 `reasoning_content`）；`nil` 表示这一片没有思维链。
    ///
    /// 推理模型（`deepseek-reasoner` / o1 / o3 / QwQ 等）会先长时间只吐思维链，
    /// 之后才吐正文。思维链**单独走这个通道**，不拼进 `text`：既不会污染用户
    /// 看到的正文，也不会像以前那样被直接丢掉（丢掉的结果是正文为空、用户只看到
    /// 「服务商没有返回内容」）。UI 可以选择展示成「思考中…」或完全忽略。
    public let reasoning: String?

    /// 成员初始化。
    ///
    /// - Parameters:
    ///   - text: 本段正文（可能为空串）。
    ///   - isFinal: 是否为最后一片，默认 `false`。
    ///   - reasoning: 本段思维链，默认 `nil`（非推理模型、或这一片没有思维链）。
    public init(text: String, isFinal: Bool = false, reasoning: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.reasoning = reasoning
    }

    /// 一个只带结束标记的空增量。
    public static let done = ChatDelta(text: "", isFinal: true)
}
