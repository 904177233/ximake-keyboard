//
//  KeyboardViewModel.swift
//  墨语（Moyu）键盘扩展 · 键盘状态机
//
//  模块职责：键盘扩展的唯一状态源。持有页面状态、拼音组字、候选列表、AI 结果状态、
//            配置快照与短语/剪贴板数据；所有按键与 AI 动作统一从本类型进入。
//  设计依据：docs/02 §4.7（键盘扩展契约）、design/键盘布局规范.md §5（12 状态矩阵）、§9（交互流）。
//  线程模型：整类标注 @MainActor；`textDocumentProxy` 与 `UIView` 相关调用只在主线程发生。
//  写入边界：本类型不直接持有任何视图；视图通过 `@Published` 只读订阅。
//

import Combine
import Foundation
import UIKit

/// 键盘状态机。
///
/// 关键约定：
/// - 所有按键动作必须经过 `tap(_:)`，视图层不得直接调用 `textDocumentProxy`。
/// - 页面切换统一走 `go(to:)`，它负责维护「展开态 / 收起态」与结果页的清理。
/// - 高度不由本类型计算：`KeyboardViewController` 依据 `page` / `isLandscape` 向 `KMLayout` 取值。
/// - AI 请求实现位于 `KeyboardViewModel+AI.swift`，权限与可用性位于 `KeyboardViewModel+Access.swift`，
///   面板编辑位于 `KeyboardViewModel+Panel.swift`（同一状态机，按关注点拆文件以控制单文件行数）。
@MainActor
public final class KeyboardViewModel: ObservableObject {

    // MARK: - 页面与输入状态

    /// 当前页面。
    @Published public internal(set) var page: Page = .letters

    /// 当前浮层（叠加在键区之上，不改变高度）。
    @Published public internal(set) var overlay: Overlay = .none

    /// 26 键 / 9 键。
    @Published public internal(set) var layoutMode: LayoutMode = .qwerty

    /// Shift / 中英状态。
    @Published public internal(set) var shiftState: ShiftState = .off

    /// 当前拼音组字串（小写、无空格）。
    @Published public internal(set) var composing: String = ""

    /// 候选列表（由 `IMECore` 生成）。
    @Published public internal(set) var candidates: [IMECandidate] = []

    /// 高亮候选下标（候选栏首项高亮）。
    @Published public internal(set) var highlightedCandidateIndex: Int = 0

    /// 候选翻页下标。
    @Published public internal(set) var candidatePageIndex: Int = 0

    /// 是否横屏（由 `KeyboardViewController` 回填）。
    @Published public internal(set) var isLandscape: Bool = false

    /// 上一次上屏的文本（用于联想候选）。
    @Published public internal(set) var lastCommittedText: String = ""

    // MARK: - AI 状态

    /// AI 结果状态（契约五态 + 生图进度态）。
    @Published public internal(set) var aiState: AIResultState = .idle

    /// 流式文本（逐字追加；与 `aiState.streaming` 同步，便于视图最小刷新）。
    @Published public internal(set) var streamingText: String = ""

    /// 最近一次 AI 请求的能力（结果卡片 header 展示）。
    @Published public internal(set) var lastFeature: AIFeature = .polish

    /// 最近一次请求使用的 Provider 名称（结果卡片 header 展示）。
    @Published public internal(set) var lastProviderName: String = ""

    /// AI 可用性（对应布局规范 §5 的 ⑨⑩⑪ 三种禁用态）。
    @Published public internal(set) var aiAvailability: AIAvailability = .unknown

    /// 错误详情（失败态「重试 / 去设置」按钮使用）。
    @Published public internal(set) var lastAIErrorDetail: KMAIErrorDetail?

    /// 上一次请求耗时（秒），成功态 header 展示「已完成 0.8s」。
    @Published public internal(set) var lastAIDuration: TimeInterval = 0

    /// 回复建议拆分结果（恰好 ≤3 条，每条 ≤30 字）。
    @Published public internal(set) var replySuggestions: [String] = []

    /// 生图缩略图（≤512pt PNG；插入前再取原图）。
    @Published public internal(set) var imageThumbnailData: Data?

    /// 是否已确认拥有完全访问权限（启发式探测结果 + 失败回填）。
    @Published public internal(set) var hasFullAccess: Bool = false

    /// 是否展示「请开启完全访问」说明卡。
    @Published public internal(set) var showsFullAccessCard: Bool = false

    // MARK: - AI 面板

    /// 面板文本框内容。
    @Published public internal(set) var panelText: String = ""

    /// 面板光标位置（以 `Character` 计的偏移）。
    @Published public internal(set) var panelCursor: Int = 0

    /// 面板是否处于可编辑态（false = 只读上下文预览）。
    @Published public internal(set) var isPanelEditing: Bool = false

    /// 面板上下文预览（从宿主输入框或剪贴板取得的原文，尾部截断）。
    @Published public internal(set) var panelContextPreview: String = ""

    /// 面板语气。
    @Published public internal(set) var tone: String = "自然"

    /// 面板是否展示「仅取最近 200 字作为上下文」小字。
    @Published public internal(set) var showsContextTruncationHint: Bool = false

    // MARK: - 数据

    /// 配置快照（Provider / 语气 / 短语开关等）。
    @Published public internal(set) var snapshot: ConfigSnapshot = .defaultValue()

    /// 快捷短语（置顶优先）。
    @Published public internal(set) var phrases: [PhraseItem] = []

    /// 剪贴板历史。
    @Published public internal(set) var clipboardItems: [String] = []

    /// 词库诊断摘要（设置页展示）。
    @Published public internal(set) var dictionarySummary: String = ""

    /// 一次性提示文案（Toast）。
    @Published public internal(set) var toastMessage: String?

    /// 键盘是否已完成首次布局（避免面板在宽度未知时闪现）。
    @Published public internal(set) var isReady: Bool = false

    // MARK: - 依赖

    /// 宿主输入框代理（由 `KeyboardViewController` 注入；弱引用避免持有宿主对象）。
    public weak var proxy: UITextDocumentProxy?

    /// 地球键回调（由 `KeyboardViewController` 注入：`advanceToNextInputMode()`）。
    public var onGlobe: (() -> Void)?

    /// 收起键盘回调（扩展内等价实现：切换到下一个输入模式）。
    public var onDismissKeyboard: (() -> Void)?

    /// 上屏成功回调（用于宿主侧埋点与触感）。
    public var onInsert: ((String) -> Void)?

    /// 请求宿主刷新键盘高度（页面 / 横竖屏变化时触发）。
    public var onHeightChangeNeeded: (() -> Void)?

    /// 输入法内核（词库、学习、短语、剪贴板）。
    let engine: KMInputEngine

    /// 配置存储。
    let configStore: ConfigStore

    // MARK: - AI 任务（内部状态，不参与视图刷新）

    /// 当前流式 / 生图请求任务（取消时 `cancel()`）。
    var currentAITask: Task<Void, Never>?

    /// 生图进度定时任务（每秒刷新已等待秒数）。
    var imageProgressTask: Task<Void, Never>?

    /// 最近一次请求的输入文本（重试时复用）。
    var lastRequestText: String = ""

    /// 最近一次请求的上下文（重试时复用）。
    var lastRequestContext: String = ""

    /// 生图原图（仅本次会话内保留，切页 / 消失时立即清空，不入 `@Published` 以免大对象触发视图重算）。
    var lastImageOriginalData: Data?

    /// 面板是否处于「编辑 AI 结果后插入」模式。
    @Published public internal(set) var isEditingAIResult: Bool = false

    /// 候选引擎每页条数（候选栏分页点按 9 条一页）。
    public static let candidatePageSize: Int = 9

    /// 上下文最多取多少字（超出时提示「仅取最近 200 字」）。
    public static let contextCharacterLimit: Int = 200

    // MARK: - 初始化

    /// 创建键盘状态机。
    /// - Parameters:
    ///   - engine: 输入法内核，默认使用共享单例。
    ///   - configStore: 配置存储，默认使用 `ConfigStore()`（内部走 `SharedStore`）。
    public init(engine: KMInputEngine = .shared, configStore: ConfigStore = ConfigStore()) {
        self.engine = engine
        self.configStore = configStore
        let loaded = configStore.load()
        self.snapshot = loaded
        self.tone = loaded.defaultTone
    }

    /// 抽取的上下文尾部（供 AI 请求与面板预览使用）。
    public var contextTail: String {
        Self.tail(of: proxyContext, limit: Self.contextCharacterLimit)
    }

    /// 宿主输入框的完整上下文（前文 + 后文）。
    ///
    /// 选中文本不单独拼接：`textDocumentProxy.insertText` 在宿主内会自然替换当前选区，
    /// 因此这里只统计前后文，避免把选区内容重复发给模型。
    public var proxyContext: String {
        guard let proxy else { return "" }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        return before + after
    }

    // MARK: - 生命周期

    /// 键盘完成首次布局后调用：加载配置、预热词库、探测完全访问、刷新候选。
    public func activate() {
        engine.prepare(clipboardEnabled: snapshot.enableClipboardHistory)
        dictionarySummary = engine.diagnosticsSummary
        phrases = engine.phrases
        clipboardItems = snapshot.enableClipboardHistory ? engine.clipboardItems : []
        hasFullAccess = KMFullAccessProbe.likelyAvailable()
        refreshAvailability()
        reloadContextPreview()
        recordActiveHeartbeat()
        isReady = true
    }

    /// 键盘即将消失时调用：取消进行中的 AI 请求并释放缩略图，控制扩展内存峰值。
    public func deactivate() {
        cancelAI(silently: true)
        imageThumbnailData = nil
        showsFullAccessCard = false
        overlay = .none
    }

    /// 横竖屏变化（由 `KeyboardViewController` 回填）。
    /// - Parameter landscape: 是否横屏。
    public func setLandscape(_ landscape: Bool) {
        guard isLandscape != landscape else { return }
        isLandscape = landscape
        onHeightChangeNeeded?()
    }

    // MARK: - 按键入口

    /// 处理一次按键。
    ///
    /// 这是键盘唯一的动作入口：视图只负责把点击翻译成 `KeyboardKey`，
    /// 副作用（写输入框 / 切页 / 调 AI）全部在此集中处理。
    /// - Parameter key: 按键动作。
    public func tap(_ key: KeyboardKey) {
        // AI 面板编辑态：字符、退格、空格优先写入面板缓冲。
        if page == .aiPanel, isPanelEditing {
            switch key {
            case let .character(text):
                panelInsert(text)
                return
            case .backspace:
                panelBackspace()
                return
            case .space:
                panelInsert(" ")
                return
            case .newline:
                panelInsert("\n")
                return
            default:
                break
            }
        }

        switch key {
        case let .character(text):
            handleCharacter(text)
        case .backspace:
            handleBackspace()
        case .space:
            commitLiteral(" ")
        case .newline:
            commitLiteral("\n")
        case .shift:
            handleShift()
        case .globe:
            onGlobe?()
        case .pageLetters:
            go(to: .letters)
        case .pageNumbers:
            go(to: .numbers)
        case .pageSymbols:
            go(to: .symbols)
        case .pageEmoji:
            go(to: .emoji)
        case .toggleLayout:
            layoutMode = layoutMode == .qwerty ? .nineKey : .qwerty
            clearComposing()
        case .openAIPanel:
            openAIPanel()
        case .closeAIPanel:
            go(to: previousNonAIPage)
        case .openSettings:
            go(to: .settings)
        case .closeSettings:
            go(to: previousNonAIPage)
        case .openPhraseBar:
            overlay = overlay == .phraseBar ? .none : .phraseBar
            refreshPhrases()
        case .openClipboardBar:
            overlay = overlay == .clipboardBar ? .none : .clipboardBar
            refreshClipboard()
        case .closeOverlay:
            overlay = .none
        case .dismissKeyboard:
            onDismissKeyboard?()
        }
    }

    /// 候选栏点击（上屏单个候选）。
    /// - Parameter index: 候选下标。
    public func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        let candidate = candidates[index]
        engine.commit(candidate, input: composing)
        insertText(candidate.text)
        lastCommittedText = candidate.text
        clearComposing()
        refreshPredictions()
        KMHaptics.candidate()
    }

    /// 候选栏长按（上屏并保持候选栏，供后续继续挑词）。
    /// - Parameter index: 候选下标。
    public func longPressCandidate(at index: Int) {
        selectCandidate(at: index)
    }

    /// 切换候选翻页。
    /// - Parameter delta: +1 下一页 / −1 上一页。
    public func turnCandidatePage(_ delta: Int) {
        let count = candidatePageCount
        guard count > 1 else { return }
        candidatePageIndex = min(max(candidatePageIndex + delta, 0), count - 1)
    }

    /// 当前页候选。
    public var currentPageCandidates: [IMECandidate] {
        let size = Self.candidatePageSize
        let start = candidatePageIndex * size
        guard start < candidates.count else { return [] }
        let end = min(start + size, candidates.count)
        return Array(candidates[start..<end])
    }

    /// 候选总页数。
    public var candidatePageCount: Int {
        let size = Self.candidatePageSize
        guard !candidates.isEmpty else { return 1 }
        return (candidates.count + size - 1) / size
    }

    // MARK: - 页面

    /// 切换到指定页面。
    /// - Parameter target: 目标页面。
    public func go(to target: Page) {
        guard page != target else { return }
        overlay = .none
        let wasExpanded = page.isExpanded
        page = target
        if target != .result {
            cancelAI(silently: true)
            aiState = .idle
            streamingText = ""
            lastAIErrorDetail = nil
            imageThumbnailData = nil
            replySuggestions = []
        }
        if target == .aiPanel {
            reloadContextPreview()
            if panelText.isEmpty {
                panelText = contextTail
                panelCursor = panelText.count
            }
        }
        if target == .settings {
            snapshot = configStore.load()
            refreshPhrases()
            refreshClipboard()
            dictionarySummary = engine.diagnosticsSummary
            refreshAvailability()
        }
        if wasExpanded != target.isExpanded || target.isExpanded {
            onHeightChangeNeeded?()
        }
    }

    /// 回到上一个非 AI 页面（AI 面板 / 结果 / 设置关闭时使用）。
    public var previousNonAIPage: Page {
        .letters
    }

    /// 打开 AI 面板（工具条「展开」入口）。
    public func openAIPanel() {
        refreshAvailability()
        go(to: .aiPanel)
    }

    /// 展示 / 关闭完全访问说明卡。
    /// - Parameter shows: 是否展示。
    public func setFullAccessCard(_ shows: Bool) {
        showsFullAccessCard = shows
    }

    // MARK: - 文本写入

    /// 直接上屏一段文本（不含组字状态）。
    /// - Parameter text: 待上屏文本。
    public func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        proxy?.insertText(text)
        onInsert?(text)
    }

    /// 清空组字状态并刷新候选。
    public func clearComposing() {
        composing = ""
        candidates = []
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
        proxy?.unmarkText()
    }

    /// 刷新上下文预览（AI 面板打开时调用）。
    public func reloadContextPreview() {
        let context = contextTail
        panelContextPreview = context
        showsContextTruncationHint = proxyContext.count > Self.contextCharacterLimit
    }

    // MARK: - 提示

    /// 展示一次 Toast 提示（自动消失）。
    /// - Parameter message: 中文提示文案。
    public func showToast(_ message: String) {
        toastMessage = message
        let expected = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            if self.toastMessage == expected {
                self.toastMessage = nil
            }
        }
    }

    /// 关闭 Toast。
    public func clearToast() {
        toastMessage = nil
    }

    // MARK: - 私有实现

    /// 字符按键：英文直通；中文走拼音组字。
    private func handleCharacter(_ text: String) {
        guard !text.isEmpty else { return }
        if shiftState == .on {
            shiftState = .off
        }
        // 字母 → 进入拼音组字；数字 / 符号 / 表情 → 直接上屏。
        if text.count == 1, let scalar = text.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.uppercaseLetters.contains(scalar) {
            composing += text.lowercased()
            updateMarkedText()
            refreshCandidates()
            return
        }
        commitLiteral(text)
    }

    /// 退格：优先删组字，其次删宿主文本。
    private func handleBackspace() {
        if !composing.isEmpty {
            composing.removeLast()
            if composing.isEmpty {
                clearComposing()
            } else {
                updateMarkedText()
                refreshCandidates()
            }
            return
        }
        proxy?.deleteBackward()
    }

    /// Shift 循环：off → on → locked → off。
    private func handleShift() {
        switch shiftState {
        case .off:
            shiftState = .on
        case .on:
            shiftState = .locked
        case .locked:
            shiftState = .off
        }
    }

    /// 上屏固定文本（数字 / 符号 / 空格 / 换行）。
    private func commitLiteral(_ text: String) {
        if !composing.isEmpty {
            clearComposing()
        }
        insertText(text)
        lastCommittedText = text
    }

    /// 同步拼音组字到宿主输入框（marked text）。
    private func updateMarkedText() {
        let range = NSRange(location: (composing as NSString).length, length: 0)
        proxy?.setMarkedText(composing, selectedRange: range)
    }

    /// 重新计算候选列表。
    private func refreshCandidates() {
        guard !composing.isEmpty else {
            candidates = []
            highlightedCandidateIndex = 0
            candidatePageIndex = 0
            return
        }
        let limit = Self.candidatePageSize * 3
        candidates = engine.candidates(for: composing, limit: limit)
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
    }

    /// 上屏后刷新联想候选。
    private func refreshPredictions() {
        let predictions = engine.predictNext(after: lastCommittedText, limit: 6)
        guard !predictions.isEmpty else {
            candidates = []
            candidatePageIndex = 0
            return
        }
        candidates = predictions
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
    }

    /// 刷新短语列表。
    func refreshPhrases() {
        phrases = engine.phrases
    }

    /// 刷新剪贴板历史。
    func refreshClipboard() {
        clipboardItems = snapshot.enableClipboardHistory ? engine.clipboardItems : []
    }

    // MARK: - 工具

    /// 取字符串末尾若干字符。
    /// - Parameters:
    ///   - text: 原文本。
    ///   - limit: 最多保留的字符数。
    /// - Returns: 截断后的尾部文本。
    static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }
}
