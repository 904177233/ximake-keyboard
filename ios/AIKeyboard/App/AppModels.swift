//
//  AppModels.swift
//  墨语 · 宿主 App
//
//  模块职责：宿主 App 的轻量值类型与常量（Tab、外观模式、语气/尺寸选项、
//            Toast 消息、Provider 类型判定、App 元信息）。
//  依赖：SwiftUI（仅用于 ColorScheme）、Shared 层 Models。
//  使用方：AppState / RootView / 各页面。
//

import SwiftUI

// MARK: - 主导航

/// 主界面三个 Tab：键盘 / AI 试验场 / 设置。
enum MainTab: String, CaseIterable, Identifiable {
    case keyboard
    case playground
    case settings

    var id: String { rawValue }

    /// Tab 标题（中文）。
    var title: String {
        switch self {
        case .keyboard: return "键盘"
        case .playground: return "AI"
        case .settings: return "设置"
        }
    }

    /// Tab 图标（SF Symbol，iOS 16 已存在）。
    var systemImage: String {
        switch self {
        case .keyboard: return "keyboard"
        case .playground: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - 外观

/// 外观模式（跟随系统 / 浅色 / 深色）。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// 传给 `preferredColorScheme` 的值；nil 表示跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 选项

/// 默认语气选项（润色 / 扩写 / 回复建议会用到）。
///
/// 顺序与文案必须和 `design/主App界面规范.md` §3 及组件库 `ToneSelector.defaultTones` 一致。
enum ToneOption {
    static let all: [String] = ["自然", "简洁", "礼貌", "正式", "热情"]
    static let fallback: String = "自然"
}

/// 生图尺寸选项。
struct ImageSizeOption: Identifiable, Equatable {
    let size: String
    let title: String

    var id: String { size }

    static let all: [ImageSizeOption] = [
        ImageSizeOption(size: "1024x1024", title: "1:1 正方形"),
        ImageSizeOption(size: "768x1024", title: "3:4 竖图"),
        ImageSizeOption(size: "1024x768", title: "4:3 横图"),
        ImageSizeOption(size: "720x1280", title: "9:16 手机壁纸")
    ]

    static func title(for size: String) -> String {
        all.first { $0.size == size }?.title ?? size
    }
}

/// 翻译目标语言选项。
struct TargetLanguageOption: Identifiable, Equatable {
    let code: String
    let title: String

    var id: String { code }

    static let all: [TargetLanguageOption] = [
        TargetLanguageOption(code: "英语", title: "英语"),
        TargetLanguageOption(code: "中文", title: "中文"),
        TargetLanguageOption(code: "日语", title: "日语"),
        TargetLanguageOption(code: "韩语", title: "韩语")
    ]

    /// 默认目标语言：输入为中文时译成英语，其余情况译成中文。
    static func suggested(for text: String) -> String {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? "英语" : "中文"
    }
}

// MARK: - Toast

/// 一条悬浮提示。
struct ToastMessage: Identifiable, Equatable {

    enum Kind {
        case success
        case info
        case warning
        case failure
    }

    let id: UUID
    var kind: Kind
    var text: String
    var detail: String?

    init(kind: Kind = .info, text: String, detail: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.detail = detail
    }
}

// MARK: - Provider 能力判定（单点封装）

/// 服务商能力判定的**唯一入口**。
///
/// 契约要求：不要在 App 层复制"哪些预设只能生图"的映射表，
/// 一律转发给 Shared 层（`PresetProviders.isImageOnly(id:)` / `AIProviderConfig.supportsChat`）。
/// 若将来判定规则变化，只需改这一处。
enum ProviderKindHint {

    /// 该服务商是否只能生图、不能对话。
    static func isImageOnly(_ provider: AIProviderConfig) -> Bool {
        !provider.supportsChat
    }

    /// 该 ID 是否指向内置的"仅生图"预设。
    static func isImageOnlyPreset(id: String) -> Bool {
        PresetProviders.isImageOnly(id: id)
    }

    /// 不能作为对话服务商时的中文原因（可对话时返回 nil）。
    static func unsupportedChatReason(_ provider: AIProviderConfig) -> String? {
        provider.unsupportedChatReason
    }

    /// 该服务商是否可用于生图。
    static func supportsImage(_ provider: AIProviderConfig) -> Bool {
        provider.supportsImage
    }

    /// 适合在列表里展示的一句话摘要。
    static func summary(_ provider: AIProviderConfig) -> String {
        provider.displaySummary
    }
}

// MARK: - 键盘启用状态（启发式）

/// 键盘启用状态的三态展示（见 `design/主App界面规范.md` §2）。
///
/// iOS 不提供"是否已添加本键盘"的查询 API，这里只能基于扩展心跳 + 配置齐全度做启发式判断，
/// **不确定时必须走 `.partial` 并给出"如何确认"入口，不能断言"未添加"**。
enum KeyboardSetupState {
    /// 一切就绪：近期有扩展心跳 + 对话配置齐全。
    case ready
    /// 部分就绪：缺心跳或缺 API Key。
    case partial
    /// 还没开始：没有任何配置。
    case notConfigured

    /// 状态标题。
    var title: String {
        switch self {
        case .ready: return "一切就绪"
        case .partial: return "部分就绪"
        case .notConfigured: return "还未完成设置"
        }
    }

    /// 状态图标。
    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .notConfigured: return "circle.dashed"
        }
    }
}

// MARK: - App 元信息

/// App 级常量（版本号、路径文案、扩展标识）。
enum AppInfo {

    /// App 名称。
    static let displayName = "墨语"

    /// 一句话定位。
    static let slogan = "会 AI 的输入法"

    /// 版本号（取自 Info.plist）。
    static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }()

    /// 构建号（取自 Info.plist）。
    static let build: String = {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }()

    /// 最低系统版本。
    static let minimumIOS = "iOS 16.0"

    /// App Group 标识（免费签名下不可用，仅作展示与诊断）。
    /// 必须与 Shared 层 `SharedStore.appGroupIdentifier` 保持一致。
    static let appGroupID = SharedStore.appGroupIdentifier

    /// 键盘扩展 Bundle 名（用于"扩展是否已安装"的启发式检测）。
    static let extensionBundleName = "AIKeyboardExtension.appex"

    /// 键盘设置路径文案（系统不开放直达键盘设置页，只能引导用户手动点）。
    static let keyboardSettingsPath = "设置 › 通用 › 键盘 › 键盘"

    /// 完全访问路径文案。
    static let openAccessPath = "设置 › 通用 › 键盘 › 键盘 › 墨语 › 允许完全访问"

    /// 设备信任路径文案。
    static let trustPath = "设置 › 通用 › VPN与设备管理"

    /// 示例页脚：免责声明。
    static let disclaimer = "本 App 不收集、不上传任何输入内容；AI 请求只发往你自己配置的服务商。"
}
