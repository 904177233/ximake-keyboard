//
//  ChatMessageListView.swift
//  墨语（Moyu）键盘扩展 · 对话消息列表 / 气泡 / 操作行 / 空态
//
//  模块职责：对话面板的 180pt 消息区（design/04 §3.4–§3.7、§3.10）。覆盖六种消息形态：
//            ①用户文本 ②AI 流式中 ③AI 完成 ④思考中 ⑤错误 ⑥生图结果 / ⑥b 生图进行中；
//            以及「最新一条 AI 消息」下方的操作行（上屏 / 复制 / 重试）。
//  设计依据：design/04-AI对话与智能联想规范.md §3.4（间距）、§3.5（气泡）、§3.6（六型）、§3.7（操作行）。
//  约束：气泡最大宽 = 消息区可用宽 − 64（390 场景 = 302）；尾角差异属加分项，iOS 16 统一 16 圆角；
//        不允许把消息区撑高——列表在 180pt 内滚动。
//

import SwiftUI

// MARK: - 消息列表

/// 对话消息列表（固定 180pt，内部滚动，新消息自动滚到底）。
struct ChatMessageListView: View {

    /// 键盘状态机。
    @ObservedObject var model: KeyboardViewModel

    /// 是否展示空态（只有开场白且空闲）。
    let isEmptyState: Bool

    /// 底部滚动锚点 ID。
    private let bottomAnchor: String = "chat.bottom.anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if isEmptyState {
                        emptyState
                    } else {
                        ForEach(model.chatMessages) { message in
                            messageRow(message)
                        }
                        if model.chatPhase == .imageGenerating {
                            imageProgressRow
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
            .onChange(of: model.chatMessages.count) { _ in
                // iOS 16 单参数 onChange：新消息到达即滚到底（design/04 §3.4）。
                withAnimation(KMAnimation.animation(duration: Theme.Motion.fast)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.chatStreamingText) { _ in
                guard model.chatPhase == .streaming else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        .frame(height: KMLayout.aiChatMessageHeight)
        .background(Theme.keyboardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("对话消息"))
    }

    // MARK: - 单条消息

    /// 单条消息（气泡 + 操作行）。
    /// - Parameter message: 消息模型。
    private func messageRow(_ message: KMChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {
            bubble(for: message)
            if shouldShowActions(for: message), !message.isImageMessage {
                textActionRow(for: message)
                    .padding(.top, Theme.Spacing.sm)
            }
            if shouldShowActions(for: message), message.isImageMessage {
                imageActionRow(for: message)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.top, topSpacing(for: message))
    }

    /// 上间距：同人 6 / 换人 12（design/04 §3.4）。
    /// - Parameter message: 当前消息。
    /// - Returns: 顶部间距。
    private func topSpacing(for message: KMChatMessage) -> CGFloat {
        guard let index = model.chatMessages.firstIndex(where: { $0.id == message.id }), index > 0 else {
            return 0
        }
        let previous = model.chatMessages[index - 1]
        return previous.role == message.role ? Theme.Spacing.sm + Theme.Spacing.xs : Theme.Spacing.lg
    }

    // MARK: - 气泡

    /// 气泡本体（按消息形态分流）。
    /// - Parameter message: 消息模型。
    /// - Returns: 气泡视图。
    @ViewBuilder
    private func bubble(for message: KMChatMessage) -> some View {
        if let errorDetail = message.errorDetail {
            errorBubble(errorDetail)
        } else if let imageData = message.imageData {
            imageBubble(imageData)
        } else if message.role == .user {
            textBubble(text: message.text, isUser: true, isStreaming: false)
        } else if message.text.isEmpty && message.isStreaming {
            thinkingBubble
        } else {
            textBubble(text: message.text, isUser: false, isStreaming: message.isStreaming)
        }
    }

    /// 文本气泡。
    /// - Parameters:
    ///   - text: 文本。
    ///   - isUser: 是否用户消息。
    ///   - isStreaming: 是否流式（末尾画光标）。
    /// - Returns: 气泡视图。
    private func textBubble(text: String, isUser: Bool, isStreaming: Bool) -> some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 0) }
            HStack(alignment: .bottom, spacing: 0) {
                Text(text)
                    .font(Theme.fontBody)
                    .foregroundColor(isUser ? Theme.textOnAccent : Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isStreaming {
                    StreamingCursor()
                        .padding(.leading, Theme.Spacing.xs)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: KMLayout.aiChatBubbleCorner, style: .continuous)
                    .fill(isUser ? Theme.accent : Theme.surfaceElevated)
            )
            .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(isUser ? "你说：" : "AI 说：")\(text)"))
        .onLongPressGesture(minimumDuration: 0.5) {
            if !isUser { model.copyChatResult(text) }
        }
    }

    /// 思考中气泡（3 个 6pt 圆点依次明暗）。
    private var thinkingBubble: some View {
        HStack(spacing: 0) {
            KMChatThinkingDots()
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: KMLayout.aiChatBubbleCorner, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("AI 正在思考"))
    }

    /// 错误气泡（warning 紧凑版 + 重试）。
    /// - Parameter detail: 错误详情。
    /// - Returns: 气泡视图。
    private func errorBubble(_ detail: KMAIErrorDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                KMIconGlyph(symbol: "exclamationmark.triangle.fill", fallback: "!", size: 14, tint: Theme.warning)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(detail.title)
                        .font(Theme.fontChip)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail.recovery)
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if detail.isRetryable {
                Button(action: { model.retryChat() }) {
                    Text("重试")
                        .font(Theme.fontChip)
                        .foregroundColor(Theme.accent)
                        .frame(minHeight: Theme.Sizing.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
                .accessibilityLabel(Text("重试这条请求"))
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: KMLayout.aiChatBubbleCorner, style: .continuous)
                .fill(Theme.warningSoft)
        )
        .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// 生图结果气泡（120×120 缩略图 + 长按提示）。
    /// - Parameter data: 缩略图 PNG。
    /// - Returns: 气泡视图。
    private func imageBubble(_ data: Data) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let image = KMImageThumbnail.image(from: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Theme.Sizing.resultCardMinHeight, height: Theme.Sizing.resultCardMinHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous))
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.5) {
                        UIPasteboard.general.image = image
                        model.showToast(KeyboardViewModel.imagePasteHint)
                    }
            }
            Text("长按复制图片")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("AI 生成的图片，长按复制"))
    }

    /// 生图进行中（48pt 进度环 + 已等待秒数 + 取消）。
    private var imageProgressRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            KMProgressRing(
                size: Theme.Spacing.xxxl + Theme.Spacing.xl,
                progress: nil
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("绘制中… 已等待 \(Int(model.chatImageProgress?.elapsed ?? 0)) 秒")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                Text(progressSubtitle)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: { model.cancelChat() }) {
                Text("取消")
                    .font(Theme.fontChip)
                    .foregroundColor(Theme.accent)
                    .frame(minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("取消生图"))
        }
        .padding(.top, Theme.Spacing.lg)
    }

    /// 生图副标题（阶段文案 / 超时提示）。
    private var progressSubtitle: String {
        let elapsed = model.chatImageProgress?.elapsed ?? 0
        if elapsed > KMLayout.suggestTimeout * 13 {
            return "仍在绘制，可继续等待"
        }
        return model.chatImageProgress?.stage.title ?? "预计 5–20 秒"
    }

    // MARK: - 操作行（32pt，命中 44）

    /// 是否展示操作行：仅最新一条已完成的 AI 消息，且当前不在请求中。
    /// - Parameter message: 消息。
    /// - Returns: 是否展示。
    private func shouldShowActions(for message: KMChatMessage) -> Bool {
        guard message.role == .assistant, !message.isStreaming, message.errorDetail == nil else {
            return false
        }
        guard let lastAssistant = model.chatMessages.last(where: { $0.role == .assistant }) else {
            return false
        }
        return lastAssistant.id == message.id && !model.chatPhase.isBusy
    }

    /// 文本消息操作行：上屏 / 复制 / 重试。
    /// - Parameter message: 目标消息。
    /// - Returns: 操作行视图。
    private func textActionRow(for message: KMChatMessage) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: { model.insertChatResult(message.text) }) {
                Text("上屏")
                    .font(Theme.fontChip)
                    .foregroundColor(Theme.textOnAccent)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .frame(height: KMLayout.aiChatActionHeight)
                    .background(Capsule(style: .continuous).fill(Theme.accent))
                    .frame(minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("上屏"))
            .accessibilityHint(Text("把这条回复插入到当前输入框"))

            Button(action: { model.copyChatResult(message.text) }) {
                Text("复制")
                    .font(Theme.fontChip)
                    .foregroundColor(Theme.textSecondary)
                    .frame(minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("复制这条回复"))

            Button(action: { model.retryChat() }) {
                Text("重试")
                    .font(Theme.fontChip)
                    .foregroundColor(Theme.textSecondary)
                    .frame(minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("重新生成"))

            Spacer(minLength: 0)
        }
    }

    /// 图片消息操作行：复制图片。
    /// - Parameter message: 目标消息。
    /// - Returns: 操作行视图。
    private func imageActionRow(for message: KMChatMessage) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: { model.copyChatImage(message) }) {
                Text("复制图片")
                    .font(Theme.fontChip)
                    .foregroundColor(Theme.textSecondary)
                    .frame(minHeight: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("复制图片"))
            .accessibilityHint(Text(KeyboardViewModel.imagePasteHint))
            Spacer(minLength: 0)
        }
    }

    // MARK: - 空态

    /// 空态：图标 + 标题 + 副标题 + 3 条示例提问（design/04 §3.10）。
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            KMKnobGlyph(size: Theme.Spacing.xxxl, tint: Theme.accent.opacity(0.6))
            Text("和墨语聊聊")
                .font(Theme.fontTitle)
                .foregroundColor(Theme.textPrimary)
            Text("当前使用 \(providerName) · 回答可一键上屏")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textSecondary)
            HStack(spacing: KMLayout.sugChipGap) {
                ForEach(KeyboardViewModel.chatSamplePrompts, id: \.self) { prompt in
                    KMPillChip(prompt, style: .tag, isSelected: false, isEnabled: true) {
                        model.sendChatSample(prompt)
                    }
                }
            }
            .padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.lg)
    }

    /// 空态副标题里的服务商名称。
    private var providerName: String {
        let name = model.lastProviderName
        return name.isEmpty ? "AI 服务" : name
    }

    // MARK: - 尺寸

    /// 气泡最大宽：消息区可用宽 − 64（390 场景 = 302）。
    private var bubbleMaxWidth: CGFloat {
        max(KMLayout.contentWidthBaseline - Theme.Spacing.xxxl * 2, 120)
    }
}

// MARK: - 流式光标

/// 流式输出末尾的竖条光标（2×18，accent，0.9s 明暗循环）。
struct StreamingCursor: View {

    /// 是否变暗（由呼吸动画驱动）。
    @State private var isDim: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 2, height: 18)  // TOKEN: typography.caption.lineHeight = 18
            .opacity(isDim ? 0.2 : 1.0)
            .onAppear(perform: startIfNeeded)
            .accessibilityHidden(true)
    }

    /// 启动闪烁；Reduce Motion 下保持常亮（design/04 §7）。
    private func startIfNeeded() {
        guard !KMAnimation.isReduceMotionEnabled else { return }
        withAnimation(.easeInOut(duration: Theme.Motion.streamCursorBlink).repeatForever(autoreverses: true)) {
            isDim = true
        }
    }
}

// MARK: - 思考中三点

/// 思考中的三个圆点（6pt，依次明暗，周期 1.2s；不使用转圈）。
struct KMChatThinkingDots: View {

    /// 当前高亮的下标。
    @State private var activeIndex: Int = 0

    /// 循环定时器（视图消失时置 nil 停止）。
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: Theme.Sizing.pageDotSize, height: Theme.Sizing.pageDotSize)
                    .opacity(activeIndex == index ? 1.0 : 0.3)
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: stop)
    }

    /// 启动循环；Reduce Motion 下保持静态（design/04 §7）。
    private func startIfNeeded() {
        guard !KMAnimation.isReduceMotionEnabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }

    /// 停止循环。
    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
