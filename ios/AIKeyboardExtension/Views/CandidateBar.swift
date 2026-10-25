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

    /// 滑动候选时的高亮跟随（参数为本页内下标）。
    ///
    /// v1.4 用户反馈「候选词可以滑动选取」：国产输入法（微信/搜狗）在候选条上
    /// 横向滑动会移动高亮，松手即上屏。这里把「滑动」拆成两步回调：
    /// 滑动中不断 `onHighlight`（视觉高亮跟随手指），松手才 `onSelect`（真正上屏）。
    var onHighlight: ((Int) -> Void)?

    /// 收起候选栏（v2.2：让用户能退回 AI 工具条）。
    var onDismiss: (() -> Void)?

    /// 主题主色（design/05 §1.1：候选栏首选字背景是 4 处主色之一）。
    var accent: Color = Theme.accent

    var body: some View {
        HStack(spacing: 0) {
            contentArea
            paginationIndicator
                .frame(width: paginationWidth)
            if let onDismiss {
                // v2.2：候选栏右侧的收起按钮。用户反馈「候选词选完没有关闭
                // 候选词能力」，这颗键让效用行退回 AI 工具条；再打字会自动恢复。
                Button(action: {
                    KMHaptics.chip()
                    onDismiss()
                }) {
                    KMIconGlyph(symbol: "chevron.down", fallback: "⌄",
                                size: 13, tint: Theme.textTertiary)
                        .frame(width: Theme.Sizing.minTapTarget,
                               height: Theme.Sizing.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KMPressableStyle(scale: 0.92, pressedOpacity: 0.7))
                .accessibilityLabel(Text("收起候选栏"))
            }
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
        // v2.2 修用户反馈「候选词交互逻辑问题非常严重，不是正常滑动选词」：
        // 原来的 `simultaneousGesture` 与 `ScrollView` 同时响应，手指一滑
        // 候选列表在滚、高亮也在跳，最后松手还会上屏一个没看清楚的词。
        // 现在改为 `highPriorityGesture` 只接管**明显的横滑**（|dx| > 24 且
        // 横向远大于纵向），其余情况一律让 `ScrollView` 自己滚 ——
        // 与微信/搜狗一致：轻扫滚动看更多候选，明确横滑才逐格选词。
        .highPriorityGesture(swipeSelectionGesture)
    }

    /// 横向滑动选词：滑过一个个候选，松手上屏。
    ///
    /// 步长按 56pt 估算（候选项最小宽 48 + 项间距 20 的一半），
    /// 比精确测宽稳：候选宽度随字数变化，测宽需要 `GeometryReader` 布局回调，
    /// 在键盘里每帧回调的代价不值得。用户实际体验是「滑一点换一个」。
    private var swipeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard items.count > 1 else { return }
                // 纵向意图明显时直接放行给 ScrollView（或让父视图处理）。
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                if swipeStartIndex < 0 {
                    swipeStartIndex = highlightedIndex
                }
                let target = swipeTarget(for: value)
                guard target != highlightedIndex else { return }
                onHighlight?(target)
            }
            .onEnded { value in
                let target = swipeTarget(for: value)
                let start = swipeStartIndex
                swipeStartIndex = -1
                // 只有「确实横向滑过至少一格」才上屏，否则交给候选自身的 tap
                // 或 ScrollView 的滚动处理 —— 避免误上屏。
                guard items.count > 1, start >= 0, target != start,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                onSelect(target)
            }
    }

    /// 手势起点下标（`-1` 表示当前没有进行中的滑动）。
    @State private var swipeStartIndex: Int = -1

    /// 按当前位移算出目标下标（夹在本页范围内）。
    private func swipeTarget(for value: DragGesture.Value) -> Int {
        let start = swipeStartIndex < 0 ? highlightedIndex : swipeStartIndex
        let step: CGFloat = 56
        let offset = Int((value.translation.width / step).rounded())
        return min(max(start + offset, 0), max(items.count - 1, 0))
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
                    // design/06 §1.5：首选的语义由「字重 17 semibold + accentSoft 底」表达，
                    // 字色一律 textPrimary。v1 用主色染字，把主色摊到了第 4、5 处。
                    .font(isHighlighted ? Theme.fontHeadline : Theme.fontCandidate)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                // 纠错候选的角标。
                //
                // v1.7 修：`isTypoCorrection` 之前**只在设置页文案里被提到**，候选栏一行都没渲染，
                // 用户看到一条奇怪的词排在最前面却不知道它是「打错字纠出来的」，所以
                // 反馈「纠错基本用不了」。这里补一个极简角标：不占位、不换行，只用小字 + 次级色，
                // 与候选文字之间留 2pt，避免抢走词本身的可读性。
                if candidate.isTypoCorrection {
                    Text("纠错")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(Theme.textTertiary.opacity(Theme.MaterialToken.strokeWidth * 0.12))
                        )
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minWidth: Theme.Sizing.candidateItemMinWidth)
            .frame(minHeight: Theme.Sizing.minTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    // 主色第 1 处（唯一合法）：候选首选的底。用令牌，不用魔法透明度算式。
                    .fill(isHighlighted ? accent.opacity(0.18) : Color.clear)
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
                            // design/06 §1.5：分页点不属于 3 个「动作位」，不许用主色。
                            .fill(index == pageIndex ? Theme.textSecondary : Theme.textTertiary)
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
