//
//  KeyboardViewModel+ChatInput.swift
//  墨语（Moyu）键盘扩展 · AI 对话页的拼音组字
//
//  模块职责：让 `.aiChat` 页的字母键走与宿主输入框一致的拼音组字流程。
//
//  背景（v2.2 用户反馈「在墨语 AI 对话中不能输入中文」）：
//  对话页的键区原本直接 `appendChatDraft(text)`，把字母原样塞进草稿，
//  中文用户只能打英文。修复方式不是另写一套输入法，而是**复用同一套引擎**：
//  字母进 `composing` → 候选栏出词 → 选词时把结果写进 `chatDraft` 而不是
//  宿主输入框。这样候选质量、纠错、模糊音在对话页与宿主里完全一致。
//

import Foundation

extension KeyboardViewModel {

    /// 对话页的字母输入：进拼音组字（与宿主输入框同一条链路）。
    /// - Parameter text: 单个字母。
    func handleChatCharacter(_ text: String) {
        guard !text.isEmpty else { return }
        if shiftState == .on {
            shiftState = .off
        }
        guard text.count == 1, let scalar = text.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.uppercaseLetters.contains(scalar) else {
            // 数字 / 符号：仍直接进草稿（不需要组字）。
            appendChatDraft(text)
            return
        }
        clearSuggestions()
        composing += text.lowercased()
        // 对话页不把拼音写进宿主输入框，只更新键盘自己的状态；
        // 候选栏由 `refreshCandidates()` 驱动。
        refreshCandidates()
    }

    /// 对话页的退格：组字中先回退拼音，否则删草稿最后一个字符。
    func handleChatBackspace() {
        if !composing.isEmpty {
            composing.removeLast()
            if composing.isEmpty {
                candidates = []
                highlightedCandidateIndex = 0
                candidatePageIndex = 0
            } else {
                refreshCandidates()
            }
            return
        }
        deleteChatDraftCharacter()
    }

    /// 对话页的空格：组字中上屏首选，否则插入一个空格。
    func handleChatSpace() {
        if !composing.isEmpty, !currentPageCandidates.isEmpty {
            commitCandidateToChat(at: 0)
            return
        }
        if !composing.isEmpty {
            composing = ""
            candidates = []
            highlightedCandidateIndex = 0
            candidatePageIndex = 0
        }
        appendChatDraft(" ")
    }

    /// 对话页选词：把候选写进 `chatDraft`（不碰宿主输入框）。
    /// - Parameter index: 候选下标（本页内的可见下标）。
    public func commitCandidateToChat(at index: Int) {
        guard let absolute = candidateAbsoluteIndex(visibleIndex: index) else { return }
        let candidate = candidates[absolute]
        engine.commit(candidate, input: composing)
        appendChatDraft(candidate.text)
        lastCommittedText = candidate.text
        composing = ""
        candidates = []
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
        KMHaptics.candidate()
        scheduleSuggestions()
    }
}
