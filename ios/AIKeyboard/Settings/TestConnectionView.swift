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
        // 不是测「模型能不能好好回答问题」。所以只要能收到任何一段模型输出
        // （正文 text 或思维链 reasoning）就算连通。
        //
        // 这条区分是用户反馈「API 配置好还是用不了，提示错误」的直接原因之一：
        // deepseek-reasoner 这类推理模型对 "hi" 会先吐一大段思维链，探活预算不够时
        // 正文为空，旧逻辑会抛 contentRejected 并显示成红色失败——用户以为 Key 配错了，
        // 其实完全正常。
        Task {
            var buffer = ""
            var sawReasoning = false
            do {
                let stream = ConnectivityProbe.makeHelloStream(config: provider, apiKey: apiKey)
                for try await delta in stream {
                    if !delta.text.isEmpty {
                        buffer += delta.text
                    }
                    if let reasoning = delta.reasoning, !reasoning.isEmpty {
                        sawReasoning = true
                    }
                    if delta.isFinal {
                        break
                    }
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                guard currentTaskID == taskID else { return }
                let sample = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if sample.isEmpty {
                    // 正文空但收到过思维链 → 模型确实活着，这是推理模型的正常表现。
                    state = .success(
                        sample: sawReasoning
                            ? "（这是推理模型，探活只收到思维链，正文需在聊天框里发长一点的问题才会出现）"
                            : "（服务商返回空内容）",
                        latencyMs: elapsed
                    )
                } else {
                    state = .success(sample: Self.truncated(sample), latencyMs: elapsed)
                }
            } catch {
                guard currentTaskID == taskID else { return }
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
