//
//  KeyCap.swift
//  墨语（Moyu）键盘扩展 · 键帽
//
//  模块职责：单个按键的视觉与反馈。视觉高 39（`Theme.Sizing.letterRowHeight`），
//            外层用 `.frame(minHeight: 44)` + `contentShape` 把命中区补到 44；
//            按压反馈走 `ButtonStyle`（不用 onTapGesture），时长 `Theme.Motion.keyPress`。
//  设计依据：design/组件库.md「KeyCap」、design/键盘布局规范.md §2.7（命中区）、§8（视觉）。
//  约束：键盘域固定字号不随 Dynamic Type；键帽高光只用顶部 45% 线性渐变，
//        不用 `.ultraThinMaterial` 做单键。
//

import SwiftUI

/// 键帽标签。
enum KMKeyLabel: Equatable {

    /// 普通字符（贴左下角显示）。
    case character(String)

    /// 符号（贴左下角显示，字号更小）。
    case symbol(String)

    /// 图标（居中，带文字兜底）。
    case icon(String, fallback: String)
}

/// 键帽样式。
enum KMKeyStyle: Equatable {

    /// 字母键（白底 / 深色灰底，带阴影）。
    case letter

    /// 功能键（⇧ ⌫ 等，深灰底）。
    case function

    /// 强调键（回车 / 生成，accent 底）。
    case accent

    /// 空格键。
    case space

    /// AI 键（带 aiGlow 光晕）。
    case ai
}

/// 键帽。
struct KMKeyCap: View {

    /// 标签。
    let label: KMKeyLabel

    /// 样式。
    var style: KMKeyStyle = .letter

    /// 是否高亮（Shift 锁定、当前页高亮）。
    var isHighlighted: Bool = false

    /// 宽度（nil 表示由父视图均分）。
    var width: CGFloat?

    /// 高度。
    var height: CGFloat = Theme.Sizing.letterRowHeight

    /// 点击回调。
    let action: () -> Void

    var body: some View {
        Button(action: {
            KMHaptics.key()
            action()
        }) {
            labelContent
                .frame(maxWidth: .infinity)
                .frame(width: width, height: height)
                .background(backgroundLayer)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
                .contentShape(Rectangle())
                .frame(minHeight: Theme.Sizing.minTapTarget)
        }
        .buttonStyle(KMKeyCapStyle(style: style))
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: - 标签

    /// 标签内容。
    @ViewBuilder
    private var labelContent: some View {
        switch label {
        case let .character(text):
            Text(text)
                .font(Theme.fontKey)
                .foregroundColor(foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .center)
        case let .symbol(text):
            Text(text)
                .font(.system(size: 17, weight: .regular))  // TOKEN: typography.candidate.size（符号页相对 22pt 主字号降级）
                .foregroundColor(foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .center)
        case let .icon(symbol, fallback):
            KMIconGlyph(symbol: symbol, fallback: fallback, size: iconSize, weight: .regular, tint: foregroundColor)
                .frame(maxWidth: .infinity)
        }
    }

    /// 图标字号（token: typography.candidate.size = 17 / typography.title.size = 20）。
    private var iconSize: CGFloat {
        style == .function ? 17 : 20  // TOKEN: typography.candidate.size = 17；typography.title.size = 20
    }

    /// 文字 / 图标颜色。
    ///
    /// v2：**上档锁定不再用主色**（design/06 §1.5「选中态不用颜色，用字重」）。
    /// v1 里 Shift 锁定时字母变成主题蓝，在「主色只留 3 处」的规则下这是第 4 处。
    /// 现在改成 `keyFunctionBackgroundPressed` 深一档的底 + 保持 `text.primary` 字色，
    /// 由 `shift.fill` 图标本身表达「已锁定」。
    private var foregroundColor: Color {
        switch style {
        case .accent:
            return Theme.textOnAccent
        case .letter, .function, .space:
            return Theme.textPrimary
        case .ai:
            return Theme.textPrimary
        }
    }

    // MARK: - 背景与高光

    /// 键帽底色。
    ///
    /// v2（design/06 §1.6、§5.2）：**没有高光渐变**。真实 iOS 键帽是纯色平片，
    /// 顶部 45% 白渐变是 v1「塑料感」的主要来源，已删除（`highlightLayer` 整个移除）。
    /// 唯一的层级手段是 1pt 底边（`shadow.key`，blur = 0），它渲染出来是一条暗缝
    /// 而不是投影，作用是让密集网格里相邻键帽之间能分辨出来。
    @ViewBuilder
    private var backgroundLayer: some View {
        switch style {
        case .letter:
            // v2.1：**去掉键帽投影**。iOS 26 / 微信输入法的键帽是纯色平片，
            // 1pt 投影在密集网格里会形成一圈脏边，反而让键盘显廉价。
            // 键与键之间的距离由 keyGap(6) 本身保证，不需要投影分层。
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.keyBackground)
        case .function:
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(isHighlighted ? Theme.keyFunctionBackgroundPressed : Theme.keyFunctionBackground)
        case .accent:
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.accent)
        case .space:
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.keyBackground)
        case .ai:
            // design/06 §1.5：主色只允许 3 处。键帽不是「动作位」，用功能键底色。
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.keyFunctionBackground)
        }
    }

    // MARK: - 无障碍

    /// 无障碍标签文案。
    private var accessibilityText: String {
        switch label {
        case let .character(text):
            return "字母 \(text)"
        case let .symbol(text):
            return "符号 \(text)"
        case let .icon(symbol, fallback):
            switch symbol {
            case "delete.left":
                return "退格"
            case "return":
                return "回车"
            case "shift", "shift.fill":
                return "切换大小写"
            case "globe":
                return "切换键盘"
            case "face.smiling":
                return "表情"
            case "keyboard":
                return "切换键盘布局"
            default:
                return fallback
            }
        }
    }
}

/// 键帽按压样式：按下时换底色、去阴影、轻微缩放（时长 `Theme.Motion.keyPress`）。
struct KMKeyCapStyle: ButtonStyle {

    /// 键帽样式（决定按下时的底色）。
    let style: KMKeyStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                    .fill(style == .accent
                          ? Theme.accentPressed
                          : (style == .function ? Theme.keyFunctionBackgroundPressed : Theme.keyBackgroundPressed))
                    .opacity(configuration.isPressed ? 1 : 0)
            )
            .scaleEffect(configuration.isPressed && !KMAnimation.isReduceMotionEnabled ? 0.96 : 1.0)
            .animation(KMAnimation.animation(duration: Theme.Motion.keyPress), value: configuration.isPressed)
    }
}
