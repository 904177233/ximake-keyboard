//
//  KMPillChip.swift
//  墨语（Moyu）键盘扩展 · 胶囊按钮
//
//  模块职责：键盘域唯一的胶囊组件（设计层名 `PillChip`，实现层加 `KM` 前缀，
//            因为宿主 App target 已占用 `PillChip` 这个名字，同名会触发静态检查 DUP-DECL）。
//  设计依据：design/组件库.md「PillChip」：tool 高 30 / capsule / chipBackground /
//            chipBorder 1pt / 图标 13pt + 文字 13pt medium / 横向内边距 12 / 间距 5；
//            tone 选中 accent + textOnAccent；tag 高 22 圆角 small；provider 高 32。
//  约束：键盘内固定字号，不随 Dynamic Type 缩放。
//

import SwiftUI

/// 胶囊按钮样式。
enum KMPillChipStyle {
    /// AI 工具条等「操作型」胶囊。
    case tool
    /// 语气选择胶囊（有选中态）。
    case tone
    /// 小标签。
    case tag
    /// 服务商胶囊（有选中态）。
    case provider
}

/// 胶囊尺寸档位。
enum KMPillChipSize {
    /// 常规（tool / tone / provider）。
    case regular
    /// 小号（tag）。
    case small
}

/// 胶囊按钮。
struct KMPillChip: View {

    /// 标题。
    let title: String

    /// 首选系统图标名。
    var systemImage: String?

    /// 图标兜底字符（emoji）。
    var emoji: String?

    /// 样式。
    var style: KMPillChipStyle = .tool

    /// 尺寸。
    var size: KMPillChipSize = .regular

    /// 是否选中。
    var isSelected: Bool = false

    /// 是否可用。
    var isEnabled: Bool = true

    /// 点击回调。
    let action: () -> Void

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: chipIconTextGap) {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: iconFontSize))
                } else if let systemImage, !systemImage.isEmpty {
                    KMIconGlyph(symbol: systemImage, fallback: "", size: iconFontSize, tint: foregroundColor)
                }
                Text(title)
                    .font(titleFont)
                    .lineLimit(1)
                    .foregroundColor(foregroundColor)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: chipHeight)
            .frame(minHeight: Theme.Sizing.minTapTarget, alignment: .center)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(KMPressableStyle(scale: isSelected ? 1.0 : 0.96, pressedOpacity: isSelected ? 1.0 : 0.94))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityHint(isEnabled ? Text("") : Text("当前不可用"))
    }

    // MARK: - 视觉

    /// 胶囊视觉高度（命中区由外层 `minHeight: 44` 保证）。
    private var chipHeight: CGFloat {
        switch style {
        case .tool, .tone:
            return Theme.Sizing.aiChipHeight
        case .tag:
            return 22  // TOKEN: design/组件库.md tag 高 22
        case .provider:
            return 32  // TOKEN: design/组件库.md provider 高 32
        }
    }

    /// 横向内边距（token: spacing.lg = 12）。
    private var horizontalPadding: CGFloat {
        size == .small ? Theme.Spacing.md : Theme.Spacing.lg
    }

    /// 图标与文字间距（token: spacing.sm = 4，设计稿为 5，取令牌值）。
    private var chipIconTextGap: CGFloat {
        Theme.Spacing.sm
    }

    /// 文字字体（键盘域固定字号，不随 Dynamic Type 缩放）。
    private var titleFont: Font {
        switch style {
        case .tool, .tone:
            return Theme.fontChip
        case .tag:
            return .system(size: 12, weight: .medium)  // TOKEN: typography.caption.size = 12
        case .provider:
            return Theme.fontFootnote
        }
    }

    /// 图标字号（token: typography.chip.size = 13）。
    private var iconFontSize: CGFloat {
        13  // TOKEN: typography.chip.size
    }

    /// 前景色。
    private var foregroundColor: Color {
        switch style {
        case .tool:
            return Theme.chipText
        case .tone:
            return Theme.textPrimary
        case .tag:
            return Theme.textPrimary
        case .provider:
            return Theme.textPrimary
        }
    }

    /// 背景。
    @ViewBuilder
    private var background: some View {
        switch style {
        case .tool:
            Theme.chipBackground
        case .tone:
            isSelected ? Theme.keyFunctionBackground : Theme.chipBackground.opacity(0.4)
        case .tag:
            Theme.chipBackground
        case .provider:
            isSelected ? Theme.keyFunctionBackground : Theme.chipBackground
        }
    }

    /// 描边（tool / provider 需要）。
    @ViewBuilder
    private var border: some View {
        if style == .tool || style == .provider {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.chipBorder, lineWidth: Theme.MaterialToken.strokeWidth)
        } else {
            EmptyView()
        }
    }

    // MARK: - 动作

    /// 点击处理（触感 + 回调）。
    private func handleTap() {
        guard isEnabled else { return }
        KMHaptics.chip()
        action()
    }
}
