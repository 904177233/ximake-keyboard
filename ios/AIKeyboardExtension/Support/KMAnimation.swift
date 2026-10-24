//
//  KMAnimation.swift
//  墨语（Moyu）键盘扩展 · 动效与按压反馈
//
//  模块职责：统一键盘域动效入口，并在「减弱动态效果」开启时把时长降为 0。
//  设计依据：design/键盘布局规范.md §6（动效）、design/组件库.md「状态与动效通用」。
//  说明：键盘扩展内不能读取 SwiftUI Environment 的动态开关做全局兜底，
//        这里用 `UIAccessibility.isReduceMotionEnabled` 在调用点取当前值（主线程读取安全）。
//

import SwiftUI
import UIKit

/// 键盘域动效工具。
enum KMAnimation {

    /// 是否开启「减弱动态效果」。
    static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// 按 Reduce Motion 调整后的动画时长。
    /// - Parameter duration: 设计令牌里的时长。
    /// - Returns: Reduce Motion 开启时返回 0。
    static func duration(_ duration: Double) -> Double {
        isReduceMotionEnabled ? Theme.Motion.reducedMotionScale : duration
    }

    /// 生成一个可选的隐式动画（Reduce Motion 开启时为 nil）。
    /// - Parameter duration: 设计令牌里的时长。
    /// - Returns: 用于 `.animation(_:value:)` 的动画。
    static func animation(duration: Double) -> Animation? {
        let adjusted = self.duration(duration)
        guard adjusted > 0 else { return nil }
        return .easeOut(duration: adjusted)
    }

    /// 通用快速动画。
    static var fast: Animation? {
        animation(duration: Theme.Motion.fast)
    }

    /// 通用常规动画。
    static var normal: Animation? {
        animation(duration: Theme.Motion.normal)
    }

    /// 展开 / 收起的弹簧动画（系统弹簧在 Reduce Motion 下降级为无动画）。
    static var spring: Animation? {
        isReduceMotionEnabled ? nil : Theme.Motion.spring
    }
}

/// 通用按压反馈样式（胶囊 / 候选 / 卡片按钮共用）。
///
/// 键盘按键不使用本样式（键帽的按压反馈由 `KMKeyCapStyle` 单独实现，时长更短）。
struct KMPressableStyle: ButtonStyle {

    /// 按下时的缩放比例。
    var scale: CGFloat = 0.96

    /// 按下时的不透明度。
    var pressedOpacity: Double = 1.0

    /// 动画时长。
    var duration: Double = Theme.Motion.fast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .scaleEffect(configuration.isPressed && !KMAnimation.isReduceMotionEnabled ? scale : 1.0)
            .animation(KMAnimation.animation(duration: duration), value: configuration.isPressed)
    }
}
