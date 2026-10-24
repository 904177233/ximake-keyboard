//
//  EmptyState.swift
//  墨语 · 宿主 App 组件
//
//  空态提示（契约：design/组件库.md §4.4）。
//
import SwiftUI

/// 空态视图：图标 + 标题 + 说明 + 可选按钮。
struct EmptyState: View {

    private let symbol: String
    private let fallbackEmoji: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let isCompact: Bool

    init(
        symbol: String,
        fallbackEmoji: String = "",
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        compact: Bool = false
    ) {
        self.symbol = symbol
        self.fallbackEmoji = fallbackEmoji
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.isCompact = compact
    }

    var body: some View {
        if isCompact {
            compactBody
        } else {
            fullBody
        }
    }

    /// 全屏空态。
    private var fullBody: some View {
        VStack(spacing: AppMetrics.blockGap) {
            Circle()
                .fill(Theme.surfaceElevated)
                .frame(width: AppMetrics.emptyIconBox, height: AppMetrics.emptyIconBox)
                .overlay(
                    IconGlyph(
                        symbol: symbol,
                        fallback: fallbackEmoji,
                        size: AppMetrics.glyphSizeLarge,
                        tint: Theme.textTertiary
                    )
                )

            Text(title)
                .font(AppFont.pageTitle)
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(AppFont.body)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                PrimaryButton(
                    title: actionTitle,
                    tone: .accent,
                    size: .medium,
                    fullWidth: false,
                    action: action
                )
                .padding(.top, AppMetrics.tightGap)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxxl)
        .frame(maxWidth: .infinity)
    }

    /// 紧凑空态（卡片内 / 小组件里）。
    private var compactBody: some View {
        HStack(spacing: AppMetrics.rowGap) {
            IconGlyph(
                symbol: symbol,
                fallback: fallbackEmoji,
                size: AppMetrics.glyphSize + AppMetrics.hairGap,
                tint: Theme.textTertiary
            )
            Text(title)
                .font(AppFont.body.weight(.medium))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppMetrics.rowVPadding)
        .frame(minHeight: AppMetrics.heroIcon * 2)
    }
}

#if DEBUG
struct EmptyState_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.sectionGap) {
            EmptyState(
                symbol: "server.rack",
                fallbackEmoji: "🗄",
                title: "还没有 AI 服务",
                message: "添加一个服务商，键盘里的 AI 才能用",
                actionTitle: "添加服务",
                action: {}
            )
            EmptyState(
                symbol: "keyboard",
                fallbackEmoji: "⌨️",
                title: "还没有添加键盘",
                message: "按 3 步完成设置",
                compact: true
            )
        }
        .padding()
        .background(AppColor.pageBackground)
    }
}
#endif
