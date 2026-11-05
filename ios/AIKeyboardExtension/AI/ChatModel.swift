//
//  ChatModel.swift
//  墨语键盘 · AI 对话
//
//  整个键盘变成一个对话框。打的字进对话框，不进聊天框；回答可以一键放进聊天框。
//  推理、回答长短、人设、带几轮上下文都在 AIPrefs 里，App 的「AI 对话」页能改。
//  说「画……」或打开「画图」开关，这一句就去画图。
//

import Combine
import Foundation
import UIKit

/// 一条对话消息。
struct ChatBubble: Identifiable, Equatable {
    enum Role: Equatable {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    /// 模型的思考过程（有的模型会给）。
    var reasoning = ""
    var isStreaming = false
    var isError = false
    /// 画出来的图（小图）和它在画图历史里的编号。
    var image: UIImage?
    var imageID: String?
}

@MainActor
final class ChatModel: ObservableObject {

    /// 进行到哪一步。
    enum Phase: Equatable {
        case idle
        case thinking(String)
        case streaming
    }

    @Published private(set) var messages: [ChatBubble] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var prefs = AIPrefs.load()
    /// 下一句画成图。
    @Published private(set) var drawNext = false

    private static let historyLimit = 40
    private static let unsupportedKey = "moyu.reasoning.unsupported"

    private unowned let session: KeyboardSession
    private var task: Task<Void, Never>?
    /// 这一句已经换过模型了，再失败就直接报错。
    private var triedOtherModel = false

    init(session: KeyboardSession) {
        self.session = session
    }

    /// 进入对话前的检查结果，给界面显示。
    var blocker: AIBlocker? { session.aiBlocker }

    /// 准备进入。消息保留，下次回来接着聊；键盘重开后从记录里接上最近几句。
    func prepare() {
        prefs = AIPrefs.load()
        if messages.isEmpty, prefs.keepHistory {
            messages = ChatHistoryStore.load().suffix(10).map {
                ChatBubble(role: $0.isUser ? .user : .assistant, text: $0.text)
            }
        }
    }

    /// 清空对话（App 里的记录还在）。
    func clear() {
        cancel()
        messages = []
        session.setChatTyping(true)
    }

    // MARK: - 顶栏的选项

    /// 打字时候选栏位置显示的几个开关。
    var optionTitles: [String] {
        ["推理：\(prefs.reasoning.title)",
         "回答：\(prefs.length.title)",
         drawNext ? "下一句画图：开" : "下一句画图：关",
         "人设：\(personaTitle)"]
    }

    private var personaTitle: String {
        let current = prefs.persona.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIPrefs.personaPresets.first { $0.text == current }?.title ?? "自定义"
    }

    /// 点了第几个开关：换到下一个值。
    func cycleOption(at index: Int) {
        switch index {
        case 0:
            prefs.reasoning = Self.next(after: prefs.reasoning)
            session.showToast(prefs.reasoning == .deep ? "深度思考：慢一些，适合难题" : "推理：\(prefs.reasoning.title)")
        case 1:
            prefs.length = Self.next(after: prefs.length)
        case 2:
            drawNext.toggle()
            session.showToast(drawNext ? "下一句会画成图" : "下一句正常回答")
            session.render()
            return
        case 3:
            let presets = AIPrefs.personaPresets
            let current = presets.firstIndex { $0.text == prefs.persona } ?? -1
            prefs.persona = presets[(current + 1) % presets.count].text
            session.showToast("人设：\(personaTitle)。在墨语 App 里可以自己写")
        default:
            return
        }
        prefs.save()
        session.render()
    }

    private static func next<T: CaseIterable & Equatable>(after value: T) -> T {
        let all = Array(T.allCases)
        let index = all.firstIndex(of: value) ?? 0
        return all[(index + 1) % all.count]
    }

    // MARK: - 发送

    /// 发送草稿。在回答时再按一次就是停止。
    func send() {
        if phase != .idle {
            cancel()
            return
        }
        let text = session.takeDraft().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 发出去就切到看回答，回答要有地方显示
        session.setChatTyping(false)
        triedOtherModel = false
        guard session.host?.hostHasFullAccess == true else {
            messages.append(ChatBubble(role: .assistant,
                                       text: "还没打开完全访问，键盘连不上网。到 设置 › 通用 › 键盘 › 键盘 › 墨语，打开「允许完全访问」。",
                                       isError: true))
            return
        }
        messages.append(ChatBubble(role: .user, text: text))
        trim()
        record(isUser: true, text: text)
        if drawNext || Self.looksLikeDrawing(text) {
            drawNext = false
            session.render()
            draw(prompt: Self.drawingPrompt(from: text))
            return
        }
        if session.aiBlocker != nil {
            messages.append(ChatBubble(role: .assistant, text: Self.notConfiguredText, isError: true))
            return
        }
        start(userText: text)
    }

    /// 「画一只猫」「帮我画……」这种直接去画图。
    static func looksLikeDrawing(_ text: String) -> Bool {
        let prefixes = ["画一", "画个", "画张", "帮我画", "给我画", "生成一张", "生成图片"]
        return prefixes.contains { text.hasPrefix($0) } && text.count >= 3
    }

    static func drawingPrompt(from text: String) -> String {
        var prompt = text
        for prefix in ["帮我画", "给我画", "生成一张", "生成图片", "画一张", "画一个", "画一只", "画个", "画张"] where prompt.hasPrefix(prefix) {
            prompt = String(prompt.dropFirst(prefix.count))
            break
        }
        prompt = prompt.trimmingCharacters(in: CharacterSet(charactersIn: "：:，, "))
        return prompt.isEmpty ? text : prompt
    }

    /// 没 Key 时怎么说。App 和键盘没打通的话，在 App 里填的 Key 键盘看不到。
    private static var notConfiguredText: String {
        SharedBlob.shared.isShared
            ? "还没配好写字用的 AI 服务。关掉对话，点工具栏的齿轮 › AI 服务，选一家，填上 Key。"
            : "键盘里还没有 Key。这台手机上 App 和键盘没打通，在 App 里填的 Key 这里看不到。关掉对话，点工具栏的齿轮 › AI 服务，直接在这里填，或者点「导入 App 里的配置」。"
    }

    #if MOYU_SIM_CHECK
    func fillForSimCheck() {
        var answer = ChatBubble(role: .assistant, text: "老板您好，我明天身体不舒服，想请一天假，工作已经交接好了，谢谢。")
        answer.reasoning = "用户要一句请假的话，语气要礼貌、简短。"
        messages = [
            ChatBubble(role: .user, text: "帮我写一句请假的话"),
            answer
        ]
    }
    #endif

    /// 重发最后一句。
    func retry() {
        guard phase == .idle, let last = messages.last(where: { $0.role == .user }) else { return }
        triedOtherModel = false
        while let tail = messages.last, tail.role == .assistant {
            messages.removeLast()
        }
        if Self.looksLikeDrawing(last.text) {
            draw(prompt: Self.drawingPrompt(from: last.text))
        } else {
            start(userText: last.text)
        }
    }

    private func start(userText: String, reasoningAllowed: Bool = true) {
        let snapshot = session.snapshot
        guard let provider = snapshot.defaultProvider, provider.supportsChat,
              let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            messages.append(ChatBubble(role: .assistant, text: Self.notConfiguredText, isError: true))
            return
        }

        let context = session.host?.documentProxy.documentContextBeforeInput ?? ""
        var request = PromptLibrary.chatRequest(text: userText,
                                                context: context,
                                                history: history(excluding: userText),
                                                maxTokens: nil)
        apply(prefs, to: &request, provider: provider, reasoningAllowed: reasoningAllowed)
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey, capturesReasoning: true)
        let bubble = ChatBubble(role: .assistant, text: "", isStreaming: true)
        messages.append(bubble)
        let bubbleID = bubble.id
        phase = .thinking(request.reasoning == .deep ? "正在深度思考…" : "正在想…")
        let usedReasoning = request.reasoning != nil

        task = Task { [weak self] in
            do {
                var receivedAny = false
                for try await delta in client.stream(request) {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if let thought = delta.reasoning, !thought.isEmpty {
                        self.appendReasoning(thought, to: bubbleID)
                        if !receivedAny {
                            self.phase = .thinking("正在思考…")
                        }
                    }
                    if !delta.text.isEmpty {
                        receivedAny = true
                        self.phase = .streaming
                        self.append(delta.text, to: bubbleID)
                    }
                    if delta.isFinal { break }
                }
                guard let self, !Task.isCancelled else { return }
                self.finish(bubbleID: bubbleID, receivedAny: receivedAny)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let mapped = AIError.wrap(error)
                if usedReasoning, case .server(400, _) = mapped {
                    // 这家不认推理参数：记下来，去掉再发
                    self.markReasoningUnsupported(provider.id)
                    self.messages.removeAll { $0.id == bubbleID }
                    self.start(userText: userText, reasoningAllowed: false)
                } else if !self.triedOtherModel, ProviderCheck.isModelProblem(mapped) {
                    self.triedOtherModel = true
                    self.switchModel(after: mapped, provider: provider, apiKey: apiKey, userText: userText, bubbleID: bubbleID)
                } else {
                    self.fail(mapped, bubbleID: bubbleID)
                }
            }
        }
    }

    /// 把人设、回答长短、推理强度放进请求。
    private func apply(_ prefs: AIPrefs, to request: inout ChatRequest, provider: AIProviderConfig, reasoningAllowed: Bool) {
        if let index = request.messages.firstIndex(where: { $0.role == .system }) {
            request.messages[index] = .system(request.messages[index].content + "\n" + prefs.systemAddition)
        } else {
            request.messages.insert(.system(prefs.systemAddition), at: 0)
        }
        let level = reasoningAllowed && !Self.reasoningUnsupported(provider.id) ? prefs.reasoning.level : nil
        request.reasoning = level
        switch level {
        case .deep:
            request.maxTokens = max(prefs.length.maxTokens, 4000)
        case .fast:
            request.maxTokens = prefs.length.maxTokens
        case nil:
            // 自动时模型可能自己会先想，留足预算
            request.maxTokens = max(prefs.length.maxTokens, 2000)
        }
    }

    private static func reasoningUnsupported(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: unsupportedKey) ?? []).contains(id)
    }

    private func markReasoningUnsupported(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: Self.unsupportedKey) ?? []
        if !list.contains(id) {
            list.append(id)
            UserDefaults.standard.set(list, forKey: Self.unsupportedKey)
        }
        session.showToast("这个服务不支持调推理，按默认回答")
    }

    /// 模型用不了（下线了或没开通）：换一个能用的，存下来，再发一次。
    private func switchModel(after error: AIError, provider: AIProviderConfig, apiKey: String,
                             userText: String, bubbleID: UUID) {
        phase = .thinking("这个模型用不了，正在换一个…")
        task = Task { [weak self] in
            let result = await ProviderCheck.run(config: provider, apiKey: apiKey)
            guard let self, !Task.isCancelled else { return }
            guard result.isUsable, result.config.model != provider.model else {
                self.fail(result.isUsable ? error : AIError.unknown(result.message), bubbleID: bubbleID)
                return
            }
            var snapshot = self.session.snapshot
            if let index = snapshot.providers.firstIndex(where: { $0.id == provider.id }) {
                snapshot.providers[index] = result.config
                self.session.saveConfig(snapshot)
            }
            self.messages.removeAll { $0.id == bubbleID }
            self.session.showToast("已换成 \(result.config.model)")
            self.start(userText: userText)
        }
    }

    private func history(excluding userText: String) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages where !message.isError && !message.text.isEmpty && message.image == nil {
            result.append(message.role == .user ? .user(message.text) : .assistant(message.text))
        }
        if let last = result.last, last.role == .user, last.content == userText {
            result.removeLast()
        }
        let keep = max(prefs.contextTurns, 0) * 2
        return keep == 0 ? [] : Array(result.suffix(keep))
    }

    private func append(_ text: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }

    private func appendReasoning(_ text: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].reasoning += text
    }

    private func finish(bubbleID: UUID, receivedAny: Bool) {
        task = nil
        phase = .idle
        guard let index = messages.firstIndex(where: { $0.id == bubbleID }) else { return }
        messages[index].isStreaming = false
        if !receivedAny {
            messages[index].text = "模型没有返回内容。换一个模型试试，或者把「推理」调成快速。"
            messages[index].isError = true
        } else {
            record(isUser: false, text: messages[index].text)
        }
    }

    private func fail(_ error: Error, bubbleID: UUID) {
        task = nil
        phase = .idle
        let mapped = AIError.wrap(error)
        guard mapped != .cancelled, let index = messages.firstIndex(where: { $0.id == bubbleID }) else { return }
        let title = mapped.errorDescription ?? "出错了"
        let detail = mapped.recoverySuggestion ?? ""
        messages[index].text = detail.isEmpty ? title : "\(title)\n\(detail)"
        messages[index].isStreaming = false
        messages[index].isError = true
    }

    // MARK: - 画图

    private func draw(prompt: String) {
        let snapshot = session.snapshot
        guard let provider = snapshot.imageProvider ?? snapshot.providers.first(where: { $0.supportsImage }),
              let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            messages.append(ChatBubble(role: .assistant,
                                       text: "还没配画图服务。关掉对话，点工具栏的齿轮 › AI 服务，添加即梦或通义万相。",
                                       isError: true))
            return
        }
        let bubble = ChatBubble(role: .assistant, text: "", isStreaming: true)
        messages.append(bubble)
        let bubbleID = bubble.id
        phase = .thinking("正在画，一般要 5 到 20 秒…")
        let client = AIClientFactory.makeImage(config: provider, apiKey: apiKey)
        let request = ImageRequest(prompt: prompt + prefs.imageStyle.promptSuffix, size: prefs.imageShape.size)

        task = Task { [weak self] in
            do {
                let images = try await client.generate(request)
                guard let self, !Task.isCancelled else { return }
                guard let first = images.first, !first.isEmpty else {
                    self.fail(AIError.unknown("没有拿到图片"), bubbleID: bubbleID)
                    return
                }
                let item = ImageHistory.shared.add(first.data, prompt: prompt)
                guard let index = self.messages.firstIndex(where: { $0.id == bubbleID }) else { return }
                self.messages[index].text = prompt
                self.messages[index].imageID = item?.id
                self.messages[index].image = item.flatMap { ImageHistory.shared.thumbnail(for: $0.id, side: 220) }
                    ?? UIImage(data: first.data)
                self.messages[index].isStreaming = false
                self.phase = .idle
                self.task = nil
                self.record(isUser: false, text: "（画了一张图：\(prompt)）")
                // 配置里的模型用不了、换了一个才画出来：存回去
                if let used = first.model, used != provider.imageModel {
                    var updated = self.session.snapshot
                    if let row = updated.providers.firstIndex(where: { $0.id == provider.id }) {
                        updated.providers[row].imageModel = used
                        self.session.saveConfig(updated)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fail(error, bubbleID: bubbleID)
            }
        }
    }

    /// 把一段回答画成图。
    func drawAnswer(_ bubble: ChatBubble) {
        guard phase == .idle, !bubble.text.isEmpty else { return }
        let prompt = String(bubble.text.prefix(200))
        messages.append(ChatBubble(role: .user, text: "把这段画成图"))
        draw(prompt: prompt)
    }

    // MARK: - 其它

    /// 停止。
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
        while let last = messages.last, last.role == .assistant, last.text.isEmpty, last.image == nil {
            messages.removeLast()
        }
    }

    private func trim() {
        if messages.count > Self.historyLimit {
            messages.removeFirst(messages.count - Self.historyLimit)
        }
    }

    /// 存进对话记录（App 里能看）。
    private func record(isUser: Bool, text: String) {
        guard prefs.keepHistory, !text.isEmpty else { return }
        var entries = ChatHistoryStore.load()
        entries.append(ChatHistoryEntry(isUser: isUser, text: text))
        ChatHistoryStore.save(entries)
    }

    /// 把回答放进聊天框。
    func useInField(_ bubble: ChatBubble) {
        session.host?.documentProxy.insertText(bubble.text)
        session.setPage(.keys)
        session.showToast("已放进输入框")
    }

    /// 复制回答。
    func copy(_ bubble: ChatBubble) {
        UIPasteboard.general.string = bubble.text
        session.showToast("已复制")
    }

    /// 复制图片。
    func copyImage(_ bubble: ChatBubble) {
        guard let id = bubble.imageID, let data = ImageHistory.shared.data(for: id), let picture = UIImage(data: data) else {
            session.showToast("这张图找不到了")
            return
        }
        UIPasteboard.general.image = picture
        session.showToast("已复制，到聊天框长按粘贴")
    }

    /// 存到相册。
    func saveImage(_ bubble: ChatBubble) {
        guard let id = bubble.imageID, let data = ImageHistory.shared.data(for: id) else {
            session.showToast("这张图找不到了")
            return
        }
        ImageHistory.saveToPhotos(data) { [weak self] message in
            self?.session.showToast(message)
        }
    }
}
