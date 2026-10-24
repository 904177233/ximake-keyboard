//
//  CandidateBar.swift
//  墨语（Moyu）键盘扩展 · 候选栏
//
//  模块职责：44pt 固定高度的一行，从左到右依次是
//            ①候选滚动区（或 AI 联想胶囊行 / 空态文案，三者互斥）
//            ②分页指示点（有分页 24 宽，无分页 0 宽）
//            ③5pt 间隙
//            ④AI 对话旋钮（命中区 44×44，视觉圆 34）
//  设计依据：design/组件库.md「CandidateBar」+ design/04-AI对话与智能联想规范.md §2.2（旋钮布局）、
//            §4.2（候选栏优先级）、§4.3（联想胶囊）。
//  约束：高度固定 44，绝不因候选/联想内容变化而改变；候选项最小宽 48、项间距 20、左右内边距 16；
//        首候选 semibold + accent；高亮底 candidateSelected 圆角 6 仅覆盖文字；
//        分页点 6×6 间距 5、>5 页折叠；空态「墨语 · 会 AI 的输入法」12pt textTertiary 左对齐 16。
//

import SwiftUI

/// 候选栏。
struct CandidateBar: View {

    /// 当前页候选。
    let items: [IMECandidate]

    /// 高亮的候选下标（相对于本页）。
    let highlightedIndex: Int

    /// 是否显示候选序号（长按首候选切换）。
    let showsIndex: Bool

    /// 当前页号（0 起）。
    let pageIndex: Int

    /// 总页数。
    let pageCount: Int

    /// 正在组字的拼音串。
    let composingText: String

    /// 是否显示右侧 AI 对话旋钮（对话面板内的输入行不显示）。
    var showsChatKnob: Bool = true

    /// 旋钮当前状态（由调用方按可用性/忙碌态计算）。
    var knobState: KMChatKnobState = .idle

    /// 是否横屏（旋钮视觉圆 32，竖屏 34）。
    var isLandscape: Bool = false

    /// AI 联想胶囊（≤3 条）；非空且未在组字时优先显示。
    var suggestions: [String] = []

    /// 选择候选（参数为本页内下标）。
    let onSelect: (Int) -> Void

    /// 长按候选（参数为本页内下标）。
    let onLongPress: ((Int) -> Void)?

    /// 翻页（-1 / +1）。
    let onTogglePage: ((Int) -> Void)?

    /// 点击 AI 对话旋钮。
    var onChatKnobTap: (() -> Void)?

    /// 点击联想胶囊（参数为下标）。
    var onSelectSuggestion: ((Int) -> Void)?

    /// 主题主色（design/05 §1.1：候选栏首选字背景是 4 处主色之一）。
    var accent: Color = Theme.accent

    var body: some View {
        HStack(spacing: 0) {
            contentArea
            paginationIndicator
                .frame(width: paginationWidth)
            if showsChatKnob {
                // 旋钮与分页点之间的固定间隙（design/04 §2.2：5pt）。
                Spacer(minLength: 0)
                    .frame(width: Theme.Spacing.sm + Theme.Spacing.xs)
                KMChatKnob(
                    state: knobState,
                    isLandscape: isLandscape,
                    action: { onChatKnobTap?() }
                )
                .frame(width: KMLayout.aiChatKnobHitSize, height: KMLayout.aiChatKnobHitSize)
            }
        }
        .padding(.leading, Theme.Sizing.keyHorizontalPadding)
        .padding(.trailing, showsChatKnob ? KMLayout.aiChatKnobInset : 0)
        .frame(height: Theme.Sizing.candidateBarHeight)
        .background(Theme.candidateBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.candidateSeparator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
    }

    // MARK: - 内容区（候选 / 联想 / 空态，三档互斥）

    /// 内容区：组字中或有关联候选时显示候选；否则有 AI 联想显示联想；都没有则空态。
    @ViewBuilder
    private var contentArea: some View {
        if !items.isEmpty {
            candidateScroll
        } else if !composingText.isEmpty {
            emptyState
        } else if !suggestions.isEmpty, let onSelectSuggestion {
            KMSuggestionChipRow(titles: suggestions, onSelect: onSelectSuggestion)
        } else {
            emptyState
        }
    }

    /// 分页区宽度：有分页 24，无分页 0（design/04 §2.2 修正项）。
    private var paginationWidth: CGFloat {
        pageCount > 1 ? Theme.Spacing.xxl : 0
    }

    // MARK: - 候选列表

    /// 横向滚动的候选列表。
    private var candidateScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Sizing.candidateItemGap) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                        candidateCell(index: pair.offset, candidate: pair.element)
                            .id(pair.offset)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
            }
            .onChange(of: highlightedIndex) { newValue in
                // iOS 16 只支持单参数 onChange。
                guard newValue >= 0, newValue < items.count else { return }
                withAnimation(KMAnimation.animation(duration: Theme.Motion.fast)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个候选。
    /// - Parameters:
    ///   - index: 本页内下标。
    ///   - candidate: 候选数据。
    private func candidateCell(index: Int, candidate: IMECandidate) -> some View {
        let isHighlighted = index == highlightedIndex
        return Button(action: { onSelect(index) }) {
            HStack(spacing: Theme.Spacing.sm) {
                if showsIndex {
                    Text("\(index + 1)")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textTertiary)
                }
                Text(candidate.text)
                    .font(isHighlighted ? Theme.fontHeadline : Theme.fontCandidate)
                    .foregroundColor(isHighlighted ? accent : Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minWidth: Theme.Sizing.candidateItemMinWidth)
            .frame(minHeight: Theme.Sizing.minTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(isHighlighted ? accent.opacity(Theme.MaterialToken.strokeWidth * 0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.97, pressedOpacity: 0.6, duration: Theme.Motion.fast))
        .accessibilityLabel(Text(isHighlighted ? "\(candidate.text)，首个候选" : candidate.text))
        .accessibilityAddTraits(.isButton)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in onLongPress?(index) }
        )
    }

    // MARK: - 空态

    /// 无候选时的品牌语（12pt textTertiary，左对齐，左内边距 16）。
    private var emptyState: some View {
        HStack {
            Text(composingText.isEmpty ? "墨语 · 会 AI 的输入法" : "无匹配 · 长按退格清空")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(composingText.isEmpty ? "墨语候选栏，暂无候选" : "没有匹配的候选"))
    }

    // MARK: - 分页指示

    /// 分页区（有分页时 24 宽可点翻页；无分页时完全收起为 0 宽）。
    @ViewBuilder
    private var paginationIndicator: some View {
        if pageCount > 1 {
            Button(action: {
                KMHaptics.candidate()
                onTogglePage?(1)
            }) {
                HStack(spacing: Theme.Sizing.pageDotGap) {
                    ForEach(0..<min(pageCount, 5), id: \.self) { index in
                        Circle()
                            .fill(index == pageIndex ? Theme.accent : Theme.textTertiary)
                            .frame(width: Theme.Sizing.pageDotSize, height: Theme.Sizing.pageDotSize)
                    }
                }
                .frame(width: Theme.Spacing.xxl, height: Theme.Sizing.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.94, pressedOpacity: 0.7, duration: Theme.Motion.fast))
            .accessibilityLabel(Text("翻页，第 \(pageIndex + 1) 页，共 \(pageCount) 页"))
        } else {
            EmptyView()
        }
    }
}
