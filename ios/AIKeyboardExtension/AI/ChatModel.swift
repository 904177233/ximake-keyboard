//
//  ChatModel.swift
//  墨语键盘 · AI 对话
//
//  整个键盘变成一个对话框。打的字进对话框，不进聊天框；回答可以一键放进聊天框。
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
    var isStreaming = false
    var isError = false
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

    private static let historyLimit = 16

    private unowned let session: KeyboardSession
    private var task: Task<Void, Never>?

    init(session: KeyboardSession) {
        self.session = session
    }

    /// 进入对话前的检查结果，给界面显示。
    var blocker: AIBlocker? { session.aiBlocker }

    /// 准备进入。消息保留，下次回来接着聊。
    func prepare() {
        if messages.isEmpty {
            messages = []
        }
    }

    /// 清空对话。
    func clear() {
        cancel()
        messages = []
    }

    /// 发送草稿。在回答时再按一次就是停止。
    func send() {
        if phase != .idle {
            cancel()
            return
        }
        let text = session.takeDraft().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let blocker = session.aiBlocker {
            switch blocker {
            case .noFullAccess:
                messages.append(ChatBubble(role: .assistant,
                                           text: "还没打开完全访问，键盘连不上网。到 设置 › 通用 › 键盘 › 键盘 › 墨语，打开「允许完全访问」。",
                                           isError: true))
            case .notConfigured:
                messages.append(ChatBubble(role: .assistant,
                                           text: "还没配好 AI 服务。点右上角的齿轮，选一家服务，填上 Key。",
                                           isError: true))
            }
            return
        }
        messages.append(ChatBubble(role: .user, text: text))
        trim()
        start(userText: text)
    }

    /// 重发最后一句。
    func retry() {
        guard phase == .idle, let last = messages.last(where: { $0.role == .user }) else { return }
        while let tail = messages.last, tail.role == .assistant {
            messages.removeLast()
        }
        start(userText: last.text)
    }

    private func start(userText: String) {
        let snapshot = session.snapshot
        guard let provider = snapshot.defaultProvider, provider.supportsChat,
              let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            messages.append(ChatBubble(role: .assistant, text: "还没配好 AI 服务。", isError: true))
            return
        }

        let context = session.host?.documentProxy.documentContextBeforeInput ?? ""
        let request = PromptLibrary.chatRequest(text: userText,
                                                context: context,
                                                history: history(excluding: userText),
                                                maxTokens: nil)
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        var bubble = ChatBubble(role: .assistant, text: "", isStreaming: true)
        messages.append(bubble)
        let bubbleID = bubble.id
        bubble.text = ""
        phase = .thinking("正在想…")

        task = Task { [weak self] in
            do {
                var receivedAny = false
                for try await delta in client.stream(request) {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if !delta.text.isEmpty {
                        receivedAny = true
                        self.phase = .streaming
                        self.append(delta.text, to: bubbleID)
                    } else if delta.reasoning?.isEmpty == false, !receivedAny {
                        self.phase = .thinking("模型在推理，可能要十几秒…")
                    }
                    if delta.isFinal { break }
                }
                guard let self, !Task.isCancelled else { return }
                self.finish(bubbleID: bubbleID, receivedAny: receivedAny)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fail(error, bubbleID: bubbleID)
            }
        }
    }

    private func history(excluding userText: String) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages where !message.isError && !message.text.isEmpty {
            result.append(message.role == .user ? .user(message.text) : .assistant(message.text))
        }
        if let last = result.last, last.role == .user, last.content == userText {
            result.removeLast()
        }
        return result
    }

    private func append(_ text: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }

    private func finish(bubbleID: UUID, receivedAny: Bool) {
        task = nil
        phase = .idle
        guard let index = messages.firstIndex(where: { $0.id == bubbleID }) else { return }
        messages[index].isStreaming = false
        if !receivedAny {
            messages[index].text = "模型没有返回内容。换一个模型试试。"
            messages[index].isError = true
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

    /// 停止。
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
        while let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
        }
    }

    private func trim() {
        if messages.count > Self.historyLimit {
            messages.removeFirst(messages.count - Self.historyLimit)
        }
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
}
