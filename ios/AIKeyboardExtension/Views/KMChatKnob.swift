//
//  KMChatKnob.swift
//  墨语（Moyu）键盘扩展 · AI 对话旋钮
//
//  模块职责：候选栏右端的 AI 对话入口（design/04 §2）。点按后整个键盘区域切换为
//            完整对话界面；本控件只负责「外观 + 状态 + 命中区」，不承担页面切换逻辑。
//  设计依据：design/04-AI对话与智能联想规范.md §2.2（布局）、§2.4（图标绘制）、
//            §2.5（五态外观）、§2.6（动效）、§2.7（无障碍）。
//  约束：图标必须自绘（禁止 emoji / 禁止 SF Symbol：`bubble.left.and.sparkles` iOS 16 不存在）；
//        命中区恒 44×44，视觉圆竖屏 34 / 横屏 32。
//

import SwiftUI

// MARK: - 旋钮状态

/// 对话旋钮的五种外观状态（design/04 §2.5）。
enum KMChatKnobState: Equatable {
    /// 未打开：chip.bg 填充 + chip.border 描边 + accent 图标。
    case idle
    /// 按下：chip.bg.pressed 填充（缩放由 `KMPressableStyle` 负责）。
    case pressed
    /// 已打开：accent 填充 + 无描边 + textOnAccent 图标。
    case active
    /// 正在回答：chip.bg + chip.border + accent 图标 + 外环匀速旋转。
    case busy
    /// 不可用：chip.bg + chip.border + textTertiary 图标 + 整体 45% 透明。
    case disabled

    /// 背景填充色。
    var fillColor: Color {
        switch self {
        case .idle, .busy, .disabled:
            return Theme.chipBackground
        case .pressed:
            return Theme.chipBackgroundPressed
        case .active:
            return Theme.accent
        }
    }

    /// 描边色；`.active` 无描边。
    var borderColor: Color? {
        switch self {
        case .active:
            return nil
        case .idle, .pressed, .busy, .disabled:
            return Theme.chipBorder
        }
    }

    /// 图标颜色。
    var glyphColor: Color {
        switch self {
        case .idle, .busy:
            return Theme.accent
        case .pressed:
            return Theme.accent
        case .active:
            return Theme.textOnAccent
        case .disabled:
            return Theme.textTertiary
        }
    }

    /// 整体透明度。
    var contentOpacity: Double {
        self == .disabled ? 0.45 : 1.0
    }

    /// 是否显示外圈旋转环。
    var showsBusyRing: Bool {
        self == .busy
    }
}

// MARK: - 旋钮

/// 候选栏右端的 AI 对话旋钮。
struct KMChatKnob: View {

    /// 外观状态。
    let state: KMChatKnobState

    /// 是否横屏（视觉圆 32，竖屏 34）。
    var isLandscape: Bool = false

    /// 点击回调。
    let action: () -> Void

    /// 外环旋转角度（`.busy` 时动画驱动）。
    @State private var ringRotation: Double = 0

    /// 视觉圆直径。
    private var visualSize: CGFloat {
        isLandscape ? KMLayout.aiChatKnobLandscapeSize : KMLayout.aiChatKnobSize
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(state.fillColor)

                if let borderColor = state.borderColor {
                    Circle()
                        .strokeBorder(borderColor, lineWidth: Theme.MaterialToken.strokeWidth)
                }

                KMKnobGlyph(
                    size: KMLayout.aiChatKnobGlyphSize,
                    tint: state.glyphColor
                )

                if state.showsBusyRing {
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(ringRotation))
                        .padding(-Theme.Spacing.xs)
                }
            }
            .frame(width: visualSize, height: visualSize)
            .opacity(state.contentOpacity)
            // 命中区恒 44×44（design/04 §2.2）：视觉 34/32 之外用透明留白补齐。
            .frame(width: KMLayout.aiChatKnobHitSize, height: KMLayout.aiChatKnobHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.92, duration: KMLayout.knobPress))
        .accessibilityLabel(Text("AI 对话"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text("打开墨语 AI 对话面板，可以边打字边和 AI 聊天"))
        .accessibilityAddTraits(state == .active ? [.isButton, .isSelected] : .isButton)
        .onAppear { startBusyRingIfNeeded() }
        .onChange(of: state) { newValue in
            // iOS 16 只支持单参数 onChange。
            if newValue.showsBusyRing {
                startBusyRingIfNeeded()
            }
        }
    }

    /// 无障碍数值文案（design/04 §2.7）。
    private var accessibilityValue: String {
        switch state {
        case .idle, .pressed:
            return "未打开"
        case .active:
            return "已打开"
        case .busy:
            return "正在回答"
        case .disabled:
            return "当前不可用"
        }
    }

    /// 启动外环旋转；Reduce Motion 下保持静止（design/04 §2.6）。
    private func startBusyRingIfNeeded() {
        guard state.showsBusyRing, !KMAnimation.isReduceMotionEnabled else { return }
        ringRotation = 0
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            ringRotation = 360
        }
    }
}

// MARK: - 自绘图标

/// 对话气泡 + 四角星芒图标（design/04 §2.4，16×16 绘制框）。
///
/// 全部为 `Path` 绘制：气泡主体描边 + 气泡尾巴填充 + 右上角四角星填充。
/// 不使用 emoji、不使用 SF Symbol，保证 iOS 16/17/18/27 外观一致。
struct KMKnobGlyph: View {

    /// 目标绘制边长（默认 16，对应 `KMLayout.aiChatKnobGlyphSize`）。
    var size: CGFloat = KMLayout.aiChatKnobGlyphSize

    /// 线条与填充颜色。
    var tint: Color = Theme.accent

    /// 16×16 设计稿到目标尺寸的缩放比。
    private var unit: CGFloat { size / 16.0 }

    var body: some View {
        ZStack {
            bubbleBody
            bubbleTail
            sparkle
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 气泡主体：圆角矩形描边（rect 0.6,1.2,11.4,9.6；圆角 4；线宽 1.6）。
    ///
    /// 16×16 设计框里该矩形中心为 (6.3, 6.0)，画布中心为 (8, 8)，
    /// 因此相对居中偏移为 (−1.7, −2.0)（单位换算后）。
    private var bubbleBody: some View {
        RoundedRectangle(cornerRadius: 4 * unit, style: .continuous)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round))
            .frame(width: 11.4 * unit, height: 9.6 * unit)
            .offset(x: -1.7 * unit, y: -2.0 * unit)
    }

    /// 气泡尾巴：三角 (3.2,10.6) → (4.9,10.6) → (3.4,13.2) 闭合填充。
    private var bubbleTail: some View {
        Path { path in
            path.move(to: CGPoint(x: 3.2 * unit, y: 10.6 * unit))
            path.addLine(to: CGPoint(x: 4.9 * unit, y: 10.6 * unit))
            path.addLine(to: CGPoint(x: 3.4 * unit, y: 13.2 * unit))
            path.closeSubpath()
        }
        .fill(tint)
    }

    /// 四角星芒：中心 (12.3,3.7)、外径 3.7、内径 1.15（内/外 = 0.31）。
    private var sparkle: some View {
        Path { path in
            let center = CGPoint(x: 12.3 * unit, y: 3.7 * unit)
            let outer = 3.7 * unit
            let inner = 1.15 * unit
            // 四个外顶点（上、右、下、左）+ 四个内顶点（对角 45°）。
            let points: [CGPoint] = [
                CGPoint(x: center.x, y: center.y - outer),
                CGPoint(x: center.x + inner, y: center.y - inner),
                CGPoint(x: center.x + outer, y: center.y),
                CGPoint(x: center.x + inner, y: center.y + inner),
                CGPoint(x: center.x, y: center.y + outer),
                CGPoint(x: center.x - inner, y: center.y + inner),
                CGPoint(x: center.x - outer, y: center.y),
                CGPoint(x: center.x - inner, y: center.y - inner)
            ]
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .fill(tint)
    }
}

// MARK: - 预览辅助

#if DEBUG
/// 仅供开发期在 Xcode Preview 中查看五态（不参与打包逻辑）。
struct KMChatKnobPreviewHost: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            KMChatKnob(state: .idle, action: {})
            KMChatKnob(state: .active, action: {})
            KMChatKnob(state: .busy, action: {})
            KMChatKnob(state: .disabled, action: {})
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.keyboardBackground)
    }
}
#endif
