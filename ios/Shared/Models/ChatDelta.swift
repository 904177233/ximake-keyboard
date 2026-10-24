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
    /// 本段新增文本（可能为空串，表示仅携带结束标记）。
    public var text: String
    /// 是否为最后一片（`[DONE]` / `message_stop` 或 finish_reason 已到达）。
    public var isFinal: Bool

    /// 成员初始化。
    public init(text: String, isFinal: Bool = false) {
        self.text = text
        self.isFinal = isFinal
    }

    /// 一个只带结束标记的空增量。
    public static let done = ChatDelta(text: "", isFinal: true)
}
