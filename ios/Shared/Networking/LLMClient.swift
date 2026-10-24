//
//  LLMClient.swift
//  ios/Shared/Networking
//
//  模块职责：定义文本对话与生图两类客户端的抽象协议（docs/02 §4.2 契约），
//            以及统一的工厂 `AIClientFactory`。
//  依赖：仅 Foundation + Models。
//  使用方：键盘扩展（AIService 调 stream）、宿主 App（Playground 调 complete、
//          设置页的"测试连接"按钮、生图面板调 generate）。
//

import Foundation

/// 文本对话客户端。
///
/// 两种调用方式：
/// - `stream(_:)`：流式，键盘内使用（先出字、可随时取消，节省扩展内存）；
/// - `complete(_:)`：一次性，宿主 App 的调试页与"测试连接"使用。
public protocol LLMClient: Sendable {
    /// 流式对话。返回的流在取消（`Task.cancel()`）时会尽快终止并关闭连接。
    ///
    /// 正常结束时最后一片为 `ChatDelta(text: "", isFinal: true)`；
    /// 出错时流会以 `AIError` 抛出。
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error>

    /// 一次性对话（内部通常复用流式实现后聚合，或直接发 `stream: false`）。
    func complete(_ request: ChatRequest) async throws -> ChatResult
}

/// 生图客户端。
public protocol ImageGenerating: Sendable {
    /// 生成图片。返回数量取决于服务端能力（多数服务端只支持 1 张）。
    ///
    /// - Throws: `AIError`（未配置 / 鉴权 / 限流 / 超时 / 内容拒绝 / 下载失败）。
    func generate(_ request: ImageRequest) async throws -> [GeneratedImage]
}
