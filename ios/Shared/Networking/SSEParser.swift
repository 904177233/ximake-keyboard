//
//  SSEParser.swift
//  ios/Shared/Networking
//
//  模块职责：把任意切分的 SSE 字节流增量解析成 `SSEEvent`，正确处理跨 chunk 的半行、
//            `\r\n` 与 `\n` 两种换行、`event:` / `data:` / `id:` / `retry:` 字段、
//            多行 data 拼接、注释行（以 `:` 开头）以及 `[DONE]` 结束标记。
//  依赖：仅 Foundation。
//  使用方：OpenAICompatibleClient / AnthropicClient / GeminiClient（三者共用同一解析器）。
//

import Foundation

/// 一个解析完成的 SSE 事件。
public struct SSEEvent: Equatable, Sendable {
    /// 事件名（`event:` 字段），OpenAI 兼容接口通常为空，Anthropic 有 `message_stop` 等。
    public var event: String?
    /// 数据体（多行 `data:` 用 `\n` 拼接）。
    public var data: String
    /// 事件 id（`id:` 字段），大多服务端不返回。
    public var id: String?
    /// 重连间隔（`retry:` 字段），本 App 不使用。
    public var retry: Int?

    /// 成员初始化。
    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }

    /// 是否为流结束标记（`data: [DONE]`）。
    public var isDone: Bool {
        data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]"
    }

    /// 数据体是否为 JSON（用于跳过心跳与空行）。
    public var isJSONPayload: Bool {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }
}

/// 增量 SSE 解析器。
///
/// 典型用法：
/// ```swift
/// var parser = SSEParser()
/// for try await chunk in session.bytes(for: request) {
///     for event in parser.feed(chunk) { handle(event) }
/// }
/// for event in parser.flush() { handle(event) }
/// ```
///
/// 实现要点：
/// - 内部用字节缓冲处理半个行/半个事件；多字节 UTF-8 字符被 chunk 切断也不会乱码
///   （换行字节 0x0A/0x0D 永远不会出现在 UTF-8 多字节序列中间，所以"先切行再解码"是安全的）；
/// - 按 SSE 规范在空行处派发事件；流结束时未收到尾部空行的，需调用 `flush()` 补偿；
/// - `\r\n`、单独的 `\r`、`\n` 都能识别；注释行（`:` 开头）与未知字段静默忽略。
public struct SSEParser {
    /// 未处理完的字节缓冲。
    private var buffer: [UInt8] = []
    /// 当前正在累积的字段。
    private var currentEvent: String?
    private var currentDataLines: [String] = []
    private var currentID: String?
    private var currentRetry: Int?
    /// 是否已经开始累积某个事件。
    private var hasPendingEvent: Bool {
        !currentDataLines.isEmpty || currentEvent != nil
    }

    /// 创建一个解析器。
    public init() {}

    /// 喂入一段字节，返回本次能完整解析出的事件数组（可能为空）。
    @discardableResult
    public mutating func feed(_ data: Data) -> [SSEEvent] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)
        var events: [SSEEvent] = []
        while let endOffset = nextLineEndOffset() {
            let lineBytes = Array(buffer[0..<endOffset])
            buffer.removeFirst(endOffset)
            let line = SSEParser.decodeLine(lineBytes)
            if line.isEmpty {
                // 空行 = 事件边界，派发。
                if let event = dispatchEvent() {
                    events.append(event)
                }
                continue
            }
            if line.hasPrefix(":") {
                // 注释行（常用于 keep-alive），直接忽略。
                continue
            }
            parseField(line)
        }
        return events
    }

    /// 流结束时调用：把残留的半行与未派发的事件冲刷出来。
    public mutating func flush() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            let line = SSEParser.decodeLine(buffer)
            buffer.removeAll(keepingCapacity: false)
            if !line.isEmpty && !line.hasPrefix(":") {
                parseField(line)
            }
        }
        if let event = dispatchEvent() {
            events.append(event)
        }
        return events
    }

    /// 重置解析器状态（复用于下一次请求）。
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        currentEvent = nil
        currentDataLines.removeAll(keepingCapacity: false)
        currentID = nil
        currentRetry = nil
    }

    // MARK: - 内部实现

    /// 找到 buffer 中第一个换行的结束偏移（返回的偏移是"该行含换行符"之后的位置）。
    ///
    /// 若遇到位于缓冲末尾的单独 `\r`（可能下一个 chunk 补 `\n`），保守等待，返回 nil。
    private func nextLineEndOffset() -> Int? {
        var index = 0
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0A { // \n
                return index + 1
            }
            if byte == 0x0D { // \r
                let nextIndex = index + 1
                if nextIndex < buffer.count, buffer[nextIndex] == 0x0A {
                    return nextIndex + 1
                }
                if nextIndex == buffer.count {
                    // \r 在缓冲末尾，等下一个 chunk 再判断是不是 \r\n。
                    return nil
                }
                return nextIndex
            }
            index += 1
        }
        return nil
    }

    /// 把一行字节解码成字符串并去掉行尾换行符（含 `\r`）。
    ///
    /// 非法 UTF-8 时用替换字符兜底（不让整条流失败）。
    private static func decodeLine(_ bytes: [UInt8]) -> String {
        var data = Data(bytes)
        // 去掉行尾 \n / \r\n / \r。
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解析一行 `field: value`。
    private mutating func parseField(_ line: String) {
        let field: String
        var value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colonIndex])
            var remainder = String(line[line.index(after: colonIndex)...])
            // 规范：冒号后仅去掉一个空格。
            if remainder.hasPrefix(" ") {
                remainder.removeFirst()
            }
            value = remainder
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            currentEvent = value
        case "data":
            currentDataLines.append(value)
        case "id":
            currentID = value
        case "retry":
            currentRetry = Int(value)
        default:
            // 未知字段按规范忽略。
            break
        }
    }

    /// 把当前累积的字段组装成事件并清空状态。
    private mutating func dispatchEvent() -> SSEEvent? {
        guard hasPendingEvent else { return nil }
        let data = currentDataLines.joined(separator: "\n")
        let event = SSEEvent(event: currentEvent, data: data, id: currentID, retry: currentRetry)
        currentEvent = nil
        currentDataLines.removeAll(keepingCapacity: true)
        currentID = nil
        currentRetry = nil
        // 既无 data 又无 event 的空事件不派发。
        if event.data.isEmpty && event.event == nil {
            return nil
        }
        return event
    }
}
