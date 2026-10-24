//
//  CandidateBar.swift
//  墨语（Moyu）键盘扩展 · 候选栏
//
//  模块职责：显示当前页候选（每页最多 9 个），首候选高亮为 accent + semibold，
//            右侧分页指示点，左侧可选页码开关，空态显示品牌语。
//  设计依据：design/组件库.md「CandidateBar」（44 固定 / 项最小宽 48 / 项间距 20 /
//            左右内边距 16 / 高亮底 candidateSelected 圆角 6 仅覆盖文字 ±6 / 分页点 6×6
//            间距 5 / 空态「墨语 · 会 AI 的输入法」12pt textTertiary 左对齐 16）。
//  约束：高度固定 44，绝不因候选内容变化而改变；候选变化只做 opacity 0.15s 过渡。
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

    /// 选择候选（参数为本页内下标）。
    let onSelect: (Int) -> Void

    /// 长按候选（参数为本页内下标）。
    let onLongPress: ((Int) -> Void)?

    /// 翻页（-1 / +1）。
    let onTogglePage: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if items.isEmpty {
                emptyState
            } else {
                candidateScroll
            }
            paginationIndicator
        }
        .frame(height: Theme.Sizing.candidateBarHeight)
        .background(Theme.candidateBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.candidateSeparator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
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
                        .font(.system(size: 10, weight: .medium))  // TOKEN: typography.caption.size ≈ 10
                        .foregroundColor(Theme.textTertiary)
                }
                Text(candidate.text)
                    .font(isHighlighted ? Theme.fontHeadline : Theme.fontCandidate)
                    .foregroundColor(isHighlighted ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minWidth: Theme.Sizing.candidateItemMinWidth)
            .frame(minHeight: Theme.Sizing.minTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(isHighlighted ? Theme.candidateSelected : Color.clear)
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

    /// 右侧分页区（固定 8 宽 + 点击翻页）。
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
            Color.clear
                .frame(width: Theme.Spacing.md)
        }
    }
}
