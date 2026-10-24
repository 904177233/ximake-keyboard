//
//  ConfigTransferView.swift
//  墨语 · 宿主 App
//
//  模块职责：把配置「搬到」键盘（P0）。
//            免费 Apple ID 签名下没有 App Group，App 与键盘各自存配置，
//            这里用系统剪贴板把快照搬过去（`PasteboardBridge.export`）。
//  依赖：SwiftUI、AppState、SharedBridge（ConfigExporter）、SurfaceCard / ErrorBanner / StepCard。
//  使用方：SettingsView / PasteboardSyncSection。
//

import SwiftUI

/// 同步到键盘页。
struct ConfigTransferView: View {

    @EnvironmentObject private var appState: AppState

    /// 是否包含 API Key（默认否，勾选要提示风险）。
    @State private var includeAPIKeys = false

    /// 最近一次导出的描述。
    @State private var lastExportDescription: String?

    /// 是否展开「为什么这么麻烦」。
    @State private var showsWhy = false

    /// 是否已复制。
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                if ConfigExporter.isAppGroupAvailable {
                    appGroupReadyCard
                } else {
                    noAppGroupCard
                }

                stepsSection
                exportSection
                if !ConfigExporter.isAppGroupAvailable {
                    whySection
                }
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("同步到键盘")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if lastExportDescription == nil {
                lastExportDescription = snapshotSummary
            }
        }
    }

    // MARK: - App Group 可用

    private var appGroupReadyCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    IconGlyph(
                        symbol: "checkmark.seal.fill",
                        fallback: "✓",
                        size: AppMetrics.glyphSize,
                        weight: .semibold,
                        tint: Theme.success
                    )
                    Text("配置已自动共享")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }
                Text("当前签名支持 App Group，App 与键盘共用同一份配置，改完立即生效，不需要手动搬运。")
                    .font(AppFont.body)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 无 App Group 说明

    private var noAppGroupCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(spacing: AppMetrics.tightGap) {
                    IconGlyph(
                        symbol: "info.circle.fill",
                        fallback: "ℹ️",
                        size: AppMetrics.glyphSize,
                        weight: .semibold,
                        tint: Theme.accent
                    )
                    Text("免费签名不支持 App Group")
                        .font(AppFont.headline)
                        .foregroundColor(Theme.textPrimary)
                }

                Text("App 和键盘的配置是分开存的。这里可以用剪贴板把配置搬过去：本页写入 → 打开键盘 → 键盘内 ⚙️ → 「从 App 导入」。")
                    .font(AppFont.body)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Apple 只允许同一个 Team 的 App 与扩展共享 App Group，而免费 Apple ID 的签名没有这个能力，所以只能这样搬运。")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 三步

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "三步完成")

            VStack(spacing: 0) {
                StepCard(
                    index: 1,
                    title: "写入配置到剪贴板",
                    detail: "点下面的按钮，当前所有服务商与偏好会被打包复制到系统剪贴板。",
                    icon: "square.and.arrow.up"
                )
                StepConnector()
                StepCard(
                    index: 2,
                    title: "打开键盘并点 ⚙️",
                    detail: "在任意聊天 App 里切到墨语键盘，点工具栏上的齿轮按钮。",
                    icon: "keyboard"
                )
                StepConnector()
                StepCard(
                    index: 3,
                    title: "选择「从 App 导入」",
                    detail: "键盘会读取剪贴板里的配置，确认后写入自己的存储。",
                    icon: "square.and.arrow.down"
                )
            }
        }
    }

    // MARK: - 导出

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "导出")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    if let lastExportDescription {
                        statusLine(lastExportDescription)
                    }

                    PrimaryButton(
                        title: "写入配置到剪贴板",
                        systemImage: "doc.on.clipboard",
                        tone: .accent,
                        size: .large,
                        fullWidth: true
                    ) {
                        export()
                    }

                    SecondaryButton(
                        title: didCopy ? "已复制 ✓" : "清空剪贴板里的配置",
                        systemImage: "trash",
                        tone: .neutral,
                        size: .medium,
                        fullWidth: true
                    ) {
                        clearPasteboard()
                    }

                    RowDivider(hasIcon: false)

                    apiKeyToggle

                    if includeAPIKeys {
                        ErrorBanner(
                            severity: .warning,
                            title: "API Key 会被一并复制",
                            message: "剪贴板里的内容其它 App 也可能读到。只在私人设备上这样做，导入完成后建议清空剪贴板。"
                        )
                    }

                    Text("API Key 默认不导出：剪贴板是公共区域，建议导入配置后在键盘内单独填入 Key。")
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var apiKeyToggle: some View {
        Toggle(isOn: $includeAPIKeys) {
            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text("同时导出 API Key")
                    .font(AppFont.headline.weight(.regular))
                    .foregroundColor(Theme.textPrimary)
                Text(includeAPIKeys ? "高风险：Key 会进入剪贴板" : "推荐关闭，保护 Key 安全")
                    .font(AppFont.footnote)
                    .foregroundColor(includeAPIKeys ? Theme.danger : Theme.textSecondary)
            }
        }
        .tint(includeAPIKeys ? Theme.danger : Theme.accent)
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: AppMetrics.tightGap) {
            IconGlyph(
                symbol: didCopy ? "checkmark.circle.fill" : "doc.text",
                fallback: "📄",
                size: AppMetrics.glyphSizeSmall,
                weight: .semibold,
                tint: didCopy ? Theme.success : Theme.textSecondary
            )
            Text(text)
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 为什么

    private var whySection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    SettingsRow(
                        icon: IconSpec(symbol: "questionmark.circle", tint: Theme.textSecondary),
                        title: "为什么这么麻烦？",
                        subtitle: "展开看 App Group 与签名限制",
                        accessory: .chevron
                    ) {
                        withAnimation(Theme.Motion.spring) {
                            showsWhy.toggle()
                        }
                    }

                    if showsWhy {
                        RowDivider()
                        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                            Text("App Group 是 iOS 给「同一个开发者」的一组 App 与扩展共享容器。免费 Apple ID 只能用个人签名，没有 Team 概念，系统不会分配共享容器。")
                                .font(AppFont.footnote)
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("想彻底免掉这一步，需要加入 Apple Developer Program（每年 $99），用付费 Team 重新签名后 App Group 就会生效。")
                                .font(AppFont.footnote)
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(AppInfo.disclaimer)
                                .font(AppFont.caption)
                                .foregroundColor(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(AppMetrics.cardPadding)
                    }
                }
            }
        }
    }

    // MARK: - 逻辑

    /// 快照的一句话摘要。
    private var snapshotSummary: String {
        let providers = appState.snapshot.providers.count
        let version = appState.snapshot.version
        return "待导出：配置 v\(version) · \(providers) 个服务商 · 不含 Key"
    }

    private func export() {
        let success = appState.exportConfigToKeyboard(includeAPIKeys: includeAPIKeys)
        if success {
            didCopy = true
            lastExportDescription = includeAPIKeys
                ? "已写入（含 Key，请尽快导入并清空剪贴板）"
                : "已写入（不含 Key，请在键盘内单独填 Key）"
            Haptics.success()
            scheduleResetCopyState()
        } else {
            lastExportDescription = "写入失败，请重试"
            Haptics.warning()
        }
    }

    private func clearPasteboard() {
        PasteboardBridge.clear()
        UIPasteboard.general.string = ""
        didCopy = false
        lastExportDescription = "剪贴板里的配置已清空"
        Haptics.light()
        appState.showToast(ToastMessage(kind: .info, text: "已清空剪贴板里的配置"))
    }

    private func scheduleResetCopyState() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.toastDuration) {
            didCopy = false
        }
    }
}

// MARK: - 旧的包装视图（向后兼容）

/// 兼容旧任务书里的 `PasteboardSyncSection` 命名，实际跳转到 `ConfigTransferView`。
struct PasteboardSyncSection: View {

    var body: some View {
        NavigationLink {
            ConfigTransferView()
        } label: {
            SettingsRow(
                icon: IconSpec(symbol: "arrow.left.arrow.right", tint: Theme.accent),
                title: "同步到键盘",
                subtitle: ConfigExporter.isAppGroupAvailable
                    ? "App Group 可用，配置已自动共享"
                    : "免费签名无 App Group，需用剪贴板搬运",
                accessory: .chevron
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#if DEBUG
struct ConfigTransferView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ConfigTransferView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
