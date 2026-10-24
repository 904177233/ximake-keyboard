//
//  KeyboardViewModel+Input.swift
//  墨语（Moyu）键盘扩展 · 输入处理（从 KeyboardViewModel.swift 拆出以控制单文件行数）
//
//  模块职责：拼音组字、退格、Shift、上屏、候选刷新与联想预测的私有实现。
//  设计依据：docs/02 §4.7（键盘扩展契约）、docs/06 §6（数据流）。
//  说明：这些方法只被 `KeyboardViewModel.tap(_:)` 与候选选择调用，不对外暴露。
//

import Foundation

extension KeyboardViewModel {

    // MARK: - 私有实现

    /// 字符按键：英文直通；中文走拼音组字。
    func handleCharacter(_ text: String) {
        guard !text.isEmpty else { return }
        if shiftState == .on {
            shiftState = .off
        }
        // 字母 → 进入拼音组字；数字 / 符号 / 表情 → 直接上屏。
        if text.count == 1, let scalar = text.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.uppercaseLetters.contains(scalar) {
            // 组合态不显示联想（design/04 §4.2 优先级 1），立即清空避免闪动。
            clearSuggestions()
            composing += text.lowercased()
            updateMarkedText()
            refreshCandidates()
            return
        }
        commitLiteral(text)
    }

    /// 退格：优先删组字，其次删宿主文本。
    func handleBackspace() {
        if !composing.isEmpty {
            composing.removeLast()
            if composing.isEmpty {
                clearComposing()
                // 组字删空：重新给一次联想（design/04 §4.6「组合结束恢复」）。
                scheduleSuggestions()
            } else {
                updateMarkedText()
                refreshCandidates()
            }
            return
        }
        let before = proxy?.documentContextBeforeInput ?? ""
        proxy?.deleteBackward()
        let after = proxy?.documentContextBeforeInput ?? ""
        // 删空输入框：立即清空联想且不再请求（design/04 §4.4 触发时机 C）。
        if after.isEmpty && !before.isEmpty {
            clearSuggestions()
        } else {
            scheduleSuggestions()
        }
    }

    /// Shift 循环：off → on → locked → off。
    func handleShift() {
        switch shiftState {
        case .off:
            shiftState = .on
        case .on:
            shiftState = .locked
        case .locked:
            shiftState = .off
        }
    }

    /// 上屏固定文本（数字 / 符号 / 空格 / 换行）。
    func commitLiteral(_ text: String) {
        if !composing.isEmpty {
            clearComposing()
        }
        insertText(text)
        lastCommittedText = text
        // 上屏后启动联想防抖（design/04 §4.4 触发时机 A）。
        scheduleSuggestions()
    }

    /// 同步拼音组字到宿主输入框（marked text）。
    func updateMarkedText() {
        let range = NSRange(location: (composing as NSString).length, length: 0)
        proxy?.setMarkedText(composing, selectedRange: range)
    }

    /// 重新计算候选列表。
    func refreshCandidates() {
        guard !composing.isEmpty else {
            candidates = []
            highlightedCandidateIndex = 0
            candidatePageIndex = 0
            return
        }
        let limit = Self.candidatePageSize * 3
        candidates = engine.candidates(for: composing, limit: limit)
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
    }

    /// 上屏后刷新联想候选。
    func refreshPredictions() {
        let predictions = engine.predictNext(after: lastCommittedText, limit: 6)
        guard !predictions.isEmpty else {
            candidates = []
            candidatePageIndex = 0
            // 传统联想为空时，AI 联想有机会占位（design/04 §4.2 优先级 3）。
            scheduleSuggestions()
            return
        }
        candidates = predictions
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
    }

    /// 刷新短语列表。
    func refreshPhrases() {
        phrases = engine.phrases
    }

    /// 刷新剪贴板历史。
    func refreshClipboard() {
        clipboardItems = snapshot.enableClipboardHistory ? engine.clipboardItems : []
    }

    // MARK: - 工具

    /// 取字符串末尾若干字符。
    /// - Parameters:
    ///   - text: 原文本。
    ///   - limit: 最多保留的字符数。
    /// - Returns: 截断后的尾部文本。
    static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }
}
