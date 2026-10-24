//
//  Haptics.swift
//  墨语 · 宿主 App 组件
//
//  触感反馈统一封装（契约 §5：统一封装 `Haptics.light/medium/rigid/selection/success/warning`）。
//  宿主 App target 内可使用 UIKit 触感，但为对齐契约、方便静态审查，全部收敛在此文件。
//
import UIKit

/// 触感反馈。
///
/// 说明：宿主 App 与键盘扩展共用同一套命名，键盘扩展内的实现由 keyboard-ui 负责；
/// 本文件位于 `ios/AIKeyboard/`，仅宿主 App target 引用。
enum Haptics {

    /// 轻触（胶囊 / 普通 tap）。
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 中等（确认 / 切换）。
    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 硬（删除 / 重要操作）。
    static func rigid() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred()
    }

    /// 选择（语气 / 分段切换）。
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    /// 成功。
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    /// 警告。
    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// 失败。
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }
}
