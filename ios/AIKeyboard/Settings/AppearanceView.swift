//
//  AppearanceView.swift
//  墨语 · 宿主 App
//
//  模块职责：语气与外观设置（默认语气 / 回复条数 / 生图尺寸 / 深浅色 / 主题与形象入口）。
//  依赖：SwiftUI、AppState、ThemeStore、SegmentedTabs / SectionHeader / ListGroup / PillChip。
//  使用方：SettingsView / KeyboardHomeView。
//

import SwiftUI

/// 语气与外观设置页。
struct AppearanceView: View {

    @EnvironmentObject private var appState: AppState

    /// 当前主题名（用于入口行副标题）。从「主题与形象」返回时刷新一次。
    @State private var currentThemeName: String = ThemeStore.shared.currentTheme.name

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                toneSection
                replySection
                imageSizeSection
                appearanceSection
                themeSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("语气与外观")
        .navigationBarTitleDisplayMode(.inline)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear {
            currentThemeName = ThemeStore.shared.currentTheme.name
        }
    }

    // MARK: - 默认语气

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "默认语气", footnote: "润色、扩写、回复建议默认使用这个语气，键盘里可临时切换")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppMetrics.blockGap) {
                            ForEach(ToneOption.all, id: \.self) { tone in
                                PillChip(
                                    tone,
                                    style: .tone,
                                    isSelected: appState.currentTone == tone,
                                    action: {
                                        appState.setDefaultTone(tone)
                                        Haptics.selection()
                                    }
                                )
                            }
                        }
                        .padding(.vertical, AppMetrics.hairGap)
                    }

                    Text("选中后立即生效，键盘下次唤起时会读取。")
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - 回复条数

    private var replySection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "回复建议条数", footnote: "AI 一次生成几个候选回复")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                    HStack {
                        Text("\(appState.snapshot.replyCount) 条")
                            .font(AppFont.headline)
                            .foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Stepper(
                            "",
                            value: Binding(
                                get: { appState.snapshot.replyCount },
                                set: { appState.setReplyCount($0) }
                            ),
                            in: 1...5
                        )
                        .labelsHidden()
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppMetrics.tightGap) {
                            ForEach(Array(1...5), id: \.self) { count in
                                PillChip(
                                    "\(count) 条",
                                    style: .tag,
                                    isSelected: appState.snapshot.replyCount == count,
                                    action: {
                                        appState.setReplyCount(count)
                                        Haptics.selection()
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 生图尺寸

    private var imageSizeSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "生图尺寸", footnote: "「AI 试验场」里默认使用这个尺寸")

            ListGroup {
                ForEach(Array(ImageSizeOption.all.enumerated()), id: \.element.id) { index, option in
                    SettingsRow(
                        icon: IconSpec(symbol: "aspectratio", tint: Theme.warning),
                        title: option.title,
                        subtitle: option.size,
                        accessory: .checkmark(appState.snapshot.imageSize == option.size)
                    ) {
                        appState.setImageSize(option.size)
                        Haptics.selection()
                    }

                    if index < ImageSizeOption.all.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "外观", footnote: "深色模式下所有页面都做了适配")

            ListGroup {
                ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    SettingsRow(
                        icon: IconSpec(symbol: mode.systemImage, tint: Theme.accent),
                        title: mode.title,
                        accessory: .checkmark(appState.appearanceMode == mode)
                    ) {
                        withAnimation(Theme.Motion.normalAnimation) {
                            appState.appearanceMode = mode
                        }
                        Haptics.selection()
                    }

                    if index < AppearanceMode.allCases.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }
    // MARK: - 主题与形象

    /// 主题与小形象入口：显示当前主题名，进去可切换 6 套双色主题、导入自定义形象。
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(
                title: "主题与形象",
                footnote: "双色主题，主色只出现在最需要的地方"
            )

            ListGroup {
                NavigationLink {
                    ThemeSettingsView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "paintpalette.fill", tint: Theme.accent),
                        title: "主题与形象",
                        subtitle: currentThemeName,
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

#if DEBUG
struct AppearanceView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            AppearanceView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
