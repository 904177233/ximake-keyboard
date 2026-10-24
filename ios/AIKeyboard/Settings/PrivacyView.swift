//
//  PrivacyView.swift
//  墨语 · 宿主 App
//
//  模块职责：隐私说明页（纯本地说明，无网络请求）。
//  依赖：SwiftUI、AppState、SurfaceCard / SectionHeader / ListGroup / SettingsRow。
//  使用方：SettingsView。
//

import SwiftUI

/// 隐私说明页。
struct PrivacyView: View {

    @EnvironmentObject private var appState: AppState

    /// 清除本地数据的二次确认。
    @State private var showsClearAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                summaryCard
                dataSection
                controlsSection
                dangerSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("隐私")
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showsClearAlert) {
            Alert(
                title: Text("清除本地数据？"),
                message: Text("会清空剪贴板历史、自定义短语与本地词频学习记录。配置与 API Key 不受影响。"),
                primaryButton: .destructive(Text("清除")) {
                    clearLocalData()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - 一句话结论

    private var summaryCard: some View {
        SurfaceCard(style: .glass) {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    IconGlyph(
                        symbol: "hand.raised.fill",
                        fallback: "🛡️",
                        size: AppMetrics.glyphSize,
                        weight: .semibold,
                        tint: Theme.success
                    )
                    Text("数据不出本机")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }

                Text("墨语没有后端、没有账号、没有统计 SDK。你的输入内容只会发给你自己配置的 AI 服务商，App 与键盘之间也不经过任何服务器。")
                    .font(AppFont.body)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 存了什么

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "本机存了什么")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    dataLine(
                        "服务商配置",
                        "名称、baseURL、模型名、采样参数。保存在 App 与键盘共享的 UserDefaults。"
                    )
                    RowDivider(hasIcon: false)
                    dataLine(
                        "API Key",
                        "只保存在系统钥匙串（Keychain），不会写进配置文件，导出配置时默认也不带走。"
                    )
                    RowDivider(hasIcon: false)
                    dataLine(
                        "短语与自定义词",
                        "你手动添加的快捷短语与自造词，只存在本机。"
                    )
                    RowDivider(hasIcon: false)
                    dataLine(
                        "剪贴板历史",
                        "默认关闭。开启后键盘最多保留最近 20 条复制内容，随时可在这里关闭并清除。"
                    )
                    RowDivider(hasIcon: false)
                    dataLine(
                        "词频学习",
                        "记录你选过哪些候选词，用于调整排序；不包含输入内容本身。"
                    )
                }
            }
        }
    }

    private func dataLine(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
            Text(title)
                .font(AppFont.headline)
                .foregroundColor(Theme.textPrimary)
            Text(detail)
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 开关

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "隐私开关")
            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "clipboard", tint: Theme.success),
                    title: "剪贴板历史",
                    subtitle: appState.snapshot.enableClipboardHistory
                        ? "键盘可读取最近复制的文字"
                        : "关闭后键盘不读取剪贴板",
                    accessory: .toggle(
                        Binding(
                            get: { appState.snapshot.enableClipboardHistory },
                            set: { appState.setClipboardHistoryEnabled($0) }
                        )
                    )
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "brain", tint: Theme.success),
                    title: "本地学习",
                    subtitle: appState.snapshot.enableLearning
                        ? "词频与自造词只存在本机"
                        : "已关闭，候选词不会因你的选择而调整",
                    accessory: .toggle(
                        Binding(
                            get: { appState.snapshot.enableLearning },
                            set: { appState.setLearningEnabled($0) }
                        )
                    )
                )
            }
        }
    }

    // MARK: - 清除

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "清除")
            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "trash", tint: Theme.danger),
                    title: "清除本地数据",
                    subtitle: "剪贴板历史 / 短语 / 学习记录",
                    isDestructive: true
                ) {
                    showsClearAlert = true
                }
            }

            Text(AppInfo.disclaimer)
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppMetrics.hairGap)
        }
    }

    // MARK: - 逻辑

    private func clearLocalData() {
        appState.setClipboardHistoryEnabled(false)
        appState.setLearningEnabled(false)
        appState.showToast(
            ToastMessage(
                kind: .success,
                text: "已清除本地数据",
                detail: "剪贴板历史与学习记录已关闭并清空。"
            )
        )
        Haptics.success()
    }
}

#if DEBUG
struct PrivacyView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PrivacyView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
