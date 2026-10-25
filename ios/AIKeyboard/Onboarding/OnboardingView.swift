//
//  OnboardingView.swift
//  墨语 · 宿主 App
//
//  模块职责：首次启动的 5 步引导（固定 5 步，见 design/主App界面规范.md §1）。
//            欢迎 → 添加键盘 → 完全访问 → 配置 AI 服务 → 装到手机上。
//  依赖：SwiftUI、AppState、OnboardingStep、ProviderEditorView、InstallGuideView。
//  使用方：RootView。
//

import SwiftUI

/// 5 步引导页。
struct OnboardingView: View {

    @EnvironmentObject private var appState: AppState

    /// 当前页（0…4）。
    @State private var stepIndex: Int = 0

    /// 是否展示"设置路径图示"。
    @State private var showsPathGuide = false

    /// 是否推入服务商编辑页。
    @State private var showsProviderEditor = false

    /// 是否推入安装指南。
    @State private var showsInstallGuide = false

    /// 是否正在完成（防止连点）。
    @State private var isFinishing = false

    private var steps: [OnboardingStep] { OnboardingStep.all }

    private var currentStep: OnboardingStep {
        steps[min(max(stepIndex, 0), steps.count - 1)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, AppMetrics.pageInset)
                    .padding(.top, AppMetrics.blockGap)

                TabView(selection: $stepIndex) {
                    ForEach(steps) { step in
                        OnboardingStepContent(step: step)
                            .tag(step.index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
                    .padding(.horizontal, AppMetrics.pageInset)
                    .padding(.bottom, Theme.Spacing.xxl)
            }
            .background(AppColor.pageBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("跳过引导") {
                        finish()
                    }
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                }
            }
            .navigationDestination(isPresented: $showsProviderEditor) {
                ProviderEditorView(provider: appState.defaultChatProvider) { saved in
                    appState.upsertProvider(saved)
                    if saved.supportsChat {
                        appState.setDefaultChatProvider(id: saved.id)
                    } else {
                        appState.setDefaultImageProvider(id: saved.id)
                    }
                    showsProviderEditor = false
                    advance()
                }
            }
            .navigationDestination(isPresented: $showsInstallGuide) {
                InstallGuideView()
            }
            .onAppear(perform: restoreProgress)
            .onChange(of: stepIndex) { newValue in
                persistProgress(newValue)
            }
            .sheet(isPresented: $showsPathGuide) {
                SettingPathGuideSheet(onClose: { showsPathGuide = false })
            }
        }
    }

    // MARK: - 顶部进度条

    private var progressBar: some View {
        HStack(spacing: AppMetrics.tightGap) {
            ForEach(0..<steps.count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(segmentColor(index))
                    .frame(height: AppMetrics.hairline * 6)
            }
        }
        .frame(height: AppMetrics.hairGap)
        .accessibilityElement()
        .accessibilityLabel(Text("引导进度，第 \(stepIndex + 1) 步，共 \(steps.count) 步"))
    }

    private func segmentColor(_ index: Int) -> Color {
        if index < stepIndex {
            return Theme.accent
        }
        if index == stepIndex {
            return Theme.accent.opacity(0.6)
        }
        return Theme.separator
    }

    // MARK: - 底部按钮

    private var bottomBar: some View {
        VStack(spacing: AppMetrics.blockGap) {
            PrimaryButton(
                title: currentStep.primaryTitle,
                tone: .accent,
                size: .large,
                isEnabled: !isFinishing,
                isLoading: isFinishing,
                fullWidth: true
            ) {
                handlePrimary()
            }

            if currentStep.canSkip {
                Button {
                    advance()
                } label: {
                    Text(stepIndex == steps.count - 1 ? "完成" : "跳过")
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .frame(minHeight: AppMetrics.minTapHeight)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text("这一步不能跳过")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .frame(minHeight: AppMetrics.minTapHeight)
            }
        }
    }

    // MARK: - 交互

    private func handlePrimary() {
        Haptics.light()
        switch stepIndex {
        case 0, 1:
            advance()
        case 2:
            // 完全访问：提示后前进，同时展示系统设置入口。
            advance()
        case 3:
            showsProviderEditor = true
        case 4:
            showsInstallGuide = true
        default:
            finish()
        }
    }

    /// 前进一步，走到末尾则完成。
    private func advance() {
        if stepIndex >= steps.count - 1 {
            finish()
            return
        }
        withAnimation(Theme.Motion.spring) {
            stepIndex += 1
        }
    }

    /// 标记引导完成。
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        persistProgress(0)
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.normal) {
            appState.completeOnboarding()
            isFinishing = false
        }
    }

    private func restoreProgress() {
        let saved = SharedStore.shared.defaults.integer(forKey: OnboardingStep.progressKey)
        if saved > 0 && saved < steps.count {
            stepIndex = saved
        }
    }

    private func persistProgress(_ value: Int) {
        SharedStore.shared.defaults.set(value, forKey: OnboardingStep.progressKey)
    }
}

// MARK: - 单步内容

/// 一步的图标 + 标题 + 正文。
private struct OnboardingStepContent: View {

    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AppMetrics.heroGap)

            ZStack {
                RoundedRectangle(cornerRadius: AppMetrics.onboardingIconRadius, style: .continuous)
                    // v2：**不用渐变**（design/06 §1.8）。图标底是 56pt 小方块，
                    // 从浅到深的对角渐变在小面积上只是一团糊，改成一个实色淡底 + 发丝环。
                    .fill(AppColor.accentWash)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: AppMetrics.onboardingIconRadius,
                            style: .continuous
                        )
                        .strokeBorder(AppColor.chipBorder, lineWidth: AppMetrics.hairline)
                    )

                IconGlyph(
                    symbol: step.symbol,
                    fallback: step.fallbackEmoji,
                    size: AppMetrics.onboardingIconSize,
                    weight: .regular,
                    tint: Theme.accent
                )
            }
            .frame(width: AppMetrics.onboardingIconBox, height: AppMetrics.onboardingIconBox)
            .accessibilityHidden(true)

            Text(step.title)
                .font(.system(size: AppMetrics.onboardingTitleSize, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, AppMetrics.heroGap)
                .padding(.horizontal, AppMetrics.pageInset * 2)

            Text(step.body)
                .font(AppFont.body)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(AppMetrics.chipIconGap)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppMetrics.rowVPadding)
                .padding(.horizontal, AppMetrics.pageInset + AppMetrics.blockGap)

            if step.index == 2 {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("去系统设置")
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.accent)
                        .frame(minHeight: AppMetrics.minTapHeight)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, AppMetrics.blockGap)

                Text("系统限制：无法直接跳到键盘设置，请按上面的路径手动进入。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppMetrics.pageInset + AppMetrics.blockGap)
            }

            Spacer(minLength: AppMetrics.heroGap)
        }
    }
}

// MARK: - 设置路径图示

/// 用纯 SwiftUI 画"设置 › 通用 › 键盘 › 键盘 › 墨语"的路径，不依赖截图。
private struct SettingPathGuideSheet: View {

    let onClose: () -> Void

    private let path = ["设置", "通用", "键盘", "键盘", "墨语", "允许完全访问"]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "设置路径图示", subtitle: "手动按顺序点进去", onClose: onClose)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(path.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: AppMetrics.blockGap) {
                            Text("\(index + 1)")
                                .font(AppFont.caption)
                                .foregroundColor(Theme.textOnAccent)
                                .frame(width: AppMetrics.iconColumn, height: AppMetrics.iconColumn)
                                .background(
                                    Circle().fill(index == path.count - 1 ? Theme.success : Theme.accent)
                                )

                            Text(item)
                                .font(AppFont.headline)
                                .foregroundColor(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, AppMetrics.rowVPadding)
                                .padding(.horizontal, AppMetrics.cardPadding)
                                .background(
                                    RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                                        .fill(index == path.count - 1 ? AppColor.successWash : Theme.surface)
                                )
                        }
                        .padding(.horizontal, AppMetrics.pageInset)

                        if index < path.count - 1 {
                            IconGlyph(
                                symbol: "chevron.down",
                                fallback: "↓",
                                size: AppMetrics.glyphSizeSmall,
                                tint: Theme.textTertiary
                            )
                            .padding(.vertical, AppMetrics.hairGap)
                        }
                    }
                }
                .padding(.vertical, AppMetrics.cardPadding)
            }

            VStack(spacing: AppMetrics.blockGap) {
                PrimaryButton(title: "打开系统设置", systemImage: "gear", tone: .accent, size: .medium, fullWidth: true) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Text("只能跳到墨语自己的设置页，键盘列表需要手动点。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .presentationDetents([.large])
    }
}

#if DEBUG
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView()
            .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
