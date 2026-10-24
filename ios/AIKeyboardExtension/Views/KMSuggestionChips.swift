//
//  KMSuggestionChips.swift
//  墨语（Moyu）键盘扩展 · AI 联想胶囊
//
//  模块职责：候选栏里的「你可能想说的下一句」胶囊（design/04 §4.3）。
//            与拼音候选互斥展示：组合态显示候选，非组合态显示联想（无联想才回退传统候选）。
//  设计依据：design/04-AI对话与智能联想规范.md §4.3（视觉）、§8（无障碍）。
//  约束：高 30、水平内边距 12、capsule；底 chip.bg；唯一强区分是 1pt `accent.opacity(0.35)` 描边；
//        左侧 sparkles 11pt accent；≤3 条、每条 ≤12 字超尾部省略；出现动效 0.2s，消失无退场。
//

import SwiftUI

// MARK: - 单个联想胶囊

/// AI 联想胶囊。
struct KMSuggestionChip: View {

    /// 文案（≤12 字，超长由上游截断）。
    let title: String

    /// 点击回调。
    let action: () -> Void

    /// 左侧图标（`sparkles`，iOS 16 不存在时降级为 ✨）。
    private var icon: KMIconGlyph {
        KMIconGlyph(
            symbol: "sparkles",
            fallback: "✨",
            size: 11,  // TOKEN: typography.caption.size - 1（11pt 图标，与 13pt 文字视觉平衡）
            weight: .medium,
            tint: Theme.accent
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                icon
                Text(title)
                    .font(Theme.fontChip)
                    .foregroundColor(Theme.chipText)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: KMLayout.sugChipHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.chipBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: Theme.MaterialToken.strokeWidth)
            )
            // 命中区 44：视觉 30，上下各外扩 7pt（design/04 §8「所有可点 ≥44」）。
            .frame(minHeight: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.96, duration: Theme.Motion.fast))
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text("点击直接上屏"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 胶囊组

/// 联想胶囊组（横向滚动，从候选滚动区最左端起排）。
struct KMSuggestionChipRow: View {

    /// 胶囊文案（最多 3 条）。
    let titles: [String]

    /// 点击某条（参数为下标）。
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: KMLayout.sugChipGap) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { pair in
                        KMSuggestionChip(title: pair.element) {
                            onSelect(pair.offset)
                        }
                        .id(pair.offset)
                    }
                }
                .padding(.leading, Theme.Spacing.xl)
                .padding(.trailing, Theme.Spacing.md)
            }
            .onChange(of: titles) { _ in
                // iOS 16 单参数版；文案整体变化时回到最左（新一批联想从头看）。
                proxy.scrollTo(0, anchor: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("AI 联想，共 \(titles.count) 条"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 确认弹层

/// 键盘内轻量确认弹层（design/04 §3.3「清空当前对话？」）。
///
/// 说明：扩展内不能用 `UIAlertController`（键盘窗口层级不稳、易被系统吞掉），
/// 因此用 SwiftUI 遮罩 + 卡片自绘；高度由调用方在固定面板内叠加，不改变键盘高度。
struct KMConfirmation: View {

    /// 标题。
    let title: String

    /// 说明文案。
    var message: String?

    /// 确认按钮标题。
    var confirmTitle: String = "确认"

    /// 取消按钮标题。
    var cancelTitle: String = "取消"

    /// 确认回调。
    let onConfirm: () -> Void

    /// 取消回调。
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Theme.overlayScrim.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: Theme.Spacing.md) {
                Text(title)
                    .font(Theme.fontHeadline)
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Spacing.md) {
                    KMSecondaryButton(title: cancelTitle, isEnabled: true, height: Theme.Sizing.minTapTarget) {
                        onCancel()
                    }
                    KMPrimaryButton(title: confirmTitle, isEnabled: true, height: Theme.Sizing.minTapTarget) {
                        onConfirm()
                    }
                }
            }
            .padding(Theme.Spacing.xl)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
            )
            .padding(.horizontal, Theme.Spacing.xxl)
            .transition(.opacity)
        }
        .accessibilityElement(children: .contain)
    }
}
