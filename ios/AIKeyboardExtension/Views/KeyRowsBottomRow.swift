//
//  KeyRowsBottomRow.swift
//  AIKeyboardExtension
//
//  字母页第 4 行（🌐 / 空格 / 🙂 / ⏎ / 可选小形象角落格）。
//
//  为什么单独成文件：这一行既有「宽度分配」（有小形象时空格要让位给角落格，
//  但要吸收 382 与 384 之间那 2pt 的取整差），又有主题主色（回车键是
//  design/05 §1.1 允许的 4 处主色之一），逻辑比上面三行复杂，单独放更好维护。
//
//  设计依据：design/键盘布局规范.md §2.4（底行尺寸）、
//            design/05-主题与小形象规范.md §3.2（小形象角落格尺寸）。
//

import SwiftUI

// MARK: - 底行

/// 字母页第 4 行。
///
/// 布局：`[🌐 42] [空格 弹性] [🙂 42] [⏎ 88] ( [形象格 30/26] )`，间距 `KMLayout.keyGap`。
///
/// 尺寸说明：`42 + 42 + 156 + 88 + 30 + 6 × 4 = 382`，比内容宽 384 少 2pt，
/// 因此空格键始终是弹性宽度，由它吸收这 2pt（390pt 屏上实际 158pt），
/// 这样行尾不会出现缝隙，形象格与右边距也能对齐。
struct KeyRowsBottomRow: View {

    /// 是否横屏（形象格与图标尺寸不同）。
    let isLandscape: Bool

    /// 行高。
    let height: CGFloat

    /// 主题主色（回车键底色）。
    var accent: Color = Theme.accent

    /// 小形象配置（`nil` 表示不显示）。
    var mascot: KMMascotConfig? = nil

    /// 按键回调。
    let onTap: (KeyboardKey) -> Void

    var body: some View {
        HStack(spacing: KMLayout.keyGap) {
            globeKey
            spaceKey
            emojiKey
            returnKey
            if let mascot {
                mascotCornerCell(mascot)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 四个固定键

    /// 地球键（切换键盘）。
    private var globeKey: some View {
        functionKey(
            icon: "globe",
            fallback: "🌐",
            width: KMLayout.functionKeyWidth,
            accessibility: "切换键盘"
        ) {
            onTap(.globe)
        }
    }

    /// 空格键（弹性宽度，吸收取整差）。
    private var spaceKey: some View {
        Button(action: {
            KMHaptics.key()
            onTap(.space)
        }) {
            Text("空格")
                .font(Theme.fontBody)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(Theme.keyBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: .space))
        .accessibilityLabel(Text("空格"))
        .accessibilityAddTraits(.isKeyboardKey)
    }

    /// 表情键（切到 emoji 页）。
    private var emojiKey: some View {
        functionKey(
            icon: "face.smiling",
            fallback: "🙂",
            width: KMLayout.functionKeyWidth,
            accessibility: "表情"
        ) {
            onTap(.pageEmoji)
        }
    }

    /// 回车键（主题主色底 + 白图标）。
    private var returnKey: some View {
        Button(action: {
            KMHaptics.rigid()
            onTap(.newline)
        }) {
            KMIconGlyph(symbol: "return", fallback: "⏎", size: 18, tint: Theme.textOnAccent)
                .frame(width: KMLayout.returnKeyWidth, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(accent)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: .accent))
        .accessibilityLabel(Text("回车"))
        .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: - 小形象角落格

    /// 小形象角落格（参与 HStack 布局，绝不浮在回车键上）。
    /// - Parameter config: 小形象配置。
    private func mascotCornerCell(_ config: KMMascotConfig) -> some View {
        KMMascotView(
            size: isLandscape ? KMLayout.mascotVisualSizeLandscape : KMLayout.mascotVisualSize,
            symbol: config.symbol,
            isBusy: config.isBusy,
            accent: config.accent
        )
        .frame(
            width: isLandscape ? KMLayout.mascotCornerWidthLandscape : KMLayout.mascotCornerWidth,
            height: height
        )
        .padding(.trailing, KMLayout.mascotTrailingInset)
        .padding(.leading, KMLayout.mascotReturnSpacing)
        .accessibilityHidden(true)
    }

    // MARK: - 复用键构建

    /// 功能键（图标 + 文字兜底），与 `KeyRowsView` 上的同名实现保持视觉一致。
    /// - Parameters:
    ///   - icon: SF Symbol 名。
    ///   - fallback: 图标不可用时的文字。
    ///   - width: 键宽。
    ///   - accessibility: 无障碍文案。
    ///   - action: 点击回调。
    private func functionKey(
        icon: String,
        fallback: String,
        width: CGFloat,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            KMHaptics.function()
            action()
        }) {
            KMIconGlyph(symbol: icon, fallback: fallback, size: 17, tint: Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(Theme.keyFunctionBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: .function))
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(.isKeyboardKey)
    }
}
