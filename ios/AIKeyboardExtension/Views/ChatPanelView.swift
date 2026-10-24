//
//  ChatPanelView.swift
//  墨语（Moyu）键盘扩展 · 全场 AI 对话面板（外壳）
//
//  模块职责：键盘整区切换为对话界面（design/04 §3）。四段式固定分区：
//            40（标题条）/ 180（消息区）/ 44（输入行，组合态原地换候选行）/ 174（标准键区）。
//            本文件只负责「外壳 + 标题条 + 输入行 + 键区」；
//            消息气泡与操作行拆到 `ChatMessageListView.swift`（单文件行数约束）。
//  设计依据：design/04-AI对话与智能联想规范.md §3.2（分区）、§3.3（标题条）、
//            §3.8（输入行）、§3.9（键区路由）、§3.10（空态）。
//  约束：绝不使用 TextField（扩展内无法可靠唤起系统键盘，且易抢输入源）；
//        输入一律走 `model.tap(_:)` 写 `chatDraft`，退格按 `Character` 删除；
//        本视图不计算键盘高度，高度由 `KeyboardViewController` 的 `heightAnchor` 决定。
//

import SwiftUI

// MARK: - 对话面板

/// 全场 AI 对话面板。
struct ChatPanelView: View {

    /// 键盘状态机。
    @ObservedObject var model: KeyboardViewModel

    /// 是否展示「清空对话」确认层。
    @State private var showsClearConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ChatMessageListView(
                model: model,
                isEmptyState: showsEmptyState,
                messageHeight: messageAreaHeight
            )
            inputRow
            keyArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.keyboardBackground)
        .overlay(alignment: .center) {
            if showsClearConfirm {
                KMConfirmation(
                    title: "清空当前对话？",
                    message: "清空后无法恢复，但可以继续和墨语聊天。",
                    confirmTitle: "清空",
                    onConfirm: {
                        showsClearConfirm = false
                        model.clearChat()
                    },
                    onCancel: { showsClearConfirm = false }
                )
            }
        }
    }

    /// 是否展示空态：只有开场白且当前空闲。
    private var showsEmptyState: Bool {
        model.chatMessages.count <= 1 && model.chatPhase == .idle
    }

    // MARK: - 横竖屏尺寸

    /// 标题条高度：竖屏 40、横屏 32（design/04 §3.11）。
    private var topBarHeight: CGFloat {
        model.isLandscape ? KMLayout.aiChatLandscapeTopBarHeight : KMLayout.aiChatTopBarHeight
    }

    /// 键区高度：竖屏 174（4 × 39 + 3 × 6）、横屏 156（4 × 34.5 + 3 × 6）。
    ///
    /// 这两步都必须跟着 `isLandscape` 走 —— `keyboardHeight(.aiChat)` 横屏返回
    /// 200 + 140 = 340，若仍用竖屏的 40 / 174，四段分区会算成 438，超出 98pt。
    private var keyAreaHeight: CGFloat {
        model.isLandscape ? KMLayout.landscapeKeyRowsHeight : KMLayout.keyRowsHeight
    }

    /// 消息区高度：竖屏 180、横屏 108（design/04 §3.11）。横屏只显示 1–2 条，属可接受降级。
    private var messageAreaHeight: CGFloat {
        model.isLandscape ? KMLayout.aiChatLandscapeMessageHeight : KMLayout.aiChatMessageHeight
    }

    // MARK: - 标题条（40pt）

    /// 标题条：左关闭 / 中标题 + 状态点 / 右新对话。
    private var topBar: some View {
        HStack(spacing: 0) {
            Button(action: { model.closeAIChat() }) {
                KMIconGlyph(symbol: "xmark", fallback: "✕", size: 15, weight: .semibold, tint: Theme.textSecondary)
                    .frame(width: 44, height: topBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.92, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("关闭 AI 对话"))

            HStack(spacing: 0) {
                Text("墨语 AI")
                    .font(Theme.fontHeadline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                statusDot
                    .padding(.leading, Theme.Spacing.sm)
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Spacing.sm)

            Button(action: { requestNewChat() }) {
                KMIconGlyph(
                    symbol: "square.and.pencil",
                    fallback: "↻",
                    size: 15,
                    weight: .regular,
                    tint: Theme.textSecondary
                )
                .frame(width: 44, height: topBarHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.92, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("开始新对话"))
        }
        .frame(height: topBarHeight)
        .background(Theme.keyboardBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
        .accessibilityElement(children: .contain)
    }

    /// 标题右侧状态点（success 已连接 / warning 生成中 / danger 出错 / textTertiary 未知）。
    private var statusDot: some View {
        Circle()
            .fill(statusDotColor)
            .frame(width: Theme.Sizing.pageDotSize, height: Theme.Sizing.pageDotSize)
            .accessibilityLabel(Text(statusDotLabel))
    }

    /// 状态点颜色。
    private var statusDotColor: Color {
        switch model.chatPhase {
        case .thinking, .streaming, .imageGenerating:
            return Theme.warning
        case .failed:
            return Theme.danger
        case .idle, .cancelled:
            return model.aiAvailability == .ready ? Theme.success : Theme.textTertiary
        }
    }

    /// 状态点无障碍文案。
    private var statusDotLabel: String {
        switch model.chatPhase {
        case .thinking, .streaming:
            return "正在回答"
        case .imageGenerating:
            return "正在生成图片"
        case .failed:
            return "上一次请求出错"
        case .idle, .cancelled:
            return model.aiAvailability == .ready ? "AI 服务已连接" : "AI 服务状态未知"
        }
    }

    /// 点击「新对话」：有消息先确认。
    private func requestNewChat() {
        if showsEmptyState {
            model.clearChat()
        } else {
            showsClearConfirm = true
        }
    }

    // MARK: - 输入行（44pt）

    /// 输入行：组合态原地换候选行（高度不变）。
    @ViewBuilder
    private var inputRow: some View {
        if model.composing.isEmpty {
            HStack(spacing: Theme.Spacing.md) {
                inputCapsule
                sendButton
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: KMLayout.aiChatInputHeight)
            .background(Theme.keyboardBackground)
        } else {
            CandidateBar(
                items: model.currentPageCandidates,
                highlightedIndex: model.highlightedCandidateIndex,
                showsIndex: false,
                pageIndex: model.candidatePageIndex,
                pageCount: model.candidatePageCount,
                composingText: model.composing,
                showsChatKnob: false,
                onSelect: { index in
                    model.selectCandidate(at: model.candidatePageIndex * KeyboardViewModel.candidatePageSize + index)
                },
                onLongPress: { index in
                    model.longPressCandidate(at: model.candidatePageIndex * KeyboardViewModel.candidatePageSize + index)
                },
                onTogglePage: { delta in model.turnCandidatePage(delta) }
            )
            .frame(height: KMLayout.aiChatInputHeight)
            .transition(.opacity)
        }
    }

    /// 胶囊输入框（自绘，不用 TextField）。
    private var inputCapsule: some View {
        HStack(spacing: 0) {
            if model.chatDraft.isEmpty {
                Text("和墨语说点什么…")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPlaceholder)
                    .lineLimit(1)
            } else {
                Text(model.chatDraft)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                StreamingCursor()
                    .padding(.leading, Theme.Spacing.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: KMLayout.aiChatSendSize)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    model.chatDraft.isEmpty ? Theme.separator : Theme.accent,
                    lineWidth: Theme.MaterialToken.strokeWidth
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.chatDraft.isEmpty ? "对话输入框，空" : "对话输入框：\(model.chatDraft)"))
        .accessibilityHint(Text("用下方键盘打字，右侧按钮发送"))
    }

    /// 发送 / 停止按钮（36×36，命中 44）。
    private var sendButton: some View {
        Button(action: { model.sendChatMessage() }) {
            ZStack {
                Circle()
                    .fill(sendFill)
                KMIconGlyph(
                    symbol: model.chatPhase.isBusy ? "stop.fill" : "arrow.up",
                    fallback: model.chatPhase.isBusy ? "■" : "↑",
                    size: 16,
                    weight: .semibold,
                    tint: Theme.textOnAccent
                )
            }
            .frame(width: KMLayout.aiChatSendSize, height: KMLayout.aiChatSendSize)
            .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.92, duration: Theme.Motion.fast))
        .disabled(!canSend)
        .accessibilityLabel(Text(model.chatPhase.isBusy ? "停止生成" : "发送"))
    }

    /// 发送按钮底色。
    private var sendFill: Color {
        if model.chatPhase.isBusy { return Theme.accent }
        return canSend ? Theme.accent : Theme.accent.opacity(0.4)
    }

    /// 是否可发送。
    private var canSend: Bool {
        model.chatPhase.isBusy || !model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 键区（174pt）

    /// 标准键区：与字母页完全同一套（design/04 §3.9），onTap 统一走 `model.tap(_:)`。
    ///
    /// 高度必须正好是 `keyRowsHeight`（竖屏 174 / 横屏 156）。这两个值本身已经含了
    /// 4 行行高与 3 条行间距，而 `KeyRowsView` 内部也固定为该值，外层再加就会把四段
    /// 分区总和顶爆（竖屏 438 → 456、横屏 340 → 438），导致最底一排键被裁掉。
    /// 四段分区：40/32（标题条）+ 180/108（消息区）+ 44（输入行）+ 174/156（键区）。
    private var keyArea: some View {
        KeyRowsView(
            layoutMode: model.layoutMode,
            shiftState: model.shiftState,
            isLandscape: model.isLandscape,
            onTap: { key in model.tap(key) }
        )
        .frame(height: keyAreaHeight)
    }
}
