//
//  KMPressKey.swift
//  墨语（Moyu）键盘扩展 · 可按住 / 可重复 / 可滑动的按键壳
//
//  模块职责：提供一个「能拿到真实按下时序」的按键容器，替代 SwiftUI `Button`。
//
//  ## 为什么不用 `Button`
//  `Button` 只在「按下并在键内抬起」时触发 action，拿不到：
//  · 按住的时长 → 做不了长按（`LongPressGesture` 与 `Button` 组合会互相抢事件，
//    这正是 v1.6 「123 键点不动」的根因：`.exclusively(before: TapGesture())`
//    让长按手势在慢速点击时继续等待，抬手时 tap 已经结束，于是 tap 永远不触发）；
//  · 按住期间的重复 → 做不了「长按退格连续删除」；
//  · 手指在键内的横向位移 → 做不了「空格滑动移光标」。
//
//  ## 做法
//  用 `DragGesture(minimumDistance: 0)` 自己判定触摸生命周期：
//  · `onChanged` 第一次回调 = 手指按下（此时立即触发一次动作，保证手感不延迟）；
//  · 按住超过 `longPressDuration` → 触发 `onLongPress`（一次性）或开始 `onRepeat`（循环）；
//  · `onEnded` = 抬手，若既没长按也没重复过，就只算一次普通点按（已在按下时触发过，不重复）。
//
//  ## 无障碍
//  `Button` 的消失意味着必须自己补：`.accessibilityAddTraits(.isButton)`、
//  `.accessibilityLabel`、`.accessibilityAction`（VoiceOver 双击要能触发）。
//

import SwiftUI

// MARK: - 按住型按键

/// 能拿到真实按下时序的按键外壳。
///
/// 三种行为可以组合：
/// - `onPress`：**按下瞬间**触发一次（退格、数字、字母都走这条，手感零延迟）；
/// - `onRepeat`：按住超过 `longPressDuration` 后，每 `repeatInterval` 触发一次（长按连续删除）；
/// - `onLongPress`：按住超过 `longPressDuration` 后触发一次（123 → 切换输入法）。
struct KMPressKey<Content: View>: View {

    /// 按下瞬间触发。
    let onPress: () -> Void

    /// 按住后的重复触发（长按连续删除）。nil 表示不重复。
    var onRepeat: (() -> Void)?

    /// 按住后的一次性触发（长按切键盘）。nil 表示没有长按行为。
    var onLongPress: (() -> Void)?

    /// 触发长按/重复前的等待时长（秒）。国产输入法普遍 400–500ms。
    var longPressDuration: TimeInterval = 0.42

    /// 重复触发的间隔（秒）。70ms ≈ 每秒 14 个字符，接近 iOS 原生退格节奏。
    var repeatInterval: TimeInterval = 0.07

    /// 按下时的视觉缩放（Reduce Motion 下不缩放）。
    var pressedScale: CGFloat = 0.96

    /// 无障碍标签。
    let accessibilityLabel: String

    /// 无障碍提示（可选）。
    var accessibilityHint: String?

    /// 按键内容。
    @ViewBuilder let content: () -> Content

    /// 是否处于按下态（驱动视觉反馈）。
    @State private var isPressed = false

    /// 按住后的定时任务（重复触发）。
    @State private var holdTask: Task<Void, Never>?

    /// 长按是否已经触发过（抬手时不再补一次点按）。
    @State private var didTriggerHold = false

    var body: some View {
        content()
            .scaleEffect(isPressed && !KMAnimation.isReduceMotionEnabled ? pressedScale : 1.0)
            .animation(KMAnimation.animation(duration: Theme.Motion.keyPress), value: isPressed)
            .contentShape(Rectangle())
            .gesture(pressGesture)
            .onDisappear { cancelHold() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text(accessibilityHint ?? ""))
            .accessibilityAction { onPress() }
    }

    /// 触摸生命周期手势。
    ///
    /// `minimumDistance: 0` 是关键——距离阈值一旦大于 0，手指轻微移动就会让手势失败。
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                didTriggerHold = false
                // 按下即触发：退格/字母/数字都必须「按下去就有反应」，
                // 等抬手再触发会有肉眼可感的延迟。
                onPress()
                startHoldIfNeeded()
            }
            .onEnded { _ in
                isPressed = false
                cancelHold()
                didTriggerHold = false
            }
    }

    /// 按下后启动「长按检测 → 重复」。
    private func startHoldIfNeeded() {
        guard onRepeat != nil || onLongPress != nil else { return }
        cancelHold()
        holdTask = Task { @MainActor in
            // 第一段：等长按时长。期间抬手 → 任务被 cancel，什么都不发生。
            try? await Task.sleep(nanoseconds: UInt64(longPressDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            didTriggerHold = true

            if let onLongPress {
                // 一次性长按（123 → 切键盘）：触发后不再重复。
                KMHaptics.function()
                onLongPress()
                return
            }
            guard let onRepeat else { return }
            KMHaptics.function()
            // 第二段：重复触发，直到抬手（cancelHold 会取消这个 Task）。
            while !Task.isCancelled {
                onRepeat()
                try? await Task.sleep(nanoseconds: UInt64(repeatInterval * 1_000_000_000))
            }
        }
    }

    /// 取消按住任务（抬手 / 视图消失时调用）。
    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }
}

// MARK: - 退格键（长按连续删除）

/// 退格键：按下删一个字符，**按住连续删**。
///
/// 微信 / 搜狗 / 百度 / iOS 原生的退格都是「按住不放就一路删下去」，
/// 用户反馈「按删除键，长按连续删除，也要有」就是这条。
///
/// 节奏参照 iOS 原生：先等 0.42s 进入长按（这段时间已经删了第 1 个字符），
/// 之后每 70ms 删一个 ≈ 每秒 14 个字符；长按期间不再有逐次触感反馈
/// （系统级连续删除的触感是「一次性」的，逐次震动会让手指发麻）。
struct KMBackspaceKey: View {

    /// 键宽。
    var width: CGFloat = KMLayout.functionKeyWidth

    /// 键高。
    var height: CGFloat

    /// 图标颜色。
    var tint: Color = Theme.textPrimary

    /// 删除一个字符（点按与长按重复共用）。
    let onDelete: () -> Void

    var body: some View {
        KMPressKey(
            onPress: onDelete,
            onRepeat: onDelete,
            longPressDuration: 0.42,
            repeatInterval: 0.07,
            accessibilityLabel: "退格",
            accessibilityHint: "长按连续删除"
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                    .fill(Theme.keyFunctionBackground)
                KMIconGlyph(symbol: "delete.left", fallback: "⌫", size: 18, tint: tint)
            }
            .frame(width: width, height: height)
        }
        .accessibilityAddTraits(.isKeyboardKey)
    }
}


/// 空格键：点按输入空格，**横向滑动移动光标**。
///
/// 这是 Gboard / 微信输入法 / 搜狗 的通用手势：在空格上左右滑，
/// 光标跟着走；滑过之后抬手不再补空格。
///
/// 实现要点：
/// - 用 `DragGesture(minimumDistance: 0)` 拿全程位移；
/// - 每滑过一个 `cursorStep`（8pt）就调一次 `adjustTextPosition(byCharacterOffset:)`，
///   而不是等抬手一次算总位移——这样光标是跟着手指走的，不是跳的；
/// - `didMoveCursor` 一旦置位，抬手时就不再输入空格。
struct KMSpaceKey<Label: View>: View {

    /// 输入一个空格。
    let onSpace: () -> Void

    /// 移动光标（±1 为按字符移动）。
    let onMoveCursor: (Int) -> Void

    /// 每滑多少 pt 移动一个字符。
    var cursorStep: CGFloat = 8

    /// 按下时的视觉缩放。
    var pressedScale: CGFloat = 0.96

    /// 无障碍标签。
    let accessibilityLabel: String

    /// 按键内容。
    @ViewBuilder let content: () -> Label

    @State private var isPressed = false
    @State private var didMoveCursor = false
    @State private var consumedSteps = 0

    var body: some View {
        content()
            .scaleEffect(isPressed && !KMAnimation.isReduceMotionEnabled ? pressedScale : 1.0)
            .animation(KMAnimation.animation(duration: Theme.Motion.keyPress), value: isPressed)
            .contentShape(Rectangle())
            .gesture(spaceGesture)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAction { onSpace() }
    }

    private var spaceGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressed {
                    isPressed = true
                    didMoveCursor = false
                    consumedSteps = 0
                    KMHaptics.key()
                }
                // 每累计一个 cursorStep 就移动一格光标。
                let steps = Int((value.translation.width / cursorStep).rounded())
                guard steps != consumedSteps else { return }
                let delta = steps - consumedSteps
                consumedSteps = steps
                didMoveCursor = true
                onMoveCursor(delta)
            }
            .onEnded { _ in
                isPressed = false
                let moved = didMoveCursor
                didMoveCursor = false
                consumedSteps = 0
                // 滑过光标就不补空格了，否则会「移完光标又插一个空格」。
                guard !moved else { return }
                onSpace()
            }
    }
}
