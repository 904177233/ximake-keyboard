//
//  TestConnectionView.swift
//  墨语 · 宿主 App
//
//  模块职责：「测试连接」的复用逻辑与结果条。
//            对指定服务商发一条 `hi`（maxTokens 8）的流式请求，统计首字延迟与总耗时，
//            成功显示「连接成功 · 返回：…」，失败显示 AIError 的中文文案与建议。
//  依赖：SwiftUI、Shared（AIClientFactory / ChatRequest / ChatDelta / AIError）。
//  使用方：ProviderEditorView / ProviderListView / DiagnosticsView。
//

import SwiftUI

/// 一次连接测试的状态。
enum ConnectionTestState: Equatable {
    /// 未测试。
    case idle
    /// 测试中（已等待秒数由视图自行计时）。
    case testing
    /// 成功：返回片段 + 耗时（毫秒）。
    case success(sample: String, latencyMs: Int)
    /// 失败：中文主文案 + 可选建议。
    case failure(message: String, suggestion: String?)

    /// 是否正在测试。
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

/// 连接测试执行器。
@MainActor
final class ConnectionTester: ObservableObject {

    /// 当前状态。
    @Published private(set) var state: ConnectionTestState = .idle

    /// 当前测试任务的标识（用于取消上一个）。
    private var currentTaskID = UUID()

    /// 发起测试。
    /// - Parameters:
    ///   - provider: 待测服务商配置。
    ///   - apiKey: 该服务商的 API Key。
    func test(provider: AIProviderConfig, apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failure(message: "还没有填写 API Key", suggestion: "请先在上面填入 API Key 并保存到钥匙串。")
            return
        }
        guard provider.isChatConfigured else {
            state = .failure(message: "配置还不完整", suggestion: "请填写 Base URL 与模型名后再测试。")
            return
        }
        guard provider.supportsChat else {
            state = .failure(
                message: "该服务仅支持生图",
                suggestion: provider.unsupportedChatReason
            )
            return
        }

        let taskID = UUID()
        currentTaskID = taskID
        state = .testing
        let startedAt = Date()

        // 探活的目的只有一个：**证明「地址 + Key + 模型名」这三项能换回模型的响应**。
        // 不是测「模型能不能好好回答问题」。
        //
        // v2.3 改动：改走**非流式** `complete()`，不再用 SSE 流。
        // 用户报「测试 API 服务商返回空内容 / 发生未知错误」的直接原因就在这条路径上：
        // 流式解析要对齐 SSE 格式（`data:` 前缀、`[DONE]`、`choices[].delta.content`），
        // 任何一个网关的格式偏差都会让正文一个字符都拿不到，于是「明明配对了却显示空内容」。
        // 探活只需一次完整的非流式响应，最稳、也最少依赖实现细节。
        Task {
            do {
                let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
                let request = ChatRequest(
                    messages: [ChatMessage.user("hi")],
                    temperature: 0,
                    // 1024：推理模型对 "hi" 的思维链本身就要一百多 token。
                    maxTokens: 1024,
                    stream: false
                )
                let result = try await client.complete(request)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                guard currentTaskID == taskID else { return }
                let sample = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if sample.isEmpty {
                    state = .success(
                        sample: "（地址与 Key 已通过验证，但正文为空）",
                        latencyMs: elapsed
                    )
                } else {
                    state = .success(sample: Self.truncated(sample), latencyMs: elapsed)
                }
            } catch {
                guard currentTaskID == taskID else { return }
                // `contentRejected` 表示「HTTP 通了、但正文为空」——地址/Key/模型名
                // 都已经验收通过，不该显示成红色失败（那会让用户以为 Key 配错了）。
                if case AIError.contentRejected = AIError.wrap(error) {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    state = .success(
                        sample: "（地址与 Key 已通过验证，正文为空："
                            + (AIError.wrap(error).errorDescription ?? "")
                            + "）",
                        latencyMs: elapsed
                    )
                    return
                }
                let wrapped = AIError.wrap(error)
                if case AIError.cancelled = wrapped {
                    state = .idle
                    return
                }
                // 收到过思维链却因「正文为空」抛错 → 仍然算连通（同上理由）。
                if sawReasoning, case AIError.contentRejected = wrapped {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    state = .success(
                        sample: "（这是推理模型，探活只收到思维链，正文需在聊天框里发长一点的问题才会出现）",
                        latencyMs: elapsed
                    )
                    return
                }
                state = .failure(
                    message: ErrorPresenter.message(error),
                    suggestion: ErrorPresenter.suggestion(error)
                )
            }
        }
    }

    /// 取消当前测试（回到未测试状态）。
    func cancel() {
        currentTaskID = UUID()
        state = .idle
    }

    /// 重置为未测试。
    func reset() {
        cancel()
    }

    /// 截断过长的返回内容（保留一行、最多 40 字）。
    private static func truncated(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= 40 {
            return singleLine
        }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: 40)
        return String(singleLine[..<endIndex]) + "…"
    }
}

/// 连接测试结果条（成功绿 / 失败红 / 测试中蓝）。
struct ConnectionTestBanner: View {

    let state: ConnectionTestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .testing:
            bannerContainer(tint: Theme.accent) {
                HStack(spacing: AppMetrics.tightGap) {
                    ProgressDots(tint: Theme.accent)
                    Text("正在测试连接…")
                        .font(AppFont.footnoteStrong)
                        .foregroundColor(Theme.textPrimary)
                }
            }

        case .success(let sample, let latencyMs):
            bannerContainer(tint: Theme.success) {
                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    HStack(spacing: AppMetrics.tightGap) {
                        IconGlyph(
                            symbol: "checkmark.circle.fill",
                            fallback: "✓",
                            size: AppMetrics.glyphSizeSmall,
                            weight: .semibold,
                            tint: Theme.success
                        )
                        Text("连接成功 · \(latencyMs) 毫秒")
                            .font(AppFont.footnoteStrong)
                            .foregroundColor(Theme.textPrimary)
                    }
                    Text("返回：\(sample)")
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .failure(let message, let suggestion):
            bannerContainer(tint: Theme.danger) {
                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    HStack(spacing: AppMetrics.tightGap) {
                        IconGlyph(
                            symbol: "exclamationmark.circle.fill",
                            fallback: "!",
                            size: AppMetrics.glyphSizeSmall,
                            weight: .semibold,
                            tint: Theme.danger
                        )
                        Text(message)
                            .font(AppFont.footnoteStrong)
                            .foregroundColor(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let suggestion {
                        Text(suggestion)
                            .font(AppFont.caption)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func bannerContainer<Content: View>(
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(AppMetrics.rowVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: AppMetrics.hairline)
            )
            .transition(.opacity.combined(with: .offset(y: -AppMetrics.tightGap)))
            .animation(Theme.Motion.normalAnimation, value: state)
    }
}

#if DEBUG
struct ConnectionTestBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.blockGap) {
            ConnectionTestBanner(state: .testing)
            ConnectionTestBanner(state: .success(sample: "你好！有什么可以帮你？", latencyMs: 812))
            ConnectionTestBanner(
                state: .failure(
                    message: "API Key 无效或已过期",
                    suggestion: "请到服务商控制台重新创建 Key，再回到这里重新填写。"
                )
            )
        }
        .padding(AppMetrics.pageInset)
        .background(AppColor.pageBackground)
    }
}
#endif
