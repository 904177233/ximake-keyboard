//
//  AIBar.swift
//  墨语（Moyu）键盘扩展 · AI 工具条（签名元素）
//
//  模块职责：横向滚动的玻璃胶囊能力条。40pt 固定高，chip 高 30、间距 8、
//            左右各 24pt 渐变遮罩产生「边缘渐隐」；最后一个胶囊固定为「⚙️ 设置」。
//            禁用时整条 opacity 0.55 并把三分支提示替换为能力列表（三态文案用设计原句）。
//  设计依据：design/组件库.md「AIBar」、design/键盘布局规范.md §5 状态 ⑨⑩⑪。
//  约束：横屏时折叠为候选栏右侧 32×32 玻璃圆钮（由 `landscapeCompact` 触发）。
//

import SwiftUI

/// AI 工具条中的一个能力胶囊。
struct KMAIBarItem: Identifiable, Equatable {

    /// 稳定标识。
    let id: String

    /// 对应能力。
    let feature: AIFeature

    /// 标题（中文）。
    let title: String

    /// 图标 emoji。
    let emoji: String

    /// 默认能力列表（与 PRD §4.1 一致）。
    static let defaults: [KMAIBarItem] = [
        KMAIBarItem(id: "polish", feature: .polish, title: "润色", emoji: "✨"),
        KMAIBarItem(id: "expand", feature: .expand, title: "扩写", emoji: "💬"),
        KMAIBarItem(id: "translate", feature: .translate, title: "翻译", emoji: "🌐"),
        KMAIBarItem(id: "reply", feature: .replySuggestion, title: "回复", emoji: "🧠"),
        KMAIBarItem(id: "image", feature: .image, title: "生图", emoji: "🎨")
    ]
}

/// AI 工具条。
struct AIBar: View {

    /// 能力胶囊列表。
    var items: [KMAIBarItem] = KMAIBarItem.defaults

    /// 当前可用性。
    let availability: KeyboardViewModel.AIAvailability

    /// 是否正在生成（生成中禁用能力胶囊，避免并发请求）。
    let isBusy: Bool

    /// 是否横屏折叠（折叠成 32×32 圆钮）。
    let landscapeCompact: Bool

    /// 当前正在处理的能力（生成中用于高亮对应胶囊）。
    var activeFeature: AIFeature?

    /// 选择能力。
    let onSelect: (AIFeature) -> Void

    /// 打开键盘内设置。
    let onOpenSettings: () -> Void

    /// 展开 AI 面板（横屏圆钮点击）。
    let onOpenPanel: () -> Void

    /// 点击禁用提示区。
    let onDisabledTap: () -> Void

    var body: some View {
        if landscapeCompact {
            compactButton
        } else {
            regularBar
        }
    }

    // MARK: - 常规形态

    /// 常规 40pt 工具条。
    private var regularBar: some View {
        ZStack {
            content
            edgeMasks
        }
        .frame(height: Theme.Sizing.aiBarHeight)
    }

    /// 内容（能力胶囊 + 设置胶囊，或禁用提示）。
    @ViewBuilder
    private var content: some View {
        if let reason = disabledReason {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Sizing.aiChipGap) {
                    Button(action: onDisabledTap) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(reason.message)
                                .font(Theme.fontChip)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                            KMIconGlyph(symbol: "chevron.right", fallback: "›", size: 11, tint: Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(height: Theme.Sizing.aiChipHeight)
                        .frame(minHeight: Theme.Sizing.minTapTarget)
                        .background(Theme.chipBackground)
                        .overlay(
                            Capsule().strokeBorder(Theme.chipBorder, lineWidth: Theme.MaterialToken.strokeWidth)
                        )
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(KMPressableStyle(scale: 0.97, pressedOpacity: 0.9))
                    .accessibilityLabel(Text(reason.message))
                }
                .padding(.horizontal, Theme.Sizing.aiBarInset)
            }
            .opacity(0.55)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Sizing.aiChipGap) {
                    ForEach(items) { item in
                        KMPillChip(
                            title: item.title,
                            emoji: item.emoji,
                            style: .tool,
                            size: .regular,
                            isSelected: activeFeature == item.feature,
                            isEnabled: isBusy == false,
                            action: { onSelect(item.feature) }
                        )
                    }
                    KMPillChip(
                        title: "设置",
                        emoji: "⚙️",
                        style: .tool,
                        size: .regular,
                        isSelected: false,
                        isEnabled: true,
                        action: onOpenSettings
                    )
                }
                .padding(.horizontal, Theme.Sizing.aiBarInset)
            }
        }
    }

    /// 左右边缘渐隐遮罩（24pt，颜色取实际背景色）。
    private var edgeMasks: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [Theme.keyboardBackground, Theme.keyboardBackground.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Theme.Sizing.aiBarFadeWidth)
            .allowsHitTesting(false)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [Theme.keyboardBackground.opacity(0), Theme.keyboardBackground],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Theme.Sizing.aiBarFadeWidth)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 横屏折叠形态

    /// 横屏 32×32 玻璃圆钮。
    private var compactButton: some View {
        Button(action: {
            KMHaptics.chip()
            onOpenPanel()
        }) {
            ZStack {
                Circle()
                    .fill(BusyOrEnabledColor(isBusy: isBusy, availability: availability).color)
                Circle()
                    .strokeBorder(Theme.chipBorder, lineWidth: Theme.MaterialToken.strokeWidth)
                Text("✨")
                    .font(.system(size: 14))  // TOKEN: typography.chip.size ≈ 14
            }
            .frame(width: Theme.Sizing.aiChipHeight + Theme.Spacing.xs, height: Theme.Sizing.aiChipHeight + Theme.Spacing.xs)
            .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.94, pressedOpacity: 0.9))
        .accessibilityLabel(Text("AI 助手"))
        .accessibilityHint(Text("展开 AI 面板"))
    }

    // MARK: - 状态推导

    /// 禁用原因（优先级：无完全访问 > 未配置 > 离线）。
    private var disabledReason: KMAIBarDisabledReason? {
        if isBusy { return nil }
        switch availability {
        case .noFullAccess:
            return KMAIBarDisabledReason(message: "开启完全访问后可用 AI", kind: .noFullAccess)
        case .notConfigured:
            return KMAIBarDisabledReason(message: "还没有配置 AI 服务 · 点此设置", kind: .notConfigured)
        case .offline:
            return KMAIBarDisabledReason(message: "网络未连接", kind: .offline)
        case .ready, .unknown, .busy:
            return nil
        }
    }
}

/// 工具条禁用态（标题 + 分类，供点击后决定引导去向）。
struct KMAIBarDisabledReason: Equatable {

    /// 禁用分类。
    enum Kind: Equatable {
        /// 未开启完全访问。
        case noFullAccess
        /// 未配置 AI 服务。
        case notConfigured
        /// 离线。
        case offline
    }

    /// 展示文案（设计原句）。
    let message: String

    /// 分类。
    let kind: Kind
}

/// 圆钮背景色的推导。
///
/// 说明：`.fill(_:)`、`.background(_:)` 等要求传入 `ShapeStyle`，而 `Color` 本身即
/// 遵循 `ShapeStyle`，故这里直接返回 `Color`（早期实现返回 `View` 导致找不到重载）。
private struct BusyOrEnabledColor {

    /// 是否生成中。
    let isBusy: Bool

    /// 可用性。
    let availability: KeyboardViewModel.AIAvailability

    /// 推导出的填充色。
    var color: Color {
        if isBusy {
            return Theme.accentSoft
        }
        if availability.canStartRequest {
            return Theme.chipBackground
        }
        return Theme.chipBackground.opacity(0.6)
    }
}
