//
//  KeyboardViewModel+Chat.swift
//  墨语（Moyu）键盘扩展 · AI 对话状态机
//
//  模块职责：全场对话面板（design/04 §3）的状态与副作用——多轮 messages 累积、
//            流式逐字追加、思考/失败/取消/生图四类中间态、以及「上屏到宿主输入框」。
//  设计依据：design/04-AI对话与智能联想规范.md §3.12（状态机）、§3.4（自动滚底）、
//            §3.6（六种消息类型）、§3.7（操作行）、§3.9（键区路由）。
//  复用说明：AI 请求仍走 `AIClientFactory.makeLLM` + `AIError.wrap`，不新增网络层；
//            与结果页（`KeyboardViewModel+AI.swift`）的区别是「多轮累积」且不切页。
//            请求构造统一走共享层 `PromptLibrary.chatRequest(text:context:history:maxTokens:)`，
//            人设（`builtin.chat.assistant`）与温度由共享层维护，扩展侧不再自带 system prompt。
//

import Foundation
import UIKit

// MARK: - 对话开关

extension KeyboardViewModel {

    /// 对话最多保留多少条历史（超出丢弃最早，控制 token 与内存）。
    static let chatHistoryLimit: Int = 16

    /// 对话开场白（首次进入且无历史时插入本地消息，不发网络请求）。
    static let chatGreeting: String = "你好，我是墨语。可以直接打字和我聊，回答可以一键上屏。"

    /// 空态展示的三条示例提问（design/04 §3.10）。
    static let chatSamplePrompts: [String] = ["帮我想个回复", "把这段话润色一下", "翻译成英文"]

    /// 生图意图关键词（键盘内没有独立的生图入口，用自然语言触发）。
    static let chatImageKeywords: [String] = ["画一张", "画个", "画一只", "帮我画", "生成图片", "生图", "来张图"]

    /// 打开 AI 对话面板。
    ///
    /// 可用性不满足时**不进入面板**，只给出对应中文引导（design/04 §2.5）。
    public func openAIChat() {
        refreshAvailability()
        guard aiAvailability.canStartRequest else {
            handleChatUnavailable()
            return
        }
        KMHaptics.function()
        go(to: .aiChat)
    }

    /// 关闭对话面板（保留会话消息，下次进入继续）。
    public func closeAIChat() {
        guard page == .aiChat else { return }
        KMHaptics.function()
        go(to: .letters)
    }

    /// 清空当前对话（标题条「新对话」）。
    public func clearChat() {
        cancelChat()
        chatMessages = []
        chatStreamingText = ""
        chatErrorDetail = nil
        chatImageProgress = nil
        chatImageThumbnailData = nil
        chatImageOriginalData = nil
        chatPhase = .idle
        chatDraft = ""
        prepareChatSessionIfNeeded()
    }

    /// 首次进入对话时插入本地开场白（不发网络请求）。
    func prepareChatSessionIfNeeded() {
        guard chatMessages.isEmpty else { return }
        chatMessages = [
            KMChatMessage(role: .assistant, text: Self.chatGreeting)
        ]
    }

    /// 可用性不满足时的引导（不进入面板）。
    func handleChatUnavailable() {
        switch aiAvailability {
        case .noFullAccess:
            KMHaptics.warning()
            showsFullAccessCard = true
        case .notConfigured:
            showToast(Self.notConfiguredMessage)
            go(to: .settings)
        case .offline:
            showToast(Self.offlineMessage)
        case .busy:
            showToast("正在生成中，请稍候")
        case .ready, .unknown:
            showToast(Self.notConfiguredMessage)
        }
    }

    /// 离开对话时挂起在飞任务（保留消息与已生成文本）。
    func suspendChatTasks() {
        chatTask?.cancel()
        chatTask = nil
        chatImageProgressTask?.cancel()
        chatImageProgressTask = nil
        freezeStreamingMessages()
        if chatPhase.isBusy {
            chatPhase = .cancelled
        }
    }
}

// MARK: - 输入行（自绘输入，不用 TextField）

extension KeyboardViewModel {

    /// 向对话草稿追加文本（键区字符键在 `.aiChat` 页调用）。
    /// - Parameter text: 待追加文本。
    public func appendChatDraft(_ text: String) {
        guard !text.isEmpty else { return }
        guard chatDraft.count < Self.contextCharacterLimit else {
            showToast("输入内容已达上限")
            return
        }
        chatDraft += text
    }

    /// 删除对话草稿的最后一个字符（按 `Character` 而非 UTF-16 处理，避免拆坏 emoji）。
    public func deleteChatDraftCharacter() {
        guard !chatDraft.isEmpty else { return }
        chatDraft.removeLast()
    }

    /// 清空对话草稿。
    public func clearChatDraft() {
        chatDraft = ""
    }

    /// 用示例提问填充草稿并立即发送（空态一键发送）。
    /// - Parameter prompt: 示例文案。
    public func sendChatSample(_ prompt: String) {
        guard !prompt.isEmpty else { return }
        chatDraft = prompt
        sendChatMessage()
    }
}

// MARK: - 发送与流式

extension KeyboardViewModel {

    /// 发送当前草稿。
    ///
    /// 同一时刻只允许一个请求（design/04 §3.12）：若已有请求在飞，本次点击视为「停止」。
    public func sendChatMessage() {
        if chatPhase.isBusy {
            cancelChat()
            return
        }
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        refreshAvailability()
        guard aiAvailability.canStartRequest else {
            handleChatUnavailable()
            return
        }
        chatDraft = ""
        chatErrorDetail = nil
        KMHaptics.function()
        appendUserMessage(text)
        if Self.looksLikeImageRequest(text) {
            startChatImageGeneration(prompt: text)
        } else {
            startChatTextStream()
        }
    }

    /// 重试最后一次失败请求（重发最后一条用户消息）。
    public func retryChat() {
        guard !chatPhase.isBusy else { return }
        guard let lastUser = chatMessages.last(where: { $0.role == .user }) else { return }
        removeTrailingAssistantMessages()
        chatErrorDetail = nil
        KMHaptics.function()
        if Self.looksLikeImageRequest(lastUser.text) {
            startChatImageGeneration(prompt: lastUser.text)
        } else {
            startChatTextStream()
        }
    }

    /// 取消在飞请求（保留已生成文本与操作行）。
    public func cancelChat() {
        chatTask?.cancel()
        chatTask = nil
        chatImageProgressTask?.cancel()
        chatImageProgressTask = nil
        freezeStreamingMessages()
        if chatPhase.isBusy {
            chatPhase = .cancelled
        }
    }

    /// 把最后一条流式消息标记为结束（用于取消/离开页面）。
    func freezeStreamingMessages() {
        guard !chatMessages.isEmpty else { return }
        for index in chatMessages.indices where chatMessages[index].isStreaming {
            chatMessages[index].isStreaming = false
        }
    }

    /// 追加一条用户消息。
    /// - Parameter text: 用户输入。
    func appendUserMessage(_ text: String) {
        chatMessages.append(KMChatMessage(role: .user, text: text))
        trimHistoryIfNeeded()
    }

    /// 追加一条空的 AI 占位消息（流式与思考态都基于它）。
    @discardableResult
    func appendAssistantPlaceholder() -> String {
        let message = KMChatMessage(role: .assistant, text: "", isStreaming: true)
        chatMessages.append(message)
        return message.id
    }

    /// 移除末尾连续的 AI 消息（重试前清理失败的占位）。
    func removeTrailingAssistantMessages() {
        while let last = chatMessages.last, last.role == .assistant, last.text.isEmpty || last.errorDetail != nil {
            chatMessages.removeLast()
        }
    }

    /// 历史过长时丢弃最早的对话（保留开场白以免面板看起来是空的）。
    func trimHistoryIfNeeded() {
        guard chatMessages.count > Self.chatHistoryLimit else { return }
        let overflow = chatMessages.count - Self.chatHistoryLimit
        chatMessages.removeFirst(overflow)
    }

    /// 组装多轮历史（交给共享层 `PromptLibrary.chatRequest` 拼 system 与本轮用户输入）。
    ///
    /// 只保留纯文本问答轮次：跳过本地开场白（避免模型把它当自己的输出模仿）、
    /// 生图消息与错误占位气泡。**本轮用户消息**由 `chatRequest(text:)` 单独传入，
    /// 故这里把它从末尾剔除，避免出现两条一样的 user 消息。
    /// - Parameter userText: 本轮用户输入。
    /// - Returns: 本轮之前的历史（时间正序，不含 system）。
    func makeChatHistory(excluding userText: String) -> [ChatMessage] {
        var history: [ChatMessage] = []
        for message in chatMessages {
            guard !message.isImageMessage, message.errorDetail == nil else { continue }
            guard !message.text.isEmpty else { continue }
            switch message.role {
            case .user:
                history.append(.user(message.text))
            case .assistant:
                // 开场白属于本地话术，不进入模型上下文。
                guard message.text != Self.chatGreeting else { continue }
                history.append(.assistant(message.text))
            }
        }
        // chatMessages 末尾是刚写入的本轮用户输入，历史里去掉它（chatRequest 会单独追加）。
        if let last = history.last, last.role == .user, last.content == userText {
            history.removeLast()
        }
        return history
    }

    /// 发起文本对话流式请求。
    func startChatTextStream() {
        let snapshot = configStore.load()
        self.snapshot = snapshot
        guard let provider = snapshot.defaultProvider, provider.supportsChat else {
            failChat(with: .notConfigured)
            return
        }
        guard let apiKey = Self.apiKey(for: provider), !apiKey.isEmpty else {
            failChat(with: .missingAPIKey)
            return
        }
        lastProviderName = provider.name
        let userText = chatMessages.last(where: { $0.role == .user })?.text ?? ""
        // 请求构造统一走共享层：system 人设来自 `builtin.chat.assistant`，
        // 温度取模板 0.7，maxTokens 默认 512（`PromptLibrary.chatMaxTokens`）。
        let request = PromptLibrary.chatRequest(
            text: userText,
            context: proxy?.documentContextBeforeInput ?? "",
            history: makeChatHistory(excluding: userText),
            maxTokens: PromptLibrary.chatMaxTokens
        )
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        let placeholderID = appendAssistantPlaceholder()
        chatPhase = .thinking
        chatStreamingText = ""
        chatIsBusy = true
        chatTask = Task { [weak self] in
            guard let self else { return }
            var receivedAny = false
            do {
                for try await delta in client.stream(request) {
                    if Task.isCancelled { return }
                    if !delta.text.isEmpty {
                        if !receivedAny {
                            receivedAny = true
                            self.chatPhase = .streaming
                        }
                        self.appendChatDelta(delta.text, messageID: placeholderID)
                    }
                    if delta.isFinal { break }
                }
                if Task.isCancelled { return }
                self.finishChatStream(messageID: placeholderID, receivedAny: receivedAny)
            } catch {
                if Task.isCancelled { return }
                let wrapped = AIError.wrap(error)
                if wrapped == .cancelled {
                    self.freezeStreamingMessages()
                    self.chatPhase = .cancelled
                    self.chatIsBusy = false
                    return
                }
                self.failChat(with: wrapped, messageID: placeholderID)
            }
        }
    }

    /// 追加流式文本到指定消息。
    /// - Parameters:
    ///   - delta: 增量文本。
    ///   - messageID: 目标消息 ID。
    func appendChatDelta(_ delta: String, messageID: String) {
        chatStreamingText += delta
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { return }
        chatMessages[index].text += delta
        chatMessages[index].isStreaming = true
    }

    /// 流式正常结束。
    /// - Parameters:
    ///   - messageID: 消息 ID。
    ///   - receivedAny: 是否收到过内容。
    func finishChatStream(messageID: String, receivedAny: Bool) {
        chatTask = nil
        chatIsBusy = false
        if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].isStreaming = false
            if !receivedAny {
                chatMessages[index].text = "模型没有返回内容，可以换个说法再试。"
                chatMessages[index].errorDetail = KMAIErrorDetail(
                    title: "模型没有返回内容",
                    recovery: "可以换个说法再试，或检查服务商是否支持该模型。",
                    isRetryable: true,
                    suggestsSettings: false,
                    isOffline: false
                )
                chatPhase = .failed
                KMHaptics.warning()
                return
            }
        }
        chatPhase = .idle
        chatStreamingText = ""
        recordNetworkOKHeartbeat()
        KMHaptics.success()
    }

    /// 对话请求失败。
    /// - Parameters:
    ///   - error: 错误。
    ///   - messageID: 占位消息 ID（nil 时追加一条错误消息）。
    func failChat(with error: AIError, messageID: String? = nil) {
        chatIsBusy = false
        chatTask = nil
        let detail = Self.errorDetail(from: error)
        chatErrorDetail = detail
        chatPhase = .failed
        let targetID: String
        if let messageID {
            targetID = messageID
        } else {
            targetID = appendAssistantPlaceholder()
        }
        if let index = chatMessages.firstIndex(where: { $0.id == targetID }) {
            chatMessages[index].isStreaming = false
            chatMessages[index].errorDetail = detail
            if chatMessages[index].text.isEmpty {
                chatMessages[index].text = detail.title
            }
        }
        if detail.isOffline {
            aiAvailability = .offline
        }
        KMHaptics.warning()
    }

    /// 对话温度由共享层模板决定（`builtin.chat.assistant` → 0.7），
    /// 扩展侧不再自行调节，避免与服务商设置叠加出不可预期的高温输出。
}

// MARK: - 对话内生图

extension KeyboardViewModel {

    /// 判断是否属于生图意图（键盘内无独立入口，用自然语言触发）。
    /// - Parameter text: 用户输入。
    /// - Returns: 是否走生图管线。
    static func looksLikeImageRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return chatImageKeywords.contains { trimmed.hasPrefix($0) }
    }

    /// 发起对话内生的生图请求。
    /// - Parameter prompt: 用户描述（中文）。
    func startChatImageGeneration(prompt: String) {
        let snapshot = configStore.load()
        self.snapshot = snapshot
        guard let provider = snapshot.imageProvider ?? snapshot.providers.first(where: { $0.supportsImage }) else {
            failChat(with: .notConfigured)
            return
        }
        guard let apiKey = Self.apiKey(for: provider), !apiKey.isEmpty else {
            failChat(with: .missingAPIKey)
            return
        }
        let placeholderID = appendAssistantPlaceholder()
        chatPhase = .imageGenerating
        chatIsBusy = true
        chatImageProgress = KMImageProgress(prompt: prompt, elapsed: 0, expected: 5...20, stage: .queued)
        startChatImageProgressTimer(prompt: prompt)
        chatTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalPrompt = await Self.enhancePrompt(prompt, provider: provider, apiKey: apiKey) ?? prompt
                let client = AIClientFactory.makeImage(config: provider, apiKey: apiKey)
                let request = ImageRequest(prompt: finalPrompt, size: snapshot.imageSize, quality: "standard", count: 1)
                let images = try await client.generate(request)
                if Task.isCancelled { return }
                guard let first = images.first, !first.isEmpty else {
                    self.failChat(with: .unknown("生成的图片为空"), messageID: placeholderID)
                    return
                }
                self.finishChatImage(data: first.data, messageID: placeholderID)
            } catch {
                if Task.isCancelled { return }
                let wrapped = AIError.wrap(error)
                if wrapped == .cancelled {
                    self.freezeStreamingMessages()
                    self.chatPhase = .cancelled
                    self.chatIsBusy = false
                    return
                }
                self.failChat(with: wrapped, messageID: placeholderID)
            }
        }
    }

    /// 逐秒刷新生图已等待时间与阶段文案。
    /// - Parameter prompt: 提示词。
    func startChatImageProgressTimer(prompt: String) {
        chatImageProgressTask?.cancel()
        chatImageProgressTask = Task { [weak self] in
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                elapsed += 1
                guard let self else { return }
                var progress = self.chatImageProgress ?? KMImageProgress(prompt: prompt)
                progress.elapsed = elapsed
                progress.stage = Self.imageStage(for: elapsed)
                self.chatImageProgress = progress
            }
        }
    }

    /// 根据已等待秒数推导阶段。
    /// - Parameter elapsed: 已等待秒数。
    /// - Returns: 阶段。
    static func imageStage(for elapsed: TimeInterval) -> KMImageProgress.Stage {
        if elapsed < 1 { return .queued }
        if elapsed < 3 { return .enhancing }
        if elapsed < 12 { return .drawing }
        return .downloading
    }

    /// 生图成功。
    /// - Parameters:
    ///   - data: 原图数据。
    ///   - messageID: 占位消息 ID。
    func finishChatImage(data: Data, messageID: String) {
        chatTask = nil
        chatImageProgressTask?.cancel()
        chatImageProgressTask = nil
        chatImageProgress = nil
        chatIsBusy = false
        chatImageOriginalData = data
        // 内存控制：键盘内只保留 ≤512pt 缩略图，原图仅在本次会话内暂存、离开页面即释放。
        let thumbnail = KMImageThumbnail.make(from: data) ?? data
        chatImageThumbnailData = thumbnail
        if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].isStreaming = false
            chatMessages[index].imageData = thumbnail
            chatMessages[index].text = ""
        }
        chatPhase = .idle
        recordNetworkOKHeartbeat()
        KMHaptics.success()
    }

    /// 复制对话里的图片到系统剪贴板。
    /// - Parameter message: 图片消息。
    public func copyChatImage(_ message: KMChatMessage) {
        guard let data = message.imageData, let image = KMImageThumbnail.image(from: data) else {
            showToast("图片已释放，请重新生成")
            return
        }
        UIPasteboard.general.image = image
        KMHaptics.success()
        showToast(Self.imagePasteHint)
    }
}

// MARK: - 操作行（上屏 / 复制）

extension KeyboardViewModel {

    /// 把一条 AI 回复上屏到宿主输入框（**不关闭对话面板**，方便继续聊）。
    ///
    /// 说明：design/04 §3.7 写的是 `insertAIResult(_:)`，但那个方法会切页回 `.letters`；
    /// 对话场景下用户通常希望「上屏后继续追问」，因此这里复用同一套写入逻辑但保留当前页。
    /// - Parameter text: 待上屏文本。
    public func insertChatResult(_ text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        if let selected = proxy?.selectedText, !selected.isEmpty {
            proxy?.deleteBackward()
        }
        proxy?.insertText(content)
        onInsert?(content)
        lastCommittedText = content
        KMHaptics.success()
        showToast("已上屏")
        // 上屏后按 design/04 §4.6 重新请求联想（清空旧结果再防抖）。
        scheduleSuggestions()
    }

    /// 复制一条 AI 回复。
    /// - Parameter text: 待复制文本。
    public func copyChatResult(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        KMHaptics.chip()
        showToast("已复制")
    }

    /// 取最新一条可上屏的 AI 消息（文案按钮是否可用的依据）。
    public var latestChatResultText: String? {
        guard let last = chatMessages.last(where: { $0.role == .assistant && !$0.isStreaming && $0.errorDetail == nil }),
              !last.text.isEmpty, !last.isImageMessage else {
            return nil
        }
        return last.text
    }
}
