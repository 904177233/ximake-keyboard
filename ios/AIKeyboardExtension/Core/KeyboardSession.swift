//
//  KeyboardSession.swift
//  墨语键盘 · 状态中心
//
//  键盘的全部状态和动作都在这里：当前哪一页、中英文、组字、候选、往哪写字。
//  UIKit 部分（键区、顶栏）由 onRender 回调刷新，SwiftUI 面板订阅 @Published。
//

import Combine
import SwiftUI
import UIKit

/// 控制器提供给状态中心的能力。
@MainActor
protocol KeyboardHost: AnyObject {
    var documentProxy: UITextDocumentProxy { get }
    var hostHasFullAccess: Bool { get }
    var hostNeedsSwitchKey: Bool { get }
    var heightDiagnostic: String { get }
    func goToNextKeyboard()
    func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void)
}

@MainActor
final class KeyboardSession: ObservableObject {

    /// 页面。
    enum Page: Equatable {
        case keys, numbers, symbols, candidates, ai, chat, settings, field, voice
    }

    /// 符号面板的页签。
    enum SymbolTab: String, CaseIterable, Identifiable {
        case emoji, chinese, english, math, phrases, clipboard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .emoji: return "表情"
            case .chinese: return "中文"
            case .english: return "英文"
            case .math: return "数学"
            case .phrases: return "短语"
            case .clipboard: return "剪贴板"
            }
        }
    }

    /// 正在编辑的设置项（键盘里不能用系统输入框，所以用自己的键区往草稿里打）。
    struct FieldEdit {
        let title: String
        let isSecret: Bool
        let onDone: (String) -> Void
    }

    /// 长按空格说话的状态。
    enum VoiceHold: Equatable {
        case off, listening, cancelling, transcribing
    }

    /// 语音面板显示什么。录音在 App 里，这里只是看结果。
    enum VoicePanelState: Equatable {
        case opening, listening, transcribing, waitingInApp
        case failed(String)
    }

    /// 组字中已经选好的一段。
    private struct Segment {
        let text: String
        let key: String
        let raw: [Character]
    }

    // MARK: - 给界面看的状态

    @Published private(set) var page: Page = .keys
    @Published var symbolTab: SymbolTab = .emoji
    @Published private(set) var draft = ""
    @Published private(set) var toast: String?
    @Published private(set) var prefs: KeyboardPrefs
    @Published private(set) var snapshot: ConfigSnapshot
    @Published private(set) var palette: MoyuPalette
    @Published private(set) var conversion: IMEConversion = .empty
    @Published private(set) var fieldEdit: FieldEdit?
    @Published var settingsRoute: SettingsRoute = .home
    /// 对话页：true 在打字（有键区），false 在看回答（消息占满）。
    @Published private(set) var chatTyping = true
    @Published private(set) var voiceState: VoicePanelState = .opening
    @Published private(set) var voiceText = ""
    @Published private(set) var voiceHold: VoiceHold = .off
    /// 在键盘上拖动调高度。
    @Published private(set) var isResizing = false

    /// 是否深色（控制器根据外观回填）。
    private(set) var isDark = false
    /// 是否横屏（控制器回填）。
    private(set) var isLandscape = false

    private(set) var isChinese = true
    private(set) var shift: KeyboardVisualState.Shift = .off
    private var lastShiftTap = Date.distantPast

    private var raw: [Character] = []
    private var selected: [Segment] = []
    private var locks: [Int: UInt8] = [:]
    private var breaks: Set<Int> = []

    private var showingTools = true
    private(set) var predictions: [String] = []
    private(set) var aiSuggestions: [String] = []
    private var lastCommit = ""
    private var documentIdentifier: UUID?
    private var isActive = false
    private var toastTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var appAliveAt: Date?
    private var signalsReady = false

    /// UIKit 部分需要刷新时调用。
    var onRender: (() -> Void)?

    /// 控制器。
    weak var host: KeyboardHost?

    /// 内核（键盘第一次弹出时创建）。
    private(set) lazy var kit: IMEKit = {
        IMEKit(store: SharedStore.shared, clipboardEnabled: snapshot.enableClipboardHistory)
    }()

    private let configStore = ConfigStore()

    lazy var ai = AIPanelModel(session: self)
    lazy var chat = ChatModel(session: self)
    lazy var suggest = SuggestEngine(session: self)
    lazy var settings = SettingsModel(session: self)

    init() {
        let prefs = KeyboardPrefs.load()
        self.prefs = prefs
        self.snapshot = ConfigStore().load()
        self.palette = MoyuPalette(theme: prefs.theme, dark: false)
    }

    // MARK: - 生命周期

    /// 键盘要显示了：重新读配置（可能刚在 App 里改过），准备内核。
    func activate() {
        isActive = true
        // 每次弹出都从打字页开始，上次停在对话或设置页也一样
        page = .keys
        fieldEdit = nil
        draft = ""
        prefs = KeyboardPrefs.load()
        snapshot = loadedSnapshot()
        kit.learning.isEnabled = snapshot.enableLearning
        kit.reloadPhrases()
        _ = FuzzyPinyinSettings.shared.setEnabled(prefs.fuzzyPinyin)
        palette = MoyuPalette(theme: prefs.theme, dark: isDark)
        syncWithDocument(force: true)
        kit.learning.reloadIfChanged()
        setUpVoiceSignals()
        VoiceSignals.post(.ping)
        resumeVoice()
        render()
    }

    /// 读配置。默认的那家没填 Key、别的填了的话，用填了的。
    private func loadedSnapshot() -> ConfigSnapshot {
        var loaded = configStore.load()
        PresetProviders.repairDefaults(&loaded) { KeychainStore.shared.hasAPIKey(for: $0) }
        return loaded
    }

    /// 键盘收起：停掉所有请求，把学习数据写盘。
    func deactivate() {
        isActive = false
        ai.cancel()
        chat.cancel()
        suggest.cancel()
        kit.learning.flush()
        voiceTask?.cancel()
        voiceTask = nil
        if voiceHold != .off {
            holdTask?.cancel()
            VoiceSignals.post(.discard)
            voiceHold = .off
        }
        if isResizing {
            isResizing = false
            prefs.save()
        }
        if page == .voice {
            page = .keys
        }
    }

    /// 外观变化。
    func setAppearance(dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        palette = MoyuPalette(theme: prefs.theme, dark: dark)
        render()
    }

    /// 横竖屏变化。
    func setLandscape(_ landscape: Bool) {
        guard landscape != isLandscape else { return }
        isLandscape = landscape
        render()
    }

    /// 宿主输入框内容变化。
    func documentDidChange() {
        syncWithDocument(force: false)
        render()
    }

    /// 换了输入框时重置状态，并按输入框类型选中/英文和数字页。
    private func syncWithDocument(force: Bool) {
        guard let proxy = host?.documentProxy else { return }
        let identifier = proxy.documentIdentifier
        guard force || identifier != documentIdentifier else {
            updateAutoCapitalization()
            return
        }
        documentIdentifier = identifier
        resetComposition()
        predictions = []
        aiSuggestions = []
        showingTools = true
        if page != .chat, page != .field, page != .settings {
            page = .keys
        }
        switch proxy.keyboardType ?? .default {
        case .numberPad, .decimalPad, .asciiCapableNumberPad, .phonePad, .numbersAndPunctuation:
            page = .numbers
        case .URL, .emailAddress, .asciiCapable, .twitter:
            isChinese = false
        default:
            isChinese = true
        }
        shift = .off
        updateAutoCapitalization()
    }

    // MARK: - 派生状态

    var isComposing: Bool { !raw.isEmpty || !selected.isEmpty }

    private var usesNineKey: Bool { prefs.layout == .nineKey && isChinese }

    /// 字往哪写：聊天面板和设置项写草稿，其余写输入框。
    private var writesToDraft: Bool { page == .chat || page == .field }

    /// 键区该长什么样。
    var visualState: KeyboardVisualState {
        var state = KeyboardVisualState()
        switch page {
        case .numbers:
            state.kind = .numbers
        default:
            state.kind = usesNineKey ? .nineKey : .qwerty
        }
        state.isChinese = isChinese
        state.shift = shift
        state.isComposing = isComposing
        state.showsNextKeyboard = host?.hostNeedsSwitchKey ?? false

        if isComposing {
            state.returnTitle = "确认"
        } else if page == .chat {
            state.returnTitle = "发送"
            state.returnIsAccent = true
        } else if page == .field {
            state.returnTitle = "完成"
            state.returnIsAccent = true
        } else if let proxy = host?.documentProxy {
            switch proxy.returnKeyType ?? .default {
            case .send:
                state.returnTitle = "发送"
                state.returnIsAccent = true
            case .search, .google, .yahoo:
                state.returnTitle = "搜索"
                state.returnIsAccent = true
            case .go, .route:
                state.returnTitle = "前往"
                state.returnIsAccent = true
            case .done:
                state.returnTitle = "完成"
                state.returnIsAccent = true
            case .join:
                state.returnTitle = "加入"
                state.returnIsAccent = true
            case .next:
                state.returnTitle = "下一项"
            case .continue:
                state.returnTitle = "继续"
            default:
                state.returnTitle = "换行"
            }
            if proxy.enablesReturnKeyAutomatically == true, state.returnIsAccent, !proxy.hasText {
                state.returnIsDisabled = true
            }
        }
        return state
    }

    /// 顶栏内容。
    var topBarContent: TopBarContent {
        if isComposing {
            let cells = conversion.candidates.prefix(40)
            var marks: [Int: String] = [:]
            for (index, cell) in cells.enumerated() {
                if cell.kind == .raw {
                    marks[index] = "原样"
                } else if cell.kind == .corrected {
                    marks[index] = "纠错"
                }
            }
            return .composing(selected: selected.map { $0.text }.joined(),
                              spelling: conversion.spelling,
                              candidates: cells.map { $0.text },
                              marks: marks)
        }
        if page == .chat {
            return .options(chat.optionTitles)
        }
        if page == .field {
            return .hint("正在填写：\(fieldEdit?.title ?? "")")
        }
        if !showingTools, !(predictions.isEmpty && aiSuggestions.isEmpty) {
            return .suggestions(words: predictions, aiWords: aiSuggestions)
        }
        return .tools
    }

    /// 九宫格左栏内容。
    var sideStripItems: [String] {
        isComposing && !raw.isEmpty ? conversion.pinyinChoices : ["，", "。", "？", "！", "、", "…", "～", "："]
    }

    /// 顶栏工具。
    var tools: [ToolID] {
        var list: [ToolID] = [.polish, .translate, .reply, .expand, .image, .voice]
        if host?.hostNeedsSwitchKey == true {
            list.append(.symbols)
        }
        list.append(contentsOf: [.clipboard, .phrases, .layout, .settings])
        return list
    }

    /// 小形象图片。
    var mascotImage: UIImage? {
        if let name = prefs.mascot.systemName {
            return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        }
        if let data = SharedStore.shared.data(forKey: SharedStoreKey.customMascot) {
            return UIImage(data: data)
        }
        return UIImage(systemName: "drop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
    }

    func render() {
        onRender?()
    }

    // MARK: - 按键

    /// 处理一个按键动作。
    func handle(_ action: KeyAction) {
        switch action {
        case let .letter(character):
            handleLetter(character)
        case let .t9(digit):
            raw.append(digit)
            recompute()
            leaveIdleState()
        case let .text(text):
            if isComposing { commitTopCandidate() }
            insert(text)
        case let .punctuation(text):
            handlePunctuation(text)
        case .separator:
            if !raw.isEmpty {
                breaks.insert(raw.count)
                recompute()
            } else {
                insert("'")
            }
        case .backspace:
            handleBackspace()
        case .shift:
            handleShift()
        case .space:
            handleSpace()
        case .enter:
            handleEnter()
        case .language:
            commitTopCandidate()
            isChinese.toggle()
            shift = .off
            updateAutoCapitalization()
        case .showNumbers:
            commitTopCandidate()
            setPage(.numbers)
        case .showLetters:
            setPage(.keys)
        case .showSymbols:
            commitTopCandidate()
            symbolTab = .emoji
            setPage(.symbols)
        case .clearComposition:
            resetComposition()
            showingTools = true
        case .toggleLayout:
            toggleLayout()
        case .nextKeyboard:
            host?.goToNextKeyboard()
        }
        render()
    }

    private func leaveIdleState() {
        showingTools = false
        predictions = []
        aiSuggestions = []
        suggest.cancel()
    }

    private func handleLetter(_ character: Character) {
        let output = shift == .off ? character : Character(String(character).uppercased())
        if shift == .once {
            shift = .off
        }
        if isChinese {
            raw.append(output)
            recompute()
            leaveIdleState()
        } else {
            insert(String(output))
        }
    }

    private func handlePunctuation(_ text: String) {
        if isComposing { commitTopCandidate() }
        // 数字后面的句号大多是小数点
        if text == "。", let last = lastCharacterBeforeCursor, last.isNumber {
            insert(".")
        } else {
            insert(text)
        }
    }

    private var lastCharacterBeforeCursor: Character? {
        writesToDraft ? draft.last : host?.documentProxy.documentContextBeforeInput?.last
    }

    private func handleBackspace() {
        if !raw.isEmpty {
            raw.removeLast()
            locks[raw.count] = nil
            breaks.remove(raw.count)
            if raw.isEmpty, let last = selected.popLast() {
                raw = last.raw
            }
            if raw.isEmpty {
                resetComposition()
                showingTools = true
            } else {
                recompute()
            }
            return
        }
        if writesToDraft {
            if !draft.isEmpty {
                draft.removeLast()
            }
            return
        }
        host?.documentProxy.deleteBackward()
        predictions = []
        aiSuggestions = []
        showingTools = true
        suggest.cancel()
        updateAutoCapitalization()
    }

    private func handleShift() {
        let now = Date()
        if shift == .once, now.timeIntervalSince(lastShiftTap) < 0.32 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
    }

    private func handleSpace() {
        if isComposing {
            if conversion.candidates.isEmpty {
                commitLiteral()
            } else {
                chooseCandidate(at: 0)
            }
            return
        }
        // 英文连按两下空格 = 句号
        if !isChinese, !writesToDraft, let before = host?.documentProxy.documentContextBeforeInput,
           before.hasSuffix(" "), before.dropLast().last?.isLetter == true {
            host?.documentProxy.deleteBackward()
            insert(". ")
            return
        }
        insert(" ")
    }

    private func handleEnter() {
        if isComposing {
            commitLiteral()
            return
        }
        switch page {
        case .chat:
            chat.send()
        case .field:
            finishField(save: true)
        default:
            host?.documentProxy.insertText("\n")
            predictions = []
            aiSuggestions = []
            showingTools = true
            updateAutoCapitalization()
        }
    }

    /// 写字：写到输入框或草稿。
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        if writesToDraft {
            draft += text
        } else {
            host?.documentProxy.insertText(text)
            updateAutoCapitalization()
        }
    }

    /// 空格滑动移光标。
    func moveCursor(by offset: Int) {
        guard !isComposing, !writesToDraft, offset != 0 else { return }
        host?.documentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    /// 英文模式下按输入框要求自动大写。
    private func updateAutoCapitalization() {
        guard !isChinese, shift != .locked, let proxy = host?.documentProxy else { return }
        guard !writesToDraft else {
            if shift == .once { shift = .off }
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let wantsUpper: Bool
        let capitalization: UITextAutocapitalizationType = proxy.autocapitalizationType ?? UITextAutocapitalizationType.none
        switch capitalization {
        case .allCharacters:
            wantsUpper = true
        case .words:
            wantsUpper = before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            wantsUpper = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("!")
                || trimmed.hasSuffix("?") || trimmed.hasSuffix("\n")
        default:
            wantsUpper = false
        }
        shift = wantsUpper ? .once : .off
    }

    // MARK: - 组字

    private func makeQuery() -> IMEQuery {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count)
        for character in raw {
            if let byte = String(character).lowercased().utf8.first {
                bytes.append(byte)
            }
        }
        return IMEQuery(mode: usesNineKey ? .t9 : .qwerty, input: bytes, breaks: breaks, locks: locks)
    }

    private func recompute() {
        guard !raw.isEmpty else {
            conversion = .empty
            return
        }
        var result = kit.engine.convert(makeQuery(),
                                        rawText: usesNineKey ? nil : String(raw),
                                        fuzzy: FuzzyPinyinSettings.shared.options,
                                        typoCorrection: snapshot.enableTypoCorrection)
        // 短语快捷键（dz -> 我的地址）放最前面
        if !usesNineKey, let phrase = kit.phrases.match(key: String(raw).lowercased()) {
            let text = kit.phrases.expand(phrase, clipboard: nil)
            result.candidates.insert(IMECandidate(text: text, key: "", consumed: raw.count, kind: .word), at: 0)
        }
        conversion = result
    }

    private func resetComposition() {
        raw = []
        selected = []
        locks = [:]
        breaks = []
        conversion = .empty
    }

    /// 选一个候选。
    func chooseCandidate(at index: Int) {
        guard conversion.candidates.indices.contains(index) else { return }
        let candidate = conversion.candidates[index]
        if candidate.kind == .raw, candidate.key.isEmpty, candidate.text == String(raw) {
            commitLiteral()
            render()
            return
        }
        let consumed = min(max(candidate.consumed, 1), raw.count)
        selected.append(Segment(text: candidate.text, key: candidate.key, raw: Array(raw.prefix(consumed))))
        raw.removeFirst(consumed)
        // 选定字母和分词位置跟着前移
        var movedLocks: [Int: UInt8] = [:]
        for (position, byte) in locks where position >= consumed {
            movedLocks[position - consumed] = byte
        }
        locks = movedLocks
        breaks = Set(breaks.compactMap { $0 > consumed ? $0 - consumed : nil })

        if raw.isEmpty {
            finishComposition()
        } else {
            recompute()
        }
        if page == .candidates {
            page = .keys
        }
        render()
    }

    /// 全部选完：上屏并学习。
    private func finishComposition() {
        let segments = selected
        let text = segments.map { $0.text }.joined()
        resetComposition()
        insert(text)
        kit.engine.learn(segments: segments.filter { !$0.key.isEmpty }.map { (text: $0.text, key: $0.key) })
        // 简拼时按打的字母也记一份，下次打同样的字母直接排第一
        var typed: [(text: String, typed: String)] = []
        for segment in segments {
            let letters = String(segment.raw).lowercased()
            if !letters.isEmpty, letters != segment.key, letters.allSatisfy({ $0.isASCII && $0.isLetter }) {
                typed.append((segment.text, letters))
            }
        }
        let allLetters = segments.map { String($0.raw) }.joined().lowercased()
        if segments.count >= 2, allLetters.allSatisfy({ $0.isASCII && $0.isLetter }),
           allLetters != segments.map(\.key).joined() {
            typed.append((text, allLetters))
        }
        kit.learning.recordTyped(typed)
        didCommit(text)
    }

    /// 上屏后：记先后关系，给联想。
    private func didCommit(_ text: String) {
        kit.learning.recordFollow(previous: lastCommit, current: text)
        lastCommit = text
        if writesToDraft {
            predictions = []
            showingTools = true
            return
        }
        predictions = kit.engine.predictions(after: text, limit: 14)
        aiSuggestions = []
        showingTools = predictions.isEmpty
        suggest.schedule()
    }

    /// 按原样上屏（回车）：已选的词 + 没转换的字母。
    func commitLiteral() {
        let text = selected.map { $0.text }.joined() + String(raw)
        resetComposition()
        insert(text)
        predictions = []
        showingTools = true
    }

    /// 上屏首选（打标点、切键盘时）。
    private func commitTopCandidate() {
        var guardCount = 0
        while !raw.isEmpty, guardCount < 32 {
            guardCount += 1
            guard let top = conversion.candidates.first else {
                commitLiteral()
                return
            }
            if top.kind == .raw {
                commitLiteral()
                return
            }
            let consumed = min(max(top.consumed, 1), raw.count)
            selected.append(Segment(text: top.text, key: top.key, raw: Array(raw.prefix(consumed))))
            raw.removeFirst(consumed)
            if raw.isEmpty {
                finishComposition()
                return
            }
            recompute()
        }
        if !selected.isEmpty, raw.isEmpty {
            finishComposition()
        }
    }

    /// 九宫格左栏被点了。
    func selectSideStrip(at index: Int) {
        let items = sideStripItems
        guard items.indices.contains(index) else { return }
        if isComposing, !raw.isEmpty {
            for (offset, byte) in items[index].utf8.enumerated() where offset < raw.count {
                locks[offset] = byte
            }
            recompute()
        } else {
            insert(items[index])
        }
        render()
    }

    /// 退格左滑：清空组字。
    func clearCompositionBySwipe() {
        guard isComposing else { return }
        resetComposition()
        showingTools = true
        render()
    }

    // MARK: - 联想

    /// 顶栏联想被点了。AI 给的排在前面。
    func chooseSuggestion(at index: Int) {
        if page == .chat {
            chat.cycleOption(at: index)
            return
        }
        let words = aiSuggestions + predictions
        guard words.indices.contains(index) else { return }
        let word = words[index]
        insert(word)
        if index < aiSuggestions.count {
            suggest.recordAccepted(word)
        }
        didCommit(word)
        render()
    }

    /// AI 联想回来了。
    func setAISuggestions(_ words: [String]) {
        guard !isComposing, page == .keys || page == .numbers else { return }
        aiSuggestions = words
        if !words.isEmpty {
            showingTools = false
        }
        render()
    }

    func showTools() {
        showingTools = true
        predictions = []
        aiSuggestions = []
        render()
    }

    // MARK: - 页面

    func setPage(_ target: Page) {
        guard page != target else { return }
        if page == .voice {
            voiceTask?.cancel()
            voiceTask = nil
            if voiceState == .listening {
                VoiceBridge.send(.discard)
                VoiceSignals.post(.discard)
            }
        }
        if page == .chat || page == .field {
            resetComposition()
            draft = ""
        }
        page = target
        render()
    }

    func closePanel() {
        ai.cancel()
        setPage(.keys)
    }

    /// 箭头：展开或收起全部候选。
    func expandCandidates() {
        setPage(page == .candidates ? .keys : .candidates)
    }

    func toggleLayout() {
        resetComposition()
        updatePrefs { $0.layout = $0.layout == .qwerty ? .nineKey : .qwerty }
        showToast(prefs.layout == .qwerty ? "26 键" : "九宫格")
    }

    /// 工具栏按钮。
    func runTool(_ tool: ToolID) {
        switch tool {
        case .polish:
            openAI(.polish)
        case .translate:
            openAI(.translate)
        case .reply:
            openAI(.reply)
        case .expand:
            openAI(.expand)
        case .image:
            openAI(.image)
        case .voice:
            openVoice()
        case .symbols:
            symbolTab = .emoji
            setPage(.symbols)
        case .clipboard:
            symbolTab = .clipboard
            setPage(.symbols)
        case .phrases:
            symbolTab = .phrases
            setPage(.symbols)
        case .layout:
            toggleLayout()
        case .settings:
            openSettings()
        }
    }

    /// AI 能不能用；不能用就把人带到该去的地方。
    var aiBlocker: AIBlocker? {
        guard host?.hostHasFullAccess == true else { return .noFullAccess }
        guard let provider = snapshot.defaultProvider, provider.isChatConfigured,
              KeychainStore.shared.hasAPIKey(for: provider.id) else { return .notConfigured }
        return nil
    }

    func openAI(_ feature: AIPanelFeature) {
        snapshot = loadedSnapshot()
        ai.open(feature)
        setPage(.ai)
    }

    func openChat() {
        snapshot = loadedSnapshot()
        chat.prepare()
        resetComposition()
        draft = ""
        // 聊过的话先给看回答，没聊过直接打字
        chatTyping = chat.messages.isEmpty
        setPage(.chat)
    }

    /// 对话页在打字和看回答之间切换。
    func setChatTyping(_ typing: Bool) {
        guard chatTyping != typing else { return }
        chatTyping = typing
        render()
    }

    func openSettings() {
        snapshot = loadedSnapshot()
        settingsRoute = .home
        setPage(.settings)
    }

    /// 直接进 AI 服务列表（没配服务时从 AI 面板跳过来）。
    func openProviderSettings() {
        snapshot = loadedSnapshot()
        settingsRoute = .providers
        setPage(.settings)
    }

    /// 点麦克风：App 的语音会话开着就直接在这里听；没开就跳到 App 里打开（苹果不给键盘用麦克风）。
    func openVoice() {
        guard host?.hostHasFullAccess == true else {
            showToast("先在系统设置里打开「允许完全访问」")
            return
        }
        setUpVoiceSignals()
        voiceText = ""
        if isAppVoiceAlive {
            VoiceSignals.post(.start)
            VoiceBridge.send(.start)
            voiceState = .listening
            setPage(.voice)
            startVoicePolling()
            return
        }
        guard let url = URL(string: "moyu://voice") else { return }
        VoiceBridge.clear()
        voiceState = .opening
        setPage(.voice)
        host?.openContainingApp(url) { [weak self] success in
            guard let self, !success, self.page == .voice else { return }
            self.voiceState = .failed("打不开墨语。手动打开墨语 App，在「键盘」页点「说话转文字」，说完回到这里会自动放进输入框。")
        }
    }

    /// 键盘弹出时看看语音那边怎么样了。
    private func resumeVoice() {
        guard host?.hostHasFullAccess == true else { return }
        if let text = VoiceBridge.takeFinishedText() {
            deliverVoice(text)
            return
        }
        if let state = VoiceBridge.readState(), state.isFresh, state.status == .listening || state.status == .transcribing {
            page = .voice
            applyVoice(state)
            startVoicePolling()
        }
    }

    private func applyVoice(_ state: VoiceBridgeState) {
        voiceText = state.text
        voiceState = state.status == .transcribing ? .transcribing : .listening
    }

    private func startVoicePolling() {
        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self, self.page == .voice else { return }
                self.pollVoice()
            }
        }
    }

    private func pollVoice() {
        if let text = VoiceBridge.takeFinishedText() {
            setPage(.keys)
            deliverVoice(text)
            return
        }
        guard let state = VoiceBridge.readState() else { return }
        if state.status == .failed {
            voiceState = .failed(state.text)
            VoiceBridge.clear()
        } else if !state.isFresh {
            voiceState = .failed("录音断了，再点一次麦克风。")
            VoiceBridge.clear()
        } else {
            applyVoice(state)
        }
    }

    /// 刚弹出时输入框还没接好，等一下再写。
    private func deliverVoice(_ text: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.host?.documentProxy.insertText(text)
            self.showToast("已放进输入框")
        }
    }

    /// 语音面板上的「说完了」。
    func finishVoice() {
        VoiceBridge.send(.stop)
        VoiceSignals.post(.stop)
        voiceState = .transcribing
    }

    // MARK: - 长按空格说话

    private func setUpVoiceSignals() {
        guard !signalsReady else { return }
        signalsReady = true
        VoiceSignals.observe(.pong) { [weak self] in
            self?.appAliveAt = Date()
        }
        VoiceSignals.observe(.done) { [weak self] in
            self?.voiceResultReady()
        }
    }

    /// App 的语音会话开着。
    private var isAppVoiceAlive: Bool {
        if let appAliveAt, Date().timeIntervalSince(appAliveAt) < 20 {
            return true
        }
        if let state = VoiceBridge.readState(), state.isFresh,
           state.status == .ready || state.status == .listening || state.status == .transcribing {
            return true
        }
        return false
    }

    func beginVoiceHold() {
        guard host?.hostHasFullAccess == true else {
            showToast("先在系统设置里打开「允许完全访问」")
            return
        }
        setUpVoiceSignals()
        if isComposing {
            commitTopCandidate()
        }
        VoiceSignals.post(.ping)
        VoiceSignals.post(.start)
        VoiceBridge.send(.start)
        voiceText = ""
        voiceHold = .listening
        render()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            // 等一下 App 的回应：没开着就跳过去开
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.voiceHold != .off else { return }
            guard self.isAppVoiceAlive else {
                self.voiceHold = .off
                self.render()
                self.showToast("先到墨语里打开语音，之后长按空格就能直接说")
                self.openVoice()
                return
            }
            while !Task.isCancelled, self.voiceHold == .listening || self.voiceHold == .cancelling {
                if let state = VoiceBridge.readState(), state.status == .listening, state.text != self.voiceText {
                    self.voiceText = state.text
                    self.render()
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func updateVoiceHold(cancel: Bool) {
        guard voiceHold == .listening || voiceHold == .cancelling else { return }
        voiceHold = cancel ? .cancelling : .listening
        render()
    }

    func endVoiceHold(cancelled: Bool) {
        holdTask?.cancel()
        guard voiceHold != .off else { return }
        if cancelled {
            VoiceSignals.post(.discard)
            VoiceBridge.send(.discard)
            voiceHold = .off
            render()
            return
        }
        VoiceSignals.post(.stop)
        VoiceBridge.send(.stop)
        voiceHold = .transcribing
        render()
        holdTask = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.voiceHold == .transcribing else { return }
                if self.takeVoiceResult() { return }
            }
            guard let self, self.voiceHold == .transcribing else { return }
            self.voiceHold = .off
            self.render()
            self.showToast("没等到结果，再说一次")
        }
    }

    /// App 说结果好了。
    private func voiceResultReady() {
        if voiceHold == .transcribing {
            _ = takeVoiceResult()
        } else if page == .voice {
            pollVoice()
        }
    }

    /// 取结果放进输入框。取到了返回 true。
    private func takeVoiceResult() -> Bool {
        if let text = VoiceBridge.takeFinishedText() {
            voiceHold = .off
            render()
            deliverVoice(text)
            return true
        }
        if let state = VoiceBridge.readState(), state.status == .failed {
            voiceHold = .off
            render()
            showToast(state.text)
            VoiceBridge.clear()
            return true
        }
        return false
    }

    // MARK: - 拖动调高度

    func beginResize() {
        setPage(.keys)
        isResizing = true
        render()
    }

    func resize(toSurfaceHeight height: CGFloat) {
        prefs.customSurfaceHeight = Double(height)
        render()
    }

    func endResize() {
        isResizing = false
        prefs.save()
        render()
        showToast("高度已保存")
    }

    func resetHeight() {
        prefs.customSurfaceHeight = nil
        prefs.save()
        render()
    }

    #if MOYU_SIM_CHECK
    func showVoiceHoldForSimCheck() {
        voiceText = "今天下午三点开会"
        voiceHold = .listening
        render()
    }

    func showVoicePanelForSimCheck() {
        voiceText = "今天下午三点开会"
        voiceState = .listening
        setPage(.voice)
    }
    #endif

    // MARK: - 设置项编辑

    func beginField(title: String, value: String, isSecret: Bool, preferEnglish: Bool, onDone: @escaping (String) -> Void) {
        fieldEdit = FieldEdit(title: title, isSecret: isSecret, onDone: onDone)
        resetComposition()
        draft = value
        if preferEnglish {
            isChinese = false
            shift = .off
        }
        page = .field
        render()
    }

    func finishField(save: Bool) {
        commitTopCandidate()
        let value = draft
        let edit = fieldEdit
        fieldEdit = nil
        draft = ""
        resetComposition()
        isChinese = true
        page = .settings
        if save {
            edit?.onDone(value)
        }
        render()
    }

    /// 粘贴到草稿（填 API Key 最常用）。
    func pasteIntoDraft() {
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string else {
            showToast("剪贴板里没有文字")
            return
        }
        draft += text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearDraft() {
        draft = ""
    }

    /// 把草稿整个拿走（发送用）。
    func takeDraft() -> String {
        commitTopCandidate()
        let value = draft
        draft = ""
        render()
        return value
    }

    // MARK: - 偏好与配置

    func updatePrefs(_ change: (inout KeyboardPrefs) -> Void) {
        change(&prefs)
        prefs.save()
        palette = MoyuPalette(theme: prefs.theme, dark: isDark)
        render()
    }

    func saveConfig(_ updated: ConfigSnapshot) {
        configStore.save(updated)
        snapshot = updated
        kit.learning.isEnabled = updated.enableLearning
        render()
    }

    // MARK: - 提示

    func showToast(_ text: String) {
        toast = text
        render()
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.toast = nil
            self.render()
        }
    }
}

/// AI 用不了的原因。
enum AIBlocker {
    case noFullAccess, notConfigured
}
