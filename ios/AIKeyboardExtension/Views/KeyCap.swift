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
                .overlay(highlightLayer)
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
                .frame(maxWidth: .infinity, alignment: style == .space ? .center : .leading)
                .padding(.leading, style == .space ? 0 : Theme.Spacing.md)
        case let .symbol(text):
            Text(text)
                .font(.system(size: 17, weight: .regular))  // TOKEN: typography.candidate.size（符号页相对 22pt 主字号降级）
                .foregroundColor(foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Theme.Spacing.sm)
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
    private var foregroundColor: Color {
        switch style {
        case .accent:
            return Theme.textOnAccent
        case .letter:
            return isHighlighted ? Theme.accent : Theme.textPrimary
        case .function, .space:
            return isHighlighted ? Theme.accent : Theme.textPrimary
        case .ai:
            return Theme.accent
        }
    }

    // MARK: - 背景与高光

    /// 键帽底色。
    @ViewBuilder
    private var backgroundLayer: some View {
        switch style {
        case .letter:
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.keyBackground)
                .shadow(
                    color: Theme.keyShadow,
                    radius: Theme.Shadow.key.blur,
                    x: 0,
                    y: Theme.Shadow.key.y
                )
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
            RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                .fill(Theme.accentSoft)
        }
    }

    /// 顶部 45% 玻璃高光（仅字母与空格键，符合规范 §8 ①）。
    @ViewBuilder
    private var highlightLayer: some View {
        if style == .letter || style == .space {
            GeometryReader { proxy in
                LinearGradient(
                    colors: [Color.white.opacity(0.25), Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.45)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
                .allowsHitTesting(false)
            }
        } else {
            EmptyView()
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
