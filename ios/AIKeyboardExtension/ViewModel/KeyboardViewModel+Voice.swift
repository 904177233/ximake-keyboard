//
//  KeyboardViewModel+Voice.swift
//  墨语（Moyu）键盘扩展 · 语音输入页的状态与跳转
//
//  模块职责：把 `KMVoiceInput`（录音 + 转写）与键盘状态机接起来：
//            ①判断当前环境能否进入语音页（`canUseVoiceInput`）；
//            ②进出语音页（`openVoiceInput()` / `closeVoiceInput()`），
//              并保证「离开页面 = 停止录音」，不会留一个在后台吃麦克风的会话；
//            ③把转写结果上屏（`commitVoiceText(_:)`）。
//  设计依据：design/05 §1（主色只用 4 处，语音页不放主色）、docs/13 §5。
//  约束：语音页与 `.aiChat` 同高 438（`KMLayout.keyboardHeight` 已处理，不在此重复计算）。
//

import Foundation

extension KeyboardViewModel {

    // MARK: - 可用性

    /// 当前能否进入语音输入页。
    ///
    /// 四个条件同时满足才为 true：
    /// ①系统/设备支持语音识别（模拟器、部分地区会返回 false）；
    /// ②**已经拿到麦克风 + 语音识别授权** —— 扩展里绝不能自己弹权限框
    ///   （弹框会让键盘失去第一响应者被收起，用户看到的就是「点语音就切到别的输入法」），
    ///   所以没授权时这里直接返回 false，由 UI 引导去宿主 App 开；
    /// ③有完全访问（`aiAvailability != .noFullAccess`）——没有完全访问时
    ///   扩展连网络都发不出去，转写必然失败，不如不给入口；
    /// ④当前不在忙碌态（正在生成 AI 内容时先别抢麦克风与注意力）。
    public var canUseVoiceInput: Bool {
        guard KMVoiceInput.shared.isPlatformSupported else { return false }
        guard KMVoiceInput.shared.isAuthorized else { return false }
        if aiAvailability == .noFullAccess { return false }
        return aiAvailability != .busy
    }

    /// 语音入口是否应该显示（只要平台支持就显示，点了再给引导文案）。
    ///
    /// 与 `canUseVoiceInput` 分开：没授权时仍然显示麦克风按钮，
    /// 否则用户永远不知道有这个功能，也无从知道要去哪里开权限。
    public var showsVoiceEntry: Bool {
        guard KMVoiceInput.shared.isPlatformSupported else { return false }
        return aiAvailability != .noFullAccess
    }

    // MARK: - 进出语音页

    /// 进入语音输入页并立即开始录音。
    ///
    /// 不可用时只给中文引导，**不切页面**（与 `openAIChat()` 的策略一致）。
    public func openVoiceInput() {
        if aiAvailability == .noFullAccess {
            KMHaptics.warning()
            showsFullAccessCard = true
            return
        }
        guard KMVoiceInput.shared.isPlatformSupported else {
            showToast("当前系统不支持键盘内语音，可以到「墨语」App 里用语音")
            return
        }
        guard KMVoiceInput.shared.isAuthorized else {
            KMHaptics.warning()
            let hint = KMVoiceInput.shared.authorizationHint
            let suffix = hint.isEmpty ? "" : "（\(hint)）"
            showToast("请先到「墨语」App › 语音输入 里允许麦克风与语音识别\(suffix)")
            return
        }
        guard aiAvailability != .busy else {
            showToast("正在生成内容，稍等一下再用语音")
            return
        }
        KMHaptics.function()
        go(to: .voice)
        KMVoiceInput.shared.reset()
        KMVoiceInput.shared.start()
    }

    /// 离开语音输入页（停止录音、丢弃未提交的转写结果）。
    public func closeVoiceInput() {
        KMVoiceInput.shared.cancel()
        if page == .voice {
            go(to: .letters)
        }
    }

    // MARK: - 上屏

    /// 把语音转写结果写入宿主输入框。
    ///
    /// `KMVoiceInput` 只负责识别，不碰 `UITextDocumentProxy`；
    /// 上屏由键盘统一走 `insertText(_:)`，这样学习数据、联想、Toast 都能复用。
    /// - Parameter text: 转写文本（已由录音侧 trim）。
    public func commitVoiceText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("没有识别到内容，再说一次试试")
            return
        }
        insertText(trimmed)
        lastCommittedText = trimmed
        KMVoiceInput.shared.reset()
        go(to: .letters)
    }
}
