//
//  KeyboardRootView.swift
//  墨语（Moyu）键盘扩展 · SwiftUI 根视图与键盘外壳
//
//  模块职责：键盘扩展的视图树根。负责：
//            ①`KeyboardShell` 统一背景（keyboardBackground + 顶部 0.5pt 阴影）；
//            ②候选栏 44 + AI 工具条 40 共用一条 84pt 连续玻璃背景（布局规范 §8 ④）；
//            ③按 `model.page` 切换键区内容（26 键 / 数字 / 符号 / emoji / AI 面板 / 结果 / 设置 / AI 对话）；
//            ④浮层（短语 / 剪贴板）与 Toast 的叠加。
//  设计依据：design/键盘布局规范.md §1（总高 258）、§4（各页）、§8（视觉层级）、§5（12 状态）；
//            design/04-AI对话与智能联想规范.md §3.2（`.aiChat` 整页隐藏 84pt chrome）。
//  约束：本视图不计算高度——高度由 `KeyboardViewController` 的 `heightAnchor` 唯一决定；
//        本视图只负责在给定高度内排布，因此所有子视图都用固定高度，不用 `Spacer` 撑高。
//

import SwiftUI

/// 某个页面是否需要显示效用行（44pt：候选条 / AI 工具条二选一）。
/// - Parameter page: 当前页面。
/// - Returns: 是否显示。
private func pageShowsChrome(_ page: KeyboardViewModel.Page) -> Bool {
    // `.aiChat` / `.voice` 都是全场模式：自己的标题条替代了效用行（design/04 §3.2）。
    switch page {
    case .aiChat, .voice:
        return false
    default:
        return true
    }
}

/// 旋钮状态：不可用时 disabled、回答中 busy、已打开 active，否则 idle。
/// - Parameter model: 键盘状态机。
/// - Returns: 旋钮外观状态。
///
/// 必须标注 `@MainActor`：`KeyboardViewModel` 是 `@MainActor` 隔离的，
/// 其 `aiAvailability` / `chatPhase` / `isChatOpen` 不能在非隔离上下文里读取
/// （否则报 “main actor-isolated property … can not be referenced from a non-isolated context”）。
@MainActor
private func chatKnobState(for model: KeyboardViewModel) -> KMChatKnobState {
    if model.aiAvailability == .noFullAccess || model.aiAvailability == .notConfigured || model.aiAvailability == .offline {
        return .disabled
    }
    if model.chatPhase.isBusy {
        return .busy
    }
    return model.isChatOpen ? .active : .idle
}

    /// 键盘根视图。
    struct KeyboardRootView: View {

        /// 键盘状态机（由 `KeyboardViewController` 注入并持有）。
        @ObservedObject var model: KeyboardViewModel

        /// 主题状态（design/05 §1）：主色与符号跟随 `ThemeStore.shared.currentTheme`。
        ///
        /// `ThemeStore` 没有 Combine 通知，所以这里把它包成 `@State` + `objectWillChange`
        /// 的手动刷新：设置页改完主题后调用 `applyTheme()` 让视图重算。
        @State private var theme: AppTheme = ThemeStore.shared.currentTheme

        /// 创建根视图。
        /// - Parameter model: 键盘状态机。
        init(model: KeyboardViewModel) {
            self.model = model
        }

        var body: some View {
            ZStack(alignment: .top) {
                KeyboardShell {
                    VStack(spacing: 0) {
                        if pageShowsChrome(model.page) {
                            chrome
                        }
                        keyArea
                    }
                }

                if model.overlay != .none {
                    overlayLayer
                }

                if let toast = model.toastMessage {
                    toastLayer(toast)
                }

                if model.showsFullAccessCard {
                    fullAccessLayer
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .onAppear { reloadThemeState() }
            .onChange(of: model.page) { _ in
                // 从设置页回来时主题 / 小形象可能已改，重算一次。
                reloadThemeState()
            }
        }

        // MARK: - 主题状态

        /// 从 `ThemeStore` 与本地开关重新读取主题、小形象设置。
        private func reloadThemeState() {
            theme = ThemeStore.shared.currentTheme
        }

        /// 主题主色（design/05 §1.1 允许出现在 4 处：候选栏首选字背景 / AI 工具条选中胶囊 / 对话旋钮 / 回车键）。
        private var themeAccent: Color {
            theme.accent
        }


    // MARK: - 效用行（候选条 / AI 工具条二选一，共用 44pt）

    /// 组字中（或存在候选）时效用行显示候选，否则显示 AI 工具条。
    ///
    /// 这是 v1.3 的核心交互改造：此前候选栏 44 + 工具条 40 上下叠了两行、常驻 84pt，
    /// 用户反馈「一直在的时候非常影响正常打字」。现在合并成一行 44pt 交叉淡入淡出，
    /// 与微信输入法/Fleksy 等主流输入法一致：**打字时是候选，不打字时是工具**。
    private var showsCandidateRow: Bool {
        !model.composing.isEmpty || !model.candidates.isEmpty
    }

    /// 效用行：候选条与 AI 工具条占同一格，按 `showsCandidateRow` 交叉淡入淡出。
    private var chrome: some View {
        ZStack {
            // v2（design/06 §1.6）：效用行**不用玻璃**，实色 `Theme.candidateBar` + 底部 0.5pt 发丝线。
            // 键盘背后是任意 App 内容，玻璃会让候选字对比度随背景漂移（白色文档上发灰、
            // 深色视频上发亮），只有实色才可控。
            Theme.candidateBar

            if showsCandidateRow {
                CandidateBar(
                    items: model.currentPageCandidates,
                    highlightedIndex: model.highlightedCandidateIndex,
                    showsIndex: model.candidates.isEmpty == false,
                    pageIndex: model.candidatePageIndex,
                    pageCount: model.candidatePageCount,
                    composingText: model.composing,
                    showsChatKnob: true,
                    knobState: chatKnobState(for: model),
                    isLandscape: model.isLandscape,
                    suggestions: model.suggestionChips,
                    onSelect: { index in model.selectCandidate(at: index) },
                    onLongPress: { index in model.longPressCandidate(at: index) },
                    onTogglePage: { delta in model.turnCandidatePage(delta) },
                    onChatKnobTap: { model.openAIChat() },
                    onSelectSuggestion: { index in model.insertSuggestion(at: index) },
                    onHighlight: { index in model.highlightCandidate(at: index) },
                    accent: themeAccent
                )
                .frame(height: KMLayout.utilityRowHeight)
                .transition(.opacity)
            } else {
                AIBar(
                    items: KMAIBarItem.defaults,
                    availability: model.aiAvailability,
                    isBusy: model.aiState.isBusy,
                    landscapeCompact: model.isLandscape,
                    activeFeature: model.aiState.isBusy ? model.lastFeature : nil,
                    onSelect: { feature in model.startAI(feature) },
                    onOpenSettings: { model.tap(.openSettings) },
                    onOpenPanel: { model.openAIPanel() },
                    onOpenChat: { model.openAIChat() },
                    onDisabledTap: { model.handleAIBarDisabledTap() },
                    showsVoice: model.canUseVoiceInput,
                    onOpenVoice: { model.openVoiceInput() },
                    accent: themeAccent
                )
                .frame(height: KMLayout.utilityRowHeight)
                .transition(.opacity)
            }
        }
        .frame(height: KMLayout.utilityRowHeight)
        .clipped()
        .overlay(alignment: .bottom) {
            // 0.5pt 发丝线：v2 唯一允许的分隔手段（design/06 §1.1「唯一辅助手法：发丝分隔」）。
            Theme.candidateSeparator.frame(height: 0.5)
        }
        .animation(Theme.Motion.fastAnimation, value: showsCandidateRow)
    }

    // MARK: - 键区（按页面切换）

    /// 键区（固定占满剩余高度，内部各页自己排布）。
    @ViewBuilder
    private var keyArea: some View {
        switch model.page {
        case .letters:
            letterKeys
        case .numbers:
            NumberPadView(onTap: { key in model.tap(key) })
        case .symbols:
            SymbolPadView(onTap: { key in model.tap(key) })
        case .emoji:
            EmojiPanelView(
                onTap: { key in model.tap(key) },
                onInsert: { emoji in model.insertText(emoji) }
            )
        case .aiPanel:
            // v2.1 修：面板页不再是「面板顶替键区」，而是「面板叠在键区之上」。
            // 键盘高度 386 = 44(效用行) + 168(面板) + 174(键区)，原来只渲染面板
            // （面板自身 168）会让下面空出 174pt 的键盘底色 —— 就是用户截图里
            // 「设置页/对话框被裁掉、下面一大片灰」的那块空白。
            VStack(spacing: 0) {
                AIPanelView(model: model)
                letterKeys
            }
        case .result:
            VStack(spacing: 0) {
                AIResultCardView(model: model)
                letterKeys
            }
        case .settings:
            VStack(spacing: 0) {
                ExtensionSettingsSheet(model: model)
                letterKeys
            }
        case .aiChat:
            ChatPanelView(model: model)
        case .voice:
            KMVoicePanel(
                voice: KMVoiceInput.shared,
                onClose: { model.closeVoiceInput() },
                onCommit: { text in model.insertText(text) }
            )
        }
    }

    /// 字母键区（多处复用：字母页本体，以及各个「面板 + 键盘」页的下半部分）。
    private var letterKeys: some View {
        KeyRowsView(
            layoutMode: model.layoutMode,
            shiftState: model.shiftState,
            isLandscape: model.isLandscape,
            onTap: { key in model.tap(key) },
            onMoveCursor: { offset in model.moveCursor(byCharacterOffset: offset) },
            accent: themeAccent,
            returnKeyKind: model.returnKeyKind
        )
    }

    // MARK: - 浮层

    /// 短语 / 剪贴板浮层（叠加在键区之上，不改变键盘高度）。
    @ViewBuilder
    private var overlayLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PhraseBarView(
                mode: model.overlay == .clipboardBar ? .clipboard : .phrases,
                phrases: model.phrases.map { $0.text },
                clipboardItems: model.clipboardItems,
                onSelect: { text in
                    model.insertText(text)
                    model.tap(.closeOverlay)
                },
                onClose: { model.tap(.closeOverlay) }
            )
            .frame(height: KMLayout.keyRowsHeight + KMLayout.keyGap)
            .background(Theme.keyboardBackground)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .background(Theme.overlayScrim.opacity(0.35))
        .onTapGesture { model.tap(.closeOverlay) }
        .zIndex(1)
    }

    // MARK: - Toast

    /// 一次性提示条。
    /// - Parameter message: 提示文案。
    private func toastLayer(_ message: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(message)
                .font(Theme.fontFootnote)
                .foregroundColor(Theme.textOnAccent)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(Theme.overlayScrim)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .padding(.bottom, Theme.Spacing.xl)
                .accessibilityLabel(Text(message))
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .transition(.opacity)
        .zIndex(2)
    }

    // MARK: - 完全访问说明卡

    /// 完全访问说明卡（扩展内无法跳转设置，只能列步骤文字引导）。
    private var fullAccessLayer: some View {
        VStack(spacing: Theme.Spacing.lg) {
            HStack {
                Text("需要开启完全访问")
                    .font(Theme.fontHeadline)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 0)
                Button(action: { model.setFullAccessCard(false) }) {
                    KMIconGlyph(symbol: "xmark.circle.fill", fallback: "✕", size: 20, tint: Theme.textTertiary)
                        .frame(width: Theme.Sizing.minTapTarget, height: Theme.Sizing.minTapTarget)
                }
                .buttonStyle(KMPressableStyle())
                .accessibilityLabel(Text("关闭"))
            }

            Text(KeyboardViewModel.noFullAccessMessage)
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Array(KeyboardViewModel.fullAccessSteps.enumerated()), id: \.offset) { pair in
                    Text("\(pair.offset + 1). \(pair.element)")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: Theme.MaterialToken.strokeWidth)
        )
        .padding(Theme.Spacing.xl)
        .zIndex(3)
        .transition(.opacity)
    }
}

// MARK: - 键盘外壳

/// 键盘外壳：统一背景 + 顶部阴影 + 内容槽。
///
/// 高度不在这里计算；调用方负责让内容恰好填满 `inputView` 的高度。
struct KeyboardShell<Content: View>: View {

    /// 内容（候选栏 + 键区）。
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            Theme.keyboardBackground
            VStack(spacing: 0) {
                // 顶部 0.5pt 阴影：键盘与宿主界面的分界（无圆角，符合系统键盘观感）。
                Rectangle()
                    .fill(Theme.keyboardTopShadow)
                    .frame(height: Theme.MaterialToken.strokeWidth)
                content()
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
