//
//  ChatResult.swift
//  ios/Shared/Models
//
//  模块职责：一次性（非流式）对话的完整结果，以及 token 用量统计。
//  依赖：仅 Foundation。
//  使用方：Networking（LLMClient.complete 的返回值）、UI（结果卡片与用量展示）。
//

import Foundation

/// 一次接口调用返回的 token 用量。
public struct TokenUsage: Codable, Equatable, Sendable {
    /// 输入（prompt）token 数。
    public var promptTokens: Int
    /// 输出（completion）token 数。
    public var completionTokens: Int
    /// 总 token 数；为 0 时按前两者相加兜底。
    public var totalTokens: Int

    /// 成员初始化，全部默认 0。
    public init(promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    /// 容错解码：任何字段缺失都按 0 处理。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.promptTokens = (try? container.decodeIfPresent(Int.self, forKey: .promptTokens)) ?? 0
        self.completionTokens = (try? container.decodeIfPresent(Int.self, forKey: .completionTokens)) ?? 0
        let decodedTotal = (try? container.decodeIfPresent(Int.self, forKey: .totalTokens)) ?? 0
        self.totalTokens = decodedTotal > 0 ? decodedTotal : promptTokens + completionTokens
    }

    /// 是否没有任何用量信息（部分服务端不返回 usage）。
    public var isEmpty: Bool {
        promptTokens == 0 && completionTokens == 0 && totalTokens == 0
    }
}

/// 一次性对话结果。
public struct ChatResult: Sendable {
    /// 完整回复文本（已做首尾空白裁剪）。
    public var text: String
    /// token 用量；服务端未返回时为 nil。
    public var usage: TokenUsage?
    /// 结束原因，例如 `stop`、`length`、`content_filter`。
    public var finishReason: String?

    /// 成员初始化。
    public init(text: String, usage: TokenUsage? = nil, finishReason: String? = nil) {
        self.text = text
        self.usage = usage
        self.finishReason = finishReason
    }

    /// 回复是否为空（用于判定 `contentRejected`）。
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
