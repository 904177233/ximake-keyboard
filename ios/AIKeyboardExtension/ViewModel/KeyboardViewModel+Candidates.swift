//
//  KeyboardViewModel+Candidates.swift
//  墨语（Moyu）键盘扩展 · 候选与空格上屏
//
//  模块职责：候选列表的取数（含「输入纠错」开关的可见性过滤）与上屏动作。
//  从 KeyboardViewModel.swift 拆出来：主文件已贴 600 行上限（docs/02 §3.7）。
//  约束：可见性过滤只有 visibleCandidates 一个入口，视图下标必须经
//        candidateAbsoluteIndex(visibleIndex:) 换算成 candidates 的绝对下标。
//

import Foundation

extension KeyboardViewModel {

    /// 候选栏滑动时移动高亮（**不上屏**，松手才由 `selectCandidate` 真正上屏）。
    /// - Parameter index: 候选下标（本页内的可见下标）。
    public func highlightCandidate(at index: Int) {
        guard currentPageCandidates.indices.contains(index) else { return }
        guard highlightedCandidateIndex != index else { return }
        highlightedCandidateIndex = index
        KMHaptics.chip()
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

    /// 空格键：**组字时上屏首选，未组字时输入空格**。
    ///
    /// v1.4 修用户反馈「空格居然不能选候选词，你到底有没有研究过国产输入法」——
    /// 空格选首选是国产输入法（微信/搜狗/百度/Gboard）的通用约定：
    /// 打出拼音后按空格 = 直接上屏第一个候选，这是最高频的一次交互。
    /// 组字中却没有候选（例如只打了非法拼音）时仍然补一个空格，不做静默吞键。
    private func handleSpace() {
        if !composing.isEmpty, !currentPageCandidates.isEmpty {
            selectCandidate(at: 0)
            return
        }
        if !composing.isEmpty {
            // 组字中但没有任何候选：先清掉 marked text，再补空格，避免拼音串与空格混在输入框里。
            clearComposing()
        }
        commitLiteral(" ")
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

    // 文本写入相关的 `insertText` / `clearComposing` / `reloadContextPreview` 见
    }
