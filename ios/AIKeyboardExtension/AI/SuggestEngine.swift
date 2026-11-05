//
//  SuggestEngine.swift
//  墨语键盘 · AI 猜下一句
//
//  这是非传统联想：不是词库给下一个词，而是根据输入框里的话猜你接下来想说什么。
//  本地规则先给结果，AI 回来再覆盖。全程静默，失败不提示，也不改键盘高度。
//

import Foundation

@MainActor
final class SuggestEngine {

    private static let debounce: UInt64 = 450_000_000
    private static let throttle: TimeInterval = 3
    private static let timeout: UInt64 = 2_500_000_000
    private static let cooldown: TimeInterval = 5
    private static let minimumContext = 6
    private static let maximumChips = 3
    private static let maximumCharacters = 14

    private unowned let session: KeyboardSession
    private var debounceTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var lastRequestAt = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var requestID = UUID()

    init(session: KeyboardSession) {
        self.session = session
    }

    /// 上屏后调用。
    func schedule() {
        guard session.snapshot.enableAISuggestion else { return }
        guard session.aiBlocker == nil, Date() >= cooldownUntil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.request()
        }
    }

    /// 取消。
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = UUID()
    }

    /// 用户点了 AI 给的词，记下来，下次本地就能给。
    func recordAccepted(_ text: String) {
        let context = currentContext
        guard !context.isEmpty else { return }
        session.kit.contextual.record(context: context, committed: text)
    }

    private var currentContext: String {
        let before = session.host?.documentProxy.documentContextBeforeInput ?? ""
        return LocalSuggestionIndex.lastSentence(before)
    }

    private func request() {
        let context = currentContext
        guard context.count >= Self.minimumContext, !session.isComposing else { return }
        let token = UUID()
        requestID = token

        let local = session.kit.contextual.suggestions(context: context, composing: "", limit: 2)
        let chips = Self.clean(local.map { $0.text })
        if !chips.isEmpty {
            session.setAISuggestions(chips)
        }

        let now = Date()
        guard now.timeIntervalSince(lastRequestAt) >= Self.throttle else { return }
        lastRequestAt = now

        guard let provider = session.snapshot.defaultProvider, provider.supportsChat,
              let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else { return }
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        let prompt = PromptLibrary.suggestionRequest(context: context, text: "")

        let timeout = Self.timeout
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            do {
                let output: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await client.complete(prompt).text
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeout)
                        throw AIError.timeout
                    }
                    guard let first = try await group.next() else { throw AIError.timeout }
                    group.cancelAll()
                    return first
                }
                guard let self, !Task.isCancelled, token == self.requestID else { return }
                let parsed = Self.clean(PromptLibrary.parseSuggestionCandidates(output))
                if parsed.isEmpty {
                    self.cooldownUntil = Date().addingTimeInterval(Self.cooldown)
                } else {
                    self.session.setAISuggestions(parsed)
                }
            } catch {
                guard let self else { return }
                self.cooldownUntil = Date().addingTimeInterval(Self.cooldown)
            }
        }
    }

    private static func clean(_ raw: [String]) -> [String] {
        var result: [String] = []
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "「", "」", "『", "』"]
        for item in raw {
            var value = item.trimmingCharacters(in: .whitespacesAndNewlines)
            value = String(value.filter { !quotes.contains($0) && !$0.isNewline })
            if value.count > maximumCharacters {
                value = String(value.prefix(maximumCharacters))
            }
            if !value.isEmpty, !result.contains(value) {
                result.append(value)
            }
            if result.count >= maximumChips { break }
        }
        return result
    }
}
