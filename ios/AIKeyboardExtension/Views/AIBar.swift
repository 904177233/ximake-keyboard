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
import UIKit

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

    /// 展开 AI 面板（保留旧路径；横屏圆钮改为进入 AI 对话后仅供长按使用）。
    let onOpenPanel: () -> Void

    /// 进入 AI 对话面板（横屏圆钮的主路径，design/04 §2.8）。
    var onOpenChat: () -> Void = {}

    /// 点击禁用提示区。
    let onDisabledTap: () -> Void

    /// 是否显示「语音」胶囊（`KeyboardViewModel.canUseVoiceInput` 为 true 时由调用方置位）。
    ///
    /// 语音不是 `AIFeature`（它走麦克风 + 本地/端侧识别，不发给用户配置的 LLM），
    /// 因此单独一个回调，不塞进 `onSelect(feature)`。
    var showsVoice: Bool = false

    /// 点击「语音」胶囊。
    var onOpenVoice: () -> Void = {}

    /// 主题主色（design/05 §1.1：AI 工具条选中胶囊是 4 处主色之一）。
    var accent: Color = Theme.accent

    var body: some View {
        if landscapeCompact {
            compactButton
        } else {
            regularBar
        }
    }

    // MARK: - 常规形态

    /// 常规工具条（高度由父容器决定：v1.3 起与候选条共用 44pt 效用行）。
    private var regularBar: some View {
        ZStack {
            content
            edgeMasks
        }
        .frame(maxHeight: .infinity)
    }

    /// 内容（圆形图标按钮 + 设置 / 语音）。
    @ViewBuilder
    private var content: some View {
        if let reason = disabledReason {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Sizing.aiChipGap) {
                    Button(action: onDisabledTap) {
                        HStack(spacing: Theme.Spacing.sm) {
                            iconButtonGlyph(symbol: "lock.fill", fallback: "🔒", tint: Theme.textSecondary, size: 11)
                            Text(reason.message)
                                .font(Theme.fontChip)
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                            iconButtonGlyph(symbol: "chevron.right", fallback: "›", tint: Theme.textTertiary, size: 11)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(height: Theme.Sizing.aiChipHeight)
                        .frame(minHeight: Theme.Sizing.minTapTarget)
                        .background(Theme.chipBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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
                        iconButton(
                            symbol: item.feature.systemImage,
                            fallback: "•",
                            accessibility: item.title,
                            isSelected: activeFeature == item.feature,
                            isEnabled: isBusy == false,
                            action: { onSelect(item.feature) }
                        )
                    }
                    iconButton(
                        symbol: "gearshape",
                        fallback: "⚙",
                        accessibility: "设置",
                        isSelected: false,
                        isEnabled: true,
                        action: onOpenSettings
                    )
                    if showsVoice {
                        iconButton(
                            symbol: "mic",
                            fallback: "🎤",
                            accessibility: "语音输入",
                            isSelected: false,
                            isEnabled: isBusy == false,
                            action: onOpenVoice
                        )
                    }
                }
                .padding(.horizontal, Theme.Sizing.aiBarInset)
                .frame(height: Theme.Sizing.aiChipHeight + Theme.Spacing.md)
            }
        }
    }

    /// 圆形图标按钮（**只画图标，不放 emoji、不放文字**）。
    ///
    /// v1.4 修用户反馈「导航栏的图标依旧丑，居然省事到用 emoji，变成圆形图标，节省空间」：
    /// - 图形用 SF Symbol（矢量，跟随 Dynamic Type 与字重），无 SF Symbol 时退回文本字符兜底；
    /// - 容器恒为 32pt 圆，命中区扩到 44pt；
    /// - 未选中 = 无底色的图标；选中 = `accentSoft` 底 + 主色图标（主色只在这个位置出现）；
    /// - 按下用 `KMPressableStyle` 做 0.94 缩放，时长走 `Theme.Motion.fastAnimation`。
    private func iconButton(
        symbol: String,
        fallback: String,
        accessibility: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard isEnabled else { return }
            KMHaptics.chip()
            action()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.clear)
                iconButtonGlyph(
                    symbol: symbol,
                    fallback: fallback,
                    tint: isSelected ? Theme.accent : Theme.textSecondary,
                    size: 17
                )
            }
            .frame(width: Theme.Sizing.aiChipHeight, height: Theme.Sizing.aiChipHeight)
            .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(KMPressableStyle(scale: 0.94, pressedOpacity: 0.9))
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(Theme.Motion.fastAnimation, value: isSelected)
    }

    /// 图标字形：优先 SF Symbol，取不到时退回字符兜底。
    @ViewBuilder
    private func iconButtonGlyph(symbol: String, fallback: String, tint: Color, size: CGFloat) -> some View {
        if UIImage(systemName: symbol) != nil {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
        } else {
            Text(fallback)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(tint)
        }
    }

    /// 左右边缘渐隐遮罩（24pt，颜色取实际背景色）。
    private var edgeMasks: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [Theme.candidateBar, Theme.candidateBar.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Theme.Sizing.aiBarFadeWidth)
            .allowsHitTesting(false)

            Spacer(minLength: 0)

            LinearGradient(
                colors: [Theme.candidateBar.opacity(0), Theme.candidateBar],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Theme.Sizing.aiBarFadeWidth)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 横屏折叠形态

    /// 横屏 32×32 玻璃圆钮。
    ///
    /// 主路径改为「进入 AI 对话面板」（design/04 §2.8）：横屏隐藏独立 AIBar 后，
    /// 这里是 AI 入口；长按仍展开旧 AI 面板，保留旧路径不影响既有功能。
    private var compactButton: some View {
        Button(action: {
            KMHaptics.chip()
            onOpenChat()
        }) {
            ZStack {
                Circle()
                    .fill(BusyOrEnabledColor(isBusy: isBusy, availability: availability).color)
                Circle()
                    .strokeBorder(Theme.chipBorder, lineWidth: Theme.MaterialToken.strokeWidth)
                KMKnobGlyph(
                    size: KMLayout.aiChatKnobGlyphSize,
                    tint: availability.canStartRequest ? Theme.accent : Theme.textTertiary
                )
            }
            .frame(width: Theme.Sizing.aiChipHeight + Theme.Spacing.xs, height: Theme.Sizing.aiChipHeight + Theme.Spacing.xs)
            .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.94, pressedOpacity: 0.9))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onOpenPanel() }
        )
        .accessibilityLabel(Text("AI 对话"))
        .accessibilityHint(Text("打开墨语 AI 对话面板；长按展开 AI 能力面板"))
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
