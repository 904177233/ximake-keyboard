//
//  KeyboardViewModel+AI.swift
//  墨语（Moyu）键盘扩展 · AI 能力（流式文本 / 生图）
//
//  模块职责：把「点一次 AI 能力」翻译成一次网络请求，并把增量结果写回状态机。
//            - 文本能力：`AIClientFactory.makeLLM` → `client.stream(req)` 逐字追加；
//            - 生图能力：先做一次提示词英译增强（失败则退回原文），再 `makeImage` → `generate`；
//            - 全程可取消：`currentAITask` / `imageProgressTask` 持有任务引用。
//  设计依据：docs/02 §4.7 / §6（数据流）、docs/01 §4.2（能力输出约束）、
//            design/键盘布局规范.md §5（状态 ③④⑤⑥⑦⑧）、§9（交互流 S1/S2/S4）。
//  内存约束：生图只保留 ≤512pt 缩略图（`imageThumbnailData`）；原图暂存于
//            `lastImageOriginalData`，离开结果页立即释放（见 `releaseImageBuffers()`）。
//

import Foundation
import UIKit

extension KeyboardViewModel {

    // MARK: - 入口

    /// 发起一次 AI 能力（工具条 chip / 面板「生成」按钮的统一下游）。
    ///
    /// 内部会重新加载配置快照并校验可用性，因此视图层不需要自己判断权限。
    /// - Parameter feature: AI 能力。
    public func startAI(_ feature: AIFeature) {
        let latest = configStore.load()
        snapshot = latest
        refreshAvailability()

        switch aiAvailability {
        case .noFullAccess:
            showsFullAccessCard = true
            return
        case .notConfigured:
            showsFullAccessCard = false
            go(to: .settings)
            return
        case .offline:
            showsFullAccessCard = false
            showToast(Self.offlineMessage)
            return
        case .busy:
            showToast("正在生成中，请稍候")
            return
        case .unknown, .ready:
            break
        }

        let rawText = currentRequestText()
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("请先输入要处理的内容")
            return
        }

        lastFeature = feature
        lastRequestText = rawText
        lastRequestContext = contextTail

        if feature.usesImageClient {
            startImageGeneration(prompt: rawText)
        } else {
            startTextGeneration(feature: feature, text: rawText, context: contextTail)
        }
    }

    /// 重试上一次失败的能力（沿用上一次的输入与上下文）。
    public func retryAI() {
        guard let detail = lastAIErrorDetail, detail.isRetryable else {
            startAI(lastFeature)
            return
        }
        let text = lastRequestText.isEmpty ? currentRequestText() : lastRequestText
        guard !text.isEmpty else {
            showToast("内容已清空，请重新输入")
            return
        }
        if lastFeature.usesImageClient {
            startImageGeneration(prompt: text)
        } else {
            startTextGeneration(feature: lastFeature, text: text, context: lastRequestContext)
        }
    }

    /// 取消当前 AI 请求。
    /// - Parameter silently: 为 true 时不改变结果状态（用于页面切换 / 键盘收起）。
    public func cancelAI(silently: Bool) {
        currentAITask?.cancel()
        currentAITask = nil
        imageProgressTask?.cancel()
        imageProgressTask = nil
        if !silently {
            streamingText = ""
            aiState = .idle
            lastAIErrorDetail = nil
            refreshAvailability()
        }
    }

    // MARK: - 文本流式

    /// 文本能力流式请求。
    /// - Parameters:
    ///   - feature: AI 能力。
    ///   - text: 待处理文本。
    ///   - context: 上下文（回复建议使用）。
    func startTextGeneration(feature: AIFeature, text: String, context: String) {
        guard let provider = snapshot.defaultProvider else {
            fail(with: .notConfigured)
            return
        }
        guard let apiKey = Self.apiKey(for: provider), !apiKey.isEmpty else {
            fail(with: .missingAPIKey)
            return
        }

        let template = PromptLibrary.defaultTemplate(for: feature) ?? BuiltInPrompts.custom
        let request = PromptLibrary.makeRequest(
            template,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: snapshot.providers.isEmpty ? "英文" : Self.targetLanguage(for: snapshot),
            replyCount: max(snapshot.replyCount, 1)
        )

        lastProviderName = provider.name
        lastAIErrorDetail = nil
        replySuggestions = []
        streamingText = ""
        aiState = .streaming("")
        showsFullAccessCard = false
        showsContextTruncationHint = context.count >= Self.contextCharacterLimit
        go(to: .result)
        aiState = .streaming("")

        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        let startedAt = Date()

        currentAITask?.cancel()
        currentAITask = Task { [weak self] in
            do {
                for try await delta in client.stream(request) {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if !delta.text.isEmpty {
                        self.appendStreaming(delta.text)
                    }
                    if delta.isFinal { break }
                }
                guard let self, !Task.isCancelled else { return }
                self.finishTextGeneration(feature: feature, startedAt: startedAt)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let mapped = AIError.wrap(error)
                if mapped == .cancelled { return }
                self.fail(with: mapped)
            }
        }
    }

    /// 追加流式文本（同时同步 `aiState`，让结果卡片只有一个数据源）。
    /// - Parameter delta: 增量文本。
    func appendStreaming(_ delta: String) {
        streamingText += delta
        aiState = .streaming(streamingText)
    }

    /// 流式正常结束：落定结果、拆分回复建议、记录耗时。
    /// - Parameters:
    ///   - feature: 本次能力。
    ///   - startedAt: 请求开始时间。
    func finishTextGeneration(feature: AIFeature, startedAt: Date) {
        currentAITask = nil
        let result = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastAIDuration = max(Date().timeIntervalSince(startedAt), 0)
        guard !result.isEmpty else {
            fail(with: .unknown("模型没有返回内容"))
            return
        }
        aiState = .done(result)
        replySuggestions = feature == .replySuggestion ? Self.splitReplySuggestions(result) : []
        KMHaptics.success()
        recordNetworkOKHeartbeat()
        refreshAvailability()
    }

    // MARK: - 生图

    /// 生图请求（含提示词英译增强 + 进度刷新）。
    /// - Parameter prompt: 用户输入的提示词（中文即可）。
    func startImageGeneration(prompt: String) {
        guard let provider = snapshot.imageProvider ?? snapshot.providers.first(where: { $0.supportsImage }) else {
            fail(with: .notConfigured)
            return
        }
        guard let apiKey = Self.apiKey(for: provider), !apiKey.isEmpty else {
            fail(with: .missingAPIKey)
            return
        }

        lastProviderName = provider.name
        lastAIErrorDetail = nil
        replySuggestions = []
        imageThumbnailData = nil
        lastImageOriginalData = nil
        streamingText = ""
        aiState = .imageGenerating(KMImageProgress(prompt: prompt, elapsed: 0, stage: .queued))
        go(to: .result)
        aiState = .imageGenerating(KMImageProgress(prompt: prompt, elapsed: 0, stage: .queued))

        let chatProvider = snapshot.defaultProvider
        let chatKey = chatProvider.flatMap { Self.apiKey(for: $0) }
        let imageClient = AIClientFactory.makeImage(config: provider, apiKey: apiKey)
        let size = snapshot.imageSize

        startImageProgressTimer()

        currentAITask?.cancel()
        currentAITask = Task { [weak self] in
            do {
                var finalPrompt = prompt
                if let chatProvider, let chatKey, !chatKey.isEmpty {
                    let enhanced = await Self.enhancePrompt(prompt, provider: chatProvider, apiKey: chatKey)
                    if let enhanced, !enhanced.isEmpty { finalPrompt = enhanced }
                }
                if Task.isCancelled { return }

                let request = ImageRequest(prompt: finalPrompt, size: size, quality: "standard", count: 1)
                let images = try await imageClient.generate(request)
                guard let first = images.first, !first.isEmpty else {
                    throw AIError.unknown("生成的图片为空")
                }
                guard let self, !Task.isCancelled else { return }
                self.finishImageGeneration(data: first.data, startedAt: Date())
            } catch {
                guard let self, !Task.isCancelled else { return }
                let mapped = AIError.wrap(error)
                if mapped == .cancelled { return }
                self.fail(with: mapped)
            }
        }
    }

    /// 生图完成：只保留缩略图给界面，原图仅暂存供复制。
    /// - Parameters:
    ///   - data: 原图数据。
    ///   - startedAt: 请求开始时间。
    func finishImageGeneration(data: Data, startedAt: Date) {
        currentAITask = nil
        imageProgressTask?.cancel()
        imageProgressTask = nil
        lastImageOriginalData = data
        lastAIDuration = max(Date().timeIntervalSince(startedAt), 0)

        if let thumbnail = KMImageThumbnail.make(from: data) {
            imageThumbnailData = thumbnail
            aiState = .image(thumbnail)
        } else {
            imageThumbnailData = nil
            fail(with: .decoding("图片数据无法解码"))
            return
        }
        KMHaptics.success()
        recordNetworkOKHeartbeat()
        refreshAvailability()
    }

    /// 启动生图进度定时器（每秒刷新已等待秒数与阶段）。
    func startImageProgressTimer() {
        imageProgressTask?.cancel()
        imageProgressTask = Task { [weak self] in
            var elapsed: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                elapsed += 1
                self.tickImageProgress(elapsed: elapsed)
            }
        }
    }

    /// 刷新生图进度（阶段按已等待秒数推进，纯展示用途）。
    /// - Parameter elapsed: 已等待秒数。
    func tickImageProgress(elapsed: TimeInterval) {
        guard case let .imageGenerating(progress) = aiState else { return }
        let stage: KMImageProgress.Stage
        switch elapsed {
        case ..<1:
            stage = .queued
        case ..<3:
            stage = .enhancing
        default:
            stage = .drawing
        }
        aiState = .imageGenerating(
            KMImageProgress(prompt: progress.prompt, elapsed: elapsed, expected: progress.expected, stage: stage)
        )
    }

    // MARK: - 结果使用

    /// 插入 AI 文本结果（替换当前选区后回到键盘，并收起结果页）。
    /// - Parameter text: 待插入文本。
    public func insertAIResult(_ text: String) {
        let content = text.isEmpty ? streamingText : text
        guard !content.isEmpty else { return }
        replaceSelectionIfNeeded()
        insertText(content)
        isEditingAIResult = false
        aiState = .idle
        streamingText = ""
        releaseImageBuffers()
        go(to: previousNonAIPage)
        showToast("已插入")
        KMHaptics.success()
    }

    /// 复制 AI 文本结果到系统剪贴板。
    /// - Parameter text: 待复制文本。
    public func copyAIResult(_ text: String) {
        let content = text.isEmpty ? streamingText : text
        guard !content.isEmpty else { return }
        UIPasteboard.general.string = content
        showToast("已复制")
        KMHaptics.candidate()
    }

    /// 复制生图结果到系统剪贴板。
    ///
    /// 扩展无法把图片直接插进宿主输入框，只能复制后由用户在聊天框长按粘贴。
    public func copyImageToPasteboard() {
        let data = lastImageOriginalData ?? imageThumbnailData
        guard let data, let image = UIImage(data: data) else {
            showToast("图片已释放，请重新生成")
            return
        }
        UIPasteboard.general.image = image
        showToast(Self.imagePasteHint)
        KMHaptics.success()
    }

    /// 把当前 AI 结果交给面板做「编辑后插入」。
    public func editAIResult() {
        let content = aiState.streamingText.isEmpty ? aiState.doneText : aiState.streamingText
        panelText = content
        panelCursor = content.count
        isPanelEditing = true
        isEditingAIResult = true
        go(to: .aiPanel)
        _ = panelText
    }

    /// 关闭结果页并释放大对象。
    public func dismissAIResult() {
        cancelAI(silently: true)
        releaseImageBuffers()
        aiState = .idle
        streamingText = ""
        replySuggestions = []
        lastAIErrorDetail = nil
        isEditingAIResult = false
        go(to: previousNonAIPage)
    }

    /// 插入一条回复建议（点某条直接上屏并收起）。
    /// - Parameter index: 建议下标。
    public func insertReplySuggestion(at index: Int) {
        guard replySuggestions.indices.contains(index) else { return }
        let text = replySuggestions[index]
        replaceSelectionIfNeeded()
        insertText(text)
        replySuggestions = []
        aiState = .idle
        streamingText = ""
        go(to: previousNonAIPage)
        KMHaptics.success()
    }

    // MARK: - 失败

    /// 统一失败处理：写结果状态、错误详情、可用性与触感。
    /// - Parameter error: 已归一化的错误。
    func fail(with error: AIError) {
        currentAITask = nil
        imageProgressTask?.cancel()
        imageProgressTask = nil
        let detail = Self.errorDetail(from: error)
        lastAIErrorDetail = detail
        aiState = .failed(detail.title)
        if detail.isOffline {
            aiAvailability = .offline
        }
        if error == .missingAPIKey || error == .unauthorized || error == .notConfigured {
            aiAvailability = .notConfigured
        }
        KMHaptics.warning()
    }

    // MARK: - 私有工具

    /// 当前应该送给模型的文本：优先面板内容，其次宿主上下文尾部。
    /// - Returns: 待处理文本。
    private func currentRequestText() -> String {
        let panel = panelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !panel.isEmpty { return panel }
        let context = contextTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return context
    }

    /// 宿主存在选区时先删除选区，避免插入后残留原文（契约 docs/02 §6）。
    private func replaceSelectionIfNeeded() {
        guard let proxy else { return }
        if let selected = proxy.selectedText, !selected.isEmpty {
            proxy.deleteBackward()
        }
    }

    /// 释放生图相关的大内存（键盘扩展内存上限约 40–60MB）。
    func releaseImageBuffers() {
        lastImageOriginalData = nil
        imageThumbnailData = nil
    }

    /// 读取 Provider 对应的 API Key（无 Keychain 时返回 nil）。
    /// - Parameter provider: 服务商配置。
    /// - Returns: API Key。
    static func apiKey(for provider: AIProviderConfig) -> String? {
        KeychainStore.shared.apiKey(for: provider.id)
    }

    /// 目标语言（配置里没有单独字段时默认英文，与契约一致）。
    /// - Parameter snapshot: 配置快照。
    /// - Returns: 目标语言。
    static func targetLanguage(for snapshot: ConfigSnapshot) -> String {
        _ = snapshot
        return "英文"
    }

    /// 把 `AIError` 映射为视图可直接展示的中文错误数据。
    /// - Parameter error: 错误。
    /// - Returns: 展示数据。
    static func errorDetail(from error: AIError) -> KMAIErrorDetail {
        let title = error.errorDescription ?? "发生了未知错误"
        let recovery = error.recoverySuggestion ?? "请稍后重试。"
        let offline: Bool
        if case .network = error { offline = true } else { offline = false }
        let suggestsSettings: Bool
        switch error {
        case .notConfigured, .missingAPIKey, .unauthorized:
            suggestsSettings = true
        default:
            suggestsSettings = false
        }
        return KMAIErrorDetail(
            title: title,
            recovery: recovery,
            isRetryable: error.isRetryable,
            suggestsSettings: suggestsSettings,
            isOffline: offline
        )
    }

    /// 拆分回复建议：按换行 → 序号前缀 → 分号 依次切分，最多 3 条、每条 ≤30 字。
    /// - Parameter text: 模型原始输出。
    /// - Returns: 建议列表。
    static func splitReplySuggestions(_ text: String) -> [String] {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count < 3 {
            let extra = lines.flatMap { line -> [String] in
                line.components(separatedBy: "；").flatMap { $0.components(separatedBy: ";") }
            }
            lines = extra.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        let cleaned = lines.map(stripOrderingPrefix)
        var result: [String] = []
        for item in cleaned where !item.isEmpty {
            if result.contains(item) { continue }
            result.append(String(item.prefix(30)))
            if result.count == 3 { break }
        }
        return result
    }

    /// 去掉「1.」「2、」「3)」这类序号前缀。
    /// - Parameter line: 原始行。
    /// - Returns: 去前缀后的文本。
    static func stripOrderingPrefix(_ line: String) -> String {
        let pattern = "^\\s*[0-9一二三四五六七八九十]+\\s*[.、)）:：]\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用 LLM 把中文提示词增强成英文生图提示词（失败时静默退回原文）。
    /// - Parameters:
    ///   - prompt: 中文提示词。
    ///   - provider: 文本服务商。
    ///   - apiKey: API Key。
    /// - Returns: 英文提示词；失败为 nil。
    static func enhancePrompt(_ prompt: String, provider: AIProviderConfig, apiKey: String) async -> String? {
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        let request = PromptLibrary.imagePromptEnhanceRequest(prompt)
        do {
            let result = try await client.complete(request)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

extension AIResultState {

    /// 已完成文本（仅 `.done` 有值，其余空串）。
    var doneText: String {
        if case let .done(text) = self { return text }
        return ""
    }
}
