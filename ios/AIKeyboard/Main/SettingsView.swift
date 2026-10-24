//
//  SettingsView.swift
//  墨语 · 宿主 App
//
//  模块职责：Tab3「设置」——AI / 键盘 / 隐私 / 同步 / 支持 / 危险区 六组。
//  依赖：SwiftUI、AppState、SettingsRow / SectionHeader / ListGroup、
//        各二级页（ProviderListView / PromptLibraryView / AppearanceView /
//        PrivacyView / ConfigTransferView / InstallGuideView / DiagnosticsView / AboutView）。
//  使用方：MainTabView。
//

import SwiftUI

/// 设置主页。
struct SettingsView: View {

    @EnvironmentObject private var appState: AppState

    /// 危险操作的二次确认。
    @State private var showsResetAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                aiGroup
                keyboardGroup
                privacyGroup
                syncGroup
                supportGroup
                dangerGroup
                footer
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .alert(isPresented: $showsResetAlert) {
            Alert(
                title: Text("恢复默认服务商列表？"),
                message: Text("会清空你添加的服务商与默认项，API Key 不会随之删除，需要重新填写。"),
                primaryButton: .destructive(Text("恢复")) {
                    appState.resetToPresetOnly()
                    Haptics.warning()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - AI

    private var aiGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "AI")
            ListGroup {
                NavigationLink {
                    ProviderListView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "server.rack", tint: Theme.accent),
                        title: "AI 服务",
                        subtitle: "配置服务商与 API Key",
                        accessory: .value(chatProviderValue)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    ProviderListView(showImageProviders: true)
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "photo.on.rectangle.angled", tint: Theme.warning),
                        title: "生图服务商",
                        subtitle: "即梦 / 通义万相，试验场可用",
                        accessory: .value(appState.isImageReady ? (appState.imageProvider?.name ?? "已配置") : "未配置")
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    AppearanceView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "slider.horizontal.3", tint: Theme.accent),
                        title: "语气与外观",
                        subtitle: "默认语气、深浅色",
                        accessory: .value(appState.currentTone)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    PromptLibraryView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "square.stack.3d.up", tint: Theme.accent),
                        title: "Prompt 模板",
                        subtitle: "内置模板只读，可复制为自定义",
                        accessory: .value("\(PromptCatalog.builtIn.count + PromptCatalog.custom.count) 个")
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var chatProviderValue: String {
        guard appState.isChatReady else { return "未配置" }
        return appState.defaultChatProvider?.name ?? "已配置"
    }

    // MARK: - 键盘

    private var keyboardGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "键盘", footnote: "布局与候选设置会在键盘扩展内生效")
            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "text.cursor", tint: Theme.textSecondary),
                    title: "键盘布局",
                    subtitle: "26 键全键盘",
                    accessory: .value("26 键")
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "character.cursor.ibeam", tint: Theme.textSecondary),
                    title: "候选字号",
                    subtitle: "标准 / 大",
                    accessory: .value("标准")
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "speaker.wave.2", tint: Theme.textSecondary),
                    title: "按键音",
                    accessory: .value("关闭")
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "hand.tap", tint: Theme.textSecondary),
                    title: "振动反馈",
                    accessory: .value("开启")
                )
            }
        }
    }

    // MARK: - 隐私

    private var privacyGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "隐私")
            ListGroup(footer: "这两项都只在本机生效，不会上传任何内容。") {
                SettingsRow(
                    icon: IconSpec(symbol: "clipboard", tint: Theme.success),
                    title: "剪贴板历史",
                    subtitle: appState.snapshot.enableClipboardHistory ? "键盘可读取最近复制的文字" : "关闭后键盘不读取剪贴板",
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
                    subtitle: "词频与自造词只存在本机",
                    accessory: .toggle(
                        Binding(
                            get: { appState.snapshot.enableLearning },
                            set: { appState.setLearningEnabled($0) }
                        )
                    )
                )

                RowDivider()

                NavigationLink {
                    PrivacyView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "hand.raised", tint: Theme.success),
                        title: "隐私说明",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - 同步

    private var syncGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "同步")
            ListGroup {
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
    }

    // MARK: - 支持

    private var supportGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "支持")
            ListGroup {
                NavigationLink {
                    InstallGuideView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "book", tint: Theme.accent),
                        title: "安装与续签指南",
                        subtitle: "没有 Mac 也能装到 iPhone",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "stethoscope", tint: Theme.warning),
                        title: "诊断",
                        subtitle: "键盘、权限、网络与配置",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "info.circle", tint: Theme.textSecondary),
                        title: "关于墨语",
                        accessory: .value("\(AppInfo.version) (\(AppInfo.build))")
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - 危险区

    private var dangerGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "重置")
            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "arrow.counterclockwise", tint: Theme.danger),
                    title: "恢复默认服务商列表",
                    subtitle: "保留语气与隐私设置",
                    isDestructive: true
                ) {
                    showsResetAlert = true
                }

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "arrow.clockwise.circle", tint: Theme.danger),
                    title: "重新观看引导",
                    isDestructive: true
                ) {
                    appState.restartOnboarding()
                }
            }
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: AppMetrics.hairGap) {
            Text("\(AppInfo.displayName) \(AppInfo.version) (\(AppInfo.build)) · \(AppInfo.minimumIOS)+")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
            Text(signatureLine)
                .font(AppFont.caption)
                .foregroundColor(signatureTint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppMetrics.hairGap)
    }

    /// 签名剩余天数（从首次运行日期起算 7 天）。
    private var signatureLine: String {
        let remaining = SignatureClock.remainingDays()
        switch remaining {
        case .unknown:
            return "免费签名的 App 每 7 天需要续签一次"
        case .expired:
            return "签名可能已过期 · 请重新安装"
        case .days(let value):
            if value <= 2 {
                return "签名剩余 \(value) 天 · 该续签了"
            }
            return "签名剩余 \(value) 天"
        }
    }

    private var signatureTint: Color {
        let remaining = SignatureClock.remainingDays()
        switch remaining {
        case .unknown:
            return Theme.textTertiary
        case .expired:
            return Theme.danger
        case .days(let value):
            return value <= 2 ? Theme.warning : Theme.textTertiary
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
