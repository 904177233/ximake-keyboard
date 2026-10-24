//
//  KeyboardViewModel+Suggest.swift
//  墨语（Moyu）键盘扩展 · 智能联想（L1 本地 + L2 AI 覆盖）
//
//  模块职责：候选栏上方的「你可能想说的下一句」胶囊（design/04 §4）。
//            L1：`LocalSuggestionIndex` 本地规则 + 学习，毫秒级秒出；
//            L2：AI 生成覆盖（防抖 0.35s、节流 3s、超时 1.5s、失败**完全静默**）。
//  设计依据：design/04-AI对话与智能联想规范.md §4.1–§4.6。
//  硬约束：失败绝不 toast / 不占位 / 不改变候选栏高度；无完全访问、未配置、离线时整块不出现。
//

import Foundation

extension KeyboardViewModel {

    /// 触发联想的上下文最短长度（design/04 §4.4 ③）。
    static let suggestMinimumContextLength: Int = 6

    /// 联想解析失败后的冷却时长（design/04 §4.5：5s 内不再重试）。
    static let suggestFailureCooldown: TimeInterval = 5.0

    /// 组合态期间联想数据的保留时长（design/04 §4.6）。
    static let suggestCompositionGrace: TimeInterval = 10.0

    // MARK: - 触发入口

    /// 调度一次联想（上屏后 / 宿主文本变化后调用）。
    ///
    /// 该方法只负责「要不要发」，真正的 L1+L2 在 `requestSuggestions()` 里；
    /// 所有失败路径都静默返回，绝不产生可见副作用。
    /// 用户关闭「AI 联想词」时：直接清空并返回，不创建任何 Task。
    public func scheduleSuggestions() {
        guard snapshot.enableAISuggestion else {
            clearSuggestions()
            return
        }
        guard canScheduleSuggestions else { return }
        suggestDebounceTask?.cancel()
        let token = UUID()
        suggestDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(KMLayout.suggestDebounce * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            guard self.suggestDebounceTask != nil else { return }
            self.suggestDebounceTask = nil
            self.requestSuggestions(token: token)
        }
    }

    /// 用户删空输入框 / 切页 / 关闭键盘时清空联想（无退场动画）。
    public func clearSuggestions() {
        suggestDebounceTask?.cancel()
        suggestDebounceTask = nil
        suggestTask?.cancel()
        suggestTask = nil
        suggestIsLoading = false
        if !suggestionChips.isEmpty {
            suggestionChips = []
        }
    }

    /// 是否可以调度联想（design/04 §4.4 ①–⑤）。
    var canScheduleSuggestions: Bool {
        guard snapshot.enableAISuggestion else { return false }
        guard aiAvailability == .ready else { return false }
        guard page == .letters || page == .numbers else { return false }
        guard !isChatOpen else { return false }
        guard composing.isEmpty else { return false }
        guard !suggestIsLoading else { return false }
        guard Date() >= suggestCooldownUntil else { return false }
        let context = currentSuggestionContext
        guard context.count >= Self.suggestMinimumContextLength else { return false }
        return true
    }

    /// 联想使用的上下文（取宿主前文末句 + 最近上屏内容）。
    var currentSuggestionContext: String {
        let host = Self.suggestionContextTail(proxy?.documentContextBeforeInput ?? "")
        if !host.isEmpty {
            return String(host.suffix(Self.contextCharacterLimit))
        }
        return lastCommittedText
    }

    // MARK: - L1 + L2

    /// 执行一次联想：先 L1 秒出，再 L2 覆盖。
    /// - Parameter token: 本次调度令牌（用于丢弃过期响应）。
    func requestSuggestions(token: UUID) {
        let context = currentSuggestionContext
        guard context.count >= Self.suggestMinimumContextLength else {
            clearSuggestions()
            return
        }
        suggestRequestID = token
        let now = Date()
        guard now.timeIntervalSince(suggestLastRequestAt) >= KMLayout.suggestThrottle else {
            // 节流窗口内：只保留本地结果，不发 AI 请求。
            applyLocalSuggestions(context: context, token: token)
            return
        }
        suggestLastRequestAt = now
        applyLocalSuggestions(context: context, token: token)
        startAISuggestions(context: context, token: token)
    }

    /// 应用本地联想（L1）：0~2 条，立刻可点。
    /// - Parameters:
    ///   - context: 上下文。
    ///   - token: 调度令牌。
    func applyLocalSuggestions(context: String, token: UUID) {
        guard token == suggestRequestID else { return }
        let local = localSuggestions.suggestions(context: context, composing: "", limit: 2)
        let chips = Self.makeSuggestionChips(from: local.map { $0.text })
        if !chips.isEmpty {
            suggestionChips = chips
        }
    }

    /// 发起 AI 联想（L2）：超时 1.5s、失败静默、成功覆盖本地结果。
    ///
    /// 请求与解析统一走共享层（`design/04` §4.4 的 JSON 数组契约）：
    /// `PromptLibrary.suggestionRequest(context:text:)` 构造，`parseSuggestionCandidates` 三级容错解析，
    /// 失败返回空数组且**绝不抛错**。
    /// - Parameters:
    ///   - context: 上下文。
    ///   - token: 调度令牌。
    func startAISuggestions(context: String, token: UUID) {
        let snapshot = configStore.load()
        guard let provider = snapshot.defaultProvider, provider.supportsChat else { return }
        guard let apiKey = Self.apiKey(for: provider), !apiKey.isEmpty else { return }
        let request = PromptLibrary.suggestionRequest(context: context, text: "")
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        suggestIsLoading = true
        suggestTask?.cancel()
        suggestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.suggestIsLoading = false }
            do {
                let output = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        let result = try await client.complete(request)
                        return result.text
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(KMLayout.suggestTimeout * 1_000_000_000))
                        throw AIError.timeout
                    }
                    let first = try await group.next()
                    group.cancelAll()
                    guard let first else { throw AIError.timeout }
                    return first
                }
                if Task.isCancelled { return }
                guard token == self.suggestRequestID else { return }
                let chips = Self.makeSuggestionChips(
                    from: PromptLibrary.parseSuggestionCandidates(output)
                )
                guard !chips.isEmpty else {
                    // 解析不出有效结果：5s 冷却，期间不重试（但保留 L1 结果）。
                    self.suggestCooldownUntil = Date().addingTimeInterval(Self.suggestFailureCooldown)
                    return
                }
                self.suggestionChips = chips
            } catch {
                // 失败完全静默：不 toast、不占位、不改高度（design/04 §4.5）。
                self.suggestCooldownUntil = Date().addingTimeInterval(Self.suggestFailureCooldown)
            }
        }
    }

    /// 点击联想胶囊：直接上屏并清空。
    /// - Parameter index: 胶囊下标。
    public func insertSuggestion(at index: Int) {
        guard suggestionChips.indices.contains(index) else { return }
        let text = suggestionChips[index]
        KMHaptics.candidate()
        insertText(text)
        lastCommittedText = text
        clearSuggestions()
        recordSuggestionAcceptance(text)
    }

    /// 记录一次联想被采纳（供本地索引学习，提升后续命中率）。
    /// - Parameter text: 采纳的联想文案。
    func recordSuggestionAcceptance(_ text: String) {
        let context = currentSuggestionContext
        guard !context.isEmpty else { return }
        localSuggestions.record(context: context, committed: text)
    }

    // MARK: - 解析与清洗

    /// 把原始候选文案清洗为可展示的胶囊（去空 / 去重 / 截断 / 限量）。
    /// - Parameter raw: 原始文案。
    /// - Returns: 胶囊文案数组。
    static func makeSuggestionChips(from raw: [String]) -> [String] {
        var result: [String] = []
        for item in raw {
            let trimmed = trimSuggestion(item)
            guard !trimmed.isEmpty else { continue }
            guard !result.contains(trimmed) else { continue }
            result.append(trimmed)
            if result.count >= KMLayout.sugChipMaxCount { break }
        }
        return result
    }

    /// 清洗单条联想文案：去引号 / 去序号 / 去换行 / 截断到 12 字。
    /// - Parameter text: 原始文案。
    /// - Returns: 清洗后的文案。
    static func trimSuggestion(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "\n", with: " ")
        let quoteSet: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "「", "」", "『", "』"]
        value = String(value.filter { !quoteSet.contains($0) })
        value = stripOrderingPrefix(value).trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("、") || value.hasPrefix("。") || value.hasPrefix(",") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if value.count > KMLayout.sugChipMaxChars {
            value = String(value.prefix(KMLayout.sugChipMaxChars))
        }
        return value
    }

    /// 从宿主前文里取「最后一句」作为联想上下文（比整段更贴近「下一句」语义）。
    /// - Parameter context: 宿主前文。
    /// - Returns: 末句。
    static func suggestionContextTail(_ context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sentenceEndings: Set<Character> = ["。", "！", "？", "!", "?", "\n", ".", ";", "；"]
        var buffer: [Character] = []
        for character in trimmed.reversed() {
            if sentenceEndings.contains(character) {
                if buffer.isEmpty { continue }
                break
            }
            buffer.append(character)
            if buffer.count >= Self.contextCharacterLimit { break }
        }
        return String(buffer.reversed()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
