//
//  KeyboardViewModel+Access.swift
//  墨语（Moyu）键盘扩展 · 完全访问与可用性
//
//  模块职责：判断「AI 能不能用」并给出对应引导态。键盘扩展没有网络权限时无法发请求，
//            而扩展内**不能跳转设置**（没有 openURL、也没有宿主 App 的跳转能力），
//            所以只能给文字说明 + 让用户自己去「设置 › 通用 › 键盘 › 墨语」开启。
//  设计依据：design/键盘布局规范.md §5 状态 ⑨⑩⑪（优先级 ⑨ > ⑩ > ⑪）。
//

import Foundation

extension KeyboardViewModel {

    /// 回填完全访问状态并重算 AI 可用性。
    ///
    /// 判定顺序：宿主 `UIInputViewController.hasFullAccess` 为真直接用；
    /// 否则退回 `UIPasteboard` 可读性启发式（无完全访问时剪贴板读取会被系统拦截）。
    /// - Parameter hasFullAccess: 宿主上报的完全访问状态。
    public func refreshAccessState(hasFullAccess: Bool) {
        let probed = KMFullAccessProbe.likelyAvailable()
        self.hasFullAccess = hasFullAccess || probed
        refreshAvailability()
    }

    /// 重算 AI 可用性（在打开面板、回到前台、切页、配置变化后调用）。
    public func refreshAvailability() {
        if aiState.isBusy {
            aiAvailability = .busy
            return
        }
        guard hasFullAccess else {
            aiAvailability = .noFullAccess
            return
        }
        guard snapshot.defaultProvider != nil, snapshot.isChatReady else {
            aiAvailability = .notConfigured
            return
        }
        aiAvailability = .ready
    }

    /// 当前是否允许发起 AI 请求。
    public var canStartAIRequest: Bool {
        aiAvailability.canStartRequest && !aiState.isBusy
    }

    /// 无完全访问时的说明文案（逐字复用布局规范 §5-⑨ 的原文）。
    public static let noFullAccessMessage: String = "需要在“设置 › 键盘”中开启“允许完全访问”，AI 才能联网"

    /// 未配置服务商时的提示文案（逐字复用布局规范 §5-⑩ 的原文）。
    public static let notConfiguredMessage: String = "还没有配置 AI 服务 · 点此设置"

    /// 离线时提示文案。
    public static let offlineMessage: String = "网络未连接"

    /// 生图复制成功后的提示文案（逐字复用布局规范 §5-⑥ 的原文）。
    public static let imagePasteHint: String = "复制后在聊天窗口长按输入框粘贴"

    /// 完全访问说明卡的分步指引（设置路径不能点，只能文字引导）。
    public static let fullAccessSteps: [String] = [
        "打开系统「设置」",
        "进入「通用 › 键盘」",
        "点开「键盘」列表里的「墨语」",
        "打开「允许完全访问」开关",
        "回到任意输入框，重新唤出墨语键盘"
    ]

    // MARK: - 工具条禁用态点击

    /// 点击 AI 工具条禁用提示时的引导（按可用性分流）。
    ///
    /// 键盘扩展内无法打开系统设置（没有 `openURL` 能力），因此无完全访问时
    /// 只能弹出分步说明卡：「设置 › 通用 › 键盘 › 墨语 › 允许完全访问」。
    public func handleAIBarDisabledTap() {
        switch aiAvailability {
        case .noFullAccess:
            showsFullAccessCard = true
            KMHaptics.warning()
        case .notConfigured:
            go(to: .settings)
        case .offline:
            showToast(Self.offlineMessage)
        case .unknown:
            refreshAvailability()
            switch aiAvailability {
            case .ready:
                showToast("AI 已就绪，请选择要使用的能力")
            case .noFullAccess:
                showsFullAccessCard = true
            case .notConfigured:
                go(to: .settings)
            case .offline:
                showToast(Self.offlineMessage)
            case .busy, .unknown:
                showToast("正在准备 AI，请稍候再试")
            }
        case .busy:
            showToast("正在生成中，请稍候")
        case .ready:
            break
        }
    }

    // MARK: - 心跳

    /// 扩展心跳键：键盘被唤起的时间（宿主 App 诊断页读取）。
    public static let heartbeatActiveKey: String = "moyu.ext.lastActiveAt"

    /// 扩展心跳键：最近一次 AI 网络请求成功的时间（宿主 App 诊断页读取）。
    public static let heartbeatNetworkOKKey: String = "moyu.ext.lastNetworkOKAt"

    /// 记录「键盘被唤起」心跳。
    public func recordActiveHeartbeat() {
        SharedStore.shared.setDouble(Date().timeIntervalSince1970, forKey: Self.heartbeatActiveKey)
    }

    /// 记录「AI 网络请求成功」心跳。
    public func recordNetworkOKHeartbeat() {
        SharedStore.shared.setDouble(Date().timeIntervalSince1970, forKey: Self.heartbeatNetworkOKKey)
    }
}
