//
//  PillChip.swift
//  墨语 · 宿主 App 组件
//
//  L1 原子组件：**全项目唯一胶囊组件**（契约 §2.1）。
//  AI 能力、语气、Provider 预设、只读标签都用它，靠 `style` 区分视觉。
//
import SwiftUI

/// 胶囊组件。
///
/// 四种用途（契约 §2.1）：
/// - `.tool`：AI 工具条 / 能力选择，高 30，玻璃底 + 描边；
/// - `.tone`：语气选择，高 30，选中为强调色实底；
/// - `.tag`：只读标签（型号 / 状态），高 22，小圆角；
/// - `.provider`：Provider 预设，高 32，选中为强调色浅底。
struct PillChip: View {

    /// 胶囊用途。
    enum Style {
        case tool
        case tone
        case tag
        case provider
    }

    /// 胶囊尺寸。
    enum Size {
        case regular
        case compact
    }

    /// 标题。
    let title: String

    /// SF Symbol（与 `emoji` 二选一，`emoji` 优先）。
    var systemImage: String?

    /// Emoji（与 `systemImage` 二选一，优先显示）。
    var emoji: String?

    /// 用途。
    var style: Style

    /// 尺寸。
    var size: Size

    /// 是否选中。
    var isSelected: Bool

    /// 是否可用。
    var isEnabled: Bool

    /// 点击回调。
    var action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        emoji: String? = nil,
        style: Style = .tool,
        size: Size = .regular,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.emoji = emoji
        self.style = style
        self.size = size
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            playHaptic()
            action()
        } label: {
            shapedContent
        }
        .buttonStyle(ChipPressStyle(isActive: !isSelected && isEnabled))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 外观

    /// 内容 + 背景 + 描边 + 裁剪（按 `style` 选择胶囊或小圆角矩形）。
    @ViewBuilder
    private var shapedContent: some View {
        if style == .tag {
            contentBody
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous))
        } else {
            contentBody
                .background(background)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .clipShape(Capsule(style: .continuous))
        }
    }

    /// 内容行（图标 + 文字），不含背景。
    private var contentBody: some View {
        HStack(spacing: AppMetrics.chipIconGap) {
            if let emoji {
                Text(emoji)
                    .font(AppFont.chip)
            } else if let systemImage {
                IconGlyph(symbol: systemImage, fallback: "", size: AppMetrics.glyphSizeSmall)
            }
            Text(title)
                .font(textFont)
                .lineLimit(1)
        }
        .foregroundColor(foreground)
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .contentShape(Rectangle())
    }

    /// 文字字号。
    private var textFont: Font {
        if size == .compact {
            return AppFont.caption
        }
        return style == .tag ? AppFont.caption : AppFont.chip
    }

    /// 固定高度（契约 §2.1）。
    private var height: CGFloat {
        switch style {
        case .tool, .tone:
            return size == .compact ? AppMetrics.chipHeight - AppMetrics.tightGap : AppMetrics.chipHeight
        case .tag:
            return AppMetrics.chipHeightTag
        case .provider:
            return size == .compact ? AppMetrics.chipHeightProvider - AppMetrics.tightGap : AppMetrics.chipHeightProvider
        }
    }

    /// 横向内边距。
    private var horizontalPadding: CGFloat {
        switch style {
        case .tag:
            return AppMetrics.tightGap + AppMetrics.hairGap
        case .tone, .tool, .provider:
            return AppMetrics.rowVPadding
        }
    }

    /// 描边宽度（有描边的样式为 1pt，其余为 0）。
    private var borderWidth: CGFloat {
        switch style {
        case .tone, .tag:
            return 0
        case .tool, .provider:
            return AppMetrics.hairline * 2
        }
    }

    /// 描边颜色（宽度为 0 时不起作用）。
    private var borderColor: Color {
        switch style {
        case .tool:
            return AppColor.chipBorder
        case .tone, .tag:
            return Color.clear
        case .provider:
            return isSelected ? Theme.accent.opacity(0.45) : Theme.separator
        }
    }

    /// 前景色。
    private var foreground: Color {
        switch style {
        case .tool:
            return AppColor.chipText
        case .tone:
            return isSelected ? AppColor.onAccent : Theme.textPrimary
        case .tag:
            return Theme.accent
        case .provider:
            return isSelected ? Theme.accent : Theme.textPrimary
        }
    }

    /// 背景。
    private var background: Color {
        switch style {
        case .tool:
            return AppColor.chipFill
        case .tone:
            return isSelected ? Theme.accent : AppColor.chipFill
        case .tag:
            return Theme.accentSoft
        case .provider:
            return isSelected ? Theme.accentSoft : Color.clear
        }
    }

    /// 触感。
    private func playHaptic() {
        switch style {
        case .tone:
            Haptics.selection()
        case .tool, .provider, .tag:
            Haptics.light()
        }
    }
}

/// 胶囊按压反馈：缩放 0.96 + 亮度降低（契约 §2.1 / §5）。
private struct ChipPressStyle: ButtonStyle {

    /// 是否启用缩放（选中态不缩放，避免抖动）。
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isActive ? 0.96 : 1)
            .brightness(configuration.isPressed && isActive ? -0.06 : 0)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

#if DEBUG
struct PillChip_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            HStack(spacing: AppMetrics.blockGap) {
                PillChip("润色", emoji: "✨", action: {})
                PillChip("翻译", systemImage: "globe", action: {})
            }
            HStack(spacing: AppMetrics.blockGap) {
                PillChip("自然", style: .tone, isSelected: true, action: {})
                PillChip("简洁", style: .tone, action: {})
            }
            HStack(spacing: AppMetrics.blockGap) {
                PillChip("默认", style: .tag, action: {})
                PillChip("DeepSeek", style: .provider, isSelected: true, action: {})
                PillChip("Kimi", style: .provider, action: {})
            }
        }
        .padding(AppMetrics.pageInset)
        .background(AppColor.pageBackground)
    }
}
#endif
