//
//  OnboardingModels.swift
//  墨语 · 宿主 App
//
//  模块职责：引导流程的静态数据（5 步的标题、正文、图标、按钮文案、是否可跳过）。
//  说明：步骤数量与文案由 `design/主App界面规范.md` §1 固定为 5 步，不允许增减。
//  依赖：SwiftUI（图标名仅字符串，不依赖）。
//  使用方：OnboardingView / OnboardingStepContent。
//

import Foundation

/// 引导流程中的一步。
struct OnboardingStep: Identifiable, Equatable {

    /// 步骤序号（从 0 开始）。
    let index: Int
    /// 顶部大图标（SF Symbol）。
    let symbol: String
    /// 图标不可用时的 emoji 兜底。
    let fallbackEmoji: String
    /// 主标题。
    let title: String
    /// 正文。
    let body: String
    /// 主按钮文案。
    let primaryTitle: String
    /// 次要按钮文案（nil 表示没有）。
    let secondaryTitle: String?
    /// 是否允许「跳过」。
    let canSkip: Bool

    var id: Int { index }

    /// 固定的 5 步。
    static let all: [OnboardingStep] = [
        OnboardingStep(
            index: 0,
            symbol: "sparkles",
            fallbackEmoji: "✨",
            title: "欢迎使用墨语",
            body: "一颗会 AI 的输入法。打字时随手润色、翻译、生成回复，不用切 App。",
            primaryTitle: "开始设置",
            secondaryTitle: "跳过",
            canSkip: true
        ),
        OnboardingStep(
            index: 1,
            symbol: "square.grid.2x2",
            fallbackEmoji: "⌨️",
            title: "第 1 步 · 添加键盘",
            body: "设置 › 通用 › 键盘 › 键盘 › 添加新键盘 › 墨语。加完后在聊天框里长按地球键就能切换。",
            primaryTitle: "我已完成",
            secondaryTitle: "稍后",
            canSkip: true
        ),
        OnboardingStep(
            index: 2,
            symbol: "lock.shield",
            fallbackEmoji: "🔐",
            title: "第 2 步 · 开启完全访问",
            body: "设置 › 通用 › 键盘 › 墨语 › 打开「允许完全访问」。不开这个，键盘就无法联网，AI 不可用。",
            primaryTitle: "我已开启",
            secondaryTitle: "查看图示",
            canSkip: false
        ),
        OnboardingStep(
            index: 3,
            symbol: "server.rack",
            fallbackEmoji: "🛠️",
            title: "第 3 步 · 配置 AI 服务",
            body: "填一个 baseURL + API Key + 模型名就能用。支持 DeepSeek、通义千问、Kimi、智谱、OpenRouter 等 9 家预设。",
            primaryTitle: "去配置",
            secondaryTitle: "稍后",
            canSkip: true
        ),
        OnboardingStep(
            index: 4,
            symbol: "checkmark.seal",
            fallbackEmoji: "✅",
            title: "第 4 步 · 装到手机上",
            body: "没有 Mac？用 GitHub Actions 云端编译出 ipa，再用 iloader 装到 iPhone（免费 Apple ID 每 7 天续签一次）。",
            primaryTitle: "看安装指南",
            secondaryTitle: "完成",
            canSkip: true
        )
    ]

    /// 进度持久化的偏好键。
    static let progressKey = "moyu.host.onboardingStep"

    /// 总步数。
    static var count: Int { all.count }
}
