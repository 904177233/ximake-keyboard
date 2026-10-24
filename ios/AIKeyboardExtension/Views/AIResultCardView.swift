//
//  AIResultCardView.swift
//  墨语（Moyu）键盘扩展 · AI 结果卡片
//
//  模块职责：AI 结果的五态展示（流式 / 完成 / 失败 / 生图绘制中 / 图片结果）。
//            文本态布局 = 上 8 + 卡片 164（header 28 + body 92 + actions 44）+ 下 8 = 180。
//            生图绘制中显示进度环 + 「绘制中… 已等待 N 秒」+「预计 5–20 秒」+ 阶段文案 + 取消，
//            并明确「不用无限转圈的 ProgressView」。
//  设计依据：design/组件库.md「AIResultCard」、design/键盘布局规范.md §4.5、§5 状态 ③④⑤⑥⑦⑧。
//  约束：body 用 `KMStreamingText` 的 maxHeight 92 内部滚动，绝不撑高键盘。
//

import SwiftUI

/// AI 结果卡片。
struct AIResultCardView: View {

    /// 键盘状态机。
    @ObservedObject var model: KeyboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            card
            if model.lastFeature == .replySuggestion, !model.replySuggestions.isEmpty {
                replySuggestionBar
            }
        }
        .padding(.top, KMLayout.resultPadding)
        .padding(.bottom, KMLayout.resultPadding)
        .padding(.horizontal, KMLayout.resultCardSideInset)
        .frame(height: KMLayout.resultCardHeight + KMLayout.resultPadding * 2, alignment: .top)
        .background(Theme.keyboardBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 卡片主体

    /// 玻璃卡片（header 28 + body 92 + actions 44）。
    private var card: some View {
        KMGlassSurface(level: .bar, cornerRadius: Theme.Radius.card, showsHighlight: true) {
            VStack(spacing: 0) {
                header
                    .frame(height: KMLayout.resultHeaderHeight)
                bodyContent
                    .frame(height: KMLayout.resultBodyHeight)
                actionBar
                    .frame(height: KMLayout.resultActionHeight)
            }
        }
        .frame(height: KMLayout.resultCardHeight)
    }

    // MARK: - header

    /// 头部：能力标签 + 服务商 + 状态 + 关闭。
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            KMPillChip(
                title: model.lastFeature.title,
                systemImage: model.lastFeature.systemImage,
                style: .tag,
                size: .small,
                isSelected: false,
                isEnabled: false,
                action: {}
            )

            if !model.lastProviderName.isEmpty {
                Text(model.lastProviderName)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(statusText)
                .font(Theme.fontCaption)
                .foregroundColor(statusColor)
                .lineLimit(1)

            Button(action: {
                KMHaptics.chip()
                model.dismissAIResult()
            }) {
                KMIconGlyph(symbol: "xmark", fallback: "✕", size: 12, tint: Theme.textTertiary)
                    .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
            }
            .buttonStyle(KMPressableStyle())
            .accessibilityLabel(Text("关闭结果"))
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    /// 状态文案。
    private var statusText: String {
        switch model.aiState {
        case .idle:
            return ""
        case .streaming:
            return "正在生成…"
        case .done:
            return String(format: "已完成 %.1fs", model.lastAIDuration)
        case .failed:
            return "失败"
        case .imageGenerating:
            return "绘制中…"
        case .image:
            return "已完成"
        }
    }

    /// 状态颜色。
    private var statusColor: Color {
        switch model.aiState {
        case .failed:
            return Theme.danger
        case .done, .image:
            return Theme.success
        default:
            return Theme.textSecondary
        }
    }

    // MARK: - body

    /// 正文（按状态切换）。
    @ViewBuilder
    private var bodyContent: some View {
        switch model.aiState {
        case .idle:
            KMEmptyState(
                systemImage: "sparkles",
                fallback: "✨",
                title: "选择一个 AI 能力开始",
                message: "润色 / 扩写 / 翻译 / 回复 / 生图"
            )
        case let .streaming(text):
            KMStreamingText(text: text, isStreaming: true, maxHeight: KMLayout.resultBodyHeight)
                .padding(.horizontal, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case let .done(text):
            KMStreamingText(text: text, isStreaming: false, maxHeight: KMLayout.resultBodyHeight)
                .padding(.horizontal, Theme.Spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed:
            failureBody
        case let .imageGenerating(progress):
            imageGeneratingBody(progress)
        case let .image(data):
            imageResultBody(data)
        }
    }

    /// 失败态：错误条 + 恢复建议。
    private var failureBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            let detail = model.lastAIErrorDetail
            KMErrorBanner(
                severity: .error,
                title: detail?.title ?? "生成失败",
                message: detail?.recovery,
                actionTitle: detail?.suggestsSettings == true ? "去设置" : nil,
                onAction: detail?.suggestsSettings == true
                    ? { model.tap(.openSettings) }
                    : nil,
                onDismiss: nil
            )

            HStack(spacing: Theme.Spacing.sm) {
                KMSecondaryButton(title: "重试", systemImage: "arrow.clockwise") {
                    model.retryAI()
                }
                .opacity(model.lastRequestText.isEmpty ? 0.4 : 1)
                .disabled(model.lastRequestText.isEmpty)

                KMSecondaryButton(title: "关闭") {
                    model.dismissAIResult()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 生图绘制中：进度环 + 已等待秒数 + 预计时长 + 阶段 + 取消。
    private func imageGeneratingBody(_ progress: KMImageProgress) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            KMProgressRing(
                size: 48,  // TOKEN: design/键盘布局规范.md §4.5 进度环 48
                progress: min(progress.elapsed / max(progress.expected.upperBound, 1), 0.98)
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("绘制中… 已等待 \(Int(progress.elapsed)) 秒")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(progress.elapsed > progress.expected.upperBound
                     ? "仍在绘制，可继续等待"
                     : "预计 5–20 秒")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                Text(progress.stage.title)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            KMSecondaryButton(title: "取消") {
                model.cancelAI(silently: false)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("正在绘制图片，已等待 \(Int(progress.elapsed)) 秒"))
    }

    /// 图片结果：缩略图 + 竖排按钮 + 长按粘贴提示。
    private func imageResultBody(_ data: Data) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            thumbnail(data)

            VStack(spacing: Theme.Spacing.sm) {
                KMSecondaryButton(title: "复制图片", systemImage: "doc.on.doc") {
                    model.copyImageToPasteboard()
                }
                KMSecondaryButton(title: "关闭") {
                    model.dismissAIResult()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 缩略图（最大 160×120，圆角 12）。
    @ViewBuilder
    private func thumbnail(_ data: Data) -> some View {
        if let image = KMImageThumbnail.image(from: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: 160, maxHeight: KMLayout.resultBodyHeight - Theme.Spacing.md)
                .frame(width: 120, height: KMLayout.resultBodyHeight - Theme.Spacing.md)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
                )
                .overlay(alignment: .bottom) {
                    Text(KeyboardViewModel.imagePasteHint)
                        .font(.system(size: 12, weight: .regular))  // TOKEN: typography.caption.size = 12
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.surfaceElevated.opacity(0.9))
                        .padding(.bottom, Theme.Spacing.sm)
                }
                .accessibilityLabel(Text("生成的图片，\(KeyboardViewModel.imagePasteHint)"))
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
                .fill(Theme.surfaceElevated)
                .frame(width: 120, height: KMLayout.resultBodyHeight - Theme.Spacing.md)
                .overlay(
                    Text("图片不可用")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textTertiary)
                )
        }
    }

    // MARK: - actions

    /// 动作条：插入 / 复制 / 编辑 / 重试 / 取消。
    private var actionBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            switch model.aiState {
            case .streaming:
                if let text = model.aiState.streamingText as String? {
                    KMSecondaryButton(title: "取消") {
                        _ = text
                        model.cancelAI(silently: false)
                    }
                }
                Spacer(minLength: 0)
                Text("正在生成…")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
            case let .done(text):
                KMPrimaryButton(
                    title: "插入",
                    systemImage: "arrow.down.doc",
                    isEnabled: true,
                    isLoading: false,
                    height: Theme.Spacing.xxxl,
                    fullWidth: false,
                    action: { model.insertAIResult(text) }
                )
                KMSecondaryButton(title: "复制") {
                    model.copyAIResult(text)
                }
                KMSecondaryButton(title: "编辑") {
                    model.editAIResult()
                }
                Spacer(minLength: 0)
                Button(action: {
                    KMHaptics.chip()
                    model.retryAI()
                }) {
                    KMIconGlyph(symbol: "arrow.clockwise", fallback: "↻", size: 16, tint: Theme.textSecondary)
                        .frame(width: Theme.Sizing.minTapTarget, height: Theme.Spacing.xxxl)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KMPressableStyle(scale: 0.94, pressedOpacity: 0.8))
                .accessibilityLabel(Text("重试"))
            case .imageGenerating:
                KMSecondaryButton(title: "取消") {
                    model.cancelAI(silently: false)
                }
                Spacer(minLength: 0)
                Text("预计 5–20 秒")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
            case .image:
                KMSecondaryButton(title: "复制图片") {
                    model.copyImageToPasteboard()
                }
                Spacer(minLength: 0)
                Text(KeyboardViewModel.imagePasteHint)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            case .failed, .idle:
                Spacer(minLength: 0)
                KMSecondaryButton(title: "关闭") {
                    model.dismissAIResult()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - 回复建议

    /// 回复建议三条（点某条直接上屏并收起）。
    private var replySuggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Sizing.aiChipGap) {
                ForEach(Array(model.replySuggestions.enumerated()), id: \.offset) { pair in
                    KMPillChip(
                        title: pair.element,
                        systemImage: "bubble.left",
                        style: .tool,
                        size: .regular,
                        isSelected: false,
                        isEnabled: true,
                        action: { model.insertReplySuggestion(at: pair.offset) }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .frame(height: Theme.Sizing.aiChipHeight + Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .accessibilityElement(children: .contain)
    }
}
