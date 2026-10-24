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

    // MARK: - AI 对话（全场模式，design/04 §3.12 状态机）

    /// 对话面板是否展开（等价于 `page == .aiChat`，视图层单独订阅以减少组合刷新）。
    @Published public internal(set) var isChatOpen: Bool = false

    /// 对话输入行草稿（自绘输入，不走系统键盘）。
    @Published public internal(set) var chatDraft: String = ""

    /// 对话消息列表（跨「关闭→再次进入」保留）。
    @Published public internal(set) var chatMessages: [KMChatMessage] = []

    /// 当前是否有对话请求在飞（thinking / streaming / imageGenerating 统一为 true）。
    @Published public internal(set) var chatIsBusy: Bool = false

    /// 对话阶段（用于标题条状态点、发送按钮形态）。
    @Published public internal(set) var chatPhase: KMChatPhase = .idle

    /// 对话本轮已生成文本（流式追加用；消息列表里的最后一条同步更新）。
    @Published public internal(set) var chatStreamingText: String = ""

    /// 对话错误详情（失败气泡用；成功后置 nil）。
    @Published public internal(set) var chatErrorDetail: KMAIErrorDetail?

    /// 生图进度（对话内的生图消息）。
    @Published public internal(set) var chatImageProgress: KMImageProgress?

    /// 对话生图缩略图（≤512pt PNG）。
    @Published public internal(set) var chatImageThumbnailData: Data?

    // MARK: - 智能联想（design/04 §4）

    /// 联想胶囊文案（≤3 条、每条 ≤12 字）。
    @Published public internal(set) var suggestionChips: [String] = []

    /// 联想请求是否在飞（仅内部用于防重入，不驱动 UI 占位）。
    @Published public internal(set) var suggestIsLoading: Bool = false

    // MARK: - 数据

    /// 配置快照（Provider / 语气 / 短语开关等）。
    @Published public internal(set) var snapshot: ConfigSnapshot = .defaultValue()

    /// 快捷短语（置顶优先）。
    @Published public internal(set) var phrases: [PhraseItem] = []

    /// 剪贴板历史。
    @Published public internal(set) var clipboardItems: [String] = []

    /// 词库诊断摘要（设置页展示）。
    @Published public internal(set) var dictionarySummary: String = ""

    /// 模糊音是否开启（设置页「模糊音」开关；持久化在 `moyu.ime.fuzzy.v1`）。
    ///
    /// 单一真相源是 IMECore 的 `FuzzyPinyinSettings.shared`，本属性只是给 SwiftUI 用的镜像：
    /// `activate()` 时从内核读回来，开关变化时写回内核并刷新这个 `@Published`。
    @Published public internal(set) var fuzzyPinyinEnabled: Bool = true

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

    // MARK: - 对话 / 联想内部状态（不参与视图刷新）

    /// 对话流式请求任务。
    var chatTask: Task<Void, Never>?

    /// 对话生图进度定时任务。
    var chatImageProgressTask: Task<Void, Never>?

    /// 对话生图原图（≤1 张，上屏前若需原图再取；不入 `@Published`）。
    var chatImageOriginalData: Data?

    /// 联想防抖任务。
    var suggestDebounceTask: Task<Void, Never>?

    /// 联想请求任务（新请求前先取消）。
    var suggestTask: Task<Void, Never>?

    /// 联想请求序号（用于丢弃过期响应）。
    var suggestRequestID: UUID = UUID()

    /// 最近一次发起联想请求的时间（节流用）。
    var suggestLastRequestAt: Date = .distantPast

    /// 联想解析失败后的冷却截止时间（失败后 5s 内不再重试）。
    var suggestCooldownUntil: Date = .distantPast

    /// 本地联想索引（ime-core 的 `LocalSuggestionIndex`，与宿主共享学习数据）。
    let localSuggestions: LocalSuggestionIndex = LocalSuggestionIndex(store: .shared)

    /// 面板是否处于「编辑 AI 结果后插入」模式。
    @Published public internal(set) var isEditingAIResult: Bool = false

    /// 候选引擎每页条数（候选栏分页点按 9 条一页）。
    public static let candidatePageSize: Int = 9

    /// 上下文最多取多少字（超出时提示「仅取最近 200 字」）。
    public static let contextCharacterLimit: Int = 200

    // MARK: - 初始化

    /// 创建键盘状态机。
    ///
    /// 可见性说明：`KMInputEngine` 是扩展内部类型，按 Swift「默认参数值不得引用
    /// 比声明更严格的符号」规则，本初始化器不能声明为 `public`，故保持 `internal`。
    /// `KeyboardViewModel` 只在键盘扩展模块内使用（对 `Views/` 同模块可见）。
    /// - Parameters:
    ///   - engine: 输入法内核，默认使用共享单例。
    ///   - configStore: 配置存储，默认使用 `ConfigStore()`（内部走 `SharedStore`）。
    init(engine: KMInputEngine = .shared, configStore: ConfigStore = ConfigStore()) {
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
        // 模糊音是内核级设置（`moyu.ime.fuzzy.v1`），这里把持久化值同步到 UI 镜像。
        fuzzyPinyinEnabled = FuzzyPinyinSettings.shared.options.enabled
        hasFullAccess = KMFullAccessProbe.likelyAvailable()
        refreshAvailability()
        reloadContextPreview()
        recordActiveHeartbeat()
        isReady = true
    }

    /// 切换模糊音开关（设置页 Toggle 调用）。
    ///
    /// 写回内核单例并立即持久化，下一次按键生效；`zh/z`、`ch/c`、`sh/s`、`in/ing`、`l/n`
    /// 这 5 条默认规则保持不变，只改开关。
    /// - Parameter enabled: 是否启用模糊音。
    public func setFuzzyPinyinEnabled(_ enabled: Bool) {
        _ = FuzzyPinyinSettings.shared.setEnabled(enabled)
        fuzzyPinyinEnabled = FuzzyPinyinSettings.shared.options.enabled
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
        // AI 对话页：字符 / 退格 / 空格 / 回车写入 `chatDraft`，不碰宿主输入框（design/04 §3.8–§3.9）。
        if page == .aiChat {
            switch key {
            case let .character(text):
                appendChatDraft(text)
                return
            case .backspace:
                deleteChatDraftCharacter()
                return
            case .space:
                appendChatDraft(" ")
                return
            case .newline:
                sendChatMessage()
                return
            case .shift:
                handleShift()
                return
            default:
                break
            }
        }

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
    /// - Parameter index: 候选下标（**已过滤后的可见下标**）。
    public func selectCandidate(at index: Int) {
        guard let absolute = candidateAbsoluteIndex(visibleIndex: index) else { return }
        let candidate = candidates[absolute]
        engine.commit(candidate, input: composing)
        insertText(candidate.text)
        lastCommittedText = candidate.text
        clearComposing()
        refreshPredictions()
        KMHaptics.candidate()
        // 上屏后启动 AI 联想防抖（design/04 §4.4 触发时机 A）。
        scheduleSuggestions()
    }

    /// 把「当前页的可见下标」换算成 `candidates` 里的绝对下标。
    ///
    /// 关掉「输入纠错」后可见列表会过滤掉 `isTypoCorrection` 候选，
    /// 因此视图传进来的下标必须经过这一层换算，否则会点错词。
    /// - Parameter index: 当前页内的可见下标。
    /// - Returns: 绝对下标；越界返回 `nil`。
    public func candidateAbsoluteIndex(visibleIndex: Int) -> Int? {
        let page = currentPageCandidates
        guard page.indices.contains(visibleIndex) else { return nil }
        let target = page[visibleIndex]
        return candidates.firstIndex(where: { $0.text == target.text && $0.pinyin == target.pinyin })
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

    /// 过滤掉被开关关闭的纠错候选。
    ///
    /// `PinyinEngine+TypoCorrection` 产出的候选带 `isTypoCorrection = true`；
    /// 设置里关掉「输入纠错」（`snapshot.enableTypoCorrection == false`）后，
    /// 这里在视图取数前统一滤掉，翻页计数也一并不再算它们。
    private var visibleCandidates: [IMECandidate] {
        snapshot.enableTypoCorrection ? candidates : candidates.filter { !$0.isTypoCorrection }
    }

    /// 当前页候选。
    public var currentPageCandidates: [IMECandidate] {
        let source = visibleCandidates
        let size = Self.candidatePageSize
        let start = candidatePageIndex * size
        guard start < source.count else { return [] }
        let end = min(start + size, source.count)
        return Array(source[start..<end])
    }

    /// 候选总页数。
    public var candidatePageCount: Int {
        let size = Self.candidatePageSize
        let count = visibleCandidates.count
        guard count > 0 else { return 1 }
        return (count + size - 1) / size
    }

    // MARK: - 页面

    /// 切换到指定页面。
    /// - Parameter target: 目标页面。
    public func go(to target: Page) {
        guard page != target else { return }
        let leavingChat = page == .aiChat
        let leavingVoice = page == .voice
        overlay = .none
        let wasExpanded = page.isExpanded
        page = target
        if leavingVoice {
            // 任何路径离开语音页都要停录音：否则麦克风会话会留在后台继续吃电与隐私额度
            // （`closeVoiceInput()` 走同一条路，这里是兜底，防止从别处直接 `go(to:)`）。
            KMVoiceInput.shared.cancel()
        }
        if target != .result {
            cancelAI(silently: true)
            aiState = .idle
            streamingText = ""
            lastAIErrorDetail = nil
            imageThumbnailData = nil
            replySuggestions = []
        }
        if leavingChat {
            // 离开对话：停掉在飞请求与定时任务，但**保留 chatMessages**（设计 §3.1）。
            suspendChatTasks()
            isChatOpen = false
        }
        if target == .aiChat {
            isChatOpen = true
            refreshAvailability()
            prepareChatSessionIfNeeded()
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
        if target != .letters && target != .numbers {
            clearSuggestions()
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
}
