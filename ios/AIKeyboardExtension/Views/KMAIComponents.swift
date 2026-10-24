//
//  KMAIComponents.swift
//  墨语（Moyu）键盘扩展 · AI 通用小组件
//
//  模块职责：AI 面板与结果卡片共用的小组件，避免重复实现：
//            `KMStreamingText`（打字机文本 + 光标）、`KMProgressDots`（三点加载）、
//            `KMProgressRing`（生图进度环）、`KMToneSelector`（语气选择）、
//            `KMPrimaryButton` / `KMSecondaryButton`（主次按钮）、
//            `KMErrorBanner`（错误条）、`KMSheetHeader`（面板头部）、`KMEmptyState`。
//  设计依据：design/组件库.md 同名组件（实现层加 `KM` 前缀，App target 已占用原名）。
//  约束：所有颜色 / 字体 / 间距来自 `Theme`；iOS 16 可用 API；不使用 iOS 17 的 `.rect(cornerRadius:)`。
//

import SwiftUI

// MARK: - 流式文本

/// 打字机文本（流式中末尾带闪烁光标，空内容显示三点加载）。
struct KMStreamingText: View {

    /// 文本内容。
    let text: String

    /// 是否正在流式输出。
    let isStreaming: Bool

    /// 字体。
    var font: Font = Theme.fontResult

    /// 最大高度（超出内部滚动，绝不撑高键盘）。
    var maxHeight: CGFloat = KMLayout.resultBodyHeight

    /// 光标闪烁状态。
    @State private var cursorVisible: Bool = true

    var body: some View {
        Group {
            if text.isEmpty && isStreaming {
                HStack(spacing: Theme.Spacing.sm) {
                    KMProgressDots()
                    Text("正在思考…")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 2) {
                        Text(text)
                            .font(font)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        if isStreaming {
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: 2, height: 18)
                                .opacity(cursorVisible ? 1 : 0.2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: maxHeight, alignment: .topLeading)
        .onAppear(perform: startCursorBlinkIfNeeded)
        .onChange(of: isStreaming) { streaming in
            if streaming { startCursorBlinkIfNeeded() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isStreaming ? "正在生成" : text))
    }

    /// 启动光标闪烁（Reduce Motion 时保持常亮，不闪烁）。
    private func startCursorBlinkIfNeeded() {
        guard isStreaming, !KMAnimation.isReduceMotionEnabled else {
            cursorVisible = true
            return
        }
        cursorVisible = true
        withAnimation(
            Animation.easeInOut(duration: Theme.Motion.streamCursorBlink)
                .repeatForever(autoreverses: true)
        ) {
            cursorVisible = false
        }
    }
}

// MARK: - 三点加载

/// 三个循环缩放的圆点。
struct KMProgressDots: View {

    /// 圆点直径。
    var size: CGFloat = Theme.Spacing.sm

    /// 是否播放（Reduce Motion 时静止）。
    @State private var animating: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs + Theme.Spacing.xs) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: size, height: size)
                    .opacity(animating ? 1.0 : 0.35)
                    .animation(
                        KMAnimation.isReduceMotionEnabled
                            ? nil
                            : Animation.easeInOut(duration: Theme.Motion.fast).repeatForever().delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}

// MARK: - 进度环

/// 环形进度（生图绘制中，配合每秒已等待时间使用；不用无限转圈的 ProgressView）。
struct KMProgressRing: View {

    /// 环直径。
    var size: CGFloat = Theme.Spacing.xxxl + Theme.Spacing.xl

    /// 线宽。
    var lineWidth: CGFloat = Theme.Spacing.sm - Theme.Spacing.xs / 2

    /// 进度（0…1）；nil 表示不确定进度（缓慢自转）。
    var progress: Double?

    /// 旋转角度（不确定进度时使用）。
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.separator, lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(min(progress, 1), 0))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                    .onAppear(perform: startRotationIfNeeded)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 启动缓慢自转（Reduce Motion 下不转）。
    private func startRotationIfNeeded() {
        guard !KMAnimation.isReduceMotionEnabled else { return }
        rotation = 0
        withAnimation(Animation.linear(duration: Theme.Motion.toastDuration).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

// MARK: - 语气选择

/// 语气选择行（横向滚动的胶囊）。
struct KMToneSelector: View {

    /// 可选语气。
    var tones: [String] = KMToneSelector.defaultTones

    /// 当前选中语气。
    let selected: String

    /// 选择回调。
    let onSelect: (String) -> Void

    /// 默认语气（PRD §4.1：自然 / 简洁 / 礼貌 / 正式 / 热情）。
    static let defaultTones: [String] = ["自然", "简洁", "礼貌", "正式", "热情"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Sizing.aiChipGap) {
                ForEach(tones, id: \.self) { tone in
                    KMPillChip(
                        title: tone,
                        style: .tone,
                        size: .regular,
                        isSelected: tone == selected,
                        isEnabled: true,
                        action: { onSelect(tone) }
                    )
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .frame(height: KMLayout.panelToneRowHeight)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 按钮

/// 主按钮（accent 底，高度按档位）。
struct KMPrimaryButton: View {

    /// 标题。
    let title: String

    /// 图标（可选）。
    var systemImage: String?

    /// 是否可用。
    var isEnabled: Bool = true

    /// 是否加载中。
    var isLoading: Bool = false

    /// 高度档位。
    var height: CGFloat = Theme.Sizing.minTapTarget

    /// 是否占满宽度。
    var fullWidth: Bool = false

    /// 点击回调。
    let action: () -> Void

    var body: some View {
        Button(action: {
            guard isEnabled, !isLoading else { return }
            KMHaptics.chip()
            action()
        }) {
            HStack(spacing: Theme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.textOnAccent)
                        .scaleEffect(0.7)
                } else if let systemImage {
                    KMIconGlyph(symbol: systemImage, fallback: "", size: 15, tint: Theme.textOnAccent)
                }
                Text(title)
                    .font(Theme.fontButton)
                    .foregroundColor(Theme.textOnAccent)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, fullWidth ? 0 : Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accent)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.97, pressedOpacity: 0.9))
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
    }
}

/// 次按钮（chip 底 + 主文字色）。
struct KMSecondaryButton: View {

    /// 标题。
    let title: String

    /// 图标（可选）。
    var systemImage: String?

    /// 是否可用。
    var isEnabled: Bool = true

    /// 高度档位。
    var height: CGFloat = Theme.Spacing.xxl + Theme.Spacing.lg

    /// 点击回调。
    let action: () -> Void

    var body: some View {
        Button(action: {
            guard isEnabled else { return }
            KMHaptics.chip()
            action()
        }) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    KMIconGlyph(symbol: systemImage, fallback: "", size: 13, tint: Theme.textPrimary)
                }
                Text(title)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(height: height)
            .padding(.horizontal, Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.chipBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.97, pressedOpacity: 0.9))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 错误条

/// 错误 / 警告 / 提示条（键盘内高度上限 72）。
struct KMErrorBanner: View {

    /// 级别。
    enum Severity {
        /// 错误。
        case error
        /// 警告。
        case warning
        /// 提示。
        case info
    }

    /// 级别。
    let severity: Severity

    /// 标题。
    let title: String

    /// 说明（可选）。
    var message: String?

    /// 操作按钮标题（可选）。
    var actionTitle: String?

    /// 操作回调（可选）。
    var onAction: (() -> Void)?

    /// 关闭回调（可选）。
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            KMIconGlyph(symbol: iconName, fallback: "!", size: 16, tint: iconColor)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.fontBody)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let onAction {
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(Theme.fontCaption)
                            .fontWeight(.semibold)
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(actionTitle))
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    KMIconGlyph(symbol: "xmark", fallback: "✕", size: 12, tint: Theme.textTertiary)
                        .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
                }
                .buttonStyle(KMPressableStyle())
                .accessibilityLabel(Text("关闭提示"))
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: 72, alignment: .topLeading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .padding(.horizontal, Theme.Spacing.xl)
    }

    /// 图标名。
    private var iconName: String {
        switch severity {
        case .error:
            return "exclamationmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    /// 图标颜色。
    private var iconColor: Color {
        switch severity {
        case .error:
            return Theme.danger
        case .warning:
            return Theme.warning
        case .info:
            return Theme.accent
        }
    }

    /// 背景色。
    private var backgroundColor: Color {
        switch severity {
        case .error:
            return Theme.dangerSoft
        case .warning:
            return Theme.warningSoft
        case .info:
            return Theme.accentSoft
        }
    }
}

// MARK: - 面板头部

/// 面板头部（抓手上 + 标题 + 关闭按钮）。
struct KMSheetHeader: View {

    /// 标题。
    let title: String

    /// 副标题（可选）。
    var subtitle: String?

    /// 是否显示关闭按钮。
    var showsClose: Bool = true

    /// 关闭回调。
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.fontHeadline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if showsClose {
                Button(action: {
                    KMHaptics.chip()
                    onClose()
                }) {
                    KMIconGlyph(symbol: "xmark.circle.fill", fallback: "✕", size: 20, tint: Theme.textTertiary)
                        .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
                }
                .buttonStyle(KMPressableStyle())
                .accessibilityLabel(Text("关闭"))
            }
        }
        .frame(height: KMLayout.settingsHeaderHeight)
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

// MARK: - 空态

/// 紧凑空态（图标 + 标题 + 说明）。
struct KMEmptyState: View {

    /// 图标（SF Symbol）。
    var systemImage: String = "sparkles"

    /// 图标兜底文字。
    var fallback: String = "✨"

    /// 标题。
    let title: String

    /// 说明（可选）。
    var message: String?

    /// 操作按钮标题（可选）。
    var actionTitle: String?

    /// 操作回调（可选）。
    var onAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            KMIconGlyph(symbol: systemImage, fallback: fallback, size: 20, tint: Theme.textTertiary)
            Text(title)
                .font(Theme.fontBody)
                .fontWeight(.medium)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let message, !message.isEmpty {
                Text(message)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedsizeIfAvailable()
            }
            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(Theme.fontCaption)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(actionTitle))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message.map { "\(title)，\($0)" } ?? title))
    }
}

// MARK: - 小工具

private extension View {

    /// 让说明文字在窄高度里换行而不被压缩（保持调用点可读性）。
    func fixedsizeIfAvailable() -> some View {
        self.fixedSize(horizontal: false, vertical: true)
    }
}
