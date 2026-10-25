//
//  OpenAICompatibleClient+LenientParse.swift
//  墨语 · Shared/Networking
//
//  「宽松解析」：应对**不守 SSE 规范的中转站 / 网关**。
//
//  背景（v2.5 的实测证据）：
//  请求里写了 `stream: false`，但部分网关无视该字段，仍按流式回
//  `object: "chat.completion.chunk"` 的分片。而上游真正回给我们的报文
//  **根本不符合 SSE 规范** —— 实测样本里同时出现三个问题：
//
//      data：{"id":"…","object":"chat.completion.chunk","choices":[{"delta":{"content":"你"}}]}
//      ^^^^                                                                                  ^^^
//      ① 全角冒号            ② 分片之间没有空行（不按空行分派事件）    ③ 多个对象首尾相连
//
//  标准 `SSEParser` 依赖「空行分派事件」，遇到这种报文会把全部分片攒成
//  一个巨大事件，`JSONSerialization` 直接失败 —— 用户看到的就是
//  「服务商返回了 200，但没有解析出任何正文」。v2.4 曾先按 `SSEParser` 拼过一次，
//  真机仍是 200 无正文，因此 v2.5 彻底放弃 SSE 语义。
//
//  现在的做法只有一个：**按花括号深度把原文里所有平衡的 JSON 对象抠出来**，
//  逐个解析取 `choices`。这样无论网关怎么拼（有无 `data:`、有无空行、
//  全角/半角冒号、一行一个还是全挤在一起、甚至整段就是一个 chunk 对象）都能还原正文。
//
//  单独成文件的原因：主文件 `OpenAICompatibleClient.swift` 已接近 600 行上限，
//  而这一段是纯字符串处理、与网络逻辑无关，拆开后两边都更容易读。
//

import Foundation

extension OpenAICompatibleClient {

    /// 把「本该是非流式、实际被网关按流式回了」的响应体拼成一次完整回复。
    ///
    /// - Parameter data: 完整响应体（可能是一整段普通 JSON，也可能是掺杂 `data:` 的分片）。
    /// - Returns: 拼好的 `ChatResult`；**一个可用对象都没找到**、或拼出来正文为空时返回 `nil`，
    ///   交回调用方走原有 JSON 分支与统一的空正文判定（普通 JSON 的行为完全不变）。
    static func parseSSEBodyAsCompletion(_ data: Data) -> ChatResult? {
        let plain = String(decoding: data, as: UTF8.self)
        let lowered = plain.lowercased()
        // 快速排除：既没有 `data` 字样、也不是 chat chunk 的，基本就是普通 JSON。
        guard lowered.contains("data") || lowered.contains("chat.completion.chunk") else { return nil }

        let objects = extractJSONObjects(from: plain)
        guard !objects.isEmpty else { return nil }

        var text = ""
        var reasoning = ""
        var finishReason: String?
        var usage: TokenUsage?
        var sawAnyChoice = false

        for object in objects {
            guard let jsonData = object.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            if let usageDictionary = root["usage"] as? [String: Any] {
                usage = OpenAICompatibleClient.parseUsage(usageDictionary)
            }
            guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
                continue
            }
            sawAnyChoice = true
            // 流式分片走 `delta`；个别网关会在流里塞 `message`；两种都收。
            let container = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any])
            if let content = container?["content"] as? String {
                text += content
            } else if let parts = container?["content"] as? [[String: Any]] {
                // 少数服务端把正文分段成 `[{"type":"text","text":"…"}]`。
                text += parts.compactMap { $0["text"] as? String }.joined()
            }
            if let chain = container?["reasoning_content"] as? String {
                reasoning += chain
            }
            if let reason = first["finish_reason"] as? String, !reason.isEmpty {
                finishReason = reason
            }
        }

        // 一个 choices 都没解析出来 → 不是流式分片，交回原路径报「非合法 JSON」。
        guard sawAnyChoice else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正文为空时返回 `nil`：交给 `parseCompletion` 里已有的空正文判定，
        // 由它统一区分「只有思维链 / 被长度截断 / 真空响应」，避免两处文案分叉。
        // `reasoning` 仍被读取，是为了将来需要时能在这里区分，但当前不参与判定。
        _ = reasoning
        guard !trimmed.isEmpty else { return nil }
        return ChatResult(text: trimmed, usage: usage, finishReason: finishReason)
    }

    /// 从任意文本里按**花括号深度**抠出所有平衡的 JSON 对象字符串。
    ///
    /// 只在字符串字面量之外计深度，因此正文里出现 `{` / `}`（例如模型回答里的代码）
    /// 不会把括号算乱；`\"` 转义也能正确跳过。逐个 `Character` 遍历，
    /// 多字节字符与 emoji 不会被切半。
    ///
    /// - Parameter text: 原始响应体。
    /// - Returns: 按出现顺序排列的 JSON 对象文本（不含外层 `data:` 之类前缀）。
    static func extractJSONObjects(from text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    // 只有已经进入某个对象内部时，引号才表示字符串开始；
                    // 否则把对象之间的裸引号误判成字符串会吞掉后面的 `{`。
                    if depth > 0 { inString = true }
                case "{":
                    if depth == 0 { start = index }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let began = start {
                            results.append(String(text[began...index]))
                            start = nil
                        }
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return results
    }
}
