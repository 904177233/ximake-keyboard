//
//  KeyboardViewModel+Text.swift
//  AIKeyboardExtension
//
//  文本写入与回车键语义（从 KeyboardViewModel.swift 拆出）。
//
//  为什么拆：主文件已接近 600 行硬上限（static_check 的 FILE-TOO-LONG），
//  而「上屏 / 清组字 / 刷新上下文 / 刷新回车键语义」是一组高内聚、低耦合的操作，
//  放一起更便于维护，也让主文件只留状态与生命周期。
//

import Foundation
import UIKit

extension KeyboardViewModel {

    // MARK: - 文本写入

    /// 直接上屏一段文本（自动收干净组字状态）。
    ///
    /// **为什么要先清 marked text**：`UITextDocumentProxy.insertText(_:)` 在部分宿主
    /// （SwiftUI `TextEditor` / 某些第三方 `UITextView`）里**不会替换**正在 marked 的
    /// 拼音串，而是追加在后面，表现为「输入框里 `wq` 和候选词同时存在」「字数比实际多」。
    /// 所以上屏前先 `setMarkedText("")` 把组字结束掉（内容为空，不会残留字符）。
    /// - Parameter text: 待上屏文本。
    public func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        if !composing.isEmpty {
            proxy?.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            composing = ""
            candidates = []
            highlightedCandidateIndex = 0
            candidatePageIndex = 0
        }
        proxy?.insertText(text)
        onInsert?(text)
    }

    /// 清空组字状态并刷新候选。
    public func clearComposing() {
        composing = ""
        candidates = []
        highlightedCandidateIndex = 0
        candidatePageIndex = 0
        proxy?.unmarkText()
    }

    /// 刷新上下文预览（AI 面板打开时调用）。
    public func reloadContextPreview() {
        let context = contextTail
        panelContextPreview = context
        showsContextTruncationHint = proxyContext.count > Self.contextCharacterLimit
    }

    // MARK: - 回车键语义

    /// 刷新回车键语义（读宿主输入框的 `returnKeyType`）。
    ///
    /// 由 `activate()` 与 `KeyboardViewController.textDidChange(_:)` 调用 —— 切到别的
    /// 输入框（聊天框 ↔ 搜索框 ↔ 普通文本框）时 `returnKeyType` 会变，键面要跟着变。
    public func refreshReturnKeyKind() {
        guard let proxy else {
            returnKeyKind = .newline
            return
        }
        switch proxy.returnKeyType ?? .default {
        case .send:
            returnKeyKind = .send
        case .search, .google, .yahoo:
            returnKeyKind = .search
        case .go, .route:
            returnKeyKind = .go
        case .done:
            returnKeyKind = .done
        case .next:
            returnKeyKind = .next
        case .default, .continue, .join, .emergencyCall:
            returnKeyKind = .newline
        @unknown default:
            returnKeyKind = .newline
        }
    }
}
