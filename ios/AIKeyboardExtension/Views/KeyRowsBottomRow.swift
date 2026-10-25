//
//  KeyRowsBottomRow.swift
//  AIKeyboardExtension
//
//  字母页第 4 行（123 / 空格 / 🙂 / 回车）。
//
//  为什么单独成文件：这一行既有「宽度分配」，又有主题主色（回车键在「发送/搜索」
//  语义下才用主色），逻辑比上面三行复杂，单独放更好维护。
//
//  设计依据：design/06-界面重构规范v2.md §4.1–§4.5、§2.5（底行精确 384）。
//
//  v2 改动（design/06 §4.5）：**删除小形象角落格**。理由四条：
//  ① 空格被挤到 156pt，比主流输入法（微信 194+）窄 20%，是「不好用」的直接来源；
//  ② 30pt 格低于 44pt 命中区，是「看得见点不着」；
//  ③ v1 底行 382 ≠ 内容宽 384，靠空格弹性吸收 2pt，网格最后一行守不住；
//  ④ 用户五个红圈没有一个指向它，却点名要「数字键」和「别占回车」。
//  现在底行精确闭合：42 + 194 + 42 + 88 + 6 × 3 = 384。小形象迁到设置页顶部展示。
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
/// 布局：`[123 42] [空格 194] [🙂 42] [⏎ 88]`，三个 `KMLayout.keyGap(6)` 间距。
///
/// 尺寸说明（design/06 §2.5，精确闭合，零弹性）：`42 + 194 + 42 + 88 + 6 × 3 = 384`
/// —— 与 390pt 屏的键区内容宽 384 完全相等，行尾不会出现缝隙，也不需要靠空格吸收取整差。
/// 空格仍是 `maxWidth: .infinity`（横屏 200 时键区更窄，需要它吸收差值）。
struct KeyRowsBottomRow: View {

    /// 是否横屏（形象格与图标尺寸不同）。
    let isLandscape: Bool

    /// 行高。
    let height: CGFloat

    /// 主题主色（回车键在提交型语义下的底色）。
    var accent: Color = Theme.accent

    /// 回车键语义（聊天框=发送、搜索框=搜索、普通框=换行）。
    var returnKeyKind: KMReturnKeyKind = .newline

    /// 按键回调。
    let onTap: (KeyboardKey) -> Void

    /// 空格横向滑动时移动光标（参数为字符偏移，正数向右）。
    var onMoveCursor: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: KMLayout.keyGap) {
            numberKey
            // v2.2 修用户反馈「现在不能切到英文输入法」：
            // v1.7 把左下角 🌐 换成 123（切键盘收进长按），但长按门槛 0.42s
            // 对普通用户等于不存在。Apple 的 HIG 也要求键盘必须有一颗
            // 可见的全局键（`needsInputModeSwitchKey` 为真时不提供会被审核挑）。
            // 这里把 🌐 加回来，压在 123 与空格之间，宽度同为 42。
            globeKey
            spaceKey
            emojiKey
            returnKey
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
    /// ## v1.7 修（用户第三次反馈「数字键还是不能用」）
    /// 前两次都试图用 SwiftUI 的手势组合解决，**都错了**：
    /// · v1.4 用 `Button` + `.highPriorityGesture(LongPressGesture)` → 长按抢走 tap，只长按有效；
    /// · v1.6 改 `LongPressGesture().exclusively(before: TapGesture())` → **仍然点不动**。
    ///   原因：长按手势在「快速点击」时不会立即判负，而是继续等待到 0.45s；
    ///   用户抬手时 tap 的触摸序列已经结束，`TapGesture` 永远等不到完整的按下-抬起，
    ///   于是 quick tap 被丢弃。
    /// · v1.7 改用 `KMPressKey`：它用 `DragGesture(minimumDistance: 0)` 自己拿
    ///   「按下 / 持续 / 抬手」的完整时序，**按下瞬间就发点按事件**，
    ///   超过 0.42s 才升级成长按。两个行为不再互相竞争。
    private var numberKey: some View {
        KMPressKey(
            onPress: {
                KMHaptics.function()
                onTap(.pageNumbers)
            },
            onLongPress: { onTap(.globe) },
            accessibilityLabel: "数字与符号",
            accessibilityHint: "长按切换输入法"
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                    .fill(Theme.keyFunctionBackground)
                Text("123")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textPrimary)
            }
            .frame(width: KMLayout.functionKeyWidth, height: height)
        }
        .accessibilityAddTraits(.isKeyboardKey)
    }

    /// 空格键（弹性宽度，吸收取整差）：点按输入空格，**横向滑动移动光标**。
    ///
    /// 空格滑移是 Gboard / 微信 / 搜狗 的通用手势（用户反馈「移动光标也没做好」）。
    /// 用 `KMSpaceKey` 而不是 `Button`：后者拿不到全程位移。
    private var spaceKey: some View {
        KMSpaceKey(
            onSpace: { onTap(.space) },
            onMoveCursor: { offset in onMoveCursor(offset) },
            accessibilityLabel: "空格，可左右滑动移动光标"
        ) {
            Text("空格")
                .font(Theme.fontBody)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(Theme.keyBackground)
                )
        }
    }

    /// 地球键：切到下一个输入法（系统级）。
    ///
    /// 长按可以列出全部已启用键盘（`handleInputModeList` 是系统默认行为，
    /// SwiftUI 里通过 `UIInputViewController` 的 `handleInputModeList(from:with:)`
    /// 提供，这里用最简的「点一下切下一个」，语义与 iOS 原生一致）。
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
