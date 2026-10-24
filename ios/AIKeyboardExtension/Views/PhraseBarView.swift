//
//  PhraseBarView.swift
//  墨语（Moyu）键盘扩展 · 快捷短语 / 剪贴板浮层
//
//  模块职责：在键区之上浮出两条横滚列表：
//            ①快捷短语（`PhraseLibrary.items`，点一条即上屏，支持长按置顶提示）；
//            ②剪贴板历史（`ClipboardHistory.items`，需完全访问才读得到）。
//            浮层不改变键盘总高度（高度仍由 `KeyboardController` 决定），
//            而是覆盖键区，点击空白处或关闭按钮收起。
//  设计依据：design/键盘布局规范.md §4.6 的列表式思路、PRD §4.1「快捷短语 & 剪贴板历史」。
//  约束：浮层里的可点项命中区 ≥44；无内容时给可读空态而不是空白。
//

import SwiftUI

/// 短语 / 剪贴板浮层。
struct PhraseBarView: View {

    /// 浮层模式。
    enum Mode: Equatable {
        /// 快捷短语。
        case phrases
        /// 剪贴板历史。
        case clipboard
    }

    /// 当前模式。
    let mode: Mode

    /// 快捷短语文本。
    let phrases: [String]

    /// 剪贴板历史文本。
    let clipboardItems: [String]

    /// 选中一条。
    let onSelect: (String) -> Void

    /// 关闭浮层。
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.surfaceGrouped)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 头部

    /// 浮层头部：标题 + 条数 + 关闭。
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            KMIconGlyph(
                symbol: mode == .phrases ? "text.bubble" : "doc.on.clipboard",
                fallback: mode == .phrases ? "🗂" : "📋",
                size: 14,
                tint: Theme.textSecondary
            )
            Text(mode == .phrases ? "快捷短语" : "剪贴板历史")
                .font(Theme.fontBody)
                .fontWeight(.medium)
                .foregroundColor(Theme.textPrimary)
            Text("\(currentItems.count) 条")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textTertiary)
            Spacer(minLength: 0)
            Button(action: {
                KMHaptics.chip()
                onClose()
            }) {
                Text("收起")
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, Theme.Spacing.md)
                    .frame(height: Theme.Sizing.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.96))
            .accessibilityLabel(Text("收起\(mode == .phrases ? "短语" : "剪贴板")面板"))
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: Theme.Sizing.minTapTarget)
    }

    // MARK: - 内容

    /// 列表内容（空态 / 横滚胶囊）。
    @ViewBuilder
    private var content: some View {
        if currentItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(currentItems.enumerated()), id: \.offset) { pair in
                        row(text: pair.element)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
    }

    /// 单行：文本 + 上屏图标。
    /// - Parameter text: 待上屏文本。
    private func row(text: String) -> some View {
        Button(action: {
            KMHaptics.candidate()
            onSelect(text)
        }) {
            HStack(spacing: Theme.Spacing.md) {
                Text(text)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                KMIconGlyph(symbol: "arrow.up.left", fallback: "↑", size: 12, tint: Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(minHeight: Theme.Sizing.minTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.98, pressedOpacity: 0.9))
        .accessibilityLabel(Text(text))
        .accessibilityHint(Text("点击上屏"))
    }

    /// 空态。
    private var emptyState: some View {
        KMEmptyState(
            systemImage: mode == .phrases ? "text.bubble" : "doc.on.clipboard",
            fallback: mode == .phrases ? "🗂" : "📋",
            title: mode == .phrases ? "还没有快捷短语" : "剪贴板历史为空",
            message: mode == .phrases
                ? "在宿主 App 里添加常用短语，键盘内即可一键上屏"
                : "复制内容后回到键盘可在这里取用"
        )
    }

    // MARK: - 数据

    /// 当前模式对应的数据源。
    private var currentItems: [String] {
        mode == .phrases ? phrases : clipboardItems
    }
}
