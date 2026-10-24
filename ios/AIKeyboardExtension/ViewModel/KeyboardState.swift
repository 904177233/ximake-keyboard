//
//  KeyboardState.swift
//  墨语（Moyu）键盘扩展 · 键盘状态机与值类型
//
//  模块职责：定义键盘全部界面状态、按键枚举、AI 结果状态与错误展示数据。
//  设计依据：docs/02 §4.7（键盘扩展契约）、design/键盘布局规范.md §5（12 状态矩阵）。
//  约束：本文件为纯值类型与枚举，不持有任何 UI 对象；全部 Sendable。
//

import Foundation

// MARK: - 按键

/// 键盘按键动作（所有按键必须经由 `KeyboardViewModel.tap(_:)` 入口）。
///
/// 该枚举是视图层与状态机之间唯一的按键契约：视图只负责把点击翻译成 case，
/// 状态机负责产生副作用（`textDocumentProxy` 写入、页面切换、AI 调用）。
public enum KeyboardKey: Equatable, Sendable {
    /// 普通字符按键（字母 / 数字 / 符号 / 表情）。
    case character(String)
    /// 退格（长按进入连删）。
    case backspace
    /// 空格。
    case space
    /// 回车 / 换行。
    case newline
    /// 中英切换（Shift）。
    case shift
    /// 切换输入源（地球键）。
    case globe
    /// 切换到字母页。
    case pageLetters
    /// 切换到数字页。
    case pageNumbers
    /// 切换到符号页。
    case pageSymbols
    /// 切换到表情页。
    case pageEmoji
    /// 26 键 / 9 键切换。
    case toggleLayout
    /// 打开 AI 面板（工具条 chip 走 `startAI`，此 case 仅用于展开面板）。
    case openAIPanel
    /// 关闭 AI 面板 / 结果页，回到键盘基础高度。
    case closeAIPanel
    /// 打开键盘内设置。
    case openSettings
    /// 关闭键盘内设置。
    case closeSettings
    /// 打开快捷短语浮层。
    case openPhraseBar
    /// 打开剪贴板历史浮层。
    case openClipboardBar
    /// 关闭浮层。
    case closeOverlay
    /// 收起键盘（扩展内无 resign 能力，走 `advanceToNextInputMode` 的对偶实现）。
    case dismissKeyboard
}

// MARK: - 页面 / 浮层 / Shift

extension KeyboardViewModel {

    /// 键盘页面（契约 docs/02 §4.7：letters / numbers / symbols / emoji / aiPanel / result / settings）。
    ///
    /// 面内不含 `phraseBar` / `clipboardBar`：这两者是叠加在键区之上的浮层，
    /// 用 `Overlay` 表达，避免页面高度计算被浮层污染（见 README「状态机图」）。
    public enum Page: String, CaseIterable, Sendable {
        /// 26 键 / 9 键字母页。
        case letters
        /// 数字页。
        case numbers
        /// 符号页。
        case symbols
        /// Emoji 页。
        case emoji
        /// AI 面板（输入框 + 语气 + 生成）。
        case aiPanel
        /// AI 结果页（流式 / 完成 / 失败 / 生图）。
        case result
        /// 键盘内设置。
        case settings
        /// AI 对话面板（全场模式，design/04-AI对话与智能联想规范.md §3）。
        ///
        /// 该页会整体隐藏候选栏 + AI 工具条（84pt chrome），改为
        /// 「标题条 40 + 消息区 180 + 输入行 44 + 键区 174」四段式，总高 438。
        case aiChat

        /// 是否属于「展开态」页面（决定键盘高度增量）。
        public var isExpanded: Bool {
            switch self {
            case .aiPanel, .result, .settings, .aiChat:
                return true
            case .letters, .numbers, .symbols, .emoji:
                return false
            }
        }

        /// 中文标题（无障碍朗读用）。
        public var accessibilityTitle: String {
            switch self {
            case .letters:
                return "字母键盘"
            case .numbers:
                return "数字键盘"
            case .symbols:
                return "符号键盘"
            case .emoji:
                return "表情键盘"
            case .aiPanel:
                return "AI 面板"
            case .result:
                return "AI 结果"
            case .settings:
                return "键盘设置"
            case .aiChat:
                return "AI 对话"
            }
        }
    }

    /// 浮层（叠加态，不改变键盘高度）。
    public enum Overlay: String, Sendable {
        /// 无浮层。
        case none
        /// 快捷短语浮层。
        case phraseBar
        /// 剪贴板历史浮层。
        case clipboardBar
    }

    /// Shift / 中英状态。
    public enum ShiftState: String, Sendable {
        /// 小写 / 中文输入。
        case off
        /// 大写（下一次输入后自动复位）。
        case on
        /// 大写锁定。
        case locked

        /// 是否处于大写状态。
        public var isUppercase: Bool {
            self != .off
        }
    }

    /// 26 键 / 9 键布局。
    public enum LayoutMode: String, Sendable {
        /// 26 键 QWERTY。
        case qwerty
        /// 9 键九宫格。
        case nineKey
    }

    /// AI 能力可用性（对应布局规范 §5 的 ⑨⑩⑪ 三种禁用态）。
    public enum AIAvailability: Equatable, Sendable {
        /// 尚未探测。
        case unknown
        /// 可用。
        case ready
        /// 无完全访问权限（优先级最高）。
        case noFullAccess
        /// 未配置 Provider。
        case notConfigured
        /// 离线（离线态由网络请求失败回填）。
        case offline
        /// 处于 AI 请求进行中（工具条保持可用但显示进度）。
        case busy

        /// 是否允许发起 AI 请求。
        public var canStartRequest: Bool {
            switch self {
            case .ready:
                return true
            case .unknown, .noFullAccess, .notConfigured, .offline, .busy:
                return false
            }
        }
    }
}

// MARK: - AI 结果状态

/// AI 结果状态（契约 docs/02 §4.7 的五态，另加生图绘制中的进度态）。
///
/// 与契约的差异说明（CONTRACT-ADD）：
/// - `.failed` 契约原文为 `failed(String)`，此处保持 `String`（已拼好的中文提示），
///   错误详情另存于 `KeyboardViewModel.lastAIErrorDetail`，供「重试 / 去设置」按钮使用。
/// - `.image(Data)` 中的 `Data` 是 **≤512pt 缩略图 PNG**，不保留原始大图。
public enum AIResultState: Equatable, Sendable {
    /// 空闲。
    case idle
    /// 流式增量文本。
    case streaming(String)
    /// 生成完成（全文）。
    case done(String)
    /// 失败（已本地化的中文提示）。
    case failed(String)
    /// 生图绘制中。
    case imageGenerating(KMImageProgress)
    /// 生图完成（仅缩略图数据）。
    case image(Data)

    /// 是否处于请求进行中（流式或绘制中）。
    public var isBusy: Bool {
        switch self {
        case .streaming, .imageGenerating:
            return true
        case .idle, .done, .failed, .image:
            return false
        }
    }

    /// 当前流式文本（非流式返回空串）。
    public var streamingText: String {
        if case let .streaming(text) = self {
            return text
        }
        return ""
    }
}

/// AI 错误展示数据（视图层只读，不依赖 `AIError` 的具体 case）。
public struct KMAIErrorDetail: Equatable, Sendable {
    /// 一句话错误标题（来自 `AIError.errorDescription`）。
    public let title: String
    /// 恢复建议（来自 `AIError.recoverySuggestion`）。
    public let recovery: String
    /// 是否可重试。
    public let isRetryable: Bool
    /// 是否建议跳转键盘内设置（401 / 未配置 Key）。
    public let suggestsSettings: Bool
    /// 是否因离线（网络不可达）。
    public let isOffline: Bool

    /// 创建错误展示数据。
    /// - Parameters:
    ///   - title: 错误标题。
    ///   - recovery: 恢复建议。
    ///   - isRetryable: 是否可重试。
    ///   - suggestsSettings: 是否引导去设置。
    ///   - isOffline: 是否为离线错误。
    public init(
        title: String,
        recovery: String,
        isRetryable: Bool = true,
        suggestsSettings: Bool = false,
        isOffline: Bool = false
    ) {
        self.title = title
        self.recovery = recovery
        self.isRetryable = isRetryable
        self.suggestsSettings = suggestsSettings
        self.isOffline = isOffline
    }
}

/// 生图进度（对应组件库 `ImageProgress`，键盘域使用 `KM` 前缀避免与宿主 App 重名）。
public struct KMImageProgress: Equatable, Sendable {
    /// 生图阶段。
    public enum Stage: String, Sendable {
        /// 排队中。
        case queued
        /// 正在绘制。
        case drawing
        /// 正在优化提示词。
        case enhancing
        /// 正在下载。
        case downloading

        /// 中文阶段文案。
        public var title: String {
            switch self {
            case .queued:
                return "排队中"
            case .drawing:
                return "正在绘制"
            case .enhancing:
                return "正在优化提示词"
            case .downloading:
                return "正在下载"
            }
        }
    }

    /// 用户输入的原始提示词。
    public let prompt: String
    /// 已等待秒数。
    public let elapsed: TimeInterval
    /// 预计耗时区间（秒）。
    public let expected: ClosedRange<TimeInterval>
    /// 当前阶段。
    public let stage: Stage

    /// 创建生图进度。
    /// - Parameters:
    ///   - prompt: 提示词。
    ///   - elapsed: 已等待秒数。
    ///   - expected: 预计耗时区间。
    ///   - stage: 当前阶段。
    public init(
        prompt: String,
        elapsed: TimeInterval = 0,
        expected: ClosedRange<TimeInterval> = 5...20,
        stage: Stage = .queued
    ) {
        self.prompt = prompt
        self.elapsed = elapsed
        self.expected = expected
        self.stage = stage
    }
}

// MARK: - 短语 / 剪贴板

/// 快捷短语（键盘域轻量模型；`ime-core` 的 `PhraseItem` 落盘后可替换）。
public struct KMPhrase: Identifiable, Equatable, Sendable {
    /// 稳定 ID。
    public let id: String
    /// 短语正文。
    public let text: String
    /// 是否置顶。
    public let isPinned: Bool

    /// 创建短语。
    /// - Parameters:
    ///   - id: 稳定 ID。
    ///   - text: 短语正文。
    ///   - isPinned: 是否置顶。
    public init(id: String = UUID().uuidString, text: String, isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.isPinned = isPinned
    }
}

// MARK: - AI 对话

/// 对话面板的会话阶段（design/04-AI对话与智能联想规范.md §3.12）。
///
/// 与 `AIResultState`（单次 AI 能力结果）分开维护：对话是多轮累积，
/// 而结果页是一次请求的临时展示，两者生命周期不同，不能混用同一个枚举。
public enum KMChatPhase: Equatable, Sendable {
    /// 空闲：可输入、可发送。
    case idle
    /// 已发送但首字未到（思考中，显示三点气泡）。
    case thinking
    /// 正在流式输出（末尾光标）。
    case streaming
    /// 请求失败（显示错误气泡 + 重试）。
    case failed
    /// 生图进行中（显示进度环 + 已等待秒数）。
    case imageGenerating
    /// 已取消（保留已生成文本与操作行）。
    case cancelled

    /// 是否有请求在飞（决定发送按钮形态与输入行可用性）。
    public var isBusy: Bool {
        switch self {
        case .thinking, .streaming, .imageGenerating:
            return true
        case .idle, .failed, .cancelled:
            return false
        }
    }
}

/// 对话消息角色。
public enum KMChatRole: Equatable, Sendable {
    /// 用户。
    case user
    /// AI。
    case assistant
}

/// 对话消息（键盘扩展侧的展示模型）。
///
/// 说明：不复用 Shared 的 `ChatMessage`，因为展示层还需要承载「生图缩略图」「错误详情」
/// 「是否仍在流式」等 UI 状态；发请求时再映射为 `[ChatMessage]`。
public struct KMChatMessage: Identifiable, Equatable, Sendable {

    /// 稳定 ID。
    public let id: String

    /// 角色。
    public let role: KMChatRole

    /// 文本内容（流式时逐字增长）。
    public var text: String

    /// 是否仍在流式输出（末尾画光标）。
    public var isStreaming: Bool

    /// 生图缩略图（≤512pt PNG；文本消息为 nil）。
    public var imageData: Data?

    /// 失败详情（成功消息为 nil）。
    public var errorDetail: KMAIErrorDetail?

    /// 创建消息。
    /// - Parameters:
    ///   - id: 稳定 ID。
    ///   - role: 角色。
    ///   - text: 文本内容。
    ///   - isStreaming: 是否仍在流式输出。
    ///   - imageData: 生图缩略图。
    ///   - errorDetail: 失败详情。
    public init(
        id: String = UUID().uuidString,
        role: KMChatRole,
        text: String = "",
        isStreaming: Bool = false,
        imageData: Data? = nil,
        errorDetail: KMAIErrorDetail? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.imageData = imageData
        self.errorDetail = errorDetail
    }

    /// 是否为生图消息。
    public var isImageMessage: Bool {
        imageData != nil
    }
}

