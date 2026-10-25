//
//  KeyRowsBottomRow.swift
//  AIKeyboardExtension
//
//  字母页第 4 行（123 / 空格 / 🙂 / 回车 / 可选小形象角落格）。
//
//  为什么单独成文件：这一行既有「宽度分配」（有小形象时空格要让位给角落格，
//  但要吸收 382 与 384 之间那 2pt 的取整差），又有主题主色（回车键在「发送/搜索」
//  语义下才用主色），逻辑比上面三行复杂，单独放更好维护。
//
//  设计依据：design/键盘布局规范.md §2.4（底行尺寸）、
//            design/05-主题与小形象规范.md §3.2（小形象角落格尺寸）。
//
//  v1.3 两处用户反馈驱动的改动：
//  ① 「为什么要有这个（🌐），而没有数字键」→ 左下角改为 **123** 键（点按切数字页、
//     长按切下一个键盘）。切键盘仍然可达，但不再白占一颗最顺手的位置。
//  ② 「这个回车居然也被占用…不适合阻挡发送」→ 回车键按宿主 `returnKeyType` 变身：
//     聊天框显示「发送」、搜索框显示「搜索」，只有提交型语义才用主题主色，
//     普通文本框回到中性的「⏎ 换行」。
//

import SwiftUI

// MARK: - 底行

/// 字母页第 4 行。
///
/// 布局：`[123 42] [空格 弹性] [🙂 42] [⏎ 88] ( [形象格 30/26] )`，间距 `KMLayout.keyGap`。
///
/// 尺寸说明：`42 + 42 + 156 + 88 + 30 + 6 × 4 = 382`，比内容宽 384 少 2pt，
/// 因此空格键始终是弹性宽度，由它吸收这 2pt（390pt 屏上实际 158pt），
/// 这样行尾不会出现缝隙，形象格与右边距也能对齐。
struct KeyRowsBottomRow: View {

    /// 是否横屏（形象格与图标尺寸不同）。
    let isLandscape: Bool

    /// 行高。
    let height: CGFloat

    /// 主题主色（回车键在提交型语义下的底色）。
    var accent: Color = Theme.accent

    /// 回车键语义（聊天框=发送、搜索框=搜索、普通框=换行）。
    var returnKeyKind: KMReturnKeyKind = .newline

    /// 小形象配置（`nil` 表示不显示）。
    var mascot: KMMascotConfig? = nil

    /// 按键回调。
    let onTap: (KeyboardKey) -> Void

    var body: some View {
        HStack(spacing: KMLayout.keyGap) {
            numberKey
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

    /// 数字键：点按切到数字页，长按切下一个键盘。
    ///
    /// 右下角的位置原本放的是地球键。用户反馈「为什么要有这个，而没有数字键」——
    /// 主流输入法（微信、搜狗、Gboard）左下角都是 `123`，切键盘收进长按里。
    ///
    /// v1.4 修真实 bug（用户反馈「数字键盘完全没有用」）：上一版是 `Button` +
    /// `.highPriorityGesture(LongPressGesture)`，而 **highPriorityGesture 会抢走
    /// Button 的 tap** —— 结果只有长按 0.45s 有效，点按永远收不到 `.pageNumbers`。
    /// 这里改成不用 Button、自己用 `LongPressGesture.exclusively(before: TapGesture)`
    /// 组合：先等长按，松手够快就判定为点按。两条路径都显式发事件，不再互相抢。
    private var numberKey: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.keyFunctionBackground)
            Text("123")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textPrimary)
        }
        .frame(width: KMLayout.functionKeyWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    KMHaptics.function()
                    onTap(.globe)
                }
                .exclusively(
                    before: TapGesture().onEnded {
                        KMHaptics.function()
                        onTap(.pageNumbers)
                    }
                )
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("数字与符号"))
        .accessibilityHint(Text("长按切换输入法"))
        .accessibilityAddTraits(.isKeyboardKey)
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

    /// 回车键：语义跟随宿主输入框（发送 / 搜索 / 换行…）。
    ///
    /// 提交型语义（发送、搜索、前往、完成）用主题主色 + 中文词，
    /// 普通换行用中性功能键底色 + ⏎ 图标 —— 用户反馈「不适合阻挡发送」，
    /// 所以聊天框里这颗键必须长得像「发送」，而不是一颗抢戏的蓝色回车。
    private var returnKey: some View {
        Button(action: {
            KMHaptics.rigid()
            onTap(.newline)
        }) {
            Group {
                if let title = returnKeyKind.title {
                    Text(title)
                        .font(Theme.fontChip)
                        .foregroundColor(returnKeyKind.isPrimary ? Theme.textOnAccent : Theme.textPrimary)
                } else {
                    KMIconGlyph(
                        symbol: "return",
                        fallback: "⏎",
                        size: 18,
                        tint: returnKeyKind.isPrimary ? Theme.textOnAccent : Theme.textPrimary
                    )
                }
            }
            .frame(width: KMLayout.returnKeyWidth, height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                    .fill(returnKeyKind.isPrimary ? accent : Theme.keyFunctionBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: returnKeyKind.isPrimary ? .accent : .function))
        .accessibilityLabel(Text(returnKeyKind.accessibilityTitle))
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
