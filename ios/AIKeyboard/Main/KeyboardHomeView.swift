//
//  KeyboardHomeView.swift
//  墨语 · 宿主 App
//
//  模块职责：Tab1「键盘」——键盘状态仪表盘 + 快速开始 + 快捷入口。
//  依赖：SwiftUI、AppState、SurfaceCard / SettingsRow / SectionHeader / ListGroup、
//        InstallGuideView、ConfigTransferView、DiagnosticsView。
//  使用方：MainTabView。
//

import SwiftUI

/// 键盘主页。
struct KeyboardHomeView: View {

    @EnvironmentObject private var appState: AppState

    /// 是否展示"如何确认键盘状态"的说明弹窗。
    @State private var showsStatusHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                statusCard

                if appState.keyboardSetupState == .notConfigured {
                    quickStartGroup
                } else {
                    readinessGroup
                }

                chatGroup
                libraryGroup
                supportGroup
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("键盘")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showsStatusHelp) {
            KeyboardStatusHelpSheet(onClose: { showsStatusHelp = false })
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        SurfaceCard(style: .glass) {
            VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                HStack(alignment: .center, spacing: AppMetrics.rowGap) {
                    RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                        .fill(AppColor.accentWash)
                        .frame(width: AppMetrics.iconTileSize + AppMetrics.blockGap,
                               height: AppMetrics.iconTileSize + AppMetrics.blockGap)
                        .overlay(
                            IconGlyph(
                                symbol: "keyboard",
                                fallback: "⌨️",
                                size: AppMetrics.glyphSize + AppMetrics.hairGap,
                                weight: .semibold,
                                tint: Theme.accent
                            )
                        )

                    VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                        Text("墨语键盘")
                            .font(AppFont.headline)
                            .foregroundColor(Theme.textPrimary)
                        Text(installedLine)
                            .font(AppFont.footnote)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                RowDivider(hasIcon: false)

                HStack(spacing: AppMetrics.tightGap) {
                    IconGlyph(
                        symbol: appState.keyboardSetupState.systemImage,
                        fallback: "",
                        size: AppMetrics.glyphSizeSmall,
                        weight: .semibold,
                        tint: statusTint
                    )
                    Text(appState.keyboardSetupState.title)
                        .font(AppFont.footnoteStrong)
                        .foregroundColor(statusTint)
                    Text("·")
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textTertiary)
                    Text(appState.keyboardStatusDetail)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        showsStatusHelp = true
                    } label: {
                        Text("如何确认")
                            .font(AppFont.caption)
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    /// 扩展安装/使用情况的一句话。
    private var installedLine: String {
        if appState.extensionLastActiveAt != nil {
            return "最近使用：\(ExtensionTelemetry.relativeDescription(appState.extensionLastActiveAt))"
        }
        if appState.isExtensionInstalled {
            return "扩展已安装 · 还没检测到使用记录"
        }
        return "还没有检测到键盘扩展，请先完成安装"
    }

    private var statusTint: Color {
        switch appState.keyboardSetupState {
        case .ready: return Theme.success
        case .partial: return Theme.warning
        case .notConfigured: return Theme.textSecondary
        }
    }

    // MARK: - 首次使用的三步

    private var quickStartGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "快速开始", footnote: "三步就能在聊天框里用上 AI")
            ListGroup {
                NavigationLink {
                    InstallGuideView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "square.grid.2x2", tint: Theme.accent),
                        title: "添加键盘",
                        subtitle: "设置 › 通用 › 键盘 › 键盘 › 添加新键盘",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    InstallGuideView(initialStep: 3)
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "lock.shield", tint: Theme.success),
                        title: "开启完全访问",
                        subtitle: "不开这个，键盘无法联网，AI 不可用",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    ProviderListView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "sparkles", tint: Theme.accent),
                        title: "配置 AI 服务",
                        subtitle: appState.isChatReady ? "已配置 \(appState.chatProviders.count) 个服务商" : "还没有配置",
                        accessory: .value(appState.isChatReady ? "已配置" : "未配置")
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - 就绪后的能力概览

    private var readinessGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "我的 AI")
            ListGroup {
                NavigationLink {
                    ProviderListView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "server.rack", tint: Theme.accent),
                        title: "对话服务商",
                        subtitle: appState.defaultChatProvider?.displaySummary,
                        accessory: .value(appState.isReadyForAI ? "可用" : "待补 Key")
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
                        subtitle: appState.imageProvider?.displaySummary ?? "未选择",
                        accessory: .value(appState.isImageReady ? "可用" : "未配置")
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    AppearanceView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "textformat.size", tint: Theme.textSecondary),
                        title: "默认语气",
                        subtitle: "润色 / 回复建议默认使用的语气",
                        accessory: .value(appState.currentTone)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - 在聊天里试一下

    private var chatGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "在聊天里试一下")
            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                    Text("切换到墨语键盘后，点输入框上方的 ✨ 就能润色、翻译或生成回复。")
                        .font(AppFont.body)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SecondaryButton(
                        title: "查看使用方式",
                        systemImage: "questionmark.circle",
                        tone: .neutral,
                        size: .medium,
                        fullWidth: true
                    ) {
                        appState.selectedTab = .playground
                    }

                    Text("iOS 不允许 App 直接打开其它 App，请手动切到微信，长按地球键切换到墨语。")
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 词库与短语

    private var libraryGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "词库与短语")
            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "character.book.closed", tint: Theme.accent),
                    title: "拼音词库",
                    subtitle: dictionarySubtitle,
                    accessory: .value(dictionaryVersion)
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "text.badge.plus", tint: Theme.success),
                    title: "快捷短语",
                    subtitle: "输入触发词即可展开成整段文字",
                    accessory: .value("\(appState.phraseCount) 条")
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "clipboard", tint: Theme.textSecondary),
                    title: "剪贴板历史",
                    subtitle: appState.snapshot.enableClipboardHistory ? "已开启，最多保留最近 20 条" : "关闭时键盘不读取剪贴板",
                    accessory: .value(appState.snapshot.enableClipboardHistory ? "已开启" : "已关闭")
                )
            }
        }
    }

    private var dictionarySubtitle: String {
        guard let info = appState.dictionaryInfo else {
            return "词库未加载，可在诊断页查看"
        }
        return "\(info.formattedWordCount) 词"
    }

    private var dictionaryVersion: String {
        guard let info = appState.dictionaryInfo else { return "未知" }
        return "v\(info.version)"
    }

    // MARK: - 支持

    private var supportGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "支持")
            ListGroup(footer: "免费 Apple ID 签名的 App 每 7 天需要续签一次。") {
                NavigationLink {
                    InstallGuideView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "book", tint: Theme.accent),
                        title: "安装与续签指南",
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
                        subtitle: "检查键盘、权限与网络",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - 状态说明弹窗

/// 解释"为什么 App 不能确定键盘是否已添加"。
private struct KeyboardStatusHelpSheet: View {

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "如何确认键盘状态", onClose: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                            Text("为什么这里只显示「可能」")
                                .font(AppFont.headline)
                                .foregroundColor(Theme.textPrimary)
                            Text("iOS 不允许 App 查询「本键盘是否已添加到系统键盘列表」。墨语只能通过键盘扩展最近一次使用的时间来推测，因此状态可能是「可能未添加」。")
                                .font(AppFont.body)
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                            Text("手动确认")
                                .font(AppFont.headline)
                                .foregroundColor(Theme.textPrimary)
                            checkLine("1", "打开任意输入框，长按地球键")
                            checkLine("2", "看列表里有没有「墨语」")
                            checkLine("3", "有就说明已添加；没有请按指南添加")
                        }
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                            Text("完全访问")
                                .font(AppFont.headline)
                                .foregroundColor(Theme.textPrimary)
                            Text(AppInfo.openAccessPath)
                                .font(AppFont.monospacedFootnote)
                                .foregroundColor(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("系统限制：无法直接跳到键盘设置页，需要手动进入。")
                                .font(AppFont.caption)
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                .padding(AppMetrics.pageInset)
            }
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .presentationDetents([.large])
    }

    private func checkLine(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: AppMetrics.blockGap) {
            Text(index)
                .font(AppFont.footnoteStrong)
                .foregroundColor(Theme.accent)
                .frame(width: AppMetrics.glyphSize, alignment: .leading)
            Text(text)
                .font(AppFont.body)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
struct KeyboardHomeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            KeyboardHomeView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
