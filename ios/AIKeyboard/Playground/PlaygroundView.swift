//
//  PlaygroundView.swift
//  墨语 · 宿主 App
//
//  模块职责：「AI 试验场」（Tab 2）—— 不依赖键盘，全屏试用全部 AI 能力。
//            输入 → 选能力 / 服务商 / 语气 / 模板 → 流式输出卡片 / 生图卡片 →
//            复制、保存为短语、重试。
//            本文件只保留状态、页面骨架、输入区与能力 chips；
//            参数区见 `PlaygroundParameterSection.swift`，
//            生成 / 结果 / 提示 / 逻辑见 `PlaygroundActionSection.swift`。
//  依赖：SwiftUI、AppState、PlaygroundEngine、SurfaceCard / PillChip / ErrorBanner。
//  使用方：MainTabView。
//

import SwiftUI

/// AI 试验场。
///
/// 本页是宿主 App 里不依赖键盘就能试用全部 AI 能力的地方：
/// 填一段文字（或一段画面描述）→ 选能力 / 服务商 / 语气 / 模板 → 看流式结果或生成图片。
struct PlaygroundView: View {

    @EnvironmentObject var appState: AppState

    /// 执行引擎。
    @StateObject var engine = PlaygroundEngine()

    /// 输入文本。
    @State var inputText = ""

    /// 当前能力。
    @State var feature: AIFeature = .polish

    /// 语气。
    @State var tone: String = ToneOption.fallback

    /// 翻译目标语言。
    @State var targetLanguage: String = "英语"

    /// 生图尺寸。
    @State var imageSize: String = "1024x1024"

    /// 选中的对话服务商 ID。
    @State var chatProviderID: String?

    /// 选中的生图服务商 ID。
    @State var imageProviderID: String?

    /// 选中的模板 ID（nil = 默认模板）。
    @State var templateID: String?

    /// 是否展开参数区。
    @State var showsParameters = false

    /// 输入框是否聚焦。
    @FocusState var isInputFocused: Bool

    /// 当前能力是否需要图像结果。
    var isImageFeature: Bool {
        feature == .image
    }

    /// 输入长度上限。
    static let inputLimit = 2000

    /// 结果区滚动锚点。
    static let resultAnchor = "playground-result"

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                    if !appState.isReadyForAI {
                        notReadyBanner
                    }

                    inputCard
                    featureChips
                    parameterRow
                    generateButton

                    if let state = engine.state {
                        resultSection(state: state)
                            .id(Self.resultAnchor)
                    }

                    if engine.state == nil {
                        tipsCard
                    }
                }
                .padding(.horizontal, AppMetrics.pageInset)
                .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
                .onChange(of: engine.state) { newValue in
                    guard let newValue else { return }
                    if case .streaming = newValue { return }
                    withAnimation(Theme.Motion.normalAnimation) {
                        proxy.scrollTo(Self.resultAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("AI 试验场")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: syncDefaults)
    }

    // MARK: - 未配置提示

    /// 一个服务商都没配时，页面顶部的引导条。
    var notReadyBanner: some View {
        ErrorBanner(
            severity: .warning,
            title: "还没有可用的 AI 服务",
            message: "去「设置 › AI 服务」添加一个服务商并填入 API 密钥，就能在这里试用全部能力。",
            actionTitle: "去配置"
        ) {
            appState.selectedTab = .settings
        }
    }

    // MARK: - 输入

    /// 输入卡片：多行输入 + 字数 + 清空。
    var inputCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text(isImageFeature ? "描述一下想画什么…" : "输入一段话，试试 AI…")
                            .font(AppFont.body)
                            .foregroundColor(Theme.textPlaceholder)
                            .padding(.top, AppMetrics.blockGap)
                            .padding(.leading, AppMetrics.tightGap)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $inputText)
                        .font(AppFont.body)
                        .foregroundColor(Theme.textPrimary)
                        .frame(minHeight: AppMetrics.playgroundInputHeight)
                        .focused($isInputFocused)
                        .scrollContentBackgroundHiddenCompat()
                        .onChange(of: inputText) { newValue in
                            if newValue.count > Self.inputLimit {
                                inputText = String(newValue.prefix(Self.inputLimit))
                            }
                        }
                }

                HStack(spacing: AppMetrics.tightGap) {
                    Text("\(inputText.count) / \(Self.inputLimit)")
                        .font(AppFont.caption)
                        .foregroundColor(inputText.count >= Self.inputLimit ? Theme.warning : Theme.textTertiary)
                        .monospacedDigit()

                    Spacer(minLength: 0)

                    if !inputText.isEmpty {
                        Button {
                            withAnimation(Theme.Motion.fastAnimation) {
                                inputText = ""
                            }
                            Haptics.light()
                        } label: {
                            Text("清空")
                                .font(AppFont.footnote)
                                .foregroundColor(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: AppMetrics.minTapHeight)
                    }
                }
            }
        }
    }

    // MARK: - 能力

    /// 能力胶囊：润色 / 扩写 / 翻译 / 回复 / 生图。
    var featureChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppMetrics.blockGap) {
                ForEach(AIFeature.allCases, id: \.rawValue) { item in
                    PillChip(
                        item.title,
                        systemImage: FeatureGlyph.symbol(for: item),
                        emoji: FeatureGlyph.fallback(for: item),
                        style: .tool,
                        isSelected: feature == item,
                        action: {
                            withAnimation(Theme.Motion.fastAnimation) {
                                feature = item
                                templateID = nil
                            }
                            isInputFocused = false
                            engine.clear()
                            Haptics.selection()
                        }
                    )
                }
            }
            .padding(.vertical, AppMetrics.hairGap)
        }
    }
}


#if DEBUG
struct PlaygroundView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PlaygroundView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
